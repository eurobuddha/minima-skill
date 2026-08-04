# Minima AI skill — source & distribution

Everything needed to build, publish, and install the **Minima** AI skill: a comprehensive,
on-chain-proven knowledge pack that teaches any AI assistant how to build on and operate the
[Minima](https://minima.global) blockchain.

## What's here

```
minima/                 the skill itself (Agent-Skill format)
  SKILL.md              entry point: orientation, 24 critical rules, routing table
  references/*.md       14 per-domain deep references
INSTALL.md              novice-friendly "add it to your AI" instructions (every major tool)
build.sh                packages the distributables into dist/
site/
  index.html            self-contained download/landing page (host anywhere)
  minima.svg            icon
catalog/
  skills.json           store catalog manifest (the "AI Skills" tab)
minidapp/               a small MDS MiniDapp (info + download card for the store)
  dapp.conf  index.html  icon.svg
DEPLOY.md               step-by-step publishing runbook (GitHub / web / IPFS / PandaDapps)
dist/                   build output (zip, single-file .md, .mds.zip, SHA256SUMS.txt)
```

## Build

```bash
./build.sh 1.0.0
```

Produces in `dist/`:

- `minima-skill-1.0.0.zip` — the `minima/` skill folder (Claude Code, Claude.ai, VS Code, Copilot)
- `minima-skill-1.0.0.md` — the whole skill in one file (Cursor, Windsurf, ChatGPT, Gemini, any chatbot)
- `minima-skill-1.0.0.mds.zip` — the MiniDapp (PandaDapps store)
- `SHA256SUMS.txt` — checksums

## Install (short version)

- **Claude Code:** unzip and drop the `minima/` folder in `~/.claude/skills/`.
- **Claude.ai:** upload the zip in Settings → Skills.
- **Cursor / Windsurf / ChatGPT / Gemini:** use the one-file `.md`.
- Full per-tool steps: **[INSTALL.md](INSTALL.md)**.

## Publish

See **[DEPLOY.md](DEPLOY.md)** — GitHub release, the `eurobuddha.com/skills/` page, the IPFS
store "AI Skills" tab, and the PandaDapps listing.

## Editing the skill

Edit files under `minima/`, then re-run `./build.sh <version>` and re-publish. Keep the skill
**public-safe**: no credentials, hosts, private infra, personal data, or attack tooling — it is
distributed to anyone who downloads it. MIT-licensed; sources are the official Minima docs plus
original on-chain research.
