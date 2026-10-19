# Distribution & Packaging — Shipping MiniDapps

How to package a `.mds.zip`, install it (UI / CLI / programmatic), publish it through an
app-store manifest, run the same store front-end across three capability tiers, and mirror
a catalog to IPFS. All patterns are generic and reusable.

## Packaging gotchas

Read these first — each one has silently broken a real install:

- **`dapp.conf` MUST be the first entry in the `.mds.zip`.** If it isn't, MiniHub
  *silently* fails to install — no error, the dapp just never appears. Build the zip so
  `dapp.conf` is added before anything else (see below).
- **Pending is signalled inconsistently.** A read-permission install lands in "Pending"
  for user approval, but the response sometimes carries `pending:true` and sometimes
  `status:false` with the word `"pending"` inside `error`. Detect both.
- **The sandbox `NetGET` returns a STRING.** In the web-embed sandbox, `miniweb_NetGET`'s
  `response` field is a JSON *string*, not an object — `JSON.parse` it.
- **File mode 644 or 403.** Every published file must be world-readable (mode 644, dirs
  755). A wrong-mode upload returns HTTP 403 and looks like "the store is broken."
- **Manifest fields have real type inconsistencies.** In the richer manifest dialect,
  `description`/`about`/`update` can each be a string *or* an array. Normalize before use.

---

## Packaging a `.mds.zip`

A MiniDapp is a plain web app (HTML/CSS/JS) zipped with the `.mds.zip` extension. Minimum
directory contents:

```
dapp.conf      # config/metadata (JSON) — MUST be zipped first
index.html     # entry page
mds.js         # the MDS JS library (MDS.* API)
service.js     # OPTIONAL background service that handles Main messages
icon.png       # app icon (name must match dapp.conf "icon")
assets/        # OPTIONAL folder of images, css, fonts, etc.
```

### Build command (dapp.conf first)

`zip -r` walks the directory in filesystem order, which does **not** guarantee
`dapp.conf` is the first archive entry. Force it explicitly:

```bash
# 1) add dapp.conf as the very first entry (-j = junk paths, no leading dir)
zip -j out.mds.zip dapp.conf
# 2) append everything else (-r recurse, -j flatten, or drop -j to keep asset paths)
zip -rj out.mds.zip index.html mds.js service.js icon.png assets
```

Verify the order — `dapp.conf` should be listed first:

```bash
unzip -l out.mds.zip | head
```

### `dapp.conf` format

JSON object of MiniDapp metadata read by the MiniDapp Hub:

```json
{
  "name": "Hello World",
  "icon": "favicon.ico",
  "version": "1.0",
  "description": "My Hello World MiniDapp",
  "browser": "internal"
}
```

Fields:

- **name** — the MiniDapp's display name and install identity. Stores match this
  case-insensitively against the installed list to decide Install vs Update.
- **icon** — filename of the icon in the same folder (e.g. `icon.png`, `favicon.ico`).
- **version** — dotted version string; compared numerically for update detection. Use
  semver (`MAJOR.MINOR.PATCH`).
- **description** — plain-text description.
- **browser** — `internal` (launch inside the app's webview) or `external` (open in the
  device browser). Mobile-interface hint.
- **permission** — some tooling records the requested trust level (`READ` / `WRITE`);
  actual permission is granted at install time, not from the file.
- **category** — optional store-categorization hint.

---

## Install paths

### 1. Via the MiniHub / Dapp Store UI

- **WRITE mode:** one-click install/update straight from a store row.
- **READ mode:** download the `.mds.zip` to the device first, then Home → `+` →
  **Choose File** → **Install**. (On Safari, disable "Open safe files after downloading"
  so the zip is not auto-unpacked.)

### 2. Via the terminal

```bash
mds action:install file:/path/to/out.mds.zip
# with an explicit trust level:
mds action:install file:/path/to/out.mds.zip trust:read
```

With `trust:read` the install lands in **Pending** and waits for the user to approve it
(the store only holds read permission, so it can stage but not authorize the mutation).

### 3. Programmatic install — `download → resolve path → action:install`

The canonical three-step recipe from JS. Download the zip, take the download response's
**full `path`** directly, and only fall back to `MDS.file.getpath` on the relative
`file`:

```javascript
MDS.file.download(dapp.file, function (res) {
  if (!res || res.status === false) { /* download failed */ return; }
  var full = res.response.download.path || "";  // FULL fs path — use this directly
  var rel  = res.response.download.file || "";  // relative /Downloads/<name>
  if (full) return runInstall(full);
  if (!rel) rel = "/Downloads/" + String(dapp.file).split("/").pop().split("?")[0];
  if (rel.charAt(0) !== "/") rel = "/" + rel;
  MDS.file.getpath(rel, function (p) {          // fallback: relative → absolute
    var path = (p && p.response && p.response.getpath.path) || "";
    if (!p || p.status === false || !path) { /* couldn't locate file */ return; }
    runInstall(path);
  });
});

function runInstall(path) {
  MDS.cmd("mds action:install file:" + path + " trust:read", function (r) {
    if (r && r.pending) { /* sent to Pending — user must approve */ }
    else if (r && typeof r.error === "string" && /pending/i.test(r.error)) {
      /* pending signalled as status:false + "pending" in error */
    }
    else if (r && r.status) { /* installed */ }
    else { /* install failed: r.error || r.message */ }
  });
}
```

Notes:

- Prefer the download response's **full `path`**; `getpath` on the relative `file` is only
  a fallback. (Earlier code used `getpath` unconditionally and mis-located files.)
- Delete the temp zip after install.
- **Pending is signalled inconsistently** — check `r.pending` *and* a `"pending"` substring
  in `r.error`.

### Installed-state detection

Query the installed set and compare versions:

```javascript
MDS.cmd("mds", function (r) {
  var installed = (r.response && r.response.minidapps) || [];
  installed.forEach(function (m) {
    // m.conf.name, m.conf.version
  });
  // match by lowercased name; compareSemver(catalogVersion, installedVersion)
  //   >0 → Update available;  ==0 → Installed;  not present → Install
});
```

---

## Update / versioning conventions

- Use **semver** in `dapp.conf` `version`.
- MiniDapps **do not auto-update** — the user decides. A store marks an update available
  when the catalog version is greater than the installed `conf.version` for a matching
  (lowercased) name.
- Always **Update** rather than delete-then-reinstall: update migrates the MiniDapp's
  database to the new version; delete destroys that data (on-chain coins are unaffected,
  but app-local data is lost).

---

## Two manifest dialects for app stores

Both dialects share a top-level shape:
`{ name, description, icon, version, dapps: [...] }`.

### Minimal dialect — lean and consistent

Every dapp entry has **exactly five string fields, all required, all present** — safe to
consume naively:

| field | meaning |
|---|---|
| `file` | absolute HTTPS URL to the `.mds.zip` |
| `icon` | absolute HTTPS URL to the icon |
| `name` | install identity (matched case-insensitively vs installed list) |
| `description` | plain string (always a string in this dialect) |
| `version` | dotted version, compared numerically |

### Mirror dialect — richer and inconsistent

The same 5 core fields **plus** optional metadata with real type inconsistencies a client
must tolerate:

- `description` — **string OR array-of-strings**.
- `about` — list on most entries, **string on a few**.
- `update` — list on most, **string on some**.
- `date` — string (e.g. `"April 14, 2025"`).
- `history[]` — heterogeneous: empty `{}`, or `{version, file:"", update:<str>}`, or
  `update` as a nested array; inner `file` is usually `""`.
- `category`, `gallery` (few); `dependencies` (rare, e.g. `["MiniFS"]`).

Keep a normalizer in any shared consumer:

```javascript
/* mirror-dialect quirk: description/about/update are string OR array */
function normDesc(d) { if (Array.isArray(d)) d = d.join(' '); return d || ''; }
```

Also **force-upgrade `http://`→`https://`** on `file`/`icon` before use, and carry a
`sha256` per entry so clients can verify the downloaded zip.

---

## Three front-end execution contexts = three capability tiers

The same store UI can run in three places with very different powers. Detect which you're
in and degrade gracefully:

1. **Inside a sandboxed web-embed iframe** — **no `MDS` object**. Every privileged call is
   brokered by the parent frame via `postMessage` through a `miniweb.js` shim. Can read
   node state and install (brokered), nothing else.
2. **As a first-class MDS MiniDapp** — direct `MDS.*` access, direct install. Full power.
3. **On a bare IPFS/HTTP gateway** — plain `fetch()`, **no node present**. Download-only;
   there is no install path at all.

---

## The web-embed sandbox API (`miniweb_*`)

For front-ends running inside the sandboxed iframe. Load the `miniweb.js` shim and **call
`miniweb_Init()` first** — it installs the `window.onmessage` reply listener. Each call
mints a `randid`, posts `{action, data, randid, ...}` to the parent, and the parent
replies `{action:"MINIWEB_RESPONSE", randid, data}`. **Requests have a ~2-minute TTL.**

| function | callback receives (`msg.data`) |
|---|---|
| `miniweb_Init()` | — (sets up listener; call once, first) |
| `miniweb_NetGET(url, cb)` | `{status, response}` — **`response` is a STRING → `JSON.parse` it** |
| `miniweb_MdsCmd(cmd, cb)` | raw command response (read-only allowlist) |
| `miniweb_InstallDapp(fileUrl, name, cb)` | `{status, installed, pending}` or `{status:false, error}` |
| `miniweb_JumpToURL(minifile, cb?)` | cross-site navigation |

```javascript
miniweb_Init();
miniweb_NetGET("https://example.org/store.json", function (msg) {
  var data = JSON.parse(msg.response);   // response is a STRING
  // ... render data.dapps
});
```

### The trust boundary is an ALLOWLIST, not a denylist

The parent enforces, from the outside:

- **`NET_GET`:** HTTPS only; **blocks loopback/LAN** (`127.0.0.1`, `localhost`, `0.0.0.0`,
  `[::1]`, `192.168.*`, `10.*`).
- **`MDS_CMD`:** a **read-only allowlist** — roughly
  `mds, block, status, balance, coins, maxima, checkmode, history, tokenvalidate, keys,
  getaddress, random, convert, hash` — and it **refuses** any string containing
  `action:install / uninstall / remove / send / sendall`. The iframe can *read* node state
  but cannot mutate through the generic cmd proxy.
- **`INSTALL_DAPP`** is the one sanctioned mutation path.

The front-end also **force-upgrades `http://`→`https://`** on the file URL before handing
it up.

---

## Server hosting hygiene

- **Filenames lowercase-hyphenated** (`mydapp-1.2.0.mds.zip`). Local builds are often
  mixed-case with underscores — rename on upload so the filename matches the URL in the
  manifest exactly. Case-sensitive servers turn a wrong-case name into a **404**.
- **Every published file mode 644, dirs 755.** A wrong-mode (e.g. 700) upload returns
  **HTTP 403** and looks like a broken store. Verify — the following should print nothing:

  ```bash
  find <webroot> -type f ! -perm -o=r    # any file NOT world-readable → fix it
  ```

- **`sha256` in catalogs.** Publish a checksum per zip/asset so clients verify integrity
  after download.

---

## IPFS / IPNS mirror pattern (reusable design patterns)

A content-addressed mirror gives a catalog a DNS-stable address that survives origin
outages. The following are reusable patterns, not any specific pipeline:

- **Single-instance flock guard** — `exec 9>/some/lock; flock -n 9 || exit 0`. A slow run
  (large downloads) must not overlap the next scheduled fire.
- **Self-contained snapshot** — copy the catalog + local dapps from the origin, then pull
  every externally-hosted zip/asset into a **persistent download cache** so the snapshot
  has no live external dependencies. Treat `latest`-style URLs as always-refetch (their
  content changes without the name changing).
- **Dual catalog rewrite** — emit each catalog twice: one with **root-relative** paths
  (works at any gateway or raw `/ipfs/<CID>/` path) and one with **absolute** URLs for
  clients that require absolute `file`/`icon`. Rewrite only the `file`/`icon` fields.
- **Asset integrity check** — verify each asset against the catalog `sha256`, **refetch
  once** on mismatch, and **prune** assets no longer referenced (snapshot stays
  current-versions-only).
