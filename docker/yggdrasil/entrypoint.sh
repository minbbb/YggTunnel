#!/bin/sh
#
# Yggdrasil node entrypoint, shared by both compose files.
#
# 1. generate the node's private key if it has none (the key is the identity);
# 2. render yggdrasil.conf from the template, so .env is the single source of
#    truth and changes take effect on the next start;
# 3. start the node and publish its address/subnet into the runtime volume once
#    the TUN device is actually up, which is what the Shadowsocks container
#    waits for;
# 4. on a node that runs a Shadowsocks server, restrict that port to the node
#    addresses named in YGG_CLIENT_ADDR, unless it says 'any';
# 5. stay in the foreground and forward signals.

set -eu

STATE_DIR="${YGG_STATE_DIR:-/state}"
CONF_TEMPLATE="${YGG_CONF_TEMPLATE:-/etc/yggdrasil/yggdrasil.conf.template}"
CONF="${STATE_DIR}/config.conf"
KEY="${STATE_DIR}/yggdrasil.key"
ADMIN_SOCK="${STATE_DIR}/yggdrasil.sock"
RUNTIME_DIR="${YGG_RUNTIME_DIR:-/runtime}"
ADDR_FILE="${RUNTIME_DIR}/address"
SUBNET_FILE="${RUNTIME_DIR}/subnet"

# The address and the subnet are published into a directory of their own rather
# than into STATE_DIR, because they are the only two things the Shadowsocks
# container needs and it must not be able to read the private key or the
# rendered config (which holds the group password in clear text) out of the
# state volume.
#
# AdminListen is parsed as a URI, so the socket needs exactly three slashes
# after the scheme. It is built here rather than put into the template so that
# the template stays free of assumptions about STATE_DIR.
ADMIN_SOCK_URI="unix://${ADMIN_SOCK}"

# The port filter only exists on a node that runs a Shadowsocks server, and
# YGG_SS_FILTER_PORT is the switch for it. The server compose file sets it to
# the Shadowsocks port; the client compose file does not set it at all, because
# nothing of ours listens on the overlay there.
SS_FILTER_PORT="${YGG_SS_FILTER_PORT:-}"
TUN_WAIT_SECONDS=120

log() {
    printf '%s [entrypoint] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"
}

fail() {
    log "ERROR: $*"
    exit 1
}

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

mkdir -p "${STATE_DIR}" "${RUNTIME_DIR}"

# ---------------------------------------------------------------------------
# 0. Decide and validate who may reach the Shadowsocks port
# ---------------------------------------------------------------------------
# Done before anything is started, so a bad value fails in a second with a
# readable message instead of after the node is already up. The rules themselves
# are installed in step 4, once the TUN device exists. .env.example documents the
# three accepted forms; an empty value is an error, never "unfiltered".
filter_mode='none'
client_addrs=''
if [ -n "${SS_FILTER_PORT}" ]; then
    # Whitespace is stripped from the whole value, so " a , b " and "a,b" mean
    # the same thing. That is what makes the comma separated form usable in a
    # .env file, where aligning the values is natural.
    client_spec="$(printf '%s' "${YGG_CLIENT_ADDR:-}" | tr -d '[:space:]')"

    if [ -z "${client_spec}" ]; then
        fail "YGG_CLIENT_ADDR is empty. Set it to 'any' to accept every node that knows the group password, or to a comma separated list of client node addresses to install the port filter on ${SS_FILTER_PORT}."
    fi

    if [ "$(printf '%s' "${client_spec}" | tr '[:upper:]' '[:lower:]')" = "any" ]; then
        filter_mode='any'
    else
        # Every element is validated before a single rule is installed, so a
        # typo in the third address cannot leave behind a filter that accepts
        # nobody. The glob is disabled because the loop below expands the value
        # unquoted, and .env is not trusted input.
        set -f
        saved_ifs="${IFS}"
        IFS=','
        for addr in ${client_spec}; do
            if ! is_ygg_address "${addr}"; then
                IFS="${saved_ifs}"
                set +f
                fail "'${addr}' from YGG_CLIENT_ADDR='${YGG_CLIENT_ADDR}' is not a Yggdrasil node address"
            fi
            client_addrs="${client_addrs}${client_addrs:+,}${addr}"
        done
        IFS="${saved_ifs}"
        set +f
        filter_mode='list'
    fi
fi

