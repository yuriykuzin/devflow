# Devflow — Cross-Tool AI Workflow Orchestrator

Automates the planning → implementation → review pipeline across multiple AI coding tools (Claude Code, Codex CLI, Windsurf, Gemini CLI, Cursor).

## How It Works

Devflow adds a **cross-tool orchestration layer** on top of [Superpowers](https://github.com/obra/superpowers). It delegates internal process to superpowers skills (brainstorming, writing-plans, TDD, code review) and adds **external review loops** by calling other AI tools via their CLI.

```
You (in Claude Code):  "devflow:run — add caching for /skills endpoint"
  │
  ├─ Phase 1: PLAN (current tool + superpowers:brainstorming + superpowers:writing-plans)
  │    └─ External review: codex exec --full-auto "Review this plan..." → iterate until OK
  │
  ├─ Phase 2: IMPLEMENT (external tool or current tool + superpowers:subagent-driven-development)
  │    └─ External review: codex exec --full-auto "Review this code..." → iterate until OK
  │
  └─ Phase 3: REVIEW (cross-tool verification)
       └─ Both current tool and external tool review final result
       └─ Report saved to docs/devflow/reports/
```

## Requirements

- At least one external CLI tool: `codex` (recommended) or `claude`
- Bash access (all agentic environments provide this)
- **Optional**: [Superpowers](https://github.com/obra/superpowers) plugin for internal workflow skills (brainstorming, TDD, etc.). Devflow works without it but is more powerful with it.

## Installation

Follows the superpowers pattern: **clone → symlink → done**.

### Quick install

```bash
git clone https://github.com/yuriykuzin/devflow.git ~/.codex/devflow
~/.codex/devflow/install.sh
```

You can clone to **any directory** — the install script creates symlinks pointing to wherever it lives. `~/.codex/devflow` is the recommended convention.

Run `install.sh --status` to check, `install.sh --choose` to select tools, or `install.sh --uninstall` to remove.

### Manual install (per platform)

**Codex CLI** — one directory symlink (Codex scans recursively):
```bash
mkdir -p ~/.agents/skills
ln -s /path/to/devflow/skills ~/.agents/skills/devflow
```

**Claude Code** — registered automatically by `install.sh` (creates local marketplace + copies to plugin cache). Restart Claude Code after install. If skills don't appear, start with:
```bash
claude --plugin-dir /path/to/devflow
```

**Cursor** — reads plugin manifest from the repo directly (no setup needed).

**Windsurf** — symlink workflow files:
```bash
mkdir -p ~/.codeium/windsurf/windsurf/workflows
for f in /path/to/devflow/windsurf/devflow-*.md; do
  ln -sf "$f" ~/.codeium/windsurf/windsurf/workflows/
done
```

**Gemini CLI** — reads `GEMINI.md` and `gemini-extension.json` from the repo directly.

**Config** (optional):
```bash
mkdir -p ~/.devflow
cp /path/to/devflow/config.default.yaml ~/.devflow/config.yaml
```

## Updating

```bash
cd /path/to/devflow && git pull
```

All consumers use symlinks — changes propagate instantly. No re-install needed.

## Uninstalling

```bash
/path/to/devflow/install.sh --uninstall
```

Or manually:
```bash
rm ~/.agents/skills/devflow                                          # Codex
rm ~/.codeium/windsurf/windsurf/workflows/devflow-*.md 2>/dev/null   # Windsurf
rm -rf ~/.devflow                                                     # Config (optional)
```

## Multi-Agent Coexistence

Devflow works seamlessly across multiple agentic apps on the same machine:

- **Single source of truth**: the git repo — clone it anywhere, symlinks point back
- **Shared config**: `~/.devflow/config.yaml` is read by all agents
- **Symlinks everywhere**: Codex (`~/.agents/skills/devflow`) and Windsurf (`workflows/devflow-*.md`) both point back to the repo
- **Direct reads**: Claude Code, Cursor, and Gemini read from the repo directory
- **Session files**: stored in `/tmp/devflow-*.session` — any agent can resume another's Codex session
- **Per-project overrides**: `.devflow.yaml` in project root overrides global config

## Configuration

Global config: `~/.devflow/config.yaml`
Project override: `.devflow.yaml` in project root

```yaml
reviewer:
  tool: codex            # codex | claude | custom
  command: "codex exec"  # CLI command + subcommand
  flags: "--full-auto"   # non-interactive flags
  model: "gpt-5.4"       # model for reviews
  effort: "xhigh"        # reasoning effort (xhigh = thorough reviews)

implementer:
  tool: codex
  command: "codex exec"
  flags: "--full-auto"
  model: "gpt-5.4"       # model for implementation
  effort: "high"         # reasoning effort (high = fast implementation)

session_reuse: true      # saves ~20k tokens per resumed call
autonomy: attended       # attended | unattended
output_dir: "docs/devflow/reports"
```

### Model Tiers

| Role | Default Model | Default Effort | Purpose |
|------|--------------|----------------|----------|
| Reviewer | gpt-5.4 | xhigh | Thorough plan and code reviews |
| Implementer | gpt-5.4 | high | Fast, capable code generation |
| Orchestrator | (host model) | (host effort) | The agent running devflow (e.g., opus-4.6) |

### Session Reuse

When `session_reuse: true`, devflow captures the Codex session ID on the first call (`--json` → `thread_id`) and resumes subsequent iterations in the same session (`codex exec resume <id>`). This:
- Saves ~20k tokens per resumed call (Codex skips re-reading skills/AGENTS.md)
- Preserves review context across iterations
- Enables session handoff between phases (plan review → implementation review)

## Skills

| Skill | Description | When to use |
|-------|-------------|-------------|
| `devflow:plan` | Planning with cross-tool review loop | "Plan this feature" |
| `devflow:implement` | Implementation with cross-tool review | "Implement this plan" |
| `devflow:review` | Cross-tool review of existing code | "Review my changes" |
| `devflow:run` | Full pipeline (plan → implement → review) | "Build this feature end-to-end" |

## Windsurf Workflows

| Workflow | Equivalent skill |
|----------|-----------------|
| `/devflow-plan` | `devflow:plan` |
| `/devflow-implement` | `devflow:implement` |
| `/devflow-review` | `devflow:review` |
| `/devflow-run` | `devflow:run` |

## Relationship with Superpowers

Devflow and superpowers are **complementary, not competing**:

| Level | What | Who |
|-------|------|-----|
| Cross-tool orchestration | Which tool does which step, external review loops, session management | **devflow** |
| Single-tool process | How to brainstorm, plan, write tests, review code within one agent | **superpowers** |

### Priority rules

- **User says "devflow"** or mentions cross-tool review → devflow orchestrates, superpowers used internally
- **User says "plan this feature"** without mentioning cross-tool → superpowers only
- **Never invoke both** devflow:plan AND superpowers:writing-plans for the same task — devflow already delegates to superpowers

### Without superpowers

Devflow works standalone — cross-tool orchestration, session reuse, and external reviews are fully independent. Internal process quality is lower (no brainstorming skill, no TDD enforcement), but devflow's core value is unaffected.

If superpowers updates (new skills, improved TDD), devflow automatically benefits because it delegates rather than reimplements.

## File Structure

```
devflow/
├── install.sh                      # Installer with --status / --uninstall
├── config.default.yaml             # Default config template
├── README.md                       # This file
├── GEMINI.md                       # Gemini CLI instructions
├── gemini-extension.json           # Gemini extension manifest
├── .claude-plugin/plugin.json      # Claude Code plugin manifest
├── .cursor-plugin/plugin.json      # Cursor plugin manifest
├── .codex/INSTALL.md               # Agent-readable install instructions
├── skills/                         # Skill definitions (shared by all agents)
│   ├── using-devflow/SKILL.md      # Entry point — skill discovery
│   ├── using-devflow/references/   # Platform-specific tool mappings
│   ├── devflow-plan/SKILL.md       # Plan with cross-tool review
│   ├── devflow-implement/SKILL.md  # Implement with cross-tool review
│   ├── devflow-review/SKILL.md     # Standalone cross-tool review
│   └── devflow-run/SKILL.md        # Full pipeline orchestrator
└── windsurf/                       # Windsurf workflow adapters
    ├── devflow-plan.md
    ├── devflow-implement.md
    ├── devflow-review.md
    └── devflow-run.md
```

After installation:
```
/path/to/devflow/                              # Git repo = single source of truth
~/.devflow/config.yaml                         # Global configuration
~/.agents/skills/devflow                       # Codex: symlink → skills/
~/.codeium/.../devflow-*.md                    # Windsurf: symlinks → windsurf/
~/.claude/plugins/cache/devflow-local/...       # Claude Code: plugin cache
```

## License

MIT
