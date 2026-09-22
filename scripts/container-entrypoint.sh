#!/bin/sh
set -eu

umask 077

log() {
    printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"
}

die() {
    log "ERROR: $*"
    exit 1
}

is_ipv4() {
    printf '%s\n' "$1" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$'
}

uu_log_level="${UU_LOG_LEVEL:-info}"
case "$uu_log_level" in
    debug|info|warning|fatal) ;;
    *) die "UU_LOG_LEVEL must be debug, info, warning, or fatal" ;;
esac

[ "$(id -u)" -eq 0 ] || die "container must run as root with scoped capabilities"
[ "$(uname -m)" = "x86_64" ] || die "UU package is x86_64-only"
[ -c /dev/net/tun ] || die "/dev/net/tun is unavailable; load the host tun module first"

is_ipv4 "${UU_CONTAINER_IP:-}" || die "invalid UU_CONTAINER_IP"
is_ipv4 "${UU_UPSTREAM_GATEWAY:-}" || die "invalid UU_UPSTREAM_GATEWAY"
is_ipv4 "${DNSMASQ_UPSTREAM:-}" || die "invalid DNSMASQ_UPSTREAM"
printf '%s\n' "${UU_LAN_SUBNET:-}" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$' \
    || die "invalid UU_LAN_SUBNET"

if ! ip link show br-lan >/dev/null 2>&1; then
    ip link show eth0 >/dev/null 2>&1 || die "Docker macvlan endpoint eth0 is missing"
    lan_cidr="$(ip -4 -o address show dev eth0 scope global | awk '{print $4; exit}')"
    lan_mac="$(cat /sys/class/net/eth0/address)"
    [ -n "$lan_cidr" ] || die "Docker did not assign an IPv4 address to eth0"

    ip link add br-lan type bridge
    ip link set br-lan address "$lan_mac"
    ip addr flush dev eth0
    ip link set eth0 master br-lan
    ip link set eth0 up
    ip link set br-lan up
    ip address add "$lan_cidr" dev br-lan
    ip route replace default via "$UU_UPSTREAM_GATEWAY" dev br-lan
fi

ip link show br-lan >/dev/null 2>&1 || die "macvlan interface br-lan was not created"
ip -4 -o address show dev br-lan | grep -F " ${UU_CONTAINER_IP}/" >/dev/null \
    || die "br-lan does not own ${UU_CONTAINER_IP}"
ip route show default | grep -F "via ${UU_UPSTREAM_GATEWAY}" >/dev/null \
    || die "default route does not use ${UU_UPSTREAM_GATEWAY}"

[ "$(cat /proc/sys/net/ipv4/ip_forward)" = "1" ] || die "IPv4 forwarding is disabled"
[ "$(cat /proc/sys/net/ipv4/conf/all/send_redirects)" = "0" ] \
    || die "ICMP redirects must be disabled"
[ "$(cat /proc/sys/net/ipv4/conf/default/send_redirects)" = "0" ] \
    || die "default ICMP redirects must be disabled"

# The interface was renamed after Docker applied its per-interface defaults.
if [ -w /proc/sys/net/ipv4/conf/br-lan/send_redirects ]; then
    printf '0\n' > /proc/sys/net/ipv4/conf/br-lan/send_redirects
fi
if [ -w /proc/sys/net/ipv4/conf/br-lan/rp_filter ]; then
    printf '0\n' > /proc/sys/net/ipv4/conf/br-lan/rp_filter
fi

iptables -w -t filter -L -n >/dev/null 2>&1 \
    || die "iptables-nft is unavailable in this network namespace"
nft list ruleset >/dev/null 2>&1 \
    || die "nftables is unavailable in this network namespace"

case "${UU_SNAT_MODE:-off}" in
    off)
        log "extra SNAT disabled (single NAT through the upstream router)"
        ;;
    masquerade)
        iptables -w -t nat -N UU_CONTAINER_BASE 2>/dev/null || true
        iptables -w -t nat -F UU_CONTAINER_BASE
        iptables -w -t nat -C POSTROUTING -j UU_CONTAINER_BASE 2>/dev/null \
            || iptables -w -t nat -A POSTROUTING -j UU_CONTAINER_BASE
        iptables -w -t nat -A UU_CONTAINER_BASE \
            -s "$UU_LAN_SUBNET" ! -d "$UU_LAN_SUBNET" -o br-lan -j MASQUERADE
        log "extra SNAT masquerade enabled; this may change console NAT type"
        ;;
    *)
        die "UU_SNAT_MODE must be off or masquerade"
        ;;
esac

mkdir -p /tmp/uu /usr/sbin/uu
cp /opt/uu/uuplugin /opt/uu/xuplugin-guardian /opt/uu/uu.conf \
    /opt/uu/xtables-nft-multi /tmp/uu/
