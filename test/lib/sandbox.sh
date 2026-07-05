# Fixture builders for the harness. Sourced by cases after assert.sh.
# Requires env from run.sh: RUNNER (path to devflow-runner.sh), LIB (this dir), DEVFLOW_TEST_REPO.

# mk_sandbox: fresh fake HOME + fixture git repo + project .devflow.yaml pointing at fake-codex.
# Exports: SB (sandbox root), REPO_FX (fixture project root), HOME, FAKE_CODEX_LOG.
mk_sandbox(){
  SB="$(mktemp -d "${TMPDIR:-/tmp}/devflow-sb.XXXXXX")"
  export HOME="$SB/home"; mkdir -p "$HOME/.devflow"
  export FAKE_CODEX_LOG="$SB/codex.log"; : > "$FAKE_CODEX_LOG"

  # command_path/fallback_command are ONLY trusted from global config
  # (~/.devflow/config.yaml) — never from a project-level .devflow.yaml. The fixture
  # mirrors that trust boundary: the fake-codex path lives here, not in $REPO_FX.
  cat > "$HOME/.devflow/config.yaml" <<YAML
codex:
  command_path: "$LIB/fake-codex"
  fallback_command: ""
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

# bootstrap_here: run the real script's bootstrap subcommand as a subprocess (cwd = fixture
# repo), then source the resulting run.env into THIS shell for the case's own convenience —
# the code under test never relies on that sourcing; it recomputes everything itself on
# every subprocess call, exactly like a real agent invocation would.
bootstrap_here(){
  cd "$REPO_FX" || return 1
  local out
  out="$(bash "$RUNNER" bootstrap)" || { echo "bootstrap failed: $out" >&2; return 1; }
  RUN_DIR="$(printf '%s\n' "$out" | sed -n 's/^RUN_DIR=//p')"
  set -a; . "$RUN_DIR/run.env"; set +a
  export RUN_DIR
}

# RUN_DIR now lives under ${TMPDIR:-/tmp}/devflow-run.<hash> — OUTSIDE $SB (unlike the
# old in-repo `.devflow/run`, which `rm -rf "$SB"` cleaned up as a side effect). Remove it
# explicitly so sandboxed test runs don't leak hashed run dirs into the real $TMPDIR.
cleanup_sandbox(){ [ -n "${RUN_DIR:-}" ] && rm -rf "$RUN_DIR"; [ -n "${SB:-}" ] && rm -rf "$SB"; }
