#!/usr/bin/env bash
# devflow_kill_wait must terminate a child that IGNORES SIGTERM (escalate to -9) and
# return within its bound instead of hanging forever on `wait`.
set -u
. "$LIB/assert.sh"; . "$LIB/sandbox.sh"

# Only the function definitions are needed (no bootstrap).
. "$EXTRACTED/b.sh"

# Child traps+ignores TERM, so a plain `kill; wait` would block indefinitely.
bash -c 'trap "" TERM; sleep 30' &
pid=$!
sleep 0.3                              # let the trap install

SECONDS=0
devflow_kill_wait "$pid"
dur=$SECONDS

if kill -0 "$pid" 2>/dev/null; then alive=1; else alive=0; fi
is "$alive" "0" "SIGTERM-ignoring child is killed (escalated to -9)"
ok "[ $dur -lt 7 ]" "kill_wait returns within bound (${dur}s), no unbounded hang"

report
