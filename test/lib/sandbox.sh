# Fixture builders for the harness. Sourced by cases after assert.sh.
# Requires env from run.sh: EXTRACTED (dir with a1..d.sh), LIB (this dir), DEVFLOW_TEST_REPO.

# mk_sandbox: fresh fake HOME + fixture git repo + project .devflow.yaml pointing at fake-codex.
# Exports: SB (sandbox root), REPO_FX (fixture project root), HOME, FAKE_CODEX_LOG.
mk_sandbox(){
  SB="$(mktemp -d "${TMPDIR:-/tmp}/devflow-sb.XXXXXX")"
  export HOME="$SB/home"; mkdir -p "$HOME/.devflow"
  : > "$HOME/.devflow/config.yaml"                 # empty global override (defaults come from plugin dir)
  # Redirect TMPDIR into the sandbox so the runner's RUN_DIR + last-run land under $SB and are
  # cleaned with it — no more leaked /tmp/devflow-run.* dirs accumulating across test runs.
  export TMPDIR="$SB/tmp"; mkdir -p "$TMPDIR"
  export FAKE_CODEX_LOG="$SB/codex.log"; : > "$FAKE_CODEX_LOG"

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
  command_path: "$LIB/fake-codex"
  reviewer:    { model: gpt-5.5, effort: high }
  implementer: { model: gpt-5.5, effort: high }
  session_reuse: true
  fallback_command: ""
YAML

  export DEVFLOW_PLUGIN_DIR="$DEVFLOW_TEST_REPO"   # real checkout -> real config.default.yaml + personas
  # Start each case from a clean bootstrap slate.
  unset DEVFLOW_RUN_ENV DEVFLOW_REUSE_LAST_RUN REUSE RUN_DIR
  rm -f "${TMPDIR:-/tmp}/devflow-last-run"
  export SB REPO_FX
}

# bootstrap_here: source A.1/A.2/A.3 with cwd = fixture repo. Leaves run.env sourced.
bootstrap_here(){
  cd "$REPO_FX" || return 1
  # shellcheck disable=SC1090
  . "$EXTRACTED/a1.sh"
  . "$EXTRACTED/a2.sh"
  . "$EXTRACTED/a3.sh"
}

cleanup_sandbox(){ [ -n "${SB:-}" ] && rm -rf "$SB"; }
