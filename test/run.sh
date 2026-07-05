#!/usr/bin/env bash
# devflow harness: drives the real scripts/devflow-runner.sh against a deterministic fake
# codex in throwaway sandboxes. Offline, no API token, ~seconds.
#
#   bash test/run.sh            # run all cases
#   bash test/run.sh 30 60      # run only cases matching these prefixes
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
export RUNNER="$REPO/scripts/devflow-runner.sh"
[ -f "$RUNNER" ] || { echo "cannot find $RUNNER" >&2; exit 2; }
bash -n "$RUNNER" || { echo "bash -n failed on $(basename "$RUNNER")" >&2; exit 1; }
echo "== bash -n: devflow-runner.sh OK =="

chmod +x "$HERE/lib/fake-codex" "$HERE/lib/fake-codex-ok" "$HERE/lib/fake-claude" 2>/dev/null || true

export LIB="$HERE/lib"
export DEVFLOW_TEST_REPO="$REPO"

sel=("$@")
matches(){ [ ${#sel[@]} -eq 0 ] && return 0; for p in "${sel[@]}"; do case "$1" in "$p"*) return 0;; esac; done; return 1; }

fail=0; total_c=0
for c in "$HERE"/cases/*.sh; do
  base="$(basename "$c")"
  matches "$base" || continue
  total_c=$((total_c+1))
  echo "== $base =="
  out="$(bash "$c" 2>&1)"; rc=$?
  printf '%s\n' "$out"
  if [ "$rc" -ne 0 ]; then
    fail=1; echo "   ($base FAILED, rc=$rc)"
  elif ! printf '%s\n' "$out" | grep -Eq -- '-- [0-9]+ passed, [0-9]+ failed --'; then
    fail=1; echo "   ($base FAILED — never reached report(); no assertions ran)"
  fi
done

echo
if [ "$total_c" -eq 0 ]; then
  echo "NO CASES MATCHED${sel:+ (filter: ${sel[*]})}"; exit 1
fi
if [ "$fail" -eq 0 ]; then echo "ALL PASS ($total_c case files)"; else echo "SOME FAILED"; fi
exit "$fail"