# ---------------------------------------------------------------------------
# 1. Node identity
# ---------------------------------------------------------------------------
# The private key IS the node: its IPv6 address and its routed /64 are derived
# from it. It is generated once and then lives in the state volume, so the
# address of the server stays the same across restarts and redeploys.
if [ ! -s "${KEY}" ]; then
    log "no node key found, generating a new one in ${KEY}"
    ( umask 077
      yggdrasil -genconf | yggdrasil -useconf -exportkey > "${KEY}.tmp"
    )
    mv "${KEY}.tmp" "${KEY}"
    chmod 0600 "${KEY}"
    log "new node key generated"
fi

# ---------------------------------------------------------------------------
# 2. Render the config
# ---------------------------------------------------------------------------
[ -f "${CONF_TEMPLATE}" ] || fail "config template not found: ${CONF_TEMPLATE}"

# YGG_PEERS arrives as a comma separated list from .env and has to become an
# HJSON array. Peering URIs never contain spaces or commas, so both can be
# stripped safely. An empty list renders as an empty array, i.e. the node only
# accepts traffic through the DHT and never peers on its own.
if [ -n "${YGG_PEERS:-}" ]; then
    peers="$(printf '%s' "${YGG_PEERS}" | tr -d '[:space:]' | sed -e 's/[\\"]/\\&/g' -e 's/,/", "/g' -e 's/^/"/' -e 's/$/"/')"
else
    log "warning: YGG_PEERS is empty, the node will not be able to join the network"
    peers=''
fi

# The group password is interpolated into a quoted HJSON string, so a backslash
# doubles and a quote is backslash-quoted.
group_password="$(printf '%s' "${YGG_GROUP_PASSWORD:-}" | sed -e 's/[\\"]/\\&/g')"

# Literal placeholder substitution, one line at a time.
#
# Deliberately not a single sed script: in s|…|…| the replacement text treats &
# and | specially, so a group password containing a literal & used to render as
# the placeholder itself, on *both* nodes -- which still matched each other, so
# the tunnel worked with a public secret and nothing looked wrong. ${var%%pat}
# is a plain string operation with no such special cases, so a value can contain
# any character at all. Each placeholder appears exactly once per line in the
# template, which is why one pass is enough.
sub() {
    case "$1" in
        *"$2"*) printf '%s%s%s\n' "${1%%"$2"*}" "$3" "${1#*"$2"}" ;;
        *) printf '%s\n' "$1" ;;
    esac
}

while IFS= read -r line || [ -n "${line}" ]; do
    line="$(sub "${line}" '__YGG_STATE_DIR__' "${STATE_DIR}")"
    line="$(sub "${line}" '__YGG_ADMIN_SOCK_URI__' "${ADMIN_SOCK_URI}")"
    line="$(sub "${line}" '__YGG_PEERS__' "${peers}")"
    line="$(sub "${line}" '__YGG_GROUP_PASSWORD__' "${group_password}")"
    line="$(sub "${line}" '__YGG_IF_MTU__' "${YGG_IF_MTU:-65535}")"
    printf '%s\n' "${line}"
done < "${CONF_TEMPLATE}" > "${CONF}.tmp"

# 0600 because the rendered config contains the group password; the private key
# itself lives in KEY and is not inlined here.
chmod 0600 "${CONF}.tmp"
mv "${CONF}.tmp" "${CONF}"

# Both values are pure functions of the private key, so they are known before
# the node is even started. The address is what the client needs to reach us.
address="$(yggdrasil -useconffile "${CONF}" -address)"
subnet="$(yggdrasil -useconffile "${CONF}" -subnet)"

# The address/subnet files describe the TUN device, not the config. The key and
# the config survive a restart, the TUN does not, so drop the stale files to
# keep the container healthcheck honest.
rm -f "${ADDR_FILE}" "${SUBNET_FILE}"

log "node address ${address}, routed subnet ${subnet}"

# ---------------------------------------------------------------------------
# 3. Run
# ---------------------------------------------------------------------------
yggdrasil -useconffile "${CONF}" &
yggdrasil_pid=$!

# tini forwards SIGTERM to this script, so pass it on to the node instead of
# leaving it orphaned and letting Docker escalate to SIGKILL.
trap 'log "stopping yggdrasil"; kill -TERM "${yggdrasil_pid}" 2>/dev/null || true' TERM INT