- **Change detection** — hash the whole stage
  (`find | sort | sha256sum | sha256sum`) against a stored hash; skip the `ipfs add`/publish
  if unchanged **but still reconcile the remote pin**.
- **Idempotent remote-pin reconciliation** — on both the publish and the no-change paths:
  skip if the CID is already queued/pinned, otherwise pin, then **rotate** — unpin any
  remote pin that isn't the current CID. (Skipping pinning on no-change runs means a failed
  pin never retries.)
- **Publish + DNSLink** — `ipfs add -r --cid-version 1 -Q` → `ipfs name publish` →
  remote-pin rotation → write the CID somewhere clients can read it. DNSLink is a one-time
  TXT record (`_dnslink.<host> → dnslink=/ipns/<key>`), so publishes never touch DNS again.

Access surface for such a mirror: your own gateway, any public gateway via
`/ipns/<host>/`, or the DNS-free raw IPNS key `/ipns/<k51-key>`.

---

## Release discipline for real-funds software (hard lessons)

- ★ **NEVER change code without bumping versionCode+versionName: one logical change = one version
  = one commit = one push**, enforced by a pre-commit hook — and know the hook's blind spot: a
  hook keyed on `src/` commits a patched bundled `minima.jar` cleanly with no bump; the most
  consequential change is the one the hook cannot see. Every build is one immutable versioned
  artifact, archived forever, with `shasum -a 256` sidecar lines so `shasum -c` works. Never
  overwrite a published binary; never let two different binaries claim one version — a
  "split-brain" republish (built a few commits behind the reviewed source) is resolved by
  shipping a NEW version of the reviewed code, never by re-tagging.
- **A store catalog is manifest-only:** metadata plus a per-row sha256; binaries live on release
  hosting, never in git (GitHub's pre-receive rejects >100 MB blobs and you end up squashing
  history — gitignore `dist/` from day one). Clients verify downloads against the catalog hash —
  re-stamp every row on publish, and after publishing, **download the public artifact back and
  compare hashes** before calling it released.
- **"Publish" means every surface, atomically:** the release is not done until the primary store,
  the mirror, and the decentralized (IPFS) snapshot all serve the new version with matching
  hashes. Encode this in one release script that exits non-zero unless everything is live.
  Running a legacy publisher does not update the current public host — verify the *public*
  endpoint serves the new content by hash, not that your publish job exited 0.
- **IPFS store mirroring that works:** pin the snapshot on a second self-hosted node; keep kubo
  versions/defaults identical so both compute identical CIDs; sync by *pulling* a published CID
  file over HTTPS and `ipfs pin add` (bitswap moves only changed blocks); set mutual
  `Peering.Peers`. A remote pinning service is redundancy and must **never be a gate** — run it
  last, warnings only. A public gateway only serves blocks it can still fetch from someone: with
  one provider, the "gateway fallback" expires with the cache.
- **Deploy via a versioned file + symlink** so rollback is one `ln -sf`; name artifacts with
  their version (a deploy script that derives version from filename turns an unversioned jar
  into `-dev`); run a secrets audit before making any repo public.
- **Surgical jar patching** (changing a prebuilt node jar without a toolchain rebuild): patch
  EVERY copy of the jar (they drift); compile the class once PER jar with that jar as classpath
  (clean compilation is the API-compatibility proof); use `zip`, not `jar uf` (unreliable on fat
  jars); verify entry counts unchanged, the patched class's CRC identical across jars, then
  `dexdump` the built APK to confirm the class survived into the dex (JVM-valid bytecode can
  still be rejected by ART) — and finally verify the change *does* something: arrival is not
  behavior.
- **MiniDapp packaging:** the version lives in `dapp.conf` and the same bump-per-change rule
  applies; bump `?v=` cache-busters in lockstep and CI-gate version + busters + visible footer
  stamp together.
- **Changing an Android app's applicationId orphans its data** — it needs explicit migration and
  users must keep the previous install until recovery is verified. Keep the IPC action prefix
  constant across SKUs so companions work against either; two same-prefix nodes can't run
  simultaneously anyway (port bind) — a cheap port pre-flight probe with a plain warning covers
  the confusion.
