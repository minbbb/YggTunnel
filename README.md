# YggTunnel

**English** · [Русский](README.ru.md)

A project for tunnelling traffic through the Yggdrasil mesh network. A local SOCKS5
proxy (sslocal-rust) passes encrypted traffic over Yggdrasil to a remote
ssserver-rust, which provides the exit to the regular internet.

```
           CLIENT                                         SERVER
┌───────────────────────────┐                   ┌────────────────────────┐
│      App on the host      │                   │   The public internet  │
│            │              │                   │            ▲           │
│            ▼              │                   │            │           │
│      sslocal-rust         │                   │            │           │
│   SOCKS5 127.0.0.1:1080   │                   │   ssserver-rust:8388   │
│            │              │                   │            ▲           │
│            ▼              │ Yggdrasil network │            │           │
│      Yggdrasil node    ──────────────────────────>  Yggdrasil node     │
└───────────────────────────┘                   └────────────────────────┘
```

## Quick start

### 1. On the server

```sh
git clone https://github.com/minbbb/YggTunnel
cd YggTunnel
cp .env.example .env

# generate the two secrets and put them into .env
openssl rand -hex 32   # -> SS_PASSWORD
openssl rand -hex 32   # -> YGG_GROUP_PASSWORD
```

Take two or three public peers and put them into `.env` as `YGG_PEERS`.
You can get peers from https://publicpeers.neilalexander.dev/

Run

```
docker compose up -d
```

Find out the server's address in the Yggdrasil network - the client will need it:

```sh
chmod a+x ./scripts/get-server-address.sh
./scripts/get-server-address.sh
# example: 200:1a2b:3c4d:5e6f:7a8b:9abc:def0:1234
```

The address is derived from the node's private key in the `ygg-state` volume, so
it does not change on restarts and only changes if you delete that volume.

### 2. On the client

```sh
git clone https://github.com/minbbb/YggTunnel
cd YggTunnel
cp .env.example .env
```

Fill in `.env`:

- `SS_PASSWORD` and `YGG_GROUP_PASSWORD` - the same values as on the server
- `YGG_SERVER_ADDR` - the address printed by `get-server-address.sh`
- `YGG_PEERS` - two or three live public peers.

```sh
docker compose -f docker-compose.client.yml up -d
```

### 2b. (optional) Restricting which nodes may connect

Get the Yggdrasil address of the **client**

```sh
COMPOSE_FILE=docker-compose.client.yml ./scripts/get-server-address.sh
# example: 201:1a2b:3c4d:5e6f:7a8b:9abc:def0:1234
```

put it into `YGG_CLIENT_ADDR` in the **server's** `.env`, then restart the server:

```sh
docker compose up -d
```

The server will now accept connections only from that address.

You can check that the address was applied with

```
docker compose exec yggdrasil ip6tables -S INPUT | grep 8388
# -A INPUT -s 201:1a2b:3c4d:5e6f:7a8b:9abc:def0:1234/128 -i tun0 -p tcp -m tcp --dport 8388 -j ACCEPT
# -A INPUT -p tcp -m tcp --dport 8388 -j DROP
```

To add several addresses, write them separated by commas. If the client's address
is not known in advance or changes constantly, set `YGG_CLIENT_ADDR=any`.

### 3. Check it

To check, make a request on the client:

```bash
curl -x socks5h://127.0.0.1:1080 https://api.ipify.org
```

It returns the **public IP of the server**.

> Note the `socks5h` (the domain is resolved through the proxy - on the server
> side). With `socks5` (without `h`) the domain is resolved locally by the
> client's system resolver and will not go through the tunnel.

### 4. Connect

To use it, point your browser or another application at SOCKS5 `127.0.0.1:1080`.

## Configuration

Everything is in `.env`, the annotated version is `.env.example`.

| Variable             | Where  | Meaning                                                                                                                  |
| -------------------- | ------ | ------------------------------------------------------------------------------------------------------------------------ |
| `SS_PASSWORD`        | both   | Shadowsocks password. Must match.                                                                                        |
| `SS_METHOD`          | both   | Cipher, `aes-256-gcm` by default. Must match.                                                                            |
| `SS_SERVER_PORT`     | both   | Port on the Yggdrasil address. Must match.                                                                               |
| `SS_LOCAL_PORT`      | client | SOCKS5 port on the host, `1080` by default.                                                                              |
| `YGG_GROUP_PASSWORD` | both   | Closed-overlay password. Must match.                                                                                     |
| `YGG_SERVER_ADDR`    | client | The server's Yggdrasil address.                                                                                          |
| `YGG_CLIENT_ADDR`    | server | Who may reach the Shadowsocks port: addresses separated by commas, or `any` for no filter. Required, may not be empty.  |
| `YGG_PEERS`          | both   | Comma-separated peers. Required, there is no default: without it the node cannot reach the network at all. See below.     |
| `YGG_VERSION`        | both   | Yggdrasil release to build, `0.5.14`.                                                                                    |
| `YGG_IF_MTU`         | both   | TUN MTU, `65535` upstream default.                                                                                       |
| `SS_IMAGE_TAG`       | both   | shadowsocks-rust image tag, `v1.25.0`.                                                                                   |

The entrypoint re-renders the configuration on every start, so after editing
`.env` a `docker compose up -d` is enough - a plain `restart` does it too. Only a
change to `YGG_VERSION`, to the Dockerfile or to `entrypoint.sh`
(`./scripts/build-image.sh`) needs a rebuild.

### Choosing peers

The `YGG_PEERS` setting. Your two nodes do not peer with each other, they find
each other through the DHT, so a node without peers never reaches the network and
the tunnel never comes up.

Take public peer connection strings and insert them separated by commas:

```sh
YGG_PEERS=tls://a.example.org:1338?key=00000000...b9be63ce693e18a,tls://b.example.org:1338?key=000000d8...1e4644ae
```

A long list goes in double quotes and is split across several lines.
The server and client lists may differ.

You should only peer with nodes that are **geographically close**. The latency
and bandwidth of the whole tunnel are determined by the first hop.

Check them with `./scripts/yggctl.sh getPeers` once the node is up: if the tunnel
still does not work, the first thing to look at is whether there are any peers
in state `Up` at all.

A peer that only has an `AAAA` record is unreachable from a container on a host
without IPv6 and gives `connect: network is unreachable` in the node log and in
`getPeers`. This is noise, not a failure: remove it, give the host IPv6 and ignore
it as long as two or three peers are in state `Up`.

## Helper scripts

| Script                            | Purpose                                                                                                                                                                                 |
| --------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `./scripts/get-server-address.sh` | Prints a node's Yggdrasil address. Works while the node is stopped, as long as it has run once. Honours `COMPOSE_FILE`, so on the client it prints the client's address.                 |
| `./scripts/yggctl.sh <command>`   | Runs `yggdrasilctl` against the node: `getSelf`, `getPeers`, `getSessions`, `getPaths`. Defaults to `list`, which prints every available command. Also honours `COMPOSE_FILE`.             |
| `./scripts/build-image.sh`        | Builds the pinned Yggdrasil image. `PLATFORMS=linux/amd64,linux/arm64` for a multi-arch build.                                                                                           |

`getPaths` is useful when the tunnel seems slow: it prints the sequence of hops
between the nodes. On a "DHT only" setup that sequence is long and changes as the
paths are rebuilt in the network - this is normal.
