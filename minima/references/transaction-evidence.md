# Transaction evidence & wallet-app engineering — hard lessons

Lessons from building and reviewing many production wallet, NFT, DEX, pool and shop apps on
Minima. Everything here was learned from a real bug, a failed review finding, or verified node
bytecode. The theme: **a Minima app must treat every node reply as evidence to validate, never
as a verdict to trust** — and must persist its own intent durably before it signs anything.

---

## 1. What a post result actually is

- **`txnpost` returns `TxPoW.toJSON()`** — the top-level `txpowid` is the transaction's ID, the
  transaction state is at `body.txn.state`, output `tokenamount` is a **string**, and
  `storestate`/`spent` are **Booleans**. Output coinids are derived from the first input plus
  the output index.
- ★ **A positive reply without a transaction ID is malformed, not success.** `status:true` with
  no response body or a missing/empty TxPoW ID has been observed; a strict receipt predicate
  (typed Boolean status + 64-hex-character TxPoW ID) must gate anything that advances state.
- ★ **The mined TxPoW ID can differ from the returned one.** `sendpost`/`txnpost` return the
  TxPoW *before* asynchronous mining, and mining changes the TxPoW ID (`txnbasics` calculates
  it; `txnlist` returns the named row's transactionid). If the returned ID never gains chain
  proof, search bounded `history` pages for the **exact saved transaction** (full input/output
  match) rather than concluding failure.
- **`txncheck` on newer nodes** returns `valid.signatures` as an **array** plus
  `allsignaturesvalid` as the aggregate boolean — gate on the aggregate, not the array.

## 2. Proving a transaction actually happened (or didn't)

- ★ **Input absence is NOT confirmation.** "My input coin is gone" can mean anything. Confirm by
  polling the **exact expected output**: correct coinid, destination (match `miniaddress`
  exactly for Mx forms, then use the receipt's canonical hex address on-chain), tokenid,
  `tokenamount`, `storestate`, unspent status, and preserved state. A missing list, malformed
  row, `status:false`, or empty reply can never display success.
- ★ **`history` is not proof of chain inclusion** — it returns TxPoWs relevant to you, including
  ones that never made it. For inclusion use **`txpow onchain:<txnid>`** and require ALL of:
  Boolean `status`/`found`, a **nonzero 32-byte hex block ID**, a positive block height, and
  `tip − block == confirmations`; treat depth ≥ 3 as the usual settlement bar
  (`GlobalParams.MINIMA_CONFIRM_DEPTH`). A cached history row's block number is display data,
  not confirmation.
- ★ **Never infer failure from a timeout, elapsed time, absence from history, or a
  still-unspent input.** All four have produced false "failed" verdicts followed by double
  spends/retries. An uncertain outcome stays **UNKNOWN** — keep the reservation, surface it, and
  resolve only with receipt + inclusion evidence.
- ★ **Never schedule `txndelete` from a timeout** — signing/posting may still be executing and
  the delete races it. Delete only on a *definite* build-stage rejection.
- **Confirmed output spent onward before your first poll** cannot be proven by an unspent
  lookup; inclusion proof of the original transfer is what settles it.

## 3. The durable-journal pattern (what reliable wallets converged on)

Every financial flow that survived review follows the same shape:

1. **Freeze and validate the public intent** (inputs, outputs, token, amounts, burn) from the
   values the user actually reviewed — never re-read mutable UI/selection state later.
2. **Persist the intent and reserve the exact input coinids atomically** (one SQLite
   transaction) *before* building or signing. If the write fails, the flow stops.
3. Commit a **POSTING** marker before `txnpost`/`sendpost`. After this point any ambiguous error
   keeps the reservation — it is evidence of a possible broadcast.
4. Save the **strict receipt** before reporting POSTED; commit receipt + inclusion evidence +
   visible status **in one transaction** when confirming.
5. On restart, an earlier process's PREPARED attempts become NOT_SUBMITTED explicitly; recovery
   is **read-only** (bounded history scans — e.g. 4-entry pages, 4-page batches, an
   oversized-response shrink path, capped polling such as 20 × 20 s) and never re-signs or
   replays automatically.
6. Different flows sharing coins (quick send, consolidation, custom sends) must check each
   other's reserved input IDs **in the same database transaction** so two attempts can never
   claim the same coin.

## 4. Burn traps

- ★ **Duplicate burn:** passing a burn parameter to the post step asks the node to build a
  **separate** burn transaction. If your builder already reserved the burn inside the selected
  inputs, the user is charged twice. Subtract burn in your own change OR delegate it, never
  both.
- **`sendnosign` deliberately disables burn signing** — you cannot obtain an unsigned
  token-burn plan from it (the signed `send` dryrun path may sign a separate token-burn
  transaction). Plan token burns as explicit Minima inputs in your own construction.
- **`sendnosign` divides each amount by `split` with no rounding remainder** (unlike `send`,
  which constructs a remainder output). For non-divisible amounts use `split:1` with an
  explicit `multi` list of exact outputs. Token amounts need known precision (0–44 decimals);
  if precision is unavailable, refuse rather than guess.

## 5. The unsigned-send command family

`sendnosign → sendview → sendsign → sendpost` is the node-native way to build, inspect, sign
and broadcast without hand-rolling txn construction:

- `sendnosign` writes an unsigned transaction file using **native coin selection and
  wallet-owned change** — validate the unsigned plan (recipient, exact amounts, token, change
  addresses) before signing.
- `sendsign` signs the main (and burn) transactions and writes the resulting file **without
  broadcasting**; `sendview` verifies a file's contents.
- `consolidate tokenid:0x00 ... dryrun:true` returns the node's native consolidation selection
  without signing or posting — validate a frozen copy (every output a default wallet address),
  then reserve those inputs through your own journal before executing.
- **Validating "this change address is mine":** `checkaddress relevant:true` also counts
  **watched** scripts, so it does NOT prove ownership. Query `scripts address:<addr>` and
  require `default:true`, `simple:true` and a public key. A simple wallet script is **exactly**
  `RETURN SIGNEDBY(<pubkey>)` — compare the whole script, never `contains(pubkey)` (a hostile
  script can embed your pubkey).

## 6. Async-callback hygiene (where wallet bugs actually live)

The single most repeated review finding across every app, in several disguises:

- ★ **A delayed node reply must not act on state that changed since the request.** Late
  `getaddress` responses overwriting a hand-edited change-address field; a reviewed send
  submitting a *different* token because submission re-read live selection; image/mode fields
  read only after `getaddress` returned, minting unreviewed content. The fix is always the
  same: **capture/freeze the reviewed values when the user approves, tag each request with a
  generation/owner token, and drop stale callbacks** (manual edits and newer requests
  invalidate older ones).
- Build the full command string **before** the first async hop, not after.
- **Strict reply validation before mutating anything:** reject null, missing/false/string
  `status` (require `Boolean.TRUE` — some paths return status as a string), non-array where an
  array is expected, malformed rows, duplicate IDs, and mismatched tokens. A failed or
  malformed balance/coin read must **preserve** existing state — never clear listings,
  collections or caches on a failed read, and never let an empty reply "confirm" emptiness.
- ★ **Command injection:** token IDs, addresses and amounts get concatenated into node command
  strings. Validate them first (hex grammar, no whitespace/semicolons/command syntax) — a
  "token id" of `0x00;vault` is a command. Reuse one strict gate everywhere.
- **Bound every render of node data.** Synchronously rendering unbounded persisted output
  (e.g. a logs view reading every stored event into one text widget) has crashed both app and
  embedded node. Page it.
- **History pagination:** advance with the node's own `offset + rows-returned`, never your
  accumulated *filtered/stored* row count — filtering non-transactions desynchronizes the
  offset and silently skips pages. Validate whole pages; a failed page must not be skipped as
  if empty.

## 7. Token metadata is polymorphic

A token's `name` field may be a plain string, a JSON **string** containing serialized JSON, or
a nested/enveloped object (with `name`, `url`, icon fields, collection metadata). Apps that
treated it as a literal label lost icons and crashed on nested forms. Parse all shapes the way
the core wallet's TokenMeta does (object → fields; string → try JSON decode → fields; else
literal), keep genuinely plain names literal, and take the token's identity from the **outer**
node `tokenid`, ignoring any tokenid claimed inside metadata. Display fallback for a missing
name: the token ID itself (in full, copyable).

## 8. Protecting seeds and reports in app UIs

- Seed/passphrase dialogs need `FLAG_SECURE`, cleared text on pause, and disabled text
  selection — and a host app's global screenshot policy can silently clear `FLAG_SECURE` on
  resume, so sensitive screens must re-assert it.
- **Quote untrusted text before composing it into reports.** Node errors, backup notes and
  imported addresses can contain line breaks that masquerade as your app's own report lines
  (a classic injection). `JSONObject.quote` is reversible and sufficient; keep valid hex
  addresses literal.
- Backup containers deserve strict schema validation: duplicate field/index rejection, exact
  nonnegative integer counters, UTF-8 validation, size bounds, fixed salt/nonce/tag sizes and
  a KDF iteration cap. Distinguish "valid payload, counters temporarily unavailable" (retry)
  from "damaged backup" (refuse) — mislabeling the first as the second makes users discard
  good backups.
