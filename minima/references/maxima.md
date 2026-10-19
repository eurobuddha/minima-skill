# Maxima — Off-Chain Encrypted Messaging

> **Newer alternative:** the **keets** services layer offers E2E-encrypted pubkey messaging with store-and-forward mailboxes and P2P media hosting over Hyperswarm/DHT, with no Maxima hosts to configure — see `references/keets.md`. Maxima remains the messaging layer built into every stock node.


Maxima is Minima's information transport layer: every Minima node also runs Maxima, letting nodes exchange end-to-end encrypted data (text, JSON, files, transaction data) peer-to-peer over the same network — without touching the blockchain. It powers MiniDapp-to-MiniDapp communication: chat apps (MaxSolo, Chatter), DEX order relays, payment-channel negotiation, multiplayer games.

Full parameter dumps for `maxima`, `maxcontacts`, `maxextra`, `maxsign`, `maxverify`, and `maxcreate` live in `references/commands-node-network.md` — this file is the tutorial.

## Maxima gotchas

- **Delivery is NOT guaranteed.** Always check `response.delivered` on send, and design for messages that never arrive (timeouts), arrive twice (idempotency guards), or arrive out of order (check state before processing).
- **Large messages can corrupt in transit.** Transaction data relayed via Maxima between remote nodes can arrive truncated — `txnimport` then fails with `java.io.EOFException`. There is no fix except keeping payloads small and validating defensively on receipt.
- **For anything stateful, use a handshake.** A SYNACK/ACK exchange before proceeding, plus a phase/sequence guard against duplicates, is the difference between a demo and a production MiniDapp.
- **Contact addresses expire.** Share and add them immediately; for long-lived, publishable addresses you need a static MLS + permanent `MAX#` address.
- **Contacts cost work.** Each contact connection is maintained with small Tx-PoW; ~10–20 contacts is the practical per-node limit before performance suffers.

## Why Maxima exists

Where Minima is freedom of *value* exchange, Maxima is freedom of *information* exchange. Messages are:

- **End-to-end encrypted** with asymmetric RSA — relaying nodes cannot read them.
- **Signed** with the sender's Maxima private key, so the recipient can authenticate the origin.
- **Paid in work, not coins.** Every send requires a small Transaction Proof-of-Work (~1 second of hashing). This is the spam defense, and it also feeds hash power into securing the Minima chain. You need zero Minima coins to use Maxima.
- **Off-chain.** The message itself never appears on the blockchain; only the TxPoW unit (if it happens to be a block) propagates on-chain.

The send path: your node signs and encrypts the payload, mines a TxPoW unit, and sends both to the *recipient's* Maxima host — a randomly selected server node the recipient is connected through. The host verifies the work was done, then forwards the encrypted message to the recipient. Invalid or under-worked messages are discarded.

## Identity

Run `maxima` (or `maxima action:info`) to see who you are:

```bash
maxima
```

Key fields in the response:

