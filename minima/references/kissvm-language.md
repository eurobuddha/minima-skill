# KISS VM Language Reference

The complete reference for KISS VM — Minima's on-chain smart-contract scripting language. Every function, global, and limit below is verified against the Minima node source (`org.minima.kissvm`) and the official in-node tutorial (`tutorial` command). Where published docs and the actual VM disagree, this file follows the source and says so.

---

## KISS gotchas

Read these before writing a single line. Each one has burned real developers on real chains.

- **NO underscores in variable names.** Variables are `[a-z]+` — lowercase letters ONLY. `player_pick` does not throw a helpful error; the script silently fails to parse/execute. Use `playerpick`, `pp`, `hpk`.
- **~1200-character script size limit (undocumented).** Scripts larger than roughly 1200 characters are silently rejected on-chain — no error, the transaction just never validates. Minify variable names to 2–3 chars and move rarely-used branches into MAST.
- **Use `@COINAGE`, not `@BLOCK`, for timing.** Relative timelocks via `@COINAGE GT n` are reliable everywhere. Absolute `@BLOCK` deadlines have proven unreliable on some synced nodes, and `txncheck` cannot evaluate `@BLOCK`/`@COINAGE` at all (they depend on the block the tx lands in). Store a timeout duration in state and compare against `@COINAGE`.
- **Word operators are boolean; symbol operators are bitwise-on-HEX.** `AND OR XOR NAND NOR NXOR` operate on TRUE/FALSE only. The symbols `& | ^ ~ << >>` are bitwise, but **both operands must be HEX values** — they do not work on numbers. `5 XOR 3` is not bitwise math; `0x05 ^ 0x03` is.
- **`NUMBER()` on a 32-byte hash overflows.** Never `NUMBER(SHA3(x))`. Truncate first: `NUMBER(SUBSET(0 4 h))` takes the first 4 bytes.
- **`SUBSET` is `(start end hexdata)` — numbers first, and the second number is an END index, not a length.** Some older docs describe `SUBSET(HEX start length)`; the actual VM reads param 0 = start, param 1 = end (exclusive), param 2 = the hex data. `SUBSET(0 4 h)` = first 4 bytes of `h`. Same shape for `SUBSTR(start end string)`.
- **Reading an unset state port crashes the script.** `STATE(n)` / `PREVSTATE(n)` on a port that was never set throws an execution error → script returns FALSE. Set every port your script might read (use `0` for unused), or guard the read behind a phase check that guarantees the port exists.
- **Scripts default to FALSE.** If execution falls off the end without `RETURN TRUE`, the coin cannot be spent. Every valid path must explicitly `RETURN TRUE`.
- **Scripts are case sensitive.** Keywords and function names are UPPERCASE, variables lowercase.
- **`VERIFYOUT` keepstate must match the output's `storestate`.** Phase transition (coin recreated at the script address, carrying state): `VERIFYOUT(... TRUE)` + `txnoutput ... storestate:true`. Final payout to a wallet: `VERIFYOUT(... FALSE)` + `storestate:false`. A mismatch silently invalidates the transaction.

---

## 1. Overview & philosophy

KISS = **K**eep **I**t **S**imple **S**tupid. The VM is deliberately minimal:

- **UTxO model.** Like Bitcoin, not Ethereum. Every coin (Minima, custom token, or NFT) is locked by a script. A script is a pure predicate: it runs when the coin is used as a transaction **input** and must return **TRUE** for the spend to be valid. The default is FALSE.
- **Deterministic and bounded.** Hard instruction cap (1024), hard stack depth (64), no unbounded loops in practice (`WHILE` exists but is subject to the instruction cap — every iteration costs instructions). Every full node re-executes every script; scripts must be cheap.
- **No global chain state.** A script sees only its own transaction: its input coin, the other inputs/outputs, the transaction's state variables, and the coin's stored (previous) state. Minima uses per-coin state in the MMR proof database rather than a global state trie — this is what makes contracts inherently Layer-2 compatible.
- **Human-readable.** Scripts are plain UTF-8 text, not bytecode. The address of a script is the hash of its cleaned text — `ADDRESS(script)` / the `newscript` command give you the `0x...` address coins are sent to.
- **Two scripts must pass.** When spending a token/NFT coin, both the coin's address script AND the token's own token script must return TRUE. A plain token has `RETURN TRUE` as its token script.

The default lock on an ordinary wallet coin:

```
RETURN SIGNEDBY(0xFFEEDDCCBBAA99887766554433221100FFEEDDCCBBAA99887766554433221100)
```

— TRUE only if the transaction carries a valid signature from that public key.

---

## 2. Value types

KISS has four value types. There are no type declarations; values are typed by literal form and functions are strict about what they accept.

| Type | Literal form | Notes |
|---|---|---|
| **NUMBER** | `0`, `42`, `3.14`, `-5` | Arbitrary-precision decimal (MiniNumber). Full decimal math, no wrap-around. |
| **HEX** | `0xFFEE01` | Raw bytes. Addresses, public keys, coinids, tokenids, hashes. Max 64 KB. |
| **SCRIPT** (string) | `[hello world]` | UTF-8 string, written in square brackets inside scripts. Also how you embed a script-as-data (for `EXEC`, `ADDRESS`, `FUNCTION`). Max 64 KB. |
| **BOOLEAN** | `TRUE`, `FALSE` | The only values a script may ultimately RETURN. |

Truthiness: `FALSE` is 0; `TRUE` is anything not FALSE (`BOOL()` converts explicitly). Don't rely on implicit coercion — convert with `BOOL`, `NUMBER`, `HEX`, `STRING`.

---

## 3. Official grammar

From the node's built-in tutorial (authoritative):

```
ADDRESS     ::= ADDRESS ( BLOCK )
BLOCK       ::= STATEMENT_1 STATEMENT_2 ... STATEMENT_n
STATEMENT   ::= LET VARIABLE = EXPRESSION |
                LET ( EXPRESSION_1 EXPRESSION_2 ... EXPRESSION_n ) = EXPRESSION |
                IF EXPRESSION THEN BLOCK
                  [ELSEIF EXPRESSION THEN BLOCK]* [ELSE BLOCK] ENDIF |
                WHILE EXPRESSION DO BLOCK ENDWHILE |
                EXEC EXPRESSION |
                MAST EXPRESSION |
                ASSERT EXPRESSION |
                RETURN EXPRESSION
EXPRESSION  ::= RELATION
RELATION    ::= LOGIC AND LOGIC | LOGIC OR LOGIC | LOGIC XOR LOGIC |
                LOGIC NAND LOGIC | LOGIC NOR LOGIC | LOGIC NXOR LOGIC | LOGIC
LOGIC       ::= OPERATION EQ OPERATION | OPERATION NEQ OPERATION |
                OPERATION GT OPERATION | OPERATION GTE OPERATION |
                OPERATION LT OPERATION | OPERATION LTE OPERATION | OPERATION
OPERATION   ::= ADDSUB & ADDSUB | ADDSUB | ADDSUB | ADDSUB ^ ADDSUB | ADDSUB
ADDSUB      ::= MULDIV + MULDIV | MULDIV - MULDIV | MULDIV % MULDIV |
                MULDIV << MULDIV | MULDIV >> MULDIV | MULDIV
MULDIV      ::= PRIME * PRIME | PRIME / PRIME | PRIME
PRIME       ::= NOT PRIME | NEG PRIME | ~PRIME | BASEUNIT
BASEUNIT    ::= VARIABLE | VALUE | -NUMBER | GLOBAL | FUNCTION | ( EXPRESSION )
VARIABLE    ::= [a-z]+
VALUE       ::= NUMBER | HEX | STRING | BOOLEAN
NUMBER      ::= ^[0-9]+(\.[0-9]+)?
HEX         ::= 0x[0-9a-fA-F]+
STRING      ::= [UTF8_String]
BOOLEAN     ::= TRUE | FALSE
```

### Statements

**`LET variable = expression`** — assignment. Variables are lowercase letters only, created on first assignment, reassignable.

```
LET amt = 10
LET total = amt * 2 + 1
LET h = SHA3(0xFFAA)
```

**`LET ( expr1 expr2 ... ) = expression`** — array assignment. KISS has a simple keyed array: the parenthesised expressions form a multi-dimensional key. Read back with `GET`, test with `EXISTS`:

```
LET ( 1 2 ) = [movevalid]
LET v = GET(1 2)
IF EXISTS(1 2) THEN RETURN TRUE ENDIF
```

**`IF ... THEN ... [ELSEIF ... THEN ...]* [ELSE ...] ENDIF`** — conditional. No braces, terminated by `ENDIF`.

