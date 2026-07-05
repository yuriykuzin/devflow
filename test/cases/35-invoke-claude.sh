#!/usr/bin/env bash
# run-external against the DEFAULT backend (claude). Unlike codex, there is no
# claude.command_path config override (the trust-boundary hardening in Task 1 restricts
# exec-path override keys to codex; claude resolution is always `command -v claude`), so
# this fixture shims PATH with a `claude` executable pointing at fake-claude, instead of
# writing a command_path into config the way mk_sandbox does for fake-codex.
set -u
export DEVFLOW_POLL_SCHEDULE="1 1 1 1 1 1"
export DEVFLOW_DRAIN_SCHEDULE="0.2 0.2 0.2 0.2 0.2 0.2"
. "$LIB/assert.sh"; . "$LIB/sandbox.sh"

mk_sandbox

cat > "$REPO_FX/.devflow.yaml" <<YAML
backend: claude
claude:
  reviewer:    { model: claude-opus-4-8, effort: max }
  implementer: { model: claude-sonnet-5, effort: high }
  session_reuse: true
YAML
FAKE_CLAUDE_BIN_DIR="$SB/bin"; mkdir -p "$FAKE_CLAUDE_BIN_DIR"
ln -sf "$LIB/fake-claude" "$FAKE_CLAUDE_BIN_DIR/claude"
export PATH="$FAKE_CLAUDE_BIN_DIR:$PATH"
export FAKE_CLAUDE_LOG="$SB/claude.log"; : > "$FAKE_CLAUDE_LOG"

bootstrap_here
is "$BACKEND" "claude" "sandbox bootstrapped with backend=claude"
is "$CLAUDE_BIN" "$FAKE_CLAUDE_BIN_DIR/claude" "CLAUDE_BIN resolved via PATH to the fake binary"

PROMPT_FILE="$SB/prompt.txt"; printf 'review please\n' > "$PROMPT_FILE"
kv(){ printf '%s\n' "$1" | sed -n "s/^$2=//p"; }

# --- normal success: .result/.session_id parsed (not codex's JSONL-events parsing) ---
out="$(cd "$REPO_FX" && env FAKE_CLAUDE_MODE=ok bash "$RUNNER" run-external --phase final-review --prompt-file "$PROMPT_FILE")"
is "$(kv "$out" EXIT)" "0" "normal claude call exits 0"
has "$(cat "$(kv "$out" VERDICT_FILE)")" "APPROVED" "verdict text extracted from .result"
is "$(kv "$out" VERDICT_STATUS)" "APPROVED" "VERDICT_STATUS parsed from claude's result text"
is "$(kv "$out" SESSION_ID)" "claude_test_session_xyz" "session_id captured from .session_id"
ok "[ -s '$(kv "$out" SESSION_FILE)' ]" "session file written for resume"
has "$(cat "$FAKE_CLAUDE_LOG")" "permission-mode=plan" "default permission-mode (plan) passed through"

# --- ephemeral (--no-session-reuse) -> claude invoked with --no-session-persistence ---
out="$(cd "$REPO_FX" && env FAKE_CLAUDE_MODE=ok bash "$RUNNER" run-external --phase final-review --prompt-file "$PROMPT_FILE" --no-session-reuse)"
is "$(kv "$out" EXIT)" "0" "ephemeral claude call still exits 0"
ok "[ ! -s '$(kv "$out" SESSION_FILE)' ]" "ephemeral call persists no session"
has "$(tail -1 "$FAKE_CLAUDE_LOG")" "no-session-persistence=1" "--no-session-reuse -> claude invoked with --no-session-persistence"

# --- resume + non-default permission-mode (mirrors the implementer-handoff call shape) ---
: > "$FAKE_CLAUDE_LOG"
out="$(cd "$REPO_FX" && env FAKE_CLAUDE_MODE=ok bash "$RUNNER" run-external --phase final-review --prompt-file "$PROMPT_FILE" --resume claude_test_session_xyz --permission-mode default)"
is "$(kv "$out" EXIT)" "0" "resume call exits 0"
has "$(cat "$FAKE_CLAUDE_LOG")" "resume=1" "--resume set -> claude invoked with --resume"
has "$(cat "$FAKE_CLAUDE_LOG")" "permission-mode=default" "--permission-mode default passed through"

# --- hang: claude never exits -> hard-cap kill (124) ---
SECONDS=0
out="$(cd "$REPO_FX" && env FAKE_CLAUDE_MODE=hang bash "$RUNNER" run-external --phase final-review --prompt-file "$PROMPT_FILE")"
dur=$SECONDS
is "$(kv "$out" EXIT)" "124" "claude process that never exits hits the hard cap (exit 124)"
ok "[ $dur -lt 15 ]" "hard-cap path bounded (did not hang); took ${dur}s"
session_file="$(kv "$out" SESSION_FILE)"
ok "[ -f \"$session_file\" ]" "hard-cap path still writes SESSION_FILE (output contract holds even on timeout)"
ok "[ ! -s \"$session_file\" ]" "hard-cap path's SESSION_FILE is empty (no session captured)"

cleanup_sandbox
report
