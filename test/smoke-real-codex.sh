#!/usr/bin/env bash
# LIVE smoke test: drive the REAL scripts/devflow-runner.sh against the REAL codex CLI,
# to confirm fake-codex's event schema matches reality.
#
# This is the one gap the offline harness cannot cover: fake-codex encodes OUR assumptions
# about codex's JSONL event shape. This test proves those assumptions on live codex.
#
# Requires a working codex login. NOT run by run.sh (offline). Run manually:
#   bash test/smoke-real-codex.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
RUNNER="$REPO/scripts/devflow-runner.sh"
. "$HERE/lib/assert.sh"

REAL_CODEX="${DEVFLOW_SMOKE_CODEX:-$(command -v codex || true)}"
[ -x "$REAL_CODEX" ] || { echo "SKIP: no codex binary (set DEVFLOW_SMOKE_CODEX)"; exit 0; }
echo "using real codex: $REAL_CODEX"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/devflow-smoke.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home"; mkdir -p "$HOME/.devflow"

# command_path is only trusted from global config — see Task 1's security note.
cat > "$HOME/.devflow/config.yaml" <<YAML
codex:
  command_path: "$REAL_CODEX"
  fallback_command: ""
YAML

REPO_FX="$WORK/proj"; mkdir -p "$REPO_FX"
( cd "$REPO_FX"; git init -q; git config user.email t@t; git config user.name t
  git config commit.gpgsign false
  printf 'hello\n' > a.txt; git add -A; git commit -qm init )
cat > "$REPO_FX/.devflow.yaml" <<YAML
backend: codex
codex:
  reviewer:    { model: gpt-5.5, effort: low }
  implementer: { model: gpt-5.5, effort: low }
  session_reuse: true
YAML

cd "$REPO_FX"
out="$(bash "$RUNNER" bootstrap)" || { echo "bootstrap failed: $out"; exit 1; }
RUN_DIR="$(printf '%s\n' "$out" | sed -n 's/^RUN_DIR=//p')"
set -a; . "$RUN_DIR/run.env"; set +a
is "$CODEX_BIN" "$REAL_CODEX" "bootstrap resolved the real codex binary"

PROMPT_FILE="$WORK/prompt.txt"
printf 'This is a connectivity smoke test. Reply with exactly one line containing the single word: APPROVED\n' > "$PROMPT_FILE"
export DEVFLOW_POLL_SCHEDULE="5 5 10 15 30 60 60 90"

echo "launching real codex (may take ~30-90s)..."
out="$(bash "$RUNNER" run-external --phase smoke --prompt-file "$PROMPT_FILE")"
kv(){ printf '%s\n' "$1" | sed -n "s/^$2=//p"; }

echo "--- $out ---"
is "$(kv "$out" EXIT)" "0" "real codex call exits 0"
verdict="$(cat "$(kv "$out" VERDICT_FILE)")"
ok "[ -n '$verdict' ]" "verdict text extracted from REAL events (item.completed/agent_message)"
ok "[ -n '$(kv "$out" SESSION_ID)' ]" "thread_id captured from REAL events"
events="$RUN_DIR/smoke-events.jsonl"
ok "grep -q '\"type\":\"turn.completed\"' '$events'" "REAL events contain exact turn.completed marker"

# Schema fidelity: the exact shapes fake-codex emits must appear in real output.
ok "grep -q '\"thread_id\"' '$events'" "real schema has thread_id field (fake-codex matches)"
ok "grep -q '\"agent_message\"' '$events'" "real schema has agent_message item (fake-codex matches)"

echo "== real event types seen =="
grep -o '"type":"[^"]*"' "$events" | sort -u

report
