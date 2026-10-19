# Native Android IPC — companion apps and an on-device Minima node

How a native (non-MDS) Android app talks to a full Minima light client running on the
same phone, over Android broadcast-Intent IPC. This is the integration surface for
companion apps (wallets, faucets, mail, DEX/AMM front-ends) that live in their own APK and
drive a separately-installed **node app**.

Throughout, `<node-package>` is the Android package id of the installed node app (e.g. the
one that embeds `minima.jar`). Substitute your node's real package everywhere.

---

## Native IPC gotchas (read first)

- **A large response is an UNCATCHABLE node/app KILL.** Intent extras cross the Android
  Binder (~1 MB per transaction). An over-limit `sendBroadcast` throws
  `TransactionTooLargeException` with no try/catch in the path, so the OS **force-kills the
  process before any callback runs**. You cannot catch it and you cannot truncate app-side —
  the only lever is making the node return **less up front**. Bound `depth:`, use
  `simplestate:true`, request one token's `balance tokenid:` not all, and take a tiny first
  `history` page.
- **There are THREE distinct size caps — don't conflate them** (details below): a node-RPC
  256 KB "results too long" stub (catchable), an app-side `MinimaReceiver.MAX_MESSAGE_LEN`
  ~256 KB (an application constant, not in the core jar), and the native Binder ~1 MB (the
  uncatchable one).
- **Adaptive paging** is the portable mitigation: start `max:8`, halve on any
  over-limit/empty/errored page (8→4→2→1), and keep the smaller size.
- **Socket-opening commands fail over IPC with misleading errors.** `megammrsync`,
  `archive`, `restoresync` open a raw socket inline on the main thread →
  `NetworkOnMainThreadException` is swallowed → the user sees "Could not connect to Archive
  host!" though the host was never contacted.
- **`getaddress` rotates.** It returns a different one of the node's 64 permanent keys on
  every call. Never treat it as stable identity.
- **Pin `com.h2database:h2:2.1.214`.** 2.4.240 fails Android's ART verifier and hangs the
  node on "Syncing…".
- **Authenticate the caller — never trust self-asserted identity.** Package name, app id and
  "secret" in Intent extras are all chosen by the sender.

---

## What it is, and how it differs from MDS

A native Android node app embeds the **real Java `minima.jar`** in an Android service,
started in-process with `minima.mainStarter(...)` and driven with
`minima.runMinimaCMD(cmd, false, userid)`. It runs a full light client. A representative
startup profile:

```
-daemon -data <filesDir> -basefolder <filesDir> -port 11001
-isclient -mobile -limitbandwidth -allowallip
-nosyncibd -noshutdownhook -anyseed -seed <seed>
```

Divergences from a desktop/server node — internalize these:

- **No MDS subsystem** — no `-mdsenable`, no MiniHUB, no MDS web server.
- **No `.mds.zip` support** — MiniDapps do not install here at all. "Apps" are separate
  native Android APKs, each its own installed package.
- **No RPC HTTP port** — the only control surface is the in-process `runMinimaCMD`, reached
  through broadcast IPC.
- **Instead:** companions send terminal-style command strings (`balance`, `send ...`,
  `history max:50`, `getaddress`) and get back the **same JSON the terminal would**. Node
  events arrive via a `.NOTIFY` broadcast.

Because there is no HTTP surface, everything below is the *entire* integration surface.

---

## The `minimaapi` broadcast protocol

Actions (all prefixed with the node package):

| Action | Direction | Purpose |
|---|---|---|
| `<node-package>.REGISTER` | app → node | announce the app; create its `receive.db` row |
| `<node-package>.CMD`      | app → node | run one terminal command |
| `<node-package>.RESPONSE` | node → app | the command's JSON reply |
| `<node-package>.NOTIFY`   | node → app | pushed node event |

Extras: `PACKAGE_CLASS`, `APP_UID`, `REGISTER_MINIMAID`, `CMD_ACTION`, `RESPONSE_ID`,
`RESPONSE_RESULT`, `NOTIFY_DATA`.

Companion lifecycle:

```java
// 1. On first construction, mint two random 32-hex ids ONCE and persist them.
//    Use SecureRandom — NOT java.util.Random (clock-seeded, predictable). If this id
//    is the only thing distinguishing your traffic, it must be a real secret.
SharedPreferences p = ctx.getSharedPreferences("minima_api_prefs", MODE_PRIVATE);
String appUid   = p.getString("myapp_uid",  null);
String minimaId = p.getString("minima_uid", null);
if (appUid == null) {
    appUid   = randomHex32(new SecureRandom());
    minimaId = randomHex32(new SecureRandom());
    p.edit().putString("myapp_uid", appUid)
            .putString("minima_uid", minimaId).apply();
}

// 2. Register a RESPONSE receiver (and a NOTIFY receiver) for this app's actions.
ctx.registerReceiver(responseReceiver, new IntentFilter("<node-package>.RESPONSE"));

// 3. Fire REGISTER.
Intent reg = new Intent("<node-package>.REGISTER");
reg.setPackage("<node-package>");                 // unicast to the node ONLY
reg.putExtra("PACKAGE_CLASS", ctx.getPackageName());
reg.putExtra("APP_UID", appUid);
reg.putExtra("REGISTER_MINIMAID", minimaId);
ctx.sendBroadcast(reg);

// 4. Every command: setPackage + a fresh RESPONSE_ID to correlate the reply.
Intent cmd = new Intent("<node-package>.CMD");
cmd.setPackage("<node-package>");                 // MANDATORY on every command
String responseId = randomHex32(new SecureRandom());
cmd.putExtra("CMD_ACTION", "balance");
cmd.putExtra("RESPONSE_ID", responseId);
cmd.putExtra("APP_UID", appUid);
cmd.putExtra("REGISTER_MINIMAID", minimaId);
ctx.sendBroadcast(cmd);
// RESPONSE arrives with the matching RESPONSE_ID in RESPONSE_RESULT (a JSON string).
```

`setPackage(<node-package>)` on **every** outbound intent keeps the broadcast unicast to the
node, so no other app can intercept it.

**Node side** (`MinimaReceiver`): looks the app up by the triple
`(package, packageid, minimaid)` in a receive DB, and **refuses commands unless the app is
Enabled** (`penabled=1`). It picks the RPC user, runs `runMinimaCMD`, and broadcasts the raw
JSON reply back to the caller only.

---

## The Enable / Admin permission model (native equivalent of MDS READ / WRITE)

- An app **auto-registers on first launch but starts Disabled and non-admin**. Commands are
  refused until the **user flips Enable** in the node's Apps screen.
- **Admin** is a separate toggle. It maps the app's node user: a normal (enabled) app runs
  as RPC user **`0xFF`**; an **admin** app runs as **`0x00`** (full RPC).
- Drawing the installed-app list (icons/labels for the consent UI) needs the
  `QUERY_ALL_PACKAGES` manifest permission — see the security note on why that permission is
  a double-edged sword.

---

## NOTIFY events (node → app push)

On node events the service pushes `{event, data}` via `.NOTIFY` in `NOTIFY_DATA`, **only to
enabled apps** (unicast per app via `setPackage`). Events:

- `NEWBLOCK` — a new tip block.
- `NEWBALANCE` — wallet balance changed.
- `SHUTDOWN` — node is stopping.
- `LOAD_ALL_KEYS_START` / `LOAD_ALL_KEYS_FINISH` / `LOAD_ALL_KEYS_VALUE` — key-load progress.
- `MINIMALOG` — a line of node log output (drives a live Logs tail).

Gate handling on a minima-id check before trusting the payload — a companion's NOTIFY
receiver should verify the incoming minima-id matches its own persisted `minima_uid` (the
equivalent of `MinimaAPI.checkMinimaID`) and reject otherwise.

---

## The four hard truths about response size (fund / stability critical)

### 1. A large response CRASHES the node/app — uncatchable, not app-fixable

The node's IPC receiver runs the command and returns the result as an Intent String extra
via `sendBroadcast`, with **no try/catch**. Intent extras cross the Binder (~1 MB per
transaction), so a response over the limit throws `android.os.TransactionTooLargeException`
at `sendBroadcast`, and the OS **force-kills the app before any callback runs**. There is no
error object to catch and no chance to truncate — the process is already dead.

⇒ **The only lever is making the node return less up front.** Bound `depth:`, use
`simplestate:true`, take a tiny first `history` page, request `balance tokenid:<one>` rather
than the all-token balance.

Danger commands:

- **`history`** ≈ 14 KB per txpow (`action:list` always returns full txpow bodies, no lite
  mode). Default `max` ~100 ⇒ well over 1 MB on an active wallet. **Never** call `history`
  on a per-reload or per-block loop — poll it only while the History tab is visible, at most
  once per new block, bounded (e.g. `history relevant:true max:25 offset:N`).
