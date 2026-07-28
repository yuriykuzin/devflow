#!/usr/bin/env bash
# The freshness invariant: a .tree is promoted ONLY by a call that produced a real review, and
# freshness-check separates "still the reviewed tree" (0) from "edited since" (1) and from
# "nothing was ever reviewed" (2). The gate exists to stop the orchestrator certifying code no
# external reviewer read, so the failure paths matter more than the happy one.
set -u
# More poll slots than the other cases use: this file makes a dozen external calls, and calls
# here were seen to fail intermittently on a loaded machine. Slots only bound the WAIT, so a
# call that completes on the first poll costs the same as before — but be honest that this is
# margin, not a diagnosis: the flakiness is load-correlated, it also shows up in cases this
# changeset never touched, and its mechanism is not yet pinned down. Do not read a green suite
# under load as proof it is gone.
export DEVFLOW_POLL_SCHEDULE="1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1"
. "$LIB/assert.sh"; . "$LIB/sandbox.sh"

mk_sandbox
run_dir_here
cd "$REPO_FX"
fc(){ bash "$RUNNER" freshness-check "$@"; }
PF="$SB/prompt.txt"; printf 'review this\n' > "$PF"

# (1) no call yet -> no .tree -> exit 2. Absent evidence is not approval.
out="$(fc --phase final-review 2>&1)"; rc=$?
is "$rc" "2" "freshness-check with no .tree exits 2 (nothing reviewed)"
has "$out" "REASON=no-tree" "...and says why"

# (2) a successful call promotes the snapshot
printf 'dirty\n' >> a.txt          # something for the snapshot to capture
out="$(rx --phase final-review --prompt-file "$PF" --freshness 2>&1)"; rc=$?
is "$rc" "0" "run-external --freshness exits 0 on a usable review"
ok "[ -s '$RUN_DIR/final-review.tree' ]" "...and promotes .tree"
ok "[ ! -e '$RUN_DIR/final-review.tree.pending' ]" "...leaving no .tree.pending behind"
has "$out" "ROUND=1" "...and reports the round number"

# (3) unchanged tree -> fresh
out="$(fc --phase final-review 2>&1)"; rc=$?
is "$rc" "0" "unchanged tree is fresh"
has "$out" "FRESH=yes" "...reported as FRESH=yes"

# (4) editing an ALREADY-modified file must break it. This is the case a status-only snapshot
# would miss: HEAD and `git status --porcelain` read identical before and after.
before_status="$(git status --porcelain)"
printf 'dirtier\n' >> a.txt
is "$(git status --porcelain)" "$before_status" "the edit leaves git status unchanged"
out="$(fc --phase final-review 2>&1)"; rc=$?
is "$rc" "1" "content edit to an already-modified file is still detected"
has "$out" "REASON=tree-changed" "...reported as tree-changed"

# (5) an untracked file is part of the tree too — it is unreviewed code like any other.
printf 'new\n' > c.txt
out="$(rx --phase final-review --prompt-file "$PF" --freshness 2>&1)"
has "$out" "ROUND=2" "a second reviewed round increments the counter"
printf 'newer\n' > c.txt
is "$(fc --phase final-review >/dev/null 2>&1; echo $?)" "1" "editing an untracked file is detected"

# (6) a FAILED call must not promote anything — otherwise a killed call would leave a .tree
# matching the current tree and the check would "pass" on code nobody read.
rm -f "$RUN_DIR/final-review.tree"
out="$(FAKE_CODEX_MODE=auth rx --phase final-review --prompt-file "$PF" --freshness 2>&1)"; rc=$?
isnt "$rc" "0" "a failed call exits non-zero"
ok "[ ! -e '$RUN_DIR/final-review.tree' ]" "...promotes no .tree"
ok "[ ! -e '$RUN_DIR/final-review.tree.pending' ]" "...and cleans up .tree.pending"
is "$(fc --phase final-review >/dev/null 2>&1; echo $?)" "2" "so the check still reports nothing-reviewed"

