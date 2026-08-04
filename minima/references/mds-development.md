# MDS MiniDapp Development

End-to-end guide to building a MiniDapp on **MDS** — the MiniDapp System, the app runtime
built into every Minima node. A MiniDapp is a self-contained web app (HTML/JS/CSS) that the
node serves over HTTPS and drives through a single JavaScript bridge, `MDS`. There is no
server to run: your code executes in the node's browser context (the page) and, optionally,
in a persistent background worker (`service.js`).

---

## MDS gotchas (read first)

These are the failures that cost the most time. Every one is silent — nothing throws.

- **`service.js` is ES5-only (Nashorn/Rhino).** No `async`/`await`, `Promise`, `Set`, arrow
  functions, `let`/`const`, or template literals. A single one makes the file fail to parse
  and **the daemon silently never starts**. Plain `var` + `function` + callbacks only.
- **256 KB reply cap → empty results, not an error.** A command reply over 256 KB trips the
  node's "too long" stub and you get an **empty** payload back. Bound every scan:
  `history max:4`, `depth:400`, coin queries limited.
- **Validate every `MDS.cmd` hop, `txndelete` on every error path.** Semicolon-chained
  commands return an **array** where each step fails independently. Null-check each hop; on
  any failure delete the transaction or it becomes a zombie that locks your coins.
- **Page and service share ONLY SQL.** `index.html` and `service.js` are two separate JS
  contexts. They do not share variables, closures, or memory — only the MiniDapp's SQL
  database and one-way `MDS.comms.solo()` messages.
- **SQL columns come back UPPERCASE.** `row.BLOCKNUMBER`, never `row.blockNumber`, regardless
  of how you cased the `CREATE TABLE`.
- **Every MDS function is async.** Treating `MDS.cmd`/`MDS.sql`/`MDS.file.*` as synchronous
  returns `undefined` and fails silently. Continue work **inside** the callback.

---

## Setup

### Option A — mds.js via `<script>` (plain JS)

Copy `mds.js` from the Minima repo into your MiniDapp folder and include it:

```html
<script type="text/javascript" src="mds.js"></script>
```

`MDS` is then a global. This is the only option that works for `service.js` (which is
loaded by the node, not bundled).

### Option B — `@minima-global/mds` (TypeScript SDK)

```bash
npm install @minima-global/mds
```

```typescript
import { MDS, MinimaEvents } from "@minima-global/mds";
```

The SDK ships types for the event payloads and command responses. Use it for the page/UI in
a bundled app; `service.js` still has to be hand-written ES5.

### The init pattern

Nothing works before `inited`. Register one handler and branch on `msg.event`:

```javascript
MDS.init(function (msg) {
  if (msg.event === "inited") {
    // MDS is ready — safe to run commands
    MDS.cmd("balance", function (res) {
      console.log(res.response);
    });
  }
});
```

### React / TypeScript note

In React, call `MDS.init()` **once** — inside a top-level `useEffect(() => { ... }, [])`
(or an app-bootstrap module), never inside a component that re-renders, or you register the
handler multiple times and every event fires N times. Push event data into state
(`useState`/store) from the init callback; render from state. Keep all `MDS.*` calls out of
render. The npm SDK's `MinimaEvents` enum gives you typed event names.

---

## The events to handle

`MDS.init`'s callback receives every event as `msg` with `msg.event` and (usually)
`msg.data`. Handle these:

| Event | Meaning | Payload |
|---|---|---|
| `inited` | MDS is ready; run first commands | none |
| `NEWBLOCK` | Chain tip advanced | `msg.data.txpow` — full TxPoW of the new block (`msg.data.txpow.header.block` = height) |
| `NEWBALANCE` | An unconfirmed coin arrived / balance changed | no useful data — call `MDS.cmd("balance")` to read it |
| `MINING` | Mining started/ended | `msg.data` = TxPoW object; started `true` / ended `false` |
| `MINIMALOG` | A new log line is available | the log message |
| `MDSAPI` | An API message from another MiniDapp (see `MDS.api.call`) | `msg.data` with the request + a `requestid` to reply to |
| `MDSFAIL` | A command failed at the bridge level | error info |
| `MAXIMA` | A Maxima message was received | `msg.data` — application, from, and data |

