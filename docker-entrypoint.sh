#!/bin/sh
nohup openvpn --config /etc/openvpn-config/openvpn.ovpn --askpass /etc/openvpn-config/pass.txt >>/var/log/custom/ovpn.log &
sleep 8
ssserver -c /etc/shadowsocks.json