# (7) --freshness-file snapshots one file (the plan flavour) instead of the worktree
PLAN="$SB/plan.md"; printf '# plan v1\n' > "$PLAN"
out="$(rx --phase plan-review --prompt-file "$PF" --freshness-file "$PLAN" 2>&1)"; rc=$?
is "$rc" "0" "run-external --freshness-file exits 0"
is "$(cat "$RUN_DIR/plan-review.tree")" "# plan v1" "...snapshots the named file, not the worktree"
is "$(fc --phase plan-review --file "$PLAN" >/dev/null 2>&1; echo $?)" "0" "unchanged plan is fresh"
printf '# plan v2\n' > "$PLAN"
is "$(fc --phase plan-review --file "$PLAN" >/dev/null 2>&1; echo $?)" "1" "edited plan is stale"

# (8) a missing --freshness-file is an argument error, not a silently empty snapshot
rx --phase plan2 --prompt-file "$PF" --freshness-file "$SB/nope.md" >/dev/null 2>&1
is "$?" "2" "--freshness-file with a missing path is rejected"
ok "[ ! -e '$RUN_DIR/plan2.tree.pending' ]" "...and writes no pending snapshot"

# (9) bad flags on freshness-check are rejected, not defaulted
is "$(fc >/dev/null 2>&1; echo $?)" "2" "freshness-check without --phase is rejected"
is "$(fc --phase 'a/b' >/dev/null 2>&1; echo $?)" "2" "a phase with a path separator is rejected"
is "$(fc --phase '..' >/dev/null 2>&1; echo $?)" "2" "a phase of '..' is rejected (it would escape the run dir)"
# --file '' would fall through to a WORKTREE snapshot compared against a single-file .tree:
# a permanent tree-changed that blames the user for an unset $PLAN_PATH.
is "$(fc --phase plan-review --file '' >/dev/null 2>&1; echo $?)" "2" "an empty --file is rejected, not treated as worktree mode"
is "$(fc --phase plan-review --file "$SB/nope.md" >/dev/null 2>&1; echo $?)" "2" "a missing --file is rejected"

# (9b) a write-mode call must not be able to certify its own output as reviewed
rx --phase final-fix --prompt-file "$PF" --role implementer --freshness >/dev/null 2>&1
is "$?" "2" "--freshness with --role implementer is rejected"

# (9c) the verdict must be written BEFORE the tree is promoted. A corrupted rounds file used to
# abort the runner between the two, leaving a fresh .tree beside the PREVIOUS round's verdict —
# a stale APPROVED that freshness-check then called fresh.
rm -f "$RUN_DIR/final-review.tree"
FAKE_CODEX_VERDICT="ROUND-A APPROVED" rx --phase final-review --prompt-file "$PF" --freshness >/dev/null 2>&1
printf 'not-a-number' > "$RUN_DIR/final-review-rounds.txt"
printf 'moved on\n' >> a.txt
out="$(FAKE_CODEX_VERDICT="ROUND-B CHANGES_REQUESTED" rx --phase final-review --prompt-file "$PF" --freshness 2>&1)"; rc=$?
is "$rc" "0" "a corrupted rounds file does not break a usable call"
has "$out" "ROUND=1" "...the counter falls back to a sane value"
has "$(cat "$RUN_DIR/final-review-verdict.txt")" "ROUND-B" "...and the verdict file holds THIS round's verdict"
is "$(fc --phase final-review >/dev/null 2>&1; echo $?)" "0" "...next to a tree that matches it"
# A leading zero is decimal 8 here, not an invalid octal literal that would abort the runner.
printf '08\n' > "$RUN_DIR/final-review-rounds.txt"
printf 'again\n' >> a.txt
out="$(rx --phase final-review --prompt-file "$PF" --freshness 2>&1)"
has "$out" "ROUND=9" "a leading-zero counter is read as base 10"

# (10) without --freshness the runner takes no snapshot at all (opt-in, so plain calls stay cheap)
rm -f "$RUN_DIR/final-review.tree"
rx --phase final-review --prompt-file "$PF" >/dev/null 2>&1
ok "[ ! -e '$RUN_DIR/final-review.tree' ]" "no snapshot without --freshness"

