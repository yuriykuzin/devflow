#!/usr/bin/env bash
# run-external: fake codex -> verdict extracted, session captured, exit 0;
# --no-session-reuse -> ephemeral (no session persisted); linger -> drain then reap as success (0).
set -u
export DEVFLOW_POLL_SCHEDULE="1 1 1 1 1 1"      # test seam: sub-second polling
export DEVFLOW_DRAIN_SCHEDULE="0.2 0.2 0.2 0.2 0.2 0.2"
. "$LIB/assert.sh"; . "$LIB/sandbox.sh"

mk_sandbox
run_dir_here

PROMPT_FILE="$SB/prompt.txt"; printf 'review please\n' > "$PROMPT_FILE"
kv(){ printf '%s\n' "$1" | sed -n "s/^$2=//p"; }   # kv "$out" KEY -> value

# --- normal success ---
out="$(FAKE_CODEX_MODE=ok rx --phase final-review --prompt-file "$PROMPT_FILE")"
is "$(kv "$out" EXIT)" "0" "normal call exits 0"
has "$(cat "$(kv "$out" VERDICT_FILE)")" "APPROVED" "verdict text extracted from events into VERDICT_FILE"
is "$(kv "$out" SESSION_ID)" "thread_test_abc123" "thread_id captured as session id"
ok "[ -s '$(kv "$out" SESSION_FILE)' ]" "session file written for resume"

# --- ephemeral (--no-session-reuse) ---
out="$(FAKE_CODEX_MODE=ok rx --phase final-review --prompt-file "$PROMPT_FILE" --no-session-reuse)"
is "$(kv "$out" EXIT)" "0" "ephemeral call still exits 0"
ok "[ ! -s '$(kv "$out" SESSION_FILE)' ]" "ephemeral call persists no session"

# --- linger: turn.completed then process stays alive -> bounded drain -> reap as SUCCESS ---
# The verdict was already produced, so a slow-to-exit process is reaped and reported EXIT=0,
# NOT escalated as a 124 timeout. The verdict is still extracted from the completed turn.
SECONDS=0
out="$(FAKE_CODEX_MODE=linger rx --phase final-review --prompt-file "$PROMPT_FILE")"
dur=$SECONDS
is "$(kv "$out" EXIT)" "0" "lingering process reaped after turn.completed, treated as success (exit 0)"
has "$(cat "$(kv "$out" VERDICT_FILE)")" "APPROVED" "verdict from the completed turn survives the linger->reap path"
ok "[ $dur -lt 15 ]" "linger path bounded (did not hang); took ${dur}s"

# --- resume: --resume set -> codex invoked with `exec resume` (session-reuse path) ---
: > "$FAKE_CODEX_LOG"
out="$(FAKE_CODEX_MODE=ok rx --phase final-review --prompt-file "$PROMPT_FILE" --resume thread_test_abc123)"
is "$(kv "$out" EXIT)" "0" "resume call exits 0"
has "$(cat "$FAKE_CODEX_LOG")" "resume=1" "--resume set -> codex invoked via 'exec resume'"

# --- hang: never emits turn.completed -> poll schedule exhausts -> hard-cap kill (124) ---
SECONDS=0
out="$(FAKE_CODEX_MODE=hang rx --phase final-review --prompt-file "$PROMPT_FILE")"
dur=$SECONDS
is "$(kv "$out" EXIT)" "124" "process that never completes hits the hard cap (exit 124)"
ok "[ $dur -lt 15 ]" "hard-cap path bounded (did not hang); took ${dur}s"
session_file="$(kv "$out" SESSION_FILE)"
ok "[ -f \"$session_file\" ]" "hard-cap path still writes SESSION_FILE (output contract holds even on timeout)"
ok "[ ! -s \"$session_file\" ]" "hard-cap path's SESSION_FILE is empty (no session captured)"

