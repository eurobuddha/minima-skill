# Ecosystem & Tooling — patterns built on Minima, and how to look things up

A map of the Minima ecosystem: the application patterns that have been proven on-chain, the
official resources, the explorer/lookup tooling a developer or agent actually uses, and the
offline KISS-VM bench for testing contract logic. Contract mechanics referenced below are
described in full in `references/contracts-covenants.md`; node commands live in
`references/node-operations.md` and `references/commands-node-network.md`.

## Tooling gotchas

Read these before you trust a lookup or a test result:

1. **The hosted explorer's human page gives FALSE NEGATIVES — never WebFetch
   `explorer.minima.global/transactions/<hash>`.** That page is a client-hydrated SPA (Next.js);
   the HTML is empty until JavaScript runs, so a plain GET returns near-empty markup and every
   transaction looks "not found". For programmatic lookups use the explorer's tRPC endpoint (see
   below) or, better, your own node's `txpow` command.
2. **An explorer's block height is advisory, not canonical.** A hosted explorer's indexer can run
   *ahead* of the real chain (observed ~20k blocks higher) and can also be *missing* large spans
   of blocks. Treat any height or "confirmed" status from an explorer as a lead, and confirm
   settlement against your own node's `block` / `txpow` / archive before declaring anything final.
3. **The offline KISS-VM bench does not do real cryptography or chain state.** It validates script
   *logic*, not signatures, UTXO existence, MMR proofs, fees, or multi-transaction flows. A script
   that returns TRUE on the bench can still be rejected on-chain. Use it for logic; verify
   signature and chain behaviour on a live node.

---

## Proven application patterns gallery

These are ecosystem examples — categories of things that have been built and run on Minima. Each is
a UTXO + KISS-VM covenant pattern; the contract mechanics are detailed in
`references/contracts-covenants.md`.

**Constant-product AMM on UTXO.** A liquidity pool is represented as two reserve coins sitting at a
single *stateless* covenant address (the same script guards both reserves; pool identity is in the
coins, not in mutable script state). Swaps are validated by a constant-product invariant
(`x * y` must not decrease across the transaction), pinned with `VERIFYOUT` so the output reserves
land back at the pool address. A **minimum-product floor** is enforced alongside the invariant to
defeat dust-drain attacks, where an adversary repeatedly nibbles tiny amounts and rounds the
reserves down. Stateless design means anyone can construct a valid swap without permission.

**Cross-chain atomic swaps via HTLC.** A hash-time-locked contract links two legs (on Minima and on
another chain, or two coins on Minima) by a shared SHA-256 hashlock: revealing the preimage to claim
one leg exposes it to claim the other, so either both legs settle or neither does. A timelock
refund path returns funds to the maker if the taker never reveals. Orders are advertised on shared
**sentinel addresses** that act as a public order board — makers post offers to a well-known
address, takers scan it and fill.

**StateNFT — a collection under one tokenid.** Instead of minting a distinct token per item, an
entire collection shares ONE `tokenid`, and each coin carries per-item identity in its own coin
state (state ports). The covenant enforces that identity travels with the coin as it is spent and
recreated, so "which NFT" is a function of coin state rather than of a unique token. This keeps a
whole series under a single mintable asset while preserving per-item uniqueness and provenance.

**On-chain orderbook / fixed-exchange DEX covenants.** A resting offer is a coin at an exchange
covenant that encodes an exact price. Typical branches: an **owner-cancel** path (`SIGNEDBY` the
maker reclaims the coin), an **expiry-return** path (after a block height the offer can be returned
to the maker), and an **exact-fill** path where a taker consumes the offer only by paying the
precise counter-amount. Every payout branch is pinned with `VERIFYOUT` so the taker cannot redirect
proceeds or fill at the wrong price. This is the "fixed-exchange" style: no continuous curve, just
discrete take-it-or-leave-it orders.

**Prediction-market / escrow covenants.** Funds are locked pending an outcome, with an **arbiter**
key empowered to release to one party, and **MAST** branches (a Merklised set of spend conditions)
selecting the payout path — win, lose, refund on timeout, or arbiter override. MAST keeps the
on-chain script small: only the branch actually taken is revealed and executed.

**Time-lock "future cash" guardian vaults.** A coin is locked until a target block, after which
anyone can push it to a predetermined payout address. Because the same WOTS key must not sign twice,
these guardian/vault designs favour a **collect-and-sweep** pattern that consolidates matured coins
to a fresh address in a WOTS-safe way, avoiding key reuse when many locked coins mature and are
swept together. (See `references/key-security-wots.md` for the one-time-signature constraint.)

