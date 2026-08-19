# Fixture builders for the harness. Sourced by cases after assert.sh.
# Requires env from run.sh: RUNNER (path to devflow-runner.sh), LIB (this dir), DEVFLOW_TEST_REPO.

# mk_sandbox: fresh fake HOME + fixture git repo + project .devflow.yaml pointing at fake-codex.
# Exports: SB (sandbox root), REPO_FX (fixture project root), HOME, FAKE_CODEX_LOG.
mk_sandbox(){
  SB="$(mktemp -d "${TMPDIR:-/tmp}/devflow-sb.XXXXXX")"
  export HOME="$SB/home"; mkdir -p "$HOME/.devflow"
  export FAKE_CODEX_LOG="$SB/codex.log"; : > "$FAKE_CODEX_LOG"

  # command_path is ONLY trusted from global config (~/.devflow/config.yaml) — never from a
  # project-level .devflow.yaml. The fixture mirrors that trust boundary: the fake-codex path
  # lives here, not in $REPO_FX.
  cat > "$HOME/.devflow/config.yaml" <<YAML
codex:
  command_path: "$LIB/fake-codex"
YAML

  REPO_FX="$SB/proj"; mkdir -p "$REPO_FX"
  (
    cd "$REPO_FX" || exit 1
    git init -q
    git config user.email t@example.test
    git config user.name  tester
    git config commit.gpgsign false
    printf 'v1\n' > a.txt
    printf 'v1\n' > b.txt
    git add -A && git commit -qm "init"
  )

  cat > "$REPO_FX/.devflow.yaml" <<YAML
backend: codex
codex:
  reviewer:    { model: gpt-5.5, effort: high }
  implementer: { model: gpt-5.5, effort: high }
  session_reuse: true
YAML

  export SB REPO_FX
}

# run_dir_here: ask the real script for this fixture repo's (secured) RUN_DIR and export it,
# exactly as a skill does with `devflow-runner.sh dir` before its first call. No config is
# frozen — the runner resolves the codex binary per call from the trusted config, and cases
# pass --backend/--model/--effort to run-external explicitly (the values a skill would have
# read from .devflow.yaml itself).
run_dir_here(){
  cd "$REPO_FX" || return 1
  local out
  out="$(bash "$RUNNER" dir)" || { echo "dir failed: $out" >&2; return 1; }
  RUN_DIR="$(printf '%s\n' "$out" | sed -n 's/^RUN_DIR=//p')"
  export RUN_DIR
}

# rx <run-external flags...>: invoke run-external for the codex fixture with the fixed
# backend/model/effort a skill would supply after reading .devflow.yaml, so cases don't
# repeat them. Runs in $REPO_FX. FAKE_CODEX_MODE / FAKE_CODEX_VERDICT are read from the
# environment — set them inline: `FAKE_CODEX_MODE=ok rx --phase p --prompt-file f`.
rx(){ ( cd "$REPO_FX" && bash "$RUNNER" run-external --backend codex --model gpt-5.5 --effort high "$@" ); }

# RUN_DIR lives under $HOME/.devflow/run/devflow-run.<hash> (NOT $TMPDIR — a write-mode
# implementer call's writable root; see cross-tool-runner.md "Security"). HOME is sandboxed, so it
# lands inside $SB — but the removal below stays explicit, because a case that overrides
# DEVFLOW_RUN_HOME (15-gc) or HOME would otherwise leak a hashed run dir. Formerly the dir was
# in $TMPDIR, outside $SB entirely, which is why this explicit cleanup exists at all.
cleanup_sandbox(){ [ -n "${RUN_DIR:-}" ] && rm -rf "$RUN_DIR"; [ -n "${SB:-}" ] && rm -rf "$SB"; }
