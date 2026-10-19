# Minima UTXO Model & Manual Transaction Construction

The canonical reference for Minima's coin (UTXO) model, token creation, and building
transactions by hand with the `txn*` command family. Everything here is proven on-chain.

---

## Transaction gotchas

Read these before touching funds. Each one is a real, fund-losing (or fund-locking) trap.

1. **The amounts triad.** For a **token** coin the real value is `tokenamount`; the
   `amount` field is the underlying coloured-Minima dust (~1e-37 at typical scales).
   `c.amount || c.tokenamount` is a **bug** — `amount` is always present so it always
   wins and you silently read dust. MINIMA (`0x00`) has **no** `tokenamount` — its
   `amount` IS the value. Correct read:
   `tid === "0x00" ? c.amount : (c.tokenamount != null ? c.tokenamount : c.amount)`.
2. **Sign BEFORE basics.** The 3-step post is `txnsign` → `txnbasics` → `txnpost`,
   in that order, never combined.
3. **`txndelete` on every error path.** Once a coin is added with `txninput`, it is
   locked to that transaction. If anything fails, `txndelete id:<id>` or the inputs
   stay locked and later spends mysteriously fail with "insufficient funds".
4. **`txnpost status:true` is mempool-accept only** — it is NOT on-chain success. An
   invalid transaction broadcasts fine and is silently rejected by every node. Verify
   by watching for the spent/unspent coin events or re-querying `coins`.
5. **State is a LIST**, `[{port, type, data}, ...]` — never a map. Always iterate to
   find a port. And state is **per-transaction**, not per-output: N distinct state
   stamps require N transactions.
6. **Never fund a script address you have not proven parses.** Before sending a single
   Minima to a derived covenant/script address, run the exact script bytes through
   `runscript`/`newscript` and require `parseok:true`. A coin at an unparseable-script
   address is **permanently unspendable** — no key, node rebuild, or seed resync can
   recover it.
7. **Never `txnpost auto:true` for script-address coins** — returns `status:true` but
   silently fails on-chain. Only safe for plain wallet sends.
8. **Grain:** every token amount stored on-chain is FLOORED to the token's grain
   (10^-decimals). When a covenant pins an output amount, quantize to the grain —
   round reserves UP, proceeds/change DOWN — or the spend is rejected.

---

## The UTXO / coin model

Minima keeps track of **coins**. Not users, not balances — coins. A coin is an unspent
transaction output: some amount of value locked by a script.

- A **transaction** consumes input coins and creates output coins. Per tokenid, inputs
  must equal outputs; any MINIMA difference is **burned** (burn buys mempool priority —
  burnt coins are destroyed, not paid to the block finder). Tokens may NOT be burned:
  per-tokenid input must equal output exactly, so never drop a positive token "change"
  amount as dust — pay it back to yourself.
- A coin's **address is the hash of the script** that locks it. The coin can be spent —
  always in full — if that script returns TRUE when the transaction is validated.
  Default wallet addresses use `RETURN SIGNEDBY(<publickey>)`; each node has 64 of them.
- Every address has two interchangeable formats: hex `0x...` (`address`) and
  `Mx...` (`miniaddress`). Both are accepted anywhere an address is expected.
- **`tokenid: 0x00` is MINIMA** itself (44 decimal places). Any other tokenid is a
  custom token — a **coloured coin**: a tiny fraction of Minima coloured to represent
  the token's supply.
- Each coin carries: `coinid` (unique id), `address`, `amount`, `tokenid`, an optional
  `state` list, a `storestate` flag, and an **MMR entry** — nodes only track coins
  relevant to them and present a Merkle Mountain Range proof of validity when spending.
- A transaction also carries a **state variable list (ports 0–255)** which can be
  stamped into its output coins and read back by scripts via `PREVSTATE` — the basic
  memory mechanic for counters, sequences, and covenants.

Practical consequences of "spend in full":

- Change is a second output back to one of your own addresses. Forget it and the
  difference is burned forever.
- Spending the same coin twice fails — the second transaction references a spent
  UTXO. After sending, wait for confirmation before spending "the same" funds again
  (the change coin is `unconfirmed` until mined).

---

## Coin JSON anatomy

A real coin object from `coins relevant:true`, for a **token** coin (addresses and
coinids replaced with placeholders; the tokenid is MxUSD, a real mainnet token,
`decimals:8 scale:36`):

