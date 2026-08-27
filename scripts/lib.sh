#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
ENV_FILE="$PROJECT_DIR/.env"
LOCK_FILE="$PROJECT_DIR/plugin.lock"
VENDOR_DIR="$PROJECT_DIR/vendor"
PLUGIN_TAR="$VENDOR_DIR/uu.tar.gz"
COMPOSE_FILE="$PROJECT_DIR/compose.yaml"

say() {
    printf '%s\n' "$*"
}

note() {
    printf 'NOTE: %s\n' "$*"
}

warn() {
    printf 'WARNING: %s\n' "$*" >&2
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

need_command() {
    command -v "$1" >/dev/null 2>&1 || die "missing command: $1"
}

field_from_file() {
    local file="$1" key="$2"
    sed -n "s/^${key}=//p" "$file" | tail -n 1
}

env_value() {
    local key="$1"
    [ -f "$ENV_FILE" ] || return 1
    field_from_file "$ENV_FILE" "$key"
}

plugin_backup_url_version() {
    local url="$1"
    if [[ "$url" =~ ^https?://uurouter\.gdl[0-9]+\.netease\.com/uuplugin/openwrt-x86_64/(v[0-9]+(\.[0-9]+)+)/uu\.tar\.gz$ ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
    elif [[ "$url" =~ ^https?://uurouter-[0-9]+\.gdl\.nieapps\.com/uuplugin/openwrt-x86_64/(v[0-9]+(\.[0-9]+)+)/uu\.tar\.gz$ ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
    else
        return 1
    fi
}

load_lock() {
    [ -f "$LOCK_FILE" ] || die "missing $LOCK_FILE"
    PLUGIN_TYPE="$(field_from_file "$LOCK_FILE" PLUGIN_TYPE)"
    PLUGIN_VERSION="$(field_from_file "$LOCK_FILE" PLUGIN_VERSION)"
    PLUGIN_URL="$(field_from_file "$LOCK_FILE" PLUGIN_URL)"
    PLUGIN_MD5="$(field_from_file "$LOCK_FILE" PLUGIN_MD5)"
    PLUGIN_SHA256="$(field_from_file "$LOCK_FILE" PLUGIN_SHA256)"
    PLUGIN_SIZE="$(field_from_file "$LOCK_FILE" PLUGIN_SIZE)"
    [[ "$PLUGIN_TYPE" == "openwrt-x86_64" ]] || die "unexpected plugin type in lock"
    [[ "$PLUGIN_VERSION" =~ ^v[0-9]+(\.[0-9]+)+$ ]] || die "invalid locked version"
    local url_version
    url_version="$(plugin_backup_url_version "$PLUGIN_URL")" \
        || die "invalid locked plugin URL"
    [ "$url_version" = "$PLUGIN_VERSION" ] || die "locked URL version does not match locked version"
    [[ "$PLUGIN_MD5" =~ ^[0-9a-f]{32}$ ]] || die "invalid locked MD5"
    [[ "$PLUGIN_SHA256" =~ ^[0-9a-f]{64}$ ]] || die "invalid locked SHA-256"
    [[ "$PLUGIN_SIZE" =~ ^[0-9]+$ ]] || die "invalid locked size"
}

proxy_value() {
    env_value DOWNLOAD_PROXY 2>/dev/null || true
}

curl_with_protocol() {
    local protocol="$1" output="$2" url="$3"
    shift 3
    local common=(
        --fail --silent --show-error --location
        --proto "$protocol" --proto-redir "$protocol"
        --connect-timeout 10 --max-time 180
    )
    [ "$protocol" != '=https' ] || common+=(--tlsv1.2)
    common+=("$@" "$url" --output "$output")
    if curl "${common[@]}"; then
        return 0
    fi
    local proxy
    proxy="$(proxy_value)"
    [ -n "$proxy" ] || return 1
    warn "direct download failed; retrying through the configured proxy"
    curl --proxy "$proxy" "${common[@]}"
}

curl_https() {
    curl_with_protocol '=https' "$@"
}

curl_plugin_url() {
    local output="$1" url="$2"
    case "$url" in
        https://*) curl_with_protocol '=https' "$output" "$url" ;;
        http://*) curl_with_protocol '=http' "$output" "$url" ;;
        *) return 1 ;;
    esac
}

query_latest() {
    local metadata
    LATEST_ERROR=""
    LATEST_URL=""
    LATEST_MD5=""
    LATEST_BACKUP=""
    LATEST_VERSION=""
    metadata="$(mktemp "${TMPDIR:-/tmp}/netease-uu-metadata.XXXXXX")"
    if ! curl_https "$metadata" \
        "https://router.uu.163.com/api/plugin?type=openwrt-x86_64" \
        --header 'Accept: text/plain'; then
        rm -f "$metadata"
        LATEST_ERROR="unable to query the official UU plugin API"
        return 1
    fi

    local extra
    IFS=',' read -r LATEST_URL LATEST_MD5 LATEST_BACKUP extra < "$metadata" || true
    rm -f "$metadata"
    if [ -n "${extra:-}" ]; then
        LATEST_ERROR="official API returned unexpected extra fields"
        return 1
    fi
    LATEST_MD5="$(printf '%s' "$LATEST_MD5" | tr '[:upper:]' '[:lower:]')"
    if [[ ! "$LATEST_MD5" =~ ^[0-9a-f]{32}$ ]]; then
        LATEST_ERROR="official API returned an invalid MD5"
        return 1
    fi

    case "$LATEST_URL" in
        http://uurouter.gdl.netease.com/*)
            LATEST_URL="https://${LATEST_URL#http://}"
            ;;
        https://uurouter.gdl.netease.com/*)
            ;;
        *)
            LATEST_ERROR="official API returned an unexpected primary download host"
            return 1
            ;;
    esac

    local primary_without_query backup_version
    primary_without_query="${LATEST_URL%%\?*}"
    if [[ "$primary_without_query" =~ ^https://uurouter\.gdl\.netease\.com/uuplugin/openwrt-x86_64/(v[0-9]+(\.[0-9]+)+)/uu\.tar\.gz$ ]]; then
        LATEST_VERSION="${BASH_REMATCH[1]}"
    else
        LATEST_ERROR="cannot parse plugin version from the official primary URL"
        return 1
    fi

    if [[ "$LATEST_BACKUP" == *\?* || "$LATEST_BACKUP" == *\#* ]]; then
        LATEST_ERROR="official backup URL unexpectedly contains a query or fragment"
        return 1
    fi
    if ! backup_version="$(plugin_backup_url_version "$LATEST_BACKUP")"; then
        LATEST_ERROR="official API returned an unexpected backup download URL"
        return 1
    fi
    if [ "$backup_version" != "$LATEST_VERSION" ]; then
        LATEST_ERROR="official primary and backup URLs disagree on version"
        return 1
    fi
    case "$LATEST_BACKUP" in
        http://uurouter-*.gdl.nieapps.com/*)
            LATEST_BACKUP="https://${LATEST_BACKUP#http://}"
            ;;
    esac
}

md5_file() {
    md5sum "$1" | awk '{print $1}'
}

sha256_file() {
    sha256sum "$1" | awk '{print $1}'
}

size_file() {
    stat -c '%s' "$1" 2>/dev/null || stat -f '%z' "$1"
}

validate_plugin_archive() {
    local archive="$1" listing expected
    listing="$(tar -tzf "$archive" | LC_ALL=C sort)"
    expected="$(printf '%s\n' uu.conf uuplugin xtables-nft-multi xuplugin-guardian | LC_ALL=C sort)"
    [ "$listing" = "$expected" ] || die "plugin archive contains unexpected paths"
}

check_latest_status() {
    LATEST_CHECK_OK=0
    if ! query_latest; then
        warn "${LATEST_ERROR:-unable to check the official latest version}; continuing with locked $PLUGIN_VERSION"
        return 0
    fi
    LATEST_CHECK_OK=1
    if [ "$LATEST_VERSION" != "$PLUGIN_VERSION" ]; then
        note "official latest is $LATEST_VERSION; installing repository-locked $PLUGIN_VERSION"
    elif [ "$LATEST_MD5" != "$PLUGIN_MD5" ]; then
        warn "official MD5 changed for locked $PLUGIN_VERSION; continuing only with the repository-pinned SHA-256"
    fi
}

ensure_locked_plugin() {
    load_lock
    mkdir -p "$VENDOR_DIR"
    local cache_valid=0
    if [ -f "$PLUGIN_TAR" ] \
        && [ "$(sha256_file "$PLUGIN_TAR")" = "$PLUGIN_SHA256" ] \
        && [ "$(size_file "$PLUGIN_TAR")" = "$PLUGIN_SIZE" ]; then
        validate_plugin_archive "$PLUGIN_TAR"
        cache_valid=1
    fi

    check_latest_status
    if [ "$cache_valid" -eq 1 ]; then
        return 0
    fi

    local temporary="$VENDOR_DIR/uu.tar.gz.tmp"
    rm -f "$temporary"
    if ! curl_plugin_url "$temporary" "$PLUGIN_URL"; then
        rm -f "$temporary"
        if [ "$LATEST_CHECK_OK" -eq 1 ] \
            && [ "$LATEST_VERSION" = "$PLUGIN_VERSION" ] \
            && [ "$LATEST_MD5" = "$PLUGIN_MD5" ]; then
            warn "pinned no-key URL failed; retrying the signed official URL for the same locked package"
            curl_https "$temporary" "$LATEST_URL" || die "official plugin download failed"
        else
            die "pinned plugin download failed and no matching official fallback is available"
        fi
    fi
    [ "$(md5_file "$temporary")" = "$PLUGIN_MD5" ] || die "plugin MD5 mismatch"
    [ "$(sha256_file "$temporary")" = "$PLUGIN_SHA256" ] || die "plugin SHA-256 mismatch"
    [ "$(size_file "$temporary")" = "$PLUGIN_SIZE" ] || die "plugin size mismatch"
    validate_plugin_archive "$temporary"
    mv "$temporary" "$PLUGIN_TAR"
}

compose() {
    docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" "$@"
}
