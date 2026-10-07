# iGhostVT relay protocol, version 1

The relay lets a device reach a host that is not on its local network. It
splices TCP and nothing else: the remote-access TLS (TLS 1.2 PSK, see
`Shared/Remote/RemoteTLS.swift`) runs end to end between the app and the
host, and the relay only ever sees its ciphertext.

One TCP port (46405 by default). The first byte of a connection says what
it is:

- `0x16`: a TLS record — an app connecting to a host. Routed by SNI.
- `I` (`IGVR`): the control protocol, spoken by hosts and by apps listing
  hosts.

Anything else is closed.

## Keys

The relay generates one P-256 key pair when it first starts. It keeps the
public key (`/data/relay.json`); the private key goes only into the
configuration file it writes for people to import (`.vtrpsc`). Every device
that imports that file signs with the private key, so the relay checks
membership without ever holding a secret worth stealing.

Each host also has its own P-256 key (the "host key"), made by the host. The
first registration of a host id binds that id to the host key
(`/data/hosts.json`); later registrations must sign with the same key, and
only that key can accept a connection for the host.

Signatures are ECDSA over SHA-256, DER-encoded (CryptoKit's
`P256.Signing.ECDSASignature.derRepresentation`, Go's `ecdsa.VerifyASN1`),
base64 (standard alphabet, padded) in JSON. A host key travels as its
SubjectPublicKeyInfo DER (CryptoKit's `P256.Signing.PublicKey.derRepresentation`,
Go's `x509.ParsePKIXPublicKey`), base64.

The signed message is UTF-8 text, fields joined by `\n`:

```
ighostvt-relay-v1
<role>
<relayID>
<nonce, base64; empty for accept>
<parameter: hostID for host, ticket for accept, empty for list>
```

## The configuration file (`.vtrpsc`)

JSON, UTType `wiki.qaq.ighostvt.relay-config`:

```json
{
  "format": "ighostvt-relay",
  "version": 1,
  "name": "home",
  "endpoint": "relay.example.com:46405",
  "relayID": "6F1C…",
  "key": "<P-256 private key, raw 32-byte scalar, base64>"
}
```

`endpoint` is `host:port`; an IPv6 address is bracketed. `version` is the
file format's, not the protocol's; an app refuses a version it does not know.

## App → host: a data connection

1. The app opens TCP to the relay and starts the TLS handshake it would
   start with the host directly, with SNI set to the host id, lower-case.
2. The relay reads the first TLS record within 5 s: a 5-byte header, then at
   most 16384 bytes. It must be one whole ClientHello with exactly one
   `host_name` in its `server_name` extension; with a trailing dot removed
   and lower-cased that name must be a UUID. A ClientHello spread over more
   than one record is refused.
3. If that host is registered, the relay makes a ticket (16 random bytes,
   base64url, no padding) and sends the host `{"type":"incoming",
   "ticket":…, "from":"<client address>"}`. The ticket dies after 10 s, or as
   soon as the client goes away.
4. The host connects back and accepts the ticket (below). The relay writes
   every byte it has read from the client so far to the host, then splices
   the two connections both ways.
5. No such host, no accept in time, a bad SNI: the relay closes the
   connection. The app sees its TLS handshake fail.

## Control connections

The client writes `IGVR` and one byte, the protocol version (1). The relay
answers at once with its hello frame, before reading anything else:

```json
{"relay":"ighostvt-relay","version":1,"relayID":"…","nonce":"<32 random bytes, base64>"}
```

If the byte the client sent is not the relay's version, the relay follows
the hello with `{"ok":false,"reason":"version"}` and closes. A client that
reads a hello whose `version` is not its own stops too. Versions must be
equal; there is no negotiation.

Every frame after the magic is `[u32 big-endian length][JSON object]`, at
most 64 KiB. A reader reads exactly 4 bytes and then exactly that length —
after an `accept` is granted, the bytes that follow are no longer frames.

A connection that has not sent its request within 5 s is closed.

The client's first frame names its `role`:

### `host`

Sent after reading the hello (it signs the nonce):

```json
{"role":"host","hostID":"…","name":"Office Mac","appVersion":"1.4.0",
 "hostKey":"<SPKI DER, base64>","sig":"<relay key>","hostSig":"<host key>"}
```

`sig` and `hostSig` sign the same message (role `host`, the nonce, the host
id). Answered with `{"ok":true}` or `{"ok":false,"reason":…}`:

| reason | meaning |
|---|---|
| `version` | protocol versions differ |
| `auth` | `sig` does not verify: not a member of this relay |
| `hostKey` | the host id is bound to another host key, or `hostSig` does not verify |
| `full` | the relay holds as many hosts as it allows |
| `invalid` | anything malformed |

After `ok` the connection stays open. The relay sends `incoming` frames.
The host sends `{"type":"ping"}` every 90 s and the relay answers
`{"type":"pong"}`; a relay that hears nothing from a host for 200 s drops
it, a host that hears nothing for 180 s reconnects. Both ends also run TCP
keepalive.

A host id registered again with the same host key replaces the old
connection: the relay sends the old one `{"type":"superseded"}` and closes
it. A host that receives `superseded` does not reconnect by itself —
another machine is running with its identity.

### `accept`

Sent without waiting for the hello (the ticket is fresh on its own; this
saves a round trip). The client still reads the hello before the answer.

```json
{"role":"accept","ticket":"…","hostSig":"<host key, message with empty nonce and the ticket>"}
```

Answered with `{"ok":true}` — every byte after that frame is the client's
TLS stream — or `{"ok":false,"reason":"ticket"}` (unknown, expired, or the
client left) and closed. Only the host the ticket was issued to can sign it.

### `list`

Sent after reading the hello:

```json
{"role":"list","sig":"<relay key>"}
```

Answered with `{"ok":true,"hosts":[{"id":"…","name":"…","appVersion":"1.4.0","since":1760000000}]}`
and closed.

## Liveness

Every connection the relay holds — both legs of a splice and every control
connection — has TCP keepalive (10 s idle, 5 s interval, 3 probes) and a
TCP user timeout of 25 s. When either leg of a splice ends, by EOF, error
or timeout, the relay closes both; nothing is left half-open.

## Limits

64 hosts; 32 pending tickets per host; 512 splices; 64 connections that
have not yet produced an SNI; data connections rate-limited per source
address (60 per 10 s by default, `RELAY_RATE_PER_IP`). A splice reads from one side only after the write to
the other has completed, so a slow reader slows its writer instead of
filling the relay's memory.
