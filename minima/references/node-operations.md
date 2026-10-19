# Node Operations — install, run, restore, recover

How to install, run, back up, restore, and troubleshoot a Minima node. Commands shown are typed
into the Minima terminal (CLI stdin, Terminal MiniDapp, RPC client, or `curl` to the RPC port)
unless prefixed with `java -jar` / `docker` / `sudo` (shell commands).

## Node-ops gotchas

Read these before touching a node that holds funds:

1. **`keyuses` on a seed restore is FUND-CRITICAL.** Minima signatures are stateful one-time
   WOTS leaves. When restoring from a seed phrase you MUST set `keyuses:` HIGHER than the true
   number of signatures you have ever made with those keys. Too low = the node re-issues
   already-spent leaves = self-inflicted key reuse = the exposure that loses funds.
   `keyuses:0` is only for a brand-new wallet that has never signed anything.
   (See `references/key-security-wots.md`.)
2. **Restore/resync with `megammrsync`, never `archive action:resync`.** `megammrsync` against a
   `-megammr` host lands you on the chain tip in seconds. `archive action:resync` replays the
   whole archive and takes hours. Same end state, 1000x the time.
3. **On a megammr/fresh node you cannot spend a coin at an untracked address**, even though
   `coins` shows it. You must `newscript trackall:true` + `coinexport` + `coinimport track:true`
   first. Symptom in the logs: `Script Missing from TxPoW for address 0x... TxPoW FAILS Basic
   checks`. The coin is never lost — just unspendable until tracked.
4. **The archive cannot recover deep-history spend destinations.** Archive data keeps coins
   (MMR), not witnesses: inputs, outputs, and signatures of transactions older than the
   unpruned window (~last 13k blocks) are gone from the archive format itself. No archive node,
   hosted or local, can tell you where an old spend went.
5. **Never poll long-running archive commands.** `archive action:integrity` takes minutes —
   issue it once and wait. Concurrent heavy archive queries can OOM a JVM with a bounded heap.
6. **Never ship a default backup password.** A backup of an unlocked node contains the
   unencrypted seed. A weak or hardcoded default password (in a script, an app, a doc example)
   means every backup is effectively plaintext. Always require a strong, user-chosen password.
7. **`-clean` deletes everything.** It wipes the node's data including keys. Only use it when
   you have the seed phrase written down or genuinely want a fresh node.

---

## Install and run

Minima is a single Java jar. Any platform with Java (11+) runs it:

```bash
java -jar minima.jar
```

With no parameters it connects to the main Minima network and works out of the box.
Full parameter list:

```bash
java -jar minima.jar -help
```

### Ports

A node uses a range of 5 ports starting at the base port (default **9001**, so 9001–9005):

| Port | Use |
|------|-----|
| 9001 | Main Minima P2P port. Open this externally on a server so your node acts as a relay. |
| 9002 | Not in use. |
| 9003 | MDS (MiniDapp System), **base port + 2**, served over **https** with a self-signed cert: `https://127.0.0.1:9003/` |
| 9004 | Not in use. |
| 9005 | RPC port (when `-rpcenable` is set). |

`-port [port]` moves the whole range (e.g. `-port 9010` → 9010–9014, MDS on 9012).

### MDS (MiniDapp System)

```bash
java -jar minima.jar -mdsenable -mdspassword YOUR_STRONG_PASSWORD
```

- MDS runs over SSL on base+2 (default `https://127.0.0.1:9003/`). Your browser will warn
  about the self-signed certificate — proceed past the warning.
- If you don't specify `-mdspassword`, a good one is generated for you; see it by running
  `mds` in the CLI.
- If the MDS login page is reachable from the internet, the password must be long and strong.
  Prefer firewalling 9003 to your own IP.

### RPC

RPC is off by default. Enable it at startup:

```bash
java -jar minima.jar -rpcenable -rpcpassword YOUR_RPC_PASSWORD -rpcssl
```

Then call commands over HTTP (URL-encode spaces as `%20`):

```bash
curl -k -u minima:YOUR_RPC_PASSWORD https://127.0.0.1:9005/status
curl -k -u minima:YOUR_RPC_PASSWORD "https://127.0.0.1:9005/balance"
```

Or use the bundled RPC client for an interactive terminal:

```bash
java -cp minima.jar org.minima.utils.MinimaRPCClient -password YOUR_RPC_PASSWORD -host https://127.0.0.1:9005
```

