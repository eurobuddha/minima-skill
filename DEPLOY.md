# Deploy the Minima skill to the stores

Run these on your own machine / server — nothing here is executed automatically. Everything
you publish is built into `dist/` first. **Never reuse a published filename**; bump the
version and rebuild for any change (clients update by filename/version, and CDNs cache ~5 min).

Artifacts (from `./build.sh 1.0.0`):

| File | Goes to | sha256 (from `dist/SHA256SUMS.txt`) |
|---|---|---|
| `dist/minima-skill-1.0.0.zip` | GitHub release + web `/skills/` | `bc6342c2…5a00c825` |
| `dist/minima-skill-1.0.0.md` | GitHub release + web `/skills/` | `52d9c99a…d2c1cfbd` |
| `dist/minima-skill-1.0.0.mds.zip` | PandaDapps store (`panda_dapps/`) | `ea7cd7e1…729333aeb` |
| `site/index.html`, `site/minima.svg`, `INSTALL.md` | web `/skills/` | — |
| `catalog/skills.json` | web root (served at `/skills.json`) | — |

> Full current hashes are in `dist/SHA256SUMS.txt` after every build — copy from there, not from this table.

---

## 0. Build

```bash
cd ~/Projects/skillz
./build.sh 1.0.0            # writes dist/ (zip, .md, .mds.zip, SHA256SUMS.txt) + prints a catalog entry
```

## 1. GitHub release (durable public URLs)

```bash
gh release create v1.0.0 \
  dist/minima-skill-1.0.0.zip \
  dist/minima-skill-1.0.0.md \
  --title "Minima AI skill v1.0.0" \
  --notes "Everything-Minima AI skill: KISS VM contracts, MiniDapps, transactions, node ops, Maxima, native Android, diagnostics. Install: see INSTALL.md."
```

This gives permanent URLs like
`https://github.com/<you>/minima-skill/releases/download/v1.0.0/minima-skill-1.0.0.zip`.
If you prefer GitHub as the canonical download, swap the `file:` URLs in `catalog/skills.json`
to these before step 3. (The IPFS builder mirrors whatever `file:`/`icon:` point at, so either
origin is fine.)

## 2. Web download page + files → `eurobuddha.com/skills/`

Put the page, its icon, the instructions, and both downloads in one directory so the page's
relative links resolve:

```bash
# on your machine
scp site/index.html site/minima.svg INSTALL.md \
    dist/minima-skill-1.0.0.zip dist/minima-skill-1.0.0.md \
    <you>@eurobuddha.com:/var/www/html/skills/

# on the Pi (uploads land root-owned; Apache needs world-readable)
ssh <you>@eurobuddha.com 'sudo chown -R www-data:www-data /var/www/html/skills && \
                          sudo chmod -R a+rX /var/www/html/skills'
```

Live at `https://eurobuddha.com/skills/`. (`mkdir /var/www/html/skills` first if it's new.)

## 3. IPFS store "Skills" tab

**3a.** Copy the catalog to the web root (the store fetches catalogs relative to its own root):

```bash
scp catalog/skills.json <you>@eurobuddha.com:/var/www/html/skills.json
ssh <you>@eurobuddha.com 'sudo chown www-data:www-data /var/www/html/skills.json && sudo chmod 644 /var/www/html/skills.json'
```

**3b.** Add ONE tab to the store front-end. In
`~/Projects/minima/tools/dappstore/ipfs-site/index.html`, in the `var TABS = [ … ]` array
(~line 467), add a comma after the last entry and append:

```js
	{ id: 'skills',   label: 'AI Skills',      src: 'skills.json',            key: 'skills',
	  accent: '#f7931a', accentDim: '#f7931a30', note: 'AI skills — add to Claude, ChatGPT, Cursor…' }
```

The `key: 'skills'` matches the top-level `"skills": [ … ]` array in `skills.json`; each entry's
`file:` is a remote https URL, so the store renders an "External download" button (no MiniHub
install path — correct for a skill). Deploy the edited `index.html` the way you already deploy
the store (it's copied into the snapshot by `build_ipfs_store.sh`).

**3c.** Refresh the IPFS snapshot (it self-contains by downloading every `file:`/`icon:`):

```bash
ssh <you>@eurobuddha.com 'sudo /usr/local/bin/build_ipfs_store.sh'   # or wait for the hourly cron
```

> The IPFS builder only URL-rewrites the `file` and `icon` fields — `skills.json` uses exactly
> those, so both downloads are pulled into the self-contained snapshot automatically.

## 4. List the MiniDapp in the PandaDapps store (both stores)

The `.mds.zip` is a normal MiniDapp — publish it like any other, which means **both** catalogs.

```bash
scp dist/minima-skill-1.0.0.mds.zip <you>@eurobuddha.com:/var/www/html/panda_dapps/minima-skill-1.0.0.mds.zip
scp site/minima.svg                 <you>@eurobuddha.com:/var/www/html/panda_dapps/minima-skill.svg
ssh <you>@eurobuddha.com 'sudo chown www-data:www-data /var/www/html/panda_dapps/minima-skill-* && sudo chmod 644 /var/www/html/panda_dapps/minima-skill-*'
```

Add this entry to `dapps[]` in **`~/Projects/minima/tools/dappstore/pandadapps.json`** (and the
equivalent, `about`-carrying entry to `store/minimadapps.json` — "publish means both stores"):

```json
{
  "file": "https://eurobuddha.com/panda_dapps/minima-skill-1.0.0.mds.zip",
  "icon": "https://eurobuddha.com/panda_dapps/minima-skill.svg",
  "name": "Minima Skill",
  "description": "Get the everything-Minima AI skill for Claude, ChatGPT, Cursor and more — with install instructions.",
  "version": "1.0.0"
}
```

Then `scp` the edited catalog(s) back and `chown www-data`. **Structurally diff before upload**
(the manifest drifts/reformats): confirm the entry count went up by exactly one, your row is
present, and nothing else changed. A PNG tile icon renders more reliably than SVG in some
MiniHub versions — if the tile looks off, swap `minima-skill.svg` for a `minima-skill.png` and
update the one `icon` field.

## 5. Verify

- `https://eurobuddha.com/skills/` loads; both download buttons deliver the files; copy-boxes copy.
- `https://eurobuddha.com/skills.json` returns valid JSON (`curl -s … | python3 -m json.tool`).
- The store's **AI Skills** tab lists both entries with working External-download buttons.
- Checksums match: `curl -sL <file-url> | sha256sum` equals the value in `dist/SHA256SUMS.txt`.
- PandaDapps shows **Minima Skill**; opening it shows the info page and its links work.
- Cache-bust when re-checking a just-pushed file (`?v=1` query) — the CDN holds ~5 min.

---

### Re-releasing (v1.0.1, …)
Bump: `./build.sh 1.0.1`, then regenerate `catalog/skills.json` (new filenames + new sha256 from
the build's printed entry / `SHA256SUMS.txt`), and repeat steps 1–4 with the new version in every
filename. Leave the old files in place — clients pin by URL, and old links should keep working.
