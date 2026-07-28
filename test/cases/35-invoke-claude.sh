#!/usr/bin/env bash
# run-external with --backend claude. Unlike codex, there is no command_path config for
# claude (the trust boundary restricts exec-path override keys to codex); claude always
# resolves via `command -v claude`, so this fixture shims PATH with a `claude` executable
# pointing at fake-claude. Model/effort are passed as flags, exactly as a claude-backed
# skill would after reading .devflow.yaml.
set -u
export DEVFLOW_POLL_SCHEDULE="1 1 1 1 1 1"
export DEVFLOW_DRAIN_SCHEDULE="0.2 0.2 0.2 0.2 0.2 0.2"
. "$LIB/assert.sh"; . "$LIB/sandbox.sh"

mk_sandbox
run_dir_here

FAKE_CLAUDE_BIN_DIR="$SB/bin"; mkdir -p "$FAKE_CLAUDE_BIN_DIR"
ln -sf "$LIB/fake-claude" "$FAKE_CLAUDE_BIN_DIR/claude"
export PATH="$FAKE_CLAUDE_BIN_DIR:$PATH"
export FAKE_CLAUDE_LOG="$SB/claude.log"; : > "$FAKE_CLAUDE_LOG"

PROMPT_FILE="$SB/prompt.txt"; printf 'review please\n' > "$PROMPT_FILE"
kv(){ printf '%s\n' "$1" | sed -n "s/^$2=//p"; }
# cx <run-external flags...>: claude-backend invocation for this fixture.
cx(){ ( cd "$REPO_FX" && bash "$RUNNER" run-external --backend claude --model claude-opus-4-8 --effort max "$@" ); }

# --- normal success: .result/.session_id parsed (not codex's JSONL-events parsing) ---
out="$(FAKE_CLAUDE_MODE=ok cx --phase final-review --prompt-file "$PROMPT_FILE")"
is "$(kv "$out" EXIT)" "0" "normal claude call exits 0"
has "$(cat "$(kv "$out" VERDICT_FILE)")" "APPROVED" "verdict text extracted from .result into VERDICT_FILE"
is "$(kv "$out" SESSION_ID)" "claude_test_session_xyz" "session_id captured from .session_id"
ok "[ -s '$(kv "$out" SESSION_FILE)' ]" "session file written for resume"
has "$(cat "$FAKE_CLAUDE_LOG")" "permission-mode=plan" "reviewer role -> read-only permission-mode (plan), derived not passed (claude resolved via PATH)"

# --- ephemeral (--no-session-reuse) -> claude invoked with --no-session-persistence ---
out="$(FAKE_CLAUDE_MODE=ok cx --phase final-review --prompt-file "$PROMPT_FILE" --no-session-reuse)"
is "$(kv "$out" EXIT)" "0" "ephemeral claude call still exits 0"
ok "[ ! -s '$(kv "$out" SESSION_FILE)' ]" "ephemeral call persists no session"
has "$(tail -1 "$FAKE_CLAUDE_LOG")" "no-session-persistence=1" "--no-session-reuse -> claude invoked with --no-session-persistence"

# --- resume + implementer role (mirrors the implementer-handoff call shape) ---
# --role implementer derives write permission-mode (default); reviewer (above) derives plan.
: > "$FAKE_CLAUDE_LOG"
out="$(FAKE_CLAUDE_MODE=ok cx --phase final-review --prompt-file "$PROMPT_FILE" --resume claude_test_session_xyz --role implementer)"
is "$(kv "$out" EXIT)" "0" "resume call exits 0"
has "$(cat "$FAKE_CLAUDE_LOG")" "resume=1" "--resume set -> claude invoked with --resume"
has "$(cat "$FAKE_CLAUDE_LOG")" "permission-mode=default" "implementer role -> write permission-mode (default), derived from --role"

# --- empty --resume == "fresh" (same caller contract as the codex case in 30-invoke) ---
# Skills pass --resume unconditionally with a possibly-empty session file, so an empty value must
# be accepted AND must not put `--resume` on the claude command line.
: > "$FAKE_CLAUDE_LOG"
out="$(FAKE_CLAUDE_MODE=ok cx --phase final-review --prompt-file "$PROMPT_FILE" --resume "")"; rc=$?
is "$rc" "0"                                      "empty --resume is accepted, not rejected as a usage error"
is "$(kv "$out" EXIT)" "0"                        "empty --resume call exits 0"
has "$(cat "$FAKE_CLAUDE_LOG")" "resume=0"        "empty --resume -> claude invoked WITHOUT --resume"

# --- hang: claude never exits -> hard-cap kill (124) ---
SECONDS=0
out="$(FAKE_CLAUDE_MODE=hang cx --phase final-review --prompt-file "$PROMPT_FILE")"
dur=$SECONDS
is "$(kv "$out" EXIT)" "124" "claude process that never exits hits the hard cap (exit 124)"
ok "[ $dur -lt 15 ]" "hard-cap path bounded (did not hang); took ${dur}s"
session_file="$(kv "$out" SESSION_FILE)"
ok "[ -f \"$session_file\" ]" "hard-cap path still writes SESSION_FILE (output contract holds even on timeout)"
# A hard-cap kill captures no id of its own, but it must NOT blank the id an earlier round
# captured (the `ok` call above did): that would read as "this review never had a session",
# which the skills treat as grounds for self-certifying without an external re-review.
is "$(cat "$session_file")" "claude_test_session_xyz" "hard-cap path keeps the previously captured session id"

# --- the OTHER half: a hard cap on the FIRST call of a phase captured no id, so SESSION_FILE must
# exist and be EMPTY, with no "kept the previous one" claim. Same contract as the codex case.
out="$(FAKE_CLAUDE_MODE=hang cx --phase never-called --prompt-file "$PROMPT_FILE" 2>&1)"
first_sf="$(kv "$out" SESSION_FILE)"
ok "[ -f \"$first_sf\" ]" "a first-call hard cap still creates SESSION_FILE"
ok "[ ! -s \"$first_sf\" ]" "...and leaves it empty (no id was ever captured)"
hasnt "$out" "keeping the previously captured one" "...without claiming it preserved an id"

cleanup_sandbox
report
