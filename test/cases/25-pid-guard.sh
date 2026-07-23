#!/usr/bin/env bash
# The reported RUN_DIR concurrent-wipe race: while a run-external call is in flight (its PID
# leased under $RUN_DIR/.pids/), a second `dir --fresh` — starting a new run on the same
# deterministic RUN_DIR — must REFUSE to rm -rf the directory out from under it, instead of
# silently wiping the live call's session/output files. Once the run is gone, a stale marker
# must not keep blocking a fresh dir (self-healing).
set -u
export DEVFLOW_POLL_SCHEDULE="2 2 2 2 2"     # keep the hang call alive ~10s while we probe
. "$LIB/assert.sh"; . "$LIB/sandbox.sh"

mk_sandbox
run_dir_here

PROMPT_FILE="$SB/prompt.txt"; printf 'review please\n' > "$PROMPT_FILE"

# Launch a call that stays alive (hang: emits no events, so the runner polls until the cap).
# `exec` makes the subshell BECOME the runner, so $! is the runner's own PID — the exact PID
# it records in the lease (a plain `( ... ) &` would give the wrapper's PID).
( cd "$REPO_FX" && exec env FAKE_CODEX_MODE=hang bash "$RUNNER" run-external \
    --backend codex --model gpt-5.5 --effort high \
    --phase live-run --prompt-file "$PROMPT_FILE" >/dev/null 2>&1 ) &
bg_pid=$!

# Wait (bounded) for the lease marker to appear before we try to race it.
leased=""
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
  [ -e "$RUN_DIR/.pids/$bg_pid" ] && { leased=1; break; }
  sleep 0.3
done
ok "[ -n '$leased' ]" "run-external leased its PID under \$RUN_DIR/.pids/"

# Sentinel: proves the directory survived a refused wipe.
printf 'live\n' > "$RUN_DIR/sentinel"

# dir --fresh must refuse while the lease is live.
err="$(cd "$REPO_FX" && bash "$RUNNER" dir --fresh 2>&1)"; rc=$?
isnt "$rc" "0"                    "dir --fresh refuses while a run is live"
has  "$err" "refusing to wipe"    "...with an explicit refusal message"
ok   "[ -f '$RUN_DIR/sentinel' ]" "...and the live run's RUN_DIR was NOT wiped"

# Stop the live run and reap it, so no live PID remains.
kill -TERM "$bg_pid" 2>/dev/null
wait "$bg_pid" 2>/dev/null || true

# Once no live PID remains, a fresh dir is allowed again (dead marker ignored / self-healing).
out="$(cd "$REPO_FX" && bash "$RUNNER" dir --fresh 2>&1)"; rc3=$?
is  "$rc3" "0"                     "dir --fresh succeeds once the run is gone (self-healing)"
has "$out" "RUN_DIR="              "...and re-emits a RUN_DIR"
ok  "[ ! -f '$RUN_DIR/sentinel' ]" "...the stale sentinel was cleared by the rebuild"

cleanup_sandbox
report
