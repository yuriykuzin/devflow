#!/usr/bin/env bash
# Devflow cross-tool runner — mechanics for bootstrap, scope-pinning, and external
# CLI invocation (codex/claude), shared by all devflow skills across all hosts.
# See skills/using-devflow/references/cross-tool-runner.md for the agent-facing guide.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEVFLOW_PLUGIN_DIR="$(cd "$SELF_DIR/.." && pwd)"
DEVFLOW_PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
_DEVFLOW_SELF_ROOT="$DEVFLOW_PROJECT_ROOT"   # cached: cwd can't change before the re-assert below needs it

# RUN_DIR lives OUTSIDE the repo tree, under a hash of the project root — deterministic
# (every invocation recomputes the same path, no mktemp/exported pointer to lose) but
# never inside the working tree, so a hostile clone can never *deliver* a tracked
# run.env/config.env into a path we later source (the original design's in-repo
# `.devflow/run` made that a same-day RCE: `.gitignore` only blocks *future* untracked
# additions, not files the clone already ships tracked).
_devflow_hash() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 | cut -c1-16
  elif command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -c1-16
  else cksum | cut -d' ' -f1
  fi
}
DEVFLOW_ROOT_HASH="$(printf '%s' "$DEVFLOW_PROJECT_ROOT" | _devflow_hash)"
RUN_DIR="${TMPDIR:-/tmp}/devflow-run.$DEVFLOW_ROOT_HASH"

# Never source a run.env we don't fully control: reject symlinks, anything not owned by
# us, and anything group/other-writable. This is the actual gate against a predictable
# shared-/tmp path being pre-planted by another user, and against a run.env whose
# permissions were loosened after the fact. GNU stat (`-c`) tried first per this file's
# existing convention (see devflow_cfg_fingerprint); BSD/macOS falls back to `-f`.
devflow_env_file_safe() {
  local f="$1" owner perm tail
  [ -f "$f" ] && [ ! -L "$f" ] || return 1
  owner="$(stat -c %u "$f" 2>/dev/null || stat -f %u "$f" 2>/dev/null)"
  [ "$owner" = "$(id -u)" ] || return 1
  perm="$(stat -c %a "$f" 2>/dev/null || stat -f %Lp "$f" 2>/dev/null)"
  tail="${perm: -3}"   # owner/group/other digits — ignore any leading setuid/gid/sticky digit
  case "$tail" in
    ?[2367]?|??[2367]) return 1 ;;   # group-writable (middle digit) or other-writable (last digit)
  esac
  return 0
}

# Create (if absent) and enforce 0700 + ownership on RUN_DIR before trusting anything
# inside it — defeats pre-planting the deterministic path as a symlink or as a
# different-owner directory on a shared host. Runs on every invocation, before any
# subcommand (bootstrap/scope/run-external alike) touches the directory.
devflow_secure_dir() {
  local d="$1" owner perm
  if [ -e "$d" ] && [ -L "$d" ]; then
    echo "devflow: FATAL — $d is a symlink; refusing to use it. Remove it and retry." >&2; exit 1
  fi
  mkdir -p "$d" 2>/dev/null
  [ -d "$d" ] || { echo "devflow: FATAL — $d exists but is not a directory; refusing to use it." >&2; exit 1; }
  chmod 700 "$d" 2>/dev/null
  owner="$(stat -c %u "$d" 2>/dev/null || stat -f %u "$d" 2>/dev/null)"
  [ "$owner" = "$(id -u)" ] || { echo "devflow: FATAL — $d is not owned by the current user; refusing to use it." >&2; exit 1; }
  perm="$(stat -c %a "$d" 2>/dev/null || stat -f %Lp "$d" 2>/dev/null)"
  [ "${perm: -3}" = "700" ] || { echo "devflow: FATAL — $d has unsafe permissions ($perm, expected 700)." >&2; exit 1; }
}
devflow_secure_dir "$RUN_DIR"