- **`publickey`** — your Maxima public key (a long `0x3081...` RSA key). This is your stable Maxima identity; it never changes. Messages are addressed to it and signed by its private half.
- **`contact`** — your current **contact address**: a long `Mx...` string ending in `@ip:port` (the host you're currently routed through). **This changes at random intervals** for privacy — anyone holding an old one loses the ability to reach you.
- **`mls` / `staticmls`** — your current Maxima Location Service host and whether it's pinned.
- **`p2pidentity`** — relevant only for server nodes acting as hosts/MLS.
- **`name`** — your display name, set with `maxima action:setname name:alice`.

So: the *public key* is who you are, the *contact address* is where you currently live, and the *MLS* is the directory service that keeps the two linked for your contacts.

### Permanent MAX# addresses

Because contact addresses rotate, you can't print one on a website. If you run a second, always-on server node, you can build a permanent address of the form:

```
MAX#<yourMaximaPublicKey>#<staticMLShost>
```

Setup: pin your primary node to the server as static MLS (`maxextra action:staticmls host:<server p2pidentity>`), then on the *server* run `maxextra action:addpermanent publickey:0x3081...`. Anyone can now message you at the MAX# address forever — the static MLS answers `getaddress` requests with your latest rotating contact address. See "Advanced options" below.

## Contacts

Contacts are mutual: only one side needs to add the other's address, and both immediately see each other. Deleting a contact removes you from *their* list too, and since your contact address keeps rotating, they cannot silently re-add you later — this is the privacy model.

```bash
# Share your own address: copy the "contact" field from
maxima

# Add a friend (paste their FULL address including the @ip:port part,
# and do it immediately — addresses expire)
maxcontacts action:add contact:MxG18H....@<host>:9001

# List contacts — note each one's id, publickey, lastseen, samechain
maxcontacts

# Remove
maxcontacts action:remove id:1
```

In the `maxcontacts` listing, check **`samechain: true`** for each contact — `false` means you're on different forks and should re-add them. If a connection stays broken for more than 24 hours, delete and re-add with a fresh address.

## The MLS (Maxima Location Service)

Your MLS host is a randomly selected server node that tells your contacts your latest contact address whenever it rotates. As long as your node comes online at least once every 24 hours, the MLS keeps you and your contacts connected through address changes.

For privacy, your node moves to a *new* random MLS every 12 hours (staying registered with the previous one for a 12-hour overlap, so briefly-offline contacts can still find you). Net effect: a removed contact loses the ability to re-add you after at most 12 hours.

A **static MLS** replaces the random host with your own always-on server node — more stable connections, and the prerequisite for permanent MAX# addresses.

## Sending application messages

The workhorse is `maxima action:send`. Three ways to address the recipient, plus the two fields every MiniDapp cares about:

```bash
# by contact id (from maxcontacts)
maxima action:send id:1 application:myapp data:{"type":"HELLO","v":1}

# by contact address
maxima action:send to:MxG18H.... application:myapp data:0xFED5..

# by Maxima public key (with retry polling)
maxima action:send publickey:0x3081.. application:myapp data:0xFED5.. poll:true

# to a permanent MAX# address (recipient need not be a contact)
maxima action:send to:MAX#0x3081..#Mx...@<host>:9001 application:myapp data:{"hi":true}

# broadcast to every contact (optionally spaced out)
maxima action:sendall application:myapp data:{"type":"PING"} delay:500
```

- **`application`** is a free-form namespace string. Every listening MiniDapp on the recipient node receives the MAXIMA event; they filter on this field. Pick something unique to your dapp (e.g. `"dicegame_v1"`) and ignore everything else.
- **`data`** can be `0x` HEX or a JSON object. Either way it arrives at the far end as HEX — you decode it back.
- **`poll:true`** keeps retrying the send until it succeeds — useful for important messages to a contact who may be briefly offline. `delay:<ms>` postpones sending (used with poll/sendall).

The response includes a `delivered` boolean and a `msgid`. **Check `delivered`** — `false` means the message did not reach the recipient's host and you must retry or fail gracefully.

From a MiniDapp, wrap it in `MDS.cmd`:

```javascript
var payload = JSON.stringify({type:"MOVE", seq:seq, move:move});
MDS.cmd("maxima action:send id:1 application:myapp data:" + payload,
  function(resp){
    if (!resp.status || !resp.response.delivered) {
      MDS.log("Send failed — will retry");
      // schedule a retry / surface an error; do NOT assume it arrived
    }
});
```

## Receiving — the MAXIMA event

Incoming messages surface in MDS as a `MAXIMA` event, best handled in `service.js` so your dapp processes them even when no browser tab is open:

```javascript
// service.js
MDS.init(function(msg){
  if (msg.event == "MAXIMA") {
    // Only handle YOUR namespace — every dapp sees every message
    if (msg.data.application != "myapp") { return; }

    // msg.data.from  : sender's Maxima public key (authenticated)
    // msg.data.data  : the payload as 0x HEX
    // msg.data.msgid : unique message id
    var json = JSON.parse(hexToUtf8(msg.data.data));
    handleAppMessage(msg.data.from, json);
  }
});

function hexToUtf8(hex){
  hex = hex.startsWith("0x") ? hex.substring(2) : hex;
  var str = "";
  for (var i = 0; i < hex.length; i += 2) {
    str += String.fromCharCode(parseInt(hex.substr(i, 2), 16));
  }
  return decodeURIComponent(escape(str));
}
```

`msg.data.from` is trustworthy — the node has already verified the sender's signature and decrypted the payload before the event fires. Use it (not anything inside the payload) to identify who is talking to you.

## Delivery caveats — design for failure

Hard-won rules from production MiniDapps:

1. **Handle `delivered:false`.** Every send can fail. Retry with backoff or use `poll:true`, and tell the user when the counterparty is unreachable.
2. **Use timeouts for replies.** A message can be delivered but the response can be lost. For interactive flows (game rounds, order negotiation), 45+ seconds is a realistic timeout before declaring the exchange dead.
3. **Expect duplicates.** Retries and polling mean the same logical message can arrive twice. Guard with an idempotency check — a phase/state variable ("gamephase"), a sequence number, or a seen-`msgid` set — and drop anything that doesn't fit the current state.
4. **Expect out-of-order arrival.** Check your state machine before processing; never assume message N arrives before N+1.
5. **Keep payloads small.** Large blobs (notably serialized transactions passed between remote nodes) can arrive truncated. Symptom: `txnimport` throwing `java.io.EOFException` and one side stalling silently forever. Always validate:

```javascript
MDS.cmd("txnimport id:" + txid + " data:" + txndata, function(resp){
  if (!resp.status) {
    MDS.log("txnimport failed (corrupt Maxima transfer?): " + resp.error);
    return abortAndNotify();   // never continue on a broken import
  }
  // safe to continue
});
```

## Production messaging patterns

### SYNACK/ACK handshake

For any user-initiated action that commits both sides to something (channel open, game invite, trade), confirm the counterparty actually received it before proceeding:

```
A → B : {type:"SYN",    reqid:R, ...proposal}
B → A : {type:"SYNACK", reqid:R}        // "got it, proceeding"
A → B : {type:"ACK",    reqid:R}        // "confirmed, go"
```

Neither side changes durable state until the handshake completes; a timeout at any step rolls the flow back cleanly. Without this, a lost first message leaves one user staring at "Setting up..." forever.

### Phase guards against duplicates and crossed messages

Keep an explicit phase variable per peer/session (e.g. `0=idle, 1=request-sent, 2=active`) and enforce it on every incoming message:

- A duplicate `GAME_RESULT` while already back in phase 0 → drop it (prevents double-counting).
- An incoming `GAME_REQUEST` while *you* have already sent one (both users clicked simultaneously) → reject it; one side must win the race.

### One brain, one screen

Process Maxima messages in exactly one place — `service.js`. The UI (`index.html`) only renders notifications relayed from the service via `MDS.comms.solo()` and never handles `MAXIMA` events itself (the one conventional exception: responding to SYNACK in a UI-driven handshake). This guarantees each message is processed once, whether or not the dapp's window is open.

## Advanced options

- **Static MLS:** `maxextra action:staticmls host:<p2pidentity-of-your-server-node>` on your primary node; `host:clear` to revert to random hosts.
- **Permanent address:** on the static MLS server, `maxextra action:addpermanent publickey:<your primary node's Maxima pubkey>`. Others can then resolve you via `maxextra action:getaddress maxaddress:MAX#0x3081..#Mx..@<host>:9001` or just send to the MAX# address directly.
- **Lock down contact adds:** with a public MAX# address, anyone can add you as a contact. Disable that with `maxextra action:allowallcontacts enable:false` (messages still get through), then whitelist chosen peers with `maxextra action:addallowed publickey:0x...` / `listallowed` / `clearallowed`.
- **Signing arbitrary data:** `maxsign data:0xCD34..` signs with your Maxima private key (or a key made with `maxcreate` via `privatekey:`); the counterpart `maxverify data:.. publickey:.. signature:..` checks it. Useful for proving identity or authenticating off-band data — e.g. signing an order in a DEX relay so any third party can verify who posted it.

## Quick checklist for a Maxima-based MiniDapp

1. Namespace your messages: one unique `application` string, filter on it in `service.js`.
2. JSON payloads with a `type` field; decode from hex on receipt.
3. Check `delivered` on every send; retry or `poll:true` for must-arrive messages.
4. Timeouts on every expected reply; SYNACK/ACK before committing state.
5. Phase/sequence guards — drop duplicates and out-of-order messages.
6. Keep payloads small; validate `txnimport` (and any deserialization) on receipt.
7. Identify peers by `msg.data.from` (the verified public key), never by payload contents.

---

# Hard lessons from building a production Maxima messenger

Everything below was learned building and operating a production messenger (Parlons) and its
relay fleet on Maxima — each item traces to a live incident, a review finding, or reference-jar
verification. ★ = reliability- or fund-critical.

## Wire-level protocol facts (pin them with golden vectors)

- ★ **Generate golden vectors from the real reference `minima.jar`, never from your reading of
  the protocol.** One wrong field order makes you silently invisible on the live network — no
  error, no signal. Known traps, all vector-pinned: `MaximaMessage` field order is
  `random, from, to, timeMilli, application, data` (time is *fourth*); `MLSPacketGETResp` wire
  order differs from its constructor order; hex of empty input is `""` not `"0x"`; ack bodies
  are byte-compared by senders.
- **The `Mx` encoding is NOT standard base32** — it is a positional big-integer conversion with
  `i→w, l→y, o→z` substitutions that destroys leading zero bytes (hence the `0x01` guard byte).
  Always round-trip addresses through Minima's own code.
- **The node seed is `SHA3-256(UPPERCASE space-joined phrase)`** — not BIP39: no PBKDF2, no
  checksum, no wordlist. A lowercased phrase hashes to a different, valid-looking, *empty*
  wallet with no error anywhere. One shared identity function, parity-proven against the
  reference.
- ★ **The MAXIMA_CTRL type-1 payload carries the bare `Mx…` key with NO `@host:port`** — the
  receiver appends the address it observed the connection from. Sending a full address doubles
  the host on the peer's side.
- ★ **Mine real PoW on every Maxima send** to the chain Magic min-work, ~10% past the floor
  (÷1.1 headroom) like classic — mining exactly TO the floor gets edged out at the live-Magic
  boundary. ~10k hashes, tens of ms. Relay-side: store the already-mined MaxTxPoW and never
  re-mine on mail redelivery (an attacker storing to its own key and never acking otherwise
  forces ~900k hashes per maintenance pass).
- ★ **The 256 KB wire ceiling (`MaximaPackage.MAX_SIZE`; peers reply TOOBIG) is a hard wall**:
  anything over it silently black-holes. Page everything that can grow (contact lists, chat
  summaries, backups, console relays) and reject oversize locally at build time, not after a
  round trip. Large content moves by chunking, never bigger frames.

## Identity, addresses and resolution

- ★ **Contacts are identity-first: the durable handle is the public key; addresses are only
  cache.** Share `MAX#pubkey#mls`, never a bare address (classic exports contact *addresses*,
  valid only while that host connection lives). Keep a resolution ladder: cached address →
  MLS lookup → fan-out, plus address history.
- ★ **A truly permanent address comes ONLY from a deliberately pinned static MLS on an open-pool
  relay** — never from the rotating auto-anchor (the address changes when the host moves
  networks). And pool membership must be a per-instance flag: a process-global pool default once
  made every phone a directory host whose anchored addresses went dark when it slept.
- ★ **Pin the identity seed file into the node's data directory BEFORE first boot** — the
  permanent MAX# derives from it and a pinned seed survives `wallet resync`; without it a
  resync mints a new identity and every contact's saved address for you goes silently wrong.
  A restore must NOT carry the old host's pinned MLS anchor — the same key re-pins a fresh
  reachable anchor on first boot, while a restored stale anchor keeps naming a retired relay.
- **MLS trust:** accept the contact's own advertised MLS alone; any other resolution requires
  **≥2 independent relays to agree** — a resolved address carries the key you then encrypt to,
  so one lying directory redirects your messages to an attacker key. Replicated directory
  entries must carry the publisher's signed proof so forwarded entries are re-verifiable, and a
  strictly newer signed publish (by the publisher's own timestamp inside the proof) must replace
  a relay's stale copy, or a restarted account stays unreachable for the full TTL.
- ★ **Never advertise an address that hasn't been proven from OUTSIDE by a relay dial-back**,
  and never advertise internal/LAN/hostless addresses — the greeting's host field *overrides*
  what the peer dialled, so one bad advert poisons their record. A refresh with zero hosts
  connected must say nothing. Beware the hairpin false positive: home routers don't hairpin, so
  a dial-back from a relay on your own public IP proves nothing an external peer can use. Behind
  CGNAT, advertise nothing.

## Delivery semantics that survive production

- ★ **"delivered: true" means "queued at a relay", not "received".** Build app-layer receipts
  (SENT → DELIVERED → READ) merged by rank so a late SENT can never regress a DELIVERED, and
  reject inbound FAILED receipts — a recipient must not be able to assert your send failed.
- ★ **A duplicate arrival IS proof the sender lacks your receipt** — re-send the DELIVERED
  receipt on every dedup hit, not only on first record. A receipt lost in a restart window is
  otherwise a *permanent* bad state (message visible at the receiver, endless resend spam at
  the sender). The resend loop doubles as the receipt-recovery channel.
- ★ **Fan every 1:1 message out to ALL relay addresses the peer advertises; the receiver dedups
  by message id.** First-accepting-relay delivery strands copies in mailboxes the peer no longer
  polls (their live relay set drifts from your snapshot). Groups may stop at first-accept (cost
  × members).
- **Carry the sender's send-time on the wire; clamp inbound timestamps to now+5min; stamp
  arrival separately.** Receiver-time stamping sorts late deliveries to the bottom of threads;
  an unclamped future timestamp poisons unread watermarks and pruning (order pruning by
  max(send, arrival), never attacker time).
- ★ **Keep-alive ~25s on write-idle links, one dedicated blocking reader per attached host.**
  The reference NIO drops peers it hasn't READ from in 10 min and home NATs reap idle TCP in
  30–60 s — a passive link becomes a black hole that still reports attached. Track lastWrite
  separately from lastSeen; detach on silence past a threshold.
- **Layered staleness heals:** inline MLS re-resolve + one retry when a whole fan-out fails; a
  periodic (~30 min) stale re-resolve; and a receipt-heal (any outbound entry stuck short of
  DELIVERED gets an MLS lookup before each resend beat) — the third exists because a stale
  relay still accepts blobs (mailbox rot) while inbound traffic keeps lastSeen fresh. After a
  host restart, refresh contacts early (~15 s): peers keep sending to pre-restart addresses
  until they learn new ones.
- **Groups: no shared group key — seal 1:1 per member and fan out.** Removal then actually
  removes; roster changes only from an admin checked against the EXISTING roster (else a removed
  member re-adds themselves); when removing a member prune their ADMIN bit too. Cap group size
  (~12, cost is N sealed sends) and coalesce receipts. Group two-ticks require EVERY current
  member's receipt intersected with the current roster.
- **Persist tombstones for user-deleted contacts** — a live peer's periodic contact-ctrl refresh
  silently re-adds what you deleted. Tombstone by public key, with a grace window for deliberate
  re-adds.
- **Bridge media by capability of the TRANSPORT, not the peer's claimed capabilities** — a blob
  reference sent over a transport with no media mesh renders blank; inline (base64 data-URL
  under the ~150 KB inline cap) exactly where the blob path can't work. Any inbound typed chat
  message is itself proof the peer speaks the dialect — learn and persist capability from that.
- **Classic-engine leaf devices (phones) should run slave mode** (`TXBLOCK_NODE=true`): classic's
  verify-or-disconnect self-defeats on weak cellular (destroys the socket inbound would arrive
  on, then reconnect-storms); slave mode holds the relay connection and auto-pins the static MLS.

## Building the app around the node

- ★ **Never do blocking network work on the inbound handler thread or under the node's main
  lock.** One lock across dedup + contact fsync + a reciprocal network send + RPC handlers
  deafened the whole node whenever anything was slow — and clients' retry ladders then minted
  duplicates. Narrow locks to dedup + last-seen; run chat/RPC/side-work on serial lanes keyed by
  peer, with bounded queues.
- ★ **Give latency classes their own executor lanes.** One thread carrying pushes + call
  signalling + 55-second media publishes buried call offers (calls stopped ringing). Call
  signalling gets its own lane; per-device push pools so one dead device can't stall the rest.
- ★ **Every money RPC needs a client idempotency key, and a transport failure is "outcome
  unknown", never a safe ✗.** A retried pay once queued a second build — one tap, two one-time
  keys burned, potentially two payments. Only a gateway-REPORTED failure is a safe failure.
- ★ **Mailbox re-push is a standing property of the transport: EVERY consumer must dedup by
  message id — including call signalling.** Re-pushed offers ghost-rang phones hours later; a
  duplicate offer for the *current* call in ANY active state must be a no-op, never a busy-reply
  that kills the live call. Bind every call signal to the peer's key, not just the callId.
- **WebRTC over Maxima:** signalling rides the chat layer as typed control messages (signed,
  E2E-sealed, mined, never a bubble, never a receipt); media is ordinary DTLS-SRTP peer-to-peer;
  run STUN on your own relays (a stateless RFC 5389 binding responder is ~90 lines) so no third
  party learns who calls whom. Be honest about hard-NAT with no TURN, and add a connect
  watchdog — ICE can go quiet without ever reporting FAILED.
- ★ **Replace polling with one dedicated push reader per attached relay; paint local-first.**
  Cache paints instantly, optimistic send echo, push events applied from the event body, delta
  cursors with periodic full reconcile. Push bodies must not be truncated (a 500-char cap broke
  every pushed media manifest).
- ★ **"Live device" must mean an explicit app heartbeat, never "any authorized RPC".** A push
  extension's post-wake fetch once stamped a device live, so follow-ups were mailboxed as
  "delivered" with no wake sent. Heartbeat with a short window and explicit live:false on
  background.
- **Media over the mesh:** encrypt once (AES-256-GCM, fresh key per file), chunk under the wire
  ceiling, owner's device is the source of truth, replicate k-of-n to relays in PARALLEL under a
  wall-clock budget. Enforce an honest size cap up front (the structural walls — relay put
  rates, shared LRU shelves, owner heap — are not tunable). **Pin your OWN published media in
  the local LRU**: eviction must only ever take viewed media, or your published photos vanish
  from their own source of truth within weeks.
- **Chat persistence:** coalesce writes (one write per burst) but **flush before any mailbox
  ack**; allocate per-message bookkeeping lazily; load history off the main thread.
  Whole-file-rewrite-per-message collapses to 1–2 msg/s at 100k messages.

## Running relay/host infrastructure (generic patterns, no hosts)

- ★ **An accept loop must survive `Throwable`, not `Exception`** — `Thread.start()` throws
  OutOfMemoryError at the task limit, which escapes `catch(Exception)` and leaves a relay
  "active" that admits nobody. Guard admission separately, sleep on repeated accept errors, and
  let maintenance restart a dead accept thread.
- ★ **Socket writes have no timeout: a peer that stops reading blocks its writer forever** — and
  if that writer is the single maintenance thread, keep-alives and sweeps stop for everyone.
  Stamp write-start and reap connections whose write stalls; move keep-alives and mailbox drains
  onto bounded discard-policy pools.
- ★ **Reap only UNREGISTERED idle connections** — a registered-idle client is the normal case
  (attach, register, wait for pushes); reaping them disconnects every phone every few minutes.
  Conversely DO reap unregistered pingers on a clock, or clients that reconnect without
  dropping the old socket exhaust the per-source cap and lock out every device behind one NAT.
- ★ **Relay route registration must demand proof-of-possession** (a signed ack verified with the
  routing key itself). Unauthenticated registration lets an attacker squat an offline victim's
  routing key — receiving their mail and draining held ciphertext. Interop-preserving rule: an
  unverified route gets mailbox-AND-best-effort-live (a squatter only ever sees undecryptable
  E2E ciphertext and can never drain held mail); a connection that proves possession reclaims
  the route.
- ★ **Never sign a mailbox-deletion ack for a message that exists only in memory** — run every
  store flush before the signed ack that lets the relay delete its copy.
- **Mailbox storage at scale:** one file per held item (tmp + fsync + rename), metadata-only in
  memory, ciphertext read at delivery time; a global item cap (heap) beside the byte cap (disk).
  Reserve → write → commit; a failed write acks UNKNOWN so the sender retries elsewhere.
- ★ **systemd `MemoryMax` must exceed `-Xmx` by a margin (+512M)** or the kernel kills the JVM
  when off-heap overhead appears — and derive every in-memory cap from `Runtime.maxMemory()`
  (a flat 200k-entry cap was ~800 MB of proofs on a 96 MB heap: it could never bite before OOM).
- ★ **Never print a seed to stdout on a service** — under systemd stdout is a log file and
  shippers copy a spendable seed onward forever. Print only on a TTY; otherwise point at the
  0600 seed file. Write identity files LAST in any restore so a half-restore can't look complete.
- **Rate-limit BEFORE auth, with a global bucket as the backstop; key abuse limits on the
  connection's source IP, never on identity keys** (keys are free to mint — rotating keys gave
  each request its own probe budget). A reachability probe may only ever target the asking
  connection's source IP, or it is a port scanner.
- **Load-shed without centralizing:** the shed signal carries NO destination (a signal that
  names one lets a relay steer clients to an accomplice); the client draws its own replacement
  from relays it verified itself, detaching only after the replacement attached. Relay discovery
  generally: verify-before-adopt on a fresh socket, a relay may only claim ITSELF (claimed host
  must equal the connection's source IP), keep a negative cache for failed/refusing peers.
- **Compatibility-gate protocol rollouts:** a relay-side auth change must not reach the fleet
  until the clients that must answer it have updated, or pre-update clients lose delivery.