**Never expose port 9005 to the internet.** An open RPC port exposes your node and seed phrase.
If you must reach it remotely, firewall it to your own IP and always use `-rpcpassword` with
`-rpcssl` (Basic Auth without SSL is not secure).

In the interactive terminal: `exit` leaves the terminal, **`quit` shuts down the node** — don't
confuse them.

### Linux VPS as a systemd service

Install Java, create a `minima` user, download the jar:

```bash
sudo apt update -y && sudo apt install default-jdk wget jq -y
sudo adduser minima
sudo su minima && cd /home/minima
wget https://github.com/minima-global/Minima/raw/master/jar/minima.jar
exit
```

Create `/etc/systemd/system/minima.service`:

```ini
[Unit]
Description=minima
[Service]
User=minima
Type=simple
ExecStart=/usr/bin/java -jar /home/minima/minima.jar -rpcenable -rpcpassword YOUR_RPC_PASSWORD -rpcssl -mdsenable -mdspassword YOUR_MDS_PASSWORD -daemon -basefolder /home/minima -data /home/minima/.minima
Restart=always
RestartSec=100
[Install]
WantedBy=multi-user.target
```

Note `-daemon` — required for background/service mode (no stdin).

```bash
sudo systemctl daemon-reload
sudo systemctl enable minima
sudo systemctl start minima
sudo journalctl -u minima -f        # watch the logs (Ctrl+C to exit; node keeps running)
```

Firewall rules for a server node:

- **Allow 9001 in from anywhere** — makes your node a relay (backbone of the P2P network).
- **Deny 9002, 9004** (unused), **deny 9005** (RPC) from everywhere; RPC stays localhost-only.
- **9003 (MDS)**: allow only from your home IP, or keep closed for CLI-only nodes.
- If you run Docker on a VPS, do NOT rely on UFW — Docker bypasses UFW rules. Use the VPS
  provider's firewall.

The node does not auto-update. To update: stop the service, replace `minima.jar` with the
latest release, restart the service.

### Docker

```bash
docker pull minimaglobal/minima:latest
docker run -d \
  -e minima_mdspassword=YOUR_STRONG_PASSWORD \
  -e minima_desktop=true \
  -v ~/minimadocker:/home/minima/data \
  -p 9001-9003:9001-9003 \
  --restart unless-stopped --name minima minimaglobal/minima:latest
```

Startup parameters become environment variables in Docker: `-clean` → `-e minima_clean=true`,
`-megammr` → `-e minima_megammr=true`, `-archive` → `-e minima_archive=true`, and so on.
Run additional containers on shifted host ports, e.g. `-p 7001-7003:9001-9003`.

### Desktop

Windows/Mac users can use the Minima launcher (JNLP); custom startup parameters go in
Settings → "Use custom startup params". Or just run the jar from a terminal as above.
Android runs a full node via the official app.

---

## Key startup parameters

From `java -jar minima.jar -help` (Docker: convert to `-e minima_<name>=<value>`):

### General

| Parameter | Description |
|-----------|-------------|
| `-data [path]` | Config/data folder. Default: hidden `.minima` in the home directory. Always reuse the same folder when restarting an existing node. |
| `-basefolder [path]` | Default folder for file creation, backup, restore. Default: home directory. |
| `-conf [path]` | Configuration file (same keys as parameters: `-port 9008` → `port=9008`). CLI args take precedence. |
| `-port [port]` | Base port; range used is base to base+4. Default 9001–9005. |
| `-host [ip]` | Specify the host IP. |
| `-clean` | CAREFUL: wipes existing data, starts fresh. All coins (keys) on the node are lost. |
| `-daemon` | Run with no stdin (background services). |
| `-server` / `-desktop` / `-isclient` | Connection profile: accepts incoming connections / doesn't / tells P2P it can't. |
| `-allowallip` | Allow all IPs for Maxima/networking. |
| `-dbpassword [pw]` | AES password for the wallet/SQL DBs. Must be set on FIRST launch; cannot be changed later. |
| `-seed "[24 words]"` | Use this seed phrase when starting a new node. |
| `-archive` | Run as an archive node (store all sync blocks from now on). |
| `-megammr` | Run as a Mega MMR node (store all unspent coins + proofs for the whole chain). |
| `-rescuenode [host]` | MegaMMR node to resync from if you land on a heavier chain. |

### MDS

