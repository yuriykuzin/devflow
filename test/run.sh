#!/usr/bin/env bash
# devflow harness: extract the real bash from cross-tool-runner.md, then drive it against
# a deterministic fake codex in throwaway sandboxes. Offline, no API token, ~seconds.
#
#   bash test/run.sh            # run all cases
#   bash test/run.sh 30 60      # run only cases matching these prefixes
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
RUNNER="$REPO/skills/using-devflow/references/cross-tool-runner.md"
[ -f "$RUNNER" ] || { echo "cannot find $RUNNER" >&2; exit 2; }

chmod +x "$HERE/lib/fake-codex" "$HERE/lib/fake-codex-ok" 2>/dev/null || true

WORK="$(mktemp -d "${TMPDIR:-/tmp}/devflow-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
export EXTRACTED="$WORK/extracted"
export LIB="$HERE/lib"
export DEVFLOW_TEST_REPO="$REPO"

echo "== extracting runner bash =="
python3 "$HERE/lib/extract-bash.py" "$RUNNER" "$EXTRACTED" || { echo "extraction failed" >&2; exit 1; }

# syntax gate on every extracted section before running anything
for f in "$EXTRACTED"/*.sh; do
  bash -n "$f" || { echo "bash -n failed on $(basename "$f")" >&2; exit 1; }
done
echo "   bash -n: all sections OK"

sel=("$@")
matches(){ [ ${#sel[@]} -eq 0 ] && return 0; for p in "${sel[@]}"; do case "$1" in "$p"*) return 0;; esac; done; return 1; }

fail=0; total_c=0
for c in "$HERE"/cases/*.sh; do
  base="$(basename "$c")"
  matches "$base" || continue
  total_c=$((total_c+1))
  echo "== $base =="
  bash "$c"; rc=$?
  [ "$rc" -ne 0 ] && { fail=1; echo "   ($base FAILED, rc=$rc)"; }
done

echo
if [ "$fail" -eq 0 ]; then echo "ALL PASS ($total_c case files)"; else echo "SOME FAILED"; fi
exit "$fail"