# Auto-load a prior run's frozen state, if any (and only if it passes the safety check
# above). A stale/foreign run.env may itself contain
# DEVFLOW_PLUGIN_DIR/DEVFLOW_PROJECT_ROOT/RUN_DIR/SELF_DIR — those four are ALWAYS
# self-derived, never trusted from a file, so re-assert them immediately after sourcing.
devflow_env_file_safe "$RUN_DIR/run.env" && { set -a; . "$RUN_DIR/run.env"; set +a; }
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEVFLOW_PLUGIN_DIR="$(cd "$SELF_DIR/.." && pwd)"
DEVFLOW_PROJECT_ROOT="$_DEVFLOW_SELF_ROOT"   # re-assert the pre-sourcing value, not a re-run of `git rev-parse`: cwd is unchanged since it was cached above, so the two calls would only ever agree — reuse instead of paying a second subprocess for the same answer
RUN_DIR="${TMPDIR:-/tmp}/devflow-run.$DEVFLOW_ROOT_HASH"

# ── Section A helpers ──────────────────────────────────────────────────────────
# Files whose presence+mtime define config validity:
devflow_cfg_files() {
  printf '%s\n' "$DEVFLOW_PLUGIN_DIR/config.default.yaml" "$HOME/.devflow/config.yaml" \
                "$DEVFLOW_PROJECT_ROOT/.devflow.yaml" \
                "$DEVFLOW_PLUGIN_DIR/skills/devflow-review/references/review-personas.md"
}
# Build the validity fingerprint: "path|exists|mtime;" for every tracked file.
devflow_cfg_fingerprint() {
  local f m e out=""
  while IFS= read -r f; do
    # GNU stat FIRST (`-c %Y`): on Linux `-f` means --file-system and would emit volatile
    # filesystem stats into the fingerprint. On BSD/macOS `-c` errors, so fall back to `-f %m`.
    if [ -f "$f" ]; then e=1; m="$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null)"; else e=0; m=0; fi
    out="$out$f|$e|$m;"
  done < <(devflow_cfg_files)
  printf '%s' "$out"
}
# valid <env-file> → 0 if the env file is safe to source (devflow_env_file_safe), matches
# the CURRENT project/plugin, AND its recorded fingerprint still matches the live
# config/persona files. Called by bootstrap AND by scope/run-external (via
# devflow_require_valid_env below) — validating once at bootstrap and then trusting the
# file unconditionally for the rest of the run is how a stale/tampered run.env would slip
# past every later subcommand.
devflow_env_valid() {
  local env="$1"
  devflow_env_file_safe "$env" || return 1
  local cur_root="$DEVFLOW_PROJECT_ROOT" cur_plugin="$DEVFLOW_PLUGIN_DIR"
  ( set -a; . "$env"; set +a
    [ "$DEVFLOW_PROJECT_ROOT" = "$cur_root" ]   || exit 1   # same repo?
    [ "$DEVFLOW_PLUGIN_DIR"   = "$cur_plugin" ] || exit 1   # same plugin install?
    DEVFLOW_PROJECT_ROOT="$cur_root"; DEVFLOW_PLUGIN_DIR="$cur_plugin"
    [ "$DEVFLOW_CFG_FINGERPRINT" = "$(devflow_cfg_fingerprint)" ] || exit 1
  ) || return 1
}
# Gate for scope/run-external: if a run.env exists but no longer validates (config
# changed, ownership/perms loosened, foreign project), refuse instead of silently
# running with stale or untrusted values. Bootstrap alone re-validating was the gap —
# scope/run-external used to trust whatever was already auto-loaded.
devflow_require_valid_env() {
  if [ -f "$RUN_DIR/run.env" ] && ! devflow_env_valid "$RUN_DIR/run.env"; then
    echo "devflow: FATAL — $RUN_DIR/run.env is stale, foreign, or unsafe to trust. Run 'bootstrap' again." >&2
    exit 1
  fi
}

