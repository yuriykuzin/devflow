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

If no config exists, defaults are used (Codex CLI for external calls).

## How Cross-Tool Calls Work

Devflow calls external tools via their CLI in non-interactive mode:

```bash
# Codex (default) — first call captures session ID via --json
codex exec --full-auto --json -m gpt-5.4 -c 'model_reasoning_effort="xhigh"' \
  -o /tmp/review-output.txt "Review this plan: ..." 2>/dev/null | tee /tmp/events.jsonl

# Codex — resume session for subsequent iterations (saves ~20k tokens)
codex exec resume "$SESSION_ID" --full-auto -o /tmp/review-output.txt "Re-review: ..."

# Claude Code
claude -p "Review this plan: ..."
```

The orchestrating agent (you) runs Bash to invoke the external tool, captures its output, and uses it to iterate.

## Model Tiers

Devflow uses different model tiers for different tasks:

| Role | Model | Effort | Purpose |
|------|-------|--------|----------|
| **Reviewer** | gpt-5.4 | xhigh | Thorough plan and code reviews |
| **Implementer** | gpt-5.4 | high | Fast, capable code generation |
| **Orchestrator** | (your model) | (your effort) | You — the host agent (e.g., opus-4.6) |

Configured in `~/.devflow/config.yaml` under `reviewer.model`/`reviewer.effort` and `implementer.model`/`implementer.effort`.

## Session Reuse

When `session_reuse: true` (default), devflow:
1. Captures the Codex session ID on the first external call (`--json` → `thread_id`)
2. Resumes the same session for subsequent iterations (`codex exec resume <id>`)
3. Passes sessions between phases (plan review → implementation review)

This saves ~20k tokens per resumed call (Codex doesn't re-read skills/AGENTS.md).

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
