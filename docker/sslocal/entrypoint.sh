#!/bin/sh
#
# Shadowsocks client, running in the network namespace of the Yggdrasil node.
# It exposes SOCKS5 to the host and forwards everything to the server's
# Yggdrasil address; its own traffic leaves through the TUN device, so it
# reaches the server over the overlay and never touches the clearnet. Destination
# domains are passed through unchanged, so name resolution happens on the
# server, in the clearnet, together with the rest of the exit traffic.

set -eu

ADDR_FILE="/runtime/address"
WAIT_STEPS=240   # 120s

if [ -z "${SS_PASSWORD:-}" ]; then
    echo "entrypoint: SS_PASSWORD is not set" >&2
    exit 1
fi

server_addr="${YGG_SERVER_ADDR:-}"

# Fail fast and loudly on an unconfigured server address instead of leaving a
# SOCKS5 proxy behind that connects nowhere.
if [ -z "${server_addr}" ]; then
    echo "entrypoint: YGG_SERVER_ADDR is not set. Copy .env.example to .env and put the" >&2
    echo "           server's Yggdrasil address there, see ./scripts/get-server-address.sh" >&2
    exit 1
fi

# This one comes from .env, so it is untrusted input and has to be checked here
# rather than in the node. See the is_ygg_address note in
# docker/ssserver/entrypoint.sh.
is_ygg_address() {
    case "$1" in
        [23]*:*) ;;
        *) return 1 ;;
    esac
    [ -z "$(printf '%s' "$1" | tr -d '0-9a-fA-F:')" ]
}

if ! is_ygg_address "${server_addr}"; then
    echo "entrypoint: '${server_addr}' is not a Yggdrasil node address" >&2
    echo "           Run ./scripts/get-server-address.sh on the server to get the real one" >&2
    exit 1
fi

step=0
while [ ! -s "${ADDR_FILE}" ]; do
    if [ "${step}" -ge "${WAIT_STEPS}" ]; then
        echo "entrypoint: timed out waiting for ${ADDR_FILE}" >&2
        exit 1
    fi
    sleep 0.5
    step=$((step + 1))
done

echo "entrypoint: local Yggdrasil address $(cat "${ADDR_FILE}")"
echo "entrypoint: SOCKS5 on 0.0.0.0:${SS_LOCAL_PORT:-1080}, remote [${server_addr}]:${SS_SERVER_PORT:-8388}"

# 0.0.0.0 is IPv4-only and has to stay that way. This container shares its
# network namespace with the node, so [::] would also bind the node's 200::/7
# address and put an unauthenticated SOCKS5 proxy in reach of the whole overlay.
# The compose file publishing the port on 127.0.0.1 is the actual access
# control; see the SECURITY note there.
drop_privs=''
if [ "$(id -u)" = "0" ]; then
    drop_privs='-a nobody'
fi

# shellcheck disable=SC2086  # empty on purpose: it is a flag, not a value
exec sslocal --log-without-time ${drop_privs} \
    -b "0.0.0.0:${SS_LOCAL_PORT:-1080}" \
    -s "[${server_addr}]:${SS_SERVER_PORT:-8388}" \
    -k "${SS_PASSWORD}" \
    -m "${SS_METHOD:-aes-256-gcm}"
