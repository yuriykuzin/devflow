# Cross-Tool Runner

Canonical procedure for external-CLI calls (review, resume, implementer handoff).
Referenced by `devflow:plan`, `devflow:implement`, `devflow:review`, and `devflow:run`.

**Why this file exists:** the three review-bearing skills used to each carry their own
copy of the codex/claude invocation bash. That duplication drifted out of sync. This
file is the single source of truth for *how* to run an external call. Each skill still
owns its *prompt content*; it delegates the *mechanics* (config caching, binary
resolution, async launch, polling, scope pinning, fallback) here.

- **Section A — Bootstrap:** resolve config + personas + backend binary ONCE per run.
- **Section B — Invocation:** launch the external call non-blocking, poll to completion.
- **Section C — Scope pinning:** build the changeset block so the reviewer reviews ONLY what you intend.
- **Section D — Failure handling:** rate-limit fallback vs permanent auth/capability failure.

> **Rule:** EVERY external call in any devflow skill — fresh review, resume re-review,
> and implementer handoff/fix — MUST go through the `devflow_run_external` function
> (Section B) and `devflow_after_call` (Section D), using the values frozen by Section A.
> Do not hand-roll a one-off invocation.

The bash below is meant to be sourced/run as-is. The only values you (the agent) fill by
hand are marked `# AGENT:` — everything else is concrete and resolves at runtime.

---

## Section A — Bootstrap (run once per run; idempotent)

Bootstrap resolves everything volatile (config values, persona definitions, the backend
binary) a single time and freezes it into a per-run env file. Later phases `source` that
file instead of re-reading YAML, re-`find`ing personas, or re-resolving the binary.

### A.1 — Resolve the plugin dir

The runner and `config.default.yaml` live in the devflow plugin root.

```bash
# AGENT: set DEVFLOW_PLUGIN_DIR to this skill's plugin root (the dir containing
# config.default.yaml + skills/). On Claude Code it is the skill's base directory.
# Best-effort fallback if you don't have it handy:
DEVFLOW_PLUGIN_DIR="${DEVFLOW_PLUGIN_DIR:-$(dirname "$(find ~/.claude/plugins ~/.agents/skills ~/.codex -path '*devflow*/config.default.yaml' 2>/dev/null | head -1)")}"
[ -f "$DEVFLOW_PLUGIN_DIR/config.default.yaml" ] || echo "devflow: WARN — could not locate plugin dir; defaults may be missing." >&2
```

### A.2 — Decide: reuse a valid env, or bootstrap

A run's frozen state lives in `$RUN_DIR/run.env`. Reuse it only when it is **valid for
the current project** — same git root, same config/persona presence+mtimes. An env
inherited from another repo (e.g. a stale exported `DEVFLOW_RUN_ENV`) is NOT trusted.

```bash
# Resolve the project root ONCE, up front — so `.devflow.yaml` is found even when devflow
# is invoked from a subdirectory (cwd-relative would miss the override + destabilize the
# fingerprint). Everything below uses $DEVFLOW_PROJECT_ROOT, never a bare ".devflow.yaml".
DEVFLOW_PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

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
# valid <env-file> → 0 if env matches current project AND fingerprint unchanged
devflow_env_valid() {
  local env="$1"
  # run.env lives INSIDE RUN_DIR, so a reaped tmp dir takes its own run.env with it — this -f
  # test therefore doubles as the "RUN_DIR still exists" guard: no file → re-bootstrap.
  [ -n "$env" ] && [ -f "$env" ] || return 1
  # Snapshot the CURRENTLY-active context BEFORE sourcing the candidate (which overwrites
  # DEVFLOW_PROJECT_ROOT / DEVFLOW_PLUGIN_DIR). A stale env from another repo or another
  # plugin install must NOT validate against its own embedded paths — compare to ours.
  local cur_root cur_plugin
  cur_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  cur_plugin="$DEVFLOW_PLUGIN_DIR"
  ( set -a; . "$env"; set +a
    [ "$DEVFLOW_PROJECT_ROOT" = "$cur_root" ]   || exit 1   # same repo?
    [ "$DEVFLOW_PLUGIN_DIR"   = "$cur_plugin" ] || exit 1   # same plugin install?
    # Restore the snapshot so the fingerprint reads the ACTIVE config/persona files,
    # not the (possibly stale) paths the env just set.
    DEVFLOW_PROJECT_ROOT="$cur_root"; DEVFLOW_PLUGIN_DIR="$cur_plugin"
    [ "$DEVFLOW_CFG_FINGERPRINT" = "$(devflow_cfg_fingerprint)" ] || exit 1
  ) || return 1
}

REUSE=""
if [ -n "${DEVFLOW_RUN_ENV:-}" ] && devflow_env_valid "$DEVFLOW_RUN_ENV"; then
  REUSE="$DEVFLOW_RUN_ENV"                         # devflow-run exported a valid env
elif [ "${DEVFLOW_REUSE_LAST_RUN:-0}" = "1" ] && [ -f "${TMPDIR:-/tmp}/devflow-last-run" ]; then
  CAND="$(cat "${TMPDIR:-/tmp}/devflow-last-run")/run.env"   # standalone reuse ONLY on opt-in
  devflow_env_valid "$CAND" && REUSE="$CAND"
fi

if [ -n "$REUSE" ]; then
  set -a; . "$REUSE"; set +a
  export DEVFLOW_RUN_ENV="$REUSE"
  echo "devflow: reusing run env $REUSE"
fi
```