| Parameter | Description |
|-----------|-------------|
| `-mdsenable` | Enable the MiniDapp System (default port 9003). |
| `-mdspassword [pw]` | MDS login password. |
| `-mdsinit [folder]` | Install a folder of MiniDapps at startup. |
| `-mdswrite [minidapp]` | Give an initial MiniDapp WRITE access. |
| `-nodefaultminidapps` | Skip installing the default MiniDapps. |
| `-nosslmds` | Disable the self-signed MDS cert (put your own SSL proxy/stunnel in front). |
| `-publicmdsuid [uid]` | Session ID for the public MiniDapp system (Mega MMR nodes only). |

### RPC

| Parameter | Description |
|-----------|-------------|
| `-rpcenable` | Enable RPC (port base+4, default 9005). |
| `-rpcpassword [pw]` | Basic Auth password. Only secure combined with SSL. |
| `-rpcssl` | Self-signed SSL for RPC. |
| `-rpcclrf` | CRLF line endings in RPC headers (NodeJS clients). |

### Test / private networks

| Parameter | Description |
|-----------|-------------|
| `-test` | Test parameters (faster block times). |
| `-genesis` | Start from the genesis block (implies `-clean`). |
| `-nop2p` | Disable the automatic P2P system. |
| `-connect [ip:port,...]` | Disable auto-P2P and connect manually to these hosts. |
| `-noconnect` | Don't dial out until connected to. |
| `-solo` | Solo/private network: `-test -nop2p`, and runs `-genesis` only the FIRST time. |
| `-nosyncibd` | Don't sync the initial blockchain download (testing). |
| `-testchainlength [n]` | Tree length kept in `-test` mode (default 32). |

### Other useful

| Parameter | Description |
|-----------|-------------|
| `-txpowdbstore [days]` | Days of TxPoW kept in the internal H2 DB (default 3). |
| `-notifyalltxpow` | Fire a NEWTXPOW notification for every transaction/block (needed by MEG). |
| `-mysqlalltxpow` | Store all TxPoW to MySQL when MySQL autobackup is on. |
| `-limitbandwidth` | Limit archive-sync bandwidth. |
| `-showparams` | Print effective startup params at launch. |

---

## Private dev/test network

For an isolated chain for development and contract testing:

```bash
java -jar minima.jar -nop2p -test -genesis
```

- `-genesis` mines the genesis block and credits the node with **1 billion Minima** — your
  faucet. It implies `-clean`, so only use it the first time.
- Restart later WITHOUT `-genesis` to keep the chain: `java -jar minima.jar -nop2p -test`
- `-solo` is the convenient shorthand: `-test -nop2p` plus automatic `-genesis` on first run
  only. A solo node auto-mines roughly **one block every ~15 seconds** — the chain advances by
  itself. Do NOT send yourself transactions to "advance the chain"; just poll `balance` (or
  `block`) and wait for confirmations to mature.

Fund a test address from the genesis node:

```
getaddress
send amount:1000 address:MxG08...
balance
```

Connect a second local node to your private chain (different base port, own data folder):

```bash
java -jar minima.jar -connect 127.0.0.1 9001 -port 9010 -clean -data minimadata2
```

---

## Backup and restore

### Take a backup

```
backup password:YOUR_BACKUP_PASSWORD file:mybackup.bak
```

- `auto:true` enables automatic backups every 24 hours (latest 14 kept on the node) — but
  CLI auto-backups **cannot be password protected**; lock your node first, or set a
  password-protected auto-backup via the Security MiniDapp.
- **If your node is not locked, backups contain your unencrypted seed phrase.** Treat an
  unlocked-node backup exactly as you would the seed itself.
- The backup password cannot be changed or recovered. Choose a strong one and record it.
- Never bake a default password into scripts or apps that create backups — a known default
  makes every backup effectively unencrypted.
- Periodically download backups off the node and store them on a different device.

### Restore a backup

```
restore file:mybackup.bak password:YOUR_BACKUP_PASSWORD
```

The node shuts down when done; restart it to complete the restore. Variants:

- Backup < ~1 month old: `restore` alone, the network catches you up.
- Older backup: `restoresync file:... password:... host:<archive-node-ip:9001>` (archive host
  syncs the missing blocks), or the fast path below with `megammrsync ... file:yourbackup.bak`.
- `reset archivefile:archiveexport.gzip action:restore file:backup.bak password:...` replays
  from an archive file (slow legacy path).

