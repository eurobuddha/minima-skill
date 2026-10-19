# keets — Minima over Hyperswarm/HyperDHT (the Keet/Holepunch transport)

**keets** makes Minima dual-transport: alongside classic TCP, nodes connect over
**Hyperswarm + HyperDHT** (the stack Keet is built on). Any node — a phone behind CGNAT
included — is dialable by its **Noise public key** via DHT hole punching, with relay
fallback where punching fails. Phone nodes become first-class peers on the existing
mainnet; classic TCP nodes are unaffected and need no upgrade. Verified live on the
mainnet DHT (October 2026).

On top of the same transport the sidecar provides two app-facing **services** — P2P media
hosting (`keets://` URLs) and E2E-encrypted pubkey messaging with store-and-forward
mailboxes — with **no Java, protocol or consensus changes**. Built for apps where users
should never have to configure (or understand) a server: the phone IS the host.

---

## Architecture: the sidecar bridge

The Java node can't speak Noise, so a **sidecar process** (Node.js on desktop, a bare-kit
worklet hosted by the app on Android) terminates the DHT streams and bridges each one to
the node's own Minima port over loopback:

1. The node starts with `-keets`; once its NIO server listens, it spawns the sidecar with
   `--port --datadir --topic --maxconns [--bootstrap] [--connect]` and env `KEETS_TOKEN`
   (32-byte hex, random per boot — never crosses the DHT, never on argv). On Android the
   app hosts the sidecar as a worklet and passes `--token` (worklet args live in process
   memory, not /proc cmdline, so argv privacy still holds).
2. The sidecar joins the Hyperswarm topic `sha256(topicString)` as both server and client
   (mainnet topic: `minima-mainnet-keets-v1`; testnet: `minima-testnet-keets-v1`), and
   optionally dials each `--connect` pubkey.
3. For EVERY established hyperswarm connection — dialed or accepted — the sidecar opens a
   plain TCP connection to `127.0.0.1:<minima port>`, writes exactly one **MSG_KEETS**
   preamble frame, then pipes bytes both ways. It never parses Minima frames.
4. The node, on receiving MSG_KEETS as a client's first message from 127.0.0.1 with the
   correct token, flags the connection as keets and assigns a synthetic identity
   `127.113.<pk[1]>.<pk[2]>:<9001+pk[3]>` derived from the peer's public key. After that
   it is the untouched Minima protocol: greeting, IBD, txpow gossip. Keets peers are
   **invisible to the classic P2P walk** — hyperswarm does its own discovery,
   reconnection and hole punching.
5. The sidecar exits when its stdin closes (parent died); the node respawns it with
   backoff.

### MSG_KEETS frame (74 bytes, type 24, big-endian, standard 4-byte length prefix)

| bytes | content |
|---|---|
| 4 | frame length = 74 |
| 1 | message type = `24` (MSG_KEETS) |
| 4 + 32 | MiniData: auth token (hex-decoded `KEETS_TOKEN`) |
| 4 + 32 | MiniData: remote peer's Noise public key |
| 1 | initiator flag (`1` if this side dialed) |

Acceptance (all must hold, else disconnect): socket host exactly `127.0.0.1`; token equals
this boot's token; not already flagged keets; no Greeting yet on the connection; pubkey
exactly 32 bytes.

### Identity files (under `<datadir>/keets/`)

- `keypair` — 32-byte seed, mode 0600. **This seed IS the node's network identity — back
  it up like a key.**
- `pubkey` — the derived public key as `0x`-prefixed hex. Give this string to another
  node's `-keetsconnect` to be dialed by key.
- `apitoken` — the per-boot loopback API token (0600).

## Running a keets node

```bash
java -jar minima-keets.jar -data ~/minimadata -keets \
  -keetssidecar /path/to/keets/sidecar/index.js \
  [-keetsbootstrap host1:49737,host2:49737] \
  [-keetsconnect 0x<pubkey>,...] [-keetsmaxconns 6]
```

Needs `node` on PATH (desktop). Your dialable identity is printed at startup and written
to `<datadir>/keets/pubkey`. A default owner-run HyperDHT bootstrap fleet is baked into
`GeneralParams.KEETS_BOOTSTRAP`; `-keetsbootstrap` overrides it, and an explicit empty
value falls back to hyperswarm's default (Holepunch-run) bootstrap — fine for dev.

