# Diagnostics & Recovery

The "something is wrong" runbook. Load this when a transaction failed, funds look stuck, a
covenant won't spend, or a node misbehaves. Every claim here comes from a real on-chain
failure. Sections go symptom → cause → fix, and point at the deeper reference file.

## First move: diagnose from data, not guesses

When a fund-critical operation fails — especially a covenant spend — the single most
expensive mistake is to start *guessing* causes and taking irreversible actions (restore
from backup, re-import keys, full seed-resync, stand up a second node) before you have read
the actual on-chain data.

A real case cost **hours** and an unnecessary seed-resync chasing a WOTS key-use / leaf
theory, when the true cause was readable in **seconds** from the exact stored script bytes.

The discipline:

1. **Get the runtime evidence first.** Read the real state — `scripts address:X`,
   `coins`, `history`, the node logs — before hypothesizing.
2. **Treat a discriminating clue as a precise signal.** "1000 works, 3000 fails" points
   straight at a size-dependent path (coin selection), not identity or balance. "It only
   happens on the new install" points at what that build changed.
3. **State confidence honestly.** "The trace proves X; I have no data on Y so I won't
   guess" beats another confident-but-wrong theory. If you can't tell from the data, go
   get the data.
4. **On likely fund loss, say so early.** "This is probably gone; one check to confirm"
   is kinder and cheaper than hours of false hope followed by the same conclusion.

For a failing covenant spend the very first command is **always**:

```
scripts address:<the covenant/script address>     # get the EXACT stored bytes
runscript script:"<those exact bytes>"             # does it even parse?
# check parseok in the response
```

If `parseok` is **false**, the coin is **permanently unspendable** — no key, keyuses, node
rebuild, or seed resync can help. Stop, and prevent it next time (prove `parseok` before
funding — see `references/transactions-utxo.md`). The node's local `keys` "uses" counter is
a local tally and is **unrelated** to why a spend is rejected — do not chase it.

---

## Script-FAIL taxonomy

A transaction that "posts fine" but never mines, or a `txncheck` returning
`valid.scripts:false`, has one of a few distinct causes. Tell them apart before acting.

### 1. Parse failure — `parseok:false` (the dead end)
The script the node stored does not parse, so **no branch can ever run** — not even an
owner-exit. The classic cause is a covenant literal containing `/` that a JSON quoter
escaped to `\/` (Java's `org.json.JSONObject.quote` does this; Python's `json.dumps` does
not — which is why an RPC/Python harness passes while the real app fails). The failure is at
parse/load time, so it fires regardless of which branch you intended to hit.

