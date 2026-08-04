# Proven covenant patterns for the Minima KISS VM

Real, on-chain-tested covenant designs for Minima's KISS (Keep It Simple, Stupid)
scripting VM, presented as teaching material. Every pattern here has been run,
broken, or fixed on a live chain. The scripts are sketches meant to teach the
*shape* of a safe covenant — read the safety rules first, then the pattern that
fits your problem.

All owner/creator public keys and wallet addresses below are shown as
`0xFF…`-placeholders. `0x00` is the real Minima (native coin) token id and is kept
literal. Amounts are rounded and anonymised.

Where an official worked tutorial exists for a pattern, the canonical version lives
in the Minima docs (see "Official tutorials" at the end) — this file is the
hard-won-lessons companion to those.

---

## Covenant safety rules (read this first)

These are the rules that separate a covenant that protects funds from one that
loses them. Every rule below traces to a real on-chain event.

1. **Prove `parseok` before you fund any script address.** A script that fails to
   parse produces coins that are **unspendable forever** — no key, no node rebuild,
   no proof can spend them. Always run the exact covenant bytes through the node's
   own `runscript` and confirm `parseok == true` (and ideally that it re-derives to
   the same address you are about to fund) *before* a single coin moves there.
2. **Every reachable branch must pin its outputs with `VERIFYOUT`.** Never leave a
   `SIGNEDBY(...) RETURN TRUE`-style path with no output restriction on a coin that
   holds funds. An unpinned owner-cancel path let ~5,000 MINIMA be drained on-chain.
3. **Canonicalise every literal baked into a covenant.** If a value is both baked
   into the script *and* stored elsewhere for re-derivation, both must be in the
   exact canonical form the node uses (`stripTrailingZeros().toPlainString()`),
   or the addresses silently diverge and funds land at an address nobody watches.
4. **Never let `/` get JSON-escaped into a script.** Java's `JSONObject.quote`
   turns `*5/1000` into `*5\/1000` → `parseok=false` → permanently unspendable
   coins. Quote scripts escaping only `"` and `\`.
5. **Do money math the way the VM does it.** MiniNumber is arbitrary-precision,
   rounds DOWN. Mirror it with `BigDecimal` / `decimal.js` (precision 40, ROUND_DOWN,
   no scientific notation) — never JS floats or `parseFloat`. A rounding-unit drift
   makes settlement un-signable. Round pool-favourable: reserves UP, proceeds DOWN.
6. **Exclude owner-key coins when funding an anyone-can-spend transaction.** If the
   covenant has a `SIGNEDBY(ownerkey)` branch and you fund a public spend from a coin
   at the owner address, `txnsign auto` signs with the owner key and the covenant
   takes its *owner* branch — rejecting your public spend.
7. **Sign with an explicit public key, never `auto`, near covenants.** Auto key
   selection lets a crafted transaction conscript wallet keys into signing inputs
   you never meant to spend, and trips owner branches unintentionally.
8. **`txnpost status:true` is NOT on-chain success.** It means "accepted to the
   mempool." A covenant Script-FAIL is silent — the coin never moves while the app
   logs success. Verify the contract-output *shape* against an offline VM
   (`minima-vm` / `runscript` / `txncheck`), not the post result.
9. **Read the covenant verdict, not the count.** Gate posting on
   `response.valid.scripts` (the boolean covenant pass/fail) — NOT top-level
   `scripts` (a count of distinct input scripts). Use a truthy helper accepting
   `true / 1 / "1" / "true"`; these flags are inconsistently typed.
10. **Move cold branches to MAST to stay under the size limit.** The script size
    limit is ~1150–1200 chars (undocumented, silently rejected). Rarely-used paths
    (dispute/claim/reclaim/void) go into MAST leaves with precomputed MMR proofs.
11. **All addresses come from coin STATE (`PREVSTATE`), never `getaddress` at
    runtime.** `getaddress` rotates keys; an address it returned today can become
    `relevant:false` after a vault/key-state change, stranding funds.
12. **Diagnosis-first on any covenant-spend failure.** When a spend fails on-chain
    (`Script FAIL` / `valid.scripts:false`), the FIRST move is
    `scripts address:X` → `runscript` the exact bytes → check `parseok`. Do not
    chase keys, keyuses, or node rebuilds first.

---

## 1. The cardinal covenant rule

> **Never leave a `SIGNEDBY(...) RETURN TRUE` path with no output restriction on a
> coin that holds funds.**

This is the single most expensive mistake you can make on Minima. A fixed-exchange
(limit-order) DEX shipped an owner-cancel path of the form:

```
IF SIGNEDBY(PREVSTATE(0)) THEN RETURN TRUE ENDIF
```

`PREVSTATE(0)` is the order owner's public key. The intent was "the owner can cancel
their own order." But there is **no `VERIFYOUT`** — an owner-key signature can send
the coins *anywhere*.

The attack didn't even need a hostile external party. Minima's MDS permission model
**shares wallet-key access across every app that holds WRITE permission**. A node
"hygiene" MiniDapp with write permission ran a `sweepCoins()` routine, saw the active
order coins as junk, signed them with the owner key, and sent ~5,000 MINIMA to
addresses obtained from `getaddress`. After a later vault/key-state change those
addresses showed `relevant:false, simple:false` — the funds were effectively lost.

Forensic tells worth remembering:

- **Only native-MINIMA (`0x00`) sell orders were swept; token buy orders survived.**
  The sweeper used `c.amount` directly — human-readable for `0x00`, but
  Minima-internal-scale for tokens — so token spends dusted or failed. The token
  orders survived by accident, not by design.
- **The token buy orders returned safely** via a contract-enforced expiry path
  (`@COINAGE GT 1500` → `VERIFYOUT(@INPUT PREVSTATE(1) @AMOUNT @TOKENID FALSE)`),
  which cannot be redirected. **This is proof that a trustless timeout-return path is
  worth building** — it protected funds while the unpinned cancel path lost them.

**Why it's unsafe:** any reachable `SIGNEDBY` path with no `VERIFYOUT` delegates full
custody to whoever holds that key — and on MDS that is every write-permission app,
not just your app.

**The fix** (see the DEX pattern, section 5): even the owner-cancel path pins its
output back to the maker's own address:

```
IF SIGNEDBY(PREVSTATE(0)) THEN ASSERT VERIFYOUT(@INPUT PREVSTATE(1) @AMOUNT @TOKENID FALSE) RETURN TRUE ENDIF
```

Now the owner can *trigger* a cancel, but the coins can only return to the maker's
own address. Custody is enforced by the chain, not the key.

---

## 2. Multi-phase state-machine covenant

**Pattern reference — a proven multi-phase contract shape, not a shipped product.**
The live productization of this style is a prediction-market / wager covenant
(section 7); this section teaches the *phase machine* with a provably-fair coin-flip /
dice / roulette contract as the reference implementation.

A multi-phase covenant keeps the coin at the *same* script address across several
transitions, carrying its progress in the coin's STATE ports. Each spend either
advances the phase (recreate the coin at the same address, `VERIFYOUT(... TRUE)` +
`storestate:true`) or pays out (send to a wallet address, `VERIFYOUT(... FALSE)` +
`storestate:false`).

### State-port layout

```
0=housepk   1=houseaddr   2=housecommit  3=range   4=payout   5=bet
6=phase     7=timeout     8=playerpk     9=playeraddr  10=playercommit
11=playerpick  12=housesecret  13=playersecret
```

`phase` (port 6) drives the machine: 0 = open, 1 = taken, 2 = revealed.

### Script (minified 4-path, ~1120 chars — under the size limit)

```
LET hpk=PREVSTATE(0) LET ha=PREVSTATE(1) LET hc=PREVSTATE(2) LET rng=PREVSTATE(3)
LET po=PREVSTATE(4) LET bt=PREVSTATE(5) LET ph=PREVSTATE(6) LET to=PREVSTATE(7)

