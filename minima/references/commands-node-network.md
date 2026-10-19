# Minima Command Reference — Part 2: Node, Network, Backup, Maxima & System

Command reference for the node/network/backup/archive/Maxima/system command surface.
Wallet, coin, token, transaction, script and crypto commands are in
`commands-wallet-transactions.md` (Part 1).

Conventions used throughout:

- `[param:]` = required, `(param:)` = optional (same notation as `help`).
- Every command returns a JSON envelope: `{"command": ..., "status": true|false, "pending": false, "response": {...}}`. `status:false` carries an `error` string. `pending:true` means an MDS MiniDapp in READ mode queued the command for user approval (see `checkpending`).
- Over HTTP RPC the command is the URL path: `curl 127.0.0.1:9005/status` (the default RPC port is the base port + 4, i.e. `9005` for a default `9001` install; RPC is **off** by default — see `rpc`).
- Multiple commands can be chained with `;`.

> ⚠️ **Global transport hazard — the 256 KB response cap.** The node refuses to return any single command response larger than 256,000 bytes ("`results too long! max ( 256000 )`"). Over RPC/MDS the oversized reply comes back **empty**, not as an error object, so callers silently get no data. Commands that return full TxPoW bodies (`history`, `txpow`, deep `printtree`) hit this easily. Pattern that works: **adaptive paging** — start with a small page (`max:8`), and on any empty/over-limit reply halve the page size (8 → 4 → 2 → 1) and retry the same offset. Never assume a fixed page size is safe.

---

## Node status & chain

### status

```
status (clean:true)
```

General node status: version, uptime, memory, chain info, stored TxPoW units, network and P2P connections, traffic. `clean:true` additionally clears RAM.

Key response fields: `version`, `uptime`, `locked` (true = Vault password-locked), `length`, `weight`, `minima` (total supply), `coins`, `data` (data-folder path), `memory{ram, disk, files}`, `chain{block, time, hash, speed, difficulty, size, length, weight, branches, cascade{start, length}}`, `txpow{mempool, ramdb, txpowdb, archivedb}`, `network{...connections, traffic...}`.

```
status
→ response.chain.block      current top block height
  response.locked           is the vault password-locked
  response.network          peer/connection details
```

This is the cheapest "is the node alive and synced" probe — poll `status` (or `block`), never `history`.

### block

```
block
```

Return just the current top block. Response fields: `block`, `hash`, `timemilli`, `date`. Much lighter than `status` when you only need the height.

```
block
→ {"block":"850123","hash":"0x0000..","timemilli":"1722..","date":"..."}
```

### history

```
history (action:list|size|customsize|transactions) (max:) (offset:) (depth:) (relevant:) (where:)
```

Return TxPoW relevant to you (default `action:list`, default `max` 100 — can be slow).

- `action:size` — count of your transactions (`relevant:false` counts all).
- `action:transactions` — how many transactions in chain over `depth:` blocks.
- `action:customsize where:"..."` — SQL WHERE clause against the TxPoWDB, e.g. `where:"isblock=1 AND timemilli>1728037509020"`.
- `relevant:` — your transactions (default true) or all.

Each list entry is a **full TxPoW**: `txpows[].body.txn.inputs[]/outputs[]` (with `coinid`, `address`, `miniaddress`, `amount`, `tokenid`), `header.block`, `header.timemilli` — enough to classify sent/received/self client-side.

```
history max:20 offset:45
history action:size relevant:false
```

> ⚠️ **IPC/RPC hazard — the single most dangerous command for transports.** `history action:list` always returns FULL TxPoW bodies (~14 KB each, much more for contract-heavy transactions; there is no "lite" mode). The default `max:100` easily exceeds 1 MB on an active wallet, and even `max:25` can exceed the node's 256 KB response cap, in which case the reply comes back empty. Use small adaptive pages (`max:8`, halve on empty, page with `offset:`), fetch only on demand (e.g. when a history view is visible), and never call `history` in a per-block loop.

