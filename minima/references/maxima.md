# Maxima — Off-Chain Encrypted Messaging

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