**`WHILE expression DO ... ENDWHILE`** — loop. Exists, works, but every iteration consumes instructions from the 1024 budget; deep loops fail. Prefer straight-line code.

**`ASSERT expression`** — if the expression is FALSE, the script immediately fails (returns FALSE). The workhorse for enforcing spend conditions mid-script.

**`RETURN expression`** — ends execution with a boolean result. `RETURN TRUE` = coin may be spent on this path. Falling off the end of the script = FALSE.

**`EXEC expression`** — execute a SCRIPT value as code, inline, sharing the current variable scope. Pairs with `PROOF` for MAST-style patterns (see MAST section).

**`MAST expression`** — declare a Merkelized script block by its MMR root hash; the actual code is supplied with the spending transaction (see MAST section).

Comments: `/* ... */` blocks are accepted by the cleaner and stripped from the canonical script.

---

## 4. Operators

### Comparison (all types where sensible)
```
EQ  NEQ  GT  GTE  LT  LTE
```

### Boolean (word operators — TRUE/FALSE only, NOT bitwise)
```
AND  OR  XOR  NAND  NOR  NXOR  NOT
```
```
IF a GT 5 AND SIGNEDBY(pk) THEN RETURN TRUE ENDIF
```

### Bitwise (symbol operators — HEX operands ONLY)
```
&  |  ^  ~        /* AND, OR, XOR, NOT — both sides must be HEX */
<<  >>            /* bit shift on HEX, max shift 256 bits */
```
The VM enforces `Value.checkSameType(..., VALUE_HEX)` — `5 & 3` fails, `0x05 & 0x03` works. If you need bitwise mixing of numbers (e.g. for randomness), don't: hash instead — `SHA3(CONCAT(a b))`.

### Arithmetic (NUMBER)
```
+  -  *  /  %     /* arbitrary-precision decimal; % is modulo */
NEG               /* unary negation */
```
There is no `**`; use the `POW(n p)` function. Division is exact decimal, use `FLOOR`/`CEIL`/`SIGDIG` to control precision.

Precedence (low → high): word-boolean ops → comparisons → `& | ^` → `+ - % << >>` → `* /` → unary `NOT NEG ~`. When in doubt, parenthesise — parentheses are free, debugging on-chain is not.

---

## 5. Global variables

Source-verified — these are exactly the globals the VM sets (`Contract.java`):

| Global | Type | Meaning |
|---|---|---|
| `@BLOCK` | NUMBER | Block number this transaction is included in |
| `@BLOCKMILLI` | NUMBER | Block time in milliseconds since 1 Jan 1970 |
| `@CREATED` | NUMBER | Block number when this input coin was created |
| `@COINAGE` | NUMBER | `@BLOCK - @CREATED` — blocks since the coin was created |
| `@INPUT` | NUMBER | Index of this input in the transaction (first input = 0) |
| `@COINID` | HEX | CoinID of this input |
| `@AMOUNT` | NUMBER | Amount of this input coin |
| `@ADDRESS` | HEX | Address (script hash) of this input coin |
| `@TOKENID` | HEX | TokenID of this input (`0x00` = Minima) |
| `@SCRIPT` | SCRIPT | This coin's script as text |
| `@TOTIN` | NUMBER | Total number of inputs in the transaction |
| `@TOTOUT` | NUMBER | Total number of outputs in the transaction |

Notes:
- `@BLOCK`, `@BLOCKMILLI`, and `@COINAGE` are the "unknowable until mined" globals — `txncheck` cannot evaluate them, and older doc/tool material sometimes calls `@BLOCK` "@BLKNUM". Prefer `@COINAGE` relative timelocks (see gotchas).
- `@INPUT`/`@ADDRESS`/`@AMOUNT`/`@TOKENID` are what make the self-referencing recreate pattern work: `VERIFYOUT(@INPUT @ADDRESS @AMOUNT @TOKENID TRUE)` means "output at my own index recreates me, state preserved".

---

## 6. Function reference

Exact signatures from the current VM. All calls are `NAME ( arg1 arg2 ... )` — arguments separated by spaces, not commas.

### State

| Function | Description |
|---|---|
| `STATE ( port )` | Value of state port `port` (0–255) in the **spending transaction** (set via `txnstate` / `send state:{...}`) |
| `PREVSTATE ( port )` | State value **stored with the input coin** when it was created (its MMR data) |
| `SAMESTATE ( start end )` | TRUE iff `STATE(n) == PREVSTATE(n)` for every port `n` in the contiguous range `[start..end]` |