Check restore progress programmatically (useful for tooling around a restoring node):

```
checkrestore
```

Returns `restoring`, `shuttingdown`, and `complete` flags.

If the node was locked when backed up, keys are still encrypted after the restore.

---

## MegaMMR seed resync runbook (fund-critical)

**To restore a wallet from a seed phrase, restore a backup to the tip, or fast-sync any node
onto the correct chain — use `megammrsync`. It completes in seconds. Do NOT use
`archive action:resync`, which replays the entire archive and takes hours.**

The `host:` must be a node running with `-megammr`. The public example host is
`megammr.minima.global:9001`; substitute your own mega node as `<your-megammr-host:9001>`.

### Case 1 — wrong chain / behind on sync, seed is fine

Host only. Keeps your current wallet, lands you on the correct tip:

```
megammrsync action:resync host:<your-megammr-host:9001>
```

### Case 2 — restore a backup and sync to tip

```
megammrsync action:resync host:<your-megammr-host:9001> file:yourbackup.bak
```

### Case 3 — restore from 24-word seed phrase (last resort, no backup)

```
megammrsync action:resync host:<your-megammr-host:9001> phrase:"YOUR 24 WORD SEED PHRASE" keyuses:2000
```

- This **WIPES the node** and rebuilds the wallet from the phrase.
- **`keyuses` is THE fund-critical parameter.** WOTS keys are stateful — every signature
  consumes a one-time leaf. `keyuses` tells the node how many leaves to skip as already used.
  - Brand-NEW wallet that has never signed: `keyuses:0`.
  - RESTORE of a wallet that has transacted: set it **higher than the maximum number of times
    you could possibly have signed** (docs default guidance: 1000 first restore, 2000 next,
    always increasing on every resync). Max is 262144 for normal keys.
  - Setting it too low re-issues already-spent leaves → key reuse → attackers can forge
    signatures over your funds. When in doubt, go higher — unused leaves cost nothing.
- `keys:` (optional) — number of key pairs to recreate; default 64 (all nodes create 64
  addresses; specify more if you used `newaddress`).
- `anyphrase:true` — required if the phrase is not a standard BIP39 24-word phrase.
- The node shuts down when the sync completes; restart it, give it a few minutes to connect.
- Do not use MiniDapps while a resync is in progress. Transaction history is deleted by a
  resync — export it from the Wallet MiniDapp first if you care.
- MiniSwap users: after a seed restore you must open MiniSwap (WRITE mode, set API keys) to
  re-register its script, then run a second chain resync to recover MiniSwap coins.

`help command:megammrsync` shows all options. The GUI equivalent is the **Security MiniDapp**
(Restore node → QuickSync / Import a Backup / Import Seed Phrase).

The slow legacy alternatives (`archive action:resync host:...`,
`reset archivefile:... action:seedsync phrase:"..." keyuses:...`) exist and work, but take
from many minutes to hours. Only reach for them when no `-megammr` host is available.

---

## Untracked-coin spend runbook

A `-megammr` (or freshly restored) node **cannot spend a coin at an address it does not
track**, even though `coins megammr:true address:0x...` displays the coin. `coins` returns
coin DATA for display; a spend needs the input's **script** and **MMR proof** attached at the
`txnbasics` step, and those come only from the node's tracked script/MMR DBs.

**Symptom** (node logs): `Script Missing from TxPoW for address 0x... → TxPoW FAILS Basic
checks`. The coin is safe on-chain the whole time — unspendable from this node, not lost.

**Fix, in order:**

```
# 1. Register the address script and track everything sent to it
newscript trackall:true script:"RETURN SIGNEDBY(0xYOUR_PUBLIC_KEY)"

# 2. Export the coin's proof out of the mega MMR
#    MUST be the FULL 66-char coinid — a truncated coinid returns a FALSE "Coin not found"
coinexport coinid:0x<FULL_66_CHAR_COINID>

# 3. (optional but recommended) validate the exported proof
coincheck data:0x<EXPORT_BLOB>

# 4. Import it into the tracked set
coinimport data:0x<EXPORT_BLOB> track:true

# 5. Verify, then spend normally
coins relevant:true
```

Notes:

- Coins that arrive AFTER the address is tracked are spendable normally — only coins created
  before tracking need the `coinexport`/`coinimport` backfill.
