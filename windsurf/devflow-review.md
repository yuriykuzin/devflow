---
description: Cross-tool review of existing code or changes. Sends your work to an external AI tool for a second opinion without planning or implementing.
---

# Devflow: Review

Cross-tool review workflow. Uses superpowers for internal review, calls an external AI tool (configured via `backend` key) for independent review, then synthesizes both.

## Prerequisites
- External reviewer CLI installed (`codex` or `claude`)
- Config: `~/.devflow/config.yaml` or `.devflow.yaml` (optional)
- Superpowers skills available (requesting-code-review) — optional but recommended

---

## Phase 1 — Read Config

// turbo
```bash
echo "=== Global config ===" && cat ~/.devflow/config.yaml 2>/dev/null || echo "(none)"
echo "=== Project config ===" && cat .devflow.yaml 2>/dev/null || echo "(none)"
```

**Resolve the active backend** from the `backend` key (default: `claude`), then read
from the matching section (`claude.*` or `codex.*`):
- `<backend>.reviewer.*` (command, flags, model, effort)
- `<backend>.implementer.*` (command, flags, model, effort)
- `<backend>.session_reuse`

---

## Phase 2 — Determine Scope

Ask the user what to review (or infer from context):

| User says | What to collect |
|-----------|----------------|
| "review my changes" | `git diff HEAD` |
| "review staged changes" | `git diff --cached` |
| "review this PR" | `gh pr diff <number>` |
| "review branch" | `git diff main..HEAD` |
| "review file X" | `cat X` |
| "review last commit" | `git show HEAD` |

// turbo
```bash
# Example: uncommitted changes
echo "=== Diff stats ===" && git diff HEAD --stat
echo "=== Full diff ===" && git diff HEAD | head -c 50000
```

---

## Phase 3 — Internal Review (superpowers)

Before calling the external tool, do a quick internal review:

1. Invoke **superpowers requesting-code-review** (if available)
2. Note any issues found internally

This gives context for evaluating the external review later.

---

## Phase 4 — External Cross-Tool Review

Common variables:
```bash
SESSION_FILE="/tmp/devflow-review.session"
OUTPUT_FILE="/tmp/devflow-review-output.txt"

REVIEW_PROMPT="You are performing a code review. READ-ONLY, do not modify files.

REVIEW FOCUS: <user-specified focus or 'general'>

REVIEW CHECKLIST:
1. BUGS — Logic errors, off-by-one, null handling, race conditions
2. SECURITY — Input validation, injection, secrets, auth
3. PERFORMANCE — N+1 queries, unnecessary allocations, missing indexes
4. PATTERNS — Does the code follow project conventions?
5. TESTING — Test coverage, edge cases, test quality
6. READABILITY — Naming, structure, comments where needed

For each issue: severity (critical/important/minor/nitpick), file:line, what's wrong, how to fix.

End with: APPROVED (no blockers) or CHANGES_REQUESTED (has critical/important issues).

Changes to review:
$REVIEW_CONTENT"
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
  "Issues were fixed. Re-review the updated changes:
$REVIEW_CONTENT"
```

### Backend: codex

> **WARNING**: Codex CLI has NO `--effort` flag. Use `-c 'model_reasoning_effort="..."'`.

**First iteration:**
```bash
EVENTS_FILE="/tmp/devflow-review-events.jsonl"
codex exec --full-auto --json \
  -m <reviewer.model> -c 'model_reasoning_effort="<reviewer.effort>"' \
  -o "$OUTPUT_FILE" \
  "$REVIEW_PROMPT" 2>/dev/null | tee "$EVENTS_FILE"
head -1 "$EVENTS_FILE" | python3 -c "import sys,json; print(json.loads(sys.stdin.read())['thread_id'])" > "$SESSION_FILE"
```

**Subsequent iterations — resume session:**
```bash
SESSION_ID=$(cat "$SESSION_FILE")
codex exec resume "$SESSION_ID" --full-auto \
  -o "$OUTPUT_FILE" \
  "Issues were fixed. Re-review the updated changes:
$REVIEW_CONTENT"
```

---

## Phase 5 — Synthesize Reviews

Combine internal (superpowers) and external review findings:

1. **Deduplicate** — same issue found by both = higher confidence
2. **Cross-reference** — issue found by one but not the other = verify manually
3. **Filter false positives** — external tool lacks full project context
4. **Categorize** — group by file, then by severity

---

## Phase 6 — Report

Present findings to user and save report:

```bash
mkdir -p <output_dir>
```

Save to `<output_dir>/YYYY-MM-DD-<scope>-review.md`:

```markdown
# Cross-Tool Review Report

**Scope**: <what was reviewed>
**Internal reviewer**: <current tool>
**External reviewer**: <tool name>

## Summary
- Critical: N | Important: N | Minor: N | Nitpick: N

## Issues

### Critical
1. **[file:line]** <description> — found by: <tool(s)>

### Important
...

### Minor / Nitpick
...

## False Positives (if any)
Issues flagged by external reviewer that appear incorrect, with explanation.

## Verdict
APPROVED / CHANGES_REQUESTED
```

---

## Iteration (if CHANGES_REQUESTED)

If user asks to fix and re-review:
1. Fix the critical/important issues
2. Re-run Phase 4 with updated diff (resume existing session)
3. Repeat until APPROVED or max iterations

**Implementation handoff** — if fixes are complex:

**claude:**
```bash
SESSION_ID=$(cat /tmp/devflow-review.session)
claude -p --output-format json --permission-mode default \
  --model <implementer.model> --effort <implementer.effort> \
  --resume "$SESSION_ID" \
  "Fix the issues you found in your review."
```

**codex:**
```bash
SESSION_ID=$(cat /tmp/devflow-review.session)
codex exec resume "$SESSION_ID" --full-auto \
  -m <implementer.model> -c 'model_reasoning_effort="<implementer.effort>"' \
  -o /tmp/devflow-review-fix-output.txt \
  "Fix the issues you found in your review."
```

---

## Partial execution examples

- *"Run `/devflow-review` on my staged changes"* → all phases
- *"Run `/devflow-review`, focus on security"* → all phases with security focus
- *"Run `/devflow-review` on PR #42"* → review PR diff