# --- verdict is passed through verbatim (no machine parse): the runner writes the reviewer's
#     text to VERDICT_FILE untouched, for the orchestrator LLM to read and judge itself. ---
out="$(FAKE_CODEX_MODE=ok FAKE_CODEX_VERDICT='Some issues remain. Please fix the null check. CHANGES_REQUESTED' \
  rx --phase final-review --prompt-file "$PROMPT_FILE")"
has "$(cat "$(kv "$out" VERDICT_FILE)")" "CHANGES_REQUESTED" "arbitrary verdict text lands in VERDICT_FILE verbatim"
has "$(cat "$(kv "$out" VERDICT_FILE)")" "null check" "full verdict prose preserved, not reduced to a token"

# --- write posture: reviewer runs read-only; implementer gets workspace-write ---
: > "$FAKE_CODEX_LOG"
out="$(FAKE_CODEX_MODE=ok rx --phase final-review --prompt-file "$PROMPT_FILE")"
has   "$(cat "$FAKE_CODEX_LOG")" "ro=1" "reviewer call runs codex read-only (sandbox_mode=read-only)"
hasnt "$(cat "$FAKE_CODEX_LOG")" "fa=1" "reviewer call does NOT get --full-auto"

: > "$FAKE_CODEX_LOG"
out="$(FAKE_CODEX_MODE=ok rx --phase impl --prompt-file "$PROMPT_FILE" --role implementer)"
has   "$(cat "$FAKE_CODEX_LOG")" "fa=1" "implementer call gets codex --full-auto (workspace-write)"
hasnt "$(cat "$FAKE_CODEX_LOG")" "ro=1" "implementer call is NOT forced read-only"

# --- input validation: required flags fail loudly BEFORE anything runs ---
noph_err="$(FAKE_CODEX_MODE=ok rx --prompt-file "$PROMPT_FILE" 2>&1)"; noph_rc=$?
has  "$noph_err" "--phase is required" "run-external without --phase fails loudly"
isnt "$noph_rc" "0"                    "run-external without --phase returns non-zero"

nopf_err="$(FAKE_CODEX_MODE=ok rx --phase final-review 2>&1)"; nopf_rc=$?
has  "$nopf_err" "--prompt-file" "run-external without --prompt-file fails loudly"
isnt "$nopf_rc" "0"               "run-external without --prompt-file returns non-zero"

missing_err="$(FAKE_CODEX_MODE=ok rx --phase final-review --prompt-file "$SB/does-not-exist.txt" 2>&1)"; missing_rc=$?
has  "$missing_err" "--prompt-file" "run-external with a nonexistent --prompt-file fails loudly"
isnt "$missing_rc" "0"              "run-external with a nonexistent --prompt-file returns non-zero"

# the flags a skill must supply (no run.env to fall back on) are each required
nobe_err="$(cd "$REPO_FX" && bash "$RUNNER" run-external --model m --effort e --phase p --prompt-file "$PROMPT_FILE" 2>&1)"; nobe_rc=$?
has  "$nobe_err" "--backend" "run-external without --backend fails loudly"
isnt "$nobe_rc" "0"          "run-external without --backend returns non-zero"

nomodel_err="$(cd "$REPO_FX" && bash "$RUNNER" run-external --backend codex --effort e --phase p --prompt-file "$PROMPT_FILE" 2>&1)"; nomodel_rc=$?
has  "$nomodel_err" "--model is required" "run-external without --model fails loudly"
isnt "$nomodel_rc" "0"                    "run-external without --model returns non-zero"

badbe_err="$(cd "$REPO_FX" && bash "$RUNNER" run-external --backend bogus --model m --effort e --phase p --prompt-file "$PROMPT_FILE" 2>&1)"; badbe_rc=$?
has  "$badbe_err" "--backend must be" "run-external with an unknown --backend fails loudly"
isnt "$badbe_rc" "0"                  "run-external with an unknown --backend returns non-zero"

cleanup_sandbox
report