- **Diagnose:** `scripts address:X` → `runscript` the exact bytes → `parseok:false`.
- **Fix:** none — the coins are gone. Audit any sibling coins funded by the same buggy
  code. Quote scripts without escaping `/` (escape only `"` and `\`), and **prove `parseok`
  before funding** so a bad covenant aborts with nothing moved.

### 2. Wrong-address / canonical-literal mismatch
A covenant literal that differs by even one character from what a registry or discovery
beacon stored produces a **different script hash → a different address**. Reserves land at
one address; discovery re-derives another (empty) one. The pool looks "invisible."

- **Diagnose:** derive the address from both the canonical and the as-stored literal and
  compare. Node-normalized numeric forms (e.g. trailing zeros stripped) are the usual
  culprit.
- **Fix:** canonicalize every literal that is both baked into a covenant and stored for
  re-derivation (`stripTrailingZeros().toPlainString()`), so covenant, stored state, and
  re-derivation all agree.

### 3. Branch failure — script parses but `RETURN` is FALSE / no branch matched
The covenant ran and *refused*. Causes: wrong state values, the wrong signer, a keepstate
mismatch, or — most commonly — the transaction's **output shape doesn't match what the
covenant requires** (e.g. an app refreshing output to the contract address while the
covenant demands output to `PREVSTATE(1)`; that Script-FAILs silently while `txnpost`
returns `status:true`, so it can run "successfully" for weeks).

- **Diagnose:** verify the output **shape** offline against `minima-vm` (see
  `references/ecosystem-tooling.md`), not via the post result. Check every `VERIFYOUT`
  the covenant enforces against what your transaction actually produces.
- **Fix:** correct the output address/amount/tokenid/keepstate to satisfy every reachable
  branch's `VERIFYOUT`. See `references/contracts-covenants.md`.

### 4. "Script Missing from TxPoW for address 0x… → TxPoW FAILS Basic checks"
The coin's address is **not tracked on this node** — the untracked-coin problem, common on
megammr/fresh nodes. The coin is safe on-chain, just unspendable here.

- **Fix:** track it, then spend — see **Untracked-coin recovery** below and
  `references/node-operations.md`.

### 5. "TokenID … doesn't match token"
You rebuilt a token descriptor by re-serializing its JSON, which reordered keys → different
bytes → a different (wrong) tokenid.

- **Fix:** take the **byte-exact** token from the binary `coinexport` CoinProof; never
  reconstruct it from a JSON object.

---

## "txnpost said status:true but the coin never moved"

`txnpost status:true` means **accepted to the mempool**, not mined and not valid. A covenant
Script-FAIL is **silent**: the post succeeds, the transaction never mines, and the coin stays
put (while a naive app logs "success"). This is the single most misleading signal in Minima.

- **Confirm the real outcome** by re-querying `coins`/`history` for the spent input and the
  expected output — not by the post result.
- **`istransaction:false` on a `txnpost` return is asynchronous mining in progress, NOT
  failure.** Do **not** retry on it — retrying causes a re-post storm that races itself and
  stalls confirmation for minutes.
- `txnsign txnpostauto:true` returns a txpowid that is **not** the final on-chain id;
  resolve the real one after mining by matching the spent input coinids against `history`.

---

## Locked inputs & "insufficient funds" that shouldn't be

Once a coin is added to a transaction with `txninput`, it is **locked** to that pending
transaction. If the build fails partway and you don't clean up, the coin stays locked and
later spends fail with "insufficient funds" even though a balance clearly exists.

- **Diagnose:** `txnlist` shows pending transactions still holding inputs.
- **Fix:** `txndelete id:<txnid>` — and always run it on every error path of any manual
  build. See the post sequence in `references/transactions-utxo.md`.

Related UTXO-lock symptoms: a coin is locked until the previous spend of it confirms; two
simultaneous spends of the same coin cross and one fails (use a single-writer lock); and
change returns to a **fresh** address on every send, so never assume it came back to the
same address.

---

## Node returned empty (not an error) / oversized reply

A query whose reply exceeds the node's ~256 KB "results too long" stub comes back **empty**,
not as an error — so an unbounded `history` or `coins` scan silently yields nothing.

- `history` returns full txpow bodies (~14 KB each); `coins` has **no count cap**, only
  `depth:` (a time bound), so a dust-flooded public address can overflow.
- **Fix:** bound every scan — e.g. `history max:4 depth:400` — and use **adaptive paging**:
  start `max:8`, halve on any empty/over-limit/errored page (8→4→2→1), keep the smaller size.
- On native Android IPC an oversized reply can **kill the app uncatchably** (the Binder
  ~1 MB limit) — you must return less up front. See `references/native-android-ipc.md`.

---

## Untracked-coin recovery

Symptom: the coin is visible in `coins` (or via `coins megammr:true`) but any spend fails
with "Script Missing from TxPoW". `txnbasics` and `coinexport` read only the node's
**tracked** MMR/script DB; `coins megammr:true` returns coin *data*, not a spendable proof.

Fix, in order, before `txnbasics`/`txnpost`:

```
newscript trackall:true script:"RETURN SIGNEDBY(0x<your-pubkey>)"   # register your script
coinexport coinid:<FULL 66-char coinid>                            # pull the proof blob
#   a TRUNCATED coinid gives a false "Coin not found"
coincheck data:<blob>                                              # optional validate
coinimport data:<blob> track:true                                 # insert into tracked set
#   coin is now coins relevant:true → txnbasics has script + proof → spend broadcasts
```

For a **token** coin, rebuild the Token from the byte-exact `coinexport` CoinProof, never by
re-serializing the token JSON (see Script-FAIL #5). Balance display: for an untracked
address, `balance megammr:true address:X` shows `sendable:0` while `confirmed` holds the real
amount (`total` is the token *supply*) — display `confirmed`. Full runbook:
`references/node-operations.md`.

---

## Wallet & key symptoms

- **"signing failed: Public Key not found" right after a seed restore** — the node's keys
  are still regenerating asynchronously. Wait / ensure keys exist before signing; do not
  bulk-regenerate keys on launch (it triggers a key-creation and pending-approval storm).
- **`publickey:auto` can't sign a retired (hardened) address** — after you retire an address
  by nulling its script-row pubkey to `0x00`, `auto` no longer finds a key. Extract the real
  key from the script and pass it explicitly. See `references/key-security-wots.md`.
- **Address case mismatch (`0x…` vs `0X…`)** → silent `0` uses / a lookup that finds nothing.
  Normalize case before comparing addresses.
- **A spend from your own owner address unexpectedly trips a covenant's owner branch** —
  `txnsign publickey:auto` signed with the owner key. Exclude owner/pool addresses from
  funding and change selection.

---

## Reading-the-chain pitfalls

- **`coins relevant:true` is not a full ownership view.** It includes imported watch-only
  and anyone-can-spend covenant coins; `track:false` coins are absent. Ownership is
  per-coin — check the coin's own state/script, not just relevance.
- **State is a LIST** of `{port,type,data}`, never a map — always iterate to find a port.
- **`history difference` nets ALL tracked coins**, including imported covenants, so a real
  swap can net to `{0,0}` and look like a self-transfer. Recompute over your own
  `simple:true` addresses.
- **The archive retains coins, not witnesses.** Signatures/inputs/outputs of deep-history
  spends are discarded, so you **cannot** determine an old spend's destination from the
  archive alone; `txpow address:` only searches roughly the last ~13k blocks.
- **Don't poll `archive action:integrity`** (3+ minutes), and don't fire concurrent archive
  queries — they can OOM a bounded-heap JVM.

---

## Case study: the permanently-stuck covenant (why "prove parseok" exists)

A pre-fix build created a live pool whose on-chain covenant literal contained `*5/1000`,
which a JSON quoter had escaped to `*5\/1000`. The node stored the backslash literally, so
the script's `parseok` was **false**. Around **~200,000 MINIMA plus tokens** — the small
original reserves plus a later mistaken direct `send` of a large amount to that same dead
address — became **permanently unspendable**.

It was proven unrecoverable the hard way: on a backup-restored node holding the exact tracked
script, the correct keyuses, full megammr proofs, and a valid owner signature, `txncheck`
still returned `valid.scripts:false` and every `txnpost` was rejected — because the tracked
script does not parse. No key, keyuses, node rebuild, or seed can spend an unparseable
covenant.

The lesson is rule #7 of the skill: **never send funds to a derived script address without
first proving, via the node's own `runscript`, that the covenant `parseok == true`** (ideally
that it re-derives to the exact funding address too). A non-parsing script's coins are gone
forever; a parsing covenant with an owner branch is always owner-recoverable. Gate any
create/fund/migrate on `parseok` **before** building a transaction, and a bad covenant aborts
with nothing moved.

---

## Fast triage table

| Symptom | Most-likely cause | First command | Open |
|---|---|---|---|
| Covenant spend rejected / `valid.scripts:false` | Unparseable stored script (`\/` etc.) | `scripts address:X` → `runscript` → check `parseok` | `references/transactions-utxo.md` |
| `txnpost status:true` but coin never moved | Silent Script-FAIL or async mining | re-query `coins`/`history` for the input | `references/contracts-covenants.md` |
| "Script Missing from TxPoW" | Address not tracked on this node | `newscript trackall:true` → `coinexport` → `coinimport track:true` | `references/node-operations.md` |
| "TokenID doesn't match token" | Token rebuilt from re-serialized JSON | use byte-exact token from `coinexport` | `references/node-operations.md` |
| "insufficient funds" but balance exists | Inputs locked to a failed pending txn | `txnlist` → `txndelete id:X` | `references/transactions-utxo.md` |
| Query returns empty inexplicably | Reply exceeded the ~256 KB stub | re-run bounded: `history max:4 depth:400` | `references/native-android-ipc.md` |
| "Public Key not found" after restore | Keys still regenerating async | wait / ensure keys before signing | `references/key-security-wots.md` |
| App killed / node crash on a big query | Android Binder ~1 MB overflow | return less up front (`depth:`, per-token) | `references/native-android-ipc.md` |
| Covenant took the wrong (owner) branch | `auto` signed with the owner key | exclude owner/pool addresses from funding | `references/contracts-covenants.md` |
| Pool/covenant "invisible" | Literal differs from stored → different address | compare derived addresses; canonicalize literals | `references/contracts-covenants.md` |

---

## Hard lessons: backup, restore, and node health

### backup/restore sharp edges

- ★ **`backup` with no password is effectively plaintext: the default password is the literal
  string `minima`, which every Minima binary knows** — and the 24-hour auto-backup runs bare
  `backup`, so auto-backup nodes accumulate seed-bearing files protected by a universal
  constant. Always pass a real `password:`; treat backup files as seed-equivalent; make sure the
  app-private folder can't become a cloud upload (an `android:allowBackup` misconfiguration did
  exactly that once).
- ★ **`restore` has no rollback:** after the password check, a corrupt or truncated backup fails
  with the node already torn down and the chain/user DBs already overwritten in place. Pre-flight
  with the non-destructive `decryptbackup`, size-verify imported backup files (a short SAF copy
  fails much later as a misleading "Incorrect Password!"), and delete partial imports
  immediately. `restore` also never signals service shutdown — it returns "Restart Minima for
  restore to take effect!" with the node already down; don't wait for a shutdown event.
- **Auto-recovery guards for destructive commands:** never auto-resync while the mempool is
  non-empty (resync drops pending txns); at most one automatic attempt per 24 h, counted at
  START; commit the pending-operation flag BEFORE issuing the destructive command (process death
  must never look like success); classify failures by WHEN they occur — "Could not connect to
  Archive host" is pre-flight (safe to retry another host), "Error getting MegaMMR data" is
  thrown AFTER the node deleted its txpow/archive DBs (never auto-retry).

### Node health and the unbounded-growth chain

- **A node can be alive, on-chain, foreground-healthy — and useless.** Heap exhaustion presents
  as every companion app timing out at once while the node looks perfect. Diagnose from logcat
  on the node pid: count "Waiting for a blocking GC" (0–3 = startup; thousands = thrash), then
  read `Long monitor contention` for which lock. Measured: 47 s single-lock holds vs 30 s client
  timeouts.
- ★ **The unbounded-growth chain:** the txpow store's only DELETE excludes relevant rows, so rows
  once marked relevant are NEVER deleted; any relevant-set inflation (e.g. a tracked shared
  covenant address adopting strangers' coins) grows the store without bound. The fix that
  actually recovers the node is **`megammrsync action:resync`** (rebuilds the coin set from the
  wallet's real addresses) — a restart buys ~2 minutes; an index only makes the bloat
  survivable. Verified live: ~1.18 GB store / pinned 512 MB heap / 12,247 blocking GCs → 29 MB /
  132 MB / 0, in the same process.
- **Total disk is a BAD health trigger:** the archive area is SUPPOSED to grow (≈100,000 blocks
  ≈ 50 days retained, hard-coded) — only txpow table size/row count diagnoses the resync-fixable
  pollution. `adb shell dumpsys diskstats` is a stale cached snapshot; measure from the node
  itself (`status complete:true` → memory.disk / memory.files.*).
- **`status complete:true` throws NPEs during node startup** (first on the wallet seed row, then
  a null chain tip). Pollers must tolerate and retry; gate on the node's startup-complete
  signal — an existing node instance is not a ready node.
- **Health checks: loud when healthy, honest when failing.** Log the OK line every check (silence
  is indistinguishable from never-ran); require verdicts to dwell (e.g. 10 min both directions);
  claim the debounce slot only AFTER a sample is taken; re-baseline when the wall clock jumps
  backwards. Calibrate thresholds from measured healthy baselines, never guesses (a 60/hr
  blocking-GC alarm would have nagged healthy nodes running ~25/hr).

### Verifying fixes and infrastructure

- ★ **When a fix "didn't deploy", unzip the artifact and check the bytes before doubting the
  fix.** Real traps: a fat-jar whose classpath resolved only inside a closure shipped stale
  bytes under a new version number with every check green; a mis-sorted jar name made the deploy
  script redeploy the old build. Verify the RUNNING version, never the deploy banner.
- **Verify infrastructure from OUTSIDE:** `systemctl is-active` proves nothing — attach two real
  clients and make them talk. One failed probe right after a cloud-firewall change proves
  nothing (rules take minutes); `tcpdump` on the box while connecting from outside is decisive
  (no packets = dies upstream; SYN in, no SYN-ACK out = the box drops it). Ship a `--selftest`
  that separates "binary broken" from "port unreachable".
- **Make failure visible before fixing it:** swallowed exceptions in fan-out/lookup/resend
  created a 15-minute blind window; every total failure must name the peer, the address tried,
  and the transport's answer. Beat-matched logs (sender beats vs receiver stamps, to the second)
  are what distinguish "delivery failed" from "the receipt was lost".
- **A regression test that passes with the bug re-injected guards nothing** — drive the actual
  fix site: re-inject the bug, watch red, then fix. A wrong lock SCOPE is invisible to
  single-threaded tests (per-instance locks over shared files double-reserved one-time signing
  keys): fund-critical counters need one process-wide lock plus an OS file lock, raise-only.
- **A block explorer is a lead, never proof** — one production explorer was missing ~93% of
  blocks with numbers off by tens of thousands. Confirm settlement against a canonical
  archive/MegaMMR source.
- **Low CPU + long wall time + only DB files open = full-table-scan thrash**, not a network
  problem. Demand covering indexes (`EXPLAIN QUERY PLAN` must say COVERING INDEX); use
  `address = ?`, never `lower(address) = ?` (the function defeats the index). Measure DB fixes
  by pages read (`EXPLAIN ANALYZE`), not wall clock on a warm developer SSD — and know H2 won't
  use an index for a bare `ORDER BY … LIMIT` without a WHERE (an added `WHERE timemilli > 0`
  looks redundant and is load-bearing).
- **Known upstream sharp edges:** the H2 LOB-cleaner thread can be interrupted by the node's
  30-minute DB reopen cycle and kill the whole process (an unhandled MVStoreException — check
  the crash buffer when a node "restarts itself"); H2 2.4.240's PBKDF2 fails ART's bytecode
  verifier on some OEM builds (VerifyError at boot the moment a password-protected DB opens) —
  pin H2 2.1.214 on Android; H2 date arithmetic reads a bare number as DAYS
  (`CURRENT_TIMESTAMP - 604800` = 604,800 *days*, so the purge never matched and a log table
  grew forever — use `DATEADD('SECOND', -n, …)` and prove the purge against the exact H2 jar the
  node ships); and two node lineages have mutually unreadable DB formats (H2 MVStore 2 vs 3)
  where the newer engine *wipes* SQL databases on a format clash — never point two node versions
  at one data folder.