# ── bootstrap ───────────────────────────────────────────────────────────────────
cmd_bootstrap() {
  local fresh=0 slug=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --fresh) fresh=1; shift ;;
      --slug) slug="$2"; shift 2 ;;
      *) echo "devflow: bootstrap: unknown flag '$1'" >&2; exit 2 ;;
    esac
  done
  [ "$fresh" = "1" ] && rm -rf "$RUN_DIR" && devflow_secure_dir "$RUN_DIR"

  if devflow_env_valid "$RUN_DIR/run.env"; then
    # A reused run.env is only a full skip if the caller didn't ask for a different
    # plan-path slug than the one already frozen — otherwise DEVFLOW_PLAN_PATH would
    # silently keep pointing at the old feature's file. DEVFLOW_PLAN_SLUG is %q-encoded
    # (printf '%q'), so eval-unquote it the same way run.env itself is sourced elsewhere.
    local existing_slug=""
    existing_slug="$(sed -n 's/^DEVFLOW_PLAN_SLUG=//p' "$RUN_DIR/run.env" | tail -1)"
    [ -n "$existing_slug" ] && eval "existing_slug=$existing_slug"
    if [ -z "$slug" ] || [ "$slug" = "$existing_slug" ]; then
      echo "RUN_DIR=$RUN_DIR"
      echo "REUSED=1"
      return 0
    fi
    # slug differs from what's frozen for this project's deterministic RUN_DIR — a
    # same-day second feature landing on the same path. Rewriting run.env alone isn't
    # enough: every phase session file (plan-review.session, impl-review.session, ...)
    # from the FIRST feature would still be sitting in RUN_DIR and get silently resumed
    # by the second feature's skill steps. Treat this exactly like --fresh: wipe the
    # whole directory and rebuild.
    rm -rf "$RUN_DIR"
  fi

  devflow_secure_dir "$RUN_DIR"

  # ── resolve config (read YAML once) ─────────────────────────────────────────
  # Concrete merge: defaults ← ~/.devflow/config.yaml ← ./.devflow.yaml — EXCEPT
  # command_path/fallback_command, which resolve from defaults ← ~/.devflow/config.yaml
  # ONLY. Those two are exec-path keys; a project-level .devflow.yaml (checked into a
  # repo you might clone from someone else) must never be able to point devflow at an
  # arbitrary binary shipped in the same clone.
  python3 - "$DEVFLOW_PLUGIN_DIR" "$DEVFLOW_PROJECT_ROOT" > "$RUN_DIR/config.env" <<'PY'
import os, sys, functools, shlex
try:
    import yaml
except ImportError:
    sys.exit(0)
plugin, root = sys.argv[1], sys.argv[2]
def load(p):
    try:
        with open(os.path.expanduser(p)) as f: return yaml.safe_load(f) or {}
    except FileNotFoundError:
        return {}
def merge(a, b):
    o = dict(a)
    for k, v in (b or {}).items():
        o[k] = merge(a.get(k, {}), v) if isinstance(v, dict) and isinstance(a.get(k), dict) else v
    return o