- **`coins`** has **no `max:`/count cap** — only `depth:`, which is a **time** bound, not a
  count bound. So a feeless-PoW **dust flood** of a public/shared address can still overflow
  regardless of `depth:`. That residual is **not app-fixable** — it needs a **node-side
  coins count-cap**.

The node also processes commands serially and synchronously on the broadcast thread, so a
slow/heavy command blocks everything and a looping client can wedge or OOM the node.

### 2. Three DISTINCT size caps — do not conflate them

| Cap | Where it lives | Value | Behaviour |
|---|---|---|---|
| (a) node RPC "results too long" stub | inside `runMinimaCMD`'s result path over RPC | 256 KB | **CATCHABLE** — reply comes back empty/stubbed; you can distinguish TOO_LONG-vs-empty and adaptive-shrink-retry |
| (b) `MinimaReceiver.MAX_MESSAGE_LEN` | the **app-side** receiver — an APPLICATION constant, **NOT in the core jar** | ~256 KB | returns a "Result too long!" stub |
| (c) native Binder | Android OS, the `sendBroadcast` transaction | ~1 MB | **UNCATCHABLE** — `TransactionTooLargeException` → OS force-kill |

**Reconciliation of an earlier belief.** Earlier notes said "the node caps at 256 KB." That
is wrong. Exhaustive source search confirms `runMinimaCMD` → `CommandRunner.runMultiCommand`
applies **no** size limit; the only 256000 in the codebase is the **receiver's**
`MAX_MESSAGE_LEN` — an app-side constant. So (b) is an application concern, and the
physical ceiling is the Binder (c), not the jar.

### 3. The fix for unbounded responses — a `content://` FileProvider hand-off

Describe this as a **generic design pattern** (a forked node implements it; upstream may
not). When a result exceeds the receiver cap, instead of inlining it:

1. The client opts in with a new CMD extra `CMD_FILERESP=true` (set automatically inside the
   updated `minimaapi` `Command()`, so app code needs no change).
2. The node writes the large result to a per-package file in its cache
   (`cacheDir/ipcresponses/<responseid>.json`), exposed through a **non-exported
   FileProvider**, and grants **read to exactly the calling package**
   (`grantUriPermission`, plus a ClipData grant for newer Android).
3. The node broadcasts the normal RESPONSE intent carrying new extras **`RESPONSE_URI`** and
   **`RESPONSE_LEN`** instead of `RESPONSE_RESULT`.
4. The client, on RESPONSE, checks for `RESPONSE_URI` first; if present it opens the URI via
   `ContentResolver.openInputStream` (off the main thread), reads UTF-8, parses JSON, and
   delivers through the unchanged listener callback.

A **file descriptor** crosses the Binder, not the data, so response size becomes effectively
**unbounded** and the `TransactionTooLargeException` node-kill is gone for opted-in clients.

Compatibility is three-way: old client → new node ignores the unknown flag and gets the old
stub; new client → old node has its unknown extra ignored and gets the old stub; results
under the cap keep the existing inline fast path in every pairing.

Hygiene: response files pruned after ~5 minutes and wiped at receiver start; URI grants
revoked on prune; a failed file write falls back to the stub (never silence — a dropped
callback hangs the caller forever). The provider stays non-exported and the grant is
read-only to the one registered, enabled caller.

```
client CMD (CMD_FILERESP=true) ─▶ node runs command
                                    │  result ≤ cap → RESPONSE + RESPONSE_RESULT (inline)
                                    │  result > cap → write file, grant read to caller,
                                    ▼                  RESPONSE + RESPONSE_URI + RESPONSE_LEN
client reads URI off-main-thread ─▶ same listener.response(json)
```

### 4. Adaptive paging — the portable mitigation

For any app on the **old** `minimaapi`, or talking to an upstream/store node without the
file hand-off, page adaptively rather than with a fixed size:

```
max := 8
loop:
  page := node("history relevant:true max:{max} offset:{off}")
  if page is over-limit / empty / errored:
      if max > 1: max := max / 2   // 8 → 4 → 2 → 1
      retry same offset
  else:
      keep this (smaller) max for subsequent pages
      off := off + len(page)
```

A **fixed** page size is not safe: contract-heavy txpows are large, so even
`history relevant:true max:25` can exceed 256 KB on an active node.

