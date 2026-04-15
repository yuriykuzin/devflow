---
description: Plan a feature with cross-tool review loop (Claude + Codex). Delegates to superpowers for internal planning, adds external AI review.
---

# Devflow: Plan

Cross-tool planning workflow. Uses superpowers internally, calls an external AI tool (configured via `backend` key) for review.

Each phase is independent — you can run them all or invoke a single phase.

## Prerequisites
- Superpowers skills available (brainstorming, writing-plans)
- External reviewer CLI installed (`codex` or `claude`)
- Config: `~/.devflow/config.yaml` or `.devflow.yaml` (optional)

---

## Phase 1 — Read Config

// turbo
```bash
echo "=== Global config ===" && cat ~/.devflow/config.yaml 2>/dev/null || echo "(none)"
echo "=== Project config ===" && cat .devflow.yaml 2>/dev/null || echo "(none)"
```

**Resolve the active backend** from the `backend` key (default: `claude`), then read
from the matching section (`claude.*` or `codex.*`):
- `<backend>.reviewer.command` | `<backend>.reviewer.flags`
- `<backend>.reviewer.model` | `<backend>.reviewer.effort`
- `<backend>.implementer.model` | `<backend>.implementer.effort`
- `<backend>.session_reuse`

---

## Phase 2 — Internal Planning (superpowers)

1. Invoke the **brainstorming** skill — explore the idea, clarify requirements, propose approaches, get user approval, write spec.
2. Invoke the **writing-plans** skill — create detailed implementation plan with bite-sized tasks.

These handle the full internal workflow including spec review loops.

After completion, note the plan file path (typically `docs/superpowers/plans/YYYY-MM-DD-<feature>.md`).

---

## Phase 3 — External Cross-Tool Review

Common variables:
```bash
PLAN_FILE="<path-to-plan>"
SESSION_FILE="/tmp/devflow-plan-review.session"
OUTPUT_FILE="/tmp/devflow-plan-review-output.txt"

REVIEW_PROMPT="You are reviewing an implementation plan. READ-ONLY review, do NOT modify files.

Review for:
1. COMPLETENESS — all edge cases covered? Missing steps?
2. CORRECTNESS — architecture sound? Technical mistakes?
3. CONSISTENCY — steps reference each other correctly?
4. TESTABILITY — test steps adequate?
5. CODEBASE FIT — follows project patterns?

Respond: APPROVED or ISSUES (severity: critical/important/minor + fix).

Plan:
$(cat $PLAN_FILE)"
```

### Backend: claude

**First iteration:**
```bash
claude -p --output-format json --permission-mode plan \
  --model <reviewer.model> --effort <reviewer.effort> \
  "$REVIEW_PROMPT" | tee "$OUTPUT_FILE"
jq -r '.session_id' "$OUTPUT_FILE" > "$SESSION_FILE"
```

**Subsequent iterations — resume session:**
```bash
SESSION_ID=$(cat "$SESSION_FILE")
claude -p --output-format json --permission-mode plan \
  --model <reviewer.model> --effort <reviewer.effort> \
  --resume "$SESSION_ID" \
  "Issues were addressed. Re-review this updated plan.
Respond: APPROVED or ISSUES.
Updated plan:
$(cat $PLAN_FILE)"
```

### Backend: codex

> **WARNING**: Codex CLI has NO `--effort` flag. Use `-c 'model_reasoning_effort="..."'`.
> **CRITICAL**: All `-c` flags MUST go BEFORE the `exec` subcommand. Placing
> them after `exec` creates a fresh config context that shadows top-level
> `-c` flags (e.g., from `codex-local-proxy`), causing codex to fall back to
> its default provider.

**First iteration:**
```bash
EVENTS_FILE="/tmp/devflow-plan-review-events.jsonl"
codex -c 'model_reasoning_effort="<reviewer.effort>"' \
  exec --full-auto --json -m <reviewer.model> \
  -o "$OUTPUT_FILE" \
  "$REVIEW_PROMPT" 2>/dev/null | tee "$EVENTS_FILE"
head -1 "$EVENTS_FILE" | python3 -c "import sys,json; print(json.loads(sys.stdin.read())['thread_id'])" > "$SESSION_FILE"
```

**Subsequent iterations — resume session:**
```bash
SESSION_ID=$(cat "$SESSION_FILE")
codex exec resume "$SESSION_ID" --full-auto \
  -o "$OUTPUT_FILE" \
  "Issues were addressed. Re-review this updated plan.
Respond: APPROVED or ISSUES.
Updated plan:
$(cat $PLAN_FILE)"
```

Resuming saves ~20k tokens per iteration (preserves full context).

---

## Phase 4 — Process Review & Iterate

- **APPROVED** → proceed to Phase 5
- **ISSUES found** → fix issues in the plan, re-run Phase 3 (resume session). Max 5 iterations.
- **Max iterations reached** → present remaining issues to user for decision.

---

## Phase 5 — Finalize

```bash
mkdir -p docs/devflow/reports
```

Save review report to `docs/devflow/reports/YYYY-MM-DD-<feature>-plan-review.md`.

Session file `/tmp/devflow-plan-review.session` is preserved for `/devflow-implement` to resume.

Announce:
> "Plan complete and cross-reviewed. Ready to implement? Use `/devflow-implement` to continue."

---

## Partial execution examples

- *"Run `/devflow-plan` for adding caching to /skills endpoint"* → all phases
- *"Run `/devflow-plan`, skip to Phase 3, plan is at docs/superpowers/plans/caching.md"* → external review only
