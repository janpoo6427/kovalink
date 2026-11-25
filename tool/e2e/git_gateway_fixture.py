#!/usr/bin/env python3
"""Loopback kovapilot gateway with a throwaway Git repository.

For KovaLink's Git maintenance e2e (test/kovapilot_git_e2e_test.dart) and
screen captures. It runs kovapilot's own ``create_app`` and ``GitRepository``
(nothing in kovapilot is changed or patched) but points the repository at a
fixture checkout under ``--state`` instead of the kovapilot checkout, so the
tests control branches, history and the dirty flag.

  PYTHONPATH=<kovapilot checkout>:<aiohttp overlay> \
    python tool/e2e/git_gateway_fixture.py --port 18083 --state /tmp/kova-git-e2e

State directory layout:
  git/origin.git   bare "origin" with the fixture branches
  git/device       clone on master tracking origin/master (what status reads)
  updater_state    text returned as updaterState (missing file -> null)
  slow             when present, every git call sleeps first (busy test)
  bin/git          shim implementing ``slow``

Always binds 127.0.0.1. Never touches Params or the device.
"""

import argparse
import os
import stat
import subprocess
from pathlib import Path

from aiohttp import web

from openpilot.kovapilot.config.kova_params import KovaParamsStore
from openpilot.kovapilot.gateway.app import create_app
from openpilot.kovapilot.gateway.git_maintenance import GitRepository

LOOPBACK_HOST = "127.0.0.1"
BASE_EPOCH = 1_795_000_000  # 2026-11-18, fixed so SHAs are reproducible

MASTER_SUBJECTS = [
  "chore: start kovapilot from upstream openpilot",
  "feat(branding): kovapilot boot logo and name",
  "feat(config): kova_params catalog and schema",
  "feat(config): persistent KovaParams runtime state",
  "feat(gateway): add loopback kova params API",
  "test(gateway): kova_params revision conflict",
  "fix(gateway): read IsOffroad from the device",
  "feat(display): onroad screen brightness modes",
  "docs: KovaLink gateway contract",
  "feat(gateway): enforce kova_params ranges and options",
  "fix(ui): 설정 화면 문구를 쉬운 말로 정리",
  "feat(longitudinal): shadow replay logging",
  "test(longitudinal): replay fixtures for shadow mode",
  "fix(car): steering icon state on CCNC",
  "feat(gateway): serve telemetry camera and git maintenance previews",
  "chore(release): bump kovapilot version",
  "fix(gateway): bounded camera signaling retries",
  "feat(ui): driver monitoring session toggle",
  "fix(params): keep KovaParams on manager restart",
  "test(gateway): telemetry stale source omission",
  "docs(gateway): Git maintenance preview contract",
  "fix(updater): log the staged commit",
  "feat(display): auto brightness at night",
  "fix(ui): 주행 화면 속도 표시 깜박임 수정",
  "feat(gateway): updater state in Git status",
]
SHADOW_SUBJECTS = [
  "feat(longitudinal): shadow planner output",
  "test(longitudinal): shadow planner replay",
  "fix(longitudinal): clamp shadow accel request",
]
DISPLAY_SUBJECTS = [
  "feat(display): sync cruise icon with the cluster",
  "test(display): cluster icon sync",
]


class MemoryBackend:
  def __init__(self):
    self.values = {}

  def get(self, key):
    return self.values.get(key)

  def put(self, key, value, block=False):
    self.values[key] = value


def _git(cwd, *args, when=0):
  env = {
    **os.environ,
    "GIT_AUTHOR_NAME": "KovaLink Fixture", "GIT_AUTHOR_EMAIL": "fixture@example.invalid",
    "GIT_COMMITTER_NAME": "KovaLink Fixture", "GIT_COMMITTER_EMAIL": "fixture@example.invalid",
    "GIT_AUTHOR_DATE": f"@{BASE_EPOCH + when} +0900", "GIT_COMMITTER_DATE": f"@{BASE_EPOCH + when} +0900",
    "GIT_CONFIG_NOSYSTEM": "1", "GIT_TERMINAL_PROMPT": "0",
  }
  return subprocess.run(["/usr/bin/git", "-c", "init.defaultBranch=master", "-c", "commit.gpgsign=false", *args],
                        cwd=cwd, env=env, check=True, capture_output=True, text=True).stdout.strip()