---

## Socket-opening commands fail over IPC with misleading errors

Because the receiver runs `runMinimaCMD` synchronously on the process **main thread**,
commands that open a raw `Socket` inline — `megammrsync`, `archive`, `restoresync` — throw
`NetworkOnMainThreadException`. The internal catch-all swallows it (returns null), so the
user sees **"Could not connect to Archive host!"** even though the host is fine and was never
contacted. Desktop nodes are unaffected. Colon-parsing of `host:<ip>:9001` is fine
(first-colon split — the host was never the problem).

**Fix pattern:** run companion commands on a single background executor, not the broadcast
thread. This both removes the misleading socket failures and eliminates the ANR risk of slow
commands.

---

## Reading coins at a SHARED address you do not own

To read coins at an address the node does not already track (e.g. a shared registry/mailbox
sentinel address):

- `coins relevant:false address:X` returns **0**. `relevant:true` also returns 0 until the
  address is tracked.
- You must first **track** the address: `coinnotify action:add address:X`. This must be
  **redone every node start** (over native IPC you get no coin-notify callback, but the add
  still makes the address's coins indexed/retained).
- Then query with a **bare `coins address:X`** — **no `relevant:` flag**. That returns the
  coins.
- **Bound it.** `coins` has no `max:`/`offset:`, only `depth:` + `order:desc`. An
  **unbounded `coins address:X` on a busy shared address CRASHED a phone node** (it built a
  giant reply and died). Start small (`depth:4`), grow only while replies stay safe, shrink
  on over-limit, and throttle — do not scan on every `NEWBLOCK`/`NEWBALANCE`.

Coin `state` comes back as `[{"port":99,"type":1,"data":"0x..."}]`.

Posting a message coin includes **PoW** (seconds on a phone). **Disable the Send button**
while a post is in flight — repeated taps post duplicates, each with a fresh random id, so DB
dedup will not catch them.

---

## Other IPC truths

- **`getaddress` rotates across the 64 default keys.** Two back-to-back calls return
  different `publickey`/`miniaddress`. All 64 are permanent keys the node controls, so any
  returned key is yours to sign with — but never treat "whatever `getaddress` returned this
  session" as stable identity. Persist **one** chosen address+pubkey once (in prefs) for
  anything others address coins to. To test "is this coin mine", match the pubkey against the
  **full 64-key set** from `keys` (`response.keys[].publickey`), not a single key. To spend a
  script coin, sign with the key embedded in the coin's own state — one of the 64, not
  necessarily the persisted one.
- **`txnpost` mines ASYNChronously.** `response.istransaction` is **false** on return for a
  good tx — it only means "PoW not done yet"; the tx is accepted/queued and confirms a few
  blocks later. **Do not treat `istransaction:false` as failure.** Retrying on it causes a
  **re-post storm** every block that races itself and stalls confirmation for minutes.
  Success signal = `status:true`; confirm the real outcome from chain state.
- **`txnsign txnpostauto:true` returns a txpowid that is NOT the on-chain id.** Its
  `response.txpow.txpowid` (no leading zeros) is never found on the node or explorer. Resolve
  the **real** on-chain txpowid (leading-zero PoW hash) after mining by matching the **input
  coinids you spent** against `history`'s
  `response.txpows[].body.txn.inputs[].coinid` → that txpow's `txpowid` is the real one.

---

## H2 VerifyError on Android — pin the dependency

`com.h2database:h2:2.4.240`'s `org.h2.security.SHA256.getPBKDF2` is **rejected by Android's
ART bytecode verifier** (reproduced on Samsung S10+, Android 9–12). The node opens its H2 DB
with a password → `ConnectionInfo.hashPassword → SHA256.getPBKDF2` → `VerifyError` kills the
node's main thread at boot, and the wallet hangs forever on "Syncing…".

`minima.jar` bundles no `org/h2/*` classes, so the offending class comes solely from gradle.

**Fix — one dependency line:**

```diff
-implementation 'com.h2database:h2:2.4.240'
+implementation 'com.h2database:h2:2.1.214'
```

2.1.214 is the same H2 2.x API used by `org.minima.utils.SqlDB` and verifies cleanly on ART.
General rule: pin native-hostile deps to ART-verifiable versions.

---

## Keep IPC ids stable across a package rename

A namespace migration (renaming the app package) **must preserve** the persisted
`myapp_uid` / `minima_uid` in the app's prefs. The node identifies apps by
`(package, packageid, minimaid)`; if you regenerate the ids on rename, the node's existing
registration and enable-state for the app are orphaned and the user must re-enable. Carry the
old ids forward so existing registrations survive.

---

## JSON `\/` script-quoting trap (cross-reference)

The same `JSONObject.quote` hazard that bites covenant builders bites native builders too:
escaping `/` in a script/address string (via `JSONObject.quote`, which emits `\/`) can make
an address unspendable. See `references/contracts-covenants.md` for the full write-up — the
takeaway here is that any node command string you assemble from JSON-quoted values is exposed
to the same trap.

---

## versionCode convention

`versionCode = major*10000 + minor*100 + patch` (e.g. `0.4.2` → `402`, `1.3.0` → `10300`).

---

## Security checklist for a native companion

- **Authenticate the caller — never the self-asserted identity.** Package name, app id and
  "secret" in Intent extras are all chosen by the sender, so any app can claim to be a
  trusted companion — and if the UI renders that package's real icon/label, the impersonation
  wins the Enable/Admin toggle. On the node side, authenticate via `Binder.getCallingUid()`
  on a bound service, `PendingIntent.getCreatorPackage()`, or a signature-level permission
  before any command runs.
- **`SecureRandom`, not `java.util.Random`, for every id/secret.** Clock-seeded ids are
  predictable and are not secrets.
- **Fail closed on empty secrets.** A gate comparing an incoming id to a stored id that
  defaults to `""` authenticates everyone until the secret is provisioned. Reject blank
  stored and blank/null incoming values.
- **Export only components that need cross-app delivery** (`exported="false"` by default),
  null-guard and try/catch inside every exported receiver, and reject unknown actions early —
  never let an exception escape `onReceive`.
- **Run node commands off the broadcast thread** (`goAsync()` or a background executor);
  `onReceive` on the main thread turns any registered app's heavy command into an ANR.
- **Key permission mutations on the same identifier used for lookup.** If registration keys
  on `(package, package-id, minimaid)` but Enable/Admin updates match only
  `(package, package-id)`, one grant flips sibling rows and is not bound to the identity that
  authenticates traffic.
- **Store the seed encrypted and out of backups.** A mnemonic in plain `SharedPreferences`
  with `allowBackup="true"` is extractable via device transfer or cloud backup. Use
  `allowBackup="false"` plus Keystore-wrapped encrypted prefs — same for any store holding an
  IPC secret. Backup-rule XML is inert unless a `fullBackupContent`/`dataExtractionRules`
  attribute actually points at it — verify the attribute, not just the file.
- **`QUERY_ALL_PACKAGES` is both a privacy and a spoofing problem.** It exposes the full
  installed-app inventory and is exactly what lets an impersonating package resolve to a
  convincing icon and label. Prefer a scoped `<queries>` element, or do not render identity
  assets for unverified callers.
- **Do not broadcast the full event firehose to every enabled app.** Per-app subscription
  and filtering leaks far less than sending every chain/wallet event with full data to each
  app.
- **Prefer internal storage and client mode for the embedded node** — app-private storage, no
  inbound listener, RPC/MDS disabled. Relaxing peer-IP filtering re-adds LAN exposure; only do
  it if the topology needs it.

---

## Hard lessons from production companion apps and embedded-node hosts

All found live. ★ = app-killing or fund-risking.

### The Binder death window, precisely

★ An IPC reply can be under the node's 256,000-char inline cutoff yet over the ~256 KB broadcast
parcel limit: `String.length()` counts UTF-16 chars while `Parcel.writeString` serializes
~2 bytes/char, so a ~131K-char `coins` reply ≈ 262 KB parcel. `TransactionTooLargeException` is
raised in the RECEIVING process before any callback and is uncatchable on either side — the
companion dies instantly and reproducibly on every open once its wallet grows through the
128K–256K-char band. Fix: cap inline replies well below (~100K chars) and hand off larger
results as a `content://` file via a non-exported FileProvider with the URI read-granted to
exactly the calling package (a file descriptor crosses Binder, not the data). Negotiate per
command with a boolean extra so old/new client/node pairings keep working. Field signature:
`am_kill … "Can't deliver broadcast"` in the event log.

### Broadcast-IPC traps

- A broadcast carrying a `content://` DATA uri never matches an intent-filter lacking a `<data>`
  element — media IPC silently dead while plain commands work.
- The sender must HOLD the signature permission it defines (defining ≠ holding), and
  `checkSignatures` needs package visibility on Android 11+ (`<queries>`) or every
  correctly-signed caller reads as UNKNOWN_PACKAGE.
- Send with `intent.setPackage` (explicit); target replies at the caller only; on API 34+ require
  `getSentFromPackage()` to agree with any claimed package — every other identifying extra is
  self-declared. Authenticate by verified signature, never by a caller-supplied package name.
- Reserve the transport's own application strings from IPC clients, or any client can forge
  protocol-internal messages as the user.
- Derive FileProvider authorities from `${applicationId}`, never a fixed string — a fixed
  authority makes two SKUs of one codebase `INSTALL_FAILED_CONFLICTING_PROVIDER`.

### Command strings are an injection surface

★ The node's command tokenizer has no escape character and whitespace-splits with **last-wins**
semantics: any untrusted text interpolated into a command is injection. A pasted recipient of
`MxREALADDRESS burn:100` injects a burn; a hostile inbound media reference rewrites a fetch
command. Validate at one choke point BEFORE a command string exists (strict no-whitespace
patterns, address/amount format checks). Also: megabyte-scale `datahex:` parameters are dropped
by the tokenizer — use file-based hand-off for big payloads in both directions.

### Services, scheduling, and the OS

- ★ Android 14 caps `dataSync` foreground services at ~6 h/day, then `startForeground` THROWS —
  with a pending background job this crash-looped the whole app until force-stop. Use
  `specialUse` (persistent connection to the user's own node) with a clean `onTimeout`, a
  graceful bail when promotion is refused, and `stopWithTask=false` so swiping the app away
  doesn't abandon a half-finished on-chain operation. Add a BootReceiver restart and a
  battery-exemption affordance.
- `AlarmManager` is not a schedule on modern Android — `setInexactRepeating` can simply never
  fire under Doze/OEM battery management. Drive periodic work from the node's own **NEWBLOCK
  heartbeat** (~50 s) with your own debounce; and debounce at the worker (starting an
  already-running service delivers `onStartCommand` again — every tick does the work twice).
- Run node commands off the broadcast main thread (`NetworkOnMainThreadException` for anything
  opening a socket) — but know the serialized-executor cost: ONE slow command (a 47 s `history`
  on an unindexed table) stalls every companion at once against their 30 s timeouts.
- Newer Android blocks cleartext HTTP even to loopback — a localhost sidecar API fails with
  "Cleartext HTTP traffic to 127.0.0.1 not permitted". Add a network-security-config exception
  for 127.0.0.1/localhost only.
- There is no SHA3 JCA provider on Android — inject one (BouncyCastle) at the top of EVERY
  process entry point, not just the main activity (onboarding flows run before it).
  `BigInteger.TWO` is API 33+ — test on your minSdk.

### Heap and storage reality on phones

- `dalvik.vm.heapgrowthlimit` vs `heapsize` differ per OEM, so `largeHeap="true"` is sometimes a
  doubling and sometimes a no-op — express every heap threshold as a fraction of
  `Runtime.maxMemory()`, never absolute MB. Mainnet MegaMMR needs ~1.2 GB RAM, so a 512 MB-heap
  phone must run `-megammr` PLUS `-megaprune`. OOM is an `Error` — `catch(Exception)` lets it
  kill the node; stream imports in batches with an in-flight heap watermark.
- ★ Never ship `-rpcenable` without `-rpcpassword` — the embedded node's HTTP server binds every
  interface and only checks credentials when a password is set. Generate a SecureRandom password
  at start (and mint IPC auth tokens with SecureRandom, never `java.util.Random`).
- Node file outputs (`backup`, `megammr action:export`, `txnexport`) land in the node's private
  files dir. If you bridge file access, admin-gate it, canonically resolve and contain every
  path to the base folder, and write-protect the live `databases/` folder — a file manager must
  never be able to corrupt the running wallet DB.
- The adaptive paged coin sweep in detail: query coins over `[coinage, depth]` age windows, halve
  the span on overflow down to single blocks, double on success, accumulate deduped by coinid.
  Tip-anchored depth ladders are all-or-nothing for same-vintage coins (20 coins × 14 KB embedded
  token metadata = one 383 KB reply = empty result). Cache the whole-wallet list briefly and
  filter locally so N collections cost one query — and conversely, don't cargo-cult the paging
  machinery into an app whose replies are 13 KB.
