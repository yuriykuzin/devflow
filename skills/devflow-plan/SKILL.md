---
name: devflow-plan
description: "Plan a feature with cross-tool review loop. Use when the user wants to plan a feature and have it reviewed by an external AI tool (e.g. Codex reviews Claude's plan)."
---

# Devflow: Plan

Plan a feature using superpowers' brainstorming and writing-plans skills, then run an **external cross-tool review loop** to validate the plan from a different AI perspective.

## When to Use

- User says "plan this feature" or "devflow:plan"
- User wants a plan that's been cross-reviewed by another AI tool
- As Phase 1 of `devflow:run`

## Inputs

- **Feature description**: what to build (from user)
- **Autonomy mode**: `attended` (default) or `unattended` (from user or config)
- **Config**: `~/.devflow/config.yaml` or `.devflow.yaml`

## Process

```dot
digraph plan {
    "Read devflow config" [shape=box];
    "Invoke superpowers:brainstorming" [shape=box style=filled fillcolor=lightyellow];
    "Invoke superpowers:writing-plans" [shape=box style=filled fillcolor=lightyellow];
    "Save plan to temp file" [shape=box];
    "Call external reviewer via CLI" [shape=box style=filled fillcolor=lightblue];
    "Parse reviewer response" [shape=box];
    "Issues found?" [shape=diamond];
    "Address issues in plan" [shape=box];
    "Max iterations reached?" [shape=diamond];
    "Escalate to user" [shape=box];
    "Plan finalized" [shape=doublecircle];

    "Read devflow config" -> "Invoke superpowers:brainstorming";
    "Invoke superpowers:brainstorming" -> "Invoke superpowers:writing-plans";
    "Invoke superpowers:writing-plans" -> "Save plan to temp file";
    "Save plan to temp file" -> "Call external reviewer via CLI";
    "Call external reviewer via CLI" -> "Parse reviewer response";
    "Parse reviewer response" -> "Issues found?";
    "Issues found?" -> "Address issues in plan" [label="yes"];
    "Address issues in plan" -> "Max iterations reached?";
    "Max iterations reached?" -> "Escalate to user" [label="yes"];
    "Max iterations reached?" -> "Call external reviewer via CLI" [label="no"];
    "Escalate to user" -> "Plan finalized";
    "Issues found?" -> "Plan finalized" [label="no — approved"];
}
```

## Step-by-Step

### Step 1: Read Config

Read devflow configuration. Check in order (later overrides earlier):
1. Defaults (see `config.default.yaml`)
2. Global: `~/.devflow/config.yaml`
3. Project: `.devflow.yaml` in project root

```bash
# Check for configs
cat ~/.devflow/config.yaml 2>/dev/null || echo "No global config"
cat .devflow.yaml 2>/dev/null || echo "No project config"
```

**Resolve the active backend** from the `backend` key (default: `claude`), then read
settings from the matching section:

- `backend`: `claude` or `codex`
- `<backend>.reviewer.command`
- `<backend>.reviewer.flags`
- `<backend>.reviewer.model`
- `<backend>.reviewer.effort`
- `<backend>.implementer.command`
- `<backend>.implementer.flags`
- `<backend>.implementer.model`
- `<backend>.implementer.effort`
- `<backend>.session_reuse`

For example, if `backend: claude`, read `claude.reviewer.command`, etc.

### Step 2: Internal Planning (superpowers)

Invoke superpowers skills for the internal planning process:

1. **Invoke `superpowers:brainstorming`** — explore the idea, ask clarifying questions, propose approaches, get user approval on design, write spec
2. **Invoke `superpowers:writing-plans`** — create detailed implementation plan with bite-sized tasks

These skills handle the full internal planning workflow including spec review loops.

After these complete, you should have a plan file (typically at `docs/superpowers/plans/YYYY-MM-DD-<feature>.md`).

### Step 3: External Cross-Tool Review

Now send the plan to an external AI tool for a fresh-perspective review.

The review prompt is the same for all backends:

```
REVIEW_PROMPT="You are reviewing an implementation plan. You must NOT create or modify any files. READ-ONLY review.

Review for:
1. COMPLETENESS — edge cases, missing steps?
2. CORRECTNESS — architecture sound? technical mistakes?
3. CONSISTENCY — steps reference each other correctly?
4. TESTABILITY — test steps adequate?
5. CODEBASE FIT — follows project patterns?

Respond: APPROVED or ISSUES (severity: critical/important/minor + fix).

Plan:
$(cat $PLAN_FILE)"
```