### txpow

```
txpow (txpowid:) (onchain:) (block:) (address:) (relevant:) (max:)
```

Search for a specific TxPoW in the unpruned chain or your mempool.

- `txpowid:` — return the full TxPoW details.
- `onchain:` — check a txpowid is on chain; returns block info and confirmations.
- `block:` — return the block TxPoW at that height (header + `body.txnlist` of transaction txpowids).
- `address:` — TxPoWs containing this 0x/Mx address.
- `relevant:true`, `max:` (default 100) — restrict/paginate.

```
txpow txpowid:0x000..
txpow block:200
txpow onchain:0x000..
```

> ⚠️ **Hazard — the unpruned window.** `txpow address:` (and `block:`/`onchain:`) only search the **unpruned** chain — roughly the last ~13,000 blocks from tip. An empty result does NOT mean "no history", just "nothing recent". Older data needs an archive node — and even there, pruned archive blocks keep only the block-level TxPoW with its `txnlist`: the per-transaction `body.txn.inputs`/`outputs` come back as `[]` (that data is gone from the archive format itself). Coin creation/spend history survives via the MMR — use `archive action:addresscheck` for old activity.

### printtree

```
printtree (depth:) (cascade:true|false)
```

Print a text-art tree of the blockchain. Default depth 32 blocks from tip; `cascade:true` also shows the cascading chain.

```
printtree depth:500
```

> ⚠️ Large `depth:` values produce very large text output — over a size-capped RPC/IPC transport this can hit the 256 KB cap and return empty. A terminal diagnostic, not an API.

### checkmode

```
checkmode
```

Show whether the calling MiniDapp is in READ or WRITE mode (MDS context). Useful for a dapp to know up front whether writes will go to the pending queue.

```
checkmode
```

### checkpending

```
checkpending uid:0xFF..
```

Check whether a pending-command UID (returned when a READ-mode MiniDapp issues a write command) is still in the pending list awaiting user accept/deny.

```
checkpending uid:0xFF..
```

---

## Network

### network

```
network (action:list|reset|recalculateip)
```

Show network status. `list` (default) lists your direct peers with their `uid`, host/port, direction and connection state — the `uid` here is what `disconnect` and `message` take. `reset` restarts the traffic counter; `recalculateip` re-detects your IP (e.g. after changing WiFi).

```
network action:list
```

### connect

```
connect [host:ip:port]
```

Connect to another Minima node — to join the main network or to build a private test net.

```
connect host:spartacusrex.com:9001
```

### disconnect

```
disconnect [uid:uid|all]
```

Disconnect from one connected/connecting host (uid from `network`) or all of them.

```
disconnect uid:CVNPMLPOCQ0HQ
disconnect uid:all
```

### message

```
message [data:message] (uid:uid)
```

Send a plain string message over the P2P network to one direct peer (or all peers if `uid:` is omitted). This is **node-to-peer** messaging — for user-to-user messaging use `maxima action:send` (see the Maxima section).

```
message data:"hello" uid:CVNPMLPOCQ0HQ
```

### rpc

```
rpc (enable:) (ssl:) (password:) (action:adduser|removeuser|listusers) (username:) (mode:read|write)
```

Enable/disable the HTTP RPC server (default **off**; port = base port + 4, i.e. `9005` on a default install). Default user `minima` has write access; you can add read-only users.

```
rpc enable:true ssl:true password:minimarpcpassword
rpc action:adduser username:rpcuser password:rpcpassword mode:read
```

> ⚠️ The Basic-Auth password travels in headers and is **only secure when combined with SSL** (`ssl:true` for self-signed, or your own stunnel/reverse proxy). Always firewall the RPC port; never expose it raw to the internet.

### webhooks

```
webhooks (action:list|add|remove|clear) (hook:url) (filter:)
```

Register URLs that receive Minima events as HTTP POSTs as they happen (NEWBLOCK, NEWBALANCE, MINING, ...). `filter:` restricts which events get posted.

