#!/usr/bin/env bash
# Package the Minima AI skill for distribution.
# Produces, under dist/:
#   minima-skill-<VER>.zip      the Agent-Skill folder (minima/SKILL.md + references/)
#   minima-skill-<VER>.md       the whole skill flattened into one Markdown file
#   minima-skill-<VER>.mds.zip  a MiniDapp that shows + serves the skill (dapp.conf FIRST)
#   SHA256SUMS.txt              sha256 of every artifact (catalogs verify against these)
# Idempotent: safe to re-run. Never reuse a published filename — bump VER for a new release.
set -euo pipefail

VER="${1:-1.0.0}"
ROOT="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$ROOT/minima"
DAPP_DIR="$ROOT/minidapp"
DIST="$ROOT/dist"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi; }

[ -f "$SKILL_DIR/SKILL.md" ] || { echo "ERROR: $SKILL_DIR/SKILL.md not found" >&2; exit 1; }
mkdir -p "$DIST"

# ---- 1. The Agent-Skill folder zip (clean: only the minima/ skill) --------------------
ZIP="$DIST/minima-skill-$VER.zip"
rm -f "$ZIP"
( cd "$ROOT" && zip -rq "$ZIP" minima -x '*.DS_Store' )
echo "built  $ZIP"

# ---- 2. Single-file Markdown (SKILL.md + every reference, one document) ----------------
ONE="$DIST/minima-skill-$VER.md"
{
  echo "<!-- Minima AI skill v$VER — single-file edition."
  echo "     This is the SKILL.md plus every reference file concatenated into one document,"
  echo "     for tools that take a single rules/instructions/knowledge file (Cursor, Windsurf,"
  echo "     Copilot, ChatGPT, Gemini, ...). In the routing table below, each 'references/NAME.md'"
  echo "     link corresponds to a '## reference: NAME' section further down this file."
  echo "     Install help: see INSTALL.md or https://docs.minima.global . MIT-licensed. -->"
  echo
  cat "$SKILL_DIR/SKILL.md"
  for f in "$SKILL_DIR"/references/*.md; do
    name="$(basename "$f" .md)"
    echo; echo; echo "---"; echo
    echo "## reference: $name"
    echo "<!-- (was references/$name.md) -->"
    echo
    cat "$f"
  done
} > "$ONE"
echo "built  $ONE"

# ---- 3. MiniDapp package (only if minidapp/ exists) — dapp.conf MUST be first entry -----
if [ -f "$DAPP_DIR/dapp.conf" ]; then
  MDS="$DIST/minima-skill-$VER.mds.zip"
  rm -f "$MDS"
  ( cd "$DAPP_DIR" && zip -q "$MDS" dapp.conf && zip -rq "$MDS" . -x dapp.conf -x '*.DS_Store' )
  echo "built  $MDS"
else
  echo "skip   MiniDapp (no $DAPP_DIR/dapp.conf yet)"
fi

# ---- 4. Checksums ----------------------------------------------------------------------
( cd "$DIST" && : > SHA256SUMS.txt
  for f in minima-skill-$VER.zip minima-skill-$VER.md minima-skill-$VER.mds.zip; do
    if [ -f "$f" ]; then echo "$(sha "$f")  $f" >> SHA256SUMS.txt; fi
  done )
echo; echo "== dist/ =="; ls -la "$DIST"; echo
echo "== SHA256 =="; cat "$DIST/SHA256SUMS.txt"

# ---- 5. Print a ready-to-paste catalog entry (fill file: URLs after the GitHub release) -
ZIP_SHA="$(sha "$ZIP")"
echo
echo "== catalog entry (skills.json 'skills[]' — set file:/icon: to your published URLs) =="
cat <<JSON
{
  "file": "https://github.com/<you>/minima-skill/releases/download/v$VER/minima-skill-$VER.zip",
  "icon": "https://eurobuddha.com/skills/minima.svg",
  "name": "Minima",
  "description": "Everything-Minima AI skill: KISS VM contracts, MiniDapps, transactions, node ops, Maxima, native Android, diagnostics.",
  "category": "AI Skill",
  "version": "$VER",
  "sha256": "$ZIP_SHA"
}
JSON
