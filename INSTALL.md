# Add the **Minima** skill to your AI

This skill teaches an AI assistant everything about building on and operating the
[Minima](https://minima.global) blockchain — KISS VM smart contracts, MiniDapps (MDS),
transactions and tokens, running a node, Maxima messaging, native Android integration, and
how to diagnose failed transactions. It is packed with hard-won, on-chain-proven gotchas so
your AI gives you *correct* Minima answers instead of guessing.

You don't need to be technical to install it. Pick the tool you use below and follow the steps.

---

## What's in the download

You downloaded one (or both) of these:

| File | What it is | Use it for |
|---|---|---|
| `minima-skill-1.1.0.zip` | The skill as a folder (`minima/` with `SKILL.md` + `references/`) | Claude Code, Claude.ai, VS Code, Copilot — anything that supports "Agent Skills" |
| `minima-skill-1.1.0.md` | The whole skill flattened into **one** Markdown file | Cursor, Windsurf, ChatGPT, Gemini, or any chatbot — paste or attach it |

Both contain the same knowledge. The `.zip` is the "official" format; the single `.md` is the
"paste anywhere" fallback.

---

## Claude Code (terminal)

1. Unzip `minima-skill-1.1.0.zip`. You'll get a folder called `minima`.
2. Move that `minima` folder into your skills directory:
   - **All your projects:** `~/.claude/skills/minima`
   - **Just one project:** `<your-project>/.claude/skills/minima`
3. Start Claude Code (or run `/skills` to confirm it's listed). Done — it loads automatically
   whenever you ask a Minima question.

```bash
# one-liner (macOS/Linux), run from where you unzipped:
mkdir -p ~/.claude/skills && cp -r minima ~/.claude/skills/
```

## Claude.ai (web / desktop app)

*Requires a Pro, Max, Team, or Enterprise plan.*

1. Go to **Settings → Capabilities → Skills** (look for **Skills** / **Custom skills**).
2. Click **Upload skill** and choose `minima-skill-1.1.0.zip`.
3. That's it — Claude uses it automatically when your chat is about Minima. (In a Project,
   you can instead just attach the zip or the `.md` file to the Project's knowledge.)

## VS Code + GitHub Copilot

VS Code supports Agent Skills natively. Put the `minima` folder in any of these:

- **This workspace:** `.github/skills/minima` (or `.claude/skills/minima`)
- **All workspaces:** `~/.copilot/skills/minima` (or `~/.claude/skills/minima`)

Reload the window; the skill appears as `/minima` in Copilot Chat and auto-loads for Minima
tasks.

*Prefer a single file?* Rename `minima-skill-1.1.0.md` to `.github/copilot-instructions.md`
in your repo (repo-wide), or trim it to the parts you need.

## Cursor

1. In your project, create the folder `.cursor/rules/` if it doesn't exist.
2. Save `minima-skill-1.1.0.md` there as `minima.mdc`.
3. Add these three lines to the **very top** of that file, then save:

   ```
   ---
   description: Minima blockchain — KISS VM contracts, MiniDapps, transactions, node ops
   alwaysApply: false
   ---
   ```

   Cursor now pulls it in automatically when your work is about Minima. (Set
   `alwaysApply: true` if you want it loaded in every chat.)

## Windsurf

1. Create the folder `.windsurf/rules/` in your project.
2. Save `minima-skill-1.1.0.md` there as `minima.md`.

Cascade reads it automatically. (Older Windsurf: save it as `.windsurfrules` in the project
root instead.)

## ChatGPT, Gemini, or any other chatbot

Two easy options — either works:

- **Attach it:** start a chat (or a Project / Gem / Custom GPT) and upload
  `minima-skill-1.1.0.md` (or the `.zip`) as a file, then ask your Minima question.
- **Paste it:** open `minima-skill-1.1.0.md`, copy everything, and paste it in as the first
  message (or into the "custom instructions" / "system prompt" box). Then ask away.

For a **Custom GPT** or **Gemini Gem**, put the file in its Knowledge and it stays available
in every conversation.

## OpenCode / Cline / Continue and other coding agents

- **OpenCode** and other Agent-Skills-aware tools: drop the `minima` folder into their skills
  directory (often `.agents/skills/` or `~/.agents/skills/`), the same way as VS Code above.
- **Cline:** save `minima-skill-1.1.0.md` as `.clinerules` in your project root.
- **Anything else:** if the tool has a "rules", "instructions", "system prompt", or "knowledge"
  place, put the single `.md` file there.

---

## How do I know it worked?

Ask your AI a question only someone who read this skill could answer, e.g.:

> "In Minima, why can `txnpost` return `status:true` and the coin still never move?"

A correct answer mentions that `status:true` means *accepted to the mempool only*, not
mined/valid — a covenant can silently Script-FAIL. If you get that, the skill is live.

---

*Minima skill v1.1.0 · MIT-licensed · built from the official Minima docs and original
on-chain research. Learn more at [docs.minima.global](https://docs.minima.global).*
