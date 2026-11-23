#!/bin/sh
set -u

LOG_DIR=/var/log/custom
LOG_FILE="$LOG_DIR/ovpn.log"
STATE_DIR=/run/openvpn2ss

mkdir -p "$LOG_DIR" "$STATE_DIR"
touch "$LOG_FILE"
rm -f "$STATE_DIR/ready"

cleanup() {
    echo "Shutting down services..."
    [ -n "${SS_PID:-}" ] && kill "$SS_PID" 2>/dev/null
    [ -n "${OVPN_PID:-}" ] && kill "$OVPN_PID" 2>/dev/null
    [ -n "${LOG_TAIL_PID:-}" ] && kill "$LOG_TAIL_PID" 2>/dev/null
    exit 0
}
trap cleanup TERM INT

echo "Starting OpenVPN log monitor..."
tail -F -n 0 "$LOG_FILE" 2>/dev/null | while read -r line; do
    case "$line" in
        *"Initialization Sequence Completed"*)
            touch "$STATE_DIR/ready"
            ;;
    esac
done &
LOG_TAIL_PID=$!

# Ensure log tail has started
sleep 1

echo "Starting OpenVPN..."
OVPN_ARGS="--config /etc/openvpn-config/openvpn.ovpn"
if [ -f /etc/openvpn-config/pass.txt ]; then
    OVPN_ARGS="$OVPN_ARGS --askpass /etc/openvpn-config/pass.txt"
fi

openvpn $OVPN_ARGS >>"$LOG_FILE" 2>&1 &
OVPN_PID=$!

TIMEOUT="${VPN_READY_TIMEOUT:-60}"
ELAPSED=0
echo "Waiting for VPN tunnel readiness (timeout: ${TIMEOUT}s)..."
while [ ! -f "$STATE_DIR/ready" ]; do
    if ! kill -0 "$OVPN_PID" 2>/dev/null; then
        echo "ERROR: OpenVPN process exited unexpectedly during startup!" >&2
        echo "=== Recent OpenVPN log ===" >&2
        tail -n 20 "$LOG_FILE" >&2
        exit 1
    fi
    if [ "$ELAPSED" -ge "$TIMEOUT" ]; then
        echo "ERROR: VPN tunnel not established within ${TIMEOUT}s" >&2
        echo "=== Recent OpenVPN log ===" >&2
        tail -n 20 "$LOG_FILE" >&2
        exit 1
    fi
    sleep 1
    ELAPSED=$((ELAPSED + 1))
done
echo "VPN tunnel established and routes ready (${ELAPSED}s)"

# Prepare Shadowsocks server command
set -- ssserver -c /etc/shadowsocks.json

if [ -n "${SS_PASSWORD:-}" ]; then
    set -- "$@" --password "$SS_PASSWORD"
elif grep -q '__SS_PASSWORD__' /etc/shadowsocks.json 2>/dev/null; then
    echo "ERROR: SS_PASSWORD environment variable is not set and /etc/shadowsocks.json contains '__SS_PASSWORD__'" >&2
    exit 1
fi

echo "Starting Shadowsocks server..."
"$@" &
SS_PID=$!

# Supervision loop: exit if either process dies
while true; do
    if ! kill -0 "$SS_PID" 2>/dev/null; then
        echo "ERROR: ssserver exited" >&2
        exit 1
    fi
    if ! kill -0 "$OVPN_PID" 2>/dev/null; then
        echo "ERROR: openvpn exited" >&2
        kill "$SS_PID" 2>/dev/null
        exit 1
    fi
    sleep 5
done