```json
{
  "coinid":      "0xFFEE01...",
  "amount":      "0.00000000000000000000000000000000000028497316",
  "address":     "0xFFAA02...",
  "miniaddress": "MxFF...",
  "tokenid":     "0x7D39745FBD29049BE29850B55A18BF550E4D442F930F86266E34193D89042A90",
  "token": {
    "name":        { "name": "MxUSD", "..." : "..." },
    "coinid":      "0xFFCC03...",
    "total":       "...",
    "decimals":    8,
    "script":      "RETURN TRUE",
    "totalamount": "...",
    "scale":       36,
    "tokenid":     "0x7D39745FBD29049BE29850B55A18BF550E4D442F930F86266E34193D89042A90"
  },
  "tokenamount": "0.28497316",
  "storestate":  false,
  "state":       [],
  "spent":       false,
  "mmrentry":    "728",
  "created":     "203728"
}
```

Field by field:

| Field | Meaning |
|---|---|
| `coinid` | Globally unique id of this UTXO. What you pass to `txninput`. |
| `amount` | The raw underlying Minima. For `0x00` this IS the value. For a token it is the coloured dust (real value ÷ scale) — see the amounts triad below. |
| `address` / `miniaddress` | Hash of the locking script, in hex and Mx form. |
| `tokenid` | `0x00` = MINIMA; otherwise the token's globally unique id. |
| `token` | `null` for MINIMA; for tokens, the full token descriptor: `name` (string or arbitrary JSON metadata), creation `coinid`, `total` supply, `decimals`, token `script`, `totalamount` (Minima coloured), `scale`. |
| `tokenamount` | Token coins only — the decoded, human-scale value. Absent on `0x00` coins. |
| `state` | List of `{port, type, data}` stamped by the transaction that created this coin. Empty for plain sends. |
| `storestate` | Whether the state list was stored in the MMR with the coin — required for a later spend's script to read it via `PREVSTATE`. |
| `spent` | `false` = unspent (a live UTXO). `coins` can also show spent history rows. |
| `mmrentry` | The coin's leaf in the MMR — the basis of its inclusion proof. |
| `created` | Block number in which the coin was created. |

Note: coins returned inside `history` txpows carry `tokenamount` too — a history-only
consumer can decode real values without extra lookups.

---

## The amounts triad (fund-critical)

Three related facts, each independently capable of producing a fund bug:

### 1. `tokenamount` is the value; `amount` is coloured dust

For the MxUSD coin above, the coin really holds **0.28497316 MxUSD**:

```
"amount":      "0.00000000000000000000000000000000000028497316"   ← raw, looks like dust, DO NOT USE
"tokenamount": "0.28497316"                                        ← the real value
```

MINIMA (`0x00`) has **no** `tokenamount` — `amount` is already real. So the correct
read, everywhere, is:

```js
const value = (tid === "0x00")
  ? c.amount
  : (c.tokenamount != null ? c.tokenamount : c.amount);
```

`c.amount || c.tokenamount` is a **BUG**: `amount` is always present, so it always
wins, and a token leg silently reads as ~1e-37 — which then gets grain-floored to 0
and disappears. Code forked from a native-MINIMA app that reads `coin.amount` for coin
selection, change, or claims will produce wrong sums, burned change, and broken locks
the moment it touches a token.

**Scope of the trap:** only the raw `coins`-JSON `amount` is the coloured-Minima.
`balance` (`confirmed`/`sendable`), `send amount:` and `txnoutput amount:` all use
TOKEN units directly. So you *read* value via `tokenamount`, but you *write* outputs
in ordinary token units.

### 2. Grain: token amounts are floored to 10^-decimals

Minima stores every token coin amount **floored to the token's grain**
(grain = 10^-decimals; an 8-decimal token → 1e-8). Internally amounts are truncated
downward, and a script's `GETOUTAMT` reads back the floored value. Write a token
output at 16 decimal places and the chain silently truncates it to 8 when the
covenant reads it.

Consequence for covenants: if a script pins an output with
`VERIFYOUT(... amount ...)` or enforces an invariant like a constant-product check,
and the client computed the output at finer precision than the grain, the on-chain
floored value is SMALLER than the client's — the check reads below threshold and the
spend is **rejected** (atomically; funds stay put, but the tx never lands, with a
cryptic node error).

