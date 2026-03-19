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

Read reviewer config from `~/.devflow/config.yaml` or `.devflow.yaml`. Default: `codex exec --full-auto`.

```bash
cat ~/.devflow/config.yaml 2>/dev/null || echo "No global config"
cat .devflow.yaml 2>/dev/null || echo "No project config"
```

Extract these values (defaults shown):
- `reviewer.command`: `codex exec`
- `reviewer.flags`: `--full-auto`
- `reviewer.model`: `gpt-5.4`
- `reviewer.effort`: `xhigh`
- `implementer.model`: `gpt-5.4`
- `implementer.effort`: `high`
- `session_reuse`: `true`

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

**First iteration — new session with model flags:**

> **WARNING**: Codex CLI has NO `--effort` flag. Reasoning effort is set via
> `-c 'model_reasoning_effort="..."'` (a config override), NOT a direct flag.

```bash
SESSION_FILE="/tmp/devflow-review.session"
OUTPUT_FILE="/tmp/devflow-review-output.txt"
EVENTS_FILE="/tmp/devflow-review-events.jsonl"

<REVIEWER_COMMAND> <REVIEWER_FLAGS> --json \
  -m <reviewer.model> -c 'model_reasoning_effort="<reviewer.effort>"' \
  -o "$OUTPUT_FILE" \
  "You are performing a code review. READ-ONLY, do not modify files.

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
$REVIEW_CONTENT" 2>/dev/null | tee "$EVENTS_FILE"

# Capture session ID for reuse
head -1 "$EVENTS_FILE" | python3 -c "import sys,json; print(json.loads(sys.stdin.read())['thread_id'])" > "$SESSION_FILE"
```

**Subsequent iterations — resume session:**
```bash
SESSION_ID=$(cat "$SESSION_FILE")
<REVIEWER_COMMAND> resume "$SESSION_ID" <REVIEWER_FLAGS> \
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

**Implementation handoff**: If fixes are complex, resume the review session with implementer effort:
```bash
SESSION_ID=$(cat /tmp/devflow-review.session)
codex exec resume "$SESSION_ID" --full-auto \
  -m <implementer.model> -c 'model_reasoning_effort="<implementer.effort>"' \
  -o /tmp/devflow-review-fix-output.txt \
  "Fix the issues you found in your review."
```

## Key Rules

- **Internal review FIRST** — gives you context to evaluate external feedback
- **Never blindly accept external review** — cross-reference with your own analysis
- **False positives are normal** — external tool lacks full project context, explain disagreements
- **Report both perspectives** — user gets the full picture, decides what to act on
