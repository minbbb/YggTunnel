# syntax=docker/dockerfile:1
#
# Pinned Yggdrasil image, built from the official release package.
#
# There is no maintained Yggdrasil image on Docker Hub: the one published under
# the yggdrasilnetwork/ organisation was last pushed in 2021 and still ships
# v0.4.x, and everything else is a personal build with no provenance. So we take
# the binaries out of the release package of the exact version named in
# YGG_VERSION and put them on a minimal base. The .deb is used only as an archive
# for the binaries, not for its Debian packaging.
#
# curl is installed and purged inside a single RUN, so it never reaches a layer.
# That RUN is split from the runtime packages so that changing YGG_VERSION does
# not re-run the expensive apt install.

ARG DEBIAN_VERSION=bookworm-slim

FROM docker.io/debian:${DEBIAN_VERSION}

ARG TARGETARCH
ARG YGG_VERSION=0.5.14

LABEL org.opencontainers.image.title="yggdrasil" \
      org.opencontainers.image.description="Yggdrasil Network node, pinned to v${YGG_VERSION}, packaged for the YggTunnel compose setup" \
      org.opencontainers.image.source="https://github.com/yggdrasil-network/yggdrasil-go" \
      org.opencontainers.image.version="${YGG_VERSION}" \
      org.opencontainers.image.licenses="MIT"

# cgo is enabled in the upstream binaries, so they need glibc and cannot run on
# Alpine. iproute2 and iptables are what the entrypoint uses to detect the TUN
# device and to restrict the Shadowsocks port; tini forwards signals.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates iproute2 iptables tini; \
    rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    case "${TARGETARCH}" in \
        amd64) pkg="yggdrasil-${YGG_VERSION}-amd64.deb" ;; \
        arm64) pkg="yggdrasil-${YGG_VERSION}-arm64.deb" ;; \
        *) echo "unsupported architecture '${TARGETARCH}' (supported: amd64, arm64)" >&2; exit 1 ;; \
    esac; \
    apt-get update; \
    apt-get install -y --no-install-recommends curl; \
    curl -fsSL -o /tmp/yggdrasil.deb \
        "https://github.com/yggdrasil-network/yggdrasil-go/releases/download/v${YGG_VERSION}/${pkg}"; \
    dpkg-deb -x /tmp/yggdrasil.deb /tmp/pkg; \
    for bin in yggdrasil yggdrasilctl; do \
        found="$(find /tmp/pkg -type f -name "${bin}" | head -n 1)"; \
        if [ -z "${found}" ]; then \
            echo "'${bin}' not found in ${pkg}" >&2; \
            exit 1; \
        fi; \
        cp "${found}" "/usr/bin/${bin}"; \
    done; \
    chmod 0755 /usr/bin/yggdrasil /usr/bin/yggdrasilctl; \
    yggdrasil -version; \
    rm -rf /tmp/pkg /tmp/yggdrasil.deb; \
    apt-get purge -y curl; \
    apt-get autoremove -y; \
    rm -rf /var/lib/apt/lists/*

# The entrypoint and the template it renders share the __YGG_*__ placeholders
# and therefore belong together. Both are baked in so the image is usable on its
# own, and the compose files mount the repository's copy over them so that
# changing the configuration does not require a rebuild.
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY yggdrasil.conf.template /etc/yggdrasil/yggdrasil.conf.template
RUN chmod 0755 /usr/local/bin/entrypoint.sh

# /state holds the node identity, the rendered config and the admin socket, and
# /runtime only the discovered address and subnet. The split is the trust
# boundary: the Shadowsocks container may see the second and not the first.
VOLUME ["/state", "/runtime"]

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
