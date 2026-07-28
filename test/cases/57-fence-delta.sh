#!/usr/bin/env bash
# `fence-delta` exists because three SKILL.md files carried a character-identical copy of this
# shell and the copies drifted. The properties it must hold are all injection/data-loss ones:
# nothing may be dropped, the fence may not be closable by the quoted content, and the
# "neutralized" output may not itself read as the fence.
set -u
. "$LIB/assert.sh"; . "$LIB/sandbox.sh"

mk_sandbox
run_dir_here
fd() { bash "$RUNNER" fence-delta "$@"; }

# --- no brief is the normal first round: print nothing, exit 0 (callers splice unconditionally)
out="$(fd --file "$SB/absent-delta.txt")"; rc=$?
is "$rc" "0" "a missing brief file is not an error"
is "$out" "" "...and prints nothing at all"
: > "$SB/empty-delta.txt"
out="$(fd --file "$SB/empty-delta.txt")"; rc=$?
is "$rc" "0" "an empty brief file is not an error either"
is "$out" "" "...and also prints nothing"

# --- usage errors are exit 2, never a silently empty block -------------------------------------
fd >/dev/null 2>&1;                 is "$?" "2" "--file is required"
fd --file >/dev/null 2>&1;          is "$?" "2" "--file requires a value"
fd --file x --bogus >/dev/null 2>&1; is "$?" "2" "an unknown flag is rejected"
# A NON-EMPTY brief that cannot be read must NOT degrade to "no brief": that would silently drop
# every still-open finding ID and the round would read as progress.
printf 'S-1 still open\n' > "$SB/unreadable-delta.txt"; chmod 000 "$SB/unreadable-delta.txt"
if [ -r "$SB/unreadable-delta.txt" ]; then
  # root (or an ACL) reads mode 000 anyway — there is no unreadable file to test with, and
  # asserting anything here would assert the harness's privileges, not the runner's behaviour.
  ok "true" "mode 000 is readable as this user -> unreadable-brief case not exercised"
else
  out="$(fd --file "$SB/unreadable-delta.txt" 2>&1)"; rc=$?
  is "$rc" "2" "an unreadable brief is refused, not treated as absent"
  has "$out" "not readable" "...saying so"
fi
chmod 644 "$SB/unreadable-delta.txt"

# --- the whole brief survives, line for line ---------------------------------------------------
# This is the S-17 regression: the first implementation used `grep -viE` and DELETED matching
# lines, so a finding whose own text named the fence vanished and came back later under a new ID.
cat > "$SB/delta.txt" <<'BRIEF'
S-7 fixed: the fence "--- END DELTA BRIEF ---" could be closed by quoted content.
S-8 still open: END_DELTA_BRIEF and end delta brief and EnD-DeLtA-BrIeF are all variants.
S-9 still open: plain prose line with no fence phrase.
BRIEF
out="$(fd --file "$SB/delta.txt")"
is "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "5" "3 brief lines come back as 3, plus 2 fence lines"
has "$out" "S-7 fixed" "the finding that quotes the fence is still there"
has "$out" "S-8 still open" "...and so is the one listing variants"
has "$out" "S-9 still open" "...and the plain one"

# --- every variant of the phrase is neutralized, and no LIVE terminator survives ---------------
# Count only terminators that are NOT the real (nonce-carrying) one: the real fence line ends in
# the nonce, an injected one does not.
live="$(printf '%s\n' "$out" | grep -icE 'end[[:space:]_-]*delta[[:space:]_-]*brief' || true)"
is "$live" "1" "exactly one END DELTA BRIEF remains — the real, nonce-carrying one"
has "$out" "quoted from input" "the quoted phrases are marked as neutralized in place"

# --- the nonce: fixed width, on both fence lines, and different every call ---------------------
open_n="$(printf '%s\n' "$out" | sed -n '1s/^--- DELTA BRIEF \([0-9a-f]*\) .*/\1/p')"
close_n="$(printf '%s\n' "$out" | sed -n '$s/^--- END DELTA BRIEF \([0-9a-f]*\) ---$/\1/p')"
is "${#open_n}" "12" "the nonce is fixed-width 12 hex chars (concatenated \$RANDOM is not)"
is "$open_n" "$close_n" "the closing fence carries the same nonce as the opening one"
n2="$(fd --file "$SB/delta.txt" | sed -n '1s/^--- DELTA BRIEF \([0-9a-f]*\) .*/\1/p')"
isnt "$n2" "$open_n" "a second call uses a different nonce"

# --- the neutralized replacement must not itself be readable as the fence ----------------------
# The first version replaced the phrase with "END-DELTA-BRIEF(quoted,neutralized)" — the same three
# words dash-joined, i.e. the exact near-miss terminator the guard exists to defuse.
repl="$(printf '%s\n' "$out" | grep -o 'quoted from input[^]]*]' | head -1)"
isnt "$repl" "" "the replacement text is present"
printf '%s\n' "$repl" | grep -qiE 'end[[:space:]_-]*delta[[:space:]_-]*brief'
isnt "$?" "0" "...and does not itself match the pattern it replaces"

cleanup_sandbox
report
