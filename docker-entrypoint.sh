#!/bin/sh
nohup openvpn --config /etc/openvpn-config/openvpn.ovpn --askpass /etc/openvpn-config/pass.txt >>/var/log/custom/ovpn.log &
sleep 8

# Replace SS password placeholder with environment variable
if [ -z "$SS_PASSWORD" ]; then
    echo "ERROR: SS_PASSWORD environment variable is not set" >&2
    exit 1
fi
sed -i "s/__SS_PASSWORD__/$SS_PASSWORD/g" /etc/shadowsocks.json

ssserver -c /etc/shadowsocks.json