/* A: Owner cancel — only while still open */
IF ph EQ 0 AND SIGNEDBY(hpk) THEN RETURN TRUE ENDIF

/* B: Take — recreate coin at phase 1 */
IF ph EQ 0 THEN
  ASSERT SAMESTATE(0 5) ASSERT STATE(6) EQ 1 ASSERT STATE(7) EQ to
  LET pp=STATE(11) ASSERT pp GTE 0 AND pp LT rng
  LET tt=@AMOUNT+bt
  ASSERT VERIFYOUT(@INPUT @ADDRESS tt @TOKENID TRUE)
  RETURN TRUE
ENDIF

LET ppk=PREVSTATE(8) LET pa=PREVSTATE(9) LET pc=PREVSTATE(10) LET pk=PREVSTATE(11)

/* C: Reveal — house reveals secret, recreate at phase 2 */
IF ph EQ 1 AND SIGNEDBY(hpk) THEN
  ASSERT SAMESTATE(0 5) ASSERT STATE(6) EQ 2 ASSERT SAMESTATE(7 11)
  LET hs=STATE(12) ASSERT SHA3(hs) EQ hc
  ASSERT VERIFYOUT(@INPUT @ADDRESS @AMOUNT @TOKENID TRUE)
  RETURN TRUE
ENDIF

/* D: Resolve — compute winner, pay out */
IF ph EQ 2 AND SIGNEDBY(ppk) THEN
  LET ps=STATE(13) ASSERT SHA3(ps) EQ pc
  LET hs=PREVSTATE(12)
  LET h=SHA3(CONCAT(hs ps)) LET r=NUMBER(SUBSET(0 4 h))%rng
  IF r EQ pk THEN
    LET w=bt*po
    ASSERT VERIFYOUT(@INPUT pa w @TOKENID FALSE)
    IF @AMOUNT GT w THEN ASSERT VERIFYOUT(@INPUT+1 ha @AMOUNT-w @TOKENID FALSE) ENDIF
  ELSE
    ASSERT VERIFYOUT(@INPUT ha @AMOUNT @TOKENID FALSE)
  ENDIF
  RETURN TRUE
ENDIF