Common variables:
```bash
PLAN_FILE="<path-to-plan-file>"
SESSION_FILE="/tmp/devflow-plan-review.session"
OUTPUT_FILE="/tmp/devflow-plan-review-output.txt"
```

---

#### Backend: claude

**First iteration — new session:**
```bash
claude -p --output-format json --permission-mode plan \
  --model <reviewer.model> --effort <reviewer.effort> \
  "$REVIEW_PROMPT" | tee "$OUTPUT_FILE"

# Capture session ID
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

**Example (first call):**
```bash
claude -p --output-format json --permission-mode plan \
  --model opus --effort max \
  "Review this plan... $(cat docs/superpowers/plans/2026-03-18-caching.md)" \
  | tee /tmp/devflow-plan-review-output.txt
```

**Parse result:**
```bash
jq -r '.result' /tmp/devflow-plan-review-output.txt
```

---

#### Backend: codex

> **WARNING**: Codex CLI has NO `--effort` flag. Reasoning effort is set via
> `-c 'model_reasoning_effort="..."'` (a config override), NOT a direct flag.

**First iteration — new session:**
```bash
EVENTS_FILE="/tmp/devflow-plan-review-events.jsonl"

codex exec --full-auto --json \
  -m <reviewer.model> -c 'model_reasoning_effort="<reviewer.effort>"' \
  -o "$OUTPUT_FILE" \
  "$REVIEW_PROMPT" 2>/dev/null | tee "$EVENTS_FILE"

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

---

The resumed session preserves full context — the reviewer already knows the plan
structure and prior feedback, saving ~20k tokens per iteration.

**If session_reuse is false**: for codex use `--ephemeral`; for claude use
`--no-session-persistence`. Skip session capture in both cases.

### Step 4: Process Review Response

Parse the external reviewer's response:

- **If APPROVED**: Plan is finalized. Proceed to Step 5.
- **If ISSUES found**:
  - For each **critical** issue: fix it in the plan
  - For each **important** issue: fix it or explain why it's a false positive
  - For each **minor** issue: note it, fix if easy
  - After fixes, go back to Step 3 (re-review)
  - **Max iterations**: 7 (from config `max_review_iterations`). If reached without approval, escalate to the user — present all remaining issues and ask what actions to take.

### Step 5: Implementation Handoff (optional)

If the plan is approved and implementation follows (e.g., in `devflow:run`):

**claude backend:**
```bash
SESSION_ID=$(cat /tmp/devflow-plan-review.session)
claude -p --output-format json --permission-mode default \
  --model <implementer.model> --effort <implementer.effort> \
  --resume "$SESSION_ID" \
  "Implement the plan you just reviewed. The plan is approved. Create the files."
```

**codex backend:**
```bash
SESSION_ID=$(cat /tmp/devflow-plan-review.session)
codex exec resume "$SESSION_ID" --full-auto \
  -m <implementer.model> -c 'model_reasoning_effort="<implementer.effort>"' \
  -o /tmp/devflow-impl-output.txt \
  "Implement the plan you just reviewed. The plan is approved. Create the files."
```

This gives the implementer full context of the plan AND all review feedback.

### Step 6: Finalize

Save the review report alongside the plan:

```bash
mkdir -p "<output_dir>"
cat > "<output_dir>/YYYY-MM-DD-<feature>-plan-review.md" << 'EOF'
# Plan Review Report

**Feature**: <feature name>
**Plan**: <path to plan>
**Reviewer**: <tool name>
**Iterations**: <count>
**Result**: APPROVED / APPROVED_WITH_NOTES

## Review History
### Iteration 1
<reviewer response>
### Iteration 2 (if any)
<fixes made + reviewer response>

## Final Status
<summary>
EOF
```

Announce to user:
> "Plan complete and cross-reviewed. Saved to `<plan-path>`. Review report at `<report-path>`. Ready to implement? (Use `devflow:implement` or `devflow:run` to continue)"

## Autonomy Modes

- **attended** (default): Run superpowers brainstorming normally (asks user questions). Present external review findings to user before fixing.
- **unattended**: Skip brainstorming questions (use feature description as-is). Auto-fix review issues without asking. Only escalate on critical blockers.

## Key Rules

- **Never skip the external review** — that's the whole point of devflow
- **Never auto-approve** — external reviewer must explicitly say APPROVED
- **Superpowers handles the HOW** — devflow handles the WHO (which tool does what)
- **Plan file is the source of truth** — all edits happen to the plan file, not in chat
