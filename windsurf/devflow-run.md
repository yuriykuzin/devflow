---
description: Full development pipeline — plan, implement, and review a feature with cross-tool AI orchestration. One command to go from idea to reviewed code.
---

# Devflow: Run (Full Pipeline)

Orchestrates the complete development workflow across multiple AI tools:
**Plan → Implement → Review**, each with cross-tool quality gates.

## Prerequisites
- Superpowers skills available
- External reviewer CLI installed (`codex` or `claude`)
- Config: `~/.devflow/config.yaml` or `.devflow.yaml` (optional)

---

## Phase 0 — Parse Request & Config

1. **Determine scope** from user's request:
   - Full pipeline (default): "build this", "devflow:run"
   - Plan only: "just plan this"
   - Implement only: "implement this plan" (needs plan file)
   - Review only: "review my changes"

2. **Determine autonomy**:
   - `attended` (default): ask user on ambiguity
   - `unattended`: "don't ask me", "--unattended" → no questions

// turbo
3. Read config:
```bash
echo "=== Config ===" && cat ~/.devflow/config.yaml 2>/dev/null || echo "(defaults)"
cat .devflow.yaml 2>/dev/null || echo "(no project override)"
```

4. **Resolve the active backend** from the `backend` key (default: `claude`), then read
   from the matching section (`claude.*` or `codex.*`):
   - **Reviewer**: `<backend>.reviewer.model` + `<backend>.reviewer.effort`
   - **Implementer**: `<backend>.implementer.model` + `<backend>.implementer.effort`
   - **Orchestrator** (you): uses its own model (e.g., `opus-4.6` in Windsurf)
   - **Session reuse**: `<backend>.session_reuse` (default: `true`)

5. Create a todo list to track phases.

---

## Phase 1 — PLAN

Run `/devflow-plan` workflow (or invoke `devflow:plan` skill).

**Input**: Feature description from user.
**Output**: Approved plan file + session file at `/tmp/devflow-plan-review.session`.

In attended mode, pause after planning:
> "Phase 1 complete. Plan at `<path>`. Proceed to implementation?"

In unattended mode, continue automatically.

---

## Phase 2 — IMPLEMENT

Run `/devflow-implement` workflow (or invoke `devflow:implement` skill).

**Input**: Plan file from Phase 1.
**Session continuity**: `/devflow-implement` auto-resumes the plan-review session — reviewer already knows the plan.
**Output**: Code changes + review report.

In attended mode, pause after implementation:
> "Phase 2 complete. N files changed. Proceed to final review?"

---

## Phase 3 — FINAL REVIEW

Run `/devflow-review` workflow if available, or do inline:

1. Internal review (superpowers requesting-code-review)
2. External review via CLI
3. Synthesize findings

If critical issues found:
- **attended**: present to user
- **unattended**: attempt fix + re-review (max 2 iterations)

---

## Phase 4 — Final Report

Generate and save comprehensive report:

```markdown
# Devflow Report: <feature>
**Date**: YYYY-MM-DD | **Autonomy**: attended/unattended

## Phase 1: Planning — ✅
- Plan: `<path>` | Review iterations: N

## Phase 2: Implementation — ✅
- Files changed: N | Review iterations: N

## Phase 3: Final Review — ✅ / ⚠️
- Critical: 0 | Important: N (resolved)

## Next Steps
- `git diff --stat` to review changes
- `<test command>` to run tests
- Commit when satisfied
```

```bash
mkdir -p docs/devflow/reports
```

Save to `docs/devflow/reports/YYYY-MM-DD-<feature>-report.md`.

---

## Partial execution examples

- *"/devflow-run — add caching for /skills"* → full pipeline
- *"/devflow-run, plan only — add caching"* → Phase 1 only
- *"/devflow-run, implement docs/plans/caching.md"* → Phase 2 + 3
- *"/devflow-run --unattended — add caching"* → full, no questions
- *"/devflow-run, review only"* → Phase 3 only

---

## Error Recovery

| Error | Action |
|-------|--------|
| External CLI not found | Suggest install, offer config change |
| Phase fails after max retries | Save progress, escalate to user |
| User cancels mid-pipeline | Save all artifacts so far, report status |
