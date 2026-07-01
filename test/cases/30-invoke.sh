#!/usr/bin/env bash
# Section B invocation: fake codex -> verdict extracted, session captured, exit 0;
# SESSION_REUSE=false -> ephemeral (no session persisted); linger -> drain then kill (124).
set -u
export DEVFLOW_POLL_SCHEDULE="1 1 1 1 1 1"      # test seam: sub-second polling
export DEVFLOW_DRAIN_SCHEDULE="0.2 0.2 0.2 0.2 0.2 0.2"
. "$LIB/assert.sh"; . "$LIB/sandbox.sh"

mk_sandbox
bootstrap_here
. "$EXTRACTED/b.sh"

PHASE="final-review"; MODEL="$REVIEWER_MODEL"; EFFORT="$REVIEWER_EFFORT"
PROMPT="review please"

# --- normal success ---
FAKE_CODEX_MODE=ok RESUME_ID="" devflow_run_external "$CODEX_BIN"
is "$CODEX_EXIT" "0" "normal call exits 0"
has "$CALL_RESULT" "APPROVED" "verdict text extracted from events"
is "$SESSION_ID" "thread_test_abc123" "thread_id captured as session id"
ok "[ -s '$SESSION_FILE' ]" "session file written for resume"

# --- ephemeral (session_reuse=false) ---
SESSION_REUSE=false FAKE_CODEX_MODE=ok RESUME_ID="" devflow_run_external "$CODEX_BIN"
is "$CODEX_EXIT" "0" "ephemeral call still exits 0"
ok "[ ! -s '$SESSION_FILE' ]" "ephemeral call persists no session"
SESSION_REUSE=true

# --- linger: turn.completed then process stays alive -> bounded drain -> kill 124 ---
SECONDS=0
FAKE_CODEX_MODE=linger RESUME_ID="" devflow_run_external "$CODEX_BIN"
dur=$SECONDS
is "$CODEX_EXIT" "124" "lingering process is killed after turn.completed (exit 124)"
ok "[ $dur -lt 15 ]" "linger path bounded (did not hang); took ${dur}s"

cleanup_sandbox
report