DEFAULTS = load(os.path.join(plugin, 'config.default.yaml'))
GLOBAL   = load('~/.devflow/config.yaml')
PROJECT  = load(os.path.join(root, '.devflow.yaml'))
trusted = functools.reduce(merge, [DEFAULTS, GLOBAL], {})   # command_path/fallback_command ONLY from here
cfg     = merge(trusted, PROJECT)                            # everything else may come from the project too
be  = cfg.get('backend', 'claude')
sec = cfg.get(be, {}) or {}
sec_trusted = trusted.get(be, {}) or {}
rev = sec.get('reviewer', {}) or {}
imp = sec.get('implementer', {}) or {}
def emit(k, v): print('%s=%s' % (k, shlex.quote('' if v is None else str(v))))
emit('BACKEND', be)
emit('REVIEWER_MODEL', rev.get('model'));       emit('REVIEWER_EFFORT', rev.get('effort'))
emit('IMPLEMENTER_MODEL', imp.get('model'));     emit('IMPLEMENTER_EFFORT', imp.get('effort'))
emit('SESSION_REUSE', str(sec.get('session_reuse', True)).lower())
emit('FALLBACK_COMMAND', sec_trusted.get('fallback_command', ''))
emit('CODEX_COMMAND_PATH', sec_trusted.get('command_path', ''))
emit('OUTPUT_DIR', cfg.get('output_dir', 'docs/devflow/reports'))
PY

  if [ -s "$RUN_DIR/config.env" ]; then
    set -a; . "$RUN_DIR/config.env"; set +a
  else
    echo "devflow: FATAL — PyYAML unavailable; cannot resolve config." >&2
    exit 1
  fi

  # ── cache persona definitions (content, not just a path) ────────────────────
  local PERSONAS_SRC="$DEVFLOW_PLUGIN_DIR/skills/devflow-review/references/review-personas.md"
  if [ -f "$PERSONAS_SRC" ]; then
    cp "$PERSONAS_SRC" "$RUN_DIR/personas.md"
  else
    echo "devflow: WARN — review-personas.md not found at $PERSONAS_SRC; internal review will fall back to single-reviewer." >&2
  fi

  # ── resolve & validate the codex binary (codex backend only) ────────────────
  # A bare `codex` can hit an NVM-shadowed old CLI lacking --json + needing TTY auth.
  # Pick the first candidate that supports `exec --json`; never persist one that doesn't.
  local CODEX_BIN="" CLAUDE_BIN=""
  if [ "$BACKEND" = "codex" ]; then
    for cand in "$CODEX_COMMAND_PATH" /opt/homebrew/bin/codex /usr/local/bin/codex $(which -a codex 2>/dev/null); do
      [ -n "$cand" ] && [ -x "$cand" ] || continue
      if "$cand" exec --help < /dev/null 2>&1 | grep -q -- '--json'; then CODEX_BIN="$cand"; break; fi
    done
    if [ -z "$CODEX_BIN" ]; then
      echo "devflow: FATAL — no codex binary supports 'exec --json'." >&2
      echo "  Tried: ${CODEX_COMMAND_PATH:-<unset>} /opt/homebrew/bin/codex /usr/local/bin/codex $(which -a codex 2>/dev/null | tr '\n' ' ')" >&2
      echo "  Fix: set codex.command_path in ~/.devflow/config.yaml to the absolute path of the Rust codex CLI." >&2
      exit 1
    fi
  else
    CLAUDE_BIN="$(command -v claude)"
    [ -n "$CLAUDE_BIN" ] || { echo "devflow: FATAL — claude CLI not found on PATH." >&2; exit 1; }
  fi

  # ── canonical plan path (safe location, never docs/superpowers) ─────────────
  local DEFAULT_DATE PLAN_DIR DEVFLOW_PLAN_PATH
  DEFAULT_DATE="$(date -u +%F 2>/dev/null || echo plan)"
  case "$OUTPUT_DIR" in
    docs/superpowers*|"") PLAN_DIR="$RUN_DIR" ;;        # untracked-unsafe → fall back to run dir
    *)                    PLAN_DIR="$OUTPUT_DIR/plans" ;;
  esac
  DEVFLOW_PLAN_PATH="$PLAN_DIR/$DEFAULT_DATE-${slug:-feature}.md"   # pass --slug to avoid same-day collisions

  # ── freeze everything into run.env ───────────────────────────────────────────
  {
    echo "# devflow run env — frozen once per run"
    cat "$RUN_DIR/config.env" 2>/dev/null
    printf 'DEVFLOW_PLUGIN_DIR=%q\n'     "$DEVFLOW_PLUGIN_DIR"
    printf 'DEVFLOW_PROJECT_ROOT=%q\n'   "$DEVFLOW_PROJECT_ROOT"
    printf 'DEVFLOW_CFG_FINGERPRINT=%q\n' "$(devflow_cfg_fingerprint)"
    printf 'RUN_DIR=%q\n'                "$RUN_DIR"
    printf 'CODEX_BIN=%q\n'              "$CODEX_BIN"
    printf 'CLAUDE_BIN=%q\n'             "$CLAUDE_BIN"
    printf 'PERSONAS_REF=%q\n'           "$RUN_DIR/personas.md"
    printf 'DEVFLOW_PLAN_PATH=%q\n'      "$DEVFLOW_PLAN_PATH"
    printf 'DEVFLOW_PLAN_SLUG=%q\n'      "$slug"
    printf 'PLAN_SESSION_FILE=%q\n'      "$RUN_DIR/plan-review.session"
  } > "$RUN_DIR/run.env"

  echo "RUN_DIR=$RUN_DIR"
  echo "REUSED=0"
}