```
webhooks action:add hook:http://127.0.0.1/myapi.php filter:MINING
```

### p2pstate

```
p2pstate
```

Print full details of the internal P2P state: in/out connections and total known peers. (There is no command literally named `p2p` — the P2P surface is `p2pstate` + `peers`.)

```
p2pstate
```

### peers

```
peers (action:list|addpeers) (peerslist:)
```

Print or extend the peers list (P2P must be enabled). `action:addpeers` takes a CSV `peerslist:ip:port,ip:port,..`. Returns `peers-list`, `havepeers`, `p2penabled`.

```
peers action:addpeers peerslist:spartacusrex.com:9001
```

### nodecount

```
nodecount (file:) (complete:false|true)
```

Enumerate the network by recursively pinging peers starting from the default node list, to count all participating nodes. `file:` writes a CSV; `complete:true` does a full crawl.

```
nodecount
```

> ⚠️ This is a network **crawl** — it pings peer after peer and can take a long time and generate real traffic. Run it deliberately from a terminal; never poll it or call it from an app loop.

### healthcheck

```
healthcheck
```

Sanity-check that chain, cascade and Maxima all add up. Response: `chain{tip, root, chainlength}`, `cascade{tip, tipcorrect}` (`tipcorrect:true` = cascade tip meets the root of the TxPoW tree), `maxima{hosts, contacts}`.

```
healthcheck
```

---

## Backup & restore

### backup

```
backup (password:) (file:) (auto:) (maxhistory:)
```

Back up the node. Uses a timestamped filename in the Minima data folder by default. `password:` encrypts it (letters/numbers only); `auto:true` schedules an unencrypted backup every 24 h; `maxhistory:` caps how many relevant TxPoW are included.

```
backup password:Longsecurepassword456 file:my-backup-01-Jan-22.bak
backup auto:true
```

### restore

```
restore [file:] (password:)
```

Restore the node from a backup. Wipes and replaces current node state. You MUST wait until all the node's original keys have been created before this is allowed.

```
restore file:my-full-backup-01-Jan-22 password:Longsecurepassword456
```

### restoresync

```
restoresync [file:] (password:) (host:) (keyuses:)
```

Restore from a backup **and** sync to the top block from an archive node — use when the backup is old (falls back to a plain `restore` if the backup is under 2 days old). `keyuses:` *increments* (not sets) the per-key use counter.

```
restoresync file:my-full-backup-01-Jan-22 password:Longsecurepassword456 host:<archive-host>:9001
```

