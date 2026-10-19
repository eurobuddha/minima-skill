---
name: minima
description: "Use when building on or operating the Minima blockchain — writing KISS VM scripts and covenants, building MiniDapps (MDS), constructing manual UTXO transactions, creating tokens/NFTs, setting up or restoring a node, Maxima messaging, connecting nodes over the keets Hyperswarm/DHT transport, integrating a native Android app, or diagnosing a failed/stuck transaction. An on-chain-proven reference with the fund-critical gotchas up front; routes to per-domain reference files."
---

# Minima

Minima is a **complete, decentralized blockchain that runs as a full constructing-and-validating node on a phone**. There are no miners and no staking: every user runs a node, and every transaction carries its own small proof-of-work (**TxPoW** — transaction and proof unified). Old blocks compress into a **cascading chain**, and coins live in a **Merkle Mountain Range (MMR)** proof database so a node can validate spends without storing the whole chain. The native coin is MINIMA (tokenid `0x00`); anyone can issue coloured tokens and NFTs.

On top of the base chain sit three things this skill covers in depth: **KISS VM**, a deliberately simple, loop-free on-chain scripting language that guards coins (Minima's "smart contracts" are spending **covenants**); **MDS (the MiniDapp System)**, an app runtime built into every node that serves web MiniDapps and exposes a `MDS.cmd`/SQL/comms API; and **Maxima**, an off-chain end-to-end-encrypted messaging layer that runs over the node network. A fourth, newer layer is **keets** — a second transport that connects nodes over Hyperswarm/HyperDHT (the Keet/Holepunch stack), making any node (phones behind CGNAT included) dialable by public key, and adding P2P media hosting (`keets://` URLs) and pubkey messaging on top.

Everything in this skill is grounded in on-chain-proven experience (node v1.0.47–1.0.48 era) plus the official docs. Minima is **quantum-safe** because it signs with **WOTS+ one-time keys** — and that single fact is the root of most of the fund-losing traps below, so read the rules before you write anything that signs or holds funds.

---

## CRITICAL RULES

These are the mistakes that lose or lock real funds. `★` = has caused on-chain fund loss; `★★` = permanent, unrecoverable loss. Load the linked reference for the full treatment.

### Writing scripts (KISS VM)
1. **No underscores in KISS variable names** — the parser fails silently. Keep names short (script size is tight — see rule 2).
2. **Scripts silently fail over ~1200 characters** (hard VM limits: 1024 instructions, 64 stack depth, 32 params, 0–255 state ports). Minify names and move rarely-used branches into **MAST** cold paths.
3. **Time with `@COINAGE` against a stored duration, not `@BLOCK`** (older docs write the global as `@BLKNUM`) — absolute block-height checks are unreliable across synced nodes. Note `txncheck` cannot evaluate `@BLOCK`/`@BLOCKMILLI`/`@COINAGE`.
4. **`AND OR XOR NAND NOR` are BOOLEAN, not bitwise** (the symbol operators `& | ^ ~ << >>` are the bitwise ones, and require HEX operands). **`NUMBER()` overflows on 32-byte hex** — take a slice first, e.g. `SUBSET(0 4 h)` (SUBSET is `(start end hexdata)`).
5. **Match keepstate to intent:** `VERIFYOUT(... TRUE)` + `txnoutput ... storestate:true` for phase transitions that must carry state forward; `(... FALSE)` + `storestate:false` for final payouts. A mismatched pair is silently rejected.
6. ★ **Cardinal covenant rule: every reachable branch must pin its outputs with `VERIFYOUT`.** An unpinned `SIGNEDBY(...) RETURN TRUE`-style path on a fund-holding coin let ~5,000 MINIMA be drained on-chain — the MDS permission model shares wallet-key access across all WRITE apps, so "only the owner can call it" is not a defence. → `references/contracts-covenants.md`

### Funding & posting script addresses
7. ★★ **Prove `parseok` BEFORE funding any script address.** Run the exact bytes the node will store through `runscript`/`newscript` and require `parseok:true`. A coin at an unparseable-script address is **permanently unspendable** — no key, resync, or node rebuild recovers it. A literal containing `/` that Java's `JSONObject.quote` escaped to `\/` cost ~200,000 MINIMA + tokens on mainnet. Python's `json.dumps` does *not* escape `/`, so test the **real** code path, not an RPC/Python harness. → `references/diagnostics-recovery.md`
8. ★ **Diagnose from data, not guesses.** When a covenant spend fails, FIRST do `scripts address:` → `runscript` the exact bytes → check `parseok`, before touching keys, keyuses, or node state. The local `keys` "uses" counter is unrelated to why a spend is rejected.
9. ★ **`txnpost status:true` ≠ on-chain success** — it means accepted to the mempool only. Invalid transactions (e.g. a covenant Script-FAIL, or a state-stripping spend) "succeed" then silently never mine. Confirm from chain state (`coins`/`history`), never from the post result.
10. **`txncheck`: the verdict is boolean `valid.scripts`**; the top-level `scripts` is a COUNT of distinct input scripts. Gate a post on `valid.scripts && validamounts && valid.mmrproofs`, and use a `truthy()` helper — these flags come back inconsistently as bool / int / string.
11. ★ **Owner-key auto-sign trap:** funding an anyone-can-spend covenant transaction from a coin at your own owner address makes `txnsign publickey:auto` add the owner signature → the covenant takes its owner branch. Exclude owner/pool addresses from funding and change selection.
12. **Post sequence is `txnsign → txnbasics → txnpost`** — sign BEFORE basics, never combined; never `txnpost auto:true` for script-address coins; never combine `scriptmmr:true` with `txnbasics`; always `txndelete` on any error path or the input coins stay locked. → `references/transactions-utxo.md`
13. **Canonicalize any literal baked into a covenant** and also stored for re-derivation (`stripTrailingZeros().toPlainString()`) — a one-character difference yields a different script hash, a different address, and an "invisible" empty pool.

### Amounts & tokens
14. ★ **A token coin's real value is `tokenamount`; `amount` is coloured dust (~1e-37).** `c.amount || c.tokenamount` is a BUG (amount is always present). MINIMA (`0x00`) has no `tokenamount` — its `amount` is the value.
15. ★ **Every token amount is FLOORED to the token grain (10^-decimals).** When a covenant pins an output, quantize: reserves round UP, proceeds/change DOWN. MINIMA is full 44-dp. Tokens can never be burned (per-tokenid in==out); only MINIMA can.
16. **State is per-TRANSACTION, not per-output**, and is a LIST of `{port,type,data}` (iterate — never a map); set unused ports to 0. The TxPoW hard cap is 64 KB ≈ 3 token-carrying outputs + 1 signature per transaction.
17. **`history` `difference` nets ALL tracked coins**, including imported anyone-can-spend covenants — recompute wallet nets over your own `simple:true` addresses.

### Keys, restore & node state
18. ★★ **WOTS signatures are ONE-TIME.** On any restore/resync, set `keyuses` HIGHER than the true prior signature count — the node regenerates keys at `uses=0` and cannot know how many leaves were spent. Too low → it re-issues spent leaves → the key becomes recoverable and funds are stealable. → `references/key-security-wots.md`
19. **Seed restore / fast sync = `megammrsync action:resync`** (seconds), NEVER `archive action:resync` (hours). → `references/node-operations.md`
20. **An untracked coin is unspendable even when visible** ("Script Missing from TxPoW"): `newscript trackall:true` → `coinexport coinid:<FULL 66-char id>` (a truncated id gives a false "Coin not found") → `coinimport track:true`, then spend. Rebuild a token from the byte-exact `coinexport` blob — re-serializing the token JSON reorders keys → wrong tokenid → rejected.
21. **`getaddress` rotates through the node's 64 permanent keys** — a different one each call. Persist ONE chosen identity; test "is this coin mine" against all 64 keys from `keys`. In covenants, take addresses from `PREVSTATE`, never `getaddress` at runtime.

### Apps & runtime
22. **`txnpost` mines asynchronously** — `istransaction:false` at return is NOT failure; retrying on it causes a re-post storm that races itself and stalls confirmation.
23. ★ **Bound every heavy query.** `coins` has no count cap (only `depth:`); `history` returns full ~14 KB txpow bodies. Three distinct size limits exist: the node RPC's 256 KB "too long" stub (catchable — comes back EMPTY, not an error), an Android app-side ~256 KB receiver cap, and the native Binder ~1 MB (an UNCATCHABLE process kill). Use adaptive paging (`max:8`→4→2→1). → `references/native-android-ipc.md`
24. **`service.js` is ES5-only** (Nashorn/Rhino: no `let`/`const`, arrow functions, `async`/`await`, `Promise`, `Set`, template literals) — any of them silently prevents the daemon from starting. Page and service share ONLY SQL; SQL columns return UPPERCASE; H2 `varchar(1024)` silently truncates (use `text`); validate every `MDS.cmd` hop; `newaddress` keys regenerate asynchronously after a restore. → `references/mds-development.md`

### Signing, evidence & recovery (from production wallets)
25. ★★ **One seed, one signer.** Two processes signing the same classic WOTS keys with independent `uses` counters reuse leaves and leak private keys (~1,146 addresses leaked on-chain this way). Delegate signing to the node, or reserve-before-sign atomically at the node; never `keys action:list` → sign locally. → `references/key-security-wots.md`
26. ★ **Confirm with evidence, never inference.** Input absence ≠ confirmation (poll the exact expected output); `history` ≠ chain inclusion (use `txpow onchain:<id>` — it only searches ~20 hours back); never infer failure from a timeout or absence (keep UNKNOWN outcomes reserved); a positive post reply without a 64-hex TxPoW ID is malformed, and the mined ID can differ from the returned one. Persist intent and reserve inputs BEFORE signing. → `references/transaction-evidence.md`
27. ★ **`backup` without `password:` is encrypted with the literal default `minima`** (the 24-hour auto-backup runs bare) — treat backup files as seed-equivalent. **`restore` has no rollback** (DBs overwritten in place before a corrupt file fails): pre-flight with `decryptbackup`. → `references/diagnostics-recovery.md`
28. ★ **Every command string is an injection surface.** The node tokenizer has no escape character, whitespace-splits with last-wins semantics, and executes every `;`-separated segment while returning only the first result — an allow-list validating only the first verb is a fund drain, and a pasted "address" can inject `burn:`. Validate untrusted values before a command string exists. → `references/native-android-ipc.md`

---

## Which reference to load

| If you are… | Load |
|---|---|
| Understanding how Minima works — TxPoW, cascade, MMR, consensus, tokens, node types | `references/protocol-architecture.md` |
| Writing or reading any KISS script — grammar, functions, globals, limits, MAST, testing | `references/kissvm-language.md` |
| Designing a covenant — multi-phase state machine, AMM, HTLC swap, NFT, orderbook DEX, escrow, payment channel | `references/contracts-covenants.md` |
| Building or posting a manual transaction; creating tokens; reading coin JSON and amounts | `references/transactions-utxo.md` |
| Looking up a wallet / coin / token / txn / script / crypto command's syntax | `references/commands-wallet-transactions.md` |
| Looking up a node / network / backup / archive / megammr / maxima command's syntax | `references/commands-node-network.md` |
| Building a MiniDapp — mds.js, events, SQL, file ops, comms, `service.js`, TS/React, production gotchas | `references/mds-development.md` |
| Installing, running, restoring, resyncing, or hosting a node; private testnet; MEG | `references/node-operations.md` |
| Anything touching seed phrases, keyuses, signing, or key reuse | `references/key-security-wots.md` |
| Integrating a native (non-MDS) Android app over broadcast-Intent IPC | `references/native-android-ipc.md` |
| Doing off-chain, encrypted messaging between nodes | `references/maxima.md` |
| Running a node over Hyperswarm/DHT, P2P media hosting (`keets://`), pubkey messaging, the `keets` command / `KEETS` MDS event | `references/keets.md` |
| Packaging and shipping a MiniDapp — `.mds.zip`, `dapp.conf`, app stores, sandbox, IPFS | `references/distribution-packaging.md` |
| Mapping the ecosystem, querying a block explorer, or testing scripts offline (minima-vm) | `references/ecosystem-tooling.md` |
| A transaction failed, coins look stuck, a covenant won't spend, or a node misbehaves | `references/diagnostics-recovery.md` |
| Building a wallet/financial app — receipts, chain-inclusion proof, durable journals, async-callback hygiene, burn traps, the sendnosign family | `references/transaction-evidence.md` |

---

## Quickstart

Run a Minima node (Java 17+; the node is one jar):

```bash
# Public mainnet node with RPC and the MDS app runtime enabled
java -jar minima.jar -mdsenable -rpcenable
#   P2P/Minima on 9001, MDS web UI on 9003 (base+2, https, self-signed cert), RPC on 9005
```

Isolated private chain for development (no peers, instant genesis, 1-billion-MINIMA faucet):

```bash
java -jar minima.jar -data ~/mdev -nop2p -test -genesis
#   add -solo to auto-mine ~1 block / 15s — poll `balance`; do NOT self-send to advance the chain
```

Then drive it from the terminal / RPC / MDS (all three run the same commands):

```bash
runscript script:"RETURN SIGNEDBY(0xFF)"        # try a KISS script (parseok/clean check)
newaddress                                       # a fresh receive address
balance                                          # what the node holds
```

First MiniDapp: a `.mds.zip` needs `dapp.conf` (name/version/permission) as the FIRST zip entry, plus `index.html` and optionally a `service.js` daemon — see `references/mds-development.md` and `references/distribution-packaging.md`.

---

## Facts that supersede older docs

Some circulating notes are stale. Where they conflict, these win:

- **The 256 KB response limit is app/RPC-side, not the core jar.** The node RPC has a catchable "results too long" stub (returns empty); native Android has a separate app-side receiver cap; the only uncatchable one is the Android Binder (~1 MB). A fork lifts the app-side cap via a `content://` FileProvider hand-off.
- **The multi-phase "casino" contract is a PATTERN reference, not a shipped product.** The live productization of that style is a prediction-market / wager covenant.
- **A block explorer's indexer height can run ahead of canonical chain height** (observed ~20k blocks higher) — treat explorer height as advisory and trust your own node's `block`.
- **There are two different "explorers":** the hosted one at `explorer.minima.global` has a tRPC backend (a plain WebFetch of its `/transactions/<hash>` pages false-negatives because it is a client-hydrated SPA — use the tRPC endpoint or the node's own `txpow` command); a "simple explorer" is purely client-side against the visitor's own node and has no queryable backend.

---

*Shareable under MIT. Sources: the official Minima docs (docs.minima.global) and original on-chain research and incident analysis.*