**Caveat — `SAMESTATE` ranges are contiguous only.** If port 6 changes but 0–5 and 7–11 must carry over, you need two calls:

```
ASSERT SAMESTATE(0 5)
ASSERT STATE(6) EQ 1
ASSERT SAMESTATE(7 11)
```

`STATE`/`PREVSTATE` on a never-set port throws → script fails. Initialize every port you will ever read (put `0` in unused ones at coin creation).

### Signatures

| Function | Description |
|---|---|
| `SIGNEDBY ( pubkey )` | TRUE if the transaction is signed by this public key |
| `MULTISIG ( n pk1 pk2 ... pkm )` | TRUE if signed by at least `n` of the listed public keys |
| `CHECKSIG ( pubkey data signature )` | Verify an arbitrary signature over arbitrary data (not tied to the tx) |

```
/* 2-of-3 */
RETURN MULTISIG(2 0xFF..01 0xFF..02 0xFF..03)
```

### Input / output verification

| Function | Description |
|---|---|
| `VERIFYOUT ( index address amount tokenid keepstate )` | ASSERT-style check that output `index` has exactly this address, amount, tokenid, and keepstate flag |
| `VERIFYIN ( index address amount tokenid )` | Same for input `index` |
| `GETOUTADDR ( index )` | Address of output `index` |
| `GETOUTAMT ( index )` | Amount of output `index` |
| `GETOUTTOK ( index )` | TokenID of output `index` |
| `GETOUTKEEPSTATE ( index )` | Is output `index` keeping the state (boolean) |
| `GETINADDR ( index )` | Address of input `index` |
| `GETINAMT ( index )` | Amount of input `index` |
| `GETINTOK ( index )` | TokenID of input `index` |
| `GETINID ( index )` | CoinID of input `index` |
| `SUMINPUTS ( tokenid )` | Sum of all input amounts of that token |
| `SUMOUTPUTS ( tokenid )` | Sum of all output amounts of that token |

The `keepstate` boolean in `VERIFYOUT` is what binds the script to the transaction builder: TRUE means the output must carry the transaction state forward (`txnoutput ... storestate:true`), FALSE means it must not. Get this wrong and the tx is silently invalid.

### Hashing & HEX manipulation

| Function | Description |
|---|---|
| `SHA3 ( hex\|string )` | Keccak/SHA3-256 hash → 32-byte HEX |
| `SHA2 ( hex\|string )` | SHA2-256 — kept for cross-chain hashlocks with legacy chains (Bitcoin HTLCs) |
| `CONCAT ( h1 h2 ... hn )` | Concatenate HEX values: `CONCAT(0xAA 0xBB)` → `0xAABB` |
| `LEN ( hex\|string )` | Length in bytes (HEX) / characters (SCRIPT) |
| `REV ( hex )` | Reverse the bytes |
| `SUBSET ( start end hex )` | Bytes `[start, end)` of the data. **Verified against source: numbers first, END index not length.** `SUBSET(0 4 h)` = first 4 bytes |
| `SETLEN ( len hex )` | Force HEX to `len` bytes — trims (keeps the low/rightmost bytes) or left-pads with zeros |
| `OVERWRITE ( srchex srcpos desthex destpos len )` | Copy `len` bytes from source at `srcpos` into dest at `destpos` |

### Casts / conversion

| Function | Description |
|---|---|
| `NUMBER ( value )` | HEX→NUMBER (also passes numbers/booleans through). **Fails/overflows on large hex — truncate 32-byte hashes with `SUBSET(0 4 h)` first** |
| `HEX ( script )` | SCRIPT → HEX (UTF-8 bytes) |
| `STRING ( hex )` | HEX → SCRIPT |
| `UTF8 ( hex )` | HEX → UTF-8 string |
| `ASCII ( hex )` | HEX → ASCII string |
| `BOOL ( value )` | Anything → TRUE/FALSE |
| `ADDRESS ( string )` | The `0x..` address of the given script text — lets a script compute/verify another script's address on the fly |

### Math

| Function | Description |
|---|---|
| `ABS ( n )` | Absolute value |
| `FLOOR ( n )` / `CEIL ( n )` | Round down / up |
| `MIN ( a b )` / `MAX ( a b )` | Smaller / larger of two numbers |
| `INC ( n )` / `DEC ( n )` | n+1 / n-1 |
| `POW ( n p )` | n to the power p (p must be whole) |
| `SQRT ( n )` | Square root |
| `SIGDIG ( digits n )` | Round n to the given significant digits |