### A.3 — Full bootstrap (only when not reusing)

**Everything from here to the end of A is guarded** — it runs only when `REUSE` is empty.
A standalone skill with no valid env therefore re-bootstraps; it does NOT silently
re-read YAML every phase.

```bash
if [ -z "$REUSE" ]; then
  RUN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/devflow-run.XXXXXX")"

  # ── A.3a: resolve config (read YAML once) ──────────────────────────────────
  # Concrete merge: defaults ← ~/.devflow/config.yaml ← ./.devflow.yaml.
  # Emits shell-safe KEY='value' lines into config.env (merged into run.env in A.3e).
  # Requires python3 + PyYAML (standard in codex/claude environments). If PyYAML is absent
  # the block emits nothing and you (AGENT) fill the values from a manual `cat` of the
  # configs — see the fallback note.
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
cfg = functools.reduce(merge, [load(os.path.join(plugin, 'config.default.yaml')),
                               load('~/.devflow/config.yaml'),
                               load(os.path.join(root, '.devflow.yaml'))], {})
be  = cfg.get('backend', 'claude')
sec = cfg.get(be, {}) or {}
rev = sec.get('reviewer', {}) or {}
imp = sec.get('implementer', {}) or {}
# shell-safe single-quoted assignments: a value with " $ ` \ or newline cannot corrupt
# config.env or expand when sourced.
def emit(k, v): print('%s=%s' % (k, shlex.quote('' if v is None else str(v))))
emit('BACKEND', be)
emit('REVIEWER_MODEL', rev.get('model'));       emit('REVIEWER_EFFORT', rev.get('effort'))
emit('IMPLEMENTER_MODEL', imp.get('model'));     emit('IMPLEMENTER_EFFORT', imp.get('effort'))
emit('SESSION_REUSE', str(sec.get('session_reuse', True)).lower())
emit('FALLBACK_COMMAND', sec.get('fallback_command', ''))
emit('CODEX_COMMAND_PATH', sec.get('command_path', ''))
emit('OUTPUT_DIR', cfg.get('output_dir', 'docs/devflow/reports'))
PY
  if [ -s "$RUN_DIR/config.env" ]; then
    set -a; . "$RUN_DIR/config.env"; set +a
  else
    echo "devflow: WARN — PyYAML unavailable; AGENT must set BACKEND/REVIEWER_*/IMPLEMENTER_*/etc. from a manual config read." >&2
    # AGENT: having `cat`-ed the configs once, export the resolved values here, e.g.:
    #   BACKEND="codex"; REVIEWER_MODEL="gpt-5.5"; REVIEWER_EFFORT="high"; ... (do NOT leave placeholders)
  fi

  # ── A.3b: cache persona definitions (content, not just a path) ─────────────
  PERSONAS_SRC="$DEVFLOW_PLUGIN_DIR/skills/devflow-review/references/review-personas.md"
  if [ -f "$PERSONAS_SRC" ]; then
    cp "$PERSONAS_SRC" "$RUN_DIR/personas.md"
  else
    echo "devflow: WARN — review-personas.md not found at $PERSONAS_SRC; internal review will fall back to single-reviewer." >&2
  fi

  # ── A.3c: resolve & validate the codex binary (codex backend only) ─────────
  # A bare `codex` can hit an NVM-shadowed old CLI lacking --json + needing TTY auth.
  # Pick the first candidate that supports `exec --json`; never persist one that doesn't.
  CODEX_BIN=""; CLAUDE_BIN=""
  if [ "$BACKEND" = "codex" ]; then
    for cand in "$CODEX_COMMAND_PATH" /opt/homebrew/bin/codex /usr/local/bin/codex $(which -a codex 2>/dev/null); do
      [ -n "$cand" ] && [ -x "$cand" ] || continue
      if "$cand" exec --help < /dev/null 2>&1 | grep -q -- '--json'; then CODEX_BIN="$cand"; break; fi
    done
    if [ -z "$CODEX_BIN" ]; then
      echo "devflow: FATAL — no codex binary supports 'exec --json'." >&2
      echo "  Tried: ${CODEX_COMMAND_PATH:-<unset>} /opt/homebrew/bin/codex /usr/local/bin/codex $(which -a codex 2>/dev/null | tr '\n' ' ')" >&2
      echo "  Fix: set codex.command_path in ~/.devflow/config.yaml to the absolute path of the Rust codex CLI." >&2
      return 1 2>/dev/null || exit 1     # sourced → return (don't kill the caller's shell); executed → exit
    fi
  else
    CLAUDE_BIN="$(command -v claude)"
    [ -n "$CLAUDE_BIN" ] || { echo "devflow: FATAL — claude CLI not found on PATH." >&2; return 1 2>/dev/null || exit 1; }
  fi

  # ── A.3d: canonical plan path (safe location, never docs/superpowers) ──────
  DEFAULT_DATE="$(date -u +%F 2>/dev/null || echo plan)"
  case "$OUTPUT_DIR" in
    docs/superpowers*|"") PLAN_DIR="$RUN_DIR" ;;        # untracked-unsafe → fall back to run dir
    *)                    PLAN_DIR="$OUTPUT_DIR/plans" ;;
  esac
  DEVFLOW_PLAN_PATH="$PLAN_DIR/$DEFAULT_DATE-feature.md"   # AGENT: replace 'feature' with the slug

  # ── A.3e: freeze everything into run.env ───────────────────────────────────
  # The config-derived values are already shell-safe in config.env (shlex-quoted) — copy
  # them verbatim rather than re-quoting. Append the runner-computed vars with printf %q
  # (bash/zsh builtin) so paths with spaces/specials stay safe too.
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
    printf 'PLAN_SESSION_FILE=%q\n'      "$RUN_DIR/plan-review.session"
  } > "$RUN_DIR/run.env"
  # (No-PyYAML fallback: also append the config-derived values you resolved by hand, e.g.
  #  printf 'BACKEND=%q\n' "$BACKEND" >> "$RUN_DIR/run.env" — for each one.)

  export DEVFLOW_RUN_ENV="$RUN_DIR/run.env"
  echo "$RUN_DIR" > "${TMPDIR:-/tmp}/devflow-last-run"
  set -a; . "$RUN_DIR/run.env"; set +a
  echo "devflow: bootstrapped run env $DEVFLOW_RUN_ENV"