# ── scope ────────────────────────────────────────────────────────────────────
cmd_scope() {
  devflow_require_valid_env
  local SCOPE_MODE="${1:-}"; shift || true
  local REVIEW_BASE="" PR_NUMBER="" DEVFLOW_IMPL_BASE="" DEVFLOW_PLAN_PATH="${DEVFLOW_PLAN_PATH:-}"
  local -a EXPLICIT_FILES=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --base|--pr|--impl-base|--plan-path)
        [ $# -ge 2 ] || { echo "devflow: scope: $1 requires a value" >&2; exit 2; }
        case "$1" in
          --base) REVIEW_BASE="$2" ;;
          --pr) PR_NUMBER="$2" ;;
          --impl-base) DEVFLOW_IMPL_BASE="$2" ;;
          --plan-path) DEVFLOW_PLAN_PATH="$2" ;;
        esac
        shift 2 ;;
      --) shift; EXPLICIT_FILES=("$@"); break ;;
      *) echo "devflow: scope: unknown flag '$1'" >&2; exit 2 ;;
    esac
  done
  [ -n "$SCOPE_MODE" ] || { echo "devflow: scope: mode required (uncommitted|staged|last-commit|implementation|branch|pr|files|plan)" >&2; exit 2; }

  local FILES DIFF_CMD
  case "$SCOPE_MODE" in
    uncommitted)   FILES="$(git diff --name-only HEAD)";            DIFF_CMD='git diff HEAD -- <files>' ;;
    staged)        FILES="$(git diff --cached --name-only)";        DIFF_CMD='git diff --cached -- <files>' ;;
    last-commit)
      git rev-parse --verify -q HEAD^ >/dev/null 2>&1 \
        || { echo "devflow: last-commit scope needs a parent commit (HEAD^ missing on a single-commit repo)." >&2; exit 1; }
      FILES="$(git diff --name-only HEAD^ HEAD)";                   DIFF_CMD='git show HEAD  # or git diff HEAD^..HEAD -- <files>' ;;
    implementation)
      [ -n "$DEVFLOW_IMPL_BASE" ] \
        || { echo "devflow: implementation scope needs --impl-base (the pre-implementation commit)." >&2; exit 1; }
      git rev-parse --verify -q "${DEVFLOW_IMPL_BASE}^{commit}" >/dev/null 2>&1 \
        || { echo "devflow: --impl-base ('$DEVFLOW_IMPL_BASE') is not a valid commit — refusing to emit an empty scope." >&2; exit 1; }
      FILES="$(git diff --name-only "$DEVFLOW_IMPL_BASE")";         DIFF_CMD="git diff $DEVFLOW_IMPL_BASE -- <files>" ;;
    branch)
      local BASE="$REVIEW_BASE"                                     # 1) user-provided
      if [ -z "$BASE" ]; then                                       # 2) PR base, if a PR exists for this branch
        BASE="$(gh pr view --json baseRefName -q '.baseRefName' 2>/dev/null)"
        [ -n "$BASE" ] && BASE="origin/$BASE"
      fi
      [ -z "$BASE" ] && BASE="$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null)"  # 3) origin default
      for c in origin/main origin/master; do                        # 4) last resort
        [ -z "$BASE" ] && git rev-parse --verify "$c" >/dev/null 2>&1 && BASE="$c"
      done
      [ -n "$BASE" ] \
        || { echo "devflow: branch scope could not resolve a base — pass --base or set an origin remote." >&2; exit 1; }
      local MB; MB="$(git merge-base HEAD "$BASE")"
      [ -n "$MB" ] \
        || { echo "devflow: no common ancestor between HEAD and $BASE (shallow clone or unrelated histories?)." >&2; exit 1; }
      FILES="$(git diff --name-only "$MB" HEAD)";                   DIFF_CMD="git diff $MB..HEAD -- <files>" ;;
    pr)
      [ -n "$PR_NUMBER" ] || { echo "devflow: pr scope needs --pr <number>" >&2; exit 1; }
      FILES="$(gh pr diff "$PR_NUMBER" --name-only)" \
        || { echo "devflow: gh pr diff $PR_NUMBER failed -- check gh auth/network/PR number. Refusing to emit an empty scope." >&2; exit 1; }
      DIFF_CMD="gh pr diff $PR_NUMBER" ;;
    files)
      [ "${#EXPLICIT_FILES[@]}" -gt 0 ] || { echo "devflow: files scope needs paths after --" >&2; exit 1; }
      FILES="$(printf '%s\n' "${EXPLICIT_FILES[@]}")";               DIFF_CMD='git diff HEAD -- <those paths>' ;;
    plan)
      [ -n "$DEVFLOW_PLAN_PATH" ] || { echo "devflow: plan scope needs --plan-path or DEVFLOW_PLAN_PATH" >&2; exit 1; }
      FILES="$DEVFLOW_PLAN_PATH";                                    DIFF_CMD="(read-only) cat $DEVFLOW_PLAN_PATH" ;;
    *) echo "devflow: scope: unknown mode '$SCOPE_MODE'" >&2; exit 2 ;;
  esac
  local UNTRACKED; UNTRACKED="$(git ls-files --others --exclude-standard)"

  echo "SCOPE: Review ONLY this changeset. Inspect it with: $DIFF_CMD"
  echo "Files in scope:"
  [ -n "$FILES" ] && printf '%s\n' "$FILES"
  [ -n "$UNTRACKED" ] && printf '%s\n' "$UNTRACKED"
  echo "Anything outside this changeset -> list under OUT_OF_SCOPE and do NOT block on it."
}

