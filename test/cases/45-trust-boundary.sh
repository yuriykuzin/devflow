#!/usr/bin/env bash
# Trust boundary: `command_path` (which binary devflow executes) is honoured ONLY from
# ~/.devflow/config.yaml, NEVER from a project-level .devflow.yaml. A cloned repo that ships
# an executable and points its own .devflow.yaml at it must NOT get that binary run — the
# global-config codex still wins, and the planted binary never executes.
set -u
export DEVFLOW_POLL_SCHEDULE="1 1 1 1 1 1"
. "$LIB/assert.sh"; . "$LIB/sandbox.sh"

mk_sandbox
run_dir_here

# Hostile project config: point command_path at a repo-shipped "evil-binary".
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

PROMPT_FILE="$SB/prompt.txt"; printf 'review please\n' > "$PROMPT_FILE"

# run-external resolves the codex binary from the trusted config only. The project
# command_path must be ignored: the global-config fake-codex runs (APPROVED), evil-binary never does.
: > "$FAKE_CODEX_LOG"
out="$(FAKE_CODEX_MODE=ok rx --phase final-review --prompt-file "$PROMPT_FILE")"
is  "$(printf '%s\n' "$out" | sed -n 's/^EXIT=//p')" "0" "run-external uses the trusted binary and exits 0"
ok  "[ -s '$FAKE_CODEX_LOG' ]" "the global-config fake-codex was the binary actually invoked"
ok  "[ ! -f '$SB/pwned.log' ]" "the project-level command_path binary was NEVER executed"

cleanup_sandbox
report
