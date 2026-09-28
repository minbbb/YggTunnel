#!/bin/sh
#
# Prints the Yggdrasil IPv6 address of a node, e.g.
# 200:1a2b:3c4d:5e6f:7a8b:9abc:def0:1234
#
# This is the value the client needs as YGG_SERVER_ADDR, and, on the server, the
# value the client needs as YGG_CLIENT_ADDR. The address is derived from the
# node's private key in the state volume, so it stays the same across restarts
# and only changes if that volume is deleted.
#
#   ./scripts/get-server-address.sh
#   COMPOSE_FILE=docker-compose.client.yml ./scripts/get-server-address.sh

set -eu

# See the Windows section in AGENTS.md: MSYS2 would rewrite /runtime/address
# into a Windows path before Docker ever sees it.
MSYS_NO_PATHCONV=1
export MSYS_NO_PATHCONV

cd "$(dirname "$0")/.."

COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.yml}"
SERVICE="yggdrasil"

if [ ! -f "${COMPOSE_FILE}" ]; then
    echo "get-server-address.sh: ${COMPOSE_FILE} not found; run this from the repository" >&2
    exit 1
fi

# Preferred path: ask the running node. The entrypoint writes the file once the
# TUN device carries the address, and it lives in the runtime volume so that the
# Shadowsocks container can read it without ever seeing the node's private key.
address="$(docker compose -f "${COMPOSE_FILE}" exec -T "${SERVICE}" \
    sh -c 'cat /runtime/address' 2>/dev/null || true)"

# Fallback: the node is not running. The address is derived from the private key
# alone, so it can be computed without starting anything. This only works once
# the node has been started at least once, i.e. once the state volume holds a
# key.
if [ -z "${address}" ]; then
    address="$(docker compose -f "${COMPOSE_FILE}" run --rm --no-deps -T \
        --entrypoint /bin/sh "${SERVICE}" \
        -c 'yggdrasil -useconffile /state/config.conf -address' 2>/dev/null || true)"
fi

if [ -n "${address}" ]; then
    printf '%s\n' "${address}"
    exit 0
fi

cat >&2 <<'EOF'
get-server-address.sh: the server has no node identity yet.

Start the server first:

    cp .env.example .env      # and edit it
    docker compose up -d

Then run this script again. The address is stored in the ygg-state volume and
stays the same until that volume is removed.
EOF
exit 1
