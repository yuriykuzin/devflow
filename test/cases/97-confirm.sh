#!/usr/bin/env bash
# Confirmation rounds: outside the review budget, once it is spent, and NOT capped at one — every
# fix wave that changed the tree gets another diff-only round, until the no-progress rule stops the
# run (CONFIRM_STALLED after 2 consecutive rounds that left the open blocker count unchanged or
# higher). Refused while budget remains or when unlimited; recorded in the tsv yet never counted in
# `used`; must be closed before `complete`. Plus scope-digest --tree-out: a tree object whose diff
# against a later one shows tracked edits AND new untracked files, without touching the real index.
set -u
. "$LIB/assert.sh"; . "$LIB/sandbox.sh"

mk_sandbox
run_dir_here
p(){ ( cd "$REPO_FX" && bash "$RUNNER" passes "$@" ); }

# (1) confirm is refused while budget remains, and when the budget is unlimited; --open is required.
p init --deliverable d2 --max 2 >/dev/null
out="$(p reserve --deliverable d2 --call-id k --confirm --open 1)"; rc=$?
is "$rc" "4" "confirm with budget left -> exit 4"
has "$out" "CONFIRM_NOT_NEEDED" "...CONFIRM_NOT_NEEDED"
p init --deliverable d0 --max 0 >/dev/null
p reserve --deliverable d0 --call-id k --confirm --open 1 >/dev/null; is "$?" "4" "confirm on an unlimited budget -> exit 4"
p reserve --deliverable d2 --call-id k --confirm >/dev/null 2>&1; is "$?" "2" "confirm without --open -> exit 2 (usage)"
p reserve --deliverable d2 --call-id k --open 1 >/dev/null 2>&1; is "$?" "2" "--open without --confirm -> exit 2 (usage)"

# (2) spend the budget (max 1), then: normal reserve exhausted, first confirm round allowed.
p init --deliverable d --max 1 >/dev/null
p reserve --deliverable d --call-id r1 >/dev/null; p close --deliverable d --call-id r1
p reserve --deliverable d --call-id r2 >/dev/null; is "$?" "3" "budget spent -> normal reserve exit 3"
out="$(p reserve --deliverable d --call-id final-review-confirm-1 --confirm --open 2)"; rc=$?
is "$rc" "0" "first confirm round after exhaustion -> exit 0"
has "$out" "CONFIRM_RESERVED" "...CONFIRM_RESERVED"

# (3) counted separately from used.
st="$(p status --deliverable d)"
is "$st" "used=1 max=1 open=final-review-confirm-1 done=no scope=- confirm=final-review-confirm-1" \
  "status: used unchanged by the confirm, which is listed separately"
out="$(p reserve --deliverable d --call-id r3)"; rc=$?
is "$rc" "3" "a normal reserve is still exhausted after the confirm"
has "$out" "used=1 max=1" "...and the budget line does not count the confirm"

# (4) replay of the same open confirm id is a no-op; complete refuses while it is open.
p reserve --deliverable d --call-id final-review-confirm-1 --confirm --open 2 >/dev/null; is "$?" "0" "re-reserving the same open confirm id -> no-op exit 0"
p complete --deliverable d --scope s1 --verdict clean >/dev/null 2>&1; is "$?" "1" "complete refuses while the confirm call is open"

# (5) close: a confirm round must say how many blockers are still open after it; an ordinary call
# must not take --open; a closed round replays as CALL_ALREADY_CLOSED.
p close --deliverable d --call-id final-review-confirm-1 >/dev/null 2>&1; is "$?" "2" "close of a confirm without --open -> exit 2"
p close --deliverable d --call-id r1 --open 0 >/dev/null 2>&1; is "$?" "2" "close of an ordinary call with --open -> exit 2"
p close --deliverable d --call-id final-review-confirm-1 --open 1; is "$?" "0" "round 1 closed with 1 blocker still open (2 -> 1: progress)"
p reserve --deliverable d --call-id final-review-confirm-1 --confirm --open 2 >/dev/null; is "$?" "9" "closed confirm round replayed -> exit 9"

# (6) round 2 (1 -> 1: no progress) and round 3 (1 -> 1: no progress). Both are allowed: the run
# only stops after two CONSECUTIVE rounds without progress, and round 1 was progress.
out="$(p reserve --deliverable d --call-id final-review-confirm-2 --confirm --open 1)"; rc=$?
is "$rc" "0" "second confirm round (after progress) -> exit 0"
has "$out" "CONFIRM_RESERVED call-id=final-review-confirm-2" "...CONFIRM_RESERVED for round 2"
p close --deliverable d --call-id final-review-confirm-2 --open 1
out="$(p reserve --deliverable d --call-id final-review-confirm-3 --confirm --open 1)"; rc=$?
is "$rc" "0" "third confirm round (one no-progress round so far) -> exit 0"
p close --deliverable d --call-id final-review-confirm-3 --open 1

# (7) no-progress rule: after two consecutive rounds that did not reduce the open count, the next
# confirm is refused with CONFIRM_STALLED (exit 3), and no call is recorded for it.
out="$(p reserve --deliverable d --call-id final-review-confirm-4 --confirm --open 1)"; rc=$?
is "$rc" "3" "fourth confirm round after two no-progress rounds -> exit 3"
has "$out" "CONFIRM_STALLED" "...with the CONFIRM_STALLED stop line"
hasnt "$(p status --deliverable d)" "final-review-confirm-4" "...and the refused round is not recorded"

