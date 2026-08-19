#!/usr/bin/env bash
# `dir` opportunistically GCs stale sibling run dirs. RUN_DIR is keyed on the git top-level,
# so a worktree-per-feature workflow mints a fresh hash every run and completed dirs would
# pile up under $HOME/.devflow/run forever. On each `dir` call the runner reclaims a sibling devflow-run.*
# dir only when it is OURS (uid) + OLD (mtime past TTL, default DEVFLOW_RUN_TTL_DAYS=7) —
# never the current one, and a non-numeric TTL disables the sweep. mtime is a real last-USE
# clock because devflow_secure_dir touch()es RUN_DIR on every invocation, which runs before
# the sweep.
set -u
. "$LIB/assert.sh"; . "$LIB/sandbox.sh"

mk_sandbox
# Reroot the whole run-dir family under a sandbox-local directory before the first `dir` call, so
# the GC sweep can only ever touch dirs THIS test made — never a developer's real run dirs.
# DEVFLOW_RUN_HOME is the override the runner reads for exactly this purpose (RUN_DIR is under
# $HOME/.devflow/run, deliberately NOT under $TMPDIR — see the Security section of
# cross-tool-runner.md); the sandbox HOME alone would also isolate it, but naming the root here
# keeps the sweep's blast radius visible in the test.
export DEVFLOW_RUN_HOME="$SB/rtmp"; mkdir -p "$DEVFLOW_RUN_HOME"
run_dir_here

parent="$(dirname "$RUN_DIR")"
old="$parent/devflow-run.gctestold"      # old + idle  → must be pruned
fresh="$parent/devflow-run.gctestfresh"  # recent      → must be kept
mkdir -p "$old" "$fresh"
touch -t 200001010000 "$old"             # ancient dir mtime (portable BSD/GNU -t)
touch -t 200001010000 "$RUN_DIR"         # age the current dir too. TWO redundant guards keep it: secure_dir
                                         # re-touch()es RUN_DIR fresh on every invocation (before GC runs),
                                         # AND GC excludes it by basename. Either alone suffices, and the
                                         # re-touch always fires first — so the assert below can only prove
                                         # the OUTCOME (current dir survives), not that basename fires alone.
# $fresh keeps its just-created mtime (now), standing in for a still-relevant recent run.

# default TTL (7): only the old sibling is reclaimed; fresh and current survive.
out="$(cd "$REPO_FX" && bash "$RUNNER" dir)"; rc=$?
is  "$rc" "0"           "dir succeeds with GC enabled"
has "$out" "RUN_DIR=$RUN_DIR" "...and still emits the project's RUN_DIR"
ok "[ ! -e '$old' ]"   "GC pruned the stale sibling (mtime past TTL)"
ok "[ -d '$fresh' ]"   "GC kept the fresh sibling (mtime inside TTL)"
ok "[ -d '$RUN_DIR' ]" "GC never prunes the current RUN_DIR even when pre-aged (redundant guards: re-touch keeps mtime fresh AND basename excludes self — asserts the outcome, not either guard alone)"

# a non-numeric DEVFLOW_RUN_TTL_DAYS disables GC — belt for 'never surprise-delete'.
mkdir -p "$old"; touch -t 200001010000 "$old"
out2="$(cd "$REPO_FX" && DEVFLOW_RUN_TTL_DAYS=off bash "$RUNNER" dir)"; rc2=$?
is "$rc2" "0"        "dir succeeds with GC disabled"
ok "[ -d '$old' ]"   "non-numeric DEVFLOW_RUN_TTL_DAYS disables GC (stale sibling survives)"

cleanup_sandbox           # rm -rf "$SB" reclaims $DEVFLOW_RUN_HOME=$SB/rtmp and every dir under it
report
