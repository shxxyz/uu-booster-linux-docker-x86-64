#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

apply=0
purge=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --apply) apply=1 ;;
        --purge) purge=1 ;;
        -h|--help)
            printf '%s\n' "Usage: ./uninstall.sh [--apply] [--purge]"
            exit 0
            ;;
        *) printf 'ERROR: unknown argument: %s\n' "$1" >&2; exit 1 ;;
    esac
    shift
done

printf '%s\n' "UU Docker uninstall plan"
printf '%s\n' "  remove container: netease-uu"
printf '%s\n' "  remove network:   netease-uu-lan"
printf '%s\n' "  remove image:     netease-uu-openwrt:local"
if [ "$purge" -eq 1 ]; then
    printf '%s\n' "  remove volume:    netease-uu-state (loses UU binding)"
    printf '%s\n' "  remove cache:     $ROOT/vendor/uu.tar.gz"
else
    printf '%s\n' "  keep volume:      netease-uu-state (preserves UU binding)"
fi
printf '%s\n' ""
printf '%s\n' "Docker Engine, daemon settings, host routes/sysctls/firewall, and unrelated build cache are untouched."

if [ "$apply" -eq 0 ]; then
    printf '%s\n' "Dry run only. Add --apply after review."
    exit 0
fi

command -v docker >/dev/null 2>&1 || {
    printf '%s\n' "ERROR: docker is required to remove Docker objects" >&2
    exit 1
}

if docker container inspect netease-uu >/dev/null 2>&1; then
    docker stop --time 20 netease-uu >/dev/null || true
    docker rm netease-uu >/dev/null
fi

if docker network inspect netease-uu-lan >/dev/null 2>&1; then
    docker network rm netease-uu-lan >/dev/null
fi

if docker image inspect netease-uu-openwrt:local >/dev/null 2>&1; then
    docker image rm netease-uu-openwrt:local >/dev/null || true
fi

if [ "$purge" -eq 1 ]; then
    if docker volume inspect netease-uu-state >/dev/null 2>&1; then
        docker volume rm netease-uu-state >/dev/null
    fi
    rm -f "$ROOT/vendor/uu.tar.gz" "$ROOT/vendor/uu.tar.gz.tmp"
fi

printf '%s\n' "Uninstall complete."

