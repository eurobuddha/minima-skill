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
