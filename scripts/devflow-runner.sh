#!/usr/bin/env bash
# Devflow cross-tool runner — the one piece of devflow that cannot live in skill markdown:
# supervising a long (8–10 min) backend CLI (codex/claude) with nohup + bounded poll + kill,
# and keeping the deterministic RUN_DIR hygienic. Config resolution and scope-pinning are
# done by the calling skill directly (plain git + a read of .devflow.yaml); this script only
# needs the values passed as flags. See skills/using-devflow/references/cross-tool-runner.md.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEVFLOW_PLUGIN_DIR="$(cd "$SELF_DIR/.." && pwd)"
DEVFLOW_PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

# RUN_DIR lives OUTSIDE the repo tree, under a hash of the project root — deterministic
# (every invocation recomputes the same path, no mktemp/exported pointer to lose) but never
# inside the working tree, so a hostile clone can never *deliver* a tracked file into a path
# we later read (the original in-repo `.devflow/run` made that a same-day RCE: `.gitignore`
# only blocks *future* untracked additions, not files a clone already ships tracked).
_devflow_hash() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 | cut -c1-16
  elif command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -c1-16
  else cksum | cut -d' ' -f1
  fi
}
DEVFLOW_ROOT_HASH="$(printf '%s' "$DEVFLOW_PROJECT_ROOT" | _devflow_hash)"
RUN_DIR="${TMPDIR:-/tmp}/devflow-run.$DEVFLOW_ROOT_HASH"

# Create (if absent) and enforce 0700 + ownership on RUN_DIR before writing anything into
# it — defeats pre-planting the deterministic path as a symlink or as a different-owner
# directory on a shared host. Runs on every invocation, before any subcommand touches it.
# The symlink check precedes mkdir, so a narrow same-user TOCTOU window remains on first
# creation; the ownership assertion below still rejects any symlink whose target the current
# user does not own, which is the attack that matters on a shared host. The residual
# same-user race is accepted for a personal tool rather than papered over with locking.
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
  # Stamp last-USE: this runs on every invocation (dir + run-external), so RUN_DIR's own mtime
  # tracks activity, not first-creation. The GC sweep below ages dirs by this — without it a
  # steadily-reused checkout (whose phase files are only truncated, never re-created, so the
  # dir mtime never moves) would look abandoned and be reaped mid-project.
  touch "$d" 2>/dev/null
}
devflow_secure_dir "$RUN_DIR"

# ── run-liveness lease ───────────────────────────────────────────────────────────
# RUN_DIR is deterministic (one per project root), so a second invocation lands on the
# SAME directory a first one may still be using. A long-running `run-external` drops its
# own PID as a marker under $RUN_DIR/.pids/; `dir --fresh` refuses to `rm -rf` RUN_DIR
# while any recorded PID is still alive. This largely closes the reported race where a second
# `dir --fresh` (starting a new feature) wiped the session/output files of a call still in
# flight. Markers are per-PID so concurrent acquires never collide, and a dead marker left
# by a crashed run is simply ignored (and cleared by the next wipe) — self-healing.
# NOTE: guard-scan and rm are not atomic — a run-external that acquires its lease in the
# sliver between them could still be wiped. For a single-user personal tool that residual
# window is accepted rather than closed with a global lock (which would be gold-plating).
DEVFLOW_LEASE=""
devflow_lease_acquire() {
  # Fail-OPEN (proceed without a lease) rather than abort — but never SILENTLY: a lost lease
  # means a concurrent `dir --fresh` is no longer blocked from wiping this call, so say so.
  mkdir -p "$RUN_DIR/.pids" 2>/dev/null || { echo "devflow: WARN — could not create lease dir; a concurrent 'dir --fresh' will not be blocked from wiping this run." >&2; return 0; }
  DEVFLOW_LEASE="$RUN_DIR/.pids/$$"
  : > "$DEVFLOW_LEASE" 2>/dev/null || { echo "devflow: WARN — could not register run lease; a concurrent 'dir --fresh' will not be blocked from wiping this run." >&2; return 0; }
  trap 'rm -f "$DEVFLOW_LEASE" 2>/dev/null' EXIT
}
# True (0) if <dir>/.pids/ holds at least one LIVE PID marker; sets DEVFLOW_LIVE_PID to it.
# Shared by the self-wipe guard (dir --fresh) AND the GC sweep, so both honour the same
# run-liveness lease instead of GC inventing a weaker mtime-only heuristic for "is it active".
devflow_dir_has_live_pid() {
  local d="$1/.pids" marker pid
  DEVFLOW_LIVE_PID=""
  [ -d "$d" ] || return 1
  for marker in "$d"/*; do
    [ -e "$marker" ] || continue
    pid="${marker##*/}"
    case "$pid" in ''|*[!0-9]*) continue ;; esac   # ignore non-PID entries
    if kill -0 "$pid" 2>/dev/null; then DEVFLOW_LIVE_PID="$pid"; return 0; fi
  done
  return 1
}
devflow_guard_no_live_run() {
  if devflow_dir_has_live_pid "$RUN_DIR"; then
    echo "devflow: FATAL — a devflow run (pid $DEVFLOW_LIVE_PID) is active in $RUN_DIR; refusing to wipe it." >&2
    echo "  Wait for it to finish, or stop pid $DEVFLOW_LIVE_PID, then retry." >&2
    exit 1
  fi
}