> ⚠️ **IPC hazard.** `restoresync` (like `archive action:resync` and `megammrsync`) opens a raw socket to the host synchronously inside the command. On embedded/IPC transports that forbid network on the calling thread (notably Android's broadcast-Intent IPC), the socket call is killed and the internal catch-all swallows it — you get a **misleading `"Could not connect to Archive host!"` even though the host is fine and was never contacted**. Run these commands from the node's own terminal or HTTP RPC on desktop.

### checkrestore

```
checkrestore
```

Check whether the node is currently mid-restore. Poll this (not `status`) after kicking off a restore; response says if restoring is complete and whether a shutdown is pending.

```
checkrestore
```

### decryptbackup

```
decryptbackup [file:] (password:) (output:)
```

Decrypt an encrypted backup file to a plain one without restoring it.

```
decryptbackup file:my-full-backup-01-Jan-22 password:Longsecurepassword456
```

### reset

```
reset [archivefile:] [action:chainsync|seedsync|restore] (file:) (password:) (phrase:) (keys:) (keyuses:)
```

Reset the entire system from an archive export file:

- `chainsync` — re-sync all blocks from the archive file to get on the right chain; keys unchanged, no seed phrase needed.
- `seedsync` — wipe the wallet, regenerate keys from `phrase:"24 WORDS.."`, restore coins.
- `restore` — restore a backup (`file:`/`password:`) then re-sync the whole chain from the archive file.

```
reset archivefile:archiveexport-jul23.gz action:seedsync keyuses:1000 phrase:"ENTER 24 WORDS HERE"
```

> ⚠️ Minima signatures are **stateful**: every time you seed-resync you must set `keyuses:` *higher* than any previous value (default 1000, max 262144 per key), or you risk reusing signature slots.

### vault

```
vault (action:seed|wipekeys|restorekeys|passwordlock|passwordunlock) (seed:) (phrase:) (password:)
```

BE CAREFUL. Manage your private keys:

- `seed` (default) — show your seed phrase and seed. Never share these.
- `wipekeys seed:0x..` — delete private keys from this node (public keys remain) — for turning an online node into a watch-only node.
- `restorekeys phrase:"24 WORDS.."` — reinstate private keys.
- `passwordlock` / `passwordunlock` — encrypt/decrypt private keys with a password.

```
vault action:passwordlock password:your_password confirm:your_password
```

> ⚠️ While the vault is locked, `status` shows `locked:true` and anything needing the seed fails (e.g. `seedrandom` throws "DB locked!"); signing commands accept a one-shot `password:` parameter that unlocks, signs, and relocks. Ensure you have a secure record of the passphrase BEFORE locking — there is no recovery without it.

### archive

```
archive [action:] (host:) (file:) (phrase:) (anyphrase:) (keys:) (keyuses:) (address:) (statecheck:) (logs:) (maxexport:)
```

Archive-node operations — chain/seed re-sync and archive-db inspection:

- `integrity` — check your archive db integrity (no host needed).
- `inspect file:` — inspect an archive export (`last:1` means it can resync any node from genesis).
- `export` / `exportraw` — export archive db to `.gzip` / raw `.dat` (raw recommended).
- `resync host:` — chain re-sync (no phrase; wallet untouched) or seed re-sync (`phrase:"24 WORDS.."` — wipes wallet, restores coins) from an archive node.
- `import file:` — same, from an export file.
- `addresscheck address:` — search the archive for spent/unspent coins at an address; add `statecheck:` (a pubkey/address in the coin state) to find coins locked in a contract for a particular user.

```
archive action:resync host:<archive-host>:9001
archive action:addresscheck address:0xFED.. statecheck:0xABC..
```

> ⚠️ **Hazards (several, all verified in practice):**
> - `archive action:integrity` takes **3+ minutes** — run once, NEVER poll it in a loop.
> - `addresscheck` with no `statecheck:` on a busy contract address frequently runs 300 s+ and times out with no result.
> - **Concurrent archive queries on one node can OOM the JVM**, especially in Docker containers with a bounded heap. Serialize archive work.
> - `action:resync` opens a raw socket inline — over Android-style IPC it fails with the misleading "Could not connect to Archive host!" (see `restoresync`).
> - Pruned archive blocks keep coin creation/spend data (via MMR) but NOT transaction inputs/outputs — see the `txpow` hazard.

---

## MegaMMR & sync

### megammr

```
megammr (action:info|export|import) (file:)
```

Info on, or import/export of, the MegaMMR data (the complete coin set + proofs). The node must be running with `-megammr`.

```
megammr action:export file:thefile
```

### megammrsync

```
megammrsync [action:mydetails|resync] [host:] (phrase:) (anyphrase:) (keys:) (keyuses:) (file:) (password:)
```

Fast chain or seed re-sync from a MegaMMR node (much faster than a full archive resync):

- Wrong chain, wallet intact → just `action:resync host:`.
- Fresh node, restore a wallet → add `phrase:"24 WORDS.."` (and a raised `keyuses:`).
- Old backup → `file:` + `password:` restores it, then syncs to tip.
- `action:mydetails` shows which addresses/public keys a resync would search for.

The host MUST be running `-megammr`.

```
megammrsync action:resync host:<your-megammr-host:9001> phrase:"YOUR 24 WORD SEED PHRASE" keyuses:2000
```

> ⚠️ **IPC hazard.** Same socket-inline behavior as `archive`/`restoresync`: over broadcast-Intent style IPC it fails with a misleading "Could not connect" error even when the host is reachable. Run from terminal/HTTP RPC.

---

## MySQL archive

### mysql

```
mysql (host:) (database:) (user:) (password:) (readonly:) (logs:) [action:] (phrase:) (keys:) (keyuses:) (address:) (enable:) (file:)
```

Mirror the archive data into a MySQL server (for scale-out archive/explorer backends). Actions:

- `setlogin` / `clearlogin` — store login details so you don't retype them (subsequent calls then need only `action:`).
- `info` — compare blocks in the node's archive db vs the MySQL db.
- `integrity` — verify block order/parents in MySQL.
- `update` — push the latest syncblocks from the node's archive db into MySQL.
- `autobackup enable:true` — continuously save archive data (and all TxPoW the node sees) to MySQL.
- `findtxpow txpowid:` — look up an individual TxPoW (requires autobackup).
- `addresscheck address:` — full spent/unspent coin history for an address.
- `resync` — chain or seed re-sync **from** the MySQL db (`phrase:` wipes + restores the wallet). Shuts the node down when done — you must restart it.
- `wipe` — careful: wipes the MySQL db.
- `h2export` / `h2import` / `rawexport` / `rawimport` — move data between MySQL and archive gzip / raw .dat files (raw is faster).

```
mysql host:127.0.0.1:3306 database:archivedb user:archiveuser password:archivepassword action:setlogin
mysql action:update
```

### mysqlcoins

```
mysqlcoins (host:) (database:) (user:) (password:) (readonly:) (logs:) [action:info|wipe|update|search] (where:) (query:) (address:) (spent:) (limit:) (maxcoins:)
```

Build and query a searchable **coins** table from your MySQL archive data (same database as `mysql`, new table). `action:search` accepts `where:` (SQL WHERE, string values in single quotes), a full `query:`, or a simple `address:` check with `spent:true/false` and `limit:`.

```
mysqlcoins action:search where:"address='0x791E..' spent:false limit:1"
```

> ⚠️ `action:update` can take a VERY long time on a full archive — bound it with `maxcoins:` and run it incrementally.

---

## Maxima

Maxima is Minima's off-chain information transport layer (user-to-user messaging over the node network).

### maxima

```
maxima [action:info|setname|seticon|hosts|send|sendall|refresh] (name:) (icon:) (id:)|(to:)|(publickey:) (application:) (data:) (poll:) (delay:)
```

Your Maxima identity and messaging:

- `info` — your name, publickey, staticmls, mls, local identity and current contact address.
- `setname` / `seticon` — set your display name/icon.
- `hosts` — your Maxima hosts (publickey, contact address, last seen, connected).
- `send` — send to one contact by `id:` (from `maxcontacts`), `to:` (contact address) or `publickey:`, with an `application:` string (which app should process it) and `data:` (HEX or JSON). `poll:true` retries until delivered.
- `sendall` — send to all contacts (`delay:` ms between sends).
- `refresh` — ping all contacts with a network message.

```
maxima action:send id:1 application:appname data:0xFED5.. poll:true
```

### maxcontacts

```
maxcontacts [action:list|add|remove|search|export|import] (contact:) (id:) (publickey:) (contactlist:)
```

Manage Maxima contacts. `add contact:MxG18H..` uses the other node's contact address (from their `maxima action:info`); `remove id:` also removes you from their side; `export`/`import contactlist:Mx..,Mx..` migrate contacts — import quickly, Max addresses change constantly.

```
maxcontacts action:add contact:MxG18H..
```

### maxextra

```
maxextra [action:] (publickey:) (maxaddress:) (enable:) (host:)
```

Advanced Maxima: static MLS (Maxima Location Service) hosting and public contactability.

- `staticmls host:Mx..@<your-server-ip>:9001` — pin an always-on node as your MLS (`host:clear` to unset).
- `addpermanent` / `removepermanent` / `listpermanent` / `clearpermanent` — on the MLS node, allow `getaddress` requests for a publickey.
- `getaddress maxaddress:MAX#<pubkey>#<staticmls>` — resolve someone's current contact address via their permanent maxaddress.
- `mlsinfo` — who is using you as their MLS.
- `allowallcontacts enable:false`, `addallowed publickey:`, `listallowed`, `clearallowed` — control who may add you as a contact (allowed list is held in RAM).

```
maxextra action:getaddress maxaddress:MAX#0x3081..#Mx..@<static-mls-host>:9001
```

### maxcreate

```
maxcreate
```

Create a standalone 128-bit RSA public/private key pair (independent of your Maxima ID) for use with `maxsign`/`maxverify`. Returns the key pair as HEX.

```
maxcreate
```

### maxsign

```
maxsign [data:] (privatekey:)
```

Sign HEX data with your Maxima ID key, or with a `maxcreate` private key.

```
maxsign data:0xCD34.. privatekey:0x30819..
```

### maxverify

```
maxverify [data:] [publickey:] [signature:]
```

Verify a Maxima signature. Returns `valid: true|false`.

```
maxverify data:0xCD34.. publickey:0xFED5.. signature:0x4827..
```

---

## System & other

### mds

```
mds (action:list|install|update|uninstall|download|pending|accept|deny|permission|publicmds) (file:) (uid:) (trust:read|write) (enable:)
```

MiniDapp System management:

- `list` (default) — installed MiniDapps with their uid and permission.
- `install file:wallet_1.0.mds.zip (trust:write)` — install (default permission READ).
- `update uid: file:` / `uninstall uid:` / `download uid:` — lifecycle.
- `pending` / `accept uid:` / `deny uid:` — approve or reject commands queued by READ-mode dapps.
- `permission uid: trust:read|write` — change a dapp's mode.
- `publicmds enable:true` — enable the public MDS endpoint.

```
mds action:install file:wallet_1.0.mds.zip trust:write
```

> ⚠️ Do NOT give WRITE permission to MiniDapps you do not trust — WRITE means they can move funds and change node state without per-command approval.

### mine

There is **no standalone `mine` command**. Transaction mining is controlled per-command via the `mine:true` parameter on `send` / `txnpost` / `tokencreate` (mine synchronously instead of async). An `automine` command exists in the source but its body is commented out — it is a no-op; don't rely on it.

> ⚠️ Related async gotcha: posting a transaction without `mine:true` mines in the background — an immediately-returned "not a transaction yet" state is NOT a failure; the tx confirms a few blocks later. Never retry-post on that signal.

### burn

```
burn
```

View burn metrics: number of burn transactions and max/median/average/min burn over the last 1, 10 and 50 blocks (`1block`, `10block`, `50block`, each with `txns`, `max`, `med`, `avg`, `min`). Use to pick an appropriate `burn:` for your own transactions when the network is busy.

```
burn
```

### magic

```
magic (kissvm:) (txpowsize:) (txnsperblock:)
```

View (no params) or vote on the network "Magic" capacity numbers: max KISS-VM opcodes, max TxPoW size, max transactions per block. Response shows `lastblock` (the magic values actually in force at the tip) and `desired` (what your node votes for).

```
magic
```

### mempool

```
mempool
```

Check the mempool. Response: `txpow[]` (each with `txpowid`, `transaction`, `block`), plus counts — `total`, `onchain`-eligible entries, and how many are `cascade`-only.

```
mempool
```

### trace

```
trace [enable:true|false] (filter:) (network:)
```

Stream the internal Minima engine message stacks to the terminal, optionally filtered by a case-sensitive string (`MAIN`, `MINER`, `MDS`, `NOTIFYMANAGER`, `TXPOWPROCESSOR`, ...). `network:true` adds low-level network messages. **Only works on the terminal** — the output goes to stdout, not to the RPC response.

```
trace enable:true filter:MDS
```

### logs

```
logs (scripts:) (mining:) (maxima:) (networking:) (blocks:) (ibd:) (peerschecker:) (txpowdb:)
```

Toggle detailed logging per subsystem (script errors, mining start/end, Maxima, network messages, blocks, IBD processing, TxPoWDB adds). Each flag is `true`/`false`.

```
logs scripts:true mining:false
```

### quit

```
quit (compact:)
```

Shut down Minima safely. `compact:true` compacts the databases on the way down. Ensure you have a backup first.

```
quit compact:true
```

### seedrandom

```
seedrandom [modifier:]
```

Generate a deterministic random value from your wallet SEED hashed with a modifier string. Same node + same modifier → same value; different nodes → different values. Useful for deriving app-specific secrets without storing them.

```
seedrandom modifier:"Hello you"
```

> ⚠️ Fails with "DB locked!" while the node is Vault password-locked (the seed is unavailable).

### incentivecash

```
incentivecash (uid:)
```

Legacy Incentive Program command: show your rewards balance (daily/invite/community breakdown), or set your incentive UID to start receiving daily rewards. Tied to the (historical) incentive.minima.global program — of little use on modern nodes but still present.

```
incentivecash uid:00d11b34-7b47-45f3-775c-a37cbe4c9ff3
```

### help

```
help (command:)
```

`help` alone lists every command with its one-line signature (`[]` = required, `()` = optional). `help command:<name>` prints the full per-command documentation — the authoritative source for the exact flags your node version supports. Remember commands can be chained with `;`.

```
help command:archive
```

---

## Commands you may see referenced that do NOT exist in current core

Verified against the current command source tree — don't burn time hunting for these:

- **`coinsimple`** — not a command. Use `coins` (Part 1) with filters, or `balance simple:true` for a minimal balance view.
- **`sshtunnel`** — existed in old releases; removed from current core. Use a normal SSH tunnel / reverse proxy in front of the RPC port instead.
- **`taskwait`** — not a command. For "wait until a queued write is approved", poll `checkpending uid:`; for send-until-confirmed semantics use `sendpoll` (Part 1).
- **`mine`** — see the note in System & other above: it's a parameter (`mine:true`), not a command.

---

## Verified command behaviors worth knowing (production-confirmed)

- ★ **`txpow txpowid:<id>` only proves a node has *seen* a transaction; `txpow onchain:<id>` is
  the settlement check — and it only searches roughly the last ~20 hours.** Verify soon after a
  transaction, or keep the id and use an archive source.
- **Untracked address balance:** `coins megammr:true address:<addr> tokenid:0x00` on a MegaMMR
  node (both Mx and 0x forms accepted). A standard node returns nothing for untracked addresses —
  absence of coins is not proof of absence. A node without a seeded MegaMMR answers EMPTY for
  everything (see node-operations).
- ★ **The node executes every `;`-separated segment of a command string and returns only the
  first result** — see node-operations for the gateway/allow-list implications; never
  interpolate untrusted text into a command.
- **`mysql`:** the export's `where` parameter is prefixed onto `SELECT * FROM coins WHERE`, and
  `query` is passed through as a complete SQL statement; the exporter uses the node's 64
  getaddress keys constant.
- **`printmmr` documents leaf rows at row 0** (bundled MMR.addEntry inserts leaves at row 0; the
  old help said 1).
- **`restoresync` accepts no `keyuses` argument** — the command runner rejects unlisted
  arguments, despite older help text.
- **`keys action:list` returns size/depth/uses/maxuses/modifier/publickey — no address.** If you
  derive the default address yourself (the SHA3-based derivation is portable), pin the port with
  golden vectors against the node's own Java and cross-check every run — a silent mismatch means
  your lookup asked about the wrong address and got a reassuring wrong answer.
- **`vault`** phrase-based key restoration is distinct from password unlocking; **`reset`**
  delegates seed recovery to `archive`.
- **`tokens action:import/export`** moves the byte-exact token record (export as MiniData);
  descriptions of these as key-management commands in older notes are wrong.
