# iGhostVT Relay

The relay lets iGhostVT reach a device that is not on the same network:
a phone on cellular opening a terminal on the Mac at home, for example. Run
it on any server both devices can reach, import its configuration into
iGhostVT, and turn on Remote Access. Devices still pair with each other
exactly as on a local network; the relay only decides who may route through
it.

The relay splices TCP and nothing else. The remote-access TLS runs end to end
between the app and the host, so the relay sees ciphertext only. It holds no
secret worth stealing: it keeps the public half of its key, and the private
half exists only in the configuration file you hand to your devices. The wire
protocol is in [PROTOCOL.md](PROTOCOL.md).

## Deploy

You need Docker with Compose and one open TCP port (46405 by default).

```sh
curl -LO https://github.com/owngoal-dev/iGhostVT/releases/latest/download/compose.yml
docker compose up -d
docker compose logs relay
```

The first start makes the relay's key and writes the configuration. The log
says where the relay is reachable and how to get the configuration:

```
ighostvt-relay 1.4.0 (relay protocol 1): relay "iGhostVT Relay" ready at 203.0.113.7:46405 (detected via Cloudflare)
ighostvt-relay: save the config with:
    docker compose exec relay ighostvt-relay config > relay.vtrpsc
```

Run that command, copy `relay.vtrpsc` to your devices, and open it with
iGhostVT (or import it from Settings ▸ Remote Access ▸ Relay). Every device
that should host terminals or connect to them needs it.

The file contains the relay's private key: anyone holding it can register
hosts and list them on your relay. Treat it like a password. The private key is
never written to the log.

## Settings

Put these in a `.env` file beside `compose.yml` (see
[.env.example](.env.example)). All of them are optional.

| Variable | Meaning | Default |
|---|---|---|
| `RELAY_PUBLIC_HOST` | The domain or IP clients connect to, without a port. | Detected (see below) |
| `RELAY_PUBLIC_PORT` | The port clients connect to. Compose publishes the relay on it, so changing the port takes this one line. | `46405` |
| `RELAY_NAME` | The name iGhostVT shows for the relay. | `iGhostVT Relay` |
| `RELAY_RATE_PER_IP` | Data connections one address may open in any 10 s; `0` turns the limit off. | `60` |

Two more variables exist for running the binary outside the image:
`RELAY_LISTEN` (the listen address, default `:46405`) and `RELAY_DATA` (the
data directory, default `/data`).

### Finding the public address

With `RELAY_PUBLIC_HOST` empty, the relay asks two services for the address
its own traffic leaves from, every time it starts:

- Cloudflare: `https://1.1.1.1/cdn-cgi/trace`
- Google: the TXT record `o-o.myaddr.l.google.com`, asked directly of
  `ns1.google.com`

Each gets five seconds. An IPv4 answer is preferred over IPv6. When both
answer and disagree, Cloudflare's address is used and the log says so. When
neither answers, no configuration is written: the log asks you to set
`RELAY_PUBLIC_HOST`, the relay keeps running, and it keeps asking in the
background.

**Privacy:** this is the only time the relay contacts anything on its own,
and it happens only while `RELAY_PUBLIC_HOST` is empty. Set it, and neither
Cloudflare nor Google is ever contacted.

Detection finds the *outgoing* address. That is right for a typical cloud
server with one public IP; on a machine whose incoming and outgoing
addresses differ (several interfaces, policy routing, a separate load
balancer), set `RELAY_PUBLIC_HOST` yourself.

### When the address changes

Every start resolves the address again. If it differs from the one in the
configuration, the relay rewrites the configuration with the **same key** and
warns in the log. Import the new file on every device; nothing else changes.

On a connection whose IP changes (most home broadband), use a dynamic DNS
name instead and put it in `RELAY_PUBLIC_HOST`. iGhostVT resolves the name on
every connection, so an address change then needs no new configuration at
all.

## Commands

All of them run inside the container:

```sh
docker compose exec relay ighostvt-relay <command>
```

| Command | What it does |
|---|---|
| `config` | Prints the configuration (`.vtrpsc`). |
| `status` | Lists the hosts online, with their iGhostVT versions, and the connections in use. |
| `rotate` | Makes a new key and configuration and drops every registered host. The old configuration stops working at once; import the new one on every device. Use it when a configuration has leaked, or when you deleted it. |
| `forget <hostID>` | Unbinds a host id from its host key (below), for a host that was reinstalled or lost its key. A host online under that id is dropped. |
| `version` | Prints the relay's version and protocol version. |

### Host keys

Each host also has a key of its own, made on the device. The first time a
host id registers, the relay binds the id to that key, and later
registrations must use the same key: another member of the relay cannot take
over your Mac's identity. If the same host registers twice (a cloned VM, a
restored backup), the newer connection wins and the older one is told so and
stops. `forget` clears a binding.

## Data

Everything lives in the `relay-data` volume, mounted at `/data`:

| File | Contents |
|---|---|
| `relay.json` | The relay's id, name and public key. |
| `ighostvt.vtrpsc` | The configuration, private key included (mode 0600). You may delete it once every device has imported it; `config` then has nothing to print, and only `rotate` makes a new one. |
| `hosts.json` | Host id → host key bindings. |
| `admin.sock` | How the commands above reach the running relay. |

Use a named volume, as `compose.yml` does. The relay runs as an unprivileged
user (65532), and a bind-mounted directory created by root is not writable
by it; a new named volume takes the image's ownership.

## Networking notes

**IPv6 clients and Docker's userland proxy.** With the default port
publishing, Docker may forward IPv6 connections through its userland proxy,
which replaces the client's address with the bridge gateway's. The relay
then sees every such client as one address, and its per-address rate limit
(20 new connections per 10 seconds) applies to all of them together. Either
accept that, or run the relay with `network_mode: host` (drop the `ports:`
line) so it sees real addresses.

**Firewalls.** Only the one TCP port has to be open inbound. The relay needs
outbound HTTPS and DNS only for address detection.

**Limits.** 64 hosts, 16 connections waiting per host, 512 connections being
relayed, 64 connections that have not identified themselves yet. Connections
that say nothing for 5 seconds are closed, and a host that is silent for 200
seconds is dropped. Every connection has TCP keepalive; on Linux a connection
whose peer stops acknowledging data is closed after 25 seconds.

## Versions

The image tag `1` is relay protocol version 1. It follows the protocol, not
iGhostVT: an app update does not need a new relay unless the protocol
changes, and then the release notes say so and the tag becomes `2`. Each
iGhostVT release also tags the image with its own version (`1.4.0`) and
`latest`; all of them point at the image CI built and tested for that commit.

## Building

```sh
docker build -t ighostvt-relay Relay
# or, without Docker (Go 1.25 or newer, standard library only):
cd Relay && go test ./... && go build ./cmd/ighostvt-relay
```
