#!/usr/bin/env bash
# `dir`: emits the deterministic RUN_DIR for this project, created 0700. `dir --fresh` wipes it
# (a new run must not inherit a prior feature's phase session files), and re-emits a clean
# RUN_DIR. Devflow asserts neither ownership nor non-symlink-ness — a hostile local uid is out
# of scope for a personal tool — so the checks below are hygiene, not an enforced guarantee.
set -u
. "$LIB/assert.sh"; . "$LIB/sandbox.sh"

mk_sandbox
run_dir_here

has "$(cd "$REPO_FX" && bash "$RUNNER" dir)" "RUN_DIR=$RUN_DIR" "dir emits the project's RUN_DIR"
ok "[ -d '$RUN_DIR' ]" "RUN_DIR exists after dir"

# hygiene: RUN_DIR is created 0700 and, on a normal machine, as a real directory.
perm="$(stat -c %a "$RUN_DIR" 2>/dev/null || stat -f %Lp "$RUN_DIR" 2>/dev/null)"
is "${perm: -3}" "700" "RUN_DIR created with mode 700"
ok "[ ! -L '$RUN_DIR' ]" "RUN_DIR is a real directory, not a symlink"

# determinism: a second `dir` from the same repo lands on the exact same path (hash of root).
out2="$(cd "$REPO_FX" && bash "$RUNNER" dir)"
is "$(printf '%s\n' "$out2" | sed -n 's/^RUN_DIR=//p')" "$RUN_DIR" "dir is deterministic (same RUN_DIR on re-invocation)"

# --fresh wipes stale contents (e.g. a prior feature's session files) then re-secures.
printf 'stale\n' > "$RUN_DIR/plan-review.session"
out3="$(cd "$REPO_FX" && bash "$RUNNER" dir --fresh)"; rc3=$?
is "$rc3" "0" "dir --fresh succeeds on an idle run dir"
is "$(printf '%s\n' "$out3" | sed -n 's/^RUN_DIR=//p')" "$RUN_DIR" "dir --fresh re-emits the same RUN_DIR"
ok "[ ! -e '$RUN_DIR/plan-review.session' ]" "dir --fresh cleared the stale session file"
perm="$(stat -c %a "$RUN_DIR" 2>/dev/null || stat -f %Lp "$RUN_DIR" 2>/dev/null)"
is "${perm: -3}" "700" "dir --fresh re-secures RUN_DIR to mode 700"

cleanup_sandbox
report
