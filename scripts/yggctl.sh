#!/bin/sh
#
# Runs a yggdrasilctl command against the node, e.g. getSelf, getPeers,
# getSessions, getPaths. With no argument it runs "list", which prints every
# verb the running node supports.
#
#   ./scripts/yggctl.sh getSelf
#   COMPOSE_FILE=docker-compose.client.yml ./scripts/yggctl.sh getSessions

set -eu

# See the Windows section in AGENTS.md: MSYS2 would rewrite the container paths
# below into Windows paths before Docker ever sees them.
MSYS_NO_PATHCONV=1
export MSYS_NO_PATHCONV

cd "$(dirname "$0")/.."

COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.yml}"

if [ "$#" -eq 0 ]; then
    set -- list
fi

exec docker compose -f "${COMPOSE_FILE}" exec -T yggdrasil \
    yggdrasilctl -endpoint="unix:///state/yggdrasil.sock" "$@"