# ── run-external ─────────────────────────────────────────────────────────────
# Bounded kill: TERM, poll ~3s, then KILL -9, then a guaranteed-returning wait.
# A plain `kill; wait` hangs forever if the child traps/ignores SIGTERM — escalate to -9.
devflow_kill_wait() {
  local pid="$1" _i
  kill "$pid" 2>/dev/null
  for _i in 1 2 3 4 5 6; do kill -0 "$pid" 2>/dev/null || break; sleep 0.5; done
  kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null || true
}

# Inputs (env): BACKEND, RUN_DIR, PROMPT, MODEL, EFFORT, PHASE, SESSION_REUSE,
#   PERMISSION_MODE, RESUME_ID (optional). Arg $1 — the binary to use.
# Sets: OUT EVENTS STDERR SESSION_FILE CODEX_EXIT CALL_RESULT SESSION_ID.
devflow_run_external() {
  local bin="$1"
  PHASE="${PHASE:-review}"
  OUT="$RUN_DIR/$PHASE-output.txt"; EVENTS="$RUN_DIR/$PHASE-events.jsonl"
  STDERR="$RUN_DIR/$PHASE-stderr.txt"; SESSION_FILE="$RUN_DIR/$PHASE.session"
  : > "$OUT"; : > "$EVENTS"; : > "$STDERR"      # truncate — never read a prior run's output

  local PMODE="${PERMISSION_MODE:-plan}" CODEX_EXTRA="" CLAUDE_EXTRA=""
  if [ "${SESSION_REUSE:-true}" = "false" ]; then CODEX_EXTRA="--ephemeral"; CLAUDE_EXTRA="--no-session-persistence"; fi

  if [ "$BACKEND" = "codex" ]; then
    if [ -n "${RESUME_ID:-}" ]; then
      nohup "$bin" -c "model_reasoning_effort=\"$EFFORT\"" exec resume "$RESUME_ID" \
        --full-auto $CODEX_EXTRA --json -m "$MODEL" -o "$OUT" "$PROMPT" < /dev/null > "$EVENTS" 2> "$STDERR" &
    else
      nohup "$bin" -c "model_reasoning_effort=\"$EFFORT\"" exec \
        --full-auto $CODEX_EXTRA --json -m "$MODEL" -o "$OUT" "$PROMPT" < /dev/null > "$EVENTS" 2> "$STDERR" &
    fi
  else  # claude
    nohup "$bin" -p --output-format json --permission-mode "$PMODE" $CLAUDE_EXTRA --model "$MODEL" --effort "$EFFORT" \
      ${RESUME_ID:+--resume "$RESUME_ID"} "$PROMPT" < /dev/null > "$OUT" 2> "$STDERR" &
  fi
  CODEX_PID=$!

  local timed_out=1 delay
  for delay in ${DEVFLOW_POLL_SCHEDULE:-15 30 60 60 60 60 60 60 60 60}; do
    sleep "$delay"
    if ! kill -0 "$CODEX_PID" 2>/dev/null \
       || { [ "$BACKEND" = "codex" ] && grep -q '"type":"turn.completed"' "$EVENTS"; }; then
      timed_out=0; break
    fi
    tail -1 "$EVENTS" 2>/dev/null
  done

  if [ "$timed_out" = "1" ]; then
    devflow_kill_wait "$CODEX_PID"
    CODEX_EXIT=124
    CALL_RESULT=""; SESSION_ID=""
    : > "$SESSION_FILE"   # output contract: SESSION_FILE always exists after this function returns, even on hard timeout
    echo "devflow: external call hit the ~8-10min hard cap -> killed. Last event:" >&2
    tail -1 "$EVENTS" >&2
    return 124
  fi
  local i
  for i in ${DEVFLOW_DRAIN_SCHEDULE:-5 5 5 5 5 5}; do kill -0 "$CODEX_PID" 2>/dev/null || break; sleep "$i"; done
  if kill -0 "$CODEX_PID" 2>/dev/null; then
    devflow_kill_wait "$CODEX_PID"; CODEX_EXIT=124
    echo "devflow: process lingered after turn.completed -> killed." >&2
  else
    wait "$CODEX_PID" 2>/dev/null; CODEX_EXIT=$?
  fi

  if [ "$BACKEND" = "codex" ]; then
    CALL_RESULT="$(python3 - "$EVENTS" <<'PY'
import sys, json
last=None
for line in open(sys.argv[1]):
    line=line.strip()
    if not line: continue
    try: e=json.loads(line)
    except Exception: continue
    it=e.get("item",{})
    if e.get("type")=="item.completed" and it.get("type")=="agent_message":
        last=it.get("text","")
print(last if last is not None else "")
PY
)"
    SESSION_ID="$(grep -o '"thread_id":"[^"]*"' "$EVENTS" | head -1 | cut -d'"' -f4)"
  else
    CALL_RESULT="$(jq -r '.result // empty' "$OUT" 2>/dev/null)"
    SESSION_ID="$(jq -r '.session_id // empty' "$OUT" 2>/dev/null)"
  fi
  if [ "${SESSION_REUSE:-true}" = "false" ]; then
    : > "$SESSION_FILE"
  elif [ -n "$SESSION_ID" ]; then
    printf '%s\n' "$SESSION_ID" > "$SESSION_FILE"
  else
    : > "$SESSION_FILE"; echo "devflow: WARN — no session id captured; resume will start fresh." >&2
  fi
  return "$CODEX_EXIT"
}