RETURN FALSE
```

Note the **owner-cancel path (A) is only reachable at `phase 0`** — before any player
has committed funds — so an unpinned `RETURN TRUE` there is acceptable: the coin only
holds the house's own stake at that point. Once a player takes the bet, every path is
`VERIFYOUT`-pinned. (If you want to be maximally safe, pin path A too.)

### Per-path transaction construction

**Create** (the house opens the game):

```
send amount:<stake> address:<scriptAddr> state:{"0":"0xFF..hpk","1":"0xFF..ha","2":"<commit>","3":"<range>","4":"<payout>","5":"<bet>","6":"0","7":"<timeout>"}
```

**Take (path B)** — player commits, coin advances to phase 1:

```
txncreate → txninput(game coin) → txninput(player funding coin)
→ txnoutput(total=@AMOUNT+bet, scriptAddr, storestate:true)
→ txnoutput(change, playerWallet, storestate:false)
→ txnstate(preserve ports 0-5, set 6=1, 7=timeout, 8-11=player info)
→ txnsign(auto) → txnbasics → txnpost
```

**Reveal (path C)** — house reveals its secret into port 12:

```
txncreate → txninput(phase-1 coin)
→ txnoutput(same amount, scriptAddr, storestate:true)
→ txnstate(preserve 0-5, set 6=2, preserve 7-11, set 12=housesecret)
→ txnsign(housepk) → txnbasics → txnpost
```

**Resolve (path D)** — player reveals its secret, contract computes the winner:

```
txncreate → txninput(phase-2 coin)
→ txnoutput(winnings → winner, storestate:false)
→ [optional txnoutput(remainder → loser, storestate:false)]
→ txnstate(set 13=playersecret)
→ txnsign(playerpk) → txnbasics → txnpost
```

### Why it's safe / unsafe

- **Safe:** phase transitions are pinned with `VERIFYOUT(... TRUE)` and re-assert the
  immutable ports with `SAMESTATE`, so a counterparty building the next transaction
  cannot rewrite the proposition, bet, range, or payout. `SAMESTATE(0 5)` +
  `SAMESTATE(7 11)` (split because port 6 changes) pins the whole immutable region.
- **Safe:** payouts are pinned to addresses that came from `PREVSTATE` (coin state at
  creation), never `getaddress`.
- **Unsafe if you skip `SAMESTATE`:** pinning only the values you *read* lets whoever
  builds the next txn silently rewrite the rest — assert the whole region unchanged.
- **VM gotchas that silently break this contract:** no underscores in variable names;
  `@BLKNUM` is broken on synced nodes (use `@COINAGE`); unset STATE ports crash the
  Java VM (set unused ports to 0); `VERIFYOUT(... FALSE)` with `storestate:true` (or
  the reverse) is silently rejected; `NUMBER()` overflows on a 32-byte hash, so you
  MUST `SUBSET(0 4 h)` first.

---

## 3. Commit-reveal randomness

Provably-fair randomness for a 2-party game without a trusted oracle. Both sides
commit to a secret (publish `SHA3(secret)`), then both reveal; the outcome is a
deterministic function of the two secrets that neither could predict at commit time.

### The on-chain KISS math

```
LET h=SHA3(CONCAT(houseSecret playerSecret))
LET r=NUMBER(SUBSET(0 4 h))%range
```

- `CONCAT` joins the two hex secrets.
- `SHA3` (Keccak-256) produces a 32-byte hash.
- `SUBSET(0 4 h)` takes the first 4 bytes — because `NUMBER()` overflows on anything
  bigger than ~4 bytes.
- `NUMBER(...)%range` maps to `0 … range-1` (2 = coin flip, 6 = dice, 36 = roulette).

### The JS that MUST match the on-chain math exactly

```javascript
// 1. Each side generates a secret and publishes only its hash (the commit)
MDS.cmd("random", function(resp){
    var secret = resp.response.random;         // 64 hex chars, 0x-prefixed
    MDS.cmd("hash data:" + secret, function(h){
        var commit = h.response.hash;          // SHA3 — this is what you publish
    });
});

// 2. After BOTH commits are locked into coin state, both reveal their secrets.

