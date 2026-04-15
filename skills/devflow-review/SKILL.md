---
name: devflow-review
description: "Cross-tool review of existing code or changes. Use when the user wants a second AI tool to review their work without planning or implementing."
---

# Devflow: Review

Send existing code changes to an external AI tool for review. Standalone skill — does not require prior planning or implementation through devflow.

## When to Use

- User says "review my changes" or "devflow:review"
- User wants a fresh perspective from a different AI tool
- As Phase 3 of `devflow:run`
- After manual implementation that needs cross-tool validation

## Inputs

- **What to review**: git diff, specific files, a PR, or staged changes (from user)
- **Review focus** (optional): security, performance, patterns, tests, etc.
- **Config**: `~/.devflow/config.yaml` or `.devflow.yaml`

## Step-by-Step

### Step 1: Read Config

Read config from `~/.devflow/config.yaml` or `.devflow.yaml`.

```bash
cat ~/.devflow/config.yaml 2>/dev/null || echo "No global config"
cat .devflow.yaml 2>/dev/null || echo "No project config"
```

**Resolve the active backend** from the `backend` key (default: `claude`), then read
settings from the matching section:

- `backend`: `claude` or `codex`
- `<backend>.reviewer.*` (command, flags, model, effort)
- `<backend>.implementer.*` (command, flags, model, effort)
- `<backend>.session_reuse`

### Step 2: Determine Scope

Ask the user what to review (or infer from context):

| User says | What to collect |
|-----------|----------------|
| "review my changes" | `git diff HEAD` |
| "review staged changes" | `git diff --cached` |
| "review this PR" | `gh pr diff <number>` |
| "review branch" | `git diff main..HEAD` |
| "review file X" | `cat X` |
| "review last commit" | `git show HEAD` |

Collect the content:
```bash
# Example: uncommitted changes
REVIEW_CONTENT=$(git diff HEAD)
REVIEW_STATS=$(git diff HEAD --stat)

# Example: PR
REVIEW_CONTENT=$(gh pr diff <number>)
```

### Step 3: Internal Review First (superpowers)

Before calling the external tool, do a quick internal review:

1. **Invoke `superpowers:requesting-code-review`** (if not already done)
2. Note any issues found internally

This gives you context for evaluating the external review later.

### Step 4: External Cross-Tool Review

Common variables:
```bash
SESSION_FILE="/tmp/devflow-review.session"
OUTPUT_FILE="/tmp/devflow-review-output.txt"
```

The review prompt (same for all backends):
```
REVIEW_PROMPT="You are performing a code review. READ-ONLY, do not modify files.

REVIEW FOCUS: <user-specified focus or 'general'>

REVIEW CHECKLIST:
1. BUGS — Logic errors, off-by-one, null handling, race conditions
2. SECURITY — Input validation, injection, secrets, auth
3. PERFORMANCE — N+1 queries, unnecessary allocations, missing indexes
4. PATTERNS — Does the code follow project conventions?
5. TESTING — Test coverage, edge cases, test quality
6. READABILITY — Naming, structure, comments where needed

For each issue found, provide:
- Severity: critical / important / minor / nitpick
- File and approximate location
- What's wrong and how to fix it

End with: APPROVED (no blockers) or CHANGES_REQUESTED (has critical/important issues)

Changes to review:
$REVIEW_CONTENT"
```

---

#### Backend: claude

**First iteration — new session:**
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

**Parse result:**
```bash
jq -r '.result' "$OUTPUT_FILE"
```

---

#### Backend: codex

> **WARNING**: Codex CLI has NO `--effort` flag. Reasoning effort is set via
> `-c 'model_reasoning_effort="..."'` (a config override), NOT a direct flag.
> **CRITICAL**: All `-c` flags MUST go BEFORE the `exec` subcommand. Placing
> them after `exec` creates a fresh config context that shadows top-level
> `-c` flags (e.g., from `codex-local-proxy`), causing codex to fall back to
> its default provider.

**First iteration — new session:**
```bash
EVENTS_FILE="/tmp/devflow-review-events.jsonl"
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
  "Issues were fixed. Re-review the updated changes:
$REVIEW_CONTENT"
```

### Step 5: Synthesize Reviews

Combine internal (superpowers) and external review findings:

1. **Deduplicate** — same issue found by both → higher confidence
2. **Cross-reference** — issue found by one but not other → verify manually
3. **Filter false positives** — if you're confident an issue is wrong, explain why
4. **Categorize** — group by file, then by severity

### Step 6: Report

Present findings to user and save report:

```markdown
# Cross-Tool Review Report

**Scope**: <what was reviewed>
**Internal reviewer**: <current tool>
**External reviewer**: <tool name>

## Summary
- Critical: N
- Important: N
- Minor: N
- Nitpick: N

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

Create the output directory and save:

```bash
mkdir -p <output_dir>
```

Save to `<output_dir>/YYYY-MM-DD-<scope>-review.md`.

## Iteration (if CHANGES_REQUESTED)

If user asks to fix and re-review:
1. Fix the critical/important issues
2. Re-run Step 4 with the updated diff (resume existing session)
3. Repeat until APPROVED or max 7 iterations (from config `max_review_iterations`). If not approved after 7 rounds, escalate to the user — present all remaining issues and ask what actions to take

**Implementation handoff**: If fixes are complex, resume the review session with implementer settings:

**claude backend:**
```bash
SESSION_ID=$(cat /tmp/devflow-review.session)
claude -p --output-format json --permission-mode default \
  --model <implementer.model> --effort <implementer.effort> \
  --resume "$SESSION_ID" \
  "Fix the issues you found in your review."
```

**codex backend:**
```bash
SESSION_ID=$(cat /tmp/devflow-review.session)
codex -c 'model_reasoning_effort="<implementer.effort>"' \
  exec resume "$SESSION_ID" --full-auto -m <implementer.model> \
  -o /tmp/devflow-review-fix-output.txt \
  "Fix the issues you found in your review."
```

## Key Rules

- **Internal review FIRST** — gives you context to evaluate external feedback
- **Never blindly accept external review** — cross-reference with your own analysis
- **False positives are normal** — external tool lacks full project context, explain disagreements
- **Report both perspectives** — user gets the full picture, decides what to act on