# ── opportunistic GC of stale run dirs ───────────────────────────────────────────
# RUN_DIR is one-per-project-root, so a worktree-per-feature workflow mints a NEW hash every
# run and `dir --fresh` reuse never reclaims the old ones — completed run dirs would pile up
# in $TMPDIR without bound. GC runs on EVERY `dir` (not only `--fresh`): `dir` is the once-per-
# pipeline entry point every skill calls, whereas `--fresh` is passed only when starting a NEW
# feature — gating the sweep on it would let dirs accumulate indefinitely for anyone who reuses
# a checkout instead of worktrees. Each call reclaims a sibling devflow-run.* dir only when it
# is ALL THREE of:
#   - OURS       — uid matches (mirrors devflow_secure_dir's ownership assertion; on a shared
#                  /tmp we must never rm another user's run dir);
#   - IDLE       — no live PID leased under .pids/ (the SAME liveness test dir --fresh honours
#                  via devflow_dir_has_live_pid — a running call is never reclaimed, even if
#                  its dir mtime looks old);
#   - OLD        — dir mtime more than DEVFLOW_RUN_TTL_DAYS full 24h-periods ago (default 7;
#                  find rounds down, so ~8 days in practice — conservative, errs to keeping).
# mtime is a true last-USE clock because devflow_secure_dir touch()es RUN_DIR every invocation.
# The current RUN_DIR is excluded by basename (robust to a $TMPDIR trailing slash that would
# make a `//` path-string compare miss). Best-effort: a non-numeric DEVFLOW_RUN_TTL_DAYS
# disables the sweep, a failed rm WARNs (never a silent skip) but never aborts the command, and
# a non-empty sweep says what it did.
# NOTE: the per-candidate liveness check and its rm are not atomic — the SAME class of accepted
# race as the self-wipe guard (see the lease NOTE above), but with a wider exposure: it can fire
# on a routine plain `dir` (not just an operator's deliberate `--fresh`), and the victim is any
# old+idle sibling, not only self. A sibling that revives in the sliver between find's snapshot
# and its rm could be wiped (the touch() in devflow_secure_dir does NOT save it — find already
# captured the old mtime). Accepted rather than closed with a global lock (which would be gold-
# plating here) because the victim must ALSO have sat idle past the TTL to be listed at all — an
# 8-days-dormant checkout reviving in that exact sub-second window on a single-user machine is
# vanishingly unlikely, and the cost is a recreatable session dir, not data.
devflow_gc_old_runs() {
  local ttl="${DEVFLOW_RUN_TTL_DAYS:-7}" self cand n=0
  case "$ttl" in ''|*[!0-9]*) return 0 ;; esac
  self="$(basename "$RUN_DIR")"
  while IFS= read -r cand; do
    [ -n "$cand" ] || continue
    devflow_dir_has_live_pid "$cand" && continue   # never reap a live run (belt for a reused old dir)
    if rm -rf "$cand" 2>/dev/null; then n=$((n+1))
    else echo "devflow: WARN — GC could not reclaim $cand (files locked/immutable?)." >&2; fi
  done < <(find "$(dirname "$RUN_DIR")" -maxdepth 1 -type d -name 'devflow-run.*' \
             ! -name "$self" -uid "$(id -u)" -mtime "+$ttl" 2>/dev/null)
  [ "$n" -gt 0 ] && echo "devflow: GC reclaimed $n abandoned run dir(s) (idle >${ttl}d)." >&2
  return 0
}