// 3. Compute the outcome — MUST reproduce the KISS VM byte-for-byte:
var combined = houseSecret + playerSecret.substring(2);  // CONCAT, strip 0x off 2nd
MDS.cmd("hash data:" + combined, function(h){
    var hash   = h.response.hash;
    var first4 = hash.substring(2, 10);        // SUBSET(0 4 hash) — skip 0x, 8 hexits
    var num    = parseInt(first4, 16);         // NUMBER()
    var result = num % range;                  // % range
    var winner = (result === playerPick) ? "player" : "house";
});
```

The two subtle traps: **strip the `0x` prefix off the second secret before
concatenating** (KISS `CONCAT` joins the raw bytes), and **take exactly 8 hex chars
(4 bytes) after the `0x`** for the `SUBSET`. Get either wrong and the JS prediction
diverges from what the chain computes — the dispute path will disagree with your UI.

### Why pessimistic commit kills the free-option attack

Deduct the player's bet from the channel/coin balance **before** the house reveals.
If the player loses and walks away, the already-deducted balance is the correct final
state — there is nothing to gain by disappearing. If instead you settled optimistically
(bet only deducted on a loss), a player could reveal, see they lost, and abort to
avoid paying — a free option. Pessimistic commit removes the option entirely.

### Why it's safe

Neither side knows the other's secret at commit time, and the combined hash is
deterministic, so both parties (and an on-chain MAST dispute path) compute the same
result independently. The randomness is jointly sourced — one dishonest party cannot
bias it.

---

## 4. MAST dispute / branch pattern

MAST (Merkelized Abstract Syntax Tree) lets you keep rarely-used branches **off** the
main script, so the on-chain script the common path pays for stays under the
~1150-char size limit. The cold branches live as separate scripts committed to by
hash; you reveal and prove only the branch you actually spend through.

Every ELTOO-style channel or long-lived covenant should carry dispute branches at
escalating block deadlines:

```
Block 32:    DISPUTE — a party proves they won, before the counterparty can claim
Block 256:   CLAIM   — counterparty claims after the other walked away
Block 1024:  RECLAIM — recover funds if the counterparty vanished without revealing
```

### Rules every MAST branch must follow

1. **`SIGNEDBY(key from PREVSTATE)`** — authorisation comes from the *coin state*
   (immutable, set at creation), never from a runtime key lookup.
2. **`VERIFYOUT(@INPUT addr amount @TOKENID FALSE)`** — every branch pins its exact
   payout. No branch pays out without a `VERIFYOUT`.
3. **No unguarded `SIGNEDBY` path anywhere** — the cardinal rule (section 1) applies
   to MAST leaves too. An unpinned `SIGNEDBY … RETURN TRUE` leaf is the same drain.
4. **Precompute the MMR proofs** for each leaf so the disputing party can spend
   without recomputing chain state under time pressure.

### Testing a MAST spend offline

```
runscript script:"MAST 0x<root>" extrascripts:{"<the branch script>":"0x<proof>"}
```

The `extrascripts` map pairs each revealed branch's source with its MMR proof — the
node checks the branch hashes into the committed root before running it.

### Why it's safe / unsafe

- **Safe:** the common (co-operative) path never reveals the dispute logic, so it
  stays small and cheap; a griefer cannot spend a cold branch early because the
  branch's own `@COINAGE` deadline and `SIGNEDBY` gate it.
- **Unsafe if a branch skips `VERIFYOUT`:** a 1222-char contract once silently failed
  (over the size limit) and lost ~343 MINIMA — the reason cold paths *must* be MAST'd
  off rather than inlined. And an unpinned dispute leaf reintroduces the section-1
  drain on the disputed funds.

---

## 5. Fixed-exchange / limit-order DEX covenant

A limit order locks the maker's coin in a covenant that allows exactly three things:
the maker cancels (funds return to the maker), the order expires (funds return to the
maker), or someone fills it (maker receives the exact want-amount/token/address). This
is the **V4** design — the incident-hardened version.

### The covenant (V4 — every path VERIFYOUT-pinned)

```
LET u=0xFF..allowedToken
IF @TOKENID NEQ 0x00 THEN IF @TOKENID NEQ u THEN RETURN FALSE ENDIF ENDIF
IF PREVSTATE(3) NEQ 0x00 THEN IF PREVSTATE(3) NEQ u THEN RETURN FALSE ENDIF ENDIF
IF SIGNEDBY(PREVSTATE(0)) THEN ASSERT VERIFYOUT(@INPUT PREVSTATE(1) @AMOUNT @TOKENID FALSE) RETURN TRUE ENDIF
IF @COINAGE GT 1500 THEN ASSERT VERIFYOUT(@INPUT PREVSTATE(1) @AMOUNT @TOKENID FALSE) RETURN TRUE ENDIF
ASSERT VERIFYOUT(@INPUT PREVSTATE(1) PREVSTATE(2) PREVSTATE(3) FALSE) RETURN TRUE
```

State ports: `0` = owner pubkey, `1` = want (maker's own) address, `2` = want amount,
`3` = want tokenid.

Three paths, **every one pinned with `VERIFYOUT`**:

- **Owner-cancel** — `SIGNEDBY(PREVSTATE(0))` but the output is pinned back to
  `PREVSTATE(1)` (the maker's own address). This is the fix for the section-1
  incident: the owner can trigger a cancel but cannot redirect the coins.
- **`@COINAGE GT 1500` expiry** — anyone can trigger it (no signature), but the funds
  can only go to `PREVSTATE(1)`. This trustless timeout-return path is what saved the
  token orders in the incident.
- **Fill** — the taker must produce the exact `PREVSTATE(2)` amount of the
  `PREVSTATE(3)` token to `PREVSTATE(1)`. A token allow-list (`u`) is enforced up front.

### Ship all versions simultaneously

You cannot upgrade a covenant coin in place — a coin created under V1 can only be
spent by satisfying the V1 script. So register **all** versions at startup
(`newscript` V1..V4) so that orders created under older versions stay spendable while
new orders use the hardened script.

### The silent Script-FAIL lesson

After the owner branch gained its `VERIFYOUT(@INPUT PREVSTATE(1) @AMOUNT @TOKENID
FALSE)` requirement, an auto-refresh routine kept sending its refreshed output back to
the **contract address** instead of `PREVSTATE(1)`. Result: **every auto-refresh
silently Script-FAILed at mining for weeks** — `txnpost` returned `status:true`
(accepted to mempool) and the dapp logged "Refreshed," while the coin never moved.

> `txnpost status:true` means "accepted to mempool," NOT "will mine." A covenant
> Script-FAIL is silent. Reproduce the exact contract-output **shape** offline
> (`minima-vm` / `runscript`): the refresh shape returns `ASSERT failed`; the collect
> shape passes. Verify shape, never trust the post result.

### GTC (good-till-cancelled) without refreshing a covenant

You cannot "refresh" a covenant coin (any spend must satisfy the covenant). So GTC is
a **two-transaction CANCEL (funds → wallet) then RECREATE (fresh re-lock)**,
coordinated through a shared SQL table with `PRIMARY KEY(orderid)` so a page and a
service (separate JS contexts sharing only SQL) can't double-fire. **Persist before
broadcast**; treat "funds missing" as "the order was filled — never re-lock." Carry
the GTC flag in an unused state port (e.g. port 7 = "1") that the covenant ignores
(ports > 3 are unused) → interop-safe and invisible to the contract.

### Why it's safe / unsafe

- **Safe:** the trustless `@COINAGE` expiry return path means funds are recoverable
  even if the app dies, the maker loses their key-access, or a write-permission app
  goes rogue — the chain returns them to the maker after the deadline.
- **Unsafe (the V1/V2 lesson):** the unpinned owner-cancel path is exactly the
  section-1 drain. The **trustless timeout-return path saved funds where the unpinned
  cancel lost them** — build the timeout path even if you also have a cancel path.

---

## 6. Constant-product AMM on the UTXO model

A stateless constant-product AMM where **a pool is just two reserve coins** — a native
MINIMA coin (reserve `x`) and a token coin (reserve `y`) — sitting at one covenant
address. Anyone swaps by spending both coins and recreating them, provided the
constant-product invariant (minus a fee) still holds. The fee stays in the pool, so
`x·y` grows with volume — that growth is the LP's reward. No LP token, no batcher, no
shared custody.

### Why the params are hardcoded literals

A Minima transaction has **one shared STATE array**; every `keepstate` output
receives it. Two pools routed through one transaction could not each pin their own
params via coin state. So the four params are **baked into the script as literals**:

- `$OPK` — owner pubkey (a *dedicated* key, never the LP's spending key)
- `$OADR` — owner payout address
- `$TOK` — the paired token id
- `$KMIN` — the product floor (see below)

Because the params are literals, **each pool's address = its script hash**, the pool
carries **zero state**, and everything uses `storestate:false`. Multi-pool routing in
one transaction "just works" because each leg self-pins by coin index.

### The covenant

```
IF SIGNEDBY($OPK) THEN
  IF VERIFYOUT(@INPUT $OADR @AMOUNT @TOKENID FALSE) THEN RETURN TRUE ENDIF
  RETURN GETOUTADDR(@INPUT) EQ @ADDRESS AND GETOUTTOK(@INPUT) EQ @TOKENID AND GETOUTAMT(@INPUT) GTE @AMOUNT