- **Token spends:** if the input is a custom token, rebuild the `Token` object from the
  byte-exact binary `coinexport` CoinProof — never by re-serializing the token-name JSON.
  JSON key reordering changes the bytes, the recomputed tokenid no longer matches, and the
  chain rejects the spend (`TokenID in Coin input 0 doesn't match token → TxPoW FAILS Basic
  checks`). Native MINIMA has no token descriptor and is unaffected.
- **Balance display:** for an untracked address, `balance megammr:true address:0x...` returns
  `sendable: 0` (the node can't compute "spendable by me" without tracking) and `total` is the
  token's total SUPPLY — not your balance. The real amount is in **`confirmed`**. Wallet UIs
  must display `confirmed`.

---

## Node types: full, mega, archive

All Minima nodes are full nodes — they validate everything and contribute PoW.

| | Full node (default) | Mega (MMR) node | Archive node |
|---|---|---|---|
| Startup flag | (none) | `-megammr` | `-archive` |
| Stores | Own coins + cascade; prunes blocks after ~24h | **All unspent coins + proofs** for the whole chain | **All sync blocks** since the node started (tx details still pruned after ~2 months) |
| Specs | 2 CPU / 2 GB RAM | 4 CPU / 8–16 GB RAM, 50 GB | 2 CPU / 4 GB RAM, 50 GB (grows) |
| Recovers other users | No | Yes (`megammrsync` host) | Yes (archive resync/export) |
| Export | MySQL | `.mmr` coin-history file | `.raw.dat` block-history file, MySQL |
| Uptime | Any | Must stay online (< 24h downtime) | Should stay online |

### Mega node

```bash
java -jar minima.jar -megammr -mdsenable -mdspassword YOUR_STRONG_PASSWORD
# Docker: add -e minima_megammr=true
```

Join the P2P network (default public peers list):

```
peers action:addpeers peerslist:https://spartacusrex.com/minimapeers.txt
```

Backfill the complete coin history by importing a recent `.mmr` export (< 1 week old) from
another mega node:

```
megammr action:import file:/path/to/megammr.mmr
```

A mega node is what `megammrsync` clients point at; it can also host public-facing MiniDapps
and create/post transactions on behalf of external users (see MEG below).

### Archive node

```bash
java -jar minima.jar -archive -data .minima -mdsenable -mdspassword YOUR_STRONG_PASSWORD
# Docker: add -e minima_archive=true
```

An archive node stores blocks **from the moment it starts**. To serve resyncs for any user,
first resync it from an archive node that has the chain back to genesis. Export for sharing:

```
archive action:exportraw file:archiveexport-ddmmyy.raw.dat
```

Verify archive integrity:

```
archive action:integrity
```

### Archive hard limits (what an archive CANNOT do)

- **Archive keeps COINS, not WITNESSES.** For blocks older than the unpruned window (~last
  13k blocks from tip), `txpow txpowid:0x...` returns `body.txn.inputs = []` and
  `body.txn.outputs = []`. Only block-level txpow (with `txnlist`) survives.
- Preserved: coin creation via the MMR (`archive action:addresscheck address:0x...` works back
  to archive genesis), coin state and value at creation, the spent block/timestamp of each
  coin, and the txpowid of the block containing the spend.
- NOT preserved: which coinids a deep-history transaction consumed, its output addresses and
  amounts, signatures, witnesses, proofs. **You cannot determine an old spend's destination
  from the archive alone** — the data is absent from the archive format itself, on every
  archive node. The only partial workaround is cross-referencing: for an outgoing spend at
  block N of amount A, look for coins CREATED at block N with amount A at addresses you can
  enumerate.
- **Commands that hang or hurt:**
  - `archive action:integrity` can run 3+ minutes on a large archive. Issue once, wait for the
    reply. Never poll it, and never fire it from a UI on a timer.
  - Concurrent heavy archive queries will OOM a JVM running with a bounded heap. Serialize
    them.
  - `txpow address:0x...` only searches roughly the last 13k blocks — it is NOT a full-history
    address index. For full history you need the MySQL export.

---

## MySQL export

Any node can export chain data to an external MySQL database for storage and querying beyond
the node's own pruning limits. Tables: `cascadedata`, `syncblocks`, `coins`, `txpow` (full
transaction detail, v1.0.41+).

```
# check connectivity
mysql action:info host:127.0.0.1:3306 database:archivedb user:archiveuser password:...

# store login so you can omit credentials afterwards
mysql action:setlogin host:127.0.0.1:3306 database:archivedb user:archiveuser password:...

# push new blocks/coins to MySQL
mysql action:update
```

