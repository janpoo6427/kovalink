#!/usr/bin/env bash
# Hook for test/kovapilot_git_e2e_test.dart: runs kovapilot's real gateway app
# on loopback inside the kovapilot dev container, with its Git maintenance API
# pointed at a throwaway fixture repository (tool/e2e/git_gateway_fixture.py).
#
#   kovapilot_git_gateway_hook.sh start         # build the fixture repo if needed, start, wait for /v1/health
#   kovapilot_git_gateway_hook.sh stop          # stop (repository kept)
#   kovapilot_git_gateway_hook.sh reset         # stop and delete the state directory
#   kovapilot_git_gateway_hook.sh repo          # print the fixture device checkout path
#   kovapilot_git_gateway_hook.sh dirty on|off  # modify a tracked file / restore it
#   kovapilot_git_gateway_hook.sh updater TEXT  # updaterState text ("" -> null)
#   kovapilot_git_gateway_hook.sh hide|show     # move the checkout away (git_unavailable) / back
#   kovapilot_git_gateway_hook.sh slow on|off   # every git call sleeps 1 s (git_busy test)
#
# Environment (same meaning as tool/e2e/kovapilot_gateway_hook.sh):
#   KOVAPILOT_DIR        kovapilot checkout with the gateway (required; read only)
#   KOVA_E2E_GIT_PORT    loopback port (18083)
#   KOVA_E2E_GIT_STATE   state directory (fixture repo, updater text, shim)
#   KOVA_E2E_IMAGE       container image (kova-openpilot-dev:ubuntu24.04)
#   KOVA_E2E_PYTHON      python inside the container (python3)
#   KOVA_E2E_PYTHONPATH  extra PYTHONPATH entries (e.g. an aiohttp overlay)
#   KOVA_E2E_MOUNT       host directory mounted at the same path (dirname of KOVAPILOT_DIR)
#   KOVA_E2E_DOCKER      docker command ("sudo docker")
set -euo pipefail

: "${KOVAPILOT_DIR:?set KOVAPILOT_DIR to a kovapilot checkout}"
KOVAPILOT_DIR=$(readlink -f "$KOVAPILOT_DIR")
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PORT=${KOVA_E2E_GIT_PORT:-18083}
STATE=${KOVA_E2E_GIT_STATE:-${TMPDIR:-/tmp}/kovalink-git-e2e-$PORT}
IMAGE=${KOVA_E2E_IMAGE:-kova-openpilot-dev:ubuntu24.04}
PY=${KOVA_E2E_PYTHON:-python3}
MOUNT=${KOVA_E2E_MOUNT:-$(dirname "$KOVAPILOT_DIR")}
DOCKER=${KOVA_E2E_DOCKER:-sudo docker}
NAME=kovalink-e2e-git-gateway-$PORT
PYPATH=$KOVAPILOT_DIR${KOVA_E2E_PYTHONPATH:+:$KOVA_E2E_PYTHONPATH}
DEVICE=$STATE/git/device

running() { [ -n "$($DOCKER ps -q --filter "name=^${NAME}$")" ]; }

wait_health() {
  for _ in $(seq 1 120); do
    if curl -fsS --max-time 1 "http://127.0.0.1:$PORT/v1/health" >/dev/null 2>&1; then return 0; fi
    if ! running; then
      echo "gateway container exited" >&2
      $DOCKER logs "$NAME" 2>&1 | tail -20 >&2 || true
      return 1
    fi
    sleep 0.25
  done
  echo "gateway did not become healthy" >&2
  return 1
}

stop() {
  if running; then $DOCKER stop -t 3 "$NAME" >/dev/null; fi
  for _ in $(seq 1 40); do
    if ! running && ! curl -fsS --max-time 1 "http://127.0.0.1:$PORT/v1/health" >/dev/null 2>&1; then return 0; fi
    sleep 0.25
  done
  echo "gateway still answering on $PORT" >&2
  return 1
}

case ${1:-} in
  start)
    running && { echo "already running" >&2; exit 1; }
    mkdir -p "$STATE"
    [ -e "$STATE/updater_state" ] || printf 'idle' >"$STATE/updater_state"
    $DOCKER run -d --rm --init --network host \
      --user "$(id -u):$(id -g)" --name "$NAME" --label kova.task=kovalink-git-e2e \
      -e PYTHONPATH="$PYPATH" -e HOME="$STATE" \
      -v "$MOUNT:$MOUNT" -v "$STATE:$STATE" -v "$HERE:$HERE:ro" -w "$KOVAPILOT_DIR" "$IMAGE" \
      "$PY" "$HERE/git_gateway_fixture.py" --port "$PORT" --state "$STATE" >/dev/null
    wait_health
    ;;
  stop) stop ;;
  reset)
    stop
    rm -rf "$STATE"
    ;;
  repo) echo "$DEVICE" ;;
  dirty)
    case ${2:-} in
      on) echo "# local edit" >>"$DEVICE/openpilot/kovapilot/file_0.py" ;;
      off) git -C "$DEVICE" checkout -q -- . ;;
      *) echo "dirty on|off" >&2; exit 2 ;;
    esac
    ;;
  updater) printf '%s' "${2:-}" >"$STATE/updater_state" ;;
  hide) mv "$DEVICE" "$DEVICE.hidden" ;;
  show) mv "$DEVICE.hidden" "$DEVICE" ;;
  slow)
    case ${2:-} in
      on) touch "$STATE/slow" ;;
      off) rm -f "$STATE/slow" ;;
      *) echo "slow on|off" >&2; exit 2 ;;
    esac
    ;;
  *) sed -n '2,24p' "$0"; exit 2 ;;
esac