Also emitted: `MDS_TIMER_10SECONDS`, `MDS_TIMER_1HOUR` (periodic ticks — handy for polling
in `service.js`), `MDS_PENDING` (fires when the user accepts a pending transaction from the
Pending MiniDapp), `MDS_SHUTDOWN` (2 s warning before the MiniDapp system stops), and
`MDSCOMMS` (a `MDS.comms.solo`/`broadcast` message arrived — `msg.data.public` is `false`
for solo, and `msg.data.message` is the string you sent).

---

## MDS.cmd — running node commands

`MDS.cmd("<command with key:value args>", callback)`. The callback gets a response object;
its shape depends on the command:

```javascript
MDS.cmd("balance", function (res) {
  // res.response is an ARRAY of token balances:
  // { confirmed, unconfirmed, sendable, tokenid, token, coins, total }
  var confirmed = res.response[0].confirmed;   // tokenid "0x00" = Minima
});

MDS.cmd("getaddress", function (res) {
  // res.response.address (0x hex), .miniaddress (Mx…), .publickey, .script
  var addr = res.response.miniaddress;
});

MDS.cmd("send address:0xFF..DE amount:1.5", function (res) {
  if (res.error) { /* show res.error */ } else { /* sent */ }
});
```

### Chain-validation discipline

Semicolon-chained commands run in sequence and return an **array**, one entry per step. Any
step can fail while later steps come back `undefined`. **Every caller must null-check each
hop, and every error path must call `txndelete`** to avoid zombie transactions that hold
coins locked.

```javascript
// WRONG — crashes if any step failed
var chain = "txnimport id:" + txid + " data:" + txndata + ";"
          + "txnsign id:" + txid + " publickey:0xFF..AA;"
          + "txnexport id:" + txid + ";"
          + "txndelete id:" + txid + ";";
MDS.cmd(chain, function (resp) {
  callback(resp[2].response.data);   // resp[2] may be undefined
});

// RIGHT — validate every hop, clean up on failure
MDS.cmd(chain, function (resp) {
  if (!resp || !resp[0] || !resp[0].status) {
    MDS.log("txnimport failed: " + JSON.stringify(resp && resp[0] && resp[0].error));
    MDS.cmd("txndelete id:" + txid);            // never leave a partial txn
    callback(null);
    return;
  }
  if (!resp[2] || !resp[2].response) {
    MDS.log("txnexport failed");
    MDS.cmd("txndelete id:" + txid);
    callback(null);
    return;
  }
  callback(resp[2].response.data);
});
```

Route all transaction builders through **one helper that guarantees `txndelete`** on every
exit — success and failure. `txnimport` in particular can throw `EOFException` on truncated
data (common with large Maxima messages); it fails inside `service.js` with no browser
console trace, so always check `resp.status` before continuing.

### Async discipline

Every `MDS.*` function is async/callback. There is no synchronous return value — reading one
gives `undefined`.

```javascript
// WRONG
var outcome = computeOutcome(a, b);   // undefined
var r = outcome.result;               // throws / NaN

// RIGHT
computeOutcome(a, b, function (outcome) {
  var r = outcome.result;             // continue here, inside the callback
});
```

A whole transaction lifecycle is nested callbacks; if one link forgets its callback, the
chain stalls silently and no notification is ever sent.

---

## SQL (MDS.sql / H2)

Each MiniDapp gets a private H2 SQL database. Use it for persistent, multi-field, queryable
data. `MDS.keypair` is for simple settings.

