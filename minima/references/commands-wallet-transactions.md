# Minima Command Reference — Part 1: Wallet, Coins, Tokens, Transactions, Scripts, Crypto

Post/construction gotchas live in the skill's CRITICAL RULES and references/transactions-utxo.md — this file is the command lookup.

Notation: `[param:]` = required, `(param:)` = optional. Commands are typed into the Minima terminal, MDS `cmd` handler, or RPC. Chain multiple commands with `;`. `help command:<name>` on a live node prints the same detail.

---

## Wallet, Keys and Addresses

### getaddress

```
getaddress
```

Returns one of your 64 default Minima addresses — used to receive funds and as change addresses. Each address can be used securely 262144 (64^3) times. After heavy use you can wipe private keys from an online node with `vault`.

Key response fields: `address` (0x hex), `miniaddress` (Mx form — interchangeable with 0x when sending), `publickey`, `script` (always `RETURN SIGNEDBY(<publickey>)` for default addresses), `default:true`, `simple:true`.

```
getaddress
```

### newaddress

```
newaddress
```

Creates a brand-new address that is NOT one of the 64 default change addresses. Use for a specific purpose (e.g. one address per invoice) or improved privacy. Same response shape as `getaddress` but `default:false`.

```
newaddress
```

### keys

```
keys (action:list|new|checkkeys|genkey) (publickey:)
```

List all your public keys or create a new key pair. Each key can sign securely 262144 times.

- `action:list` — list existing public keys (default)
- `action:checkkeys` — verify your public and private keys match
- `action:new` — create a new key pair stored and managed in your wallet DB
- `action:genkey` — generate a key NOT stored in the DB (you keep the private key yourself)
- `publickey:` — search for one specific key

Key response fields per key: `publickey`, `script`, `address`/`miniaddress`, uses count vs max uses.

```
keys action:list publickey:0xFFEE56..
keys action:new
```

### vault

```
vault [action:seed|wipekeys|restorekeys|passwordlock|passwordunlock] (seed:) (phrase:) (password:) (confirm:)
```

BE CAREFUL. View, wipe, restore, encrypt or decrypt your private keys. Ensure you have a backup and a secure record of your passphrase before locking.

- `action:seed` — show your seed phrase and seed (default). DO NOT SHARE.
- `action:wipekeys seed:0x..` — delete private keys, keep public (cold-wallet an online node)
- `action:restorekeys phrase:"24 WORDS.."` — reinstate private keys from passphrase
- `action:passwordlock password:.. (confirm:..)` — encrypt private keys with a password
- `action:passwordunlock password:..` — decrypt and reinstate private keys

While password-locked, `send` / `txnsign` / `consolidate` / `multisig` accept a one-shot `password:` that unlocks, signs and relocks.

```
vault
vault action:wipekeys seed:0xDD4E..
vault action:passwordlock password:your_password confirm:your_password
```

### printtree

```
printtree (depth:) (cascade:true|false)
```

Print an ASCII tree representation of the blockchain / TxPoW tree. Default depth 32 blocks from the tip; `cascade:true` also shows the cascading chain (default false).

```
printtree depth:500
printtree cascade:true
```

---

## Balance and Send

### balance

```
balance (address:) (tokenid:) (confirmations:) (simple:) (coinlist:) (tokendetails:) (megammr:)
```

Show your total balance of Minima and all tokens.

- `address:` — balance for a specific 0x or Mx address
- `tokenid:` — one token only; Minima is `0x00`
- `confirmations:` — blocks before a coin counts as confirmed (default 3)
- `simple:true` — just name + confirmed amount
- `coinlist:true` — list the underlying valid coins
- `tokendetails:true` — full token metadata
- `megammr:true` — also search the MegaMMR for coins