def _commit(repo, index, subject, files, when):
  for name in files:
    path = repo / name
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as handle:
      handle.write(f"# {index}: {subject}\n")
  _git(repo, "add", "-A")
  _git(repo, "commit", "-q", "-m", subject, when=when)


def build_repository(root: Path) -> Path:
  device = root / "device"
  if (device / ".git").exists():
    return device
  seed = root / "seed"
  seed.mkdir(parents=True, exist_ok=True)
  _git(seed, "init", "-q")
  hour = 3600
  for i, subject in enumerate(MASTER_SUBJECTS):
    files = [f"openpilot/kovapilot/file_{i % 6}.py"] + ([f"docs/notes_{i}.md"] if i % 4 == 0 else [])
    _commit(seed, i, subject, files, i * 4 * hour)
  _git(seed, "branch", "release/stable", "master~8")
  _git(seed, "checkout", "-q", "-b", "feature/longitudinal-shadow", "master~3")
  for i, subject in enumerate(SHADOW_SUBJECTS):
    _commit(seed, i, subject, [f"openpilot/kovapilot/shadow/part_{i}.py", "openpilot/kovapilot/file_1.py"],
            (len(MASTER_SUBJECTS) * 4 + i + 1) * hour)
  _git(seed, "checkout", "-q", "-b", "feature/ccnc-display-sync", "master")
  for i, subject in enumerate(DISPLAY_SUBJECTS):
    _commit(seed, i, subject, [f"openpilot/kovapilot/display/part_{i}.py"],
            (len(MASTER_SUBJECTS) * 4 + i + 5) * hour)
  _git(seed, "checkout", "-q", "master")
  origin = root / "origin.git"
  _git(root, "init", "-q", "--bare", str(origin))
  _git(seed, "push", "-q", str(origin), "master", "release/stable",
       "feature/longitudinal-shadow", "feature/ccnc-display-sync")
  _git(root, "clone", "-q", str(origin), str(device))
  return device


def install_git_shim(state: Path) -> None:
  shim = state / "bin" / "git"
  shim.parent.mkdir(parents=True, exist_ok=True)
  shim.write_text(f'#!/bin/sh\n[ -f "{state}/slow" ] && sleep 1\nexec /usr/bin/git "$@"\n', encoding="utf-8")
  shim.chmod(shim.stat().st_mode | stat.S_IXUSR)
  os.environ["PATH"] = f"{shim.parent}:{os.environ.get('PATH', '/usr/bin:/bin')}"


def main() -> None:
  parser = argparse.ArgumentParser(description="KovaLink Git e2e gateway (fixture repository)")
  parser.add_argument("--port", type=int, default=18083)
  parser.add_argument("--state", type=Path, required=True)
  args = parser.parse_args()
  if not 1 <= args.port <= 65535:
    parser.error("port must be between 1 and 65535")
  state = args.state.resolve()
  if str(state).startswith("/data"):
    parser.error("state must not be on /data")
  state.mkdir(parents=True, exist_ok=True)
  device = build_repository(state / "git")
  install_git_shim(state)
  updater_file = state / "updater_state"

  def updater_state():
    try:
      return updater_file.read_text(encoding="utf-8").strip() or None
    except FileNotFoundError:
      return None

  app = create_app(KovaParamsStore(MemoryBackend()), lambda: True, git=GitRepository(str(device), updater_state))
  print(f"kovalink git e2e gateway on http://{LOOPBACK_HOST}:{args.port} repo={device}", flush=True)
  web.run_app(app, host=LOOPBACK_HOST, port=args.port, access_log=None, print=None)


if __name__ == "__main__":
  main()