fi
```

Per-phase artifact paths (`$OUT`, `$EVENTS`, `$STDERR`, per-phase session files) are
derived under `$RUN_DIR` inside Section B. Because they're namespaced per run, two
devflow runs in different repos no longer read/write each other's `/tmp/devflow-*` files.

---

## Section B — Non-blocking invocation (function)

A direct foreground `codex exec` dies at the host's ~2-min timeout — what forced the old
manual `nohup`+`sleep` loops. `devflow_run_external` launches in the background, polls the
event stream with backoff, enforces a hard cap, and always drains a real exit status.

```bash
# Inputs (env): BACKEND, RUN_DIR, PROMPT, MODEL, EFFORT, PHASE, SESSION_REUSE.
#   PHASE  — plan-review | impl-review | final-review (set by the caller).
#   MODEL/EFFORT — REVIEWER_* for reviews, IMPLEMENTER_* for handoffs.
#   PERMISSION_MODE — 'plan' (review, default) or 'default' (implementer handoff; claude only).
#   RESUME_ID — optional; resume that session instead of starting fresh.
#   SESSION_REUSE=false → ephemeral call, no session persisted.
# Arg $1 — the binary to use (CODEX_BIN normally; FALLBACK_COMMAND on a Section-D retry).
# Sets: OUT EVENTS STDERR SESSION_FILE CODEX_EXIT (and CALL_RESULT text), SESSION_ID.

