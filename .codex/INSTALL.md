# Installing Devflow

Cross-tool workflow orchestrator. Adds cross-tool review loops on top of your existing agent skills.

## Prerequisites

- Git
- At least one external CLI tool: `codex` (recommended) or `claude`
- **Recommended**: [Superpowers](https://github.com/obra/superpowers) installed — devflow delegates internal process (brainstorming, TDD, code review) to superpowers skills when available. Works without it, but less powerful.

## Installation

### 1. Clone the repository

```bash
git clone https://github.com/yuriykuzin/devflow.git ~/.codex/devflow
```

You can clone to any directory — `~/.codex/devflow` is the recommended convention.

### 2. Platform setup

**Codex CLI** — one directory symlink:
```bash
mkdir -p ~/.agents/skills
ln -s ~/.codex/devflow/skills ~/.agents/skills/devflow
```

**Claude Code** — run `install.sh` (registers a local marketplace and copies plugin to cache). Restart Claude Code after install. Fallback: `claude --plugin-dir /path/to/devflow`.

**Cursor** — no setup needed. Cursor reads `.cursor-plugin/plugin.json` from the repo.

**Gemini CLI** — reads `GEMINI.md` and `gemini-extension.json` from the repo directly.

### 3. Create config (optional)

```bash
mkdir -p ~/.devflow
cp ~/.codex/devflow/config.default.yaml ~/.devflow/config.yaml
```

Or run the convenience script which does all of the above:
```bash
~/.codex/devflow/install.sh
```

## Verify

```bash
ls ~/.agents/skills/devflow/          # Should list: devflow-plan/ devflow-implement/ etc.
ls ~/.devflow/config.yaml             # Config exists
```

## Updating

```bash
cd ~/.codex/devflow && git pull
```

Codex, Cursor, and Gemini use symlinks/direct reads — changes propagate instantly.
Claude Code uses a cached copy — re-run `install.sh` after `git pull` to update the cache.

## Uninstalling

```bash
rm ~/.agents/skills/devflow                                          # Codex
rm -rf ~/.devflow                                                     # Config (optional)
```

Or: `~/.codex/devflow/install.sh --uninstall`