# (8) ordinary reserve stays exhausted throughout; complete works once every call is closed, and
# .done counts only budgeted passes.
out="$(p reserve --deliverable d --call-id r4)"; is "$?" "3" "a normal reserve is still exhausted after all confirm rounds"
p complete --deliverable d --scope s1 --verdict clean >/dev/null; is "$?" "0" "complete succeeds once every confirm round is closed"
has "$(cat "$RUN_DIR/passes-d.done")" "closed=1" "...and .done counts only budgeted passes"

# (9) a new confirm round is refused while the previous one is still open (CONFIRM_STILL_OPEN).
p init --deliverable d3 --max 1 >/dev/null
p reserve --deliverable d3 --call-id q1 >/dev/null; p close --deliverable d3 --call-id q1
p reserve --deliverable d3 --call-id c1 --confirm --open 1 >/dev/null
out="$(p reserve --deliverable d3 --call-id c2 --confirm --open 1)"; rc=$?
is "$rc" "3" "a second confirm round while the first is open -> exit 3"
has "$out" "CONFIRM_STILL_OPEN call-id=c1" "...CONFIRM_STILL_OPEN naming the open round"

# (10) scope-digest --tree-out: diff between two recorded trees = the changes since review.
B="$(git -C "$REPO_FX" rev-parse HEAD)"
d1="$( ( cd "$REPO_FX" && bash "$RUNNER" scope-digest --base "$B" --tree-out "$SB/t1" ) )"
printf 'v2\n' > "$REPO_FX/a.txt"; printf 'n\n' > "$REPO_FX/new.txt"
( cd "$REPO_FX" && bash "$RUNNER" scope-digest --base "$B" --tree-out "$SB/t2" ) >/dev/null
names="$(git -C "$REPO_FX" diff --name-only "$(cat "$SB/t1")" "$(cat "$SB/t2")")"
has "$names" "a.txt" "tree diff shows the tracked edit"
has "$names" "new.txt" "...and the new untracked file"
hasnt "$names" "b.txt" "...and nothing unchanged"
has "$(git -C "$REPO_FX" status --porcelain)" "?? new.txt" "the real index is untouched (new.txt still untracked)"
ok "printf '%s' '$d1' | grep -Eq '^[0-9a-f]{16}\$'" "--tree-out still prints the plain digest on stdout"

# (11) DG-01: a report in output_dir is not part of a recorded tree.
mkdir -p "$REPO_FX/docs/devflow/reports"; printf 'rep\n' > "$REPO_FX/docs/devflow/reports/r.md"
( cd "$REPO_FX" && bash "$RUNNER" scope-digest --base "$B" --tree-out "$SB/t3" ) >/dev/null
hasnt "$(git -C "$REPO_FX" diff --name-only "$(cat "$SB/t2")" "$(cat "$SB/t3")")" "r.md" "output_dir reports are excluded from --tree-out"

# (12) N2: a --tree-out that cannot be written warns but still prints the digest (exit 0).
d4="$( ( cd "$REPO_FX" && bash "$RUNNER" scope-digest --base "$B" --tree-out "$SB/no-such-dir/t" 2>/dev/null ) )"
ok "printf '%s' '$d4' | grep -Eq '^[0-9a-f]{16}\$'" "--tree-out failure still prints the digest (N2)"

# (13) DG-02/B4: confirm-base is frozen per confirm call, so a replay of the same round after the
# dispatch overwrote reviewed.gittree still diffs against the PRE-round state (never
# current-vs-current), and the next round starts from what the previous round promoted.
cb(){ ( cd "$REPO_FX" && bash "$RUNNER" confirm-base "$@" ); }
cb --phase final-review --deliverable d --call-id c1 >/dev/null; is "$?" "1" "confirm-base with no reviewed gittree -> exit 1 (NO_REVIEWED_TREE)"
cp "$SB/t1" "$RUN_DIR/final-review-reviewed.gittree"
out="$(cb --phase final-review --deliverable d --call-id c1)"; is "$?" "0" "confirm-base freezes the last reviewed gittree for the round"
cp "$SB/t2" "$RUN_DIR/final-review-reviewed.gittree"     # what the confirm dispatch does (overwrite)
cb --phase final-review --deliverable d --call-id c1 >/dev/null       # the replay after compaction
is "$(cat "$RUN_DIR/final-review-confirm-base-d-c1.gittree")" "$(cat "$SB/t1")" "replay keeps the pre-round base (only written if absent)"
has "$(git -C "$REPO_FX" diff --name-only "$(cat "$RUN_DIR/final-review-confirm-base-d-c1.gittree")" "$(cat "$RUN_DIR/final-review-reviewed.gittree")")" "a.txt" "...so the replayed confirm diff is not empty"
cb --phase final-review --deliverable d --call-id c2 >/dev/null
is "$(cat "$RUN_DIR/final-review-confirm-base-d-c2.gittree")" "$(cat "$SB/t2")" "the next round's base is the tree the previous round promoted"
cb --phase final-review --deliverable d >/dev/null 2>&1; is "$?" "2" "confirm-base without --call-id -> exit 2 (usage)"
rm -f "$RUN_DIR/final-review-reviewed.gittree"; cp "$SB/t2" "$RUN_DIR/impl-review-reviewed.gittree"
out="$(cb --phase final-review --deliverable e --call-id c1 --fallback-phase impl-review)"; is "$?" "0" "B2: confirm-base falls back to the impl-review gittree"
is "$(cat "$RUN_DIR/final-review-confirm-base-e-c1.gittree")" "$(cat "$SB/t2")" "...and freezes that one"

cleanup_sandbox
report