chmod 0755 /tmp/uu/uuplugin /tmp/uu/xuplugin-guardian /tmp/uu/xtables-nft-multi
chmod 0644 /tmp/uu/uu.conf

# Only change the runtime copy; retain the audited package and version.
[ "$(grep -c '^log_level=' /opt/uu/uu.conf)" = "1" ] \
    || die "expected exactly one log_level in packaged uu.conf"
sed "s/^log_level=.*/log_level=$uu_log_level/" /opt/uu/uu.conf > /tmp/uu/uu.conf
log "UU plugin log_level=$uu_log_level; stdout/stderr are collected by Docker"

dnsmasq \
    --no-daemon \
    --conf-file=/dev/null \
    --no-resolv \
    --server="$DNSMASQ_UPSTREAM" \
    --interface=br-lan \
    --listen-address="$UU_CONTAINER_IP" \
    --bind-dynamic \
    --no-hosts \
    --cache-size=1000 &

dns_pid="$!"
printf '%s\n' "$dns_pid" > /run/dnsmasq.pid

# In no-daemon mode dnsmasq deliberately keeps its current identity. This
# avoids granting SETUID/SETGID to the closed-source UU process merely so a
# sibling DNS forwarder can drop privileges inside the same container.
sleep 1
if ! kill -0 "$dns_pid" 2>/dev/null; then
    set +e
    wait "$dns_pid"
    dns_status=$?
    set -e
    die "dnsmasq failed during startup (status ${dns_status})"
fi

plugin_pid=""
stopping=0

stop_processes() {
    stopping=1
    pid="$plugin_pid"
    if [ -s /var/run/uuplugin.pid ]; then
        pid="$(cat /var/run/uuplugin.pid)"
    fi
    case "$pid" in
        ''|*[!0-9]*) ;;
        *)
            kill -INT "$pid" 2>/dev/null || true
            i=0
            while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 10 ]; do
                sleep 1
                i=$((i + 1))
            done
            kill -TERM "$pid" 2>/dev/null || true
            ;;
    esac
    kill -TERM "$dns_pid" 2>/dev/null || true
}

trap stop_processes INT TERM

crashes=0
while [ "$stopping" -eq 0 ]; do
    rm -f /var/run/uuplugin.pid
    cd /tmp/uu
    log "starting UU plugin $(sed -n 's/^version=//p' uu.conf)"
    run_started="$(date +%s)"
    ./uuplugin ./uu.conf &
    launcher_pid=$!
    plugin_pid="$launcher_pid"

    # Current releases stay in the foreground, but accepting the pid file also
    # keeps the wrapper correct if a later guardian/launcher daemonizes.
    i=0
    while [ "$i" -lt 15 ]; do
        if [ -s /var/run/uuplugin.pid ]; then
            candidate="$(cat /var/run/uuplugin.pid)"
            case "$candidate" in
                ''|*[!0-9]*) ;;
                *)
                    if kill -0 "$candidate" 2>/dev/null; then
                        plugin_pid="$candidate"
                        break
                    fi
                    ;;
            esac
        fi
        kill -0 "$launcher_pid" 2>/dev/null || break
        sleep 1
        i=$((i + 1))
    done

    while kill -0 "$plugin_pid" 2>/dev/null && [ "$stopping" -eq 0 ]; do
        if ! kill -0 "$dns_pid" 2>/dev/null; then
            set +e
            wait "$dns_pid"
            dns_status=$?
            set -e
            die "dnsmasq exited unexpectedly (status ${dns_status})"
        fi
        sleep 2
    done

    set +e
    wait "$launcher_pid"
    status=$?
    set -e
    plugin_pid=""

    [ "$stopping" -eq 0 ] || break

    if [ -e /tmp/uu/uu.uninstall ]; then
        log "UU cloud requested unbind; removing only persisted UU identity"
        rm -f /usr/sbin/uu/.sn /usr/sbin/uu/.uuplugin_uuid /tmp/uu/uu.uninstall
        break
    fi

    if [ -e /tmp/uu/uu.update ]; then
        log "UU requested an update; ignoring it until a reviewed repository bump is installed"
        rm -f /tmp/uu/uu.update
    fi

    run_ended="$(date +%s)"
    run_seconds=$((run_ended - run_started))
    if [ "$run_seconds" -ge 300 ]; then
        crashes=1
    else
        crashes=$((crashes + 1))
    fi
    if [ "$crashes" -ge 6 ]; then
        die "UU plugin exited repeatedly (last status ${status})"
    fi
    log "UU plugin exited with status ${status}; retrying in 5 seconds"
    sleep 5
done

stop_processes
wait "$dns_pid" 2>/dev/null || true
log "UU container stopped"