The proven fix — quantize every token output to the token's exact `decimals`:

- **Pinned/recreated reserves → round UP** to the grain, so the stored (floored)
  value still clears the invariant.
- **Proceeds and change → round DOWN** to the grain, so outputs ≤ inputs and
  conservation holds.
- **Clamp token inputs down to the grain too** — an over-precise input makes the
  recreated reserve off-grain.

Read the grain from the coin's `token.decimals` field (present on every token coin
from `coins`/`tokens`).

### 3. MINIMA is exempt

`0x00` is full 44-decimal precision — any amount ≤ 44 dp is exact, no grain issue.
And MINIMA may be burned (that's the fee mechanism) while tokens may not: per-tokenid
inputs must equal outputs.

---

## Token creation

Tokens are coloured coins: `tokencreate` builds a special transaction that colours a
tiny fraction of Minima into a new, globally unique tokenid.

### Simple token

```bash
tokencreate name:MYTOKEN amount:1000 decimals:8
```

- Consumes a small fraction of Minima as input; change returns automatically as a
  second output.
- `decimals` defaults to 8. `decimals:0` makes the token indivisible — sending 1.5
  fails; `amount:1 decimals:0` is an NFT (1 unit, non-divisible).

### The amount / scale relationship

The coloured Minima × the **scale** = the token amount. Colour 1e-33 MINIMA at
scale 36 and you have 1000.00000000 tokens with 8 decimals. This is exactly why a
token coin's raw `amount` looks like dust: it is the coloured Minima, not the token
value. MxUSD (`decimals:8 scale:36`) is a live mainnet example of these numbers.

### Token with JSON metadata

`name` is just a string, so it can carry arbitrary JSON — stored on-chain, immutable:

```bash
tokencreate amount:10 name:{"name":"newcoin","link":"https://example.com","description":"A very cool token","icon":"https://example.com/icon.png"}
```

Common (application-defined, not protocol-enforced) fields: `name`, `description`,
`icon`/`url`, `color`, `webvalidate` (a URL hosting proof of authenticity that
wallets can check).

### Token scripts

A token can carry its own script (default `RETURN TRUE`). On every spend of every
coin of the token, **both** the coin's address script **and** the token script must
return TRUE:

```bash
tokencreate name:charitycoin amount:1000 script:"ASSERT VERIFYOUT(@TOTOUT-1 0xFFAA02... 1 0x00 TRUE)"
```

That token now demands that every transaction using it sends 1 Minima to
`0xFFAA02...` as its last output. A plain `send` of such a token fails — you must
build a manual transaction satisfying the script (see `sendable:0`, below).

### Reading the `tokencreate` response

```
inputs[0].tokenid   = "0x00"     ← Minima used as input
outputs[0].tokenid  = "0xFF..."  ← new token output (scale representation)
outputs[0].token.tokenid         ← the REAL tokenid — use this for send/balance
outputs[0].token.name            ← your metadata (string or JSON)
outputs[0].token.total           ← total supply
outputs[0].token.decimals        ← decimal places
outputs[0].token.script          ← default "RETURN TRUE"
outputs[0].tokenamount           ← human-readable supply
outputs[1].tokenid  = "0x00"     ← change back to sender
```

The token shows in `balance` as `unconfirmed` until mined.

### The tokenid is a hash — never re-serialize the descriptor

The tokenid is a hash over the token's creation descriptor (creation coin, name
bytes, total, decimals, script). The name JSON is hashed **as bytes**, so
re-serializing it with a different key order, whitespace, or number formatting yields
a **different hash — a wrong tokenid**. When you need to move token data between
nodes or reconstruct it, take the **byte-exact** token object from
`coinexport` / `tokens action:export` and import it verbatim
(`tokens action:import`). Never rebuild the JSON by hand.

---

## State: the transaction's variable list

- A transaction carries **0–255 state variables** (`port` 0–255). Output coins can
  store them (`storestate:true`), and a later spend's script reads them via
  `PREVSTATE(port)` — coins remember the transaction they came from.
- **State is a LIST**: `[{"port":0,"type":1,"data":"..."}, ...]`. It is not keyed by
  port in JSON — always iterate to find a specific port.