`mysqlcoins` provides coin-specific export/queries against the same database. Start the node
with `-mysqlalltxpow` to include every TxPoW when MySQL autobackup runs. Check the node is on
the correct tip (`status`) before running an update. See `help command:mysql` for the full
action list (update, info, integrity, resync, wipe, ...).

---

## Cold storage (offline vault)

For large holdings: private keys live on a permanently-offline device; an online watch node
receives funds and builds transactions; the offline device signs.

Setup sketch (full flow in the official cold-storage guide):

```
# on the OFFLINE device (never connects to the internet again)
vault                                  # view 24-word phrase + 0x seed — write the words down
vault action:wipekeys seed:0x...       # wipe private keys from the node
backup file:nokeysbackup.bak password:...   # keyless backup for the online device
vault action:restorekeys phrase:"YOUR 24 WORDS"   # put keys back on the offline node
vault action:passwordlock password:... confirm:...  # encrypt keys with a password

# on the ONLINE device
restore file:nokeysbackup.bak password:...   # same wallet, watch-only (no keys)
```

Transacting: `sendnosign` (online, creates unsigned `.txn`) → USB → `sendsign file:...
password:...` (offline) → USB → `sendpost file:...` (online). `sendview file:...` inspects a
`.txn` at any time.

---

## MEG (Minima Enterprise Gateway) — pointer

MEG is a separate Java middleware service that exposes a Minima node over an HTTP/S API with
webhooks — triggers on on-chain events, custom endpoints, and a custodial Wallet API — aimed
at exchanges and enterprise integrations. It connects to the node via the RPC port and
requires the node to run with `-rpcenable -megammr -notifyalltxpow` (optionally
`-mysqlalltxpow`). MEG has a `-minkeyuses` startup parameter for the same WOTS-statefulness
reason described above. See the official "MEG" docs under Run a Node for setup.

---

## Node-recovery decision tree

```
Is the node running and the wallet correct, but behind / on the wrong chain?
├── YES → chain resync, keep the seed:
│         megammrsync action:resync host:<your-megammr-host:9001>
└── NO ↓

Do you have a backup file?
├── YES → restore file:backup.bak password:...
│         (older than ~1 week? use megammrsync ... file:backup.bak to land on the tip)
└── NO ↓

Do you have the 24-word seed phrase?
├── YES → megammrsync action:resync host:<your-megammr-host:9001>
│                    phrase:"..." keyuses:<HIGHER than your true signature count>
│         ── keyuses too low loses funds; go generously high. anyphrase:true if non-BIP39.
└── NO  → the wallet is unrecoverable. Nothing on-chain or in any archive can restore keys.

After any restore: node shuts down → restart it → wait a few minutes to connect →
verify with:  status   and   balance

Coin visible but spend fails ("Script Missing from TxPoW")?
└── Untracked address on a megammr/fresh node:
    newscript trackall:true → coinexport (FULL coinid) → coincheck → coinimport track:true → spend

Corrupt/broken local DBs, chain state unrecoverable, seed is safe?
└── Stop node → move the -data folder aside → start clean → megammrsync with phrase+keyuses
    (same fund-critical keyuses rule applies).

Need history older than the node keeps?
└── Archive node (blocks/coins) or MySQL export (full txpow) — but remember: deep-history
    spend destinations are not recoverable from the archive (witnesses are pruned).
```

---

## Hard lessons from running nodes in production

Field-proven operational facts, each from a real incident or a security audit of the node. ★ =
funds or whole-node at stake.

### RPC and exposure

- ★ **Minima RPC is unauthenticated admin command execution unless you set a password, `rpc
  ssl:true` is a silent no-op (RPC is always plaintext HTTP), and the handler has historically
  run every authenticated request as ADMIN regardless of read/write mode.** Bind RPC to
  loopback, terminate TLS externally, and never run the MDS web UI with a default password on a
  public IP. Stock RPC binds **all interfaces** with no bind option — on a cloud box with no
  provider firewall it is internet-reachable full admin.
- ★ **The node executes EVERY `;`-separated segment of a command string and returns only the
  first result.** An RPC gateway/allow-list that validates only the first verb is a fund drain
  (`status ; send …` passes the check and the send executes — proven live). Validate every
  segment; a public gateway is an ALLOW-list (reads, track-only, relay of pre-signed txns) with
  wallet-send and seed operations deliberately absent, rate-limited per-IP and globally.
