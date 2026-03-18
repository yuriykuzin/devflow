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

**Claude Code** — no setup needed. Claude Code reads `.claude-plugin/plugin.json` from the repo.

**Cursor** — no setup needed. Cursor reads `.cursor-plugin/plugin.json` from the repo.

**Windsurf** — symlink workflow files:
```bash
mkdir -p ~/.codeium/windsurf/windsurf/workflows
for f in ~/.codex/devflow/windsurf/devflow-*.md; do
  ln -sf "$f" ~/.codeium/windsurf/windsurf/workflows/
done
```

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

All consumers use symlinks — changes propagate instantly. No re-install needed.

## Uninstalling

```bash
rm ~/.agents/skills/devflow                                          # Codex
rm ~/.codeium/windsurf/windsurf/workflows/devflow-*.md 2>/dev/null   # Windsurf
rm -rf ~/.devflow                                                     # Config (optional)
```

Or: `~/.codex/devflow/install.sh --uninstall`