- **State is per-TRANSACTION, not per-output.** Every output coin of one transaction
  that stores state stores the SAME state list. To stamp N coins with N *distinct*
  states you need N transactions (one coin each; they can run in parallel).
- Set unused ports you rely on to `0` explicitly rather than leaving them absent —
  scripts read absent state as a failure case, and explicit zeros keep re-derivation
  deterministic.
- **TxPoW hard cap: 64 KB.** Everything — inputs, outputs, state, signatures, MMR
  proofs, token descriptors — must fit. With token-carrying outputs (each output
  repeats the full token descriptor) the practical ceiling is about **3
  token-carrying outputs + 1 signature per transaction**. If a coin embeds data in
  state (e.g. a base64 image), remember a transfer carries it twice: once in the
  input coin's proof and once in the recreated output state — keep such payloads
  ≤ 8 KB.
- `storestate:true` for outputs whose state must be readable at the next spend
  (phase-transition coins staying at a script address); `storestate:false` for plain
  payout outputs — smaller, cheaper, nothing to leak.

---

## The canonical manual build sequence

For anything beyond a plain wallet send — precise coin control, script addresses,
state stamping — build the transaction by hand. The terminal commands below are the
canonical interface; `MDS.cmd("txncreate id:...")` in a MiniDapp and native IPC
integrations wrap the **same** commands with the same semantics, so this sequence is
the reference for all three.

```bash
# 1. Create the empty transaction shell
txncreate id:mytxn

# 2. Add input coin(s) — get coinids from `coins relevant:true`
txninput id:mytxn coinid:0xFFEE01...
# (shortcut: txninput ... scriptmmr:true adds the MMR proof + script here —
#  but then you MUST NOT run txnbasics later; see rules below)

# 3. Add outputs — recipient first, then change back to yourself
txnoutput id:mytxn amount:10 address:0xFFAA02...
txnoutput id:mytxn amount:<input_total - 10> address:<your_change_address> \
          storestate:false
# For a token output add tokenid:<tokenid> (amount in TOKEN units).
# For an output that must retain state at a script address: storestate:true

# 4. Set transaction state variables (if the script needs them)
txnstate id:mytxn port:0 value:0xFFDD04...

# 5. SIGN — before basics, always
txnsign id:mytxn publickey:auto

# 6. Add MMR proofs + scripts
txnbasics id:mytxn

# 7. (optional) inspect
txncheck id:mytxn      # burn, per-token in/out, valid.* booleans
txnlist  id:mytxn      # full transaction incl. witness

# 8. Post
txnpost id:mytxn                 # optionally burn:<amount> for mempool priority

# ON ANY ERROR at any step:
txndelete id:mytxn               # or the input coins stay locked
```

### Critical rules (proven on-chain)

- **3-step post: `txnsign` → `txnbasics` → `txnpost`. Sign BEFORE basics. Never
  combine.**
- **Never `txnpost auto:true` for script-address coins** — it returns `status:true`
  but silently fails on-chain. Only for simple wallet sends.
- **Never combine `txninput ... scriptmmr:true` with `txnbasics`** — duplicate MMR
  proof error. Pick one mechanism.
- **`txnpost` returns `status:true` even for invalid transactions.** Status means
  "broadcast", not "accepted into a block". Confirm success by watching the spent /
  new-unspent coin events or re-querying `coins`.
- **`txncheck` cannot evaluate `@BLKNUM` / `@COINAGE`** — scripts using those globals
  always show `scripts:false` in txncheck. Don't gate posting on it for such scripts.
- **Always `txndelete` on error paths** after `txncreate` — inputs stay locked
  otherwise.
- **Inputs must equal outputs per tokenid** — MINIMA shortfall is burned; token
  shortfall is invalid. `txncheck`'s `burn` field shows exactly what you're about to
  destroy; a forgotten change output shows up here as a huge burn.
- **`txnsign publickey:auto` signs with every wallet key matching an input coin's
  address.** Convenient, but a trap with covenants — see below.

### `txncheck` — read it correctly

```
"coins":[{ "tokenid":"0x00", "input":"...", "output":"...", "difference":"..." }],
"scripts": 1,                 ← COUNT of distinct input scripts — NOT a verdict
"burn":"0",
"validamounts":true,
"valid":{
  "basic":true, "signatures":true, "mmrproofs":true,
  "scripts":true              ← THE script pass/fail verdict is HERE
}
```

