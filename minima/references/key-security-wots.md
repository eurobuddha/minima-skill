# Key Security: WOTS+ and Stateful Signatures

This is the single most fund-critical area of Minima engineering. Read it before writing
anything that signs, re-syncs a wallet, audits spend history, or holds funds on a payout
address. Everything below is protocol- and engineering-level knowledge whose purpose is to
**protect funds** — to help you never reuse a one-time key, and to detect and evacuate any
address whose key has already been reused.

## Key-safety rules

> - **A WOTS leaf is one-time.** One leaf key signs exactly one message, ever. A second,
>   different signature under the same leaf weakens that key until its address can no longer
>   be considered secure. Treat any reused leaf as compromised.
> - **On every restore/resync, set `keyuses` HIGHER than the true prior count.** The node
>   regenerates keys at `uses = 0` and cannot know how many leaves were really spent. Too low
>   → it re-issues already-spent leaves → instant, self-inflicted reuse.
> - **When detecting reuse, filter to the leaf tier.** Root and intermediate tiers repeat by
>   design. A query that does not filter to the top (leaf) tier drowns in false positives.
> - **Land funds on covenant-pinned or fresh-key addresses.** Plain default-wallet addresses
>   are the exposed surface; covenant coins are resistant. The danger is value *landing* on a
>   reused-key address.
> - **Any code that increments a key-use counter must be atomic/serialized.** A non-atomic
>   read-modify-write of the counter hands out the same leaf twice under concurrency.

## Why Minima keys are stateful

Minima signs with **WOTS+ — Winternitz One-Time Signatures** (Winternitz parameter 8), a
hash-based scheme built entirely on SHA3-256 and considered quantum-resistant. Unlike the
ECDSA used by Bitcoin and Ethereum (which Shor's algorithm threatens on a sufficiently large
quantum computer), WOTS+ derives all of its security from hash functions. The cost of that
security is that each Winternitz key is genuinely **one-time-use**: reusing a single leaf key
to sign two different messages progressively leaks the private key.

To turn a one-time primitive into a reusable identity, Minima stacks WOTS leaves into a
**Merkle Signature Scheme** — a "tree of trees." By default each of a node's root keys is a
3-level structure, 64 keys per level, giving 64³ = **262,144** one-time leaves under a single
root public key. Each level's parent key signs the root of the tree below it, so a full
signature proves a path from a spent leaf up to the shared root public key that receivers use
as an address.

The node tracks how many leaves a key has consumed in a per-key **`uses`** counter, visible via:

```
keys action:list
```

**One leaf = one signature.** Every signature advances `uses` to the next leaf. The entire
security model rests on that counter being correct and monotonic. If a leaf is ever signed
twice over different data, that leaf's private key becomes recoverable, and every coin sitting
on that address is at risk. Treat a reused leaf as compromised, full stop.

## Two key families: classic 64×3 and block-as-keyuses 128×4

Newer nodes have **two deterministic tree shapes**, selected by the node's
`USE_BLOCK_AS_KEYUSES` mode — `TreeKey.createDefault` builds **128×4** trees when it is true and
the classic **64×3** otherwise (verified against bundled node bytecode):

- **Classic (64×3)** — the node's 64 wallet keys, 64 uses/level × depth 3. The `uses` counter
  is a locally stored count that must be managed across restores.
- **Block-as-keyuses (128×4)** — the **block height** serves as the keyuses source, so the
  signing index advances with the chain instead of a fragile local counter.

Consequences that have bitten real code and docs:

- **Never assume "every key has 262,144 capacity."** That is the classic shape only. Read each
  key's own `size`/`depth`/`uses`/`maxuses` from `keys action:list` — that is authoritative.
- **`txnsign publickey:<custom>`: the `keyuses` argument is required for classic custom
  signing but may be omitted in block-as-keyuses mode** (where a supplied value acts as a lower
  bound alongside the current block and saved position). The wrapper commands
  `consolidatefrom`, `createtokenfrom`, `sendfrom` and `signfrom` all require `keyuses` and
  delegate to `txnsign publickey:custom`: in classic mode it selects the next unused leaf.
  `TreeKey.createDefault` follows the node mode, which **must match the mode the signing
  key/address was created under**.
