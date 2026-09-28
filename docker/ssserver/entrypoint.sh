#!/bin/sh
#
# Shadowsocks server, running in the network namespace of the Yggdrasil node.
# It therefore binds to the node's Yggdrasil address, [200:...::]:8388, which
# is only routable inside the overlay, so the port is never reachable from the
# clearnet and the server needs no open port. Outgoing connections leave through
# the container's normal interface, so destinations see the server's public IP.

set -eu

ADDR_FILE="/runtime/address"
WAIT_STEPS=240   # 120s

if [ -z "${SS_PASSWORD:-}" ]; then
    echo "entrypoint: SS_PASSWORD is not set" >&2
    exit 1
fi

# Normally compose has already waited for this: the yggdrasil container is
# healthy only once the TUN device carries the address, and ssserver may not
# bind to [address]:port before that. This is the safety net for the case where
# the file was left over from a previous run.
step=0
while [ ! -s "${ADDR_FILE}" ]; do
    if [ "${step}" -ge "${WAIT_STEPS}" ]; then
        echo "entrypoint: timed out waiting for ${ADDR_FILE}" >&2
        exit 1
    fi
    sleep 0.5
    step=$((step + 1))
done

addr="$(cat "${ADDR_FILE}")"

# A node address is an IPv6 literal in 200::/7 printed uncompressed, so it
# starts with a 2 or a 3 and holds nothing but hex digits and colons. Do not
# look for a "::" in it.
is_ygg_address() {
    case "$1" in
        [23]*:*) ;;
        *) return 1 ;;
    esac
    [ -z "$(printf '%s' "$1" | tr -d '0-9a-fA-F:')" ]
}

if ! is_ygg_address "${addr}"; then
    echo "entrypoint: '${addr}' from ${ADDR_FILE} is not a Yggdrasil node address" >&2
    exit 1
fi

echo "entrypoint: ssserver listening on [${addr}]:${SS_SERVER_PORT:-8388}"

# -a nobody is passed only when the process is actually root; see the note in
# docker-compose.yml, where user: and cap_drop: are kept together for it.
drop_privs=''
if [ "$(id -u)" = "0" ]; then
    drop_privs='-a nobody'
fi

# shellcheck disable=SC2086  # empty on purpose: it is a flag, not a value
exec ssserver --log-without-time ${drop_privs} \
    -s "[${addr}]:${SS_SERVER_PORT:-8388}" \
    -k "${SS_PASSWORD}" \
    -m "${SS_METHOD:-aes-256-gcm}"
