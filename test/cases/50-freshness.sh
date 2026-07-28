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
# The .tree stores a DIGEST, not the snapshot text: the content is only a means of detecting an
# edit, and keeping it made the file as large as the whole diff plus every untracked file.
is "$(wc -l < "$RUN_DIR/final-review.tree" | tr -d " ")" "1" "...as a single-line digest, not the whole tree text"
hasnt "$(cat "$RUN_DIR/final-review.tree")" "diff --git" "...so the snapshot text itself is not stored"

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
rx --phase final-review --prompt-file "$PF" --freshness >/dev/null 2>&1
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
# The digest is of the FILE, not the worktree: the same plan text must hash the same either way.
is "$(cat "$RUN_DIR/plan-review.tree")" "$(printf '# plan v1\n' | (command -v shasum >/dev/null && shasum -a 256 || sha256sum) | cut -c1-16)" "...digests the named file, not the worktree, byte for byte including the trailing newline"
is "$(fc --phase plan-review --file "$PLAN" >/dev/null 2>&1; echo $?)" "0" "unchanged plan is fresh"
printf '# plan v2\n' > "$PLAN"
is "$(fc --phase plan-review --file "$PLAN" >/dev/null 2>&1; echo $?)" "1" "edited plan is stale"

# (7b) a trailing-newline-only edit is a real edit: the digest must not be taken through a
# command substitution, which strips trailing newlines and would bless unread bytes.
printf '# plan v1\n' > "$PLAN"
is "$(rx --phase plan-nl --prompt-file "$PF" --freshness-file "$PLAN" >/dev/null 2>&1; echo $?)" "0" "re-snapshot the plan for the newline case"
printf '# plan v1\n\n\n' > "$PLAN"
is "$(fc --phase plan-nl --file "$PLAN" >/dev/null 2>&1; echo $?)" "1" "a trailing-newline-only edit is detected as stale"

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

# (9c) the verdict must be written BEFORE the tree is promoted: otherwise a fresh .tree can end
# up beside the PREVIOUS round's verdict — a stale APPROVED that freshness-check then calls fresh.
rm -f "$RUN_DIR/final-review.tree"
FAKE_CODEX_VERDICT="ROUND-A APPROVED" rx --phase final-review --prompt-file "$PF" --freshness >/dev/null 2>&1
printf 'moved on\n' >> a.txt
out="$(FAKE_CODEX_VERDICT="ROUND-B CHANGES_REQUESTED" rx --phase final-review --prompt-file "$PF" --freshness 2>&1)"; rc=$?
is "$rc" "0" "a second usable round succeeds"
has "$(cat "$RUN_DIR/final-review-verdict.txt")" "ROUND-B" "...and the verdict file holds THIS round's verdict"
is "$(fc --phase final-review >/dev/null 2>&1; echo $?)" "0" "...next to a tree that matches it"

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

# (12) a FAILED promotion must consume nothing: no leftover pending file, and the verdict on disk
# must still be THIS round's (the tree/verdict pair may go stale, never mismatched). `mv` is
# forced to fail portably — the destination is a directory holding a non-empty directory of the
# pending file's own name, which `mv` cannot overwrite.
printf 'mv\n' >> a.txt
FAKE_CODEX_VERDICT="ROUND-A APPROVED" rx --phase mvfail --prompt-file "$PF" --freshness >/dev/null 2>&1
rm -f "$RUN_DIR/mvfail.tree"
mkdir -p "$RUN_DIR/mvfail.tree/mvfail.tree.pending/x"
printf 'sabotage\n' > "$RUN_DIR/mvfail.tree/mvfail.tree.pending/x/f"
printf 'mv2\n' >> a.txt
out="$(FAKE_CODEX_VERDICT="ROUND-B CHANGES_REQUESTED" rx --phase mvfail --prompt-file "$PF" --freshness 2>&1)"; rc=$?
isnt "$rc" "0" "a call whose promotion fails is reported unusable"
# `has "$out" "TREE_FILE="` would pass on "TREE_FILE=/some/path" too — match the VALUE, not the key.
is "$(printf '%s\n' "$out" | sed -n 's/^TREE_FILE=//p')" "" "...with an empty TREE_FILE value"
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
# root ignores a 444 mode, so the write would succeed and this case would assert the opposite of
# what it means. Probe first rather than fail the suite for the wrong reason.
if printf '' >> "$RUN_DIR/vfail-verdict.txt" 2>/dev/null; then
  chmod 644 "$RUN_DIR/vfail-verdict.txt"
  ok "true" "verdict-write failure not exercised (this uid can write a chmod 444 file — root/ACL?)"
else
  out="$(rx --phase vfail --prompt-file "$PF" --freshness 2>&1)"
  isnt "$?" "0" "a call whose verdict write fails is reported unusable"
  has "$(cat "$RUN_DIR/vfail-verdict.txt")" "ROUND-A" "...the old verdict text is what survived"
  # The report must not hand out a path to that stale text: every skill says "read the verdict at
  # VERDICT_FILE", so a populated VERDICT_FILE here points an LLM straight at the previous round's
  # APPROVED. Match the VALUE, as with TREE_FILE.
  is "$(printf '%s\n' "$out" | sed -n 's/^VERDICT_FILE=//p')" "" "...and VERDICT_FILE is reported empty, not a path to stale text"
  is "$(fc --phase vfail >/dev/null 2>&1; echo $?)" "1" "...so no fresh tree was promoted beside it"
  chmod 644 "$RUN_DIR/vfail-verdict.txt"
