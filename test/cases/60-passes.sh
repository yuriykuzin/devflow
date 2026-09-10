#!/usr/bin/env bash
# Pass budget (execution profiles: review.max_passes): init/reserve/close/status/complete
# subcommands and the state files they share. `init` fixes the budget for the deliverable's
# life (idempotent unless the value changes); `reserve` refuses to run before `init` rather
# than defaulting to unlimited; it must charge each distinct --call-id exactly once and refuse
# once the budget is spent; `complete` records the no-double-review checkpoint once every
# reservation has been closed. All of it must be wiped by `dir --fresh` like any other RUN_DIR
# artifact (no special-casing).
set -u
. "$LIB/assert.sh"; . "$LIB/sandbox.sh"

mk_sandbox
run_dir_here
p(){ ( cd "$REPO_FX" && bash "$RUNNER" passes "$@" ); }

# (1) reserve before init -> BUDGET_NOT_INITIALIZED, exit 2 (never unlimited by accident).
out0="$(p reserve --deliverable d1 --call-id c0)"; rc0=$?
is "$rc0" "2" "reserve before init -> exit 2"
is "$out0" "BUDGET_NOT_INITIALIZED" "...with the exact BUDGET_NOT_INITIALIZED line"

# (2) init fixes the budget.
p init --deliverable d1 --max 2 >/dev/null; rci=$?
is "$rci" "0" "init (max 2) exits 0"

# (3) re-init with the SAME value is idempotent.
p init --deliverable d1 --max 2 >/dev/null; rci2=$?
is "$rci2" "0" "re-init with the same value stays exit 0"

# (4) re-init with a DIFFERENT value -> BUDGET_ALREADY_SET, exit 8 (budget is fixed for life).
outi3="$(p init --deliverable d1 --max 9)"; rci3=$?
is "$rci3" "8" "re-init with a different value -> exit 8"
is "$outi3" "BUDGET_ALREADY_SET max=2" "...naming the already-set max"

# (5) reserve x2 (max 2, from init) succeed, third is BUDGET_EXHAUSTED with exit 3.
out1="$(p reserve --deliverable d1 --call-id c1)"; rc1=$?
is "$rc1" "0" "1st reserve (max 2) exits 0"
has "$out1" "remaining=1" "...and reports 1 pass remaining"

out2="$(p reserve --deliverable d1 --call-id c2)"; rc2=$?
is "$rc2" "0" "2nd reserve (max 2) exits 0"
has "$out2" "remaining=0" "...and reports 0 passes remaining"

out3="$(p reserve --deliverable d1 --call-id c3)"; rc3=$?
is "$rc3" "3" "3rd reserve exceeds the budget -> exit 3"
is "$out3" "BUDGET_EXHAUSTED used=2 max=2" "...with the exact exhaustion line"

# (6) re-reserving the same call-id is a no-op: no double charge, exact field-1 match.
out4="$(p reserve --deliverable d1 --call-id c1)"; rc4=$?
is "$rc4" "0" "re-reserving an already-reserved call-id still exits 0"
has "$out4" "remaining=0" "...without charging a second pass (still 0 remaining, not negative)"

# (6b) a call-id that is only a SUBSTRING of a reserved one must NOT match (exact field-1 match).
outsub="$(p reserve --deliverable d1 --call-id c)"; rcsub=$?
is "$rcsub" "3" "a call-id that's a substring of an existing one is not treated as reserved -> still exhausted"

# (7) status reports used/max/open/done/scope (scope is "-" until `complete` records one).
st="$(p status --deliverable d1)"
is "$st" "used=2 max=2 open=c1,c2 done=no scope=-" "status reports used, max, open call ids, done=no, scope=-"

# (8) closing a call keeps it counted in `used` but drops it from `open`.
p close --deliverable d1 --call-id c1 >/dev/null; rcclose=$?
is "$rcclose" "0" "close exits 0"
st2="$(p status --deliverable d1)"
is "$st2" "used=2 max=2 open=c2 done=no scope=-" "closing c1 removes it from open, used stays 2, scope still -"

# (8b) re-reserving a call-id that is already CLOSED (field 3 != "-") is CALL_ALREADY_CLOSED,
# exit 9 -- distinct from re-reserving one that's still open (still exit 0, see (6)).
outclosed="$(p reserve --deliverable d1 --call-id c1)"; rcclosed=$?
is "$rcclosed" "9" "reserve on a closed call-id is CALL_ALREADY_CLOSED"
is "$outclosed" "CALL_ALREADY_CLOSED call-id=c1" "...naming the closed call-id"

# (9) complete refuses while an open call-id remains.
outc1="$(p complete --deliverable d1 --scope sha123 --verdict clean)"; rcc1=$?
is "$rcc1" "1" "complete with an open call id -> exit 1"

# (10) closing the remaining call id lets complete succeed; status then reports done=yes and
# the recorded scope digest.
p close --deliverable d1 --call-id c2 >/dev/null
outc2="$(p complete --deliverable d1 --scope sha123 --verdict clean)"; rcc2=$?
is "$rcc2" "0" "complete with no open call ids -> exit 0"
st3="$(p status --deliverable d1)"
is "$st3" "used=2 max=2 open= done=yes scope=sha123" "status reports done=yes and the completed scope"

# (11) max=0 (via init) is unlimited: always reserves, regardless of how many calls came before.
p init --deliverable d0 --max 0 >/dev/null
p reserve --deliverable d0 --call-id x1 >/dev/null
p reserve --deliverable d0 --call-id x2 >/dev/null
out5="$(p reserve --deliverable d0 --call-id x3)"; rc5=$?
is "$rc5" "0" "max=0 never exhausts the budget"
has "$out5" "remaining=unlimited" "...and reports remaining as unlimited"

# (12) a distinct deliverable has an independent budget, and its own status starts fresh.
st_before="$(p status --deliverable d2)"
is "$st_before" "used=0 max=- open= done=no scope=-" "an un-init'd deliverable reports max=- (sidecar missing)"
p init --deliverable d2 --max 1 >/dev/null
out6="$(p reserve --deliverable d2 --call-id z1)"; rc6=$?
is "$rc6" "0" "a different deliverable starts with its own fresh budget"
st3b="$(p status --deliverable d2)"
is "$st3b" "used=1 max=1 open=z1 done=no scope=-" "...tracked independently of d1/d0"

# (13) `dir --fresh` wipes the pass-budget state like any other RUN_DIR artifact.
( cd "$REPO_FX" && bash "$RUNNER" dir --fresh ) >/dev/null
st4="$(p status --deliverable d1)"
is "$st4" "used=0 max=- open= done=no scope=-" "dir --fresh clears prior pass-budget state (no special-casing)"

cleanup_sandbox
report
