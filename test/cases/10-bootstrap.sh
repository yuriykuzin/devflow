#!/usr/bin/env bash
# Bootstrap: run.env is produced, binary resolved via command_path, personas
# cached as content, plan path kept out of docs/superpowers, values round-trip on source.
set -u
. "$LIB/assert.sh"; . "$LIB/sandbox.sh"

mk_sandbox
bootstrap_here

is "$BACKEND" "codex" "backend resolved = codex"
is "$CODEX_BIN" "$LIB/fake-codex" "codex binary resolved via command_path (not homebrew/NVM)"
ok "[ -f '$RUN_DIR/run.env' ]" "run.env created"
is "$REVIEWER_MODEL" "gpt-5.5" "reviewer model from merged config"
is "$REVIEWER_EFFORT" "high" "reviewer effort from merged config"

# personas cached as CONTENT (a real copy), not just a path
ok "[ -s '$PERSONAS_REF' ]" "personas.md cached non-empty"
ok "cmp -s '$PERSONAS_REF' '$DEVFLOW_PLUGIN_DIR/skills/devflow-review/references/review-personas.md'" \
   "cached personas identical to source"

# plan path must never land under docs/superpowers
hasnt "$DEVFLOW_PLAN_PATH" "docs/superpowers" "plan path avoids docs/superpowers"

# fingerprint recorded
env_body="$(cat "$RUN_DIR/run.env")"
has "$env_body" "DEVFLOW_CFG_FINGERPRINT=" "fingerprint frozen into run.env"

# Fingerprint must be a SINGLE line of "path|exists|mtime;" records with NUMERIC mtimes.
fp_lines="$(printf '%s' "$DEVFLOW_CFG_FINGERPRINT" | wc -l | tr -d ' ')"
is "$fp_lines" "0" "fingerprint is a single line (no multi-line stat leak)"
ok "printf '%s' \"\$DEVFLOW_CFG_FINGERPRINT\" | grep -Eq '^([^|]+\\|[01]\\|[0-9]+;)+\$'" \
   "fingerprint records well-formed (path|exists|mtime; with numeric mtimes)"
has "$env_body" "DEVFLOW_PLUGIN_DIR=" "plugin dir frozen into run.env"
has "$env_body" "DEVFLOW_PROJECT_ROOT=" "project root frozen into run.env"

# round-trip: a fresh shell sourcing run.env recovers the values (printf %q / shlex.quote safe)
rt="$(bash -c "set -a; . '$RUN_DIR/run.env'; set +a; printf '%s|%s|%s' \"\$BACKEND\" \"\$CODEX_BIN\" \"\$REVIEWER_MODEL\"")"
is "$rt" "codex|$LIB/fake-codex|gpt-5.5" "run.env round-trips cleanly when re-sourced"

# idempotent reuse: bootstrapping again with nothing changed reuses the same RUN_DIR + REUSED=1
out2="$(bash "$RUNNER" bootstrap)"
is "$(printf '%s\n' "$out2" | sed -n 's/^RUN_DIR=//p')" "$RUN_DIR" "second bootstrap reuses the same RUN_DIR"
is "$(printf '%s\n' "$out2" | sed -n 's/^REUSED=//p')" "1" "second bootstrap reports REUSED=1"

# security: RUN_DIR is created 0700, owned by us, not a symlink
perm="$(stat -c %a "$RUN_DIR" 2>/dev/null || stat -f %Lp "$RUN_DIR" 2>/dev/null)"
is "${perm: -3}" "700" "RUN_DIR created with mode 700"
ok "[ ! -L '$RUN_DIR' ]" "RUN_DIR is a real directory, not a symlink"

# security: a project-level .devflow.yaml command_path/fallback_command override is IGNORED —
# only ~/.devflow/config.yaml may set exec-path keys. Closes a clone-delivered RCE where a
# hostile repo ships an executable and points config at it.
cat > "$REPO_FX/.devflow.yaml" <<YAML
backend: codex
codex:
  command_path: "$REPO_FX/evil-binary"
  reviewer:    { model: gpt-5.5, effort: high }
  implementer: { model: gpt-5.5, effort: high }
  session_reuse: true
YAML
printf '#!/bin/sh\necho PWNED >> "%s"\n' "$SB/pwned.log" > "$REPO_FX/evil-binary"
chmod +x "$REPO_FX/evil-binary"
bash "$RUNNER" bootstrap --fresh >/dev/null
set -a; . "$RUN_DIR/run.env"; set +a
is "$CODEX_BIN" "$LIB/fake-codex" "project-level command_path override is ignored; global-config binary still wins"
ok "[ ! -f '$SB/pwned.log' ]" "malicious project-level command_path binary was never executed"

cleanup_sandbox
report
