---
description: Implement a plan with cross-tool review loop. Delegates to superpowers for execution, adds external AI review of the result.
---

# Devflow: Implement

Cross-tool implementation workflow. Uses superpowers for plan execution, calls an external AI tool to review the resulting code.

## Prerequisites
- Plan file ready (from `/devflow-plan` or provided by user)
- Superpowers skills available (executing-plans)
- External reviewer CLI installed (`codex` or `claude`)

---

## Phase 1 — Read Config & Plan

// turbo
```bash
echo "=== Global config ===" && cat ~/.devflow/config.yaml 2>/dev/null || echo "(none)"
echo "=== Project config ===" && cat .devflow.yaml 2>/dev/null || echo "(none)"
echo "=== Plan-review session ===" && cat /tmp/devflow-plan-review.session 2>/dev/null || echo "(none)"
```

Extract from config (defaults shown):
- `reviewer.command`: `codex exec` | `reviewer.flags`: `--full-auto`
- `reviewer.model`: `gpt-5.4` | `reviewer.effort`: `xhigh`
- `implementer.model`: `gpt-5.4` | `implementer.effort`: `high`
- `session_reuse`: `true`

Read the plan file provided by the user. Verify it has task structure.

---

## Phase 2 — Execute Plan (superpowers)

Invoke the **executing-plans** skill to implement the plan.

This handles: sequential task execution, TDD, self-review, checkpoints.

Note: In Claude Code / Codex with subagents, use **subagent-driven-development** instead for better quality.

---

## Phase 3 — Collect Changes

// turbo
```bash
echo "=== Changed files ===" && git diff HEAD --stat
echo "=== Full diff ===" && git diff HEAD | head -c 50000
```

If changes were committed during execution:
```bash
git diff <start-commit>..HEAD --stat
git diff <start-commit>..HEAD | head -c 50000
```

---

## Phase 4 — External Cross-Tool Review

**If plan-review session exists** (from `/devflow-plan`), resume it — reviewer already knows the plan:

> **WARNING**: Codex CLI has NO `--effort` flag. Reasoning effort is set via
> `-c 'model_reasoning_effort="..."'` (a config override), NOT a direct flag.

```bash
SESSION_FILE="/tmp/devflow-impl-review.session"
OUTPUT_FILE="/tmp/devflow-impl-review-output.txt"
PLAN_SESSION_FILE="/tmp/devflow-plan-review.session"

if [ -f "$PLAN_SESSION_FILE" ]; then
  SESSION_ID=$(cat "$PLAN_SESSION_FILE")
  codex exec resume "$SESSION_ID" --full-auto \
    -m <reviewer.model> -c 'model_reasoning_effort="<reviewer.effort>"' \
    -o "$OUTPUT_FILE" \
    "The plan you reviewed is now implemented. Review the code changes. READ-ONLY.

Review for:
1. PLAN COMPLIANCE — implements everything?
2. CODE QUALITY — clean, no bugs?
3. TESTING — adequate?
4. PATTERNS — project conventions?
5. SECURITY — concerns?

Respond: APPROVED or ISSUES (severity + file:line + fix).

Code changes:
$(git diff HEAD | head -c 50000)"
  cp "$PLAN_SESSION_FILE" "$SESSION_FILE"
else
  # Fresh session (no prior plan-review context)
  codex exec --full-auto --json \
    -m <reviewer.model> -c 'model_reasoning_effort="<reviewer.effort>"' \
    -o "$OUTPUT_FILE" \
    "You are reviewing code implementation against its plan. READ-ONLY.

Respond: APPROVED or ISSUES.

Plan:
$(cat <plan-file>)

Diff:
$(git diff HEAD | head -c 50000)" 2>/dev/null | tee /tmp/devflow-impl-review-events.jsonl
  head -1 /tmp/devflow-impl-review-events.jsonl | python3 -c "import sys,json; print(json.loads(sys.stdin.read())['thread_id'])" > "$SESSION_FILE"
fi
```

**Subsequent iterations — resume:**
```bash
SESSION_ID=$(cat "$SESSION_FILE")
codex exec resume "$SESSION_ID" --full-auto \
  -o "$OUTPUT_FILE" \
  "Issues fixed. Re-review:\n$(git diff HEAD | head -c 50000)"
```

**Implementation handoff** — if fixes are complex, resume with implementer effort:
```bash
codex exec resume "$SESSION_ID" --full-auto \
  -m <implementer.model> -c 'model_reasoning_effort="<implementer.effort>"' \
  -o /tmp/devflow-impl-fix-output.txt \
  "Fix the issues you found in your review."
```

---

## Phase 5 — Process Review & Iterate

- **APPROVED** → Phase 6
- **ISSUES** → fix, re-review (resume session). Max 5 iterations.

---

## Phase 6 — Finalize

```bash
mkdir -p docs/devflow/reports
```

Save report to `docs/devflow/reports/YYYY-MM-DD-<feature>-impl-review.md`.

> "Implementation complete and cross-reviewed. Changes in working directory (not committed)."
