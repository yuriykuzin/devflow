---
name: using-devflow
description: "Entry point for devflow — cross-tool workflow orchestrator. Use when the user asks to plan, implement, or review a feature using multiple AI tools (e.g. Claude + Codex)."
---

# Using Devflow

Devflow orchestrates development workflows **across multiple AI coding tools**. It layers on top of superpowers, adding cross-tool review loops via CLI.

## When Devflow Applies

Devflow skills trigger when the user:
- Asks to "plan and implement" a feature end-to-end
- Mentions using multiple tools (Claude + Codex, cross-tool review)
- Says "devflow", "devflow:plan", "devflow:run", etc.
- Wants external review of a plan or code by a different AI tool

If the user just wants internal planning/implementation (single tool), use superpowers skills directly.

## Available Skills

| Skill | When to use |
|-------|-------------|
| `devflow:plan` | Plan a feature with cross-tool review loop |
| `devflow:implement` | Implement a plan with cross-tool review loop |
| `devflow:review` | Cross-tool review of existing code/changes |
| `devflow:run` | Full pipeline: plan → implement → review |

## Configuration

Devflow merges config from three layers, first setter wins:
1. **Project**: `.devflow.yaml` in project root
2. **Global**: `~/.devflow/config.yaml`
3. **Defaults**: plugin `config.default.yaml`

If nothing overrides, the shipped defaults apply. The exec-path key `command_path` is honoured
only from the global and default layers — never a project `.devflow.yaml`. See cross-tool-runner.md's "Config" section for the canonical merge.

## Backend Switching

Devflow supports multiple CLI backends. Each has its own section with reviewer/implementer
settings; see `config.default.yaml` for the full template.

```yaml
backend: claude    # or: codex
```

### Which backend reviews — resolved by host (canonical)

`backend:` is a fallback, not the answer. The point of an external review is a **different**
tool's eyes, so the reviewing backend is chosen by which tool is hosting the run:

```yaml
external_review:
  from_claude: codex     # hosted by Claude Code → external review via codex
  from_codex: none       # hosted by Codex → internal personas only
```

Resolution, in order: `external_review.from_<host>` → `backend:` → shipped default. The host
is the tool you are running inside — you know it without asking. A host that maps to its own
backend is a configuration error, not a review: say so and stop rather than asking one tool
to independently confirm itself.

With `none`, the orchestrator decides from the internal personas' findings alone. Record in the
report which resolution was used, so a reader can tell an internal-only review from one where
an external call was configured and skipped. The implementer backend for handoff calls still
comes from `backend:`; `none` only suppresses the external *review*.

## How Cross-Tool Calls Work

Devflow calls external tools via their CLI in non-interactive mode. The one thing that
genuinely can't live in markdown — supervising a long (8–10 min) backend CLI: detached
launch, backoff polling with a hard cap, process-group kill on timeout, and session
capture — lives in a real script, `scripts/devflow-runner.sh`,
which every devflow skill calls as a subprocess. Config resolution (read `.devflow.yaml`,
pass values as flags) and scope pinning (plain `git`) are done by the calling skill:

```bash
bash "$RUNNER" dir [--fresh]     # the deterministic per-project RUN_DIR (scratch + session store)
bash "$RUNNER" run-external --backend <b> --model <m> --effort <e> --phase <name> --prompt-file <path> [flags]
```

See [`references/cross-tool-runner.md`](references/cross-tool-runner.md) for the full
subcommand reference, the config→flags mapping, the scope-mode table, the locator snippet
for `$RUNNER`, and the async-launch guidance per host. Never hand-roll a one-off `codex
exec` / `claude -p` invocation — always go through `run-external`.

### Codex binary resolution