- **Treat inbound P2P as hostile input.** Audited failure modes include attacker-sized
  allocations from length prefixes, unbounded list loops in IBD/Greeting parsing, blocking DNS
  on attacker-supplied hostnames, peer-table poisoning via unbounded greeting peer lists, and an
  OOM path that halts the JVM. Keep nodes patched; expect that one malicious peer can stall an
  old node.

### MegaMMR, archive, sync

- **MegaMMR needs ≥3 GB heap.** A fresh `-megammr` node is NOT seeded by IBD — it boots with an
  empty MegaMMR and answers EMPTY for every pre-existing address, silently defeating a
  gateway/read role. Seed it explicitly (`megammr action:export` on a donor → import), and make
  any read service refuse `megammr:true` queries on a node without one.
- **`megammrsync` auto-shuts the node down on completion — that is success, not a crash.** A
  resync wipes the MegaMMR (re-import after). Restoring from a backup file is plain
  `restore file:.. password:..`, never `megammrsync`. Completing IBD is not the same as having a
  MegaMMR.
- **Initial sync is weak-subjectivity:** IBD sync blocks are accepted on block-number/parent-hash
  linkage only — no MMR re-derivation, no PoW check (audit finding). Sync fresh or restoring
  nodes from hosts you trust and cross-check balances against a second source.

### Corruption and recovery

- **Cascade-corruption crash loop** (signature: `EOFException` reading Cascade → "Your Cascade is
  BROKEN"): move the data dir aside (reversible), boot fresh, re-seed peers (peer lists reset on
  container recreate), resync from a nearby archive node, re-import/rebuild the MegaMMR. Healthy
  disk/RAM does not rule out cascade corruption.
- **Diagnose a container crash-loop's duration by restart count × backoff, not the first error in
  the retained log** — Docker keeps old recovered incidents in the same log and a stale entry can
  misdate an outage by weeks.
- **Verify backups by their artifacts, not their schedule.** A backup cron ran "successfully" for
  months producing nothing (missing target dirs + missing container mount). Check the output
  directory the day after any backup change; never delete a large export mid-write (the writer
  keeps writing to the unlinked inode).

### Docker specifics

- **Dockerised nodes advertise their internal bridge IP by default → peers can't dial back →
  stuck at a handful of outbound-only peers.** Fix: `minima_host:<public ip>` plus
  `minima_server:true` env (the official image reads `minima_*` env natively). It is not a
  firewall problem — but beware port-remapped siblings: advertising a public host on a container
  whose public port maps to a *different* container is actively harmful.
- **docker-compose v1 after an image pull: `stop` + `rm -f` + `up -d`, never bare `up -d`** (the
  ContainerConfig bug). And a whole-stack `up -d` resurrects a deliberately stopped service under
  `restart: unless-stopped` — bring services up individually.

### MySQL coins/txpow export (mysqlcoins / mysqlalltxpow)

- ★ **The coins table deliberately has no UNIQUE constraint on coinid** (one row per
  created/spent state). On any node rebuild or migration, **truncate the coins table before the
  node comes back up** or every coin double-inserts; then re-run `mysqlcoins action:update` and
  only then restart any downstream (explorer) syncer.
- **Long-running SELECTs hold metadata locks that block TRUNCATE** — check the process list and
  kill blockers first.
- **The MySQL export updates from the cascade, so it always trails the tip by ~2000 blocks BY
  DESIGN** — do not "fix" the lag.

### Public/router fleet defaults

- `-server` mode with inbound P2P (9001) open; MDS and RPC OFF; each node generates its own seed
  on first boot — **never share one seed across nodes** (a copied identity is a second live
  account: split messages, hijacked sessions). Routers stay light (no `-archive`/`-megammr`)
  unless deliberate. Open ports in the *provider's* firewall as well as the host. For network
  strength, ASN/geographic diversity beats node count behind one provider.
- **A redeploy must reproduce per-box config exactly** — deploy-script defaults rarely match any
  live box (heap, peer lists, MegaMMR flags). Read the live unit's ExecStart and pass every flag
  back, or the box silently drops out of its mesh.
- **A cold node's first RPC request after idle can time out; a warm retry answers in
  milliseconds** — never conclude a node is down from one short-timeout probe.
