#!/usr/bin/env bash
# run-external: fake codex -> verdict extracted, session captured, exit 0;
# --no-session-reuse -> ephemeral (no session persisted); linger -> drain then kill (124).
set -u
export DEVFLOW_POLL_SCHEDULE="1 1 1 1 1 1"      # test seam: sub-second polling
export DEVFLOW_DRAIN_SCHEDULE="0.2 0.2 0.2 0.2 0.2 0.2"
. "$LIB/assert.sh"; . "$LIB/sandbox.sh"

mk_sandbox
bootstrap_here

PROMPT_FILE="$SB/prompt.txt"; printf 'review please\n' > "$PROMPT_FILE"
kv(){ printf '%s\n' "$1" | sed -n "s/^$2=//p"; }   # kv "$out" KEY -> value

# --- normal success ---
out="$(cd "$REPO_FX" && env FAKE_CODEX_MODE=ok bash "$RUNNER" run-external --phase final-review --prompt-file "$PROMPT_FILE")"
is "$(kv "$out" EXIT)" "0" "normal call exits 0"
has "$(cat "$(kv "$out" VERDICT_FILE)")" "APPROVED" "verdict text extracted from events"
is "$(kv "$out" VERDICT_STATUS)" "APPROVED" "VERDICT_STATUS parsed from the verdict text"
is "$(kv "$out" SESSION_ID)" "thread_test_abc123" "thread_id captured as session id"
ok "[ -s '$(kv "$out" SESSION_FILE)' ]" "session file written for resume"

# --- ephemeral (--no-session-reuse) ---
out="$(cd "$REPO_FX" && env FAKE_CODEX_MODE=ok bash "$RUNNER" run-external --phase final-review --prompt-file "$PROMPT_FILE" --no-session-reuse)"
is "$(kv "$out" EXIT)" "0" "ephemeral call still exits 0"
ok "[ ! -s '$(kv "$out" SESSION_FILE)' ]" "ephemeral call persists no session"

# --- linger: turn.completed then process stays alive -> bounded drain -> kill 124 ---
SECONDS=0
out="$(cd "$REPO_FX" && env FAKE_CODEX_MODE=linger bash "$RUNNER" run-external --phase final-review --prompt-file "$PROMPT_FILE")"
dur=$SECONDS
is "$(kv "$out" EXIT)" "124" "lingering process is killed after turn.completed (exit 124)"
ok "[ $dur -lt 15 ]" "linger path bounded (did not hang); took ${dur}s"

# --- resume: --resume set -> codex invoked with `exec resume` (session-reuse path) ---
: > "$FAKE_CODEX_LOG"
out="$(cd "$REPO_FX" && env FAKE_CODEX_MODE=ok bash "$RUNNER" run-external --phase final-review --prompt-file "$PROMPT_FILE" --resume thread_test_abc123)"
is "$(kv "$out" EXIT)" "0" "resume call exits 0"
has "$(cat "$FAKE_CODEX_LOG")" "resume=1" "--resume set -> codex invoked via 'exec resume'"

# --- hang: never emits turn.completed -> poll schedule exhausts -> hard-cap kill (124) ---
SECONDS=0
out="$(cd "$REPO_FX" && env FAKE_CODEX_MODE=hang bash "$RUNNER" run-external --phase final-review --prompt-file "$PROMPT_FILE")"
dur=$SECONDS
is "$(kv "$out" EXIT)" "124" "process that never completes hits the hard cap (exit 124)"
ok "[ $dur -lt 15 ]" "hard-cap path bounded (did not hang); took ${dur}s"
session_file="$(kv "$out" SESSION_FILE)"
ok "[ -f \"$session_file\" ]" "hard-cap path still writes SESSION_FILE (output contract holds even on timeout)"
ok "[ ! -s \"$session_file\" ]" "hard-cap path's SESSION_FILE is empty (no session captured)"

# --- VERDICT_STATUS parsing: case-insensitive, tolerates markdown/punctuation, last occurrence ---
out="$(cd "$REPO_FX" && env FAKE_CODEX_MODE=ok FAKE_CODEX_VERDICT='Some issues remain. **changes_requested**' \
  bash "$RUNNER" run-external --phase final-review --prompt-file "$PROMPT_FILE")"
is "$(kv "$out" VERDICT_STATUS)" "CHANGES_REQUESTED" "verdict status tolerates markdown bold + lowercase"

out="$(cd "$REPO_FX" && env FAKE_CODEX_MODE=ok FAKE_CODEX_VERDICT='Found several problems. ISSUES.' \
  bash "$RUNNER" run-external --phase final-review --prompt-file "$PROMPT_FILE")"
is "$(kv "$out" VERDICT_STATUS)" "ISSUES" "verdict status tolerates trailing punctuation"

out="$(cd "$REPO_FX" && env FAKE_CODEX_MODE=ok FAKE_CODEX_VERDICT='Looks fine, but no explicit verdict token here.' \
  bash "$RUNNER" run-external --phase final-review --prompt-file "$PROMPT_FILE")"
is "$(kv "$out" VERDICT_STATUS)" "UNKNOWN" "verdict status falls back to UNKNOWN when no known token is present"

out="$(cd "$REPO_FX" && env FAKE_CODEX_MODE=ok FAKE_CODEX_VERDICT='CHANGES_REQUESTED -- the code is not APPROVED for merge.' \
  bash "$RUNNER" run-external --phase final-review --prompt-file "$PROMPT_FILE")"
is "$(kv "$out" VERDICT_STATUS)" "UNKNOWN" "ambiguous line (both tokens present) resolves to UNKNOWN, not a guessed APPROVED"

# --- input validation: --phase and --prompt-file are both required before anything runs ---
noph_err="$(cd "$REPO_FX" && env FAKE_CODEX_MODE=ok bash "$RUNNER" run-external --prompt-file "$PROMPT_FILE" 2>&1)"; noph_rc=$?
has  "$noph_err" "--phase is required" "run-external without --phase fails loudly"
isnt "$noph_rc" "0"                    "run-external without --phase returns non-zero"

nopf_err="$(cd "$REPO_FX" && env FAKE_CODEX_MODE=ok bash "$RUNNER" run-external --phase final-review 2>&1)"; nopf_rc=$?
has  "$nopf_err" "--prompt-file" "run-external without --prompt-file fails loudly"
isnt "$nopf_rc" "0"               "run-external without --prompt-file returns non-zero"

missing_err="$(cd "$REPO_FX" && env FAKE_CODEX_MODE=ok bash "$RUNNER" run-external --phase final-review --prompt-file "$SB/does-not-exist.txt" 2>&1)"; missing_rc=$?
has  "$missing_err" "--prompt-file" "run-external with a nonexistent --prompt-file fails loudly"
isnt "$missing_rc" "0"              "run-external with a nonexistent --prompt-file returns non-zero"

cleanup_sandbox
report
