# Devflow — Cross-Tool AI Workflow Orchestrator

[![test](https://github.com/yuriykuzin/devflow/actions/workflows/test.yml/badge.svg)](https://github.com/yuriykuzin/devflow/actions/workflows/test.yml)

Automates the planning → implementation → review pipeline across multiple AI coding tools (Claude Code, Codex CLI, opencode, Gemini CLI, Cursor).

## How It Works

Devflow adds a **cross-tool orchestration layer** on top of [Superpowers](https://github.com/obra/superpowers). It delegates internal process to superpowers skills (brainstorming, writing-plans, TDD, code review) and adds **external review loops** by calling other AI tools via their CLI.

```
You (in Claude Code):  "devflow:run — add caching for /skills endpoint"
  │
  ├─ Phase 1: PLAN (current tool + superpowers:brainstorming + superpowers:writing-plans)
  │    └─ External review (read-only): "Review this plan..." → iterate until OK
  │
  ├─ Phase 2: IMPLEMENT (external tool or current tool + superpowers:subagent-driven-development)
  │    └─ External review (read-only): "Review this code..." → iterate until OK
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

**opencode** — one symlink **per skill**, because opencode discovers
`~/.config/opencode/skills/<name>/SKILL.md` and a single link to the whole `skills/` tree
would bury every skill one level too deep:
```bash
mkdir -p ~/.config/opencode/skills
for d in /path/to/devflow/skills/*/; do ln -s "${d%/}" ~/.config/opencode/skills/"$(basename "$d")"; done
```

**Cursor** — reads plugin manifest from the repo directly (no setup needed).

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

Codex, opencode, Cursor, and Gemini use symlinks or direct reads — changes propagate instantly.
Claude Code uses a cached copy — re-run `install.sh` after pulling to update the cache.

## Uninstalling

```bash
/path/to/devflow/install.sh --uninstall
```

Or manually:
```bash
rm ~/.agents/skills/devflow                                          # Codex
rm -rf ~/.devflow                                                     # Config (optional)
```

## Multi-Agent Coexistence

Devflow works seamlessly across multiple agentic apps on the same machine:

- **Single source of truth**: the git repo — clone it anywhere, symlinks point back
- **Shared config**: `~/.devflow/config.yaml` is read by all agents
- **Symlinks**: Codex (`~/.agents/skills/devflow`) points back to the repo
- **Direct reads**: Cursor and Gemini read from the repo directory; Claude Code uses a plugin-cache copy (re-run `install.sh` after `git pull`)
- **Session files**: stored under `RUN_DIR`, a deterministic path derived from a hash of
  the repo root under `${DEVFLOW_RUN_HOME:-$HOME/.devflow/run}` (namespaced per project, never
  inside the repo, and never under a write-mode call's default writable roots) —
  `bash scripts/devflow-runner.sh dir` always resolves back to the same directory
  for a given checkout; run it to recover the path rather than guessing. Abandoned run dirs
  are auto-reclaimed after `DEVFLOW_RUN_TTL_DAYS` (default 7) days of inactivity. Only dirs
  that are ours (uid match) and past the TTL are pruned, and the age is measured from last use,
  so a steadily-reused checkout is never swept. Concurrency is a convention, not an enforced
  guarantee: one devflow pipeline per checkout at a time, parallel work in git worktrees
- **Per-project overrides**: `.devflow.yaml` in project root overrides global config

## Configuration

Global config: `~/.devflow/config.yaml`
Project override: `.devflow.yaml` in project root

### Which tool reviews

The point of an external review is a **different** tool's eyes, so the reviewing backend is
picked by which tool is hosting the run — not by one global switch:

```yaml
external_review:
  from_claude: codex     # hosted by Claude Code → external review via codex
  from_codex: none       # hosted by Codex → internal personas only
```

`none` means the host runs its internal persona reviewers and the orchestrator decides from
those alone. `backend:` remains the fallback for a host not listed, and still selects the
implementer backend for handoff calls:

```yaml
backend: claude   # or: codex
```

You can also override per-project by creating `.devflow.yaml` in the project root with just:
```yaml
backend: codex   # this project uses Codex regardless of global setting
```

### Full Config Reference

```yaml
backend: claude           # codex | claude — change this one line to switch

claude:
  reviewer:
    model: "opus"          # alias for claude-opus-4-6
    effort: "max"          # --effort max (thorough reviews)
  implementer:
    model: "sonnet"        # alias for claude-sonnet-4-6
    effort: "high"         # --effort high (fast implementation)
  session_reuse: true

codex:
  command_path: ""         # "" = auto-resolve & validate (exec --json), prefer Homebrew,
                           # skip NVM-shadowed old CLI; set absolute path to force
  reviewer:
    model: "gpt-5.5"
    effort: "high"         # via -c 'model_reasoning_effort="..."'
  implementer:
    model: "gpt-5.5"
    effort: "high"
  session_reuse: true

autonomy: attended         # attended | unattended
output_dir: "docs/devflow/reports"
```

> The only keys that change behavior are `backend`, `model`, `effort`, `command_path`, `session_reuse`, `autonomy`, `output_dir`, `review_personas`, and `integrations`. The CLI invocation (flags, read-only vs write posture, session capture) is built by the runner — see `skills/using-devflow/references/cross-tool-runner.md`.

**Environment overrides** (not config-file keys): `DEVFLOW_RUN_TTL_DAYS` (default `7`) sets how many idle days before an abandoned per-project run dir under `${DEVFLOW_RUN_HOME:-$HOME/.devflow/run}` is auto-reclaimed on the next `dir` call; set it to a non-number to disable the sweep entirely.

### Model Tiers

| Role | claude backend | codex backend | Purpose |
|------|---------------|---------------|----------|
| Reviewer | opus / max | gpt-5.5 / high | Thorough plan and code reviews |
| Implementer | sonnet / high | gpt-5.5 / high | Fast, capable code generation |
| Orchestrator | (host model) | (host model) | The agent running devflow (e.g., opus-4.6) |

### Session Reuse

When `<backend>.session_reuse: true`, devflow captures the session ID on the first call and resumes subsequent iterations in the same session. This:
- Saves ~20k tokens per resumed call
- Preserves review context across iterations
- Enables session handoff between phases (plan review → implementation review)

Session capture is done by the runner via `scripts/devflow-json.py` (a stdlib-only,
fail-closed JSON extractor — no `jq` dependency), and differs by backend:
- **claude**: `session_id` from the `--output-format json` object, resume with `--resume <id>`
- **codex**: `thread_id` from the `--json` JSONL, resume with `exec resume <id>` using the
  same full flag shape as a fresh call (`-c model_reasoning_effort` before `exec`,
  `--json`, `-m`)

### External Calls Are Non-Blocking

External reviews are launched in the background and polled via their event stream
(adaptive backoff, ~8–10 min hard-cap), so they never die at a host's command timeout.
The codex binary is auto-resolved and validated (`exec --json` support; Homebrew
preferred; NVM-shadowed CLIs skipped) — override with `codex.command_path`. The skill reads
`.devflow.yaml` and passes `backend`/`model`/`effort` as explicit flags on each call; the
runner resolves the trusted binary itself (never from a flag). The
canonical procedure lives in `skills/using-devflow/references/cross-tool-runner.md`.

## Skills

| Skill | Description | When to use |
|-------|-------------|-------------|
| `devflow:plan` | Planning with cross-tool review loop | "Plan this feature" |
| `devflow:implement` | Implementation with cross-tool review | "Implement this plan" |
| `devflow:review` | Cross-tool review of existing code | "Review my changes" |
| `devflow:run` | Full pipeline (plan → implement → review) | "Build this feature end-to-end" |

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
│   ├── using-devflow/references/   # Platform tool mappings + cross-tool-runner.md (canonical external-call procedure)
│   ├── devflow-plan/SKILL.md       # Plan with cross-tool review
│   ├── devflow-implement/SKILL.md  # Implement with cross-tool review
│   ├── devflow-review/SKILL.md     # Standalone cross-tool review
│   ├── devflow-review/references/  # review-personas.md (persona lenses + tiers)
│   └── devflow-run/SKILL.md        # Full pipeline orchestrator
├── scripts/                        # The one load-bearing sh + its helpers
│   ├── devflow-runner.sh           # Supervises the long backend CLI: dir + run-external
│   └── devflow-json.py             # stdlib-only JSON extractor (verdict/session), fail-closed
└── test/                           # Offline, deterministic harness (see test/README.md)
    ├── run.sh                      # Test runner
    ├── smoke-real-codex.sh         # opt-in real-CLI smoke test (needs token, not in CI)
    ├── cases/                      # One file per case (10-dir, 30-invoke, …)
    └── lib/                        # Fakes (fake-codex, fake-claude) + assert/sandbox helpers
```

After installation:
```
/path/to/devflow/                              # Git repo = single source of truth
~/.devflow/config.yaml                         # Global configuration
~/.agents/skills/devflow                       # Codex: symlink → skills/
~/.claude/plugins/cache/devflow-local/...       # Claude Code: plugin cache
```

## Development

Run the offline test harness — no API token, no network. It drives the real `scripts/devflow-runner.sh` against fake codex/claude stubs in throwaway sandboxes:

```bash
bash test/run.sh            # all cases
bash test/run.sh 30 60      # only cases matching these prefixes
```

CI runs the same suite on Linux and macOS on every push and PR. See [`test/README.md`](test/README.md) for how the harness stays honest and the seams it exposes.

## License

MIT