```javascript
MDS.sql(
  "CREATE TABLE IF NOT EXISTS `metrics` (" +
  " `id` bigint auto_increment," +
  " `blockNumber` int NOT NULL," +
  " `blockHash` varchar(160) NOT NULL," +
  " `recipe` text," +               // NOT varchar — see quirk below
  " `blockSpeed` float NOT NULL)", function (res) { /* res.status */ });

MDS.sql("INSERT INTO metrics (blockNumber, blockHash) VALUES (100, '0xabc')", cb);

MDS.sql("SELECT * FROM metrics ORDER BY blockNumber DESC LIMIT 10", function (res) {
  if (res.status) {
    res.rows.forEach(function (row) {
      console.log(row.BLOCKNUMBER, row.BLOCKSPEED);   // UPPERCASE columns
    });
  }
});
```

### SQL quirks (all silent)

- **Columns return UPPERCASE** in `res.rows`, regardless of `CREATE TABLE` casing. Use
  `row.BLOCKNUMBER`.
- **`varchar(1024)` silently TRUNCATES.** A covenant script recipe can be ~1300 chars, so the
  row is silently dropped/cut. Use **`text`** for anything that can exceed the width, and
  verify column widths against the node's actual H2 engine.
- **An `UPDATE` can affect 0 rows while the callback still fires with `status:true`** (row
  didn't match, table locked, etc.). For any critical update, **verify with a follow-up
  `SELECT`** — don't trust the callback firing as proof the write landed.
- **Single-writer coordination:** page and service can both fire. Coordinate a single writer
  through a shared table with a `PRIMARY KEY` (and `INSERT … ` that fails on duplicate) so
  concurrent inserts from both contexts fail harmlessly instead of double-counting. Dedup by
  primary key, never check-then-insert (that races).
- **Cap unbounded tables** with a clip after each insert:

```javascript
MDS.sql("DELETE FROM metrics WHERE id NOT IN " +
        "(SELECT id FROM metrics ORDER BY blockNumber DESC LIMIT 4320)", function () {});
```

---

## File operations (MDS.file.*)

Files live in the MiniDapp's private data folder; a separate **web folder** serves assets
from the app's web root.

```javascript
MDS.file.save("data.json", JSON.stringify(obj), cb);        // write text/JSON
MDS.file.load("data.json", function (res) { JSON.parse(res.response); });

MDS.file.savebinary("f.bin", hexString, cb);                // binary is HEX-encoded
MDS.file.loadbinary("f.bin", function (res) { var hex = res.response; });

MDS.file.list("/", cb);                                     // list data folder
MDS.file.getpath("data.json", cb);                          // absolute path on node
MDS.file.copy("a.json", "b.json", cb);
MDS.file.move("old.json", "new.json", cb);
MDS.file.delete("f.json", cb);
MDS.file.makedir("myfolder", cb);

MDS.file.listweb("/", cb);                                  // web folder
MDS.file.copytoweb("local.js", "web/file.js", cb);
MDS.file.deletefromweb("web/file.js", cb);

MDS.file.upload(fileObject, cb);                            // chunks at 1 MB
MDS.file.download(url, cb);
```

---

## Key-value storage (MDS.keypair)

Simple per-MiniDapp settings. Async like everything else.

```javascript
MDS.keypair.set("username", "alice", cb);
MDS.keypair.get("username", function (res) { var v = res.value; });
```

---

## Inter-MiniDapp communication

All of these are **one-way** message primitives — there is no request/response socket.

```javascript
// Fire-and-forget to ALL MiniDapps
MDS.comms.broadcast("Hello all", cb);

// Fire-and-forget to your OWN service.js / page (same MiniDapp)
MDS.comms.solo(JSON.stringify({ type: "GAME_RESULT", winner: "player" }), cb);
// received as event MDSCOMMS: msg.data.public === false, msg.data.message === the string

// Named API to another MiniDapp — arrives there as an MDSAPI event
MDS.api.call("OtherDappName", data, function (reply) {
  console.log(reply.status, reply.data);
});
// the receiver answers with the requestid from its MDSAPI event:
MDS.api.reply("OtherDappName", requestId, responseData, cb);

// Get a link/URL to another installed MiniDapp
MDS.dapplink("OtherDappName", function (res) {
  if (res.status) window.location = res.base;
});
```

---

## Notifications, utilities, params, logging

```javascript
MDS.notify("Transaction sent!");     // system notification
MDS.notifycancel();

MDS.util.hexToBase64(hex);           // strip 0x first
MDS.util.base64ToHex(b64);
MDS.util.base64ToArrayBuffer(b64);
MDS.util.getStateVariable(coin, port);   // read a coin's state var

var uid = MDS.form.getParams("uid");     // read a GET param from the URL, or null

MDS.log("message");                  // → "Minima @ [timestamp] : message"

MDS.net.GET("https://api.example.com/data", cb);      // external HTTP (may be CORS-limited)
MDS.net.POST("https://api.example.com/post", "k=v", cb);
```

---

## service.js — the background worker

`service.js` runs persistently on the node even when the UI is closed. It is where all the
serious work goes: message handling, DB writes, signing.

### ES5 ONLY

The service worker is Nashorn/Rhino. **Forbidden:** `async`/`await`, `Promise`, `Set`,
arrow functions, `let`/`const`, template literals, and any other ES6+ syntax. Any single one
→ parse failure → **the daemon silently never starts**, no error anywhere. Write plain ES5:
`var`, `function`, string concatenation, callbacks.

```javascript
// service.js — ES5, callbacks only
MDS.load("dapplib.js");          // pull in shared functions

MDS.init(function (msg) {
  if (msg.event == "inited") {
    createDB(function () { MDS.log("service ready"); });
  } else if (msg.event == "NEWBLOCK") {
    saveNewBlock(msg);
  } else if (msg.event == "MAXIMA") {
    handleMaxima(msg.data);      // the brain handles ALL messages here
  }
});
```

### One Brain, One Screen

For any MiniDapp with background processing (games, channels, messaging, metrics):

```
service.js = THE BRAIN  — processes all messages, updates DB, signs transactions
index.html = THE SCREEN — displays notifications, handles user clicks
```

Rules:

- `service.js` **NEVER touches the DOM** (it has none).
- `index.html` **NEVER processes Maxima messages** (the one exception is a SYNACK/ACK
  handshake for user-initiated actions).
- Communication is **one-way**: `service.js → index.html` via `MDS.comms.solo()`.
- **One notification per event, one display update per notification.** Update stats,
  balances, logs in exactly one place — this is what prevents double-counting.

```javascript
// service.js — the ONLY place a result is computed, then announced once
function notify(data) { MDS.comms.solo(JSON.stringify(data)); }
notify({ type: "GAME_RESULT", result: 3, winner: "player", betamt: "10" });

// index.html — the ONLY place a result is rendered
MDS.init(function (msg) {
  if (msg.event === "MDSCOMMS" && !msg.data.public) {
    var comms = JSON.parse(msg.data.message);
    if (comms.type === "GAME_RESULT") onGameResult(comms);   // display only
  }
});
```

Persist-before-broadcast: write to SQL first, then `solo()`, so the screen reading the DB
always sees a consistent state.

---

## READ vs WRITE permission modes

A MiniDapp installs as **READ** by default; the user must explicitly grant **WRITE**
(`mds action:permission uid:0x.. trust:write`). This is a real runtime gate, not advice:

- On a **read-only** node, the `txncheck` post-gate simply **never posts** — privileged
  actions produce a pending-approval prompt or silently do nothing.
- An app that wants to **run clean in READ mode** (no approval prompts) must **drop
  privileged calls** — e.g. don't call `mds action:list`; read your version from a constant
  instead.
- A daemon that **needs WRITE** to function must **tell the user**, or it "looks fine but
  isn't" — the UI renders while the background actions silently no-op.

Never give WRITE to a MiniDapp you don't trust: WRITE is effectively full node access.

---

## MiniDapp structure + dapp.conf

```
myminidapp/
├── dapp.conf        # name, version, description, icon (required)
├── favicon.ico
├── index.html       # the screen
├── service.js       # the brain (optional, runs persistently — ES5 only)
├── styles.css
└── mds.js           # copy from the Minima repo
```

```json
{
  "name": "MyMiniDapp",
  "version": "1.0.0",
  "description": "What this MiniDapp does",
  "icon": "favicon.ico"
}
```

Package with `zip -r mydapp.mds.zip *` and install via the MiniHub UI
(`https://127.0.0.1:<MDS_PORT>`) or `mds action:install file:mydapp.mds.zip`. Full packaging
and distribution (stores, manifests, versioning) is covered in
`references/distribution-packaging.md`.

---

## Reference pattern 1 — minimal Wallet MiniDapp

`index.html` only. Shows balance + address, sends Minima. Re-reads balance on `NEWBALANCE`.

```html
<html>
  <head><script type="text/javascript" src="mds.js"></script></head>
  <body>
    <p>Balance: <span id="balance">0</span> (unconfirmed <span id="unconfirmed">0</span>)</p>
    <p>Address: <span id="address"></span></p>
    <input id="sendAddress" placeholder="Mx… or 0x…">
    <input id="amount" placeholder="amount">
    <button onclick="Send()">Send</button>
    <p id="status"></p>

    <script>
      function GetBalance() {
        MDS.cmd("balance", function (res) {
          if (!res.response || !res.response[0]) return;
          document.getElementById("balance").innerText =
            JSON.stringify(res.response[0].confirmed).slice(1, -1);
          document.getElementById("unconfirmed").innerText =
            JSON.stringify(res.response[0].unconfirmed).slice(1, -1);
        });
      }
      function GetAddress() {
        MDS.cmd("getaddress", function (res) {
          document.getElementById("address").innerText =
            JSON.stringify(res.response.miniaddress).slice(1, -1);
        });
      }
      function Send() {
        var addr = document.getElementById("sendAddress").value;
        var amt  = document.getElementById("amount").value;
        MDS.cmd("send address:" + addr + " amount:" + amt, function (res) {
          document.getElementById("status").innerText = res.error ? res.error : "Sent!";
        });
      }
      MDS.init(function (msg) {
        if (msg.event === "inited")     { GetBalance(); GetAddress(); }
        if (msg.event === "NEWBALANCE") { GetBalance(); }
      });
    </script>
  </body>
</html>
```

> Note: build commands from validated input only. Never concatenate an unvalidated value
> into a command string — `;` and quote-escapes let a crafted value append arbitrary commands
> at your privilege. Validate against a strict charset (hex/decimal) before interpolating.

---

## Reference pattern 2 — MiniStats metrics dashboard

Split across `service.js` (collect into SQL) and `index.html` (render). Demonstrates the
One-Brain/One-Screen split with SQL as the only shared state.

### service.js — collect on every block

```javascript
MDS.load("ministats.js");

MDS.init(function (msg) {
  if (msg.event == "inited") {
    createMetricsTable(function () { MDS.log("ready"); });
  } else if (msg.event == "NEWBLOCK") {
    saveNewBlock(msg);
  }
});
```

### ministats.js — shared ES5 logic

```javascript
function createMetricsTable(cb) {
  MDS.sql(
    "CREATE TABLE IF NOT EXISTS `metrics` (" +
    " `id` bigint auto_increment," +
    " `blockTime` varchar(160) NOT NULL," +
    " `blockHash` varchar(160) NOT NULL," +
    " `blockDifficulty` varchar(160) NOT NULL," +
    " `blockNumber` int NOT NULL," +
    " `blockSpeed` float NOT NULL," +
    " `chainWeight` varchar(160) NOT NULL," +
    " `cascadeWeight` varchar(160) NOT NULL)", function (res) { if (cb) cb(res); });
}

function saveNewBlock(msg) {
  var blockNumber = parseInt(msg.data.txpow.header.block);
  isBlockSaved(blockNumber, function (saved) { if (!saved) buildMetricRow(blockNumber); });
}

function isBlockSaved(blockNumber, cb) {
  MDS.sql("SELECT * FROM metrics WHERE blockNumber = " + blockNumber, function (res) {
    cb(res.status && res.rows.length > 0);      // dedup by primary key in production
  });
}

function buildMetricRow(blockNumber) {
  MDS.cmd("status", function (msg) {
    var c = msg.response.chain;
    storeMetric({ time: c.time, blockHash: c.hash, blockSpeed: c.speed,
      chainweight: c.weight, difficulty: c.difficulty,
      cascadeWeight: c.cascade.weight, blockNumber: blockNumber });
  });
}

function storeMetric(m) {
  var MAX = 4320;   // ~1 day at 20s/block
  MDS.sql(
    "INSERT INTO metrics (blockTime,blockHash,cascadeWeight,blockSpeed,chainWeight,blockDifficulty,blockNumber) " +
    "VALUES ('" + m.time + "','" + m.blockHash + "'," + m.cascadeWeight + "," + m.blockSpeed +
    ",'" + m.chainweight + "','" + m.difficulty + "'," + m.blockNumber + ")",
    function (res) { MDS.log(res.status ? "saved" : "failed"); });
  MDS.sql("DELETE FROM METRICS WHERE id NOT IN " +
          "(SELECT id FROM METRICS ORDER BY blockNumber DESC LIMIT " + MAX + ")", function () {});
}
```

### index.html — render (Chart.js)

```javascript
MDS.init(function (msg) {
  if (msg.event === "inited")   { displayMetrics(); displayCharts(); }
  else if (msg.event === "NEWBLOCK") { displayMetrics(); }   // avoid full reload if possible
});

function displayMetrics() {
  MDS.cmd("status", function (msg) {
    var c = msg.response.chain;
    document.getElementById("current-block").innerText = c.block;
    document.getElementById("block-speed").innerText   = (1 / c.speed).toFixed(1) + " s/block";
    document.getElementById("chain-weight").innerText  = c.weight;
    document.getElementById("total-weight").innerText  = msg.response.weight;
  });
}

function showChart(limit, canvasId, labelId) {
  MDS.sql("SELECT * FROM metrics ORDER BY blockNumber DESC LIMIT " + limit, function (res) {
    if (!res.status) return;
    var rows = res.rows;                           // columns UPPERCASE
    if (rows.length < limit) {
      document.getElementById(labelId).innerText = "N/A (< " + limit + " blocks)";
      return;
    }
    var total = 0, xdata = [], ydata = [];
    rows.forEach(function (row) {
      total += parseFloat(row.BLOCKSPEED);
      xdata.push(row.BLOCKNUMBER);
      ydata.push(parseFloat(1 / row.BLOCKSPEED));
    });
    document.getElementById(labelId).innerText = (1 / (total / rows.length)).toFixed(1) + " s/block";
    new Chart(canvasId, { type: "line",
      data: { labels: xdata.reverse(), datasets: [{ fill: false, data: ydata.reverse() }] },
      options: { legend: { display: false } } });
  });
}

function displayCharts() { showChart(10, "c1", "l1"); showChart(100, "c2", "l2"); }
```

---

## 2026 production gotchas

Hard-won lessons from real MiniDapps (wallets, history scanners, AMM pools, channels).

### The 256 KB reply cap — silent empty results

A command reply over **256 KB** trips the node's "too long" stub and returns **empty
results, not an error**. `history max:50` came back empty; `history max:4` (~160 KB) works.

- **Bound every scan.** `history max:4`, `depth:400`, cap coin/output counts.
- Don't `coinnotify action:add` a shared address without later removing it — the node retains
  every dust beacon posted there, growing the `scripts` reply without bound until it overflows
  the cap.

### The txncheck post-gate — read the verdict, not the count

Post a transaction only if **all** of these are truthy, else `txndelete`:

```javascript
function truthy(v) { return v === true || v === 1 || v === "1" || v === "true"; }

MDS.cmd("txncheck id:" + txid, function (res) {
  var r = res.response;
  if (truthy(r.valid.scripts) && truthy(r.validamounts) && truthy(r.valid.mmrproofs)) {
    MDS.cmd("txnpost id:" + txid);
  } else {
    MDS.cmd("txndelete id:" + txid);   // fail closed
  }
});
```

- It is **`valid.scripts`** (the covenant pass/fail verdict) — **NOT** the top-level
  `scripts` (a count). Reading the count instead of the verdict posts invalid transactions.
- The flags are **inconsistently typed** — sometimes bool, int, or string — so always route
  them through a `truthy()` helper accepting `true / 1 / "1" / "true"`.

### `history` response shape

`details[]` carry **no `txpowid`** and are **index-parallel** to `txpows[]` — associate them
by array index. Their inputs/outputs are token-sum maps, not coin arrays. Index-pair or
personal history renders nothing.

### Owner-coin funding exclusion

When funding a transaction against a contract, **exclude the pool/owner addresses** (each
`$OADR`) from coin selection, or `txnsign publickey:auto` may sign with the owner key
(`$OPK`) and trip the covenant's owner branch. Prefer signing with an **explicit public
key**, never `auto` — auto selection can conscript unrelated wallet keys into inputs you
never meant to spend.

### `newaddress` keys regenerate ASYNC after a seed restore

`newaddress` keys (index ≥ 64) are regenerated **asynchronously** after a seed-only restore.
Acting too soon fails with **"signing failed: Public Key not found."** Wrap sign call-sites
in an `ensureKeys([pubkey])` check (a no-op when the key is already held) before signing. Do
**NOT** bulk-regenerate keys on launch — it triggers a 256-key / pending-approval storm on a
re-paired node.

```javascript
function ensureKeys(pubkeys, done) {
  MDS.cmd("keys action:list", function (res) {
    var have = {};
    (res.response || []).forEach(function (k) { have[k.publickey] = true; });
    var missing = pubkeys.filter(function (p) { return !have[p]; });
    if (missing.length === 0) { done(true); return; }
    // regenerate only what's missing, one at a time; never bulk-regen on launch
    done(false);
  });
}
```

### Re-entrancy guard with a stuck-timeout on scan()

Page and service can both fire a scan concurrently. Guard with a flag **and** a stuck-timeout
so a crashed scan can't wedge the app forever:

```javascript
var scanning = false, scanStart = 0;
function scan() {
  var now = Date.now();
  if (scanning && (now - scanStart) < 120000) return;   // 2-min stuck-timeout releases it
  scanning = true; scanStart = now;
  doScan(function () { scanning = false; });
}
```

### Best practices

| Do | Why |
|---|---|
| Bound every `history`/scan (`max:4`, `depth:400`) | 256 KB cap returns empty, not error |
| Validate every `MDS.cmd` hop + `txndelete` on error | zombie txns lock coins |
| Sign with an explicit public key, never `auto` | avoid conscripting unrelated keys |
| Use `text` not `varchar(1024)` for scripts/recipes | `varchar` silently truncates ~1300-char recipes |
| Verify critical `UPDATE`s with a `SELECT` | UPDATE can affect 0 rows, callback still fires |
| Coordinate a single writer via a `PRIMARY KEY` table | page + service share only SQL |
| Persist to SQL before `comms.solo()` broadcast | screen always sees consistent state |
| Store contract addresses in coin state, use `$OADR`/PREVSTATE | `getaddress` returns different addresses over time |
| Set unused state ports to `0` | unset STATE ports crash the KISS VM |
| Keep ES6+ out of `service.js` | any ES6 → silent parse failure, daemon never starts |

### Common issues

| Symptom | Cause / fix |
|---|---|
| `service.js` never runs, no error | ES6 syntax in it → parse failure. Rewrite as ES5. |
| Query returns empty for no reason | reply exceeded 256 KB. Lower `max`/`depth`. |
| `resp[2]` is undefined in a chain | an earlier hop failed. Null-check each; `txndelete`. |
| Coin stays locked / can't spend | UTXO-locked until the previous txn confirms; also a leaked partial txn — `txndelete`. |
| `row.blockNumber` is undefined | columns are UPPERCASE — use `row.BLOCKNUMBER`. |
| Recipe rows silently missing | `varchar` truncation — switch the column to `text`. |
| "Public Key not found" after restore | `newaddress` keys still regenerating — `ensureKeys` before signing. |
| Privileged call silently no-ops | node is in READ mode — tell the user or drop the call. |
| Stale session / `serviceWorker Frame removed` noise | reopen the MiniDapp from MiniHub for a fresh session; the console noise is Chrome-extension chatter, not your bug. |

---

## Security lessons (fold into every MiniDapp)

These are pattern-level hazards, each stated as *hazard → what to do instead*.

- **Never build node commands by string concatenation with untrusted values.** `;` separates
  commands, so an unvalidated parameter appends arbitrary commands at the builder's privilege
  — and a value inside a quoted argument can close the quote and append more `key:value`
  tokens. Rejecting `;` alone is insufficient. Validate against a strict charset, or use a
  structured call interface.
- **Blocklist SQL "sanitisers" do not work.** Stripping `;`/`update`/`delete` from a free-form
  `where:` still allows unions, subqueries and comments. Drop free-form SQL fragments from any
  API; expose only typed, bound parameters.
- **Treat wallet *read* access as privileged.** Address, coin, balance and key-use enumeration
  deanonymises the whole wallet and feeds signature-reuse targeting. Require per-app,
  user-approved scopes — don't grant it to anything that can't spend. Don't ship a permission
  model that's commented out.
- **Escape every chain-sourced string before it reaches HTML.** Token names, state variables,
  app names and log details are attacker-writable and render in dashboards — unescaped output
  is stored XSS in your own session. Auto-escape on output and add a CSP.
- **Never treat an inbound notification/message as on-chain truth.** Anyone can forge a
  "payment received" event. A coinid, amount or address in an inbound message is
  attacker-controlled — resolve it yourself from your own chain scan by an immutable on-chain
  key and compare, then confirm against your node's chain view.
- **Never co-sign a transaction you didn't reconstruct yourself.** Importing counterparty hex
  and signing authorises every input it contains, including yours the attacker added. Require
  an exact match against outputs you recompute locally (address, amount, token, burn, state)
  and abort otherwise. Sign with an explicit key, never `auto`.
- **Winternitz keys are one-time.** Two signatures under one leaf leak the private key.
  Serialise signing through one gate, claim the leaf index atomically before signing, and on
  key-tree exhaustion **refuse to sign — never wrap around** to leaf zero.
- **Dedup by primary key, not check-then-insert.** A `SELECT`-then-`INSERT` races under
  concurrent message delivery; use a `PRIMARY KEY` and an insert that no-ops on duplicate.
  Avoid a single global "pending transaction" slot — key pending state by nonce/id in a table.
- **Validate input; return generic errors.** Unchecked `parseInt`, blind JSON casts and
  indexing possibly-empty arrays turn malformed input into unhandled exceptions; raw exception
  text discloses hosts, schema and versions. Validate types and lengths, log detail internally
  only.
- **Enforce security invariants at one greppable chokepoint.** "Transaction import happens in
  exactly one place, and nothing reaches signing without inspection returning clean" is
  mechanically verifiable after every change; the same rule spread across call sites is not.
- **Fail closed when a response doesn't match expectations.** If a validation gate can't find
  the field it expects in a node response, it must reject. Unknown shape = unknown state.
- **Client checks and contract enforcement are two layers — build both.** Inspection stops a
  bad transaction being signed; the covenant stops a co-signed one settling. Design so either
  alone rejects the theft.
</content>
</invoke>