- **Restore `keyuses` defaults are a trap:** `archive`/`megammrsync` default `keyuses` to
  **1000**. Do NOT assume 1000 is safe — choose a restored position above every known previous
  signature and below the key's own `maxuses`, distinguishing classic from block keys.
  `restoresync` accepts **no** `keyuses` argument at all (the command runner rejects unlisted
  arguments), despite older docs claiming otherwise.
- **`getaddress` returns an existing default address** (it does not mint a fresh key each
  call), and `vault` phrase-based key *restoration* is a different operation from password
  *unlocking* — `reset` delegates seed recovery to `archive`.

**Sharing keys between a node and an app wallet** (same seed in both) requires *coordinated,
ongoing* counter management, not a one-time copy: durable **reservation-before-sign**, MAX-only
reconciliation when counts disagree (a stored counter is never lowered), an imported starting
floor that raises all 64 classic keys at once, and invalidation of any cached audit when seed,
trust, counts or the key list change. A clean local counter is **not** proof of signing safety —
public on-chain usage evidence must be displayed independently of it, and audits with
missing/partial evidence must stay visibly incomplete rather than reporting "no reuse found."

## The tier rule — the most important detection filter

A full Minima signature carries **multiple tiers**, one per level of the tree of trees. Only
one of them is one-time:

- **Root tier** — the top-level key. Appears in *every* signature from an address, by design.
  Repetition here is expected and is **not** a vulnerability.
- **Intermediate tier(s)** — the connecting level(s) between root and leaf. Shared across
  groups of signatures, expected to repeat. **Not** a vulnerability.
- **Leaf tier (top tier)** — the actual one-time WOTS key that signs the transaction. This is
  the only tier where reuse is exploitable.

> Every reuse-detection query MUST restrict to the leaf tier. Without that filter you get
> massive false positives from the by-design root/intermediate repeats, and the real signal is
> buried. Filtering to the leaf tier is not an optimization — it is the difference between a
> working detector and noise.

## How reuse actually happens (almost always operational, not malicious)

In practice, reuse is overwhelmingly **self-inflicted through operations**, not an attack.
Three mechanisms account for nearly all of it:

**1. Re-syncing from seed with `keyuses` set too low.** When you restore a wallet from its seed
phrase, the node regenerates every key starting at `uses = 0`. It has **no way to know** how
many leaves were actually consumed on-chain before the restore. You must tell it, via the
restore/resync `keyuses:N` parameter. If `N` is lower than the true prior consumption, the node
happily re-issues leaves it has *already spent on-chain* → instant reuse → those keys are
compromised the moment they next sign. Always set `keyuses` **higher** than the true previous
count. Signatures are stateful and cumulative; over-counting only wastes headroom (the ceiling
is 262,144 per key), while under-counting destroys security. See
`references/node-operations.md` for the resync runbook.

**2. Running the same seed on two nodes.** Each node maintains its **own independent** `uses`
counter. Two nodes on one seed will each think they own the full leaf budget and will hand out
overlapping leaves.

**3. State rollback.** Any rollback that rewinds the counter below the true on-chain consumption
re-exposes already-spent leaves, exactly like an under-set `keyuses`.

The common thread: the `uses` counter is the node's only memory of what has been spent, and
anything that resets or diverges that counter without accounting for real on-chain history
re-issues spent leaves.

## How to detect reuse — two independent methods

### Method 1 — spend-block counting (the archive method, no witnesses needed)

Critical data-model fact: **an archive retains coins, not witnesses.** A stored block keeps the
coins it created and spent but *discards the signatures*, so you cannot recover exact leaf
signatures over deep history. You can, however, reconstruct each key's default address exactly
as the protocol does and count how many times it spent:

1. For each public key, derive its default address the way Minima does:
   `RETURN SIGNEDBY(<publickey>)`, then take that script's address.
2. Count the **distinct spend-blocks** for that address on-chain.
3. Verdict:

> **reuse suspected  ⇔  on-chain distinct `spend_blocks` > the node's local `uses`** for that key.

The rule is intuitive: `uses` is how many times the node *believes* it signed; distinct
spend-blocks is how many times the chain shows that address *actually* spent. If the chain shows
more distinct signing events than the counter admits, leaves were reused.

