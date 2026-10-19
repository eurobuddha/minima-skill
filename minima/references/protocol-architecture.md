# Minima Protocol Architecture

A conceptual reference for how the Minima blockchain works. Minima is a complete, decentralized blockchain designed to be so compact that **every user runs a full constructing-and-validating node** — on a phone if they like. There are no miners, no master nodes, no delegates, and no ever-growing database.

## Key concepts at a glance

- **Every node is a Complete node.** All Minima nodes construct blocks *and* validate every transaction. There are no special user classes and no block rewards — security comes from millions of users each doing a small amount of Proof-of-Work.
- **TxPoW = Transaction + Proof-of-Work.** Users mine their own transactions (~a few seconds of hashing). If the resulting hash is, by chance, also below the block difficulty, that same TxPoW unit *becomes a block*. Blocks are just lucky transactions.
- **50-second block target**, adjusted every block (max ±10%), with consensus via **GHOST** (heaviest branch wins, not longest chain).
- **The Cascading Chain** compresses history: old blocks are pruned, but "Super Blocks" (blocks that by chance achieved 2x, 4x, 8x… the required difficulty) are kept in a 32-level logarithmic chain that preserves the total cumulative PoW without storing every block.
- **The MMR (Merkle Mountain Range)** is a "storage-less" proof database of all coins (UTxOs). Users store only proofs for *their own* coins plus the tree peaks — like keeping your own page of a book plus its spine — and present a CoinProof when spending.
- **Coins are UTxOs.** Every coin has a CoinID, amount, address (always Pay-to-Script-Hash), tokenid, and optional state variables. The Minima tokenid is `0x00`.
- **Tokens are Coloured Coins.** Custom tokens and NFTs are tiny fractions of Minima "coloured" to represent a supply; the network processes them identically to Minima with no extra storage cost.
- **Quantum-safe by design**: SHA3-256 everywhere, and Winternitz One-Time Signatures (WOTS) arranged in Merkle trees of keys. Each private key must only sign **once** (see the key-security reference).
- **The Magic numbers** are the chain's self-governing parameters (max TxPoW size, max txns/block, min TxPoW work, max KISS VM ops), recalculated every block from a heavily weighted average of the network's desired values — no hard forks needed to scale.
- **Layers**: Minima (L1, on-chain value), Maxima (off-chain P2P information transport), Omnia (L2 payment channels), and MiniDapps (Web3 apps via the MiniDapp System, MDS).

---

## What Minima is

Minima's whitepaper premise: paying a small group of miners (or validators, or delegates) to run a chain inevitably centralizes it. Minima's answer is a network where *every single user is an equal and Complete member* — each node validates the whole chain **and** participates in constructing it. Disrupting the network would mean attacking, bribing, or coercing the entire user base.

This forces the design: the protocol must be resource-efficient enough that anyone can run a Complete node at all times (including on a phone); there are no paid miners; and the protocol must be *complete* (finished) from inception — scalable from day one and quantum secure — because with everyone as a miner there are no soft forks, and hard forks become impossible at scale. Ossification is the goal, as with TCP/IP or SMTP.

There are no block rewards and no minimum holding required to run a node. Maximum supply is one billion Minima, all created at genesis; the supply is deflationary via the Burn (see below).

## TxPoW: users mine their own transactions

**TxPoW (Transaction Proof-of-Work)** is Minima's unifying primitive: the transaction and the proof-of-work are one object. When a user sends a transaction, their own device hashes the TxPoW header, incrementing a nonce until the hash meets the **transaction difficulty** — roughly a second of work on the device. Only then may the TxPoW be propagated to the network and enter the mempool.

Crucially, the TxPoW header is *also* a candidate block header representing the node's current view of the chain. If the mined hash happens to also be below the much harder **block difficulty** target, the TxPoW becomes a block (a **TxBlock**) and is added to the chain. Sometimes, when you send a transaction, you also find a block. This is how the chain is constructed with no dedicated miners: everyone's small contributions sum to the chain's total PoW (an idea descended from P2Pool and HashCash).

A TxPoW unit contains:

- **Header**: nonce, Chain ID (must be `0x01`), timestamp, block number, block difficulty, cascade levels (32), Super Parent references, MMR root hash, MMR total (the sum of all coins — making total supply provable every block, eliminating inflation bugs), the Magic numbers, and the hash of the body.
- **Body**: a random number (so every node mines a different candidate), the transaction difficulty, the **main transaction** (inputs, outputs, state variables, link hash), its **Witness** (signature proofs, coin proofs, script proofs — each an MMR proof), an optional **Burn transaction** with its witness, and a **txn list** of mempool transaction *hashes* to include if this unit becomes a block.

Blocks reference transactions only by hash (like Bitcoin compact blocks) since the transactions were already relayed — so blocks are tiny.

**The Pulse.** Nodes that aren't transacting still secure the chain: periodically every node mines a TxPoW with an *empty* transaction (a Pulse), sharing its latest chain view and mempool with peers — and if it happens to meet block difficulty, the Pulse becomes a block. Peers that fail to Pulse are dropped. There are no fees; instead the **Burn** (any excess of inputs over outputs, destroyed from circulation) orders mempool transactions, regulates congestion, and makes DDoS spam expensive.

## The blockchain: TxPoW Tree + Cascading Chain

The chain has two parts:

1. **The TxPoW Tree** — the recent, unpruned portion: the most recent 1024 blocks, plus any natural branches caused by simultaneous block finds. Its root connects to the tip of the Cascade.
2. **The Cascading Chain (the Cascade)** — a compressed, unbroken chain of older block headers that preserves the chain's total cumulative Proof-of-Work without storing every block.

### How the Cascade works

Random hashing means some blocks, by luck, vastly exceed the required difficulty. A block that achieved at least 2^L times the block difficulty is a **Super Block** capable of standing in for 2^L ordinary blocks' worth of PoW. The Cascade defines **32 levels (0–31)**, each twice as hard as the one below, with a maximum of **128 blocks per level**. The probability of reaching level L is 1/2^L (a level-L Super Block appears on average every 50×2^L seconds), so the Cascade grows only logarithmically while its total weight tends toward the weight of the full unpruned chain.

Every block header carries **Super Parent** references — a pointer to its immediate parent and to the most recent block at each existing Super level — keeping the Cascade unbroken after pruning.

**Cascading process**: once the main chain reaches 1124 blocks (1024 + 100), the oldest 100 blocks are folded into the Cascade. Working backwards, blocks fill level 0 (128 slots); beyond that, only blocks meeting level-1 difficulty survive into level 1, then level 2, and so on — everything else is pruned. Before pruning, the new tree root's MMR set is updated with CoinProofs for tracked unspent coins, so no coin proofs are lost. A Super Block's **current weight** = base weight × 2^(current level).

The Cascade gives any newcomer objective, independently verifiable proof of the heaviest (hence valid) chain — Nakamoto consensus without the full history.

## Mining, difficulty, and the Magic numbers

Minima has three difficulty tiers, all evaluated against the hash of the TxPoW header (the TxPoW ID):

| Tier | Purpose | Target |
|---|---|---|
| **Transaction difficulty** | Admission to the network; anti-spam | ~1 second of work on the sending device (minimum equivalent to 1M hashes); mining stops once met |
| **Block difficulty** | Keeps blocks at ~50-second intervals | Adjusts every block by up to ±10% based on the median-smoothed speed of the last 256 blocks |
| **Super Block difficulty** | Positions blocks in the Cascade | Level L = 2^L × block difficulty, achieved by chance |

The node never *tries* to meet block difficulty — it mines only until the transaction target is met, then checks whether it lucked into a block.

**Magic numbers** are the four consensus parameters that future-proof the network without forks:

- `CurrentMaxTxPoWSize` — max TxPoW size in bytes (default/minimum 64 KB)
- `CurrentMaxTxnPerBlock` — max transactions per block (default/minimum 256)
- `CurrentMinTxPoWWork` — minimum PoW for a TxPoW to be relayed (minimum ≈ 1M hashes)
- `CurrentMaxKISSVMOps` — max KISS VM script operations per TxPoW (default/minimum 1024)

Each node may state a *Desired* value (between half and double the current value); every block, the Current values are recalculated as a 16383:1 weighted average favoring the network value. If the whole network agrees on a change, the chain converges to it over ~50 days. As phones get more powerful, Minima grows with them — "magically," with no protocol upgrade.

