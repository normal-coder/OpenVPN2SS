#!/bin/sh
nohup openvpn --config /etc/openvpn-config/openvpn.ovpn --askpass /etc/openvpn-config/pass.txt >>/var/log/custom/ovpn.log &

# Wait for VPN tunnel to be ready (check tun0 device)
TIMEOUT=60
ELAPSED=0
while [ ! -d /sys/class/net/tun0 ]; do
    if [ $ELAPSED -ge $TIMEOUT ]; then
        echo "ERROR: VPN tunnel not established within ${TIMEOUT}s" >&2
        exit 1
    fi
    sleep 1
    ELAPSED=$((ELAPSED + 1))
done
echo "VPN tunnel established (${ELAPSED}s)"

# Replace SS password placeholder with environment variable
if [ -z "$SS_PASSWORD" ]; then
    echo "ERROR: SS_PASSWORD environment variable is not set" >&2
    exit 1
fi
sed -i "s/__SS_PASSWORD__/$SS_PASSWORD/g" /etc/shadowsocks.json

# Start ssserver in background
ssserver -c /etc/shadowsocks.json &
SS_PID=$!

# Monitor: exit if either process dies
while true; do
    if ! kill -0 $SS_PID 2>/dev/null; then
        echo "ERROR: ssserver exited" >&2
        exit 1
    fi
    if ! pgrep openvpn >/dev/null; then
        echo "ERROR: openvpn exited" >&2
        kill $SS_PID 2>/dev/null
        exit 1
    fi
    sleep 5
done