fi

# (14) a snapshot that cannot be TAKEN is neither a match nor a mismatch. It must not report
# tree-changed ("you edited files") and must never report FRESH: hashing an empty snapshot would
# turn "could not read the review target" into a perfectly valid-looking digest.
# chmod cannot make a file unreadable to root (or under some ACL setups), and there the call
# would legitimately report tree-changed instead — assert only when the mode actually bites,
# rather than failing the suite for the wrong reason.
chmod 000 "$PLAN"
if [ -r "$PLAN" ]; then
  chmod 644 "$PLAN"
  ok "true" "snapshot-failed not exercised (this uid can read a chmod 000 file — root/ACL?)"
else
  out="$(fc --phase plan-review --file "$PLAN" 2>&1)"; rc=$?
  chmod 644 "$PLAN"
  is "$rc" "1" "a snapshot that cannot be taken is not fresh"
  has "$out" "REASON=snapshot-failed" "...and says the snapshot failed, not that the tree changed"
  hasnt "$out" "FRESH=yes" "...never FRESH"
fi

# (15) a repo with NO COMMITS still snapshots, and still detects an edit. `git diff HEAD` fatals
# on an unborn HEAD, and only the LAST command decides a subshell's status — so before the diff
# base was made explicit, the whole content-bearing section was silently missing and two
# different trees digested identically: FRESH=yes on unread code.
UNBORN="$SB/unborn"; mkdir -p "$UNBORN"
(
  cd "$UNBORN" || exit 1
  git init -q; git config user.email t@example.test; git config user.name tester
  printf 'staged v1\n' > s.txt; git add s.txt
)
ub_digest(){ ( cd "$UNBORN" && bash -c ". '$RUNNER'; RUN_DIR='$RUN_DIR'; devflow_snapshot_digest" < /dev/null 2>/dev/null ); }
d1="$(ub_digest)"
isnt "$d1" "" "an unborn-HEAD repo still produces a digest"
printf 'staged v2\n' > "$UNBORN/s.txt"
d2="$(ub_digest)"
isnt "$d2" "" "...and still produces one after an edit"
isnt "$d2" "$d1" "...and the two differ: an edit in a commit-less repo is detected"

# (16)-(18) SERIALIZATION FORGERY. The digest is only as strong as the framing that separates
# one untracked entry from the next. While that framing was a bare `### <path>` line, content
# the tree itself controls could impersonate it, and two materially different worktrees
# serialized byte-identically — a reviewer read one, the implementer could ship the other, and
# freshness-check said FRESH=yes over code nobody reviewed. Each case below is a working
# forgery from that era; all three must now produce DIFFERENT digests.
newrepo(){ mkdir -p "$1" && ( cd "$1" && git init -q && git config user.email t@example.test && git config user.name tester ); }
dg(){ ( cd "$1" && bash -c ". '$RUNNER'; RUN_DIR='$RUN_DIR'; devflow_snapshot_digest" < /dev/null 2>/dev/null ); }

# (16) one untracked file containing a fake entry header vs. two real untracked files.
newrepo "$SB/f1a"; mkdir -p "$SB/f1a/d"; printf 'X\n### d/b @file 2\nY\n' > "$SB/f1a/d/a"
newrepo "$SB/f1b"; mkdir -p "$SB/f1b/d"; printf 'X\n' > "$SB/f1b/d/a"; printf 'Y\n' > "$SB/f1b/d/b"
a="$(dg "$SB/f1a")"; b="$(dg "$SB/f1b")"
isnt "$a" "" "a tree whose file content mimics an entry header still digests"
isnt "$a" "$b" "...and one file faking a second entry does not collide with two real files"

# (17) an untracked file whose NAME contains a newline. git C-quotes control characters
# regardless of quotePath, so this name used to arrive quoted, fail `[ -f ]`, and be recorded as
# metadata — its content excluded from the digest entirely, rc=0, no stderr.
NL="$SB/f2"; newrepo "$NL"
EVIL="$NL/$(printf 'evil\nFRESH=yes')"
printf 'benign code\n' > "$EVIL"
c1="$(dg "$NL")"
printf 'UNREVIEWED PAYLOAD\n' > "$EVIL"
c2="$(dg "$NL")"
isnt "$c1" "" "an untracked file with a newline in its name still digests"
isnt "$c2" "$c1" "...and its CONTENT is covered: rewriting it changes the digest"

# (18) a regular file impersonating the @symlink marker.
newrepo "$SB/f3a"; ln -s ./payload.sh "$SB/f3a/x"
newrepo "$SB/f3b"; printf '@symlink -> ./payload.sh\n' > "$SB/f3b/x"
e="$(dg "$SB/f3a")"; f="$(dg "$SB/f3b")"
isnt "$e" "" "an untracked symlink digests without following its target"
isnt "$e" "$f" "...and a regular file whose content is the symlink marker does not collide"

cleanup_sandbox
report