ENDIF
IF @TOKENID EQ 0x00 THEN
  ASSERT @INPUT % 2 EQ 0 LET s=@INPUT+1
  ASSERT GETINADDR(s) EQ @ADDRESS AND GETINTOK(s) EQ $TOK
  ASSERT GETOUTADDR(s) EQ @ADDRESS AND GETOUTTOK(s) EQ $TOK
  LET x=@AMOUNT LET y=GETINAMT(s) LET nx=GETOUTAMT(@INPUT) LET ny=GETOUTAMT(s)
  ASSERT VERIFYOUT(@INPUT @ADDRESS nx 0x00 FALSE)
ELSE
  ASSERT @TOKENID EQ $TOK AND @INPUT % 2 EQ 1 LET s=@INPUT-1
  ASSERT GETINADDR(s) EQ @ADDRESS AND GETINTOK(s) EQ 0x00
  ASSERT GETOUTADDR(s) EQ @ADDRESS AND GETOUTTOK(s) EQ 0x00
  LET y=@AMOUNT LET x=GETINAMT(s) LET ny=GETOUTAMT(@INPUT) LET nx=GETOUTAMT(s)
  ASSERT VERIFYOUT(@INPUT @ADDRESS ny $TOK FALSE)
ENDIF
LET dx=nx-x LET dy=ny-y LET fx=MAX(dx 0)*5/1000 LET fy=MAX(dy 0)*5/1000
RETURN (nx-fx)*(ny-fy) GTE MAX(x*y $KMIN)
```

### The invariant (0.5% fee, fail-closed)

```
LET dx=nx-x LET dy=ny-y LET fx=MAX(dx 0)*5/1000 LET fy=MAX(dy 0)*5/1000
RETURN (nx-fx)*(ny-fy) GTE MAX(x*y $KMIN)
```

Accept a swap iff `(nx − fee·dx)·(ny − fee·dy) ≥ max(x·y, KMIN)`, with the fee only on
the side that grew (`MAX(d,0)`). The fee is **divided first** so the largest
intermediate is `(nx−fx)·ny` rather than a cross-multiplied form ~1000× larger that
would overflow much sooner. MiniNumber's magnitude ceiling is `2⁶⁴−1 ≈ 1.846e19`; any
intermediate past it makes the script throw, which the VM turns into a **clean swap
rejection** (`success=false`) — never a false-accept, never a crash. The invariant is
self-limiting.

### Legs paired by coin-index parity

The MINIMA coin sits at an **even** input index `2i`, its token coin at `2i+1`,
outputs mirrored (`@INPUT % 2`). Each leg binds its sibling by address + token id (on
both input and output), pins its own recreation with a 5-param
`VERIFYOUT(... storestate:false)`, and the final line enforces the fee-loaded product
floor. Because a signature is transaction-wide, a signed transaction takes the owner
branch on *both* legs — it can never mix owner pinning on one leg with swap logic on
the other.

### KMIN — the one non-obvious defense unique to the 2-coin UTXO model

Because a pool is two coins with **no unforgeable cross-coin binding**, anyone can
send a **dust token coin** to the pool address and pair it with the pool's real MINIMA
coin. Without a floor, the invariant `nx·ny ≥ x·y` anchors to `x·y_dust ≈ 0` and the
MINIMA leg **drains for dust**. The fix is a hardcoded floor:
`KMIN = SIGDIG(20, x0·y0)` (the creation product to 20 sig-figs, rounded down). A
forged-dust pairing must then *restore the full creation product* to extract
anything — strictly worse than swapping honestly. Constraint: **`KMIN ≥ 2⁶⁴` won't
compile**, so pools have a max size (`x0·y0 < 2⁶⁴`); split large pools into several.

### Rounding

All rounding is DOWN and pool-favourable: round recreate-reserves **UP** to token
grain; round proceeds / change **DOWN**. Every truncation favours the pool.

### THE FUND-CRITICAL TRAP: a `/` in a covenant literal

The invariant contains `*5/1000`. Java's `JSONObject.quote` (and `JSONStringer`)
**escapes forward slashes**: `*5/1000` becomes `*5\/1000`. Passed to
`newscript`/`runscript`, the node keeps the backslash literally and the KISS parser
fails (`parseok=false`) — and because the failure is at parse/load time, **no branch,
not even the owner-exit, can ever execute → any coin sent to that address is
PERMANENTLY UNSPENDABLE.**

This is not theoretical. A pre-fix build created a live pool whose on-chain covenant
literally stored the escaped fee literal `*5\/1000`; a large reserve balance plus a later mistaken direct
`send` to that dead address are permanently stuck. Proven unrecoverable: even on a
node holding the exact tracked script, correct key-uses, full MMR proofs, and a valid
owner signature, `txncheck` returned `valid.scripts:false` and every `txnpost` was
rejected — because the tracked script's `parseok=false`. **No key, keyuses, node, or
seed can spend an unparseable covenant.**

Defenses:

- **Quote scripts escaping only `"` and `\`, never `/`.** Python's `json.dumps` does
  *not* escape `/`, so an RPC/Python harness passes while the Java IPC path fails —
  test script-passing on the ACTUAL path funds will move through.