# Inputs: CODEX_EXIT, EVENTS, STDERR, FALLBACK_COMMAND, BACKEND.
# Returns 0 if the call is usable; non-zero (escalate) otherwise.
devflow_after_call() {
  local RATE='limit reached|rate.?limit|quota exceeded|too many requests'
  local AUTH='not logged in|please log in|authentication|JSONDecodeError|unexpected token'

  if [ "${CODEX_EXIT:-1}" -eq 0 ] && [ -n "${CALL_RESULT:-}" ]; then return 0; fi

  if grep -qiE "$RATE" "$STDERR" "$EVENTS" 2>/dev/null; then
    if [ -n "$FALLBACK_COMMAND" ] && command -v "$FALLBACK_COMMAND" >/dev/null 2>&1; then
      echo "devflow: rate limited — retrying once via $FALLBACK_COMMAND" >&2
      RESUME_ID=""
      devflow_run_external "$FALLBACK_COMMAND"
      [ "${CODEX_EXIT:-1}" -eq 0 ] && [ -n "${CALL_RESULT:-}" ] && return 0
      echo "devflow: fallback $FALLBACK_COMMAND also failed -> escalating." >&2
      return 1
    fi
    echo "devflow: rate limited and no usable fallback_command -> escalating." >&2
    return 1
  fi

  if grep -qiE "$AUTH" "$STDERR" "$EVENTS" 2>/dev/null || { [ "$BACKEND" = codex ] && [ ! -s "$EVENTS" ]; }; then
    echo "devflow: codex auth/capability failure (not a rate limit). The proxy won't help -- check codex.command_path / login. Escalating." >&2
    return 1
  fi

  echo "devflow: external call failed (exit ${CODEX_EXIT:-?}) for an unknown reason -> escalating." >&2
  return 1
}

