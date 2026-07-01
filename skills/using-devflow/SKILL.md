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

Devflow reads config from two places (project overrides global):
1. **Global**: `~/.devflow/config.yaml`
2. **Project**: `.devflow.yaml` in project root

If no config exists, defaults are used (Claude Code CLI for external calls).

## Backend Switching

Devflow supports multiple CLI backends. Switch with one line in config:

```yaml
backend: claude    # or: codex
```

Each backend has its own section with reviewer/implementer settings.
See `config.default.yaml` for the full template.

## How Cross-Tool Calls Work

Devflow calls external tools via their CLI in non-interactive mode. The **canonical
procedure** — config caching, binary resolution, async launch, polling, session capture,
scope pinning, and rate-limit fallback — lives in
[`references/cross-tool-runner.md`](references/cross-tool-runner.md). All devflow skills
delegate the mechanics there; below is just the shape.

```bash
# codex — launched non-blocking (-c flags BEFORE exec; always < /dev/null), polled to completion
nohup "$CODEX_BIN" -c "model_reasoning_effort=\"$REVIEWER_EFFORT\"" \
  exec --full-auto --json -m "$REVIEWER_MODEL" -o "$OUT" \
  "$PROMPT" < /dev/null > "$EVENTS" 2> "$STDERR" &
# claude — claude -p --output-format json --permission-mode plan --model <m> --effort <e> "$PROMPT"
```

The orchestrating agent (you) launches the call in the background (Bash
`run_in_background: true` on Claude Code, `nohup &` elsewhere), polls the event stream,
and iterates. See the runner for the full async/poll/fallback logic — never hand-roll a
one-off invocation.

### Codex binary resolution

`$CODEX_BIN` is resolved once during bootstrap (cross-tool-runner.md Section A): a bare
`codex` can hit an NVM-shadowed old CLI lacking `--json`. Devflow picks the first
candidate that passes `exec --help | grep --json` (preferring Homebrew
`/opt/homebrew/bin/codex`), fails loudly if none qualify, and lets you force a path with
`codex.command_path` in config. Always invoked with `< /dev/null` to avoid TTY blocks.

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
1. Captures the session ID on the first external call
   - **claude**: `jq -r '.session_id'` from `--output-format json`
   - **codex**: `thread_id` from `--json` JSONL first event
2. Resumes the same session for subsequent iterations
   - **claude**: `--resume <session_id>`
   - **codex**: `exec resume <session_id>` with the **same full flag shape** as a fresh
     call (`-c model_reasoning_effort` before `exec`, `--json`, `-m`, `< /dev/null`) —
     see cross-tool-runner.md Section B
3. Passes sessions between phases (plan review → implementation review) via the shared `run.env`

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

| Skill references | Codex equivalent | Windsurf equivalent |
|-----------------|------------------|---------------------|
| `Bash` | native shell | `run_command` |
| `Read` | native file tools | `read_file` |
| `Write` | native file tools | `write_to_file` |
| `Task` (subagent) | `spawn_agent` | not available |
| `Skill` (invoke) | native skill load | `skill` tool |
| `TodoWrite` | `update_plan` | `todo_list` |
