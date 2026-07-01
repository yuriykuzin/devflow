#!/usr/bin/env bash
# LIVE smoke test: drive the REAL runner (Section A bootstrap + Section B invocation)
# against the REAL codex CLI, to confirm fake-codex's event schema matches reality.
#
# This is the one gap the offline harness cannot cover: fake-codex encodes OUR assumptions
# about codex's JSONL event shape. This test proves those assumptions on live codex.
#
# Requires a working codex login. NOT run by run.sh (offline). Run manually:
#   bash test/smoke-real-codex.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
RUNNER="$REPO/skills/using-devflow/references/cross-tool-runner.md"
. "$HERE/lib/assert.sh"

REAL_CODEX="${DEVFLOW_SMOKE_CODEX:-$(command -v codex || true)}"
[ -x "$REAL_CODEX" ] || { echo "SKIP: no codex binary (set DEVFLOW_SMOKE_CODEX)"; exit 0; }
echo "using real codex: $REAL_CODEX"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/devflow-smoke.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
EXTRACTED="$WORK/extracted"
python3 "$HERE/lib/extract-bash.py" "$RUNNER" "$EXTRACTED" || exit 1

# Sandbox: fixture repo with a project config pointing at the REAL codex. HOME is left
# real so codex uses its native ~/.codex auth; the project .devflow.yaml overrides backend
# + command_path + effort regardless of any real ~/.devflow/config.yaml.
REPO_FX="$WORK/proj"; mkdir -p "$REPO_FX"
( cd "$REPO_FX"; git init -q; git config user.email t@t; git config user.name t
  printf 'hello\n' > a.txt; git add -A; git commit -qm init )
cat > "$REPO_FX/.devflow.yaml" <<YAML
backend: codex
codex:
  command_path: "$REAL_CODEX"
  reviewer:    { model: gpt-5.5, effort: low }
  implementer: { model: gpt-5.5, effort: low }
  session_reuse: true
  fallback_command: ""
YAML
export DEVFLOW_PLUGIN_DIR="$REPO"

cd "$REPO_FX"
. "$EXTRACTED/a1.sh"; . "$EXTRACTED/a2.sh"; . "$EXTRACTED/a3.sh"
. "$EXTRACTED/b.sh"

is "$CODEX_BIN" "$REAL_CODEX" "bootstrap resolved the real codex binary"

PHASE="smoke"; MODEL="$REVIEWER_MODEL"; EFFORT="$REVIEWER_EFFORT"; RESUME_ID=""
PROMPT="This is a connectivity smoke test. Reply with exactly one line containing the single word: APPROVED"
export DEVFLOW_POLL_SCHEDULE="5 5 10 15 30 60 60 90"

echo "launching real codex (may take ~30-90s)..."
devflow_run_external "$CODEX_BIN"

echo "--- exit=$CODEX_EXIT  session=$SESSION_ID ---"
echo "--- verdict text: $CALL_RESULT ---"

is "$CODEX_EXIT" "0" "real codex call exits 0"
ok "[ -n '$CALL_RESULT' ]" "verdict text extracted from REAL events (item.completed/agent_message)"
ok "[ -n '$SESSION_ID' ]" "thread_id captured from REAL events"
ok "grep -q '\"type\":\"turn.completed\"' '$EVENTS'" "REAL events contain exact turn.completed marker"

# Schema fidelity: the exact shapes fake-codex emits must appear in real output.
ok "grep -q '\"thread_id\"' '$EVENTS'" "real schema has thread_id field (fake-codex matches)"
ok "grep -q '\"agent_message\"' '$EVENTS'" "real schema has agent_message item (fake-codex matches)"

echo "== real event types seen =="
grep -o '"type":"[^"]*"' "$EVENTS" | sort -u

report
