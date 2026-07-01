#!/usr/bin/env bash
# Section D failure handling: success passes; a transient rate-limit retries once via the
# fallback binary; a permanent auth failure escalates WITHOUT a retry; empty fallback escalates.
set -u
export DEVFLOW_POLL_SCHEDULE="1 1 1 1 1 1"
. "$LIB/assert.sh"; . "$LIB/sandbox.sh"

mk_sandbox
bootstrap_here
. "$EXTRACTED/b.sh"
. "$EXTRACTED/d.sh"

PHASE="final-review"; MODEL="$REVIEWER_MODEL"; EFFORT="$REVIEWER_EFFORT"; PROMPT="review"
CRAFT_ERR="$SB/craft.stderr"; CRAFT_EV="$SB/craft.events"; : > "$CRAFT_EV"

# (1) clean success -> return 0, no fallback
: > "$FAKE_CODEX_LOG"
CODEX_EXIT=0; CALL_RESULT="all good APPROVED"; STDERR="$CRAFT_ERR"; EVENTS="$CRAFT_EV"; : > "$STDERR"
FALLBACK_COMMAND="$LIB/fake-codex-ok"
if devflow_after_call; then rc=0; else rc=1; fi
is "$rc" "0" "success verdict accepted without fallback"
is "$(wc -l < "$FAKE_CODEX_LOG" | tr -d ' ')" "0" "no external retry on success"

# (2) rate limit -> one fallback retry that succeeds -> return 0
: > "$FAKE_CODEX_LOG"
CODEX_EXIT=1; CALL_RESULT=""; STDERR="$CRAFT_ERR"; EVENTS="$CRAFT_EV"
printf 'Error: rate limit reached, retry later\n' > "$STDERR"
FALLBACK_COMMAND="$LIB/fake-codex-ok"
if devflow_after_call; then rc=0; else rc=1; fi
is "$rc" "0" "rate-limit recovered via fallback retry"
has "$(cat "$FAKE_CODEX_LOG")" "ok|" "fallback binary was invoked exactly once"
is "$(wc -l < "$FAKE_CODEX_LOG" | tr -d ' ')" "1" "fallback retried once (not looping)"

# (3) auth failure -> escalate, NO fallback retry
: > "$FAKE_CODEX_LOG"
CODEX_EXIT=1; CALL_RESULT=""; STDERR="$CRAFT_ERR"; EVENTS="$CRAFT_EV"; : > "$EVENTS"
printf 'Error: not logged in. Please run codex login\n' > "$STDERR"
FALLBACK_COMMAND="$LIB/fake-codex-ok"
if devflow_after_call; then rc=0; else rc=1; fi
is "$rc" "1" "auth failure escalates"
is "$(wc -l < "$FAKE_CODEX_LOG" | tr -d ' ')" "0" "no fallback retry burned on auth failure"

# (4) rate limit but no fallback configured -> escalate
CODEX_EXIT=1; CALL_RESULT=""; STDERR="$CRAFT_ERR"; EVENTS="$CRAFT_EV"
printf 'Error: rate limit reached\n' > "$STDERR"
FALLBACK_COMMAND=""
if devflow_after_call; then rc=0; else rc=1; fi
is "$rc" "1" "rate limit with empty fallback_command escalates"

cleanup_sandbox
report