**Payment channels (ELTOO-style).** Two parties transact off-chain by exchanging successively newer
signed states; only the latest agreed state needs to settle on-chain. The ELTOO structure lets a
newer state supersede an older one without the punitive complexity of earlier channel designs,
which suits Minima's every-user-runs-a-node model where both parties hold the chain.

---

## Official resources

- **docs.minima.global** — the official documentation: node install, the terminal command
  reference, KISS scripting, MDS (MiniDapp System) APIs, and Maxima.
- **github.com/minima-global/Minima** — the reference node implementation (Java). This is the
  canonical protocol source; other language ports aim for parity against it.
- **build.minima.global** — the developer/build portal for MiniDapp and node builders.
- **Community** — the Minima Discord and community channels are where node operators and MiniDapp
  authors coordinate; official links are on docs.minima.global.
- **MEG (Minima Enterprise Gateway)** — an HTTP interface that fronts a Minima node for enterprise
  integration, so back-office systems can talk to a node over HTTP rather than the raw terminal.
  Useful when a hosted service needs node access (e.g. block/coin indexing behind a web backend).

---

## Explorer & lookup tooling — two different explorers

There are two distinct things called "the explorer", and they behave oppositely. Getting them
straight avoids the "the explorer has no backend" vs "the explorer has a tRPC backend" confusion:
they are different applications.

### 1. The hosted block explorer (has a tRPC backend)

`explorer.minima.global` (in its hosted form) exposes a tRPC API you can query directly:

```
GET https://explorer.minima.global/api/trpc/txpow.findById?batch=1&input={"0":{"json":{"id":"0x<txpowid>"}}}
```

- **`batch=1` is MANDATORY.** Without it the server responds `Streaming requests must be batched`.
- The `input` value is a **URL-encoded JSON object** of the form `{"0":{"json":{"id":"0x..."}}}`.
  Passing a bare string yields `Expected object, received string`.
- Send **browser-like headers** — a `User-Agent` (e.g. `Mozilla/5.0`) and a
  `Referer: https://explorer.minima.global/` — or the request may be refused.
- Response shape is `[{"result":{"data":{"json": {...}}}}]`.

**Found vs not-found is discriminated by whether `block_number` is present** — the API always
returns HTTP 200 with a JSON body even for an unknown hash:

| Field          | On-chain | Not on-chain |
|----------------|----------|--------------|
| `block_number` | integer  | absent       |
| `datetime`     | ms epoch | `null`       |
| `header.date`  | UTC date | absent       |
| `body`         | tx body  | `null`       |

Related procedures on the same tRPC surface: `txpow.findByBlockNumber`, `txpow.onchain`,
`txpow.stats` (returns chain height), and a top-level `search`.

Minimal lookup (Python), with retry and browser headers:

```python
import urllib.request, urllib.parse, json

def lookup(h):
    inp = json.dumps({"0": {"json": {"id": h}}}, separators=(',', ':'))
    qs  = urllib.parse.urlencode({"batch": "1", "input": inp})
    url = f'https://explorer.minima.global/api/trpc/txpow.findById?{qs}'
    req = urllib.request.Request(url, headers={
        'User-Agent': 'Mozilla/5.0',
        'Referer':   'https://explorer.minima.global/',
    })
    j = json.loads(urllib.request.urlopen(req, timeout=20).read().decode())
    d = j[0].get('result', {}).get('data', {}).get('json') or {}
    return d.get('block_number')  # truthy = on-chain, None/absent = not found
```

Throttle to a few requests per second and retry transient errors. **But remember gotcha #2:** the
hosted indexer is not canonical — it can be ahead of, or missing, real chain state. Use it to *find*
a lead; confirm settlement on your own node.

### 2. The "simple explorer" (client-side, NO backend)

A separate breed of Minima explorer is a **purely client-side MiniDapp** — a React app that renders
by calling `MDS.cmd('txpow ...')` against the *visitor's own local node / MEG* (localhost). It has
no hosted backend at all. Visited as a bare web URL without a running local node, it shows "no data"
everywhere, because there is nothing behind it but your own node. **You cannot query this kind of
explorer as a remote data source** — there is no server to hit; the "data source" is whoever's
browser is open. This is the flip side of gotcha #1: one explorer *has* a queryable tRPC API, the
other is just a viewer for your own node.

### 3. Your own node (the trustless option)