# The Shadowsocks container that shares this network namespace binds to
# [address]:port and therefore may not start before the TUN carries the
# address. Wait for the interface instead of guessing.
waited=0
while ! ip -6 -o addr show 2>/dev/null | grep -qF " ${address}/"; do
    if ! kill -0 "${yggdrasil_pid}" 2>/dev/null; then
        exit_code=0
        wait "${yggdrasil_pid}" || exit_code=$?
        fail "yggdrasil exited during startup with code ${exit_code}"
    fi
    if [ "${waited}" -ge $((TUN_WAIT_SECONDS * 2)) ]; then
        fail "TUN interface did not come up within ${TUN_WAIT_SECONDS}s"
    fi
    sleep 0.5
    waited=$((waited + 1))
done

# ---------------------------------------------------------------------------
# 4. Restrict the Shadowsocks port to the client nodes
# ---------------------------------------------------------------------------
# GroupPassword already stops a node that does not know the password from
# opening a session, but it is a guessable secret, so add the layer that depends
# on guessing nothing: rules that accept the port only from YGG_CLIENT_ADDR.
# Which addresses are allowed was decided and validated in step 0.
if [ -n "${SS_FILTER_PORT}" ]; then
    ss_port="${SS_FILTER_PORT}"

    # `ip -o addr` pads the interface name, so collapse the runs of spaces
    # before splitting the field out. The address is unique on the host, so the
    # first match is the TUN device and not something else.
    tun_if="$(ip -6 -o addr show 2>/dev/null | grep -F " ${address}/" | head -n 1 | tr -s ' ' | cut -d' ' -f2)"

    if [ -z "${tun_if}" ]; then
        fail "could not find the interface carrying ${address}"
    fi

    if [ "${filter_mode}" = "any" ]; then
        log "YGG_CLIENT_ADDR=any: no firewall filter, the Shadowsocks port ${ss_port} is"
        log "  open to every node on the overlay that knows the group password and the"
        log "  Shadowsocks password. That is a deliberate choice; set YGG_CLIENT_ADDR in"
        log "  .env to node addresses to put the ip6tables filter back."
    else
        # Whether the kernel lets us match on the incoming interface is probed
        # once, with the first address, and the answer then applies to every
        # remaining rule. Half the rules matching on the interface and half not
        # would be a confusing thing to debug, so the probe result is remembered.
        use_interface=1

        # $1 is the address to accept. POSIX sh has no `local`, so `use_interface`
        # is deliberately the one piece of state this function communicates.
        accept_from() {
            if [ "${use_interface}" -eq 1 ]; then
                if ip6tables -A INPUT -i "${tun_if}" -p tcp --dport "${ss_port}" \
                        -s "$1" -j ACCEPT 2>/dev/null; then
                    return 0
                fi
                use_interface=0
                log "note: the kernel would not match on interface ${tun_if}, filtering on the address alone"
            fi
            ip6tables -A INPUT -p tcp --dport "${ss_port}" -s "$1" -j ACCEPT
        }

        set -f
        saved_ifs="${IFS}"
        IFS=','
        for addr in ${client_addrs}; do
            accept_from "${addr}" || {
                IFS="${saved_ifs}"
                set +f
                fail "ip6tables refused the accept rule for ${addr} on port ${ss_port}"
            }
        done
        IFS="${saved_ifs}"
        set +f

        # One drop rule covers everything that is not an accepted source. It is
        # deliberately not scoped to the TUN device: nothing else in this
        # namespace listens on this port, and leaving it unscoped means the port
        # stays closed even if ssserver is ever rebound to a wildcard address.
        ip6tables -A INPUT -p tcp --dport "${ss_port}" -j DROP \
            || fail "ip6tables refused the drop rule for port ${ss_port}"

        if [ "${use_interface}" -eq 1 ]; then
            log "Shadowsocks port ${ss_port} restricted to ${client_addrs} on ${tun_if}"
        else
            log "Shadowsocks port ${ss_port} restricted to ${client_addrs}"
        fi
    fi
fi

printf '%s' "${address}" > "${ADDR_FILE}"
printf '%s' "${subnet}" > "${SUBNET_FILE}"
chmod 0644 "${ADDR_FILE}" "${SUBNET_FILE}"
# Published only now, after the filter: the healthcheck is what makes Docker
# start the neighbouring Shadowsocks container, and that container is what opens
# the port. Advertising the address first would leave a window in which the port
# is reachable but unprotected.
log "TUN interface is up, address published to ${ADDR_FILE}"

wait "${yggdrasil_pid}"
