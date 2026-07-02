#!/usr/bin/env bash
# The extractor is the harness's trust anchor — it pulls the REAL bash out of the .md so tests run
# current code. Guard its own core invariant: exactly ONE ```bash block per mapped section. Without
# a test here, reverting extract-bash.py to the old concatenate-blocks behavior (which would let a
# stray illustrative block be sourced as runner code) leaves the whole suite green.
set -u
. "$LIB/assert.sh"

PY="$DEVFLOW_TEST_REPO/test/lib/extract-bash.py"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/devflow-extract.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# Fixture: two ```bash blocks under ONE mapped heading (## Section B) -> must be rejected. The
# duplicate check fires mid-parse, before the missing-sections check, so the fixture need not be
# otherwise complete.
{
  printf '## Section B\n\n'
  printf '```bash\necho one\n```\n\n'
  printf '```bash\necho two\n```\n'
} > "$TMP/dup.md"

err="$(python3 "$PY" "$TMP/dup.md" "$TMP/out" 2>&1 >/dev/null)"; rc=$?
isnt "$rc" "0"              "duplicate bash block under one section is rejected (non-zero exit)"
has  "$err" "more than one" "error explains the duplicate-block problem"
has  "$err" "section 'b'"   "error names the offending mapped section"

report