### Bit operations

| Function | Description |
|---|---|
| `BITSET ( hex pos bool )` | Return hex with the bit at `pos` set to 1/0 |
| `BITGET ( hex pos )` | Boolean value of the bit at `pos` |
| `BITCOUNT ( hex )` | Number of set bits |

### Strings & arrays

| Function | Description |
|---|---|
| `REPLACE ( str find repl )` | Replace all occurrences |
| `SUBSTR ( start end str )` | Substring `[start, end)` — same numbers-first shape as SUBSET (source-verified) |
| `GET ( k1 k2 ... )` | Read array value set with `LET ( k1 k2 ... ) = v` |
| `EXISTS ( k1 k2 ... )` | Does that array key exist (use before GET to avoid failures) |

### MAST / meta

| Function | Description |
|---|---|
| `PROOF ( data sumval proof sumval root )` | Verify `data` is a leaf of the MMR tree with `root` via `proof` — same math as the `mmrproof` command. Use `0` for the two sum values on plain (non-sum) trees |
| `FUNCTION ( script v1 v2 ... )` | Generic function: runs `script` with `$1..$n` replaced by the values; the variable `returnvalue` inside it becomes the result |

```
LET double = [LET returnvalue = $1 * 2]
LET x = FUNCTION(double 21)    /* x = 42 */
```

---

## 7. Limits

Verified against `Contract.java` constants:

| Limit | Value | Behavior on breach |
|---|---|---|
| Instructions per execution | **1024** (each operation/function = 1) | Execution error → FALSE. (Some older docs say 512 — budget conservatively; only the executed path counts, which is why MAST works) |
| Script size | **~1200 characters** (undocumented) | **Silently rejected on-chain** — the worst failure mode in KISS. Minify + MAST |
| Stack depth | **64** | Execution error |
| Function parameters | **32** max | Parse/execution error |
| HEX / STRING value size | **64 KB** | Execution error |
| HEX bit shift | **256 bits** max | Execution error |
| State ports | **256** (0–255) | `txnstate` rejects out-of-range ports |

---

## 8. MAST — Merkelized Abstract Syntax Trees

MAST is how KISS scripts escape the size limit — and gain privacy. Instead of putting every branch on-chain, you commit to a **hash tree of script blocks** and reveal only the block you actually execute, plus a merkle proof.

### Why

```
IF SIGNEDBY(0xFF..AA) THEN
  /* CODEBLOCK 1 - the everyday path */
ELSEIF @COINAGE GT 100 THEN
  /* CODEBLOCK 2 - the rare recovery path */
ENDIF
```

If block 1 runs, nobody ever needs to see block 2. The blocks behind the roots can be megabytes in total; all that matters is that the *executed path* fits the VM limits. This enables things a flat script never could — e.g. a 1-of-10,000 multisig where each leaf is a different `SIGNEDBY` block, or a game contract with thousands of pre-committed valid end states.

### The `MAST` statement

```
IF SIGNEDBY(0xFF..AA) THEN
  MAST 0x72BE56DFD48B785139A72512FEAAC7E339B8F48132E9B9340A248EFC00F4A5DA
ELSEIF @COINAGE GT 100 THEN
  MAST 0xFA1B16685F09FA56581614AC55E731697C46926392129F3A6BF8FA5EE202A251
ENDIF
```

Each `MAST 0x...` is the root of an MMR tree of script blocks. MAST blocks can nest inside other MAST blocks.

### Worked sketch

**1. Build the tree** of alternative blocks:

```
mmrcreate nodes:["RETURN TRUE","RETURN FALSE"]
```

Returns a `root` plus a per-leaf `proof`. Verify any leaf:

```
mmrproof data:"RETURN TRUE" proof:0x0000010100...C7 root:0x0E3216...15
```

Both leaves verify against the **same root** with **different proofs**.

**2. Lock the coin** with a script containing `MAST <root>` (or the explicit PROOF+EXEC form below). Get its address with `scripts action:clean script:"..."` or `newscript script:"..." trackall:true`, and `send` funds to it.

**3. Spend it** — build the txn and attach the revealed block + proof as witness data via `txnscript`:

```
txncreate id:m
txninput  id:m coinid:0x...           /* the MAST-locked coin */
txnoutput id:m address:0xFF..AA amount:1
txnscript id:m scripts:{"RETURN TRUE":"0x0000010100...C7"}
txnpost   id:m auto:true
```

The JSON maps `script text → merkle proof`. For a single non-tree MAST script, leave the proof empty (`""`). If you skip `txnscript`, the post fails with `Script FAIL 0 MAST 0x72BE...` — the node has no way to know what code the root commits to. (`txnclear` wipes witness data if you need to retry.)

### The explicit PROOF + EXEC pattern

`MAST` is sugar over primitives you can also use directly — including with the revealed script delivered via **state variables**, which makes a generic "run any committed script" contract:

```
LET script = STATE(0)
LET proof  = STATE(1)
ASSERT PROOF(script 0 proof 0 0x0E321692DA8996A833F88EC8A73F3AA8A5E949AD12FF48207130C7AE6F9DC115)
EXEC script
```

Spend with `state:{"0":"[RETURN TRUE]","1":"0x0000010100...C7"}`. `PROOF` takes the same arguments as the `mmrproof` command (the two `0`s are the sum-values, unused for plain trees). In production, still require a signature — either around the EXEC or inside every leaf block — otherwise anyone holding a valid leaf+proof can spend.

### Using MAST to beat the 1200-char limit

Keep the hot path (phase logic, signature checks) in the main script; push cold paths (dispute resolution, emergency refund, upgrade) behind `MAST` roots. Main script stays small enough to post; cold-path code is only revealed and transmitted if it ever runs.

---

## 9. Testing workflow

### 1. `runscript` — offline unit tests (fast, first line of defense)

```
runscript script:"ASSERT SIGNEDBY(0xFF..AA) RETURN TRUE"
  state:{"0":"123"} prevstate:{"0":"100"}
  globals:{"@COINAGE":"50","@AMOUNT":"10"}
  signatures:["0xFF..AA"]
  extrascripts:{"RETURN TRUE":"0x00...proof"}
```

You control everything: state, prevstate, globals, which keys "signed", and MAST extra scripts. Returns parse-ok, run-ok, and the final TRUE/FALSE plus a variable trace.

**What it can't do:** there is no real transaction behind it, so `VERIFYOUT`/`VERIFYIN`/`GETOUT*`/`GETIN*`/`SUMINPUTS`/`SUMOUTPUTS` and the keepstate/`storestate` interplay are not meaningfully testable. `SAMESTATE` only reflects the state/prevstate maps you injected. A script can pass `runscript` all day and still be unspendable on-chain.

### 2. `txncheck` — structural validation of a built transaction

`txncheck id:<txnid>` validates the constructed transaction (inputs, outputs, amounts, scripts run against the real tx context). **It cannot evaluate `@BLOCK`, `@BLOCKMILLI`, or `@COINAGE`** — those don't exist until the tx is mined into a block. A tx that fails only on a timelock can look fine in `txncheck` and still be unspendable (or vice versa). Design so timelock paths can be exercised quickly on a test chain.

### 3. Private test chains — the real proof

Run a throwaway node with a private chain (`-test` / genesis mode, or an isolated "solo" node) so you get instant blocks and free funds. Post the real transactions for every path of your contract — creation, each phase transition, each ending. This is the only environment where `VERIFYOUT` + `storestate` + state carry-over + timelocks are all exercised for real. When tracking multi-phase contracts, follow **coinids** through transitions, not just phases — multiple concurrent instances share the same script address.

### 4. Offline bench: minima-vm

A native KISS VM test bench exists for scripted offline runs (fast iteration, CI-style testing of many cases). Same fundamental limitation as `runscript`: no real chain, so tx-context functions and mining-time globals aren't fully faithful. See `ecosystem-tooling.md` for the tool and its limits.

**Recommended pipeline:** `runscript` for logic → build with `txncreate`/`txninput`/`txnoutput`/`txnstate` → `txncheck` → post every path on a private chain → only then mainnet, with small amounts first.

---

## 10. Common mistakes