# Bounded kill: TERM, poll ~3s, then KILL -9, then a guaranteed-returning wait.
# A plain `kill; wait` hangs forever if the child traps/ignores SIGTERM — escalate to -9.
devflow_kill_wait() {
  local pid="$1" _i
  kill "$pid" 2>/dev/null
  for _i in 1 2 3 4 5 6; do kill -0 "$pid" 2>/dev/null || break; sleep 0.5; done
  kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null || true
}

devflow_run_external() {
  local bin="$1"
  PHASE="${PHASE:-review}"
  OUT="$RUN_DIR/$PHASE-output.txt"; EVENTS="$RUN_DIR/$PHASE-events.jsonl"
  STDERR="$RUN_DIR/$PHASE-stderr.txt"; SESSION_FILE="$RUN_DIR/$PHASE.session"
  : > "$OUT"; : > "$EVENTS"; : > "$STDERR"      # truncate — never read a prior run's output

  # PERMISSION_MODE: 'plan' (read-only review, default) or 'default' (implementer handoff).
  # SESSION_REUSE=false → ephemeral, and we skip persisting a session id.
  local PMODE="${PERMISSION_MODE:-plan}" CODEX_EXTRA="" CLAUDE_EXTRA=""
  if [ "${SESSION_REUSE:-true}" = "false" ]; then CODEX_EXTRA="--ephemeral"; CLAUDE_EXTRA="--no-session-persistence"; fi

  if [ "$BACKEND" = "codex" ]; then
    # `-c` MUST precede `exec`; always `< /dev/null` to avoid a TTY block.
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
  # Backoff schedule (seconds). Overridable via DEVFLOW_POLL_SCHEDULE for tests; default unchanged.
  for delay in ${DEVFLOW_POLL_SCHEDULE:-15 30 60 60 60 60 60 60 60 60}; do
    sleep "$delay"
    # completion = process gone OR (codex) an EXACT turn.completed event line.
    # Match the precise JSON type — NOT a bare `turn.completed` substring, which
    # false-matches when the reviewed diff/command text contains that token.
    if ! kill -0 "$CODEX_PID" 2>/dev/null \
       || { [ "$BACKEND" = "codex" ] && grep -q '"type":"turn.completed"' "$EVENTS"; }; then
      timed_out=0; break
    fi
    tail -1 "$EVENTS" 2>/dev/null     # liveness for the operator
  done

  if [ "$timed_out" = "1" ]; then
    devflow_kill_wait "$CODEX_PID"        # bounded kill — never an unbounded wait
    CODEX_EXIT=124
    echo "devflow: external call hit the ~8-10min hard cap → killed. Last event:" >&2
    tail -1 "$EVENTS" >&2
    return 124
  fi
  # Completion was signalled by turn.completed — but the process may linger. Drain with a
  # bounded wait (~30s); if it still hasn't exited, kill it (never an unbounded wait).
  local i
  # Drain schedule = per-iteration sleep seconds. Overridable via DEVFLOW_DRAIN_SCHEDULE for tests.
  for i in ${DEVFLOW_DRAIN_SCHEDULE:-5 5 5 5 5 5}; do kill -0 "$CODEX_PID" 2>/dev/null || break; sleep "$i"; done
  if kill -0 "$CODEX_PID" 2>/dev/null; then
    devflow_kill_wait "$CODEX_PID"; CODEX_EXIT=124
    echo "devflow: process lingered after turn.completed → killed." >&2
  else
    wait "$CODEX_PID" 2>/dev/null; CODEX_EXIT=$?
  fi

  # Extract the verdict text + session id.
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
    : > "$SESSION_FILE"        # ephemeral run — nothing to resume
  elif [ -n "$SESSION_ID" ]; then
    printf '%s\n' "$SESSION_ID" > "$SESSION_FILE"
  else
    : > "$SESSION_FILE"; echo "devflow: WARN — no session id captured; resume will start fresh." >&2
  fi
  return "$CODEX_EXIT"
}
```

**Claude Code platform note:** on Claude Code prefer the Bash tool's
`run_in_background: true` + the `BashOutput` tool over the in-script `sleep` poll — same
backoff/cap/completion semantics, but each poll is a tool call rather than a blocking
sleep. On hosts without background tasks (Windsurf/Gemini/Codex-as-host), the portable
`nohup &` form above is the one to use.

---

## Section C — Scope-pinned prompt construction

The reviewer must review ONLY the intended changeset. Compute it for the requested mode,
embed an explicit file list AND the exact git command, and tell the reviewer to treat
anything else as out of scope.

```bash
# Inputs: SCOPE_MODE, and per-mode: REVIEW_BASE / PR_NUMBER / explicit paths / DEVFLOW_IMPL_BASE.
case "$SCOPE_MODE" in
  uncommitted)   FILES="$(git diff --name-only HEAD)";            DIFF_CMD='git diff HEAD -- <files>' ;;
  staged)        FILES="$(git diff --cached --name-only)";        DIFF_CMD='git diff --cached -- <files>' ;;
  last-commit)
    git rev-parse --verify -q HEAD^ >/dev/null 2>&1 \
      || { echo "devflow: last-commit scope needs a parent commit (HEAD^ missing on a single-commit repo)." >&2; return 1 2>/dev/null || exit 1; }
    FILES="$(git diff --name-only HEAD^ HEAD)";                   DIFF_CMD='git show HEAD  # or git diff HEAD^..HEAD -- <files>' ;;
  implementation)
    [ -n "${DEVFLOW_IMPL_BASE:-}" ] \
      || { echo "devflow: implementation scope needs DEVFLOW_IMPL_BASE (the pre-implementation commit)." >&2; return 1 2>/dev/null || exit 1; }
    git rev-parse --verify -q "${DEVFLOW_IMPL_BASE}^{commit}" >/dev/null 2>&1 \
      || { echo "devflow: DEVFLOW_IMPL_BASE ('$DEVFLOW_IMPL_BASE') is not a valid commit — refusing to emit an empty scope." >&2; return 1 2>/dev/null || exit 1; }
    FILES="$(git diff --name-only "$DEVFLOW_IMPL_BASE")";         DIFF_CMD="git diff $DEVFLOW_IMPL_BASE -- <files>" ;;
  branch)
    BASE="$REVIEW_BASE"                                           # 1) user-provided
    if [ -z "$BASE" ]; then                                       # 2) PR base, if a PR exists for this branch
      BASE="$(gh pr view --json baseRefName -q '.baseRefName' 2>/dev/null)"
      [ -n "$BASE" ] && BASE="origin/$BASE"
    fi
    [ -z "$BASE" ] && BASE="$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null)"  # 3) origin default
    for c in origin/main origin/master; do                        # 4) last resort
      [ -z "$BASE" ] && git rev-parse --verify "$c" >/dev/null 2>&1 && BASE="$c"
    done
    [ -n "$BASE" ] \
      || { echo "devflow: branch scope could not resolve a base — pass REVIEW_BASE or set an origin remote." >&2; return 1 2>/dev/null || exit 1; }
    MB="$(git merge-base HEAD "$BASE")"
    [ -n "$MB" ] \
      || { echo "devflow: no common ancestor between HEAD and $BASE (shallow clone or unrelated histories?)." >&2; return 1 2>/dev/null || exit 1; }
    FILES="$(git diff --name-only "$MB" HEAD)";                   DIFF_CMD="git diff $MB..HEAD -- <files>" ;;
  pr)            FILES="$(gh pr diff "$PR_NUMBER" --name-only)";  DIFF_CMD="gh pr diff $PR_NUMBER" ;;
  files)         FILES="<explicit path list>";                   DIFF_CMD='git diff HEAD -- <those paths>' ;;
  plan)          FILES="$DEVFLOW_PLAN_PATH";                      DIFF_CMD="(read-only) cat $DEVFLOW_PLAN_PATH" ;;