The top-level `scripts` field is a **count** of distinct input scripts, not a
pass/fail. The real covenant verdict is the boolean `valid.scripts`. Gating on
`scripts == 1` both blocks legitimate multi-script transactions (covenant coin +
wallet funding = 2 scripts) and falsely passes doomed single-script ones (two coins
at the same failing address = 1 script). If your JSON library coerces types
defensively (integer vs boolean), use a truthy helper on `valid.scripts` —
`optBoolean`-style APIs return their default for an integer and silently lie.

`valid.basic` only becomes true after signatures + MMR proofs are added. Before
`txnbasics` you'll also see a `Wrong Number of MMR Proofs` warning — expected.

### Covenant traps when funding and signing

- **The owner-key auto-sign trap.** If a covenant has an owner branch
  (`IF SIGNEDBY($OWNERKEY) THEN ... ENDIF`) and you fund an *anyone-can-spend*
  transaction from a coin at the owner's own address, `txnsign publickey:auto` adds
  the owner key's signature — `SIGNEDBY($OWNERKEY)` becomes TRUE and the covenant
  runs the OWNER branch instead of the intended one, typically rejecting the spend.
  This bites an operator interacting with their own contract from the same node and
  is invisible when a third party tests. Fixes: exclude the covenant owner's
  addresses from funding-coin selection, and send change to a non-owner address, so
  `auto` never has a reason to add that key.
- **Canonical literals.** Any value baked into a covenant script AND stored elsewhere
  (state, an announce, a registry) for re-derivation must be in the same canonical
  form the node uses — the node normalizes numbers (e.g. `716.2041200000000` →
  `716.20412`). One differing character → different script hash → different address
  → your coin is at an address nobody re-derives. Strip trailing zeros and use plain
  (non-exponent) decimal strings.
- **Prove `parseok` BEFORE funding.** The prevention pattern that makes stranding
  structurally impossible: before any funds move to a derived script address, submit
  the exact script bytes via `runscript`/`newscript` on the node and require
  `parseok:true` (ideally also confirm it re-derives the exact funding address).
  A script that fails to parse — e.g. because a JSON encoder escaped `/` as `\/` on
  the way in — still yields *an* address, and coins sent there are **unrecoverable**:
  the parse failure fires at load time, so no branch (not even an owner escape hatch)
  can ever execute. When a covenant spend fails with `valid.scripts:false`, the FIRST
  diagnostic is `scripts address:<X>` → run the exact stored bytes → check `parseok`,
  before chasing keys or node state.

---

## The splitter pattern and consolidation

### Splitting: one input → N outputs

When you need many small UTXOs (per-action game spends, parallel workers, avoiding
UTXO-locked waits), split one coin into N in a single transaction.

Easiest — the built-in:

```bash
send address:<your_own_address> amount:<total> split:10
# one transaction, 10 equal outputs of total/10 each
```

Manual, for exact control:

```bash
txncreate id:splitter
txninput  id:splitter coinid:<big_coin>
txnoutput id:splitter amount:0.1 address:<recipient>
txnoutput id:splitter amount:0.1 address:<recipient>
# ... repeat N times ...
txnoutput id:splitter amount:<coinAmount - N*0.1> address:<origin_address>
txnsign   id:splitter publickey:auto
txnbasics id:splitter
txnpost   id:splitter
```

Afterwards `coins relevant:true` shows N coins of 0.1. Remember the 64 KB TxPoW cap
bounds N — especially for token outputs, where ~3 per transaction is the practical
ceiling; split adaptively over several transactions for large N.

### Consolidation: N inputs → one output

The reverse — sweep dust into one coin. Add multiple `txninput`s and a single output
back to yourself for the total (every input's script must be satisfiable, one
`txnsign publickey:auto` covers all your own default addresses). Recent nodes also
provide a `consolidate` command that does this sweep for you (see
`help command:consolidate` on your node version). Consolidation matters because coin
selection needs a single coin ≥ the send amount, or multiple inputs per transaction —
and many tiny coins bloat proofs.

---

## Reading coins and scripts

### Listing UTXOs

```bash
coins relevant:true                # coins the node tracks for you
coins relevant:true simple:true    # only coins at your own SIGNEDBY addresses
coins tokenid:0x00                 # filter by token
coins coinid:0xFFEE01...           # one specific coin
```

