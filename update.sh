#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/lib.sh
source "$ROOT/scripts/lib.sh"

apply=0
restart=1
while [ "$#" -gt 0 ]; do
    case "$1" in
        --apply) apply=1 ;;
        --no-restart) restart=0 ;;
        -h|--help)
            say "Usage: ./update.sh [--apply] [--no-restart]"
            exit 0
            ;;
        *) die "unknown argument: $1" ;;
    esac
    shift
done

need_command curl
need_command md5sum
need_command sha256sum
need_command stat
need_command tar

load_lock
query_latest || die "${LATEST_ERROR:-unable to query the official UU plugin API}"
say "Locked plugin: $PLUGIN_VERSION  md5=$PLUGIN_MD5"
say "Official latest: $LATEST_VERSION  md5=$LATEST_MD5"

if [ "$LATEST_VERSION" = "$PLUGIN_VERSION" ]; then
    if [ "$LATEST_MD5" = "$PLUGIN_MD5" ]; then
        say "Already up to date."
        exit 0
    fi
    die "official MD5 changed without a version change; refusing to update the lock automatically"
fi

warn "a different official version is available; the lock remains on $PLUGIN_VERSION unless --apply is given"
if [ "$apply" -eq 0 ]; then
    say "Dry run only. Run ./update.sh --apply to download, pin, rebuild, and restart."
    exit 0
fi

mkdir -p "$VENDOR_DIR"
temporary="$VENDOR_DIR/uu.tar.gz.tmp"
rm -f "$temporary"
curl_https "$temporary" "$LATEST_URL" \
    || die "official signed HTTPS download failed; lock was not changed"
[ "$(md5_file "$temporary")" = "$LATEST_MD5" ] || die "plugin MD5 mismatch"
validate_plugin_archive "$temporary"

new_sha256="$(sha256_file "$temporary")"
new_size="$(size_file "$temporary")"
mv "$temporary" "$PLUGIN_TAR"

lock_tmp="$LOCK_FILE.tmp"
{
    say "# 由 update.sh 管理。固定官方无 key 备用 URL，并同时校验 MD5、SHA-256 与大小。"
    say "PLUGIN_TYPE=openwrt-x86_64"
    say "PLUGIN_VERSION=$LATEST_VERSION"
    say "PLUGIN_URL=$LATEST_BACKUP"
    say "PLUGIN_MD5=$LATEST_MD5"
    say "PLUGIN_SHA256=$new_sha256"
    say "PLUGIN_SIZE=$new_size"
} > "$lock_tmp"
mv "$lock_tmp" "$LOCK_FILE"

say "Pinned $LATEST_VERSION with SHA-256 $new_sha256."
if [ "$restart" -eq 1 ]; then
    exec "$ROOT/install.sh" --apply
fi
say "Run ./install.sh --apply when ready to rebuild and restart."
