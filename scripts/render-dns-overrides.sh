#!/bin/sh
set -eu

umask 077

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

is_ipv4() {
    printf '%s\n' "$1" | LC_ALL=C awk -F. '
        NF != 4 { exit 1 }
        {
            for (i = 1; i <= 4; i++) {
                if ($i !~ /^[0-9]+$/ || length($i) > 3 || $i + 0 > 255) {
                    exit 1
                }
                if ($i != "0" && substr($i, 1, 1) == "0") {
                    exit 1
                }
            }
            if ($1 + 0 == 0 || $1 + 0 == 127 || $1 + 0 >= 224) {
                exit 1
            }
        }
    '
}

is_fqdn() {
    [ "${#1}" -le 253 ] || return 1
    printf '%s\n' "$1" | LC_ALL=C awk -F. '
        NF < 2 { exit 1 }
        {
            for (i = 1; i <= NF; i++) {
                if (length($i) < 1 || length($i) > 63) {
                    exit 1
                }
                if ($i !~ /^[a-z0-9]([a-z0-9-]*[a-z0-9])?$/) {
                    exit 1
                }
            }
        }
    '
}

is_ipv4_in_cidr() {
    printf '%s\n' "$1 $2" | LC_ALL=C awk '
        function ipv4_to_number(value, octets, i, number) {
            if (split(value, octets, ".") != 4) {
                return -1
            }
            number = 0
            for (i = 1; i <= 4; i++) {
                if (octets[i] !~ /^[0-9]+$/ || octets[i] + 0 > 255) {
                    return -1
                }
                number = number * 256 + octets[i]
            }
            return number
        }
        {
            if (split($2, cidr, "/") != 2 || cidr[2] !~ /^[0-9]+$/) {
                exit 1
            }
            prefix = cidr[2] + 0
            if (prefix < 0 || prefix > 32) {
                exit 1
            }
            address = ipv4_to_number($1)
            network = ipv4_to_number(cidr[1])
            if (address < 0 || network < 0) {
                exit 1
            }
            block = 2 ^ (32 - prefix)
            base = int(network / block) * block
            if (int(address / block) != int(network / block)) {
                exit 1
            }
            if (prefix <= 30 && (address == base || address == base + block - 1)) {
                exit 1
            }
        }
    '
}

[ "$#" -eq 3 ] \
    || die "usage: render-dns-overrides OUTPUT_FILE LAN_SUBNET CONTAINER_IP"

output_file="$1"
lan_subnet="$2"
container_ip="$3"
overrides="${DNS_HOST_OVERRIDES:-}"
temporary="${output_file}.tmp.$$"

trap 'rm -f "$temporary"' 0 1 2 15
: > "$temporary"

if [ -z "$overrides" ]; then
    mv "$temporary" "$output_file"
    trap - 0 1 2 15
    printf '0\n'
    exit 0
fi

case "$overrides" in
    *[[:space:]]*) die "DNS_HOST_OVERRIDES must not contain whitespace" ;;
    ,*|*,|*,,*) die "DNS_HOST_OVERRIDES contains an empty entry" ;;
esac

remaining="$overrides"
seen='|'
count=0
printf 'local=/netease-uu.invalid/\n' >> "$temporary"
while [ -n "$remaining" ]; do
    case "$remaining" in
        *,*)
            entry="${remaining%%,*}"
            remaining="${remaining#*,}"
            ;;
        *)
            entry="$remaining"
            remaining=''
            ;;
    esac

    case "$entry" in
        *=*) ;;
        *) die "DNS override must use HOSTNAME=IPV4 syntax" ;;
    esac
    hostname="${entry%%=*}"
    address="${entry#*=}"
    case "$address" in
        *=*) die "DNS override contains more than one equals sign" ;;
    esac

    case "$hostname" in
        *.) hostname="${hostname%.}" ;;
    esac
    hostname="$(printf '%s' "$hostname" | tr '[:upper:]' '[:lower:]')"

    is_fqdn "$hostname" || die "invalid DNS override hostname: $hostname"
    case "$hostname" in
        netease-uu.invalid|*.netease-uu.invalid)
            die "DNS override hostname uses the reserved internal suffix: $hostname"
            ;;
    esac
    is_ipv4 "$address" || die "invalid DNS override IPv4 address: $address"
    is_ipv4_in_cidr "$address" "$lan_subnet" \
        || die "DNS override target must be a usable address inside $lan_subnet: $address"
    [ "$address" != "$container_ip" ] \
        || die "DNS override target must not be the UU container itself"

    case "$seen" in
        *"|${hostname}|"*) die "duplicate DNS override hostname: $hostname" ;;
    esac
    seen="${seen}${hostname}|"

    count=$((count + 1))
    [ "$count" -le 32 ] || die "DNS_HOST_OVERRIDES supports at most 32 entries"
    local_name="dns-override-${count}.netease-uu.invalid"
    printf 'host-record=%s,%s\n' "$local_name" "$address" >> "$temporary"
    printf 'cname=%s,%s\n' "$hostname" "$local_name" >> "$temporary"
done

mv "$temporary" "$output_file"
trap - 0 1 2 15
printf '%s\n' "$count"
