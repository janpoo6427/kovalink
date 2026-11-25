#!/usr/bin/env bash
# Hook for test/kovapilot_gateway_e2e_test.dart: runs a real kovapilot
# gateway on loopback inside the kovapilot dev container.
#
#   kovapilot_gateway_hook.sh start bundled|fixture   # start and wait for /v1/health
#   kovapilot_gateway_hook.sh stop                    # stop (state kept)
#   kovapilot_gateway_hook.sh reset                   # stop and delete the isolated Params
#   kovapilot_gateway_hook.sh offroad true|false      # write IsOffroad in the isolated Params
#   kovapilot_gateway_hook.sh pause|resume            # freeze/unfreeze (timeout test)
#
# Environment:
#   KOVAPILOT_DIR        kovapilot checkout with openpilot/common/libparams_c.so built (required)
#   KOVA_E2E_PORT        loopback port (18082)
#   KOVA_E2E_STATE       isolated state directory; PARAMS_ROOT=$KOVA_E2E_STATE/params
#   KOVA_E2E_IMAGE       container image (kova-openpilot-dev:ubuntu24.04)
#   KOVA_E2E_PYTHON      python inside the container (python3)
#   KOVA_E2E_PYTHONPATH  extra PYTHONPATH entries (e.g. an aiohttp overlay)
#   KOVA_E2E_MOUNT       host directory mounted at the same path (dirname of KOVAPILOT_DIR)
#   KOVA_E2E_DOCKER      docker command ("sudo docker")
#
# The gateway binds 127.0.0.1 only. `--network host` puts the container in the
# host's network namespace so KovaLink's test reaches it at 127.0.0.1.
set -euo pipefail

: "${KOVAPILOT_DIR:?set KOVAPILOT_DIR to a kovapilot checkout}"
KOVAPILOT_DIR=$(readlink -f "$KOVAPILOT_DIR")
PORT=${KOVA_E2E_PORT:-18082}
STATE=${KOVA_E2E_STATE:-${TMPDIR:-/tmp}/kovalink-e2e-$PORT}
IMAGE=${KOVA_E2E_IMAGE:-kova-openpilot-dev:ubuntu24.04}
PY=${KOVA_E2E_PYTHON:-python3}
MOUNT=${KOVA_E2E_MOUNT:-$(dirname "$KOVAPILOT_DIR")}
DOCKER=${KOVA_E2E_DOCKER:-sudo docker}
NAME=kovalink-e2e-gateway-$PORT
PYPATH=$KOVAPILOT_DIR${KOVA_E2E_PYTHONPATH:+:$KOVA_E2E_PYTHONPATH}

running() { [ -n "$($DOCKER ps -q --filter "name=^${NAME}$")" ]; }

wait_health() {
  for _ in $(seq 1 60); do
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
  if running; then
    $DOCKER unpause "$NAME" >/dev/null 2>&1 || true
    $DOCKER stop -t 3 "$NAME" >/dev/null
  fi
  for _ in $(seq 1 40); do
    if ! running && ! curl -fsS --max-time 1 "http://127.0.0.1:$PORT/v1/health" >/dev/null 2>&1; then return 0; fi
    sleep 0.25
  done
  echo "gateway still answering on $PORT" >&2
  return 1
}

case ${1:-} in
  start)
    mode=${2:-bundled}
    running && { echo "already running" >&2; exit 1; }
    mkdir -p "$STATE/params"
    case $mode in
      bundled) entry="-m openpilot.kovapilot.gateway --port $PORT" ;;
      fixture) entry="tools/kovapilot/kovalink_gateway_dev.py --port $PORT --catalog openpilot/kovapilot/tests/fixtures/kova_params_e2e.json" ;;
      *) echo "unknown mode $mode" >&2; exit 2 ;;
    esac
    # IsOffroad is CLEAR_ON_MANAGER_START on a device; start parked.
    $DOCKER run -d --rm --init --network host \
      --user "$(id -u):$(id -g)" --name "$NAME" --label kova.task=kovalink-e2e \
      -e PARAMS_ROOT="$STATE/params" -e PYTHONPATH="$PYPATH" -e HOME="$STATE" \
      -v "$MOUNT:$MOUNT" -v "$STATE:$STATE" -w "$KOVAPILOT_DIR" "$IMAGE" \
      bash -c "$PY -c 'from openpilot.common.params import Params; Params().put_bool(\"IsOffroad\", True)' && exec $PY $entry" >/dev/null
    wait_health
    ;;
  stop) stop ;;
  reset)
    stop
    rm -rf "$STATE/params"
    ;;
  offroad)
    case ${2:-} in true) v=True ;; false) v=False ;; *) echo "offroad true|false" >&2; exit 2 ;; esac
    $DOCKER exec "$NAME" "$PY" -c "from openpilot.common.params import Params; Params().put_bool('IsOffroad', $v)"
    ;;
  pause) $DOCKER pause "$NAME" >/dev/null ;;
  resume) $DOCKER unpause "$NAME" >/dev/null 2>&1 || true ;;
  *) sed -n '2,20p' "$0"; exit 2 ;;
esac