> Count **distinct spend-blocks**, NEVER a raw spent-coins count. A single signature can spend
> many coins in one transaction/block, so a coins count over-counts wildly. Collapsing to
> distinct blocks ≈ distinct signatures ≈ `uses`, which is what makes the comparison valid.

### Method 2 — on-chain signature index (heavyweight, exact)

For a signature-exact audit, index the WOTS signatures observed on-chain keyed by
`(address, tier, publickey, block)`, then detect reuse by grouping on **address + leaf tier**
and flagging any group with `count > 1`. This is a large offline dataset and is overkill for
most needs — Method 1 is sufficient for a routine key-use audit. Reserve Method 2 for when you
need signature-exact confirmation.

> Gotcha: group **per coin address**, not per canonical/root address. Grouping by the canonical
> address collapses sibling addresses and inflates counts. One row per coin address is correct.

## Reuse ≠ compromised-in-practice

A key flagged by an audit does **not** automatically mean funds were lost or moved improperly.
Owners frequently reuse a key by accident and then move their own funds out using a *fresh* key.
That pattern reads as "at-risk, then emptied" but is a benign self-resolve. **Before declaring a
loss, check which key the emptying transaction actually used.** If the coins left the address
under a fresh leaf, the owner tidied up safely and nothing was exploited. Only reuse of the leaf
that *still guards live funds* is an active danger.

## Mitigation — the time-lock guardian (collect-and-sweep)

The reusable defensive pattern is a time-lock "guardian" covenant that collects funds to a
pre-committed address and, when needed, sweeps them onward to a fresh key. A representative
time-lock contract:

```
RETURN (@BLOCK GTE PREVSTATE(1) OR @COINAGE GTE PREVSTATE(4))
       AND VERIFYOUT(@INPUT PREVSTATE(2) @AMOUNT @TOKENID FALSE)
```

The load-bearing insight: **a COLLECT to a `VERIFYOUT`-pinned address is inherently WOTS-safe.**
The covenant's `VERIFYOUT` constrains the spend so the output can only ever go to the address
pre-committed in state — a collect literally cannot pay anywhere else. So the collect itself is
never the risk. The *only* risk is that the funds then **land** on a payout address whose leaf
key has already been reused. That gives a clean two-case policy:

- **SAFE payout** (the destination key has not been reused): just COLLECT. Done.
- **AT-RISK payout** (the destination key was reused): COLLECT, then **immediately SWEEP** the
  collected coin to a fresh-key address that has never signed — in one signed transaction, at
  the earliest confirm-depth the coin becomes spendable, to minimize the time value sits on the
  weakened key.

Generalize the principle: **design fund flows so value lands on covenant-pinned or fresh-key
addresses.** A covenant coin whose spend is constrained by `SIGNEDBY` against a key held in
state plus a `VERIFYOUT` output pin does not expose funds to a reused-key weakness the way a
plain default-wallet address does. Plain default-wallet addresses are the exposed surface;
covenant coins are resistant.

### The load-bearing trick — signing a *retired* address

A common hardening step is to *retire* a reused address so change never routes back to it —
done by nulling its script-row public key to `0x00` (turning it watch-only, non-default). But
that retirement breaks automatic signing: with the pubkey nulled, `publickey:auto` reads `0x00`
and can no longer sign that address, even though the real key still exists in the keys table.

To sweep funds off a retired address you must **extract the real key from the script** and pass
it explicitly. The address's script still contains its `SIGNEDBY(<pubkey>)`, so pull the pubkey
out and hand it to the signer:

```javascript
// srow.script looks like: RETURN SIGNEDBY(0xFF..) ...
var pkm     = (srow && srow.script) ? /SIGNEDBY\((0x[0-9a-fA-F]+)\)/i.exec(srow.script) : null;
var signKey = (pkm && pkm[1]) ? pkm[1] : "auto";
// then sign the txn with publickey:signKey instead of publickey:auto
```

The explicit key works whether or not the address was retired; `publickey:auto` does not once
the row's pubkey has been nulled.

## Programmatic-signing bugs that bite transaction builders

These are the practical failure modes when you build and sign transactions in code. Each one
can silently corrupt a signed set or a use-counter:

- **`newaddress` fails silently on a locked vault.** Minting a fresh address *creates a key
  pair*, which a password-locked or keys-wiped vault cannot do — so the call just fails. A
  locked vault then looks identical to a node error. Surface the node's own `r.error` and check
  vault-locked state before minting.
