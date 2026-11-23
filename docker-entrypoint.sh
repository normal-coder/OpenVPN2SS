#!/bin/sh
set -u

LOG_DIR=/var/log/custom
LOG_FILE="$LOG_DIR/ovpn.log"
STATE_DIR=/run/openvpn2ss
UPSTREAM_DNS_FILE="$STATE_DIR/upstream-dns"

mkdir -p "$LOG_DIR" "$STATE_DIR"
touch "$LOG_FILE"
rm -f "$STATE_DIR/ready" "$STATE_DIR/dnsmasq.pid" "$UPSTREAM_DNS_FILE"

cleanup() {
    echo "Shutting down services..."
    [ -n "${SS_PID:-}" ] && kill "$SS_PID" 2>/dev/null
    [ -n "${DNS_PID:-}" ] && kill "$DNS_PID" 2>/dev/null
    [ -n "${OVPN_PID:-}" ] && kill "$OVPN_PID" 2>/dev/null
    [ -n "${LOG_TAIL_PID:-}" ] && kill "$LOG_TAIL_PID" 2>/dev/null
    exit 0
}
trap cleanup TERM INT

# Helper: format comma-separated fallback DNS into nameserver lines
append_fallback_dns() {
    if [ -n "${DNS_FALLBACK:-}" ]; then
        printf '%s\n' "$DNS_FALLBACK" | tr ',' '\n' \
            | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' \
            | grep -v '^$' | sed 's/^/nameserver /'
    fi
}

# Helper: build initial upstream DNS file from DNS_SERVERS and DNS_FALLBACK
write_initial_upstream_dns() {
    {
        if [ -n "${DNS_SERVERS:-}" ]; then
            printf '%s\n' "$DNS_SERVERS" | tr ',' '\n' \
                | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' \
                | grep -v '^$' | sed 's/^/nameserver /'
        fi
        append_fallback_dns
    } | awk '!seen[$0]++' > "$UPSTREAM_DNS_FILE"
}

# Helper: parse pushed DNS from OpenVPN log line
handle_pushed_dns() {
    line="$1"
    # Only use dynamically pushed DNS if DNS_SERVERS is not explicitly set
    if [ -z "${DNS_SERVERS:-}" ]; then
        {
            printf '%s\n' "$line" | tr ',' '\n' \
                | sed -e 's/^[[:space:]]*//' -e "s/'$//" \
                | sed -n -e 's/^dhcp-option DNS //p' -e 's/^dhcp-option DNS6 //p' \
                | sed 's/^/nameserver /'
            append_fallback_dns
        } | awk '!seen[$0]++' > "$STATE_DIR/upstream-dns.tmp"

        if [ -s "$STATE_DIR/upstream-dns.tmp" ]; then
            mv "$STATE_DIR/upstream-dns.tmp" "$UPSTREAM_DNS_FILE"
            echo "Updated upstream DNS servers from OpenVPN push"
            if [ -f "$STATE_DIR/dnsmasq.pid" ]; then
                DNS_PID_RUNNING="$(cat "$STATE_DIR/dnsmasq.pid" 2>/dev/null || true)"
                if [ -n "$DNS_PID_RUNNING" ]; then
                    kill -HUP "$DNS_PID_RUNNING" 2>/dev/null || true
                fi
            fi
        else
            rm -f "$STATE_DIR/upstream-dns.tmp"
        fi
    fi
}

write_initial_upstream_dns

echo "Starting OpenVPN log monitor..."
tail -F -n 0 "$LOG_FILE" 2>/dev/null | while read -r line; do
    case "$line" in
        *"Initialization Sequence Completed"*)
            touch "$STATE_DIR/ready"
            ;;
    esac
    case "$line" in
        *"PUSH_REPLY"*"dhcp-option DNS"*)
            handle_pushed_dns "$line"
            ;;
    esac
done &
LOG_TAIL_PID=$!

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

# DNS configuration
ENABLE_DNSMASQ="${ENABLE_DNSMASQ:-false}"
DNS_PID=""

if [ "$ENABLE_DNSMASQ" = "true" ]; then
    echo "Starting dnsmasq service..."
    if [ ! -s "$UPSTREAM_DNS_FILE" ]; then
        echo "WARNING: No upstream DNS configured or pushed yet. dnsmasq will rely on /etc/hosts and custom config files."
        touch "$UPSTREAM_DNS_FILE"
    fi

    dnsmasq --keep-in-foreground \
        --conf-file=/dev/null \
        --conf-dir=/etc/dnsmasq.d,*.conf \
        --resolv-file="$UPSTREAM_DNS_FILE" \
        --listen-address=127.0.0.1 --port=53 \
        --log-facility=- &
    DNS_PID=$!
    echo "$DNS_PID" > "$STATE_DIR/dnsmasq.pid"

    DNS_WAIT=0
    while ! nc -z 127.0.0.1 53 2>/dev/null; do
        if [ "$DNS_WAIT" -ge 10 ]; then
            echo "ERROR: dnsmasq failed to start on 127.0.0.1:53" >&2
            exit 1
        fi
        sleep 0.5
        DNS_WAIT=$((DNS_WAIT + 1))
    done
    echo "dnsmasq started successfully on 127.0.0.1:53"

    # Direct container resolver to local dnsmasq
    echo "nameserver 127.0.0.1" > /etc/resolv.conf
fi

# Prepare Shadowsocks configuration
FINAL_CONFIG="$STATE_DIR/shadowsocks.json"
if [ -n "${SS_PASSWORD:-}" ]; then
    awk -v p="$SS_PASSWORD" '{gsub(/__SS_PASSWORD__/, p); print}' /etc/shadowsocks.json > "$FINAL_CONFIG"
else
    cp /etc/shadowsocks.json "$FINAL_CONFIG"
fi

if grep -q '__SS_PASSWORD__' "$FINAL_CONFIG" 2>/dev/null; then
    echo "ERROR: SS_PASSWORD environment variable is not set and /etc/shadowsocks.json contains '__SS_PASSWORD__'" >&2
    exit 1
fi

set -- ssserver -c "$FINAL_CONFIG"

echo "Starting Shadowsocks server..."
"$@" &
SS_PID=$!

# Supervision loop: exit if any critical process dies
while true; do
    if ! kill -0 "$SS_PID" 2>/dev/null; then
        echo "ERROR: ssserver exited" >&2
        exit 1
    fi
    if ! kill -0 "$OVPN_PID" 2>/dev/null; then
        echo "ERROR: openvpn exited" >&2
        kill "$SS_PID" 2>/dev/null
        [ -n "$DNS_PID" ] && kill "$DNS_PID" 2>/dev/null
        exit 1
    fi
    if [ -n "$DNS_PID" ] && ! kill -0 "$DNS_PID" 2>/dev/null; then
        echo "ERROR: dnsmasq exited" >&2
        kill "$SS_PID" 2>/dev/null
        kill "$OVPN_PID" 2>/dev/null
        exit 1
    fi
    sleep 5
done