# ── dir ────────────────────────────────────────────────────────────────────────
# Emit the (secured) RUN_DIR for this project so a skill knows where session/output files
# live. `--fresh` wipes it first (subject to the liveness guard) to start a clean run —
# clearing a prior feature's phase session files so they aren't silently resumed.
cmd_dir() {
  local fresh=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --fresh) fresh=1; shift ;;
      *) echo "devflow: dir: unknown flag '$1'" >&2; exit 2 ;;
    esac
  done
  if [ "$fresh" = "1" ]; then
    devflow_guard_no_live_run
    # A failed rm must NOT fall through to a printed RUN_DIR as if the wipe succeeded (an
    # `&&` short-circuit would skip devflow_secure_dir yet still return 0) — abort loudly.
    rm -rf "$RUN_DIR" || { echo "devflow: FATAL — could not wipe $RUN_DIR (files locked/immutable?); refusing to proceed on a stale run." >&2; exit 1; }
    devflow_secure_dir "$RUN_DIR"
  fi
  devflow_gc_old_runs   # prune abandoned sibling run dirs (worktree workflows never reuse a hash)
  echo "RUN_DIR=$RUN_DIR"
}

# ── trusted codex-binary resolution ──────────────────────────────────────────────
# `command_path` and `fallback_command` choose which binary devflow *executes*, so they are
# read ONLY from the plugin default and ~/.devflow/config.yaml — NEVER from a project-level
# .devflow.yaml (a repo you cloned could otherwise point devflow at a binary it ships). This
# is a fixed two-key, one-level-deep reader for files we control, not a general YAML parser:
# it prints "<key>\t<value>" for `command_path`/`fallback_command` found as direct children
# of the top-level `codex:` block, later files (global config) overriding earlier (default).
devflow_codex_paths() {
  awk '
    FNR==1 { in_codex=0 }                                   # reset section state per file
    /^[^[:space:]#]/ { in_codex = ($0 ~ /^codex:[[:space:]]*$/) }
    in_codex && /^  (command_path|fallback_command)[[:space:]]*:/ {
      key=$1; sub(/:.*$/, "", key)                          # "command_path:" -> "command_path"
      val=$0; sub(/^[^:]*:[[:space:]]*/, "", val)           # strip "  key:" prefix
      sub(/[[:space:]]+#.*$/, "", val)                      # strip trailing inline comment
      gsub(/^"|"$/, "", val)                                # strip surrounding double quotes
      print key "\t" val
    }
  ' "$@"
}
# Resolve CODEX_BIN (a binary whose `exec --help` advertises --json — a bare `codex` can hit
# an NVM-shadowed old CLI lacking it) and FALLBACK_COMMAND, from the trusted files only.
devflow_resolve_codex_bin() {
  local default_cfg="$DEVFLOW_PLUGIN_DIR/config.default.yaml" global_cfg="$HOME/.devflow/config.yaml"
  local cmd_path="" key val cand
  FALLBACK_COMMAND=""
  local -a cfgs=()
  [ -f "$default_cfg" ] && cfgs+=("$default_cfg")
  [ -f "$global_cfg" ]  && cfgs+=("$global_cfg")
  if [ "${#cfgs[@]}" -gt 0 ]; then
    while IFS=$'\t' read -r key val; do
      case "$key" in
        command_path)     cmd_path="$val" ;;
        fallback_command) FALLBACK_COMMAND="$val" ;;
      esac
    done < <(devflow_codex_paths "${cfgs[@]}")
  fi
  CODEX_BIN=""
  for cand in "$cmd_path" /opt/homebrew/bin/codex /usr/local/bin/codex $(which -a codex 2>/dev/null); do
    [ -n "$cand" ] && [ -x "$cand" ] || continue
    if "$cand" exec --help < /dev/null 2>&1 | grep -q -- '--json'; then CODEX_BIN="$cand"; break; fi
  done
  [ -n "$CODEX_BIN" ] || {
    echo "devflow: FATAL — no codex binary supports 'exec --json'." >&2
    echo "  Tried: ${cmd_path:-<unset>} /opt/homebrew/bin/codex /usr/local/bin/codex $(which -a codex 2>/dev/null | tr '\n' ' ')" >&2
    echo "  Fix: set codex.command_path in ~/.devflow/config.yaml to the absolute path of the Rust codex CLI." >&2
    exit 1
  }
}

