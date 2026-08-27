FROM debian:trixie-20260803-slim

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        ca-certificates \
        dnsmasq-base \
        iproute2 \
        iptables \
        mawk \
        nftables \
        procps \
        tar \
        tini \
    && update-alternatives --set iptables /usr/sbin/iptables-nft \
    && update-alternatives --set ip6tables /usr/sbin/ip6tables-nft \
    && rm -rf /var/lib/apt/lists/*

COPY plugin.lock /tmp/plugin.lock
COPY vendor/uu.tar.gz /tmp/uu.tar.gz

RUN expected="$(sed -n 's/^PLUGIN_SHA256=//p' /tmp/plugin.lock)" \
    && test -n "$expected" \
    && printf '%s  %s\n' "$expected" /tmp/uu.tar.gz | sha256sum -c - \
    && mkdir -p /opt/uu /usr/sbin/uu \
    && tar -xzf /tmp/uu.tar.gz -C /opt/uu \
        uuplugin xuplugin-guardian uu.conf xtables-nft-multi \
    && chmod 0755 /opt/uu/uuplugin /opt/uu/xuplugin-guardian /opt/uu/xtables-nft-multi \
    && chmod 0644 /opt/uu/uu.conf \
    && sha256sum /opt/uu/* > /opt/uu/SHA256SUMS \
    && rm -f /tmp/uu.tar.gz /tmp/plugin.lock

COPY scripts/container-entrypoint.sh /usr/local/sbin/uu-entrypoint
COPY scripts/healthcheck.sh /usr/local/sbin/uu-healthcheck
COPY scripts/render-dns-overrides.sh /usr/local/sbin/render-dns-overrides

RUN chmod 0755 \
        /usr/local/sbin/uu-entrypoint \
        /usr/local/sbin/uu-healthcheck \
        /usr/local/sbin/render-dns-overrides

STOPSIGNAL SIGTERM
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/sbin/uu-entrypoint"]
