---
description: Plan a feature with cross-tool review loop (Claude + Codex). Delegates to superpowers for internal planning, adds external AI review.
---

# Devflow: Plan

Cross-tool planning workflow. Uses superpowers internally, calls an external AI tool (Codex CLI by default) for review.

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

Extract from config (defaults shown):
- `reviewer.command`: `codex exec` | `reviewer.flags`: `--full-auto`
- `reviewer.model`: `gpt-5.4` | `reviewer.effort`: `xhigh`
- `implementer.model`: `gpt-5.4` | `implementer.effort`: `high`
- `session_reuse`: `true`

---

## Phase 2 — Internal Planning (superpowers)

1. Invoke the **brainstorming** skill — explore the idea, clarify requirements, propose approaches, get user approval, write spec.
2. Invoke the **writing-plans** skill — create detailed implementation plan with bite-sized tasks.

These handle the full internal workflow including spec review loops.

After completion, note the plan file path (typically `docs/superpowers/plans/YYYY-MM-DD-<feature>.md`).

---

## Phase 3 — External Cross-Tool Review

**First iteration — start session and capture ID:**

```bash
PLAN_FILE="<path-to-plan>"
SESSION_FILE="/tmp/devflow-plan-review.session"
OUTPUT_FILE="/tmp/devflow-plan-review-output.txt"
EVENTS_FILE="/tmp/devflow-plan-review-events.jsonl"

# Model flags from config
MODEL_FLAGS='-m <reviewer.model> -c '\''model_reasoning_effort="<reviewer.effort>"'\'''

codex exec --full-auto --json $MODEL_FLAGS \
  -o "$OUTPUT_FILE" \
  "You are reviewing an implementation plan. READ-ONLY review, do NOT modify files.

Review for:
1. COMPLETENESS — all edge cases covered? Missing steps?
2. CORRECTNESS — architecture sound? Technical mistakes?
3. CONSISTENCY — steps reference each other correctly?
4. TESTABILITY — test steps adequate?
5. CODEBASE FIT — follows project patterns?

Respond: APPROVED or ISSUES (severity: critical/important/minor + fix).

Plan:
$(cat $PLAN_FILE)" 2>/dev/null | tee "$EVENTS_FILE"

# Capture session ID
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

Resuming saves ~20k tokens per iteration (Codex keeps full context).

---

## Phase 4 — Process Review & Iterate

- **APPROVED** → proceed to Phase 5
- **ISSUES found** → fix issues in the plan, re-run Phase 3 (resume session). Max 5 iterations.
- **Max iterations reached** → present remaining issues to user for decision.

---

## Phase 5 — Finalize

Save review report to `docs/devflow/reports/YYYY-MM-DD-<feature>-plan-review.md`.

Session file `/tmp/devflow-plan-review.session` is preserved for `/devflow-implement` to resume.

Announce:
> "Plan complete and cross-reviewed. Ready to implement? Use `/devflow-implement` to continue."

---

## Partial execution examples

- *"Run `/devflow-plan` for adding caching to /skills endpoint"* → all phases
- *"Run `/devflow-plan`, skip to Phase 3, plan is at docs/superpowers/plans/caching.md"* → external review only