- **Prove `parseok` via the node's own `runscript` BEFORE funding any script
  address.** This turns a permanent fund-loss into a harmless "aborted, nothing moved."
- **Canonicalise numeric literals** (`stripTrailingZeros().toPlainString()`) so the
  covenant, any stored-state copy, and the re-derived address all agree
  byte-for-byte — else discovery re-derives a *different* (empty) address than where
  reserves landed.
- **Keep `x·y < 2⁶⁴`** so KMIN compiles.

### Post-gating

Every post is gated on the covenant's own `txncheck` verdict: post only if **all** of
`response.valid.scripts` AND `response.validamounts` AND `response.valid.mmrproofs`
are truthy; else delete the txn. Read `valid.scripts` (the covenant verdict), NOT
top-level `scripts` (a count of distinct input scripts).

### Funding trap (owner-key auto-sign)

A swap is anyone-can-spend and must NOT be signed by `$OPK`. But if the taker funds
the swap from a coin at `$OADR` (the owner payout address, whose key is `$OPK`),
`txnsign auto` adds `$OPK`'s signature → the covenant takes its **owner** branch →
rejects the reserve-shrinking swap. Fixes: swap funding selection must **exclude** the
pool's owner address(es), and create/deposit/migrate change must go to a *non-owner*
wallet address.

### Transaction templates (all `storestate:false`, no state ports)

```
CREATE   — send x0 MINIMA + y0 token to derived pool address A; post an announce coin.
SWAP M→T — inputs [pool-M@A, pool-T@A, taker MINIMA funding…];
           outputs [(A,nx,0x00),(A,ny,$TOK),(taker,dy,$TOK),(taker change,0x00)]. Sign taker inputs only.
SWAP T→M — taker funds a token coin; outputs [(A,nx,0x00),(A,ny,$TOK),(taker,dm,0x00)].
ROUTED   — pool i's MINIMA coin at input 2i, token at 2i+1, outputs mirrored; ~8-10 pools per 64KB TxPoW.
DEPOSIT  — owner-signed grow-in-place: [(A,x+Δx),(A,y+Δy)], amounts ≥ inputs.
MIGRATE  — owner-signed: exit old reserves to $OADR AND fund new pool coins at new address A' (new KMIN).
CLOSE    — owner-signed: [(A→$OADR,x,0x00),(A→$OADR,y,$TOK)].
```

Pools are discovered via a shared sentinel address (an announce coin whose reclaim key
is `PREVSTATE(0)`), but the client **trusts nothing** — it re-derives the pool script
from `{tokenid, $OADR, $OPK, $KMIN}`, gets the clean address via `runscript`, and only
then scans that address for reserves.

### Why it's safe / unsafe

- **Safe:** owner-exit path runs *before any arithmetic that could throw*, so a
  pool is always owner-recoverable; KMIN blocks the dust-pairing drain; overflow
  fails closed; every truncation favours the pool.
- **Unsafe:** a `/`-escaped literal or a non-canonical KMIN strands funds forever —
  which is exactly why the `parseok` pre-flight in safety rule 1 is non-negotiable.

---

## 7. Prediction-market / escrow covenant

The live productization of the multi-phase style (section 2), but arbiter-based rather
than hash commit-reveal — for outcomes that can't be settled by cryptographic
randomness (real-world events). An 8+ port state machine (port 4 = phase 0 open /
1 matched, port 11 = outcome) with these paths:

- **owner-cancel** — while still open (unmatched), returns the maker's stake.
- **anyone-fill** — a counterparty matches the market, combining both stakes.
- **two-party self-settle (0% fee)** — both parties agree the outcome and split
  directly, no arbiter fee.
- **arbiter-resolve (fee % of pot)** — if the parties disagree, a named arbiter
  decides; the covenant enforces the payout and takes a fixed % of the pot.

Plus **MAST leaves** for refresh / timeout / void, each with a precomputed MMR proof.

### Escrow lock enforced by paired VERIFYOUT

Each side locks `bet × 1.25` (escrow = lock / 5). The self-settle escrow math is
enforced by **paired outputs** — `VERIFYOUT(@INPUT ...)` for one party and
`VERIFYOUT(@INPUT+1 ...)` for the other — so the settlement can only pay both sides
their contract-correct amounts. A `@COINAGE` timeout-refund path is the trustless
backstop if the arbiter or a party disappears.

### Pin the proposition

Pin every state variable a counterparty must not rewrite with `SAMESTATE` over the
range — the proposition, funding amount, arbiter identity, outcome port. Never key
application logic on **free-form text** (a proposition string or token name is
spoofable / duplicable); key on a fixed-width random nonce pinned on-chain, and
resolve parties by their on-chain-pinned pubkeys.