| Mistake | Result | Fix |
|---|---|---|
| Underscore in a variable name (`my_var`) | Silent parse failure — script just fails | Lowercase letters only: `myvar`, `mv` |
| Script > ~1200 chars | Silently rejected on-chain, no error anywhere | 2–3 char variable names; move cold paths to MAST |
| `@BLOCK` for deadlines | Unreliable on some synced nodes; untestable in `txncheck` | Store duration in state, check `@COINAGE GT dur` |
| `VERIFYOUT(... FALSE)` but output built with `storestate:true` (or vice versa) | Tx silently invalid | keepstate TRUE + `storestate:true` for phase transitions; FALSE + `storestate:false` for payouts |
| `XOR`/`AND` expecting bitwise math | Boolean result or type error | Word ops are boolean; `& \| ^ ~` need HEX operands; for entropy mixing use `SHA3(CONCAT(a b))` |
| `NUMBER(SHA3(x))` | Overflow / failure on 32-byte hex | `NUMBER(SUBSET(0 4 SHA3(x)))` |
| `SUBSET(data 0 4)` (docs order) | Wrong args — VM wants numbers first | `SUBSET(0 4 data)` — start, END index, data |
| Reading an unset state port | Execution error → FALSE | Set all readable ports at creation (`0` for unused), or guard reads by phase |
| `SAMESTATE(0 11)` when one port in range changes | FALSE — range must be identical end to end | Split around the changed port: `SAMESTATE(0 5)` + `SAMESTATE(7 11)` |
| No `RETURN TRUE` on a path | Coin unspendable via that path (default FALSE) | Every valid path ends in `RETURN TRUE` |
| Forgetting the token script | Token coin unspendable even though address script passes | Both scripts must return TRUE; default token script is `RETURN TRUE` |
| Posting a MAST spend without `txnscript` | `Script FAIL 0 MAST 0x...` | Attach revealed script + proof: `txnscript id:x scripts:{"<script>":"<proof>"}` |
| Deep `WHILE` loops | Instruction limit (1024) exceeded | Unroll, restructure, or redesign — KISS punishes loops |

---

## Appendix: the multi-phase contract idiom

The canonical KISS pattern for stateful contracts — a coin that recreates itself at the same address with updated state until a final payout. Skeleton (pubkeys are placeholders):

```
LET opk = PREVSTATE(0)          /* owner pubkey, set at creation */
LET ph  = PREVSTATE(6)          /* phase number */
LET dur = PREVSTATE(7)          /* timeout duration in blocks */

/* cancel: owner exits any time in phase 0 */
IF ph EQ 0 AND SIGNEDBY(opk) THEN RETURN TRUE ENDIF

/* advance: anyone moves phase 0 -> 1, must recreate the coin */
IF ph EQ 0 THEN
  ASSERT SAMESTATE(0 5)
  ASSERT STATE(6) EQ 1
  ASSERT VERIFYOUT(@INPUT @ADDRESS @AMOUNT @TOKENID TRUE)
  RETURN TRUE
ENDIF

/* timeout refund: relative timelock via COINAGE */
IF @COINAGE GT dur AND SIGNEDBY(opk) THEN RETURN TRUE ENDIF

RETURN FALSE
```

Key moves: constants live in `PREVSTATE` (written once at creation), the phase port is the only one allowed to change (enforced by split `SAMESTATE` + explicit `STATE(n) EQ` checks), `VERIFYOUT(@INPUT @ADDRESS ... TRUE)` forces faithful recreation, and the escape hatch is a `@COINAGE` timelock. Commit–reveal randomness on top: parties store `SHA3(secret)` commitments in state, later reveal secrets, and the script derives the outcome with `NUMBER(SUBSET(0 4 SHA3(CONCAT(s1 s2)))) % range`.

---

## VM cost model and re-verifiability notes

- **Gas prices instructions, not data:** CONCAT, boolean ops, shifts and SUBSET cost 1
  instruction whether operands are 1 byte or 64 KB (node audit finding). Worst-case scripts are
  CPU/allocation amplifiers on every validating node — keep bulk HEX operations small, and don't
  assume the instruction limit protects validators from a hostile script's cost. The real safety
  envelope is the layered limits (1024 instructions, stack depth 64, 64 KB values); write scripts
  that live comfortably inside them, and remember the ~8.4–12 KB spend-time WOTS signature shares
  the same 64 KB TxPoW budget as your state and token data.
- **Design for on-chain re-verifiability:** compute client-side hashes bit-identically to the
  KISS script form (e.g. SHA3 of concatenated values) so any outcome can be re-checked with
  `runscript` in a terminal — this is what makes a "provably fair" claim checkable, and it costs
  one design decision.