esac
UNTRACKED="$(git ls-files --others --exclude-standard)"   # enumerate new files so they're in scope
```

Prepend this block to the skill's review/plan prompt:

```
SCOPE: Review ONLY this changeset. Inspect it with: <DIFF_CMD>
Files in scope:
<FILES + any relevant UNTRACKED files (a git diff will NOT show new untracked files — read them directly)>
Anything outside this changeset → list under OUT_OF_SCOPE and do NOT block on it.
```

For `branch` never hardcode `origin/main` — use the resolved `$BASE` chain above. For
`implementation`, `$DEVFLOW_IMPL_BASE` is the commit captured at the start of
`devflow-implement` Step 3, so per-task auto-commits stay in scope.

---

## Section D — Failure handling (function)

Run after every call. Distinguishes a transient rate limit (retry once via the fallback
binary) from a permanent auth/capability failure (no proxy retry — it won't help).

```bash
# Inputs: CODEX_EXIT, EVENTS, STDERR, FALLBACK_COMMAND (all from Section A/B).
# Returns 0 if the call is usable; non-zero (escalate) otherwise.
devflow_after_call() {
  local RATE='limit reached|rate.?limit|quota exceeded|too many requests'
  local AUTH='not logged in|please log in|authentication|JSONDecodeError|unexpected token'

  # success = clean exit AND a non-empty result (guards the empty-success case)
  if [ "${CODEX_EXIT:-1}" -eq 0 ] && [ -n "${CALL_RESULT:-}" ]; then return 0; fi

  if grep -qiE "$RATE" "$STDERR" "$EVENTS" 2>/dev/null; then
    if [ -n "$FALLBACK_COMMAND" ] && command -v "$FALLBACK_COMMAND" >/dev/null 2>&1; then
      echo "devflow: rate limited — retrying once via $FALLBACK_COMMAND" >&2
      RESUME_ID=""                              # a rate-limited session can't be resumed via proxy
      devflow_run_external "$FALLBACK_COMMAND"  # re-runs Section B identically, new session captured
      [ "${CODEX_EXIT:-1}" -eq 0 ] && [ -n "${CALL_RESULT:-}" ] && return 0
      echo "devflow: fallback $FALLBACK_COMMAND also failed → escalating." >&2
      return 1
    fi
    echo "devflow: rate limited and no usable fallback_command → escalating." >&2
    return 1
  fi

  if grep -qiE "$AUTH" "$STDERR" "$EVENTS" 2>/dev/null || { [ "$BACKEND" = codex ] && [ ! -s "$EVENTS" ]; }; then
    echo "devflow: codex auth/capability failure (not a rate limit). The proxy won't help — check codex.command_path / login. Escalating." >&2
    return 1
  fi

  echo "devflow: external call failed (exit ${CODEX_EXIT:-?}) for an unknown reason → escalating." >&2
  return 1
}
```

- **Rate limit (transient):** one retry via `$FALLBACK_COMMAND` (new session id); if it
  also fails → escalate.
- **Auth / capability (permanent):** TTY/login prompt, `JSONDecodeError`, empty events,
  or missing `--json` → escalate immediately. Never burn a fallback retry on this.
- **`fallback_command` empty** → escalate immediately.

This is the same fallback behavior the skills had inline before, now defined once and
actually executable.

---

## Putting it together (per phase)

```bash
# 1) Section A bootstrap (sources run.env).
# 2) Build $PROMPT with the Section C scope block.
PHASE="plan-review"; MODEL="$REVIEWER_MODEL"; EFFORT="$REVIEWER_EFFORT"
# RESUME_ID="$(cat "$SESSION_FILE" 2>/dev/null)"   # set on iterations after the first
devflow_run_external "${CODEX_BIN:-$CLAUDE_BIN}"
devflow_after_call || { echo "external review unavailable — escalate to user"; }
echo "$CALL_RESULT"     # ends with APPROVED / ISSUES / CHANGES_REQUESTED
```
