#!/usr/bin/env bash
# Section A bootstrap: run.env is produced, binary resolved via command_path, personas
# cached as content, plan path kept out of docs/superpowers, values round-trip on source.
set -u
. "$LIB/assert.sh"; . "$LIB/sandbox.sh"

mk_sandbox
bootstrap_here

is "$BACKEND" "codex" "backend resolved = codex"
is "$CODEX_BIN" "$LIB/fake-codex" "codex binary resolved via command_path (not homebrew/NVM)"
ok "[ -f '$DEVFLOW_RUN_ENV' ]" "run.env created"
is "$REVIEWER_MODEL" "gpt-5.5" "reviewer model from merged config"
is "$REVIEWER_EFFORT" "high" "reviewer effort from merged config"

# personas cached as CONTENT (a real copy), not just a path
ok "[ -s '$PERSONAS_REF' ]" "personas.md cached non-empty"
ok "cmp -s '$PERSONAS_REF' '$DEVFLOW_PLUGIN_DIR/skills/devflow-review/references/review-personas.md'" \
   "cached personas identical to source"

# plan path must never land under docs/superpowers
hasnt "$DEVFLOW_PLAN_PATH" "docs/superpowers" "plan path avoids docs/superpowers"

# fingerprint recorded
env_body="$(cat "$DEVFLOW_RUN_ENV")"
has "$env_body" "DEVFLOW_CFG_FINGERPRINT=" "fingerprint frozen into run.env"

# Fingerprint must be a SINGLE line of "path|exists|mtime;" records with NUMERIC mtimes.
# Catches the GNU `stat -f` regression, which leaks multi-line volatile filesystem stats.
# Check "no newline" FIRST: a line-anchored regex alone matches each line independently and
# would wave a multi-line leak through — the newline check is what actually catches it.
fp_lines="$(printf '%s' "$DEVFLOW_CFG_FINGERPRINT" | wc -l | tr -d ' ')"
is "$fp_lines" "0" "fingerprint is a single line (no multi-line stat leak)"
ok "printf '%s' \"\$DEVFLOW_CFG_FINGERPRINT\" | grep -Eq '^([^|]+\\|[01]\\|[0-9]+;)+\$'" \
   "fingerprint records well-formed (path|exists|mtime; with numeric mtimes)"
has "$env_body" "DEVFLOW_PLUGIN_DIR=" "plugin dir frozen into run.env"
has "$env_body" "DEVFLOW_PROJECT_ROOT=" "project root frozen into run.env"

# round-trip: a fresh shell sourcing run.env recovers the values (printf %q / shlex.quote safe)
rt="$(bash -c "set -a; . '$DEVFLOW_RUN_ENV'; set +a; printf '%s|%s|%s' \"\$BACKEND\" \"\$CODEX_BIN\" \"\$REVIEWER_MODEL\"")"
is "$rt" "codex|$LIB/fake-codex|gpt-5.5" "run.env round-trips cleanly when re-sourced"

cleanup_sandbox
report