**Consensus (GHOST).** Branches occur naturally when two blocks of the same height are found. Minima uses **GHOST** (Greedy Heaviest Observed SubTree): the main chain is the *heaviest* branch — the most cumulative PoW weight — not the longest. This tolerates fast block times and defeats secret attacker chains, since a long-but-light chain never outweighs the branch the whole network is building on.

**Validation.** Every node validates every TxPoW it mines or receives: chain ID, difficulty, signatures, scripts, MMR CoinProofs, no double-use of coins, timestamps, burn-transaction link hash. Invalid units get the sender disconnected; borderline units (e.g. non-monotonic scripts that may become valid later, or coins also seen in the mempool) are kept but not forwarded.

## The MMR: a storage-less proof database

Minima has **no global UTXO database**. Instead it uses a **Merkle Mountain Range (MMR)** — an append-only hash-sum tree (based on Peter Todd's design) containing every transaction output (spent or unspent) as a leaf.

The book analogy from the docs: *if all coins were pages in a book, each user keeps only their own pages plus the spine. To spend, you present your page (CoinProof); anyone can check it fits their copy of the spine (the MMR peaks/root).*

Mechanics:

- Coins are hashed in pairs into the largest possible binary trees; unequal leaf counts create multiple peaks — the "mountain range." Bagging the peaks left-to-right yields a single root, which every block header commits to.
- Each tree node holds **MMRData** = (hash, value): for a leaf, the hash of the coin object and its Minima value (0 if spent); for parents, the hash-sum of children. The root's value is thus the total Minima in existence, checked every block.
- Every entry has a coordinate [Row, Entry]; the parent of [R,E] is [R+1, floor(E/2)]. Max 256 rows → up to 2^256 coins ever.
- A **CoinProof** is a list of proof chunks (sibling hashes + left/right flags) from a coin up to a peak. Any node can recompute the path; if the computed peak matches its own, the coin provably exists and is unspent.
- Spending flips the coin's spent flag (changing its leaf hash); outputs append new leaves. So **proofs change every block** — each block carries an MMR Set of updated entries, and users must stay reasonably in sync. A user offline too long doesn't lose coins, but needs an archive/mega node (or a friend tracking their proofs — coin proofs are not security-sensitive) to refresh them.
- Separate MMRs store **Signature Proofs** and **Script Proofs**.

This is why Minima is called *storage-less*: a normal node stores only its own coins' proofs plus the peaks — orders of magnitude less than a full ledger — while a **Mega-MMR node** opts to hold the proofs for *every* unspent coin on the network, so it can serve proofs to others and help users recover.

## The coin (UTXO) model and state

Every coin (UTxO) has:

| Attribute | Meaning |
|---|---|
| `coinid` | Globally unique ID: hash(first input coin of the creating txn \| output index) |
| `amount` | Amount of Minima (token transactions are just amounts of coloured Minima) |
| `address` | Hash of a script — **all Minima addresses are P2SH**. Default script: `RETURN SIGNEDBY(owner_public_key)` |
| `tokenid` | `0x00` for Minima; a full 64-byte hash for any custom token |
| `floating` | If true, the CoinID is ignored — any coin matching amount/address/tokenid can satisfy the input (used by advanced contracts, e.g. ELTOO) |
| `storestate` / `state` | Whether/which **state variables (0–255)** from the creating transaction are stored on the coin — readable from scripts, enabling stateful contract sequences |
| `mmrentry`, `spent`, `created` | MMR leaf number, spent flag, creation block |

A transaction = inputs (coins being spent, each requiring a CoinProof, script proof, and signature) + outputs (new coins: payments and change) + state variables + link hash. Outputs must not exceed inputs; **any difference is burned**, permanently reducing supply. Every coin is guarded by a KISS VM script that must return TRUE to be spent — the default is simply "signed by the owner," but any contract (HTLCs, covenants, MAST, oracles, vaults) is expressible. Script execution is bounded by the `CurrentMaxKISSVMOps` magic number.

## Coloured coins: native tokens and NFTs

Minima supports custom tokens **natively** — no token contract standard, no extra load on the network. A token is created by *colouring* a fraction of Minima:

- Minima carries 44 decimal places, so colouring even `1e-33` Minima can represent, say, 1000 tokens with 8 decimals (via a **scale** factor).
- The **tokenid** is created by hashing the creating coin's ID and total amount — globally unique. Minima itself is always tokenid `0x00`.
- Token metadata: name/description (a string or full JSON), total supply, decimals, scale, and an optional **token script** validated *in addition to* the coin's address script on every spend.
- **NFTs** are simply tokens with 0 decimals — spendable only whole.

Token transactions are stored, proved, and validated exactly like Minima transactions in the MMR; the network doesn't distinguish them.

## Quantum-safe signatures (overview)

Minima's consensus-critical cryptography must never need replacing, so it is post-quantum from genesis:

- **Hashing**: SHA3-256 everywhere — TxPoW mining, block and transaction hashes, proof chains, signing. (KISS VM also exposes SHA2-256 for cross-chain hash-lock contracts with legacy chains.)
- **Signatures**: the **Winternitz One-Time Signature scheme (WOTS)**, parameter 8 — hash-based and quantum-resistant, but **each key pair may safely sign only once**. Signatures are large (400–800 bytes, 10–20x ECDSA) but are pruned like almost everything else — a bandwidth cost, not a permanent one.
- **Trees of keys (Merkle Signature Scheme)**: many WOTS key pairs are stored as leaves of MMR key trees whose root hash is a reusable **root public key**. Minima builds a 3-level *tree of trees* with 64 keys per tree, giving 64^3 = **262,144 one-time signatures per root public key**, each signature carrying a proof path to the root.

The one-time property is a real operational constraint (why key reuse and certain backup/restore patterns are dangerous) — see the **key-security** reference for the practical rules.

## The network: four layers

1. **Layer 1 — Minima**: the blockchain; on-chain value transfer, flood-fill propagation, processed by every node. Where transacting relationships are established and L2 disputes settle.
2. **Maxima**: the off-chain, point-to-point **information transport layer** over the same P2P network — encrypted user-to-user messaging and data. Maxima traffic *also* pays PoW, so off-chain activity strengthens Layer 1 security instead of starving it (the inverse of fee-based chains).
3. **Layer 2 — Omnia**: bi-directional payment channels using **ELTOO** (Lightning-style, more flexible) for instant, effectively unlimited-TPS off-chain payments and contract sequences, settled on L1 only when needed.
4. **Layer 3 — MiniDapps**: decentralized applications built with JavaScript/HTML/CSS on the **MiniDapp System (MDS)**, combining value transfer (Minima), messaging (Maxima), scaling (Omnia), and KISS VM contracts.

The default P2P port is 9001; nodes accepting incoming connections additionally act as relays strengthening the network backbone.

## Node types

**All Minima node types are full, Complete nodes** — every one creates blocks, validates all transactions, and contributes PoW. They differ only in how much *extra* history/proof data they keep:

| Type | Keeps | Typical host | Notes |
|---|---|---|---|
| **Full node** (default) | ~24h of full blocks + the Cascade + proofs for *its own* coins only | Phone, Pi, desktop | Minimal storage; the standard experience |
| **Mega-MMR node** | Everything a full node has, **plus proofs for the complete unspent coin set** (the Mega MMR) | Server (must stay online; <24h downtime) | Serves coin proofs, resyncs/recovers other users, hosts public MiniDapps and web wallets, posts transactions on behalf of external/light users |
| **Archive node** | All sync blocks (headers + coin proofs) from when it started — no pruning; full txn details still pruned after ~2 months | Server/desktop | Resyncs nodes back to genesis (if seeded from a genesis archive file); exports chain history to bootstrap new archive/mega nodes |

"Light/read-only" usage (e.g. a web wallet) is served *by* a Mega-MMR node, which can create and post transactions on behalf of external users — the light user still relies on a Complete node, keeping the chain itself uniform.

## Glossary of Minima terms

- **TxPoW** — Transaction Proof-of-Work: the unified transaction+candidate-block unit every user mines themselves. Its header hash is the **TxPoW ID**.
- **TxBlock** — a TxPoW whose hash also met block difficulty, added to the chain with MMR peaks, spent-coin proofs, and new-coin list.
- **Coin** — a UTxO: `coinid`, amount, P2SH address, tokenid, optional state.
- **CoinProof** — the MMR path chunks proving a coin exists and is unspent; required per input.
- **MMR** — Merkle Mountain Range: the append-only hash-sum proof tree of all coins (also used for signatures, scripts, and key trees).
- **Mega MMR** — the complete unspent-coin proof set, held by Mega-MMR nodes to serve the network.
- **Cascade** — the 32-level compressed chain of Super Block headers preserving total cumulative PoW after pruning.
- **Super Block** — a block that by chance achieved ≥2^L times block difficulty, earning Cascade level L.
- **Magic** — the four self-adjusting network parameters (max TxPoW size, max txns/block, min TxPoW work, max script ops) converged via weighted per-block voting.
- **GHOST** — Greedy Heaviest Observed SubTree; heaviest-branch chain selection.
- **Pulse** — the periodic empty-transaction TxPoW every node mines to sync peers and add PoW; no Pulse, no peering.
- **Burn** — inputs minus outputs, destroyed from supply; orders transactions and throttles spam. No minimum.
- **Maxima** — the off-chain, point-to-point information layer of the Minima network.
- **MDS** — the MiniDapp System: the runtime and API through which MiniDapps (JS/HTML apps) use the node.
- **KISS VM** — Minima's simple, Turing-complete scripting language; every address is the hash of a KISS VM script (see the smart-contracts reference).
- **tokenid** — a token's unique 64-byte identifier; `0x00` is Minima itself.
- **State variables** — up to 256 per-transaction data registers (0–255), readable by scripts and storable on coins, enabling stateful contracts.
- **WOTS** — Winternitz One-Time Signature scheme; quantum-safe, strictly single-use keys organized into Merkle trees of keys.
- **Mempool** — unconfirmed valid TxPoW units, ordered by burn.
- **Chain ID** — the network identifier in every TxPoW header; `0x01` on the Minima main chain.

---

## Protocol facts that surprise implementers

- ★ **The seed is NOT BIP39: it is `SHA3-256(UPPERCASE space-joined phrase)`** — no PBKDF2, no
  checksum, no wordlist validation. A lowercased phrase hashes to a different, valid-looking,
  *empty* wallet with no error anywhere. Always uppercase before hashing; never validate phrases
  against BIP39 wordlists.
- **Wire-codec field order is protocol, not style.** A reimplementation that reorders one
  serialized field silently breaks interop with classic nodes while both sides still work
  against themselves. Gate any port with byte-exact golden vectors captured from the official
  `minima.jar` plus a live interop test against a real classic node.
- **The `Mx` address encoding is NOT standard base32** — it is a positional big-integer
  conversion with `i→w, l→y, o→z` substitutions that destroys leading zero bytes (hence the
  `0x01` guard byte), and SHA3-256 is used with two different pre-processings in different
  places. A library base32 produces an address that looks valid and resolves to nothing — always
  round-trip addresses through Minima's own code. (Also: hex of empty input is `""`, not
  `"0x"`.)