- **Use `token.totalamount`, not a truncated total field.** Serializing a token amount from a
  truncated/scaled field can overflow the 64-bit MiniNumber range ("MiniNumber too large"). Use
  the full-precision `token.totalamount`.
- **Always serialize and sign on the node.** If you serialize a transaction yourself (e.g. in
  Python), its TransactionID differs from the node's, so the signature will not match
  ("SIGNATURE FAIL"). Build/serialize on the node and sign the node's own bytes.
- **Normalize address case.** A store holding `0x…` (lowercase x) queried with `0X…` returns
  nothing on an exact match, which silently reads as **0 uses** — dangerous, because it looks
  like an unused key. Normalize the prefix before comparing.
- **Filter coins by the target tokenid.** A coins query returns token coins too; feeding an
  unrelated token coin into a set intended for a specific tokenid contaminates the signed set
  ("Inputs LESS than Outputs"). Filter to the target tokenid before assembling inputs.

## The core-code lesson — atomic counter increments

The definitive engineering lesson, publicly documented in the fork's maintainer writeup, is
about the counter itself. A `signData`-style path that does an **unsynchronized
read-modify-write** of the WOTS key-use counter can interleave under concurrency:

```
read  uses = N
sign  leaf N over data           // thousands of SHA3 hashes — a millisecond-wide window
write uses = N + 1
```

Two callers can both read `uses = N`, both sign leaf `N` over **different** data, and both write
`N + 1`. One leaf, two messages → the leaf's private key becomes recoverable, and one increment
is silently lost on top. The window is not tight: the signing between read and write is thousands
of hashes wide, so ordinary concurrent request handling is enough to trigger it.

Two aggravating factors make this reachable in normal operation:

- The path is hit by independent threads — per-request RPC handlers, per-socket app handlers, and
  periodic send timers can all call it concurrently on one node.
- Default-address selection that draws **uniformly at random from a small key set** with no
  least-used preference concentrates collisions rather than spreading them; by the birthday
  bound you expect a repeat within a handful of calls.

And verification does **not** save you: the tree verifier only walks the Merkle path to the root
public key — it has **no notion of leaf-index monotonicity**. A reused leaf still verifies
correctly and the network accepts it. Nothing in validation detects the reuse.

**The lesson:** any code that increments a key-use counter must be atomic/serialized (a single
`synchronized` mutator, or an equivalent lock/transaction), so two signers can never observe the
same `uses` value. The same applies to any shared prepared statement or cached state the counter
path touches. This is the one invariant that, if violated, quietly manufactures reuse no audit
downstream can prevent — only detect after the fact.

---

## One seed, one signer — the dual-signer catastrophe

★★ **Never let two processes sign classic WOTS keys from the same seed with independent `uses`
counters.** A standalone wallet once imported the node's seed, derived the same 64 classic keys,
and tracked uses in its own preferences — node-blind — while the node tracked the same keys in
its own DB. Both believed a leaf fresh, both signed different transactions with it; confirmed
on-chain: **~1,146 classic addresses permanently leaked**. Correct designs, best first:

1. **Delegate signing to the node** (`txncreate`/`txnsign`/`txnpost`, or `send`) — the companion
   app is a builder/relayer, never a signer.
2. **An atomic reserve RPC at the node** — read uses, persist uses+1, return the leaf, all under
   the node's own Wallet monitor.
3. **Exclusive ownership** — the node goes watch-only while the external signer owns the keys.

`keys action:list` → sign locally is a TOCTOU race, never acceptable. **Reserve-before-sign**
is the invariant: the counter is persisted at n+1 BEFORE leaf n is handed out, and every read
takes the **MAX across all counter sources**; a stored counter is never lowered.

**Hand-over rule between nodes:** set every key's uses to the highest per-key uses on the node
being left **plus a fixed safety margin (e.g. +100)**. A "raise only if signing was observed"
heuristic shipped once as +1 and was wrong. Fail closed: if the old node cannot report its
counters, do not start signing on the new one — surface a loud "do not sign yet" state.

## Exhaustion wraps around — refuse, don't wrap

