#!/usr/bin/env bash
# Bootstrap reuse: a second bootstrap call with nothing changed reuses the same RUN_DIR;
# a reaped RUN_DIR forces a fresh bootstrap; a changed config file invalidates it; a foreign
# env (other repo/plugin) is rejected by devflow_env_valid.
set -u
. "$LIB/assert.sh"; . "$LIB/sandbox.sh"

mk_sandbox
bootstrap_here
RUN_DIR1="$RUN_DIR"

# (1) Bootstrap again with nothing changed -> same RUN_DIR, REUSED=1, run.env untouched.
# GNU stat (`-c`) tried FIRST, matching the runner's own devflow_cfg_fingerprint convention:
# on Linux, `stat -f` means --file-system and can succeed with unrelated filesystem output,
# which would make this mtime check false-green instead of failing loudly.
before_mtime="$(stat -c %Y "$RUN_DIR1/run.env" 2>/dev/null || stat -f %m "$RUN_DIR1/run.env")"
out="$(cd "$REPO_FX" && bash "$RUNNER" bootstrap)"
is "$(printf '%s\n' "$out" | sed -n 's/^RUN_DIR=//p')" "$RUN_DIR1" "reuse keeps the same RUN_DIR (no fresh bootstrap)"
is "$(printf '%s\n' "$out" | sed -n 's/^REUSED=//p')" "1" "unchanged config -> REUSED=1"
after_mtime="$(stat -c %Y "$RUN_DIR1/run.env" 2>/dev/null || stat -f %m "$RUN_DIR1/run.env")"
is "$after_mtime" "$before_mtime" "run.env not rewritten on a reused bootstrap"

# (2) Reaped RUN_DIR: deleting it must force a fresh bootstrap, not an error.
rm -rf "$RUN_DIR1"
out="$(cd "$REPO_FX" && bash "$RUNNER" bootstrap)"
is "$(printf '%s\n' "$out" | sed -n 's/^RUN_DIR=//p')" "$RUN_DIR1" "reaped RUN_DIR is rebuilt at the same deterministic path"
is "$(printf '%s\n' "$out" | sed -n 's/^REUSED=//p')" "0" "reaped RUN_DIR forces a fresh bootstrap (REUSED=0)"
ok "[ -f '$RUN_DIR1/run.env' ]" "run.env exists again after rebuild"

# (3) Change a tracked config file's mtime -> fingerprint mismatch -> fresh bootstrap.
touch -t 210012312359.59 "$REPO_FX/.devflow.yaml"
out="$(cd "$REPO_FX" && bash "$RUNNER" bootstrap)"
is "$(printf '%s\n' "$out" | sed -n 's/^REUSED=//p')" "0" "changed config invalidates the env (fingerprint mismatch)"

# (4) Foreign env (different project root + plugin) must not validate. White-box: source
# the script (guarded main means sourcing does NOT auto-dispatch) to call devflow_env_valid.
foreign="$SB/foreign.env"
{
  echo "DEVFLOW_PROJECT_ROOT=/nowhere/else"
  echo "DEVFLOW_PLUGIN_DIR=/nowhere/plugin"
  echo "DEVFLOW_CFG_FINGERPRINT=whatever"
} > "$foreign"
foreign_rc="$( cd "$REPO_FX" && . "$RUNNER" >/dev/null 2>&1
  if devflow_env_valid "$foreign"; then echo 0; else echo 1; fi )"
is "$foreign_rc" "1" "foreign env (other root/plugin) rejected"

# (5) `--fresh` wipes stale session state, not just config — a leftover session file from
# an unrelated earlier task must not survive into a deliberately-fresh run.
out="$(cd "$REPO_FX" && bash "$RUNNER" bootstrap)"
RUN_DIR2="$(printf '%s\n' "$out" | sed -n 's/^RUN_DIR=//p')"
printf 'stale_session_id_from_last_week\n' > "$RUN_DIR2/plan-review.session"
ok "[ -s '$RUN_DIR2/plan-review.session' ]" "stale session file exists before --fresh"
cd "$REPO_FX" && bash "$RUNNER" bootstrap --fresh >/dev/null
ok "[ ! -f '$RUN_DIR2/plan-review.session' ]" "bootstrap --fresh clears the stale session file (rm -rf'd with the rest of RUN_DIR)"

# (6) A same-day second feature with a DIFFERENT --slug must not inherit the first
# feature's phase session files — a mismatched slug has to wipe RUN_DIR, not just
# rewrite run.env, or the second feature's skill steps would silently resume the first
# feature's plan-review/impl-review conversation.
out="$(cd "$REPO_FX" && bash "$RUNNER" bootstrap --slug first-feature)"
RUN_DIR3="$(printf '%s\n' "$out" | sed -n 's/^RUN_DIR=//p')"
printf 'stale_session_id_from_first_feature\n' > "$RUN_DIR3/plan-review.session"
ok "[ -s '$RUN_DIR3/plan-review.session' ]" "first feature's session file exists before slug switch"
cd "$REPO_FX" && bash "$RUNNER" bootstrap --slug second-feature >/dev/null
ok "[ ! -f '$RUN_DIR3/plan-review.session' ]" "bootstrap with a different --slug wipes the prior feature's stale session file"

cleanup_sandbox
report