- **Per-transaction PoW is not verified on the relay/inclusion path** (audit finding) — only the
  *claimed* difficulty is bounds-checked. Do not design anything that relies on txn PoW as an
  anti-spam or rate guarantee.
- **Initial sync is weak-subjectivity:** IBD sync blocks are accepted on block-number/parent-hash
  linkage only — no MMR re-derivation, no PoW verification (audit finding). Sync fresh or
  restoring nodes from hosts you trust; cross-check balances against a second source.
- ★ **Pruning changes what is auditable, permanently.** A normal (even MegaMMR) node keeps
  headers + the live coin/MMR set; spent history and signature witnesses are gone on cascade.
  Consequences: (a) a third party cannot total an arbitrary address or enumerate a token's
  holders — publishing a treasury address "for verification" proves nothing on Minima; (b)
  anything needing historical witnesses (signature forensics, reuse audits) requires an archive
  node run continuously from the relevant era — once cascaded, the data is permanently gone.
- ★ **Anyone can create a token with any name — identity is the tokenid only.** Verify the full
  tokenid character-for-character against the issuer's published validation. `tokenvalidate` has
  two independent halves: `webvalidate` (a domain publishes this tokenid — provable) and
  `signature` (signed at mint). Token metadata is fixed at creation and **cannot be signed
  retrospectively** — an unsigned token's owner field is a claim, not proof.
