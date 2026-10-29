#!/usr/bin/env bash
# gate: DONE requires (a) the last recorded reviewed digest == the current tree, and (b) a checks
# pass on that same tree and base. Covers the re-review-after-fix guard (edit after review ->
# unreviewed-changes until a new review is recorded) and every checks reason.
set -u
. "$LIB/assert.sh"; . "$LIB/sandbox.sh"

mk_sandbox
run_dir_here
B="$(git -C "$REPO_FX" rev-parse HEAD)"
g(){ ( cd "$REPO_FX" && bash "$RUNNER" gate "$@" ); }
c(){ ( cd "$REPO_FX" && bash "$RUNNER" checks run "$@" ); }
rec(){ ( cd "$REPO_FX" && bash "$RUNNER" scope-digest --base "$B" ) > "$RUN_DIR/$1-reviewed.digest"; }
jcfg(){ python3 -c 'import json,sys; json.dump({"checks":{"commands":sys.argv[2:]}}, open(sys.argv[1],"w"))' "$@"; }
jcfg "$SB/ok.json" "true"; jcfg "$SB/bad.json" "false"; jcfg "$SB/none.json"

# (1) nothing recorded at all.
out="$(g --phase final-review --base "$B")"; rc=$?
is "$rc" "1" "no review, no checks -> blocked (exit 1)"
has "$out" "REVIEWED=missing" "...REVIEWED=missing"
has "$out" "REASON=no-review-recorded" "...REASON=no-review-recorded"
has "$out" "REASON=checks-missing" "...REASON=checks-missing"

# (2) review recorded + checks pass on the same tree/base -> ok.
rec final-review; c --config "$SB/ok.json" --base "$B" >/dev/null
out="$(g --phase final-review --base "$B")"; rc=$?
is "$rc" "0" "reviewed + checks pass on this tree -> exit 0"
has "$out" "GATE=ok" "...GATE=ok"
has "$out" "REVIEWED=fresh" "...REVIEWED=fresh"
has "$out" "CHECKS=pass" "...CHECKS=pass"

# (3) a fix after the review -> unreviewed-changes (and the checks are stale too).
printf 'v2\n' > "$REPO_FX/a.txt"
out="$(g --phase final-review --base "$B")"; rc=$?
is "$rc" "1" "edit after the last review -> blocked"
has "$out" "REVIEWED=stale" "...REVIEWED=stale"
has "$out" "REASON=unreviewed-changes" "...REASON=unreviewed-changes"
has "$out" "REASON=checks-stale" "...REASON=checks-stale"

# (4) one more review pass + re-run checks on the fixed tree -> ok again.
rec final-review; c --config "$SB/ok.json" --base "$B" >/dev/null
out="$(g --phase final-review --base "$B")"; rc=$?
is "$rc" "0" "re-review + re-run checks after the fix -> ok"

# (5) failing checks.
c --config "$SB/bad.json" --base "$B" >/dev/null
out="$(g --phase final-review --base "$B")"; rc=$?
is "$rc" "1" "checks failed -> blocked"
has "$out" "REASON=checks-failed" "...REASON=checks-failed"
hasnt "$out" "REASON=unreviewed-changes" "...the review itself is still fresh"

# (6) no checks configured or discovered.
c --config "$SB/none.json" --base "$B" >/dev/null
out="$(g --phase final-review --base "$B")"; rc=$?
is "$rc" "1" "no checks could run -> blocked"
has "$out" "REASON=checks-not-run" "...REASON=checks-not-run"

# (7) checks taken against a different base are stale for this gate.
c --config "$SB/ok.json" >/dev/null
out="$(g --phase final-review --base "$B")"; rc=$?
is "$rc" "1" "checks run with another base -> blocked"
has "$out" "REASON=checks-stale" "...REASON=checks-stale"

# (8) the impl phase reads impl-review-reviewed.digest (uniform <phase>-reviewed.digest naming).
rec impl-review; c --config "$SB/ok.json" --base "$B" >/dev/null
out="$(g --phase impl-review --base "$B")"; rc=$?
is "$rc" "0" "impl-review phase gates on impl-review-reviewed.digest"

# (9) usage.
g --base "$B" >/dev/null 2>&1; is "$?" "2" "missing --phase -> exit 2"
g --phase ../x >/dev/null 2>&1; is "$?" "2" "phase with a path separator -> exit 2"

# (10) DG-01/B1: a report written into output_dir AFTER the review must not make the gate stale,
# and the scope digest used by Phase 3's SKIP_PHASE3 comparison must not move either.
rec final-review; c --config "$SB/ok.json" --base "$B" >/dev/null
d_before="$( cd "$REPO_FX" && bash "$RUNNER" scope-digest --base "$B" )"
mkdir -p "$REPO_FX/docs/devflow/reports"; printf 'report\n' > "$REPO_FX/docs/devflow/reports/2026-10-22-x-review.md"
out="$(g --phase final-review --base "$B")"; rc=$?
is "$rc" "0" "a report saved into output_dir after review does not make the gate stale"
has "$out" "REVIEWED=fresh" "...REVIEWED=fresh"
is "$( cd "$REPO_FX" && bash "$RUNNER" scope-digest --base "$B" )" "$d_before" "...and the scope digest (Phase 3 reuse comparison) still matches"
printf '{"output_dir":"out/reports"}' > "$RUN_DIR/resolved-config.json"
mkdir -p "$REPO_FX/out/reports"; printf 'r\n' > "$REPO_FX/out/reports/r.md"
d_after_cfg="$( cd "$REPO_FX" && bash "$RUNNER" scope-digest --base "$B" )"
printf 'r2\n' >> "$REPO_FX/out/reports/r.md"
is "$( cd "$REPO_FX" && bash "$RUNNER" scope-digest --base "$B" )" "$d_after_cfg" "...a custom output_dir from resolved-config.json is excluded too"
rm -f "$RUN_DIR/resolved-config.json"
printf 'v3\n' > "$REPO_FX/a.txt"
g --phase final-review --base "$B" >/dev/null; is "$?" "1" "...but a real edit outside output_dir still makes it stale"
printf 'v2\n' > "$REPO_FX/a.txt"

# (11) B2: --fallback-phase reads the impl record only when the final-review record is MISSING.
rm -f "$RUN_DIR/final-review-reviewed.digest"; rec impl-review; c --config "$SB/ok.json" --base "$B" >/dev/null
g --phase final-review --base "$B" >/dev/null; is "$?" "1" "no final-review record, no fallback -> blocked"
out="$(g --phase final-review --base "$B" --fallback-phase impl-review)"; rc=$?
is "$rc" "0" "--fallback-phase impl-review uses the impl record when final-review has none"
has "$out" "REVIEWED=fresh" "...REVIEWED=fresh"

# (12) DG-06 regression: gate ok -> edit a tracked source file afterwards -> the live gate blocks.
# Finalize always runs the live gate, so an edit after the last review can never end DONE.
g --phase impl-review --base "$B" >/dev/null; is "$?" "0" "gate ok before the late edit"
printf 'late edit\n' >> "$REPO_FX/a.txt"
out="$(g --phase impl-review --base "$B")"; rc=$?
is "$rc" "1" "edit after a passing gate -> blocked"
has "$out" "REVIEWED=stale" "...REVIEWED=stale"
has "$out" "REASON=unreviewed-changes" "...REASON=unreviewed-changes"

cleanup_sandbox
report