★ Upstream `TreeKey.sign` handles overflow by logging "SERIOUS ERROR : MAX TREEKEYS USED" and
**wrapping uses back to 0** — after which every signature reuses leaf 0. Add a capacity check
(refuse when `uses >= size^depth`) in every signing path, and run the refusal BEFORE the counter
is advanced, so retry loops don't burn increments. Never hardcode capacity 262,144: compute
`size^depth` from the key's own `keys` row (block mode is 128⁴ = 268,435,456), because on
block-as-keyuses nodes every healthy key reports `uses ≈ chain height` — a hardcoded
"exhausted" guard reads every key as spent and halts all signing (this hard-broke a production
AMM app in ~15 places).

★ **Never accept `keyuses:0` (or any low value) on restore** — it tells the node no keys were
used, so it signs from index 0 again. Floor at the node's own default (1000) and say so in the
UI.

**Dedupe leaf burn per signing key:** a transaction with N inputs at one address should consume
1 leaf, not N — and a separate burn transaction needs its own dedupe list.

## The two key families do NOT migrate

★ The same seed under block-as-keyuses (128×4) produces **different public keys and addresses**
than classic (64×3). There is no in-place migration: a legacy wallet opened on a block-mode node
gets `uses ≈ block height` (millions) against 262,144 capacity and **cannot even sweep its own
funds** (the sweep needs a legacy-shape signature). Migration is always: sweep from a
legacy-mode node to a fresh wallet created on the block-mode node. Never ship a key-mode change
as an in-place app update — new app ID, fresh installs, old app stays available for sweeping.
Drain all in-flight swaps/channels before any key-mode migration; persisted counterparty
identities (pubkey/address) do not survive the switch.

## Defining and counting reuse correctly

- **Reuse = a LEAF (deepest-tier) public key signing ≥ 2 distinct txnids.** One transaction
  spending N coins from an address produces N signature records sharing one txnid — dedupe by
  distinct txnid or a reuse depth of 3 reads as 18.
- Spend-block counting **under-counts** (two txns in one block collapse into one spend-block) —
  treat `on-chain count == node uses` as "verify", not "clear".
- Reuse that predates your witness coverage is undetectable, permanently — cascaded blocks lose
  their witnesses everywhere except a genesis-era archive node. When a reuse count is lower than
  a uses counter, suspect missing block coverage before suspecting the method.
- Never derive an address from revealed Winternitz leaf keys (they are not the wallet's root
  public key — derivation produced zero overlap with ground truth); group findings per coin
  address taken from the data itself.

## Seed handling in apps and services

- ★ **A server identity/seed file is a spendable wallet seed — treat it as funds**: owner-only
  permissions, never copied casually, and never run a test node on a copy of a live identity (a
  copy is a second live account). Never print a seed to service stdout (systemd logs + shippers
  copy it onward forever).
- If you cache a node `-seed` boot parameter, **clear it after the first successful wallet
  load** — the node only consumes `-seed` when CREATING a wallet; leaving it in prefs is pure
  cleartext liability.
- Screen hygiene (all verified bugs): `FLAG_SECURE` on seed/password screens even when a global
  "allow screenshots" setting is on (recents thumbnails); `saveEnabled=false` on password
  fields (Android serializes them into instance-state bundles); `EXTRA_IS_SENSITIVE` when
  copying a seed to the clipboard (Android 13+ preview); clear seed TextViews on pause.
  Passwords being SET take two entries (nothing verifies them later); passwords being CHECKED
  take one (the node verifies) — and never hand a `confirm:` parameter a copy of the same
  string, or the check silently compares a value with itself.
- **Seed-generation RNG:** mix two independent sources (e.g. the node's `random` command plus a
  fresh per-roll 256-bit `SecureRandom` secret) through SHA3 with exact rejection sampling for
  zero modulo bias — every historical wallet-drain RNG hack was a small enumerable seed space.
  Make the mixing bit-identical to a KISS VM script so any output is re-verifiable with
  `runscript`. The per-roll audit log is seed-equivalent — protect it like the seed.
- **BouncyCastle pin:** anything vendoring the Minima Winternitz signer (BC `gmss` classes) must
  pin `bcprov-jdk15on:1.69` — BC 1.71+/jdk18on removed those classes, and mixing jdk15on with
  jdk18on in one app is a duplicate-class build failure.