**v1 scope** — IN: greeting, IBD, full block/txpow gossip (a keets-only node fully syncs
and transacts). OUT (still TCP-only): archive/megammr resync, ping, keets pubkey sharing
via P2P.

---

## Services: media hosting + messages (sidecar 1.2.0)

- **Media** (`keets://` URLs): host files from the device over **Hyperdrive**; any peer
  that fetches re-seeds while running; pinning mirrors permanently. Content is
  hash-addressed — an NFT's on-chain state can store a
  `keets://<drivekey>/<path>?hash=<sha256>` URL, strictly stronger than an HTTP URL
  (every block is verified against the drive's signed merkle tree; `?hash=` pins the
  exact bytes end-to-end).
- **Messages**: one-shot, E2E-encrypted messages addressed to a node's keets pubkey —
  the Maxima alternative. Online peers get them directly; offline peers get them from
  **mailbox nodes** — untrusted commodity store-and-forward of *sealed* blobs
  (`crypto_box_seal` to the recipient's key, signed by the sender): a mailbox can
  neither read, alter, nor forge a message, only delay or drop it (so senders try
  several, and anyone can run one). The recipient proves ownership with a nonce
  signature. Caps: payload 256 KB (use media for big content), 30-day mailbox TTL.

### Loopback HTTP API

`127.0.0.1:<minima port + 5>` (`--apiport` overrides). Every request needs header
`x-keets-token: <token>` (from `<datadir>/keets/apitoken`). CORS is open — the token is
the gate — so a MiniDapp webview or APK can call it directly.

| endpoint | does |
|---|---|
| `GET /info` | `{pubkey, drive, apiport, version}` |
| `POST /media/<path>` (raw bytes) | host a file → `{url, drive, path, hash, size}` |
| `GET /media?url=keets://...` | fetch bytes P2P (then re-seed them) |
| `GET /files` / `DELETE /media/<path>` | list / unpublish own drive |
| `POST /pin {"url":...}` / `GET /pins` / `DELETE /pin/<drivekey>` | permanent mirrors |
| `POST /message {"to":"0x<pubkey>","payload":"..."}` | send → `{delivered:"direct"\|"mailbox"}` |
| `GET /messages` | inbox (id, from, ts, payload b64, via) |
| `DELETE /message/<id>` | ack/remove |

### Node bridge: the `keets` RPC command + `KEETS` MDS event

For apps that talk to the node rather than the sidecar (MiniDapps, web pages, APKs), the
keets-patched node exposes the whole thing as one RPC command — the node holds the API
token, apps never see it, and node RPC already sends open CORS:

```
keets action:info | send (to:, message:|datahex:) | inbox | ack (id:)
      | publish (path:, datahex:) | fetch (url:) | pin (url:) | pins | unpin (drive:)
```

Inbound consumption has two modes:

- **MDS enabled**: the node polls the sidecar inbox every 5 s and pushes each message as
  MDS event **`KEETS`** `{id, from, ts, payload b64, message utf8, via}`, acking after
  the event posts — a dapp's `service.js` should persist them.
- **No MDS**: the node does NOT auto-drain; apps poll `keets action:inbox` and
  `action:ack` what they have stored.

A reference app (**keetchat**) runs one page either as an MDS MiniDapp or as a plain RPC
page (`index.html?rpc=http://127.0.0.1:<rpcport>`).

### Wire protocol (KTS1) — services vs bridge routing

Service connections are HyperDHT Noise streams to a node's main keets pubkey: dialer
sends `'KTS1'` + 1 service byte, acceptor acks `0x4F`, then 4-byte-BE-length JSON frames
(max 1 MB). A Minima initiator's first wire byte is the high byte of a 4-byte frame
length (0x00), never `'K'`, so the acceptor peeks and routes — pre-1.2.0 peers bridge
exactly as before, and dialing a service at one fails cleanly (messaging falls back to a
mailbox). Service dials use an **ephemeral keypair**, so identity is proven in-protocol
with ed25519 signatures over the message content.

### Gotchas

- Media runs a **second Hyperswarm on its own DHT node** (derived keypair
  `sha256(seed + 'keets-media-v1')`) — sharing the main swarm's DHT node stalls
  replication handshakes under bridge churn; one swarm per DHT node is the pattern Keet
  itself ships.
- The sidecar token is per-boot: cache nothing across node restarts; re-read
  `<datadir>/keets/apitoken`.
- `keets://` fetchers re-seed opportunistically only while running; use pins
  (`POST /pin`) for content that must stay available.

---

## Interop & integration lessons (from shipping keets in production apps)

- **Hybrid DHT bootstrap beats an isolated fleet:** run your own bootstrap nodes but have each
  join the global public HyperDHT upstream, and ship clients a default list containing both —
  either side alone can boot the network (verified live: a globally-bootstrapped client dialed a
  fleet-only-bootstrapped phone in ~1 s). Mailbox nodes are dialed by Noise pubkey via the DHT,
  so their IPs are incidental, not identity.
- **Surface the node's keets identity everywhere an operator looks** — status/ping output and at
  bridge startup, always in full: the pubkey is the thing another user adds as a contact.
- **Refuse transportless contact adds:** a contacts command must reject a keets pubkey on a host
  without a keets transport rather than store a contact that can never deliver.
- **A keets send is already durable (direct or mailbox) and has NO DELIVERED protocol** — exclude
  keets peers from classic resend ladders and from group receipt denominators. A classic resend
  ladder applied to keets peers once republished every unread photo under a new drive path every
  60 s for a day.
- **Speak a peer app's dialect exactly and pin it with vectors captured from the live app.** The
  KeetChat decoder requires `body` present and dedups on `id` (omitting either produced raw-JSON
  bubbles on a real device); its read receipts are UP-TO — one receipt referencing the newest
  message marks everything before it. Keep the translation in one tested translator class.
- **Harden the bridge like a boundary:** cap blob fetches (e.g. 8 MB) so an attacker-published
  blob can't heap-load the node; validate a send target as a keets pubkey before any command
  interpolation; ack the inbox drainer only AFTER the consumer has durably stored the message;
  fall back to caption text when a media publish fails.
- **Transport ceilings differ per host:** over Android broadcast IPC, keets media as `datahex`
  hits a ~118 KB ceiling — hand larger content off via `content://` (Android) or a `file:` path
  (same-filesystem desktop node), and cache the pubkey from `keets action:info`.
- **Sandboxed sidecars need AF_NETLINK:** udx-native's network-interface watcher opens a netlink
  socket; a systemd `RestrictAddressFamilies` list without `AF_NETLINK` kills the sidecar at
  boot with EAFNOSUPPORT.
- **Received display names fill unnamed contacts only** — an inbound name must never overwrite a
  user's custom contact name; apply it only when the stored name is empty.

## App integration rules (learned shipping keets clients)

- ★ **Exactly ONE drainer per node inbox.** Store a message durably BEFORE `ack`; companions
  receiving a fan-out event store but never ack; control messages (read receipts, pay-address
  exchange) are forwarded but never stored, and only the NODE answers request-type controls. An
  RPC-mode page must never drain an inbox a host app already drains — they steal messages from
  each other.
- **The node must run with `-keets` or the `keets` command refuses** and a drainer starves
  silently — log inbox-unavailable errors (once per distinct error) or the failure is invisible.
  Prefer `datahex:` over `message:` for sends (avoids all quoting pitfalls).
- **Key disk caches by sha256 of the full `keets://` reference, never a 32-bit hashCode** (silent
  collisions display the wrong media); delete failed/partial fetches instead of caching them.
- **Adopt the incumbent wire schema for chat interop:** reuse the `maxima_chat_v1` field names
  (application/id/body/name/ref/ts, plus typed control fields) hex-encoded into `datahex`, so
  one payload convention parses in every client; keep accepting the previous plain format on
  receive.
- **Bare/worklet packaging on Android:** pack nested node_modules prebuilds RECURSIVELY (npm
  nests duplicate native addon versions — a top-level-only walk missed one `.so` and the runtime
  SIGABRT'd the app in a restart loop); a worklet's fd 0 is /dev/null, so stdin-EOF exit hooks
  kill it ~100 ms after start; map the `http` builtin to bare-http1 in the pack-time imports map.
  Pin the whole toolchain (source commit, archive hashes, runtime versions) in a lock file and
  verify the exact bundle + every nested addon + the runtime inside each built APK.
- **A Maxima contact address (`Mx…@host:port`) changes when a node moves relay** — pair by
  introducing the two nodes to each other; never persist the printed address as identity.
