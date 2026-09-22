#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/lib.sh
source "$ROOT/scripts/lib.sh"

apply=0
case "${1:-}" in
    '') ;;
    --apply) apply=1 ;;
    -h|--help)
        say "Usage: ./install.sh [--apply]"
        exit 0
        ;;
    *) die "unknown argument: $1" ;;
esac

show_plan() {
    say "UU Docker installation plan"
    say ""
    say "Will create only these Docker objects:"
    say "  container: netease-uu"
    say "  network:   netease-uu-lan (macvlan)"
    say "  image:     netease-uu-openwrt:local"
    say "  volume:    netease-uu-state"
    say "  cache:     $PLUGIN_TAR"
    say ""
    say "Will NOT change the host default route, host sysctls, host nftables/iptables rules,"
    say "Docker daemon configuration, or load kernel modules. The macvlan endpoint may make"
    say "the NIC/switch handle one additional MAC address."
    say ""
    if [ "$apply" -eq 0 ]; then
        say "Dry run only. Review .env, then run: ./install.sh --apply"
    fi
}

show_plan
[ "$apply" -eq 1 ] || exit 0

[ "$(uname -s)" = "Linux" ] || die "apply must run on the target Linux server"
[ "$(uname -m)" = "x86_64" ] || die "the official package is x86_64-only"
[ -f "$ENV_FILE" ] || die "copy .env.example to .env and review every value first"

need_command awk
need_command curl
need_command docker
need_command ip
need_command md5sum
need_command mktemp
need_command sha256sum
need_command sort
need_command stat
need_command tar
need_command tr

docker info >/dev/null 2>&1 || die "rootful Docker Engine is not running or not accessible"
docker compose version >/dev/null 2>&1 || die "Docker Compose v2 is required"
compose_version="$(docker compose version --short | sed 's/^v//')"
[[ "$compose_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]] || die "cannot parse Docker Compose version"
[ "$(printf '%s\n' 2.23.2 "$compose_version" | sort -V | head -n 1)" = "2.23.2" ] \
    || die "Docker Compose 2.23.2 or newer is required (found $compose_version)"
[ -c /dev/net/tun ] || die "/dev/net/tun is missing; load tun on the host, then retry"

parent="$(env_value UU_PARENT_INTERFACE)"
subnet="$(env_value UU_LAN_SUBNET)"
gateway="$(env_value UU_UPSTREAM_GATEWAY)"
container_ip="$(env_value UU_CONTAINER_IP)"
mac="$(env_value UU_MAC_ADDRESS)"
dnsmasq_upstream="$(env_value DNSMASQ_UPSTREAM 2>/dev/null || true)"
snat="$(env_value UU_SNAT_MODE)"
uu_log_level="$(env_value UU_LOG_LEVEL 2>/dev/null || true)"
case "${uu_log_level:-info}" in
    debug|info|warning|fatal) ;;
    *) die "UU_LOG_LEVEL must be debug, info, warning, or fatal" ;;
esac

[[ "$parent" =~ ^[a-zA-Z0-9_.:-]+$ ]] || die "invalid UU_PARENT_INTERFACE"
[ -e "/sys/class/net/$parent" ] || die "interface $parent does not exist"
ip link show "$parent" | grep -q 'UP' || die "interface $parent is not up"
[[ "$subnet" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]] || die "invalid UU_LAN_SUBNET"
[[ "$gateway" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "invalid UU_UPSTREAM_GATEWAY"
[[ "$container_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "invalid UU_CONTAINER_IP"
[[ "$dnsmasq_upstream" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] \
    || die "invalid or missing DNSMASQ_UPSTREAM"
[[ "$mac" =~ ^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$ ]] || die "invalid UU_MAC_ADDRESS"
[[ "$snat" == "off" || "$snat" == "masquerade" ]] || die "UU_SNAT_MODE must be off or masquerade"
[ "$container_ip" != "$gateway" ] || die "container IP must differ from the upstream gateway"

ip route get "$gateway" | grep -Fq "dev ${parent}" \
    || die "upstream gateway $gateway is not reachable through $parent"
ip route get "$container_ip" | grep -Fq "dev ${parent}" \
    || die "container IP $container_ip is not on the LAN reached through $parent"
if ip -4 -o address show | awk '{print $4}' | cut -d/ -f1 | grep -Fxq "$container_ip"; then
    die "container IP $container_ip is already assigned on the host"
fi

if command -v ping >/dev/null 2>&1 \
    && ! docker container inspect netease-uu >/dev/null 2>&1 \
    && ping -c 1 -W 1 "$container_ip" >/dev/null 2>&1; then
    die "$container_ip answered ping; choose an unused/reserved address"
fi

ensure_locked_plugin

say "Building the local image and starting the isolated gateway..."
compose up --detach --build

health=""
for _ in $(seq 1 30); do
    health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' netease-uu 2>/dev/null || true)"
    [ "$health" = "healthy" ] && break
    [ "$health" = "unhealthy" ] && break
    sleep 2
done

if [ "$health" != "healthy" ]; then
    compose logs --tail 120 uu >&2 || true
    die "container did not become healthy (status: ${health:-unknown})"
fi

say ""
say "UU gateway is healthy at $container_ip (MAC $mac)."
say "Next: temporarily set the phone gateway and DNS to $container_ip to bind in the UU app."
say "Then set only the PS5/Switch gateway and DNS to $container_ip."