Key response fields per token: `token` (string or metadata object), `tokenid`, `confirmed`, `unconfirmed` (pending — UTXO locked, can't spend yet), `sendable` (ready to spend now; excludes coins locked in contracts), `coins` (count), `total` (total supply for tokens).

```
balance
balance tokenid:0xFED5.. confirmations:10
balance simple:true
```

### send

```
send (address:Mx..|0x..) (amount:) (multi:[..]) (tokenid:) (state:{}) (burn:) (split:)
     (coinage:) (mine:) (password:) (fromaddress:) (signkey:) (storestate:) (debug:) (dryrun:)
```

Send Minima or custom tokens to a wallet or script address. The node picks input coins, signs, builds change and posts in one step.

- `address:` + `amount:` — recipient and amount (amount supports up to 44 decimals; min 0.000001)
- `multi:["addr:amt","addr2:amt2",..]` — multiple recipients in one transaction
- `tokenid:` — custom token id; defaults to Minima `0x00`
- `state:{"0":"value","1":"value"}` — state variables when sending to a script address
- `burn:` — Minima to burn as a priority fee
- `split:` — 1..20; splits the sent amount into N equal output coins. Send to your own address to split your own UTXOs so you can transact without waiting for change to confirm
- `coinage:` — minimum age (blocks) of input coins
- `mine:true` — mine the TxPoW immediately/synchronously
- `password:` — one-shot Vault unlock if the wallet is password locked
- `fromaddress:` — only use input coins from this address; `signkey:` — sign with only this key (use together)
- `storestate:false` — output coins do not store the state (they still appear in NOTIFYCOIN events); default true
- `dryrun:true` — simulate without posting; `debug:true` — verbose logs

Response: the full TxPoW JSON (`txpowid`, `transaction.inputs[]`, `transaction.outputs[]`, `state`, etc.). Spending the same UTXO twice before confirmation fails — wait or pre-`split`.

```
send address:0xFF.. amount:10 tokenid:0xFED5.. burn:0.1
send multi:["0xFF..:10","0xEE..:10","0xDD..:10"] split:20
send amount:1 address:0xFF.. state:{"0":"0xEE..","1":"0xDD.."}
```

### sendpoll

```
sendpoll (action:add|list|remove) (uid:) + all `send` parameters
```

Queue a `send` that is retried every 30 seconds until it succeeds (status true) — survives temporarily locked coins or unconfirmed change. Accepts all `send` parameters.

- `action:list` — show the polling list (returns each entry's `uid` and command)
- `action:remove uid:` — cancel a queued send

```
sendpoll address:0xFF.. amount:10 tokenid:0xFED5..
sendpoll action:list
sendpoll action:remove uid:0x..
```

### sendnosign

```
sendnosign (address:) (amount:) (multi:[..]) (tokenid:) (state:{}) (burn:) (split:) (file:) (debug:)
```

Construct a transaction but do NOT sign it — writes an unsigned `.txn` file to the node's base folder (or `file:`). Must run on an ONLINE node (it attaches the input coins' MMR proofs). The file is then signed offline with `sendsign` and posted with `sendpost`. Ideal for cold-wallet setups where the online node's keys are wiped or locked. Same send-shaping params as `send`.

Response: the path/name of the created unsigned `.txn` file.

```
sendnosign address:0xFF.. amount:10 tokenid:0xFED5.. burn:0.1
```

### sendview

```
sendview [file:]
```

View the JSON details of a `.txn` file (signed or unsigned) created by `sendnosign`/`sendsign` — inputs, outputs, state, signatures.

```
sendview file:unsignedtransaction-1674907380057.txn
```

### sendsign

```
sendsign [file:] (password:)
```

Sign an unsigned `.txn` file from `sendnosign`. Can run on an offline node holding the keys. If the node is Vault password-locked, pass `password:` — keys are re-encrypted after signing. Outputs a new signed `.txn` file for `sendpost`.

```
sendsign file:unsignedtransaction-1674907380057.txn password:your_vaultpassword
```

### sendpost

```
sendpost [file:]
```

Post a signed `.txn` file (from `sendnosign` → `sendsign`) to the network. Must be posted from an online node within ~24 hours of creation so the MMR proofs are still valid.

```
sendpost file:signedtransaction-1674907380057.txn
```

### sendfrom

```
sendfrom [fromaddress:] [address:] [amount:] [script:] [privatekey:] [keyuses:] (tokenid:) (state:) (split:) (burn:) (mine:)
```

Send Minima or tokens from a specific address using an explicitly provided script and private key — for keys managed outside the node wallet (see also `keys action:genkey` and the `createfrom`/`signfrom`/`postfrom` family). `keyuses:` must track how many times the key has signed (Minima signatures are stateful).

```
sendfrom fromaddress:0xFF.. address:0xEE.. amount:5 script:"RETURN SIGNEDBY(0xFF..)" privatekey:0x.. keyuses:12
```

### multisig

```
multisig [action:create|getkey|list|spend|sign|post|view] (id:) (amount:) (publickeys:[..])
         (required:) (root:) (coinid:) (address:) (file:) (password:)
```

Built-in n-of-m multisig coins: spendable only by a txn signed by `root` OR `required` of the listed `publickeys`.

- `action:getkey` — returns one of your default public keys to contribute to a multisig
- `action:create id: amount: publickeys:["0x..",..] required:n (root:0x..)` — lock funds in a multisig coin. The `id` is hashed into state variable 0 (cannot be retrieved later — keep it)
- `action:list (id:)` — list multisig coins you track
- `action:spend id:|coinid: amount: address: (file:)` — build an unsigned `.txn` spend file
- `action:sign file: (password:)` — sign with whichever relevant keys this node holds; outputs a new `signed_*.txn` — pass the file between signers until the threshold is met
- `action:view file:` — inspect a multisig `.txn` file
- `action:post file:` — post the fully signed transaction

```
multisig action:create id:2of3multisig amount:100 publickeys:["0xFF..","0xEE..","0xDD.."] required:2
multisig action:spend id:2of3multisig amount:5 address:0xFF.. file:multisig.txn
multisig action:sign file:multisig.txn
multisig action:post file:signed_multisig.txn
```

---

## Coins (UTXOs)

### coins

```
coins (relevant:true) (sendable:true) (coinid:) (amount:) (address:) (tokenid:)
      (coinage:) (depth:) (checkmempool:) (order:asc|desc) (megammr:)
```

Search for coins — yours (`relevant:true`) or anywhere in the unpruned chain (`relevant:false`, the default when other params are given).

- `sendable:true` — filter out coins locked in contracts
- `coinid:` — one specific coin
- `amount:` / `address:` (0x or Mx, incl. script addresses) / `tokenid:` (`0x00` = Minima) — filters
- `coinage:` — minimum age in blocks; `depth:` — how far back from the tip to search
- `checkmempool:true` — flag coins already spent in the mempool
- `order:asc|desc`; `megammr:true` — also search the MegaMMR

Each returned coin object:

```json
{
  "coinid": "0xFF..", "amount": "91.815999", "address": "0xFF..",
  "miniaddress": "MxFF..", "tokenid": "0x00", "token": null,
  "storestate": false, "state": [], "mmrentry": "728",
  "spent": false, "created": "203728"
}
```

`token` is null for Minima, or the token metadata object for custom tokens. Use `coinid` + `amount` + `address` when building manual transactions.

```
coins relevant:true sendable:true
coins relevant:true address:0xCEF6.. tokenid:0x00
```

### coincheck

```
coincheck [data:]
```

Check that a coin exists and is valid (unspent coins only). `data:` is the export blob from `coinexport`. Returns the coin details plus whether its MMR proof is valid (`proofblock`, proof validity flag).

```
coincheck data:0x00000..
```

### coinexport

```
coinexport [coinid:]
```

Export a coin together with its MMR proof as a single HEX blob. Another node can `coinimport` it to know of (and optionally track) the coin. Export does not enable spending — only knowledge of existence. The blob is also usable as `coindata:` in `txninput` and `data:` in `coincheck`.

```
coinexport coinid:0xCD34..
```

### coinimport

```
coinimport [data:] (track:true|false)
```

Import a coin (with MMR proof) exported from another node. `track:true` creates an MMR entry and adds it to your relevant coins so you see when it is spent. Import does not enable spending the coin.

```
coinimport data:0x00000.. track:true
```

### cointrack

```
cointrack [enable:true|false] [coinid:]
```

Track (keep its MMR proof up to date, know when spent) or untrack (remove from relevant coins) a coin already known to your node.

```
cointrack enable:true coinid:0xCD34..
```

### coinnotify

```
coinnotify [action:add|remove|check] [address:]
```

Listen for coins at a specific address WITHOUT adding a script for it — a NOTIFYCOIN event fires when a matching coin appears in the chain. Not persisted: re-add on every startup (e.g. from a MiniDapp's service.js).

```
coinnotify action:add address:0xFFEEDD..
coinnotify action:check address:Mx12ABGF56..
```

### consolidate

```
consolidate [tokenid:] (coinage:) (maxcoins:) (maxsigs:) (burn:) (password:) (debug:) (dryrun:)
```

Merge multiple small coins into one by sending them back to yourself. Requires at least 3 coins of the token.

- `tokenid:` — `0x00` for Minima or a custom token
- `coinage:` — minimum confirmations per input coin (default 3)
- `maxcoins:` — 3..20 coins per run, smallest-value first
- `maxsigs:` — up to 5 signatures; coins sorted by address to minimize signers
- `burn:` / `password:` / `dryrun:true` (simulate) / `debug:true`

```
consolidate tokenid:0x00 coinage:10 maxcoins:8 maxsigs:3 burn:1 dryrun:true
```

---

## Tokens

### tokens

```
tokens (tokenid:) (action:import|export) (data:)
```

List all tokens in the unpruned chain, or share token metadata between nodes: `action:export tokenid:` produces a HEX blob; `action:import data:` loads it. Response per token: `name` (string or JSON), `tokenid`, `total`, `decimals`, `script`, `coinid` (creation coin), `totalamount`, `scale`.

```
tokens tokenid:0xFED5..
tokens action:export tokenid:0xFED5..
tokens action:import data:0x000..
```

### tokencreate

```
tokencreate [name:] [amount:] (decimals:) (script:) (state:{}) (signtoken:) (webvalidate:) (burn:) (mine:)
```

Create (mint) custom tokens or NFTs. Tokens are "colored coins" — a fraction of 1 Minima is consumed as the base, so you need some sendable Minima.

- `name:` — a string OR a JSON object with arbitrary metadata (common app-level fields: `name`, `description`, `link`/`url`, `icon`, `color` — not enforced by protocol)
- `amount:` — total supply, 1 to 1 trillion
- `decimals:` — default 8, max 16; use `0` for NFTs
- `script:` — token-level script that must also return TRUE whenever ANY coin of this token is spent (in addition to the coin's own script)
- `state:{}` — state variables when adding a script
- `signtoken:0x..` — sign the token with a public key to prove creatorship (verify with `tokenvalidate`)
- `webvalidate:` — URL of a public .txt file you host that will contain the tokenid
- `burn:` / `mine:true`

Response structure (the minting TxPoW):

```
inputs[0].tokenid  = "0x00"     <- Minima consumed as the base
outputs[0].tokenid = tokenid    <- the new token coin
outputs[0].token.tokenid        <- THE real tokenid: use this for send/balance
outputs[0].token.name           <- your metadata
outputs[0].token.total / .decimals / .script ("RETURN TRUE" by default)
outputs[0].tokenamount          <- human-readable supply
outputs[1].tokenid = "0x00"     <- Minima change back to you
```

```
tokencreate name:newtoken amount:1000000
tokencreate amount:10 decimals:0 name:{"name":"mynft","description":"one of ten"}
tokencreate name:charitycoin amount:1000 script:"ASSERT VERIFYOUT(@TOTOUT-1 0xFF.. 1 0x00 TRUE)"
```

### tokenvalidate

```
tokenvalidate [tokenid:]
```

Validate a token's `signtoken` signature and its `webvalidate` link (fetches the URL and checks the tokenid is listed). Returns validity of both.

```
tokenvalidate tokenid:0xFED5..
```

---

## Manual Transaction Construction

The precise-control pipeline. Canonical simple flow:
`txncreate` → `txninput` → `txnoutput` (+ `txnstate`) → `txnsign` → `txnbasics` → `txnpost` → (`txndelete`).
Inputs minus outputs is burned — always add a change output. All commands return/print the current transaction JSON so you can inspect progress.

### txnlist

```
txnlist (id:) (transactiononly:)
```

List your custom in-progress transactions (including previously posted ones), with full details — inputs, outputs, state, and witness (signatures, mmrproofs, scripts).

```
txnlist id:multisig
```

### txncreate

```
txncreate [id:]
```

Create a new empty custom transaction under an id. First step before adding inputs/outputs. Delete with `txndelete` on failure paths so its input coins aren't left locked.

```
txncreate id:simpletxn
```

### txnauto

```
txnauto [id:] [amount:] [address:] (tokenid:) (sign:) (burn:) (mmrscript:)
```

Shortcut: build a complete simple transaction automatically — picks input coins for `amount`, adds output to `address` and change, optionally signs (`sign:`) and adds MMR/scripts (`mmrscript:`).

```
txnauto id:quick amount:10 address:0xFF..
```

### txnaddamount

```
txnaddamount [id:] [amount:] (address:) (onlychange:) (tokenid:) (split:) (burn:)
```

Add input coins to cover a given amount and calculate the change. Either outputs `amount` to `address`, or with `onlychange:` only adds the change output (when you've already added the main output manually). Useful for preparing multiple offline transactions.

```
txnaddamount id:simpletxn amount:10 address:0xFF..
```

### txnbasics

```
txnbasics [id:]
```

Automatically attach the MMR proofs and input scripts to a transaction. Run only when the transaction is ready to post (after signing; proofs are tip-relative). Populates `witness.mmrproofs` and `witness.scripts`.

```
txnbasics id:simpletxn
```

### txndelete

```
txndelete [id:]
```

Delete a custom transaction — or `id:all` to clear every one. Always delete abandoned transactions so their input coins are released.

```
txndelete id:simpletxn
txndelete id:all
```

### txncheck

```
txncheck [id:]
```

Show transaction details and verify inputs, outputs, signatures, proofs and scripts. Key response fields: `coins[].input` / `.output` / `.difference` per token, `burn` (what will be destroyed = inputs − outputs), and `valid.basic` / `valid.signatures` / `valid.mmrproofs` / `valid.scripts`. Note: script checks that depend on chain globals (e.g. `@BLKNUM`, `@COINAGE`) cannot be evaluated here.

```
txncheck id:simpletxn
```

### txninput

```
txninput [id:] (coinid:) (coindata:) (floating:) (address:) (amount:) (tokenid:) (scriptmmr:true)
```

Add a coin as a transaction input.

- `coinid:` — a concrete coin (find via `coins relevant:true`)
- `coindata:` — coin blob from `coinexport` or the `outputcoindata` of another transaction (chained/offline txns)
- `floating:true address: amount: tokenid:` — an unspecified ELTOO floating input: attachable later to any existing coin with the same address/amount/tokenid but any coinid
- `scriptmmr:true` — also attach the coin's script and MMR proof in this step (then skip `txnbasics` — doing both duplicates proofs)

```
txninput id:simpletxn coinid:0xD0BF..
txninput id:eltootxn floating:true address:0xFED5.. amount:10 tokenid:0x00
```

### txnoutput

```
txnoutput [id:] [amount:] [address:] (tokenid:) (storestate:)
```

Add an output — a new coin (UTXO). If sum(inputs) > sum(outputs) the difference is burned, so add your own change output. `storestate:` (default true) controls whether the transaction's state variables are stored in the new coin — must agree with any `VERIFYOUT(... keepstate)` in the controlling script.

```
txnoutput id:simpletxn amount:10 address:0xFED5..
txnoutput id:simpletxn amount:4.5 address:0xFF.. storestate:false
```

### txnstate

```
txnstate [id:] [port:] [value:]
```

Add a state variable to the transaction. `port:` 0–255; `value:` HEX, number or quoted string. Scripts read these via `STATE(port)`; output coins with `storestate:true` carry them, becoming the next spend's `PREVSTATE(port)`.

```
txnstate id:simpletxn port:0 value:0xFED5..
txnstate id:simpletxn port:1 value:"string"
```

### txnscript

```
txnscript [id:] (auto:false) (scripts:{})
```

Attach input scripts to a transaction. `scripts:` is a JSON map of `{script:proof}` — proof empty (`""`) for a plain script, or the MMR proof for a MAST script node from `mmrcreate`. `auto:true` adds the scripts your node already knows (useful in multi-party transactions).

```
txnscript id:txnmast scripts:{"RETURN TRUE":"0x000.."}
```

### txnmmr

```
txnmmr [id:]
```

Add MMR proofs for the inputs, keeping any proofs already present (unlike `txnbasics`, which sets everything).

```
txnmmr id:simpletxn
```

### txnsign

```
txnsign [id:] [publickey:0x..|auto] (password:) (txnpostauto:) (txnpostburn:) (txnpostmine:) (txndelete:)
```

Sign a transaction. `publickey:auto` signs with whatever the simple wallet inputs require; pass an explicit `publickey:0x..` for keys named in custom scripts (run once per required key). `password:` for a Vault-locked node. The `txnpost*` params optionally post in the same call (`txnpostauto` behaves like `txnpost auto:`), and `txndelete:true` deletes after sign-and-post.

```
txnsign id:simpletxn publickey:auto
txnsign id:multisig publickey:0xFD8B..
```

### txnclear

```
txnclear [id:] (scripts:) (mmr:) (signatures:)
```

Clear the witness data — signatures, MMR proofs and script proofs (each flag defaults to true, so a bare call clears all three). Use before re-signing or re-proving a stale transaction.

```
txnclear id:multisig
```

### txnpost

```
txnpost [id:] (auto:true) (burn:) (mine:) (txndelete:)
```

Post the transaction to the network. `auto:true` sets scripts and MMR proofs at post time (only safe for simple wallet inputs — for script-address coins run `txnsign` → `txnbasics` → `txnpost` explicitly). `burn:` adds a burn; `mine:true` mines it immediately; `txndelete:true` deletes the txn after posting. Note `status:true` means "accepted and broadcast", NOT "valid on-chain" — confirm by watching the coins/chain.

```
txnpost id:simpletxn
txnpost id:simpletxn burn:0.1 mine:true
```

### txnimport

```
txnimport (id:) (file:) (data:)
```

Import a transaction from exported HEX `data:` or a `.txn` `file:`, optionally assigning a new `id:`. Counterpart of `txnexport` — the transfer vehicle for multi-party / offline signing.

```
txnimport id:multisig file:multisig.txn
txnimport data:0x0000..
```

### txnexport

```
txnexport [id:] (file:)
```

Export a transaction as HEX (returned in `data`) or to a `.txn` file, to be `txnimport`ed on another node (e.g. for signing).

```
txnexport id:multisig file:multisig.txn
```

### txnview

```
txnview (file:) (data:)
```

View an exported transaction (from `.txn` file or HEX data) as JSON without importing it.

```
txnview file:multisig.txn
```

### txnmine

```
txnmine (id:) (data:)
```

Mine a transaction (perform its TxPoW) WITHOUT posting it — from a stored txn `id:` or exported `data:`. The pre-mined result can be posted later with `txnminepost` (e.g. mine on a powerful machine, post from a weak one).

```
txnmine id:simpletxn
```

### txnminepost

```
txnminepost [data:]
```

Post a pre-mined transaction produced by `txnmine`.

```
txnminepost data:0x0000..
```

### rawtxnfrom

```
rawtxnfrom [inputs:] [outputs:] [scripts:] (state:)
```

Create an unsigned transaction in one shot from JSON: `inputs:` array of `{coinid, script}` objects, `outputs:` array of `{address, amount, tokenid, storestate}` objects, `scripts:` for the input coins, `state:` JSON state object. For programmatic construction with externally managed keys.

```
rawtxnfrom inputs:[{"coinid":"0xFF..","script":"RETURN SIGNEDBY(0xEE..)"}] outputs:[{"address":"0xDD..","amount":"9.9996","storestate":false,"tokenid":"0x00"}] state:{"0":"98","1":"[MESSAGE]"}
```

### createfrom

```
createfrom [fromaddress:] [address:] [amount:] (tokenid:) [script:] (burn:)
```

Create an unsigned transaction spending from a specific address whose script you supply — for coins controlled by keys outside the node wallet. Returns the unsigned txn data for `signfrom`.

```
createfrom fromaddress:0xFF.. address:0xEE.. amount:5 script:"RETURN SIGNEDBY(0xDD..)"
```

### signfrom

```
signfrom [data:] [privatekey:] [keyuses:] (post:)
```

Sign a `createfrom` transaction with an explicitly provided private key. `keyuses:` MUST be higher than any previous signing count for that key (Minima signatures are stateful). `post:true` posts immediately after signing.

```
signfrom data:0x0000.. privatekey:0x.. keyuses:12
```

### postfrom

```
postfrom [data:] (mine:true|false) (mmr:true|false)
```

Post a transaction signed with `signfrom`. `mmr:` attaches MMR proofs at post time; `mine:true` mines it immediately.

```
postfrom data:0x0000.. mine:true
```

---

## Scripts

### scripts

```
scripts (address:)
```

List all scripts/addresses your node is tracking, or look one up by 0x/Mx address. Response per entry: `script` (KISS VM source), `address`/`miniaddress`, `simple` (basic wallet address?), `default`, `publickey` (for simple addresses — default addresses are `RETURN SIGNEDBY(<publickey>)`), `track`.

```
scripts address:0xFED5..
```

### newscript

```
newscript [script:] [trackall:false|true] (clean:false|true)
```

Register a custom script with your node. Returns the script's address — the node then recognizes coins at that address. `trackall:true` tracks ALL coins at the address; `false` only coins whose state variables are relevant to you. `clean:true` normalizes the script to its minimal correct representation before hashing (default false — cleaning changes the address!).

```
newscript trackall:true script:"RETURN SIGNEDBY(0x1539..) AND SIGNEDBY(0xAD25..)"
```

### runscript

```
runscript [script:] (state:{}) (prevstate:{}) (globals:{}) (signatures:[]) (extrascripts:{})
```

Dry-run a script off-chain with mocked context. Scripts are auto-cleaned.

- `state:{"0":"val",..}` — transaction state values (`STATE(n)`)
- `prevstate:{"0":"val",..}` — input coin state (`PREVSTATE(n)`)
- `globals:{"@BLOCK":"101","@COINAGE":"23",..}` — global variable values
- `signatures:["0xFF.."]` — pubkeys treated as having signed (`SIGNEDBY`)
- `extrascripts:{script:proof,..}` — MAST leaf scripts and proofs

Key response fields: `clean` (cleaned script + address), `parseok`, `monotonic`, `success` (the boolean result), `variables` (final LET values). Cannot evaluate `VERIFYOUT`/`VERIFYIN`/`SAMESTATE` meaningfully — no real transaction context.

```
runscript script:"RETURN SIGNEDBY(0xFF..) AND @BLOCK GT 100" globals:{"@BLOCK":"101"} signatures:["0xFF"]
runscript script:"MAST 0x0E3.." extrascripts:{"RETURN TRUE":"0x000.."}
```

### removescript

```
removescript [address:]
```

Remove a custom script from your node's DB by its 0x/Mx address. BE CAREFUL — coins at that address stop being tracked.

```
removescript address:0xFFE678768CDE..
```

### tutorial

```
tutorial
```

Print the complete KISS VM grammar — every statement, function and global for Minima scripting.

```
tutorial
```

---

## Crypto and Data Utilities

### hash

```
hash (data:) (file:) (type:sha2|sha3)
```

Hash HEX (`0x..`) or quoted-string data, or a file (path absolute or relative to the node base folder). Default algorithm SHA3 (Keccak); `type:sha2` also supported. Returns the input and the resulting hash.

```
hash data:"this is my secret" type:sha2
hash file:myfile.txt
```

### random

```
random (size:) (type:sha3|sha2)
```

Generate a random hash value; default 32 bytes. Handy for commit-reveal secrets and nonces.

```
random size:64
```

### convert

```
convert [from:] [to:] [data:]
```

Convert data between types: `String`, `HEX`, `Mx`, `Base64`. Returns the converted value.

```
convert from:String to:HEX data:hello
convert from:HEX to:Mx data:0xFFFF
```

### maths

```
maths [calculate:] (logs:)
```

Evaluate an arithmetic expression with Minima's arbitrary-precision MiniNumber math (the same precision used on-chain) — use to precompute exact amounts. `logs:true` shows working. KISS functions like `SIGDIG` are available.

```
maths calculate:"1+2 * (3/4)"
maths calculate:"1+2 * SIGDIG(1 3/4)" logs:true
```

### sign

```
sign [publickey:] [data:]
```

Sign 0x HEX data with one of your wallet public keys (the node uses the corresponding private key). Returns the signature. Remember: Minima wallet signatures are stateful — each key has a finite number of secure uses.

```
sign publickey:0xFF.. data:0xCD34..
```

### verify

```
verify [publickey:] [data:] [signature:]
```

Verify a signature over 0x HEX data against a public key. Returns valid `true`/`false`.

```
verify data:0xCD34.. publickey:0xFED5.. signature:0x4827..
```

### mmrcreate

```
mmrcreate [nodes:[..]]
```

Build an MMR tree from a JSON array of string/HEX leaf nodes — the basis of MAST contracts (leaves as alternative scripts executed via `MAST <root>` + `txnscript`/`extrascripts`) or key-set membership proofs. Returns each leaf's `data` + `proof` and the tree `root` hash. Save the proofs — you need them to spend.

```
mmrcreate nodes:["RETURN TRUE","RETURN FALSE"]
mmrcreate nodes:["0xFF..","0xEE.."]
```

### mmrproof

```
mmrproof [data:] [proof:] [root:]
```

Check an MMR proof — for coins, MAST scripts, or custom trees from `mmrcreate`. Returns `true` if the leaf `data` + `proof` hash up to `root`.

```
mmrproof data:0xCD34.. proof:0xFED5.. root:0xDAE6..
```
