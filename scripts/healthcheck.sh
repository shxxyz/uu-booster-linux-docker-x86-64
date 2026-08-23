#!/bin/sh
set -eu

[ -c /dev/net/tun ]
[ "$(cat /proc/sys/net/ipv4/ip_forward)" = "1" ]
[ "$(cat /proc/sys/net/ipv4/conf/all/send_redirects)" = "0" ]
ip link show br-lan >/dev/null 2>&1
ip route show default | grep -F "via ${UU_UPSTREAM_GATEWAY}" >/dev/null

[ -s /run/dnsmasq.pid ]
dns_pid="$(cat /run/dnsmasq.pid)"
kill -0 "$dns_pid" 2>/dev/null

[ -s /var/run/uuplugin.pid ]
uu_pid="$(cat /var/run/uuplugin.pid)"
kill -0 "$uu_pid" 2>/dev/null

