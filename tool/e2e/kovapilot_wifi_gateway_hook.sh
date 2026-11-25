#!/usr/bin/env bash
# Hook for test/kovapilot_wifi_e2e_test.dart: runs the real kovapilot
# gateway (`python -m openpilot.kovapilot.gateway`, master-jh b476713a7 or
# later) the way it runs on a comma with Wi-Fi access provisioned.
#
# The kovapilot dev container gets its own Docker bridge network; its
# interface is renamed to wlan0 from the host (nsenter), so the gateway's
# Wi-Fi listener finds a private IPv4 on wlan0 and binds it with TLS, just
# like on the device. The test process on the host is the "phone" on the
# same /24 (the bridge address). Nothing in kovapilot is changed.
#
#   kovapilot_wifi_gateway_hook.sh start          # start; waits for the TLS 401 on the comma IP
#   kovapilot_wifi_gateway_hook.sh ip             # the comma's current IP
#   kovapilot_wifi_gateway_hook.sh phone          # the "phone" (host bridge) IP
#   kovapilot_wifi_gateway_hook.sh move <octet>   # give the comma a new IP on the same /24
#   kovapilot_wifi_gateway_hook.sh stop           # stop the container, remove the network
#
# Environment:
#   KOVAPILOT_DIR          kovapilot checkout with openpilot/common/libparams_c.so built (required)
#   KOVA_E2E_WIFI_SECRETS  directory with server.pem, server.key and token.sha256 (required).
#                          Copied into the isolated state only; never part of this repository.
#   KOVA_E2E_WIFI_SUBNET   first three octets of the test /24 (172.31.250)
#   KOVA_E2E_WIFI_PORT     gateway port (8082, kovapilot's default)
#   KOVA_E2E_WIFI_STATE    isolated state (HOME, Params, /persist) directory
#   KOVA_E2E_IMAGE         container image (kova-openpilot-dev:ubuntu24.04)
#   KOVA_E2E_PYTHON        python inside the container (python3)
#   KOVA_E2E_PYTHONPATH    extra PYTHONPATH entries (aiohttp overlay, msgq)
#   KOVA_E2E_MOUNT         host directory mounted at the same path (dirname of KOVAPILOT_DIR)
#   KOVA_E2E_DOCKER        docker command ("sudo -n docker")
#   KOVA_E2E_SUDO          sudo for nsenter ("sudo -n")
set -euo pipefail

: "${KOVAPILOT_DIR:?set KOVAPILOT_DIR to a kovapilot checkout}"
: "${KOVA_E2E_WIFI_SECRETS:?set KOVA_E2E_WIFI_SECRETS to the gateway credential directory}"
KOVAPILOT_DIR=$(readlink -f "$KOVAPILOT_DIR")
SECRETS=$(readlink -f "$KOVA_E2E_WIFI_SECRETS")
SUBNET=${KOVA_E2E_WIFI_SUBNET:-172.31.250}
PORT=${KOVA_E2E_WIFI_PORT:-8082}
STATE=${KOVA_E2E_WIFI_STATE:-${TMPDIR:-/tmp}/kovalink-wifi-e2e}
IMAGE=${KOVA_E2E_IMAGE:-kova-openpilot-dev:ubuntu24.04}
PY=${KOVA_E2E_PYTHON:-python3}
MOUNT=${KOVA_E2E_MOUNT:-$(dirname "$KOVAPILOT_DIR")}
DOCKER=${KOVA_E2E_DOCKER:-sudo -n docker}
SUDO=${KOVA_E2E_SUDO:-sudo -n}
NAME=kovalink-wifi-e2e-gateway
NET=kovalink-wifi-e2e
PYPATH=$KOVAPILOT_DIR${KOVA_E2E_PYTHONPATH:+:$KOVA_E2E_PYTHONPATH}
FIRST_IP=$SUBNET.20

