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
CRAFT_ERR="$SB/craft.stderr"; CRAFT_EV="$SB/craft.events"
# A non-empty, non-error events file: forces devflow_after_call to decide on STDERR content
# alone, so the codex empty-events escalation (a DIFFERENT branch) can't be what produces the
# result. Case (5) below covers the empty-events branch on its own.
printf '{"type":"turn.completed"}\n' > "$CRAFT_EV"

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

# (3) auth failure (by message) -> escalate via the auth branch, NO fallback retry
: > "$FAKE_CODEX_LOG"
CODEX_EXIT=1; CALL_RESULT=""; STDERR="$CRAFT_ERR"; EVENTS="$CRAFT_EV"
printf 'Error: not logged in. Please run codex login\n' > "$STDERR"
FALLBACK_COMMAND="$LIB/fake-codex-ok"
err="$(devflow_after_call 2>&1)" && rc=0 || rc=1
is "$rc" "1" "auth failure escalates"
has "$err" "auth" "...via the auth/capability branch (not a rate-limit retry)"
is "$(wc -l < "$FAKE_CODEX_LOG" | tr -d ' ')" "0" "no fallback retry burned on auth failure"

# (4) rate limit, no fallback configured -> escalate via the rate-limit branch.
# Non-empty EVENTS proves the escalation is NOT the empty-events branch firing by accident.
CODEX_EXIT=1; CALL_RESULT=""; STDERR="$CRAFT_ERR"; EVENTS="$CRAFT_EV"
printf 'Error: rate limit reached\n' > "$STDERR"
FALLBACK_COMMAND=""
err="$(devflow_after_call 2>&1)" && rc=0 || rc=1
is "$rc" "1" "rate limit with empty fallback_command escalates"
has "$err" "no usable fallback" "...specifically via the rate-limit branch, not empty-events/unknown"

# (5) codex empty events, no rate/auth text -> escalate via the empty-events clause
: > "$FAKE_CODEX_LOG"
EMPTY_EV="$SB/empty.events"; : > "$EMPTY_EV"
CODEX_EXIT=1; CALL_RESULT=""; STDERR="$CRAFT_ERR"; EVENTS="$EMPTY_EV"
printf 'some unremarkable diagnostic line\n' > "$STDERR"
FALLBACK_COMMAND="$LIB/fake-codex-ok"
err="$(devflow_after_call 2>&1)" && rc=0 || rc=1
is "$rc" "1" "codex call with empty events escalates"
has "$err" "auth/capability" "...via the empty-events clause (proxy won't help)"
is "$(wc -l < "$FAKE_CODEX_LOG" | tr -d ' ')" "0" "no fallback retry burned on empty-events failure"

cleanup_sandbox
report
