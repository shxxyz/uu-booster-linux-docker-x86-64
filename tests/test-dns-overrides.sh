#!/bin/sh
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
RENDERER="$ROOT/scripts/render-dns-overrides.sh"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/netease-uu-dns-test.XXXXXX")"

trap 'rm -rf "$TEST_DIR"' 0 1 2 15

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_render() {
    overrides="$1"
    expected_count="$2"
    expected_config="$3"
    output="$TEST_DIR/dnsmasq.conf"
    count="$(DNS_HOST_OVERRIDES="$overrides" \
        "$RENDERER" "$output" 10.0.0.0/24 10.0.0.2)"
    [ "$count" = "$expected_count" ] || fail "unexpected override count"
    actual="$(cat "$output")"
    [ "$actual" = "$expected_config" ] || fail "unexpected rendered config"
}

assert_rejected() {
    overrides="$1"
    output="$TEST_DIR/rejected.conf"
    printf 'unchanged\n' > "$output"
    if DNS_HOST_OVERRIDES="$overrides" \
        "$RENDERER" "$output" 10.0.0.0/24 10.0.0.2 >/dev/null 2>&1; then
        fail "invalid override was accepted: $overrides"
    fi
    [ "$(cat "$output")" = 'unchanged' ] \
        || fail "failed rendering replaced the previous config"
}

assert_render '' 0 ''
assert_render \
    'INGEST.GLOBAL-CONTRIBUTE.LIVE-VIDEO.NET.=10.0.0.80' \
    1 \
    'local=/netease-uu.invalid/
host-record=dns-override-1.netease-uu.invalid,10.0.0.80
cname=ingest.global-contribute.live-video.net,dns-override-1.netease-uu.invalid'
assert_render \
    'one.example.com=10.0.0.80,two.example.com=10.0.0.81' \
    2 \
    'local=/netease-uu.invalid/
host-record=dns-override-1.netease-uu.invalid,10.0.0.80
cname=one.example.com,dns-override-1.netease-uu.invalid
host-record=dns-override-2.netease-uu.invalid,10.0.0.81
cname=two.example.com,dns-override-2.netease-uu.invalid'

assert_rejected '*.example.com=10.0.0.80'
assert_rejected 'single-label=10.0.0.80'
assert_rejected 'bad-.example.com=10.0.0.80'
assert_rejected 'dns-override-1.netease-uu.invalid=10.0.0.80'
assert_rejected 'example.com=010.0.0.80'
assert_rejected 'example.com=10.0.0.999'
assert_rejected 'example.com=10.0.1.80'
assert_rejected 'example.com=10.0.0.0'
assert_rejected 'example.com=10.0.0.255'
assert_rejected 'example.com=10.0.0.2'
assert_rejected 'example.com=10.0.0.80,example.com=10.0.0.81'
assert_rejected 'example.com=10.0.0.80,'
assert_rejected 'example.com =10.0.0.80'
assert_rejected 'example.com=10.0.0.80=extra'
assert_rejected '--server=/example.com/=10.0.0.80'

many_overrides=''
i=1
while [ "$i" -le 33 ]; do
    separator=','
    [ -n "$many_overrides" ] || separator=''
    many_overrides="${many_overrides}${separator}host${i}.example.com=10.0.0.80"
    i=$((i + 1))
done
assert_rejected "$many_overrides"

printf 'DNS override renderer tests passed.\n'