# ── run-external ─────────────────────────────────────────────────────────────
# Launch backends in their own session/process-group so a timeout kill can reap the whole
# tree: codex/claude spawn helper subprocesses that HEAD leaked as orphans (it killed only
# the direct child PID). macOS ships no setsid(1), so a tiny stdlib-python shim calls
# setsid()+exec; if setsid fails it still execs, degrading to HEAD behaviour.
DEVFLOW_SETSID='import os,sys
try: os.setsid()
except OSError: pass
os.execvp(sys.argv[1], sys.argv[1:])'

# Bounded kill: TERM, poll ~3s, then KILL -9, then a guaranteed-returning wait.
# A plain `kill; wait` hangs forever if the child traps/ignores SIGTERM — escalate to -9.
# Each signal is sent to the PID directly AND to its process group (negative PID): when the
# child leads its own group (see DEVFLOW_SETSID) the group signal reaps descendants; when it
# doesn't (e.g. a lone test child) the group signal harmlessly fails and the direct one wins.
devflow_kill_wait() {
  local pid="$1" _i
  kill -TERM "$pid" 2>/dev/null; kill -TERM -"$pid" 2>/dev/null
  for _i in 1 2 3 4 5 6; do kill -0 "$pid" 2>/dev/null || break; sleep 0.5; done
  if kill -0 "$pid" 2>/dev/null; then kill -9 "$pid" 2>/dev/null; kill -9 -"$pid" 2>/dev/null; fi
  wait "$pid" 2>/dev/null || true
}

# Inputs (vars set by cmd_run_external): BACKEND, RUN_DIR, PROMPT, MODEL, EFFORT, PHASE,
#   SESSION_REUSE, DEVFLOW_ROLE, RESUME_ID (optional). Arg $1 — the binary.
# Sets: OUT EVENTS STDERR SESSION_FILE CODEX_EXIT CALL_RESULT SESSION_ID.
devflow_run_external() {
  local bin="$1"
  PHASE="${PHASE:-review}"
  OUT="$RUN_DIR/$PHASE-output.txt"; EVENTS="$RUN_DIR/$PHASE-events.jsonl"
  STDERR="$RUN_DIR/$PHASE-stderr.txt"; SESSION_FILE="$RUN_DIR/$PHASE.session"
  : > "$OUT"; : > "$EVENTS"; : > "$STDERR"      # truncate — never read a prior run's output

  # Write posture is derived SOLELY from the role, never a free-form caller flag: a reviewer
  # is always read-only (claude `plan`, codex `sandbox_mode=read-only`), only an implementer
  # gets write access. This makes "reviewer == read-only" a script invariant, not a default a
  # caller could silently override.
  local PMODE; [ "${DEVFLOW_ROLE:-reviewer}" = "implementer" ] && PMODE="default" || PMODE="plan"

  if [ "$BACKEND" = "codex" ]; then
    # Global codex options (before the subcommand) vs exec options (after it). Reviewer runs
    # read-only; implementer keeps workspace-write via --full-auto. sandbox_mode is set with
    # `-c` rather than `-s` because `exec resume` rejects `-s` but honours the config override
    # on both the fresh and resume paths.
    local -a copts=(-c "model_reasoning_effort=\"$EFFORT\"")
    local -a eopts=(--json -m "$MODEL" -o "$OUT")
    [ "${SESSION_REUSE:-true}" = "false" ] && eopts+=(--ephemeral)
    if [ "${DEVFLOW_ROLE:-reviewer}" = "implementer" ]; then
      eopts+=(--full-auto)
    else
      copts+=(-c 'sandbox_mode="read-only"')
    fi
    if [ -n "${RESUME_ID:-}" ]; then
      nohup python3 -c "$DEVFLOW_SETSID" "$bin" "${copts[@]}" exec resume "$RESUME_ID" "${eopts[@]}" "$PROMPT" \
        < /dev/null > "$EVENTS" 2> "$STDERR" &
    else
      nohup python3 -c "$DEVFLOW_SETSID" "$bin" "${copts[@]}" exec "${eopts[@]}" "$PROMPT" \
        < /dev/null > "$EVENTS" 2> "$STDERR" &
    fi
  else  # claude
    local CLAUDE_EXTRA=""
    [ "${SESSION_REUSE:-true}" = "false" ] && CLAUDE_EXTRA="--no-session-persistence"
    nohup python3 -c "$DEVFLOW_SETSID" "$bin" -p --output-format json --permission-mode "$PMODE" $CLAUDE_EXTRA --model "$MODEL" --effort "$EFFORT" \
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
    tail -1 "$EVENTS" >&2 2>/dev/null   # progress -> stderr (>&2 first, then silence tail's own errors); stdout stays the KEY=VALUE report
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
    # Reachable only after turn.completed was observed (the poll loop's only other exit is the
    # process itself dying, handled by the else branch) but the process is slow to exit. Reap
    # it, yet treat the COMPLETED turn as SUCCESS (exit 0): the verdict was produced, so a
    # lingering-then-reaped process must NOT be reported as a 124 timeout failure and escalated.
    devflow_kill_wait "$CODEX_PID"; CODEX_EXIT=0
    echo "devflow: process lingered after turn.completed -> reaped (turn already complete, treated as success)." >&2
  else
    wait "$CODEX_PID" 2>/dev/null; CODEX_EXIT=$?
  fi

  # Field extraction is delegated to devflow-json.py: it parses the events/output as real
  # JSON (not grep) and fails closed — a codex stream missing a terminal turn.completed, or
  # carrying a turn.failed, yields no result rather than a stale/partial message, and a
  # session id must match a strict token or it is dropped. HEAD's `grep '"thread_id"'` could
  # latch onto a thread_id echoed inside message text; jq is no longer needed.
  local jsonc="$SELF_DIR/devflow-json.py" src jsonf
  if [ "$BACKEND" = "codex" ]; then src="codex"; jsonf="$EVENTS"; else src="claude"; jsonf="$OUT"; fi
  CALL_RESULT="$(python3 "$jsonc" "$src" result "$jsonf" 2>/dev/null)" || CALL_RESULT=""
  SESSION_ID="$(python3 "$jsonc" "$src" session "$jsonf" 2>/dev/null)" || SESSION_ID=""
  if [ "${SESSION_REUSE:-true}" = "false" ]; then
    : > "$SESSION_FILE"
  elif [ -n "$SESSION_ID" ]; then
    printf '%s\n' "$SESSION_ID" > "$SESSION_FILE"
  else
    : > "$SESSION_FILE"; echo "devflow: WARN — no session id captured; resume will start fresh." >&2
  fi
  return "$CODEX_EXIT"
}