Two scope caveats:

- `coins relevant:true` shows coins the wallet currently **tracks** — your default
  addresses plus any script/covenant coins you imported or track. It is NOT a full
  view of everything you own: a wallet-controlled script address with `track:false`
  is invisible here. Fix with `cointrack enable:true coinid:<coinid>` per coin.
- Conversely, "relevant" can include coins that aren't yours at all (imported
  watch-coins, tracked covenants). To compute *your* net worth or history, filter to
  your own signature addresses: `scripts` marks them `simple:true` (your own
  `RETURN SIGNEDBY(key)` address; `default:true` for the 64 per-key defaults) versus
  `simple:false` (covenant / imported watch address). Build the set of `simple:true`
  addresses and sum only coins at those.

### Inspecting an address's script

```bash
scripts address:0xFFAA02...
# → { "script":"RETURN SIGNEDBY(0xFFBB05...)", "address":"0x...",
#     "miniaddress":"Mx...", "simple":true, "default":true,
#     "publickey":"0xFFBB05...", "track":true }
```

This tells you exactly what must be TRUE to spend coins at that address, and (for
simple addresses) which public key `txnsign` must use.

### The address-derivation trick

Derive the address for any pubkey — or any script — **without touching the wallet**:

```bash
newscript clean:true trackall:false script:"RETURN SIGNEDBY(0xFFBB05...)"
# → { "address":"0x...", "miniaddress":"Mx...", "script":"..." }
```

`clean:true trackall:false` computes the hash without registering the script or
creating keys — no wallet mutation. Uses: derive all 64 default addresses from
`keys action:list` output in seconds; pre-compute a covenant's address (and check
`parseok`!) before funding it; verify a counterparty's claimed address matches their
claimed script.

---

## Script-token coins and `sendable:0`

`balance` reports three numbers per token: `confirmed`, `unconfirmed` (mined but not
yet spendable-deep), and `sendable`. Coins locked by a non-trivial **token script**
(anything beyond `RETURN TRUE`) show **`sendable:0`** — the plain `send` command
refuses them, because a naive send would violate the token script and be rejected
on-chain anyway. This is a feature: it protects users from building invalid
transfers.

Moving such coins requires **manual transaction construction** that satisfies the
token script — recreating required outputs, preserving state
(`storestate:true` + identical state values where the script demands `keepstate`),
and posting via the canonical sequence above. The same applies to coins at covenant
addresses: the wallet cannot auto-spend what it cannot auto-satisfy.

A worked consequence (state-carrying NFTs): a token script of the form

```
IF SIGNEDBY(0xFFBB05...) THEN RETURN TRUE ENDIF
RETURN VERIFYOUT(@INPUT GETOUTADDR(@INPUT) @AMOUNT @TOKENID TRUE)
```

lets the creator move coins freely, but forces everyone else to recreate each spent
coin at the same output index with the same amount, tokenid and identical state — a
spend that strips the state posts with `status:true` and is then **rejected on-chain**
(the coin never moves). Which is gotcha #4 from the top of this file, observed live:
never trust `txnpost` status alone.

---

## Common failures, quickly diagnosed

| Symptom | Cause / fix |
|---|---|
| "Insufficient funds" right after a send | UTXO locked/unconfirmed — wait for the previous tx to confirm; or a stale `txncreate` locked the coin — `txndelete`. |
| Second send fails immediately | Both spends target the same UTXO; only one can win. Split coins ahead of time. |
| Huge `burn` in txncheck | Missing change output — add it before posting. |
| "Wrong Number of MMR Proofs" | Expected before `txnbasics`; if it persists at post, you skipped `txnbasics` (or doubled it with `scriptmmr:true`). |
| Posted OK, coin never moved | `txnpost` status ≠ success. Check `valid.scripts` via `txncheck`; then `scripts address:` + `runscript` → `parseok`. |
| Token output "disappears", value ~1e-37 | You read `amount` instead of `tokenamount`, and/or wrote a sub-grain amount that floored to 0. |
| Covenant rejects a mathematically-correct spend | Grain flooring — quantize outputs to `token.decimals` (reserves UP, proceeds DOWN); or the owner-key auto-sign trap flipped the branch. |
| Token creation fails | Needs a small amount of spendable Minima as input. |