### The social-vs-cryptographic arbiter-trust caveat

A covenant can enforce that the arbiter's key differs from both parties' keys — it
**cannot** enforce that the arbiter is *independent*. Cryptography cannot fix a social
trust assumption. Surface the arbiter identity in the UI and state the residual trust
plainly: this is trust-minimised, not trustless, and the trust that remains is that
the arbiter is honest and independent.

### Why it's safe / unsafe

- **Safe:** the 0%-fee self-settle path means honest parties never pay the arbiter;
  the timeout-refund path recovers funds if anyone vanishes; paired `VERIFYOUT`
  makes an unequal / rewritten settlement un-signable.
- **Unsafe:** if the arbiter path lacks a `VERIFYOUT` pin on the payout, or the
  proposition ports aren't pinned with `SAMESTATE`, a matched market can be settled to
  the wrong party or the wrong amount.

---

## 8. StateNFT — a collection sharing ONE token id

A whole NFT collection under **one** Minima token id, where each coin's STATE carries
its own identity — enforced by consensus so it survives transfers and cannot be
stripped or forged. (Proven on-chain, mainnet.)

Minima tokens are coloured coins: token metadata (name/url/description) is fixed at
`tokencreate` for *every* coin of the token id, so per-NFT images cannot live there.
Instead:

1. **One `tokencreate amount:N decimals:0`** → N indivisible units, one token id.
   Metadata holds collection-level data (base image URL, extension, size).
2. **Per-coin STATE = identity.** Each unit coin carries state port 0 = item index
   (1..N). Image URL = `base + index + ext`.
3. **The immutable token script** validates every spend of every coin:

```
IF SIGNEDBY(0xFF..creatorpubkey) THEN RETURN TRUE ENDIF
RETURN VERIFYOUT(@INPUT GETOUTADDR(@INPUT) @AMOUNT @TOKENID TRUE)
```

A non-creator spend must recreate the coin at the same output index with the same
amount, token id, and **identical state** (`keepstate TRUE`). Identity travels with
the coin; a spend that strips it is rejected by the chain. The creator key is a
deliberate escape hatch (the mint/stamp path) — the standard "trust the minter"
assumption.

### Proven facts (mainnet)

- **State is per-TRANSACTION, not per-output** → stamping N distinct identities takes
  **N transactions** (one coin each; parallel-safe). You cannot mint N differently-
  stated coins in one transaction because a transaction has one shared state array.
- **TxPoW has a 64 KB cap** → ~3 token-carrying outputs + 1 signature per transaction
  is the practical ceiling. Keep coins at the creator address so one signature covers
  both the coin and the token script.
- **Script-token coins show `sendable:0`** in the wallet → plain `send` refuses them
  (which protects users from accidentally invalid transfers). All moves go through
  manually-constructed transactions.
- **A state-stripping spend posts with `status:true` but is REJECTED on-chain** (the
  coin never moves) → **never trust `txnpost` status alone.** This is the same lesson
  as the DEX silent Script-FAIL (section 5): mempool acceptance is not mining.

### Why it's safe / unsafe

- **Safe:** the `VERIFYOUT(@INPUT GETOUTADDR(@INPUT) @AMOUNT @TOKENID TRUE)` clause
  forces identity preservation on every non-creator spend — the chain, not the app,
  guarantees the image can't be swapped or stripped.
- **Unsafe (by design tradeoff):** the creator key can bypass enforcement forever —
  acceptable for a mint escape hatch, but it means holders trust the minter not to
  re-stamp. Surface this.

---

## 9. HTLC cross-chain atomic swap

A Hashed Time-Lock Contract swaps a coin on Minima for an asset on another chain with
**no trusted intermediary**. The same SHA-256 hashlock is used on both chains' legs:
claiming the far leg reveals the preimage, which then unlocks the Minima leg (or vice
versa). Each leg has a timelock refund path so nobody's funds get stuck if the swap is
abandoned.

### The Minima leg as a covenant

```
IF SHA256(secret) EQ hashlock AND SIGNEDBY(0xFF..claimant) THEN
  ASSERT VERIFYOUT(@INPUT 0xFF..claimantaddr @AMOUNT @TOKENID FALSE) RETURN TRUE
ENDIF
IF @COINAGE GT timeout AND SIGNEDBY(0xFF..refunder) THEN
  ASSERT VERIFYOUT(@INPUT 0xFF..refunderaddr @AMOUNT @TOKENID FALSE) RETURN TRUE
ENDIF
RETURN FALSE
```

- **Claim path:** whoever knows `secret` (such that `SHA256(secret)` matches the
  agreed `hashlock`) and holds the claimant key sweeps the coin — and in doing so
  publishes `secret` on-chain, which the counterparty uses to claim the other leg.
- **Refund path:** after `@COINAGE GT timeout` the funder (refunder) reclaims. The
  refund timeout on the Minima leg must be **longer** than on the leg the counterparty
  claims first, or the counterparty could claim and then let their own refund fire.

Both payout addresses are pinned with `VERIFYOUT`, so neither path can redirect funds.
Order boards / swap offers are published over **shared sentinel addresses** (the same
re-derive-and-verify discovery pattern as the AMM registry) rather than a central
server.

### Why it's safe / unsafe

- **Safe:** the hashlock links the two legs cryptographically — either both settle or
  both refund; no party can take one leg without exposing the secret that settles the
  other.
- **Unsafe if timeouts are mis-ordered:** if the Minima-leg refund fires before the
  far-leg claim window closes, a counterparty can claim your coin *and* refund theirs.
  Order the timelocks so the party who reveals the secret first has the *later* refund.