cmd_run_external() {
  devflow_require_valid_env
  PHASE=""; local PROMPT_FILE=""; RESUME_ID=""; PERMISSION_MODE="plan"; local ROLE="reviewer"
  while [ $# -gt 0 ]; do
    case "$1" in
      --phase) PHASE="$2"; shift 2 ;;
      --prompt-file) PROMPT_FILE="$2"; shift 2 ;;
      --resume) RESUME_ID="$2"; shift 2 ;;
      --role) ROLE="$2"; shift 2 ;;
      --permission-mode) PERMISSION_MODE="$2"; shift 2 ;;
      --no-session-reuse) SESSION_REUSE="false"; shift ;;
      *) echo "devflow: run-external: unknown flag '$1'" >&2; exit 2 ;;
    esac
  done
  [ -n "${BACKEND:-}" ] || { echo "devflow: run-external: no run.env found -- run 'bootstrap' first." >&2; exit 1; }
  [ -n "$PHASE" ] || { echo "devflow: run-external: --phase is required" >&2; exit 2; }
  [ -n "$PROMPT_FILE" ] && [ -f "$PROMPT_FILE" ] || { echo "devflow: run-external: --prompt-file <path> is required and must exist" >&2; exit 2; }
  PROMPT="$(cat "$PROMPT_FILE")"

  if [ "$ROLE" = "implementer" ]; then MODEL="$IMPLEMENTER_MODEL"; EFFORT="$IMPLEMENTER_EFFORT"
  else MODEL="$REVIEWER_MODEL"; EFFORT="$REVIEWER_EFFORT"; fi

  # CALL_RESULT/SESSION_ID are only ever assigned past the poll loop in
  # devflow_run_external — its hard-cap timeout path `return`s before reaching that
  # point. Initialize both so the unbound-variable check below never crashes on exactly
  # the failure path that most needs a clean report.
  CALL_RESULT=""; SESSION_ID=""
  devflow_run_external "${CODEX_BIN:-$CLAUDE_BIN}"
  devflow_after_call
  local after_exit=$?

  echo "RUN_DIR=$RUN_DIR"
  echo "PHASE=$PHASE"
  echo "EXIT=$CODEX_EXIT"
  printf '%s\n' "$CALL_RESULT" > "$RUN_DIR/$PHASE-verdict.txt"
  echo "VERDICT_FILE=$RUN_DIR/$PHASE-verdict.txt"
  # Case-insensitive, last-MATCHING-LINE scan for a known token — tolerates markdown
  # bold (`**APPROVED**`), trailing punctuation, and surrounding prose on other lines,
  # unlike a strict last-whitespace-token match. Deliberately line-scoped rather than a
  # flat substring scan across the whole blob: "CHANGES_REQUESTED — the code is not
  # APPROVED for merge." contains both tokens, and a flat `tail -1` over every match in
  # the text would silently pick APPROVED off that sentence — fail-UNSAFE on an
  # approval gate. Restricting to the last line that has any verdict token, then
  # checking for ambiguity (both APPROVED and CHANGES_REQUESTED present), turns the
  # same sentence into UNKNOWN instead of a wrong APPROVED — fail-safe, forces the
  # caller to read VERDICT_FILE instead of trusting a guess. APPROVED and
  # CHANGES_REQUESTED are mutually exclusive; if both appear on the same line, it's
  # ambiguous. ISSUES is checked separately since it's not mutually exclusive with them
  # (a response might mention "found issues" while also saying "approved").
  local status="" last_matching_line
  last_matching_line="$(printf '%s' "$CALL_RESULT" | tr '[:lower:]' '[:upper:]' | grep -E 'APPROVED|CHANGES_REQUESTED|ISSUES' | tail -1)"
  if [ -n "$last_matching_line" ]; then
    local approved_count changes_count issues_count
    approved_count="$(printf '%s' "$last_matching_line" | grep -o 'APPROVED' | wc -l)"
    changes_count="$(printf '%s' "$last_matching_line" | grep -o 'CHANGES_REQUESTED' | wc -l)"
    issues_count="$(printf '%s' "$last_matching_line" | grep -o 'ISSUES' | wc -l)"
    # APPROVED and CHANGES_REQUESTED are mutually exclusive; if both appear, it's ambiguous
    if [ "$approved_count" -gt 0 ] && [ "$changes_count" -gt 0 ]; then
      status=""   # Both present — ambiguous, fall back to UNKNOWN
    elif [ "$approved_count" -gt 0 ]; then
      status="APPROVED"
    elif [ "$changes_count" -gt 0 ]; then
      status="CHANGES_REQUESTED"
    elif [ "$issues_count" -gt 0 ]; then
      status="ISSUES"
    fi
  fi
  echo "VERDICT_STATUS=${status:-UNKNOWN}"
  echo "SESSION_ID=${SESSION_ID:-}"
  echo "SESSION_FILE=${SESSION_FILE:-}"
  return "$after_exit"
}

# ── dispatcher ───────────────────────────────────────────────────────────────
main() {
  local cmd="${1:-}"; shift || true
  case "$cmd" in
    bootstrap)     cmd_bootstrap "$@" ;;
    scope)         cmd_scope "$@" ;;
    run-external)  cmd_run_external "$@" ;;
    *) echo "usage: $(basename "$0") bootstrap [--fresh] [--slug <name>] | scope <mode> [flags] | run-external --phase <p> --prompt-file <f> [flags]" >&2; exit 2 ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
  exit $?
fi