The node's own terminal commands are the trustless local alternative and the source of truth:

- `txpow txpowid:0x<id>` — fetch a specific TxPoW.
- `txpow block:<n>` — fetch by block height.
- `txpow address:0x<addr>` — find TxPoWs touching an address. **Note the ~13k-block search
  window**: address search only reaches back over the recent unpruned range, not the full history
  (cross-ref `references/node-operations.md`).

When correctness matters, prefer the node over either explorer.

---

## Offline contract testing — the minima-vm bench

**minima-vm** is a native C++ command-line bench that runs the KISS VM offline. It executes any KISS
script against a *simulated* transaction context — state variables, inputs, outputs, signatures,
block number, coin age — and returns TRUE/FALSE plus an instruction count and an error trace, with
no live node and no chain. It is fast and ideal for iterating on script *logic*.

Typical usage:

```bash
minima-vm --script "RETURN TRUE"
minima-vm --file contract.kiss --prevstate "0:0xPUBKEY,1:0.5,2:0xTOKENID,5:0xADDR"
minima-vm --file contract.kiss --prevstate "0:0xKEY" --signatures "0xKEY"    # cancel/owner path
minima-vm --file contract.kiss \
  --prevstate "0:0xKEY,1:0.5,2:0xTOKEN,5:0xADDR" \
  --outputs '[{"address":"0xADDR","amount":"4.5","tokenid":"0xTOKEN"}]' \
  --amount 9                                                                  # fill path
```

Flags include `--script`/`--file`, `--prevstate`/`--state` (PREVSTATE / STATE ports),
`--inputs`/`--outputs` (coins as JSON), `--signatures` (signing pubkeys), `--amount`, `--block`,
`--coinage`, and `--verbose`. Exit code 0 = TRUE, 1 = FALSE, so it scripts cleanly:
`minima-vm --script "..." && echo PASS || echo FAIL`.

### What it CANNOT simulate — critical

The bench validates logic, not chain reality. Do not trust it for anything below:

- **No real signature cryptography.** `SIGNEDBY(pub)` merely checks whether `pub` appears in the
  simulated witness list — it does NOT verify a WOTS signature. On-chain, `SIGNEDBY` requires a
  valid Winternitz one-time signature. So the bench will happily "pass" a signature path that would
  fail (or be a key-reuse hazard) on-chain. Verify all signing behaviour on a live node.
- **No chain / UTXO / MMR / mempool / fee context.** There is no real coin set, no MMR proofs, no
  mempool, and no fee accounting. Whether the input coins actually exist, are unspent, and carry
  valid MMR proofs is exactly what the bench cannot check — and exactly what a node enforces.
- **No multi-transaction flows.** Each run evaluates one script against one simulated transaction.
  Sequences that span several transactions (channel updates, order-fill-then-sweep, etc.) must be
  reasoned about run-by-run or tested on a node.
- **Fixed instruction ceiling.** The KISS VM caps execution (1024 instructions, 64 stack depth); the
  bench enforces a fixed ceiling too. A script that blows the limit fails — good to catch early, but
  confirm the exact limits against the reference node.
- **`GETOUTTOK` is an alias for `GETOUTTOKEN`.** The bench accepts `GETOUTTOK` as a convenience
  alias; treat them as the same function.
- **Watch bench-vs-node divergences.** Argument order and edge cases can differ from the reference
  Java VM — for example, a `SUBSET` argument-order difference has been observed between a bench port
  and the real VM (`SUBSET(start, length, hex)` on-chain). When a script uses functions like
  `SUBSET`, confirm against the reference implementation or a live RPC node before deploying.

**Parity:** the KISS-VM interpreter is self-rated at roughly **95% parity** with the reference —
all functions used in production contracts are implemented (SIGNEDBY, PREVSTATE, STATE, GETOUTADDR,
GETOUTAMT, GETOUTTOK, VERIFYOUT, VERIFYIN, SUMINPUTS, SUMOUTPUTS, ASSERT, SHA2, SHA3, CONCAT,
SUBSET, LEN, and 40+ more). That 95% is for *logic*. The remaining gap — and the whole of signature
and chain behaviour — is why the bench is a logic sandbox, not a deployment gate.

---

## awesomeMinima

**awesomeMinima** is a community-curated "awesome list" of Minima resources — links to docs, tools,
MiniDapps, tutorials, and libraries collected by the community. It is a good discovery entry point
when you are looking for existing tooling or example projects before building your own. As with any
community list, verify that a linked project is current and matches the official protocol before
relying on it.