running() { [ -n "$($DOCKER ps -q --filter "name=^${NAME}$")" ]; }
pid() { $DOCKER inspect -f '{{.State.Pid}}' "$NAME"; }
in_net() { $SUDO nsenter -t "$(pid)" -n "$@"; }
comma_ip() { in_net ip -4 -o addr show dev wlan0 | awk '{print $4}' | cut -d/ -f1 | head -n1; }

# 401 from /v1/health without a token over TLS = the Wi-Fi listener is up.
wait_tls() {
  local ip=$1
  for _ in $(seq 1 120); do
    code=$(curl -sk --noproxy '*' --max-time 1 -o /dev/null -w '%{http_code}' "https://$ip:$PORT/v1/health" || true)
    [ "$code" = 401 ] && return 0
    if ! running; then
      echo "gateway container exited" >&2
      $DOCKER logs "$NAME" 2>&1 | tail -20 >&2 || true
      return 1
    fi
    sleep 0.25
  done
  echo "gateway did not answer over TLS on $ip:$PORT" >&2
  $DOCKER logs "$NAME" 2>&1 | tail -20 >&2 || true
  return 1
}

stop() {
  if running; then $DOCKER stop -t 3 "$NAME" >/dev/null || true; fi
  for _ in $(seq 1 40); do running || break; sleep 0.25; done
  if [ -n "$($DOCKER network ls -q --filter "name=^${NET}$")" ]; then
    $DOCKER network rm "$NET" >/dev/null
  fi
}

case ${1:-} in
  start)
    running && { echo "already running" >&2; exit 1; }
    stop
    rm -rf "$STATE"
    GW=$STATE/.comma/persist/kova/gateway
    mkdir -p "$STATE/params" "$GW"
    # The gateway insists on private files owned by its own user.
    install -m 0644 "$SECRETS/server.pem" "$GW/server.pem"
    install -m 0600 "$SECRETS/server.key" "$GW/server.key"
    install -m 0600 "$SECRETS/token.sha256" "$GW/token.sha256"
    $DOCKER network create --driver bridge --subnet "$SUBNET.0/24" --gateway "$SUBNET.1" \
      --label kova.task=kovalink-wifi-e2e "$NET" >/dev/null
    # PC openpilot: Paths.persist_root() = $HOME/.comma/persist. IsOffroad is
    # CLEAR_ON_MANAGER_START on a device; start parked. The gateway starts
    # once wlan0 exists (renamed below) so its first look finds it.
    $DOCKER run -d --rm --init --network "$NET" --ip "$FIRST_IP" \
      --user "$(id -u):$(id -g)" --name "$NAME" --label kova.task=kovalink-wifi-e2e \
      -e PARAMS_ROOT="$STATE/params" -e PYTHONPATH="$PYPATH" -e HOME="$STATE" \
      -v "$MOUNT:$MOUNT" -v "$STATE:$STATE" -w "$KOVAPILOT_DIR" "$IMAGE" \
      bash -c "$PY -c 'from openpilot.common.params import Params; Params().put_bool(\"IsOffroad\", True)' && while [ ! -e /sys/class/net/wlan0 ]; do sleep 0.2; done; exec $PY -m openpilot.kovapilot.gateway --port $PORT" >/dev/null
    for _ in $(seq 1 40); do [ "$(pid)" != 0 ] && break; sleep 0.25; done
    in_net ip link set eth0 down
    in_net ip link set eth0 name wlan0
    in_net ip link set wlan0 up
    wait_tls "$FIRST_IP"
    comma_ip
    ;;
  ip) comma_ip ;;
  phone) echo "$SUBNET.1" ;;
  move)
    octet=${2:?move <last octet>}
    old=$(comma_ip)
    new=$SUBNET.$octet
    in_net ip addr del "$old/24" dev wlan0
    in_net ip addr add "$new/24" dev wlan0
    wait_tls "$new"
    comma_ip
    ;;
  stop) stop ;;
  *) sed -n '2,30p' "$0"; exit 2 ;;
esac