# (11) the snapshot must not be blinded by a diff program the REPO names. `--no-textconv` covers
# textconv filters only; an external diff driver (diff.external, or `diff=x` in gitattributes)
# needs --no-ext-diff. It matters because the diff section is the only content-bearing part of
# the snapshot for tracked files: a driver that prints nothing makes an edited tree byte-identical
# and freshness-check reports FRESH on code no reviewer read.
printf '#!/bin/sh\nexit 0\n' > "$SB/quiet-diff.sh"; chmod +x "$SB/quiet-diff.sh"
git config diff.external "$SB/quiet-diff.sh"
printf 'ext\n' >> a.txt
rx --phase extdiff --prompt-file "$PF" --freshness >/dev/null 2>&1
is "$?" "0" "a call still succeeds with a repo-configured external diff driver"
before_status="$(git status --porcelain)"
printf 'ext2\n' >> a.txt
is "$(git status --porcelain)" "$before_status" "the second edit leaves git status unchanged"
out="$(fc --phase extdiff 2>&1)"; rc=$?
is "$rc" "1" "an external diff driver cannot blind the snapshot"
has "$out" "REASON=tree-changed" "...the edit is still reported as tree-changed"
git config --unset diff.external

# (12) a FAILED promotion must consume nothing: no round number, no leftover pending file, and
# the verdict on disk must still be THIS round's (the tree/verdict pair may go stale, never
# mismatched). `mv` is forced to fail portably — the destination is a directory holding a
# non-empty directory of the pending file's own name, which `mv` cannot overwrite.
printf 'mv\n' >> a.txt
FAKE_CODEX_VERDICT="ROUND-A APPROVED" rx --phase mvfail --prompt-file "$PF" --freshness >/dev/null 2>&1
is "$(cat "$RUN_DIR/mvfail-rounds.txt")" "1" "the first mvfail round counted"
rm -f "$RUN_DIR/mvfail.tree"
mkdir -p "$RUN_DIR/mvfail.tree/mvfail.tree.pending/x"
printf 'sabotage\n' > "$RUN_DIR/mvfail.tree/mvfail.tree.pending/x/f"
printf 'mv2\n' >> a.txt
out="$(FAKE_CODEX_VERDICT="ROUND-B CHANGES_REQUESTED" rx --phase mvfail --prompt-file "$PF" --freshness 2>&1)"; rc=$?
isnt "$rc" "0" "a call whose promotion fails is reported unusable"
# `has "$out" "TREE_FILE="` would pass on "TREE_FILE=/some/path" too — match the VALUE, not the key.
is "$(printf '%s\n' "$out" | sed -n 's/^TREE_FILE=//p')" "" "...with an empty TREE_FILE value"
is "$(printf '%s\n' "$out" | sed -n 's/^ROUND=//p')" "" "...and an empty ROUND value"
is "$(cat "$RUN_DIR/mvfail-rounds.txt")" "1" "...the round counter is NOT consumed"
ok "[ ! -e '$RUN_DIR/mvfail.tree.pending' ]" "...the pending snapshot is cleaned up"
has "$(cat "$RUN_DIR/mvfail-verdict.txt")" "ROUND-B" "...and the verdict on disk is this round's"
rm -rf "$RUN_DIR/mvfail.tree"

# (13) the other half of the same pair: if the VERDICT write fails, promotion must not happen.
# Ordering alone does not cover this — a failed write leaves the previous round's text in place,
# so promoting on top of it would produce a fresh .tree beside a stale APPROVED.
printf 'vf\n' >> a.txt
FAKE_CODEX_VERDICT="ROUND-A APPROVED" rx --phase vfail --prompt-file "$PF" --freshness >/dev/null 2>&1
is "$(fc --phase vfail >/dev/null 2>&1; echo $?)" "0" "the vfail baseline round is fresh"
chmod 444 "$RUN_DIR/vfail-verdict.txt"
printf 'vf2\n' >> a.txt
out="$(rx --phase vfail --prompt-file "$PF" --freshness 2>&1)"
isnt "$?" "0" "a call whose verdict write fails is reported unusable"
has "$(cat "$RUN_DIR/vfail-verdict.txt")" "ROUND-A" "...the old verdict text is what survived"
# The report must not hand out a path to that stale text: every skill says "read the verdict at
# VERDICT_FILE", so a populated VERDICT_FILE here points an LLM straight at the previous round's
# APPROVED. Match the VALUE, as with TREE_FILE/ROUND.
is "$(printf '%s\n' "$out" | sed -n 's/^VERDICT_FILE=//p')" "" "...and VERDICT_FILE is reported empty, not a path to stale text"
is "$(fc --phase vfail >/dev/null 2>&1; echo $?)" "1" "...so no fresh tree was promoted beside it"
chmod 644 "$RUN_DIR/vfail-verdict.txt"

cleanup_sandbox
report
