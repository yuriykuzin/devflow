---
description: Implement a plan with cross-tool review loop. Delegates to superpowers for execution, adds external AI review of the result.
---

# Devflow: Implement

Cross-tool implementation workflow. Uses superpowers for plan execution, calls an external AI tool (configured via `backend` key) to review the resulting code.

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

**Resolve the active backend** from the `backend` key (default: `claude`), then read
from the matching section (`claude.*` or `codex.*`):
- `<backend>.reviewer.*` (command, flags, model, effort)
- `<backend>.implementer.*` (command, flags, model, effort)
- `<backend>.session_reuse`

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

Common variables:
```bash
SESSION_FILE="/tmp/devflow-impl-review.session"
OUTPUT_FILE="/tmp/devflow-impl-review-output.txt"
PLAN_SESSION_FILE="/tmp/devflow-plan-review.session"

REVIEW_PROMPT="Review the code implementation. READ-ONLY.

Review for:
1. PLAN COMPLIANCE — implements everything?
2. CODE QUALITY — clean, no bugs?
3. TESTING — adequate?
4. PATTERNS — project conventions?
5. SECURITY — concerns?

Respond: APPROVED or ISSUES (severity + file:line + fix).

Code changes:
$(git diff HEAD | head -c 50000)"
```

### Backend: claude

**Resume plan-review session (if exists):**
```bash
if [ -f "$PLAN_SESSION_FILE" ]; then
  SESSION_ID=$(cat "$PLAN_SESSION_FILE")
  claude -p --output-format json --permission-mode plan \
    --model <reviewer.model> --effort <reviewer.effort> \
    --resume "$SESSION_ID" \
    "The plan you reviewed is now implemented. $REVIEW_PROMPT" | tee "$OUTPUT_FILE"
  jq -r '.session_id' "$OUTPUT_FILE" > "$SESSION_FILE"
else
  claude -p --output-format json --permission-mode plan \
    --model <reviewer.model> --effort <reviewer.effort> \
    "$REVIEW_PROMPT" | tee "$OUTPUT_FILE"
  jq -r '.session_id' "$OUTPUT_FILE" > "$SESSION_FILE"
fi
```

**Subsequent iterations — resume:**
```bash
SESSION_ID=$(cat "$SESSION_FILE")
claude -p --output-format json --permission-mode plan \
  --model <reviewer.model> --effort <reviewer.effort> \
  --resume "$SESSION_ID" \
  "Issues fixed. Re-review:\n$(git diff HEAD | head -c 50000)"
```

### Backend: codex

> **WARNING**: Codex CLI has NO `--effort` flag. Use `-c 'model_reasoning_effort="..."'`.
> **CRITICAL**: All `-c` flags MUST go BEFORE the `exec` subcommand. Placing
> them after `exec` creates a fresh config context that shadows top-level
> `-c` flags (e.g., from `codex-local-proxy`), causing codex to fall back to
> its default provider.

**Resume plan-review session (if exists):**
```bash
if [ -f "$PLAN_SESSION_FILE" ]; then
  SESSION_ID=$(cat "$PLAN_SESSION_FILE")
  codex -c 'model_reasoning_effort="<reviewer.effort>"' \
    exec resume "$SESSION_ID" --full-auto -m <reviewer.model> \
    -o "$OUTPUT_FILE" \
    "The plan you reviewed is now implemented. $REVIEW_PROMPT"
  cp "$PLAN_SESSION_FILE" "$SESSION_FILE"
else
  EVENTS_FILE="/tmp/devflow-impl-review-events.jsonl"
  codex -c 'model_reasoning_effort="<reviewer.effort>"' \
    exec --full-auto --json -m <reviewer.model> \
    -o "$OUTPUT_FILE" \
    "$REVIEW_PROMPT" 2>/dev/null | tee "$EVENTS_FILE"
  head -1 "$EVENTS_FILE" | python3 -c "import sys,json; print(json.loads(sys.stdin.read())['thread_id'])" > "$SESSION_FILE"
fi
```

**Subsequent iterations — resume:**
```bash
SESSION_ID=$(cat "$SESSION_FILE")
codex exec resume "$SESSION_ID" --full-auto \
  -o "$OUTPUT_FILE" \
  "Issues fixed. Re-review:\n$(git diff HEAD | head -c 50000)"
```

### Implementation handoff (both backends)

**claude:**
```bash
claude -p --output-format json --permission-mode default \
  --model <implementer.model> --effort <implementer.effort> \
  --resume "$SESSION_ID" \
  "Fix the issues you found in your review."
```

**codex:**
```bash
codex -c 'model_reasoning_effort="<implementer.effort>"' \
  exec resume "$SESSION_ID" --full-auto -m <implementer.model> \
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