(The canonical worked version is the official HTLC tutorial — see below. Keep your
implementation genericised: no exchange- or token-specific assumptions in the leg.)

---

## 10. ELTOO / floating coins & payment channels

An off-chain payment channel where the two parties exchange signed states off-chain
and only settle on-chain when they disagree or close. ELTOO lets a newer state
override an older one (by sequence number), so you don't need a full penalty-based
justice system — the latest state always wins.

### Channel state-port layout

```
Port 100: settlement flag (TRUE/FALSE)
Port 101: sequence number (increments with each state update)
Port 102: game phase (0=idle, 1=active)
Port 103: bet / update amount
Port 104: range (2=flip, 6=dice, 36=roulette)   -- for game-aware channels
Port 105: player commit hash (SHA3 of secret)
Port 106: house commit hash
Port 107: player's pick
Port 108: bettor indicator (1=user1, 2=user2)
Port 109: user1 payout address (FROM PREVSTATE, never getaddress)
Port 110: user2 payout address (FROM PREVSTATE, never getaddress)
Port 111: user1 pre-bet amount
Port 112: user2 pre-bet amount
Port 115: user1 public key (for MAST SIGNEDBY)
Port 116: user2 public key
Port 200: channel hashid (for payout tracking)
```

### "All addresses come from PREVSTATE, never getaddress at runtime"

This is the load-bearing rule. `getaddress` **rotates keys** — an address it returns
today can become `relevant:false` after a vault restore, key regeneration, or resync,
and any funds pinned to it are lost. Store both parties' payout addresses in the coin
STATE at channel creation and read them with `PREVSTATE` in every branch. The ~5,000
MINIMA loss traces directly to `getaddress`-derived destinations going unrecognised.

### Floating coins / precoin

A **floating** transaction (`@FLOATING`) is one whose input coin isn't pinned to a
specific coinid yet — it can attach to whichever coin ultimately carries the channel
state. **Precoins** let you pre-sign channel updates for coins that don't exist yet,
which is what makes off-chain ELTOO state exchange possible: you sign the *next*
state before the *current* one is even on-chain.

### Why it's safe / unsafe

- **Safe:** MAST dispute branches (section 4) at escalating deadlines mean either
  party can force settlement of the latest agreed state on-chain; sequence numbers
  ensure a stale state can't override a newer one.
- **Unsafe:** any `getaddress`-at-runtime address, or a channel over the ~1150-char
  size limit (the 343-MINIMA loss), or a missing `SAMESTATE` pin on the payout
  addresses/pubkeys, reintroduces a fund-loss path. Check `wc -c` on the main script
  plus MAST root before deploying.

---

## Covenant safety checklist

Before you fund a covenant or ship a change, walk this list:

- [ ] **Prove `parseok`** via the node's own `runscript` on the exact bytes, and
      confirm re-derivation to the funding address, BEFORE any coin moves.
- [ ] **Every reachable branch is `VERIFYOUT`-pinned** — no unguarded
      `SIGNEDBY … RETURN TRUE` on a coin holding funds.
- [ ] **Literals are canonical** (`stripTrailingZeros().toPlainString()`) and match
      any stored-state copy byte-for-byte.
- [ ] **No `/` gets JSON-escaped** into the script; test on the actual command path
      that funds will move through, not just a Python harness.
- [ ] **Grain rounding is pool/contract-favourable** — reserves UP, proceeds DOWN;
      all money math in `BigDecimal`/`decimal.js`, never floats.
- [ ] **Owner-key coins are excluded** from funding an anyone-can-spend transaction;
      sign with an explicit key, never `auto`, near covenants.
- [ ] **Output SHAPE verified offline** (`minima-vm` / `runscript` / `txncheck`) — not
      the `txnpost` result. `txnpost status:true` ≠ on-chain success.
- [ ] **Post-gate reads `valid.scripts`** (the verdict) with a truthy helper, not
      top-level `scripts` (a count).
- [ ] **Cold paths are MAST'd off** under the ~1150-char size limit, each with a
      precomputed MMR proof, each pinned and `SIGNEDBY`-gated from `PREVSTATE`.
- [ ] **All addresses come from `PREVSTATE`**, never `getaddress` at runtime.
- [ ] **`SAMESTATE` pins the whole immutable region** a counterparty must not rewrite.
- [ ] **`txndelete` on every path, including failures**, so a half-built transaction
      never leaks into the next operation.
- [ ] **Keep negative test vectors** (wrong-split settlement, rewritten proposition,
      under-funded fill, dust-pairing drain) and prove the chain rejects them.
- [ ] **On any spend failure, diagnose from data first**: `scripts address:X` →
      `runscript` → check `parseok`. Do not chase keys/keyuses/rebuilds.

---

## Official tutorials (canonical worked versions)

The Minima docs ship official, worked layer-1 and layer-2 tutorials that are the
canonical reference implementations for these patterns. Consult them for the reference
version; use *this* file for what breaks in production:

**Layer 1 (on-chain covenants):** basic-contract, coinflip, complex-multisig,
exchange-contract, flashcash, hashed-timelock-contract (HTLC), mast-contract,
mofnmultisig, multisig, multisig-multicoin, slowcash, thevault, time-lock-contract.

**Layer 2 (channels & scaling):** bi-directional-payments, coinflipv2, eltoo-channel,
eltoo-floating-coin, eltoo-full-sequence, eltoo-precoin, state-chains,
uni-directional-channel.

These cover multisig, HTLC, time-lock, vault, exchange, coinflip, ELTOO, and
state-chains as official worked tutorials — the canonical versions of the patterns
taught above.
