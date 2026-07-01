#!/usr/bin/env bash
# Section A.2 reuse logic: a valid exported env is reused (no re-bootstrap); a changed
# config file invalidates it; a foreign env (other repo/plugin) is rejected.
set -u
. "$LIB/assert.sh"; . "$LIB/sandbox.sh"

mk_sandbox
bootstrap_here
RUN_DIR1="$RUN_DIR"
ENV1="$DEVFLOW_RUN_ENV"

# (1) Re-run the reuse decision with the valid exported env still present -> REUSE hit, same RUN_DIR.
REUSE=""
. "$EXTRACTED/a2.sh"
isnt "$REUSE" "" "valid exported env is reused"
is "$RUN_DIR" "$RUN_DIR1" "reuse keeps the same RUN_DIR (no fresh mktemp)"

# (2) Change a tracked config file's mtime -> fingerprint mismatch -> env invalid.
touch -t 210012312359.59 "$REPO_FX/.devflow.yaml"
REUSE=""
. "$EXTRACTED/a2.sh"
is "$REUSE" "" "changed config invalidates the env (fingerprint mismatch)"

# (3) Foreign env (different project root + plugin) must not validate.
foreign="$SB/foreign.env"
{
  echo "DEVFLOW_PROJECT_ROOT=/nowhere/else"
  echo "DEVFLOW_PLUGIN_DIR=/nowhere/plugin"
  echo "DEVFLOW_CFG_FINGERPRINT=whatever"
} > "$foreign"
if devflow_env_valid "$foreign"; then rc=0; else rc=1; fi
is "$rc" "1" "foreign env (other root/plugin) rejected"

cleanup_sandbox
report