The codex binary is resolved by `run-external` on each call: a bare `codex` can hit an
NVM-shadowed old CLI lacking `--json`. Devflow picks the first candidate that passes
`exec --help | grep --json` (preferring Homebrew `/opt/homebrew/bin/codex`), fails
loudly if none qualify, and lets you force a path with `codex.command_path` in config.
That path is read only from the plugin default and `~/.devflow/config.yaml` — never a
project `.devflow.yaml`, and never a flag you pass (trust boundary; see cross-tool-runner.md).

## Model Tiers

Devflow uses different model tiers for different tasks. Defaults depend on backend:

| Role | claude backend | codex backend | Purpose |
|------|---------------|---------------|----------|
| **Reviewer** | opus / max | gpt-5.5 / high | Thorough plan and code reviews |
| **Implementer** | sonnet / high | gpt-5.5 / high | Fast, capable code generation |
| **Orchestrator** | (your model) | (your model) | You — the host agent |

Configured in `~/.devflow/config.yaml` under `<backend>.reviewer.*` and `<backend>.implementer.*`.

## Session Reuse

When `<backend>.session_reuse: true` (default), devflow:
1. Captures the session ID on the first external call (the runner extracts it with
   `scripts/devflow-json.py` — stdlib JSON, fail-closed, no `jq`)
   - **claude**: `session_id` from the `--output-format json` object
   - **codex**: `thread_id` from the `--json` JSONL first event
2. Resumes the same session for subsequent iterations
   - **claude**: `--resume <session_id>`
   - **codex**: `exec resume <session_id>` with the **same full flag shape** as a fresh
     call (`-c model_reasoning_effort` before `exec`, `--json`, `-m`, `< /dev/null`) —
     handled by `run-external --resume <id>`, see cross-tool-runner.md
3. Passes sessions between phases (plan review → implementation review) via `$RUN_DIR/<phase>.session` files

This saves ~20k tokens per resumed call.

## Relationship with Superpowers

Devflow and superpowers are **complementary, not competing**. They operate at different levels:

| Level | What | Who |
|-------|------|-----|
| **Cross-tool orchestration** | Which tool does which step, external review loops, session management | **devflow** |
| **Single-tool process** | How to brainstorm, plan, write tests, review code within one agent | **superpowers** |

### Priority rules (when both could apply)

- **User says "devflow"** or mentions cross-tool review → devflow orchestrates, superpowers is used internally
- **User says "plan this feature"** without mentioning cross-tool → superpowers only (brainstorming + writing-plans)
- **User says "devflow:plan"** → devflow skill; it calls superpowers:brainstorming + superpowers:writing-plans internally, then adds external review
- **Never invoke both devflow:plan AND superpowers:writing-plans independently** for the same task — devflow already calls superpowers

### Delegation mapping

When superpowers is available, devflow delegates internal process:
- Planning → `superpowers:brainstorming` + `superpowers:writing-plans`
- Implementation → `superpowers:subagent-driven-development` or `superpowers:executing-plans`
- Code review → `superpowers:requesting-code-review`
- TDD → `superpowers:test-driven-development`

### Graceful degradation (superpowers not installed)

Devflow works without superpowers — the cross-tool orchestration, session reuse, and external review loops are fully independent. When superpowers is absent:
- Planning: use your native planning approach (no brainstorming skill, but you can still plan)
- Implementation: implement directly (no subagent-driven-development, but code still gets written)
- Review: external review still works via CLI
- TDD: follow standard testing practices

The quality of internal process is lower without superpowers, but devflow's core value — cross-tool review — is unaffected.

## Platform Adaptation

Skills use Claude Code tool names. For other platforms:

| Skill references | Codex equivalent |
|-----------------|------------------|
| `Bash` | native shell |
| `Read` | native file tools |
| `Write` | native file tools |
| `Task` (subagent) | `spawn_agent` |
| `Skill` (invoke) | native skill load |
| `TodoWrite` | `update_plan` |

For Gemini CLI tool mappings, see `references/gemini-tools.md`; Cursor uses Claude Code-compatible tool names.