# Inputs: CODEX_EXIT, EVENTS, STDERR, FALLBACK_COMMAND, BACKEND, CALL_RESULT.
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
    echo "devflow: $BACKEND auth/capability failure (not a rate limit). The proxy won't help -- check $BACKEND login/credentials (for codex, also codex.command_path). Escalating." >&2
    return 1
  fi

  echo "devflow: external call failed (exit ${CODEX_EXIT:-?}) for an unknown reason -> escalating." >&2
  return 1
}

cmd_run_external() {
  PHASE=""; local PROMPT_FILE=""; RESUME_ID=""; local ROLE="reviewer"
  BACKEND=""; MODEL=""; EFFORT=""; SESSION_REUSE="true"
  # Every value-taking flag needs its argument; under `set -u` a bare "$2" on a dangling flag
  # would crash with a raw "unbound variable" instead of this function's own usage message.
  _need_val() { [ "$2" -ge 2 ] || { echo "devflow: run-external: $1 requires a value" >&2; exit 2; }; }
  while [ $# -gt 0 ]; do
    case "$1" in
      --phase)            _need_val --phase "$#";        PHASE="$2"; shift 2 ;;
      --prompt-file)      _need_val --prompt-file "$#";  PROMPT_FILE="$2"; shift 2 ;;
      --backend)          _need_val --backend "$#";      BACKEND="$2"; shift 2 ;;
      --model)            _need_val --model "$#";        MODEL="$2"; shift 2 ;;
      --effort)           _need_val --effort "$#";       EFFORT="$2"; shift 2 ;;
      --resume)           _need_val --resume "$#";       RESUME_ID="$2"; shift 2 ;;
      --role)             _need_val --role "$#";         ROLE="$2"; shift 2 ;;
      --no-session-reuse) SESSION_REUSE="false"; shift ;;
      *) echo "devflow: run-external: unknown flag '$1'" >&2; exit 2 ;;
    esac
  done
  [ -n "$PHASE" ] || { echo "devflow: run-external: --phase is required" >&2; exit 2; }
  # --phase is spliced into artifact paths ($RUN_DIR/$PHASE-*.txt); --effort into a codex `-c`
  # TOML string. Restrict both to a safe token charset so neither can escape the path/string.
  case "$PHASE" in *[!A-Za-z0-9._-]*) echo "devflow: run-external: --phase must match [A-Za-z0-9._-]+" >&2; exit 2 ;; esac
  [ -n "$PROMPT_FILE" ] && [ -f "$PROMPT_FILE" ] || { echo "devflow: run-external: --prompt-file <path> is required and must exist" >&2; exit 2; }
  case "$BACKEND" in codex|claude) ;; *) echo "devflow: run-external: --backend must be 'codex' or 'claude'" >&2; exit 2 ;; esac
  [ -n "$MODEL" ]  || { echo "devflow: run-external: --model is required"  >&2; exit 2; }
  [ -n "$EFFORT" ] || { echo "devflow: run-external: --effort is required" >&2; exit 2; }
  case "$EFFORT" in *[!A-Za-z0-9._-]*) echo "devflow: run-external: --effort must match [A-Za-z0-9._-]+" >&2; exit 2 ;; esac
  case "$ROLE" in reviewer|implementer) ;; *) echo "devflow: run-external: --role must be 'reviewer' or 'implementer'" >&2; exit 2 ;; esac
  PROMPT="$(cat "$PROMPT_FILE")"
  DEVFLOW_ROLE="$ROLE"   # devflow_run_external reads this to pick codex's sandbox mode

  # Resolve the execution binary from the TRUSTED config only (never a flag, never the
  # project file); claude always resolves via PATH. FALLBACK_COMMAND is set here too.
  local BIN=""
  if [ "$BACKEND" = "codex" ]; then
    devflow_resolve_codex_bin      # sets CODEX_BIN + FALLBACK_COMMAND
    BIN="$CODEX_BIN"
  else
    BIN="$(command -v claude)"
    [ -n "$BIN" ] || { echo "devflow: FATAL — claude CLI not found on PATH." >&2; exit 1; }
    FALLBACK_COMMAND=""
  fi

  # Mark this RUN_DIR as in-use for the whole call so a concurrent `dir --fresh` refuses to
  # wipe our session/output files mid-flight. Cleared by the EXIT trap in devflow_lease_acquire.
  devflow_lease_acquire

  # CALL_RESULT/SESSION_ID are only ever assigned past the poll loop in devflow_run_external
  # — its hard-cap timeout path `return`s before reaching that point. Initialize both so the
  # report below never crashes on exactly the failure path that most needs a clean report.
  CALL_RESULT=""; SESSION_ID=""
  devflow_run_external "$BIN"
  devflow_after_call
  local after_exit=$?

  echo "RUN_DIR=$RUN_DIR"
  echo "PHASE=$PHASE"
  echo "EXIT=$CODEX_EXIT"
  printf '%s\n' "$CALL_RESULT" > "$RUN_DIR/$PHASE-verdict.txt"
  echo "VERDICT_FILE=$RUN_DIR/$PHASE-verdict.txt"
  # No machine verdict parse. The orchestrator is an LLM that reads VERDICT_FILE and judges
  # approval itself — a bash token classifier would just be a second, more brittle decision on
  # the same text (it once misread "no blocking issues found. APPROVED" as ambiguous). EXIT
  # above is the only mechanical signal (did the CLI complete, or hit the hard cap); the verdict
  # text is data for the caller to read.
  echo "SESSION_ID=${SESSION_ID:-}"
  echo "SESSION_FILE=${SESSION_FILE:-}"
  return "$after_exit"
}

# ── dispatcher ───────────────────────────────────────────────────────────────
main() {
  local cmd="${1:-}"; shift || true
  case "$cmd" in
    dir)          cmd_dir "$@" ;;
    run-external) cmd_run_external "$@" ;;
    *) echo "usage: $(basename "$0") dir [--fresh] | run-external --backend <codex|claude> --model <m> --effort <e> --phase <p> --prompt-file <f> [--role reviewer|implementer] [--resume <id>] [--no-session-reuse]" >&2; exit 2 ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
  exit $?
fi
