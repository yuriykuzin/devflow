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
# The strong hash, and the ONLY place the tool is chosen. Returns non-zero when neither tool
# exists, so a caller that must not fall back can just check the status.
_devflow_strong_hash() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 | cut -c1-16
  elif command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -c1-16
  else return 1
  fi
}
# The cosmetic flavour, for the RUN_DIR name: any collision-resistant-enough digest will do, so
# cksum is an acceptable last resort here. The freshness gate must NOT use this — see
# devflow_snapshot_digest.
# Probed, not `_devflow_strong_hash || cksum`: a chained fallback would re-read a stdin the strong
# hash had already consumed if it failed mid-stream. The probe runs on a throwaway empty stdin, so
# the tool set lives in exactly one place — adding a tool there cannot leave this on cksum.
_devflow_hash() {
  if printf '' | _devflow_strong_hash >/dev/null 2>&1
  then _devflow_strong_hash
  else cksum | cut -d' ' -f1
  fi
}
DEVFLOW_ROOT_HASH="$(printf '%s' "$DEVFLOW_PROJECT_ROOT" | _devflow_hash)"
# NOT under $TMPDIR. RUN_DIR holds the freshness gate's artifacts — `<phase>.tree` and
# `<phase>-verdict.txt` — and a `--role implementer` call runs the backend in WRITE mode:
# `codex --full-auto` is sandbox_mode=workspace-write, whose default writable roots include
# $TMPDIR and /tmp (that is what the CLI's own exclude_tmpdir_env_var / exclude_slash_tmp knobs
# are for), and `claude --permission-mode default` has no OS sandbox at all. With the gate
# artifacts in $TMPDIR, a fix call — or any injected instruction inside the untrusted code it was
# told to fix — could write its own APPROVED plus a matching snapshot and the next
# freshness-check would bless it: the reviewer-only guard would be decorative. The path is still
# deterministic per project root and still outside the repo tree. DEVFLOW_RUN_HOME exists for the
# test harness (a sandboxed HOME) — it is read from the environment, so never point it at a
# writable root of a write-mode call.
RUN_DIR="${DEVFLOW_RUN_HOME:-$HOME/.devflow/run}/devflow-run.$DEVFLOW_ROOT_HASH"

# Create RUN_DIR (and its parent) 0700 before anything writes into it. devflow is a single-user
# tool on a personal machine: this is hygiene, not a defence against another uid on the box, so a
# failed mkdir is the only fatal case. The touch() stamps last-USE — the GC sweep below ages dirs
# by mtime, and phase files are truncated rather than re-created, so without it a steadily-reused
# checkout would look abandoned and be reaped mid-project.
devflow_secure_dir() {
  local d="$1"
  mkdir -p "$d" 2>/dev/null
  [ -d "$d" ] || { echo "devflow: FATAL — could not create $d (exists as a file?); refusing to proceed." >&2; exit 1; }
  chmod 700 "$d" 2>/dev/null
  touch "$d" 2>/dev/null
}
devflow_secure_dir "$(dirname "$RUN_DIR")"
devflow_secure_dir "$RUN_DIR"

# Every value-taking flag needs its argument; under `set -u` a bare "$3" on a dangling flag
# would crash with a raw "unbound variable" instead of the caller's own usage message. Shared
# across every subcommand's flag parser (not nested in one, so it's defined before any
# particular cmd_* runs).
_need_val() { [ "$3" -ge 2 ] || { echo "devflow: $1: $2 requires a value" >&2; exit 2; }; }

# ── opportunistic GC of stale run dirs ───────────────────────────────────────────
# RUN_DIR is one-per-project-root, so a worktree-per-feature workflow mints a NEW hash every
# run and `dir --fresh` reuse never reclaims the old ones — completed run dirs would pile up
# without bound. GC runs on EVERY `dir` (not only `--fresh`): `dir` is the once-per-pipeline
# entry point every skill calls, whereas `--fresh` is passed only when starting a NEW feature —
# gating the sweep on it would let dirs accumulate indefinitely for anyone who reuses a checkout
# instead of worktrees. A sibling devflow-run.* dir is reclaimed only when it is ours (uid) and
# its mtime is more than DEVFLOW_RUN_TTL_DAYS full 24h-periods old (default 7; find rounds down,
# so ~8 days in practice). mtime is a true last-USE clock because devflow_secure_dir touch()es
# RUN_DIR on every invocation. The current RUN_DIR is excluded by basename (robust to a trailing
# slash that would make a `//` path-string compare miss). Best-effort: a non-numeric
# DEVFLOW_RUN_TTL_DAYS disables the sweep, a failed rm WARNs (never a silent skip) but never
# aborts the command, and a non-empty sweep says what it did.
devflow_gc_old_runs() {
  local ttl="${DEVFLOW_RUN_TTL_DAYS:-7}" self cand n=0
  case "$ttl" in ''|*[!0-9]*) return 0 ;; esac
  self="$(basename "$RUN_DIR")"
  while IFS= read -r cand; do
    [ -n "$cand" ] || continue
    if rm -rf "$cand" 2>/dev/null; then n=$((n+1))
    else echo "devflow: WARN — GC could not reclaim $cand (files locked/immutable?)." >&2; fi
  done < <(find "$(dirname "$RUN_DIR")" -mindepth 1 -maxdepth 1 -type d -name 'devflow-run.*' \
             ! -name "$self" -uid "$(id -u)" -mtime "+$ttl" 2>/dev/null)
  [ "$n" -gt 0 ] && echo "devflow: GC reclaimed $n abandoned run dir(s) (idle >${ttl}d)." >&2
  return 0
}

# ── dir ────────────────────────────────────────────────────────────────────────
# Emit the (secured) RUN_DIR for this project so a skill knows where session/output files
# live. `--fresh` wipes it first to start a clean run — clearing a prior feature's phase
# session files so they aren't silently resumed.
#
# `--fresh` refuses to wipe while a run is live: a `$RUN_DIR/.active-<pid>` lease, written by
# `cmd_run_external` for the duration of its call and removed on its one exit path, names the
# runner process that is still in flight. `kill -0` on that pid decides liveness; a lease whose
# pid is gone (a crash, a kill -9 that skipped the cleanup) is stale and is removed on sight, not
# treated as active. `--force` skips the check entirely, for an operator who knows better. This
# closes A3: without it, `--fresh` was an UNCONDITIONAL wipe that could delete a live call's
# session/output files out from under it, silently — one pipeline per checkout at a time was a
# convention, not an enforced guarantee. (Parallel work still belongs in git worktrees — a
# worktree has its own repo root, so its own RUN_DIR hash, and never contends on one lease.)
cmd_dir() {
  local fresh=0 force=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --fresh) fresh=1; shift ;;
      --force) force=1; shift ;;
      *) echo "devflow: dir: unknown flag '$1'" >&2; exit 2 ;;
    esac
  done
  if [ "$fresh" = "1" ] && [ "$force" != "1" ]; then
    local lease pid
    for lease in "$RUN_DIR"/.active-*; do
      [ -e "$lease" ] || continue   # the glob itself when nothing matches (no nullglob in 3.2)
      pid="${lease##*/.active-}"
      case "$pid" in
        ''|*[!0-9]*) rm -f "$lease" ;;                       # not a pid-shaped lease -> litter, drop it
        *) if kill -0 "$pid" 2>/dev/null; then
             echo "RUN_ACTIVE pid=$pid"
             exit 9
           else
             rm -f "$lease"                                 # stale: the pid it named is gone
           fi ;;
      esac
    done
  fi
  if [ "$fresh" = "1" ]; then
    # A failed rm must NOT fall through to a printed RUN_DIR as if the wipe succeeded (an
    # `&&` short-circuit would skip devflow_secure_dir yet still return 0) — abort loudly.
    rm -rf "$RUN_DIR" || { echo "devflow: FATAL — could not wipe $RUN_DIR (files locked/immutable?); refusing to proceed on a stale run." >&2; exit 1; }
    devflow_secure_dir "$RUN_DIR"
  fi
  devflow_gc_old_runs   # prune abandoned sibling run dirs (worktree workflows never reuse a hash)
  echo "RUN_DIR=$RUN_DIR"
}

# ── trusted codex-binary resolution ──────────────────────────────────────────────
# `command_path` chooses which binary devflow *executes*, so it is read ONLY from the plugin
# default and ~/.devflow/config.yaml — NEVER from a project-level .devflow.yaml (a repo you
# cloned could otherwise point devflow at a binary it ships). This is a fixed one-key,
# one-level-deep reader for files we control, not a general YAML parser: it prints the value of
# `command_path` found as a direct child of the top-level `codex:` block, later files (global
# config) overriding earlier (the plugin default).
devflow_codex_paths() {
  awk '
    FNR==1 { in_codex=0 }                                   # reset section state per file
    /^[^[:space:]#]/ { in_codex = ($0 ~ /^codex:[[:space:]]*$/) }
    in_codex && /^  command_path[[:space:]]*:/ {
      val=$0; sub(/^[^:]*:[[:space:]]*/, "", val)           # strip "  key:" prefix
      sub(/[[:space:]]+#.*$/, "", val)                      # strip trailing inline comment
      gsub(/^"|"$/, "", val)                                # strip surrounding double quotes
      print val
    }
  ' "$@"
}
# Resolve CODEX_BIN (a binary whose `exec --help` advertises --json — a bare `codex` can hit
# an NVM-shadowed old CLI lacking it) from the trusted config files only.
devflow_resolve_codex_bin() {
  local default_cfg="$DEVFLOW_PLUGIN_DIR/config.default.yaml" global_cfg="$HOME/.devflow/config.yaml"
  local cmd_path="" val cand
  local -a cfgs=()
  [ -f "$default_cfg" ] && cfgs+=("$default_cfg")
  [ -f "$global_cfg" ]  && cfgs+=("$global_cfg")
  if [ "${#cfgs[@]}" -gt 0 ]; then
    # Last value wins: the global config is read after the plugin default.
    while IFS= read -r val; do cmd_path="$val"; done < <(devflow_codex_paths "${cfgs[@]}")
  fi
  CODEX_BIN=""
  local probe_out probe_rc
  # A configured command_path is a trust-boundary control — it is read ONLY from global config
  # precisely so a project cannot choose what devflow executes. So when it is set it is the ONLY
  # candidate: ANY reason it does not work (absent, not executable, probe failed) is fatal, never
  # a reason to run a different binary. Handling it before the auto-resolve loop is what makes
  # that total — a per-candidate check inside the loop covered the probe but let `[ -x ]` skip a
  # stale path straight into /opt/homebrew/bin/codex, i.e. exactly the silent substitution the
  # rule forbids (in a test sandbox: the real network-calling CLI in place of the stub).
  if [ -n "$cmd_path" ]; then
    if [ ! -x "$cmd_path" ]; then
      echo "devflow: FATAL — codex.command_path ($cmd_path) is missing or not executable." >&2
      echo "  Refusing to run a different codex binary instead: command_path decides what devflow executes." >&2
      echo "  Fix codex.command_path in ~/.devflow/config.yaml, or clear it to auto-resolve." >&2
      exit 1
    fi
    probe_out="$("$cmd_path" exec --help < /dev/null 2>&1)"; probe_rc=$?
    if printf '%s' "$probe_out" | grep -q -- '--json'; then
      CODEX_BIN="$cmd_path"
    else
      # rc is the exit code of `exec --help`, NOT of the --json check that decides pass/fail, so
      # rc=0 here means the binary ran fine and simply never mentioned --json — the modal case
      # (an outdated CLI), and the one a reader would otherwise misdiagnose as "binary is fine".
      echo "devflow: FATAL — codex.command_path ($cmd_path) did not pass the 'exec --json' probe (rc=$probe_rc)." >&2
      echo "  Refusing to run a different codex binary instead: command_path decides what devflow executes." >&2
      if [ "$probe_rc" -eq 0 ]; then
        echo "  'exec --help' ran but never advertised --json — this CLI most likely predates --json support; upgrade it." >&2
      else
        echo "  If the probe failed transiently, retry; if the path is wrong, fix codex.command_path." >&2
      fi
      echo "  First line of the probe output: $(printf '%s' "$probe_out" | head -1)" >&2
      exit 1
    fi
  else
    # Read line by line, not `for cand in $(which -a codex)`: an install path containing a space
    # would be word-split into two nonexistent candidates.
    while IFS= read -r cand; do
      [ -n "$cand" ] && [ -x "$cand" ] || continue
      probe_out="$("$cand" exec --help < /dev/null 2>&1)"
      if printf '%s' "$probe_out" | grep -q -- '--json'; then CODEX_BIN="$cand"; break; fi
    done < <(printf '%s\n' /opt/homebrew/bin/codex /usr/local/bin/codex; which -a codex 2>/dev/null)
  fi
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
# Sets: OUT EVENTS STDERR SESSION_FILE CODEX_PID CODEX_EXIT CALL_RESULT SESSION_ID EXTRACTOR_FAILED.
devflow_run_external() {
  local bin="$1"
  PHASE="${PHASE:-review}"
  OUT="$RUN_DIR/$PHASE-output.txt"; EVENTS="$RUN_DIR/$PHASE-events.jsonl"
  STDERR="$RUN_DIR/$PHASE-stderr.txt"; SESSION_FILE="$RUN_DIR/$PHASE.session"
  : > "$OUT"; : > "$EVENTS"; : > "$STDERR"      # truncate — never read a prior run's output
  # Reset with the other per-call state, NOT next to the extractor that sets it: the hard-timeout
  # path returns before ever reaching that code, so a reset placed there is skipped on exactly the
  # call that produced nothing, and the next call would read the previous one's value.
  EXTRACTOR_FAILED=0

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
      # Belt for the same hazard RUN_DIR's location addresses: workspace-write treats $TMPDIR and
      # /tmp as writable roots, and a write-mode call must not be able to reach devflow's own gate
      # artifacts wherever a future edit puts them. Unknown `-c` keys are ignored by the CLI, so
      # this is additive-only — the load-bearing control is that RUN_DIR is NOT under either root.
      copts+=(-c 'sandbox_workspace_write.exclude_tmpdir_env_var=true' \
              -c 'sandbox_workspace_write.exclude_slash_tmp=true')
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
    # argv as an array, matching the codex branch above — no unquoted `$CLAUDE_EXTRA` /
    # `${RESUME_ID:+…}` splices. Only argv delta vs the spliced form: --no-session-persistence
    # now follows --effort instead of preceding --model. Both are order-independent valueless
    # options and "$PROMPT" is still the sole trailing positional, so claude parses it the same.
    local -a cargs=(-p --output-format json --permission-mode "$PMODE" --model "$MODEL" --effort "$EFFORT")
    [ "${SESSION_REUSE:-true}" = "false" ] && cargs+=(--no-session-persistence)
    [ -n "${RESUME_ID:-}" ] && cargs+=(--resume "$RESUME_ID")
    nohup python3 -c "$DEVFLOW_SETSID" "$bin" "${cargs[@]}" "$PROMPT" \
      < /dev/null > "$OUT" 2> "$STDERR" &
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
    # Output contract: SESSION_FILE always exists after this function returns, even on a hard
    # timeout — but CREATE it, never truncate it. A killed call captures no id; blanking an id
    # an earlier round captured turns one transient timeout into "this review never had a
    # session", which the skills read as grounds for self-certifying without a re-review.
    [ -e "$SESSION_FILE" ] || : > "$SESSION_FILE"
    [ -s "$SESSION_FILE" ] && echo "devflow: WARN — timed out with no new session id; keeping the previously captured one." >&2
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
  # devflow-json.py exits 3 for "ran, nothing usable in there" and 0 with the value on stdout.
  # Any OTHER non-zero code means the extractor itself could not run (interpreter missing, a
  # traceback, a transient spawn failure under load). Both outcomes still fail closed — an empty
  # CALL_RESULT makes the call unusable — but they must not be reported as the same thing: a
  # silent extractor failure reads as "the reviewer produced nothing" and burns a review round
  # on a call whose events file was perfectly good.
  # Devflow's OWN helper gets its own stderr sink. $STDERR is the backend CLI's; a python
  # traceback landing there would be echoed to the caller as the backend's own words.
  local jrc jerr="$RUN_DIR/$PHASE-extractor-stderr.txt"
  : > "$jerr"
  CALL_RESULT="$(python3 "$jsonc" "$src" result "$jsonf" 2>>"$jerr")"; jrc=$?
  if [ "$jrc" -ne 0 ]; then
    CALL_RESULT=""
    if [ "$jrc" -ne 3 ]; then
      EXTRACTOR_FAILED=1
      echo "devflow: WARN — the verdict extractor could not run (rc=$jrc); treating the call as unusable. This is a devflow/python problem, not a reviewer verdict — see $jerr." >&2
    fi
  fi
  SESSION_ID="$(python3 "$jsonc" "$src" session "$jsonf" 2>>"$jerr")"; jrc=$?
  if [ "$jrc" -ne 0 ]; then
    SESSION_ID=""
    [ "$jrc" -eq 3 ] || echo "devflow: WARN — the session-id extractor could not run (rc=$jrc); resume may restart fresh." >&2
  fi
  if [ "${SESSION_REUSE:-true}" = "false" ]; then
    : > "$SESSION_FILE"
  elif [ -n "$SESSION_ID" ]; then
    printf '%s\n' "$SESSION_ID" > "$SESSION_FILE"
  elif [ -s "$SESSION_FILE" ]; then
    # A failed call captures no id. Do NOT blank a good id an earlier round captured — that
    # turns one transient failure into "this review never had a session", which the skills
    # treat as grounds for self-certifying without an external re-review.
    echo "devflow: WARN — no session id captured on this call; keeping the previously captured one." >&2
  else
    : > "$SESSION_FILE"; echo "devflow: WARN — no session id captured; resume will start fresh." >&2
  fi
  return "$CODEX_EXIT"
}

# ── freshness invariant ──────────────────────────────────────────────────────
# Snapshot the exact tree an external reviewer is about to read, so a later APPROVED can be
# checked against it: the orchestrator may reclassify someone else's fresh reading, never
# certify code nobody re-read.
#
# The snapshot source: a single review target when --freshness-file/--file names one (a plan
# file is the whole review target, so its content IS what must not drift), else the worktree.
# $2 (base override) only ever applies to the worktree flavour — `scope-digest --base <sha>`;
# a single-file snapshot has no "base" to diff against, its content already IS the whole thing.
devflow_snapshot_source() {
  if [ -n "${1:-}" ]; then cat -- "$1"; else devflow_tree_snapshot "${2:-}"; fi
}

# What actually gets STORED and compared: one hash line, not the content itself. The content is
# only a means of detecting an edit, and keeping it meant a `<phase>.tree` the size of the whole
# diff plus every untracked file — unbounded, and nothing ever read it. Prints nothing and
# fails, printing nothing, in three cases: the source exited non-zero (no git repo, an unreadable
# file, any failed git command), the snapshot came out EMPTY, or no strong hash tool exists.
# Hashing any of those would turn "could not snapshot" into a perfectly valid-looking digest,
# exactly the fail-open this gate exists to prevent. The residual it cannot detect is a source
# that exits 0 while complaining on stderr (git advice, a noisy filter) — hence the WARN below.
#
# The snapshot is streamed through a temp FILE, never through `content="$(...)"`: command
# substitution strips ALL trailing newlines and (under bash) deletes NUL bytes, so `# plan v1\n`
# and `# plan v1\n\n\n` would hash identically and a stale APPROVED would survive that edit —
# fail-open in the one gate that must not fail open. The stream also never lives in RAM.
#
# cksum is refused here. _devflow_hash falls back to it for the cosmetic RUN_DIR name, but a
# 32-bit CRC is linear and forgeable: a write-mode call could pad an edited tree to the same
# digest and freshness-check would print FRESH=yes on code no reviewer read.
devflow_snapshot_digest() {
  # $RUN_DIR, not $TMPDIR: a write-mode call can reach $TMPDIR, and this file decides a verdict.
  # It also matters that RUN_DIR is outside the WORKTREE: written inside, `ls-files -o` would list
  # this very file and `cat` it into itself while it was being written — an unbounded runaway, not
  # an error. (Reproduced the hard way: point DEVFLOW_RUN_HOME inside a repo and the snapshot
  # grows until the disk does.) DEVFLOW_RUN_HOME is a test seam — never aim it into a worktree.
  # No trap — a signal mid-stream leaks the two .snapshot*.<pid> files, the same litter class as a
  # killed call's .tree.pending, and a stale one can never be misread (the redirect truncates).
  local snap="$RUN_DIR/.snapshot.$$" snaperr="$RUN_DIR/.snapshot-err.$$"
  # The source's stderr is SURFACED, not discarded. Emptiness is the only failure the digest
  # itself detects, so anything the source complains about while still exiting 0 (a git hint, a
  # warning from a hook or filter) is the only signal that the snapshot may be incomplete.
  devflow_snapshot_source "${1:-}" "${2:-}" > "$snap" 2>"$snaperr"
  local src_rc=$?
  # Printed on BOTH paths. On the failure path this IS the reason the callers tell the operator to
  # look for ("see the reason above") — deleting it unread left that message pointing at nothing.
  if [ -s "$snaperr" ]; then
    if [ "$src_rc" -eq 0 ]
    then echo "devflow: WARN — the snapshot source wrote to stderr; the snapshot may be incomplete:" >&2
    else echo "devflow: the snapshot source failed:" >&2
    fi
    cat "$snaperr" >&2
  fi
  rm -f "$snaperr"
  [ "$src_rc" -eq 0 ] || { rm -f "$snap"; return 1; }
  if [ ! -s "$snap" ]; then rm -f "$snap"; return 1; fi
  _devflow_strong_hash < "$snap"
  local rc=$?
  rm -f "$snap"
  [ "$rc" -eq 0 ] || echo "devflow: no shasum/sha256sum — refusing to gate a review on a forgeable checksum." >&2
  return $rc
}

# The worktree flavour of the snapshot.
# Captures CONTENT, not just status: editing an already-modified file leaves both HEAD and
# `git status --porcelain` unchanged, so a status-only snapshot would pass on unread code.
# Untracked paths are never `cat`ed blindly — a symlink would copy content from outside the
# repo and a FIFO/device would hang or stream forever, so those are recorded as metadata.
# `ls-files -o -z` + `read -d ""` instead of quotePath=false: quotePath only suppresses quoting
# for non-ASCII, while git C-quotes CONTROL characters unconditionally. A file named with an
# embedded newline therefore arrived as the literal string `"evil\nx"`, which `[ -f ]` rejects
# and `cat` never sees, so its content was excluded from the digest with rc=0 and no stderr —
# unlimited unreviewed edits under a constant digest. `-z` emits raw bytes, so no name can be
# unreadable and no name needs unquoting. `ls-files -o`/`cat` resolve against CWD
# while `status`/`diff` are root-relative, so the whole thing runs from the repo root in a
# subshell — otherwise the same tree snapshots differently depending on the caller's CWD.
devflow_tree_snapshot() {
( BASE_OVERRIDE="${1:-}"
  TOP="$(git rev-parse --show-toplevel)" || exit 1
  # `cd ""` SUCCEEDS, so an unset toplevel would slip past `cd ... || exit 1` and snapshot the
  # caller's CWD instead of the repo — a snapshot of the wrong tree, not a detectable failure.
  [ -n "$TOP" ] || exit 1
  cd "$TOP" || exit 1
  # A snapshot must not run programs the repo names in its own config or gitattributes: they
  # could report a constant, and the diff section is the ONLY content-bearing part for tracked
  # files, so a constant there makes an edited tree look unchanged — the fail-open this gate
  # exists to prevent. --no-textconv covers textconv filters ONLY; external diff drivers
  # (diff.external, or `diff=x` in gitattributes) need --no-ext-diff, and core.fsmonitor= must
  # be set on ls-files too. Cheap here, and the gate reads the whole tree every round.
  #
  # Every git command is `|| exit 1`: only the LAST pipeline decides a subshell's status, so
  # without it a failed `git diff` merely SHORTENS the snapshot. It stays non-empty (ls-files
  # still runs), hashes cleanly, and two different trees digest the same — FRESH=yes on unread
  # code. An unborn HEAD is the one expected "failure": recorded as a value so a first-commit
  # repo still snapshots, with the empty-tree object as the diff base.
  # --verify --quiet exits 1 with NO stderr on an unborn HEAD, so the expected case stays quiet
  # while a corrupt/unreadable HEAD still reaches the caller's stderr WARN instead of being
  # mislabelled `@unborn HEAD`.
  if HEAD_OID="$(git rev-parse --verify --quiet HEAD)"; then
    printf '%s\n' "$HEAD_OID"
    # BASE_OVERRIDE (scope-digest --base <sha>) only changes what the diff is taken AGAINST;
    # the HEAD_OID line above always names the actual current HEAD, never the override, so the
    # digest still identifies which commit the tree sits on.
    DIFF_BASE="${BASE_OVERRIDE:-$HEAD_OID}"
  else
    printf '@unborn HEAD\n'
    # Asked for, not hardcoded: the empty-tree oid differs under objectFormat=sha256, and the
    # absence of -w is what keeps this read-only (it computes an oid, it writes no object).
    DIFF_BASE="${BASE_OVERRIDE:-$(git hash-object -t tree /dev/null)}" || exit 1
  fi
  # -uall, not the default `-unormal`: normal collapses an untracked DIRECTORY to a single
  # `?? d/`, which left the file boundaries inside it conveyed ONLY by the `###` headers below —
  # forgeable, see the framing comment there. With -uall the untracked file SET is recorded here,
  # independently of that framing, so the two sections corroborate each other.
  git -c core.fsmonitor= status --porcelain -uall || exit 1
  git -c core.fsmonitor= -c diff.external= diff --no-ext-diff --no-textconv "$DIFF_BASE" || exit 1
  # Every header carries a BYTE COUNT, and that is what makes the framing unforgeable. Without
  # it the entry separator was just the text `### <path>`, which a file is free to contain: one
  # file holding "X\n### d/b\nY\n" serialized byte-identically to two files d/a="X\n" d/b="Y\n",
  # so a reviewer read one tree and the implementer could ship the other under FRESH=yes. The
  # same trick with `@symlink -> t` let a regular file impersonate a symlink. With a length the
  # reader's framing no longer depends on content the tree controls.
  git -c core.fsmonitor= ls-files -o -z --exclude-standard | while IFS= read -r -d '' f; do
    if [ -L "$f" ]; then
      LINK="$(readlink -- "$f")" || exit 1
      printf '### %s @symlink %s\n%s\n' "$f" "${#LINK}" "$LINK"
    # `|| exit 1` on both reads, not a marker: the loop's status is its LAST iteration's, so an
    # unreadable file that happens to sort before a readable one produced a non-empty snapshot
    # blind to that file's content — two different trees, one digest, FRESH=yes on unread bytes.
    # Order must not decide whether the gate holds. (A marker would not help: both versions of
    # the file record the same one.)
    elif [ -f "$f" ]; then
      NBYTES="$(wc -c < "$f" | tr -d '[:space:]')" || exit 1
      printf '### %s @file %s\n' "$f" "$NBYTES"
      cat -- "$f" || exit 1
    else printf '### %s @non-regular, content not read\n' "$f"; fi
  done )
}

# Re-snapshot and compare against the promoted .tree. Exit 0 = the tree still matches what the
# reviewer read; 2 = no .tree at all, so nothing was ever reviewed (never an approval); 1 = the
# tree changed since. A leftover .tree.pending is not a .tree and does not count.
cmd_freshness_check() {
  local PH="" FILE="" FILE_GIVEN=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --phase) [ $# -ge 2 ] || { echo "devflow: freshness-check: --phase requires a value" >&2; exit 2; }
               PH="$2"; shift 2 ;;
      # The review target is one file (a plan) rather than the worktree.
      --file)  [ $# -ge 2 ] || { echo "devflow: freshness-check: --file requires a value" >&2; exit 2; }
               FILE="$2"; FILE_GIVEN=1; shift 2 ;;
      *) echo "devflow: freshness-check: unknown flag '$1'" >&2; exit 2 ;;
    esac
  done
  [ -n "$PH" ] || { echo "devflow: freshness-check: --phase is required" >&2; exit 2; }
  case "$PH" in *[!A-Za-z0-9._-]*|.|..) echo "devflow: freshness-check: --phase must match [A-Za-z0-9._-]+ and not be '.' or '..'" >&2; exit 2 ;; esac
  # An empty or missing --file would fall through to a WORKTREE snapshot and then be compared
  # against a single-file .tree — a permanent tree-changed that misreports a caller bug (an
  # unset $PLAN_PATH) as "you edited the plan", which no amount of re-reviewing fixes.
  if [ "$FILE_GIVEN" = 1 ]; then
    [ -n "$FILE" ] && [ -f "$FILE" ] \
      || { echo "devflow: freshness-check: --file must name an existing file (got '$FILE')" >&2; exit 2; }
  fi
  local TREE="$RUN_DIR/$PH.tree"
  if [ ! -s "$TREE" ]; then
    echo "FRESH=no"; echo "REASON=no-tree"
    echo "devflow: no $PH.tree — no external call ever completed for this phase. Not reviewed, so never APPROVED." >&2
    return 2
  fi
  local NOW
  # A snapshot that cannot be TAKEN is not a match and not a mismatch. Reporting it as
  # tree-changed is the safe direction (re-review), but it must not read as "you edited files".
  NOW="$(devflow_snapshot_digest "$FILE")" || {
    echo "FRESH=no"; echo "REASON=snapshot-failed"
    echo "devflow: could not snapshot the review target for $PH — not reviewed, so never APPROVED. See the reason above." >&2
    return 1
  }
  if [ "$NOW" = "$(cat "$TREE")" ]; then
    echo "FRESH=yes"; return 0
  fi
  echo "FRESH=no"; echo "REASON=tree-changed"
  echo "devflow: the tree changed since $PH was reviewed — re-review before approving." >&2
  return 1
}

# ── scope-digest (execution profiles: result.yaml `scope_digest`, `passes complete --scope`) ──
# Prints a stable digest of the CURRENT working tree (tracked + untracked, dirty included) —
# the same content-addressed snapshot the freshness gate above already computes and trusts, not
# a second, differently-forgeable notion of "what changed". `--base <sha>` only changes what the
# diff section is taken against (still reading the actual current tree); with no --base it's
# relative to HEAD, matching devflow_tree_snapshot's default.
cmd_scope_digest() {
  local base=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --base) _need_val scope-digest --base "$#"; base="$2"; shift 2 ;;
      *) echo "devflow: scope-digest: unknown flag '$1'" >&2; exit 2 ;;
    esac
  done
  local digest
  digest="$(devflow_snapshot_digest "" "$base")" || {
    echo "devflow: scope-digest: could not snapshot the working tree — see the reason above." >&2
    exit 1
  }
  printf '%s\n' "$digest"
  exit 0
}

# ── pass budget (execution profiles: review.max_passes) ─────────────────────────
# One review pass = one reviewer call (internal agent or external CLI) over a deliverable's
# agreed scope. `review.max_passes` caps passes PER DELIVERABLE (not per phase), so a caller
# reserves before making the call and closes afterwards; re-reserving the same --call-id must
# not charge twice (compaction/resume replays the same id, never a fresh one).
#
# State: one file per deliverable, $RUN_DIR/passes-<deliverable>.tsv, one line per call —
# "<call-id>\t<reserved-epoch>\t<closed-epoch|->" — plus:
#   passes-<deliverable>.max   the budget, written ONCE by `passes init` (fixed for the
#                              deliverable's life; `dir --fresh` is the only reset). `reserve`
#                              no longer takes --max — it reads this file, and refuses to run
#                              (BUDGET_NOT_INITIALIZED, exit 2) rather than default to unlimited
#                              if `init` was never called.
#   passes-<deliverable>.done  written ONCE by `passes complete`, after every reservation on the
#                              tsv has been closed — the no-double-review record.
# `used` is simply the tsv line count: closing a call does not un-charge it.
#
# Locking: a `mkdir` lock directory, not `flock` — flock(1) is not part of stock macOS, and this
# script is otherwise plain POSIX-ish bash with no non-builtin locking dependency. `mkdir` is
# atomic on every filesystem devflow runs on, and a stuck lock (crash mid-reserve) is just a
# stale directory an operator can rmdir by hand — acceptable for a single-user tool, matching
# the "hygiene, not a security boundary" posture already documented on devflow_secure_dir.
_devflow_passes_file()      { printf '%s/passes-%s.tsv'  "$RUN_DIR" "$1"; }
_devflow_passes_max_file()  { printf '%s/passes-%s.max'  "$RUN_DIR" "$1"; }
_devflow_passes_done_file() { printf '%s/passes-%s.done' "$RUN_DIR" "$1"; }
_devflow_passes_lock_dir()  { printf '%s/.passes-%s.lock' "$RUN_DIR" "$1"; }

# Exact call-id match on the tsv's first field — NOT `grep -qF "$cid<TAB>"`, which matches a
# substring anywhere in the line (a call-id that is a suffix/prefix of another, or one that
# happens to reappear inside a later field, would false-match and silently no-op a reservation
# that should have charged, or refuse to close one that should have matched).
_devflow_passes_has_id() {
  awk -F'\t' -v c="$2" '$1==c{f=1} END{exit !f}' "$1" 2>/dev/null
}

_devflow_passes_lock() {
  local lockdir="$1" n=0
  while ! mkdir "$lockdir" 2>/dev/null; do
    n=$((n + 1))
    [ "$n" -ge 50 ] && return 1   # ~5s of contention -> something is stuck, fail loudly
    sleep 0.1
  done
  return 0
}
_devflow_passes_unlock() { rmdir "$1" 2>/dev/null || true; }

_devflow_passes_validate_id() {
  # Shared by --deliverable and --call-id: both are spliced into a filename or a TSV field.
  local label="$1" val="$2"
  case "$val" in
    ''|*[!A-Za-z0-9._-]*|.|..) echo "devflow: passes: $label must match [A-Za-z0-9._-]+ and not be '.' or '..'" >&2; exit 2 ;;
  esac
}

cmd_passes_init() {
  local deliv="" max=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --deliverable) _need_val "passes init" --deliverable "$#"; deliv="$2"; shift 2 ;;
      --max)         _need_val "passes init" --max "$#";         max="$2";  shift 2 ;;
      *) echo "devflow: passes init: unknown flag '$1'" >&2; exit 2 ;;
    esac
  done
  _devflow_passes_validate_id "--deliverable" "$deliv"
  case "$max" in ''|*[!0-9]*) echo "devflow: passes init: --max must be a non-negative integer" >&2; exit 2 ;; esac

  local mf lock
  mf="$(_devflow_passes_max_file "$deliv")"; lock="$(_devflow_passes_lock_dir "$deliv")"
  _devflow_passes_lock "$lock" || { echo "devflow: passes init: could not acquire the lock for '$deliv' (timed out)" >&2; exit 1; }
  if [ -f "$mf" ]; then
    local old; old="$(cat "$mf")"
    if [ "$old" != "$max" ]; then
      _devflow_passes_unlock "$lock"
      echo "BUDGET_ALREADY_SET max=$old"
      exit 8
    fi
    _devflow_passes_unlock "$lock"
    exit 0
  fi
  printf '%s\n' "$max" > "$mf"
  _devflow_passes_unlock "$lock"
  exit 0
}

cmd_passes_reserve() {
  local deliv="" cid=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --deliverable) _need_val "passes reserve" --deliverable "$#"; deliv="$2"; shift 2 ;;
      --call-id)     _need_val "passes reserve" --call-id "$#";     cid="$2";  shift 2 ;;
      *) echo "devflow: passes reserve: unknown flag '$1'" >&2; exit 2 ;;
    esac
  done
  _devflow_passes_validate_id "--deliverable" "$deliv"
  _devflow_passes_validate_id "--call-id" "$cid"

  local f mf lock
  f="$(_devflow_passes_file "$deliv")"; mf="$(_devflow_passes_max_file "$deliv")"; lock="$(_devflow_passes_lock_dir "$deliv")"
  _devflow_passes_lock "$lock" || { echo "devflow: passes reserve: could not acquire the lock for '$deliv' (timed out)" >&2; exit 1; }
  # No --max flag any more: reserve reads the budget `init` fixed, and refuses to charge a
  # deliverable that was never initialized rather than silently treating it as unlimited.
  if [ ! -f "$mf" ]; then
    _devflow_passes_unlock "$lock"
    echo "BUDGET_NOT_INITIALIZED"
    exit 2
  fi
  local max; max="$(cat "$mf")"
  : > "${f}.touch.$$" 2>/dev/null; rm -f "${f}.touch.$$" 2>/dev/null   # RUN_DIR writability check, cheap
  touch "$f" 2>/dev/null

  local used
  used="$(wc -l < "$f" 2>/dev/null | tr -d '[:space:]')"; used="${used:-0}"

  # Re-reserving the same call-id is a no-op EXCEPT when it was already closed (field 3 != "-"):
  # a closed id is a call that already happened and was already charged, so re-dispatching it
  # (compaction replaying a completed step, say) must be a loud refusal, not a second silent
  # no-op that lets a caller re-run a call whose verdict is already on the books.
  if _devflow_passes_has_id "$f" "$cid"; then
    local closed_at; closed_at="$(awk -F'\t' -v c="$cid" '$1==c{print $3; exit}' "$f")"
    if [ "$closed_at" != "-" ]; then
      _devflow_passes_unlock "$lock"
      echo "CALL_ALREADY_CLOSED call-id=$cid"
      exit 9
    fi
    _devflow_passes_unlock "$lock"
    if [ "$max" = "0" ]; then echo "remaining=unlimited"; else echo "remaining=$((max - used))"; fi
    exit 0
  fi

  if [ "$max" != "0" ] && [ "$used" -ge "$max" ]; then
    _devflow_passes_unlock "$lock"
    echo "BUDGET_EXHAUSTED used=$used max=$max"
    exit 3
  fi

  printf '%s\t%s\t-\n' "$cid" "$(date +%s)" >> "$f"
  used=$((used + 1))
  _devflow_passes_unlock "$lock"
  if [ "$max" = "0" ]; then echo "remaining=unlimited"; else echo "remaining=$((max - used))"; fi
  exit 0
}

cmd_passes_close() {
  local deliv="" cid=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --deliverable) _need_val "passes close" --deliverable "$#"; deliv="$2"; shift 2 ;;
      --call-id)     _need_val "passes close" --call-id "$#";     cid="$2";  shift 2 ;;
      *) echo "devflow: passes close: unknown flag '$1'" >&2; exit 2 ;;
    esac
  done
  _devflow_passes_validate_id "--deliverable" "$deliv"
  _devflow_passes_validate_id "--call-id" "$cid"

  local f lock
  f="$(_devflow_passes_file "$deliv")"; lock="$(_devflow_passes_lock_dir "$deliv")"
  [ -f "$f" ] || { echo "devflow: passes close: no reservation state for deliverable '$deliv'" >&2; exit 1; }
  _devflow_passes_lock "$lock" || { echo "devflow: passes close: could not acquire the lock for '$deliv' (timed out)" >&2; exit 1; }
  if ! _devflow_passes_has_id "$f" "$cid"; then
    _devflow_passes_unlock "$lock"
    echo "devflow: passes close: no reservation found for call-id '$cid' on deliverable '$deliv'" >&2
    exit 1
  fi
  local tmp; tmp="${f}.tmp.$$"
  awk -F'\t' -v OFS='\t' -v c="$cid" -v ts="$(date +%s)" '
    $1==c && $3=="-" { $3=ts } { print }
  ' "$f" > "$tmp" && mv "$tmp" "$f"
  _devflow_passes_unlock "$lock"
  exit 0
}

cmd_passes_status() {
  local deliv=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --deliverable) _need_val "passes status" --deliverable "$#"; deliv="$2"; shift 2 ;;
      *) echo "devflow: passes status: unknown flag '$1'" >&2; exit 2 ;;
    esac
  done
  _devflow_passes_validate_id "--deliverable" "$deliv"

  local f mf df used max open done_str scope
  f="$(_devflow_passes_file "$deliv")"; mf="$(_devflow_passes_max_file "$deliv")"; df="$(_devflow_passes_done_file "$deliv")"
  if [ -f "$f" ]; then used="$(wc -l < "$f" | tr -d '[:space:]')"; else used=0; fi
  if [ -f "$mf" ]; then max="$(cat "$mf")"; else max="-"; fi
  if [ -f "$f" ]; then open="$(awk -F'\t' '$3=="-"{print $1}' "$f" | paste -sd, - 2>/dev/null)"; else open=""; fi
  # scope comes from the .done sidecar's own `scope=<digest>` first field (written once by
  # `passes complete`) — never recomputed here, so a completed record can't drift from what the
  # reviewer actually saw (A10: this is what makes a no-double-review skip trustworthy).
  if [ -f "$df" ]; then
    done_str="yes"
    local doneline; doneline="$(cat "$df")"
    scope="${doneline%%$'\t'*}"; scope="${scope#scope=}"
  else
    done_str="no"; scope="-"
  fi
  echo "used=$used max=$max open=$open done=$done_str scope=$scope"
  exit 0
}

cmd_passes_complete() {
  local deliv="" scope="" verdict=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --deliverable) _need_val "passes complete" --deliverable "$#"; deliv="$2";   shift 2 ;;
      --scope)       _need_val "passes complete" --scope "$#";       scope="$2";   shift 2 ;;
      --verdict)     _need_val "passes complete" --verdict "$#";     verdict="$2"; shift 2 ;;
      *) echo "devflow: passes complete: unknown flag '$1'" >&2; exit 2 ;;
    esac
  done
  _devflow_passes_validate_id "--deliverable" "$deliv"
  [ -n "$scope" ] || { echo "devflow: passes complete: --scope is required" >&2; exit 2; }
  case "$verdict" in
    clean|blockers) ;;
    *) echo "devflow: passes complete: --verdict must be 'clean' or 'blockers'" >&2; exit 2 ;;
  esac

  local f lock
  f="$(_devflow_passes_file "$deliv")"; lock="$(_devflow_passes_lock_dir "$deliv")"
  _devflow_passes_lock "$lock" || { echo "devflow: passes complete: could not acquire the lock for '$deliv' (timed out)" >&2; exit 1; }
  local used open
  if [ -f "$f" ]; then
    used="$(wc -l < "$f" | tr -d '[:space:]')"
    open="$(awk -F'\t' '$3=="-"{print $1}' "$f" | paste -sd, - 2>/dev/null)"
  else
    used=0; open=""
  fi
  if [ -n "$open" ]; then
    _devflow_passes_unlock "$lock"
    echo "devflow: passes complete: open call id(s) remain for '$deliv': $open" >&2
    exit 1
  fi
  local df; df="$(_devflow_passes_done_file "$deliv")"
  printf 'scope=%s\tclosed=%s\tverdict=%s\tts=%s\n' "$scope" "$used" "$verdict" "$(date +%s)" > "$df"
  _devflow_passes_unlock "$lock"
  exit 0
}

cmd_passes() {
  local sub="${1:-}"; shift || true
  case "$sub" in
    init)     cmd_passes_init "$@" ;;
    reserve)  cmd_passes_reserve "$@" ;;
    close)    cmd_passes_close "$@" ;;
    status)   cmd_passes_status "$@" ;;
    complete) cmd_passes_complete "$@" ;;
    *) echo "usage: $(basename "$0") passes init --deliverable <id> --max <n> | passes reserve --deliverable <id> --call-id <cid> | passes close --deliverable <id> --call-id <cid> | passes status --deliverable <id> | passes complete --deliverable <id> --scope <digest> --verdict <clean|blockers>" >&2; exit 2 ;;
  esac
}

# ── preflight (execution profiles: is every bound agent actually usable on this host?) ──────
# Checks two DIFFERENT capabilities: does this host support named-agent delegation at all
# (today: only Claude Code does), and, where it does, does the named agent actually resolve.
# An explicitly bound but unresolvable agent is a hard error (exit 4/5) — never a silent
# fallback to the default execution path — unless `review.fallback_to_host` is set, in which
# case it's downgraded to exit 0 plus one FALLBACK_TO_HOST line per affected role, still
# printed so the report shows a fallback happened.
#
# `--expect-host` guards against an executor manifest (docs/contracts/executor-manifest-v1.md)
# generated for a DIFFERENT host than the one actually running this phase: the manifest's
# `host` field names whose agent catalogue the `roles.*.agent` values refer to, and a role name
# that happens to exist under a different host is a coincidence, not a resolved binding. When
# --roles-file carries a `_manifest.host` (only present when devflow-config.py resolve merged
# in an executor_manifest), it is compared against --expect-host if given, else against --host
# itself — so a plain `--host <h>` call, with no --expect-host, already catches a manifest built
# for another host. Absent a manifest (`_manifest.host` empty) this check never fires.
#
# `--write-effective <path>` writes effective-roles.json ONLY on the exit-0 path (see the
# interface contract in scratchpad/fixwave_spec.md): skills read role bindings from this file,
# not from --roles-file directly, so a fallback is reflected here as agent -> "" (the default
# execution path) plus one entry in `fallbacks[]` — never a binding a skill would try to use.
_devflow_json_escape() {
  local tab cr
  tab="$(printf '\t')"; cr="$(printf '\r')"
  printf '%s' "$1" \
    | sed 's/\\/\\\\/g; s/"/\\"/g' \
    | sed "s/${tab}/\\\\t/g; s/${cr}/\\\\r/g" \
    | sed -e ':a' -e '$!{N;ba' -e '}' -e 's/\n/\\n/g'
}

_devflow_write_effective_roles() {
  local path="$1" impl="$2" rev="$3" lens="$4" ver="$5" fb_list="$6"
  local fb_json="[]"
  if [ -n "$fb_list" ]; then
    local items="" role req first=1 item
    while IFS=$'\t' read -r role req; do
      [ -n "$role" ] || continue
      item="{\"role\":\"$(_devflow_json_escape "$role")\",\"requested\":\"$(_devflow_json_escape "$req")\"}"
      if [ "$first" = 1 ]; then items="$item"; first=0; else items="$items,$item"; fi
    done <<EOF
$fb_list
EOF
    fb_json="[$items]"
  fi
  printf '{"implementer":"%s","reviewer":"%s","reviewer_lens":"%s","verifier":"%s","fallbacks":%s}\n' \
    "$(_devflow_json_escape "$impl")" "$(_devflow_json_escape "$rev")" \
    "$(_devflow_json_escape "$lens")" "$(_devflow_json_escape "$ver")" "$fb_json" \
    > "$path" || { echo "devflow: preflight: could not write --write-effective '$path'" >&2; exit 1; }
}

cmd_preflight() {
  local roles_file="" host="" expect_host="" write_effective=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --roles-file)      _need_val preflight --roles-file "$#";      roles_file="$2";      shift 2 ;;
      --host)            _need_val preflight --host "$#";            host="$2";            shift 2 ;;
      --expect-host)     _need_val preflight --expect-host "$#";     expect_host="$2";      shift 2 ;;
      --write-effective) _need_val preflight --write-effective "$#"; write_effective="$2"; shift 2 ;;
      *) echo "devflow: preflight: unknown flag '$1'" >&2; exit 2 ;;
    esac
  done
  [ -n "$roles_file" ] && [ -f "$roles_file" ] || { echo "devflow: preflight: --roles-file <path> is required and must exist" >&2; exit 2; }
  case "$host" in
    claude|codex|gemini|cursor|opencode) ;;
    *) echo "devflow: preflight: --host must be one of claude|codex|gemini|cursor|opencode" >&2; exit 2 ;;
  esac
  [ -n "$expect_host" ] || expect_host="$host"

  local cfgc="$SELF_DIR/devflow-config.py" fields frc
  fields="$(python3 "$cfgc" fields "$roles_file" 2>&1)"; frc=$?
  # exit 6 from `fields` means the roles-file itself is well-formed but its profile shape is
  # invalid (bad version, unknown role, non-int max_passes, ...) — `fields` already printed
  # exactly the one `INVALID_PROFILE <reason>` line preflight reports verbatim.
  if [ "$frc" -eq 6 ]; then
    echo "$fields"
    exit 6
  fi
  if [ "$frc" -ne 0 ]; then
    echo "devflow: preflight: could not read --roles-file '$roles_file':" >&2
    printf '%s\n' "$fields" >&2
    exit 2
  fi

  local agent_implementer="" agent_reviewer="" reviewer_lens="" agent_verifier="" fallback="false" manifest_host="" k v
  while IFS='=' read -r k v; do
    case "$k" in
      roles.implementer.agent) agent_implementer="$v" ;;
      roles.reviewer.agent)    agent_reviewer="$v" ;;
      roles.reviewer.lens)     reviewer_lens="$v" ;;
      roles.verifier.agent)    agent_verifier="$v" ;;
      review.fallback_to_host) fallback="$v" ;;
      _manifest.host)          manifest_host="$v" ;;
    esac
  done <<EOF
$fields
EOF

  if [ -n "$manifest_host" ] && [ "$manifest_host" != "$expect_host" ]; then
    echo "HOST_MISMATCH manifest=$manifest_host host=$expect_host"
    exit 7
  fi

  # No associative arrays (bash 3.2 on stock macOS): three named roles, parallel positional lists.
  # role_effective starts as a copy of the requested bindings and is blanked to "" per role when
  # that role's binding falls back — this is what gets written to effective-roles.json.
  local -a role_names=(implementer reviewer verifier)
  local -a role_agents=("$agent_implementer" "$agent_reviewer" "$agent_verifier")
  local -a role_effective=("$agent_implementer" "$agent_reviewer" "$agent_verifier")
  local any_binding=0 blocked=0 idx role name fallback_list=""

  for idx in 0 1 2; do
    role="${role_names[$idx]}"; name="${role_agents[$idx]}"
    [ -n "$name" ] || continue
    any_binding=1
    if [ "$host" = "claude" ]; then
      local ok=0
      if [ -n "${DEVFLOW_AGENTS_DIR:-}" ]; then
        [ -f "$DEVFLOW_AGENTS_DIR/$name.md" ] && ok=1
      else
        [ -f "$HOME/.claude/agents/$name.md" ] && ok=1
        [ -f "$DEVFLOW_PROJECT_ROOT/.claude/agents/$name.md" ] && ok=1
      fi
      if [ "$ok" -ne 1 ]; then
        if [ "$fallback" = "true" ]; then
          echo "FALLBACK_TO_HOST $role=$name"
          role_effective[$idx]=""
          # R1: NOT `$(printf '%s\t%s\n' ...)` — command substitution strips the trailing
          # newline, so two fallbacks concatenated into one line and the reader below (which
          # splits on TAB) put a raw TAB inside a JSON string. Real TAB + real newline instead.
          fallback_list="${fallback_list}${role}"$'\t'"${name}"$'\n'
        else
          echo "MISSING_AGENT $role=$name"
          blocked=1
        fi
      fi
    else
      # Named-agent delegation itself isn't supported on this host yet — every non-empty
      # binding is affected, reported once per role when falling back.
      if [ "$fallback" = "true" ]; then
        echo "FALLBACK_TO_HOST $role=$name"
        role_effective[$idx]=""
        fallback_list="${fallback_list}${role}"$'\t'"${name}"$'\n'
      fi
    fi
  done

  if [ "$host" != "claude" ] && [ "$any_binding" = "1" ] && [ "$fallback" != "true" ]; then
    echo "NO_NAMED_AGENTS host=$host"
    exit 5
  fi
  [ "$blocked" = "1" ] && exit 4

  [ -z "$write_effective" ] || _devflow_write_effective_roles \
    "$write_effective" "${role_effective[0]}" "${role_effective[1]}" "$reviewer_lens" "${role_effective[2]}" "$fallback_list"
  exit 0
}

# ── profile-init (execution profiles: the one Step-1 call every skill makes) ────────────────
# Replaces the resolve/max-passes/fields/preflight block every skill used to copy-paste: this is
# the single place that classifies a resolved config into off/declared/active AND runs the
# preflight (agent resolution + HOST_MISMATCH) whenever that classification isn't `off` — closing
# A12 (a manifest with no bindings and max_passes=0 used to skip preflight entirely, so a
# manifest built for the wrong host was never caught) and R2 (a stale effective-roles.json from
# a profile that has since been turned off can no longer survive: `off` deletes it).
#
#   active   = any roles.*.agent is non-empty, OR review.max_passes > 0.
#   declared = a profile shape exists (`_manifest.host` non-empty, or a `roles` key present) but
#              nothing is bound and max_passes is 0.
#   off      = neither.
_devflow_profile_shape() {
  # Small, deliberately NOT routed through cmd_preflight: reading two leaf values (max_passes,
  # whether a `roles` key exists at all) is plain JSON introspection, not the agent-resolution
  # logic (per-role file checks, fallback, HOST_MISMATCH) that cmd_preflight owns and this
  # function must not duplicate. --roles-file here is always resolved-config.json (valid JSON,
  # produced by `devflow-config.py resolve`), and its SHAPE was already validated by the `fields`
  # call in cmd_profile_init before this ever runs.
  python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
rev = d.get("review")
mp = rev.get("max_passes", 0) if isinstance(rev, dict) else 0
print(mp)
print("1" if isinstance(d.get("roles"), dict) else "0")
' "$1"
}

cmd_profile_init() {
  local roles_file="" host="" expect_host=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --roles-file)  _need_val profile-init --roles-file "$#";  roles_file="$2";  shift 2 ;;
      --host)        _need_val profile-init --host "$#";        host="$2";        shift 2 ;;
      --expect-host) _need_val profile-init --expect-host "$#"; expect_host="$2"; shift 2 ;;
      *) echo "devflow: profile-init: unknown flag '$1'" >&2; exit 2 ;;
    esac
  done
  [ -n "$roles_file" ] && [ -f "$roles_file" ] || { echo "devflow: profile-init: --roles-file <path> is required and must exist" >&2; exit 2; }
  case "$host" in
    claude|codex|gemini|cursor|opencode) ;;
    *) echo "devflow: profile-init: --host must be one of claude|codex|gemini|cursor|opencode" >&2; exit 2 ;;
  esac

  # `fields` runs validate_profile (config.py) — an invalid profile shape is reported here,
  # before any state classification or agent-resolution work happens.
  local cfgc="$SELF_DIR/devflow-config.py" fields frc
  fields="$(python3 "$cfgc" fields "$roles_file" 2>&1)"; frc=$?
  if [ "$frc" -eq 6 ]; then echo "$fields"; exit 6; fi
  if [ "$frc" -ne 0 ]; then
    echo "devflow: profile-init: could not read --roles-file '$roles_file':" >&2
    printf '%s\n' "$fields" >&2
    exit 2
  fi

  local agent_implementer="" agent_reviewer="" agent_verifier="" manifest_host="" k v
  while IFS='=' read -r k v; do
    case "$k" in
      roles.implementer.agent) agent_implementer="$v" ;;
      roles.reviewer.agent)    agent_reviewer="$v" ;;
      roles.verifier.agent)    agent_verifier="$v" ;;
      _manifest.host)          manifest_host="$v" ;;
    esac
  done <<EOF
$fields
EOF

  local shape shape_rc max_passes has_roles
  shape="$(_devflow_profile_shape "$roles_file" 2>&1)"; shape_rc=$?
  if [ "$shape_rc" -ne 0 ]; then
    echo "devflow: profile-init: could not read --roles-file '$roles_file' as JSON:" >&2
    printf '%s\n' "$shape" >&2
    exit 2
  fi
  max_passes="$(printf '%s\n' "$shape" | sed -n '1p')"
  has_roles="$(printf '%s\n' "$shape" | sed -n '2p')"

  local any_binding=0
  [ -n "$agent_implementer$agent_reviewer$agent_verifier" ] && any_binding=1

  local state
  if [ "$any_binding" = "1" ] || [ "${max_passes:-0}" -gt 0 ]; then
    state="active"
  elif [ -n "$manifest_host" ] || [ "$has_roles" = "1" ]; then
    state="declared"
  else
    state="off"
  fi

  # effective-roles.json describes THIS resolved config: stale content from an earlier call (or
  # an earlier, since-turned-off profile) must never survive under a new verdict.
  rm -f "$RUN_DIR/effective-roles.json"

  if [ "$state" != "off" ]; then
    local -a pf_args=(--roles-file "$roles_file" --host "$host" --write-effective "$RUN_DIR/effective-roles.json")
    [ -n "$expect_host" ] && pf_args+=(--expect-host "$expect_host")
    # Run in a subshell (via command substitution): cmd_preflight ends every path with `exit`,
    # and calling it directly here would terminate this whole script instead of just reporting
    # back to the caller.
    local pf_out pf_rc
    pf_out="$(cmd_preflight "${pf_args[@]}")"; pf_rc=$?
    [ -n "$pf_out" ] && printf '%s\n' "$pf_out"
    case "$pf_rc" in
      0) ;;
      4|5|6|7) exit "$pf_rc" ;;
      *) exit 2 ;;
    esac
  fi

  printf '%s\n' "$state" > "$RUN_DIR/profile-active"
  printf '%s\n' "${max_passes:-0}" > "$RUN_DIR/max-passes"
  echo "profile=$state max_passes=${max_passes:-0}"
  exit 0
}

# ── deliverable-id (execution profiles: the one place a deliverable id is computed) ─────────
# Closes R3 (a standalone review's own Bash block computed `review-<baseline>` with $BASELINE
# unset, because BASELINE only existed in a DIFFERENT step's scope) and A3's stale-impl-base
# half, by making id computation a single call whose result is persisted to $RUN_DIR/deliverable
# instead of recomputed inline by each phase.
cmd_deliverable_id() {
  local phase="" plan_path="" baseline=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --phase)     _need_val deliverable-id --phase "$#";     phase="$2";     shift 2 ;;
      --plan-path) _need_val deliverable-id --plan-path "$#"; plan_path="$2"; shift 2 ;;
      --baseline)  _need_val deliverable-id --baseline "$#";  baseline="$2";  shift 2 ;;
      *) echo "devflow: deliverable-id: unknown flag '$1'" >&2; exit 2 ;;
    esac
  done
  case "$phase" in
    plan|impl|review) ;;
    *) echo "devflow: deliverable-id: --phase must be one of plan|impl|review" >&2; exit 2 ;;
  esac

  local new_id
  case "$phase" in
    plan)
      [ -n "$plan_path" ] || { echo "devflow: deliverable-id: --plan-path is required for --phase plan" >&2; exit 2; }
      local sha
      sha="$(printf '%s' "$plan_path" | _devflow_strong_hash)" \
        || { echo "devflow: deliverable-id: no shasum/sha256sum available" >&2; exit 1; }
      new_id="plan-$sha"
      ;;
    impl)
      [ -s "$RUN_DIR/impl-base" ] || { echo "NO_IMPL_BASE"; exit 2; }
      new_id="impl-$(cat "$RUN_DIR/impl-base")"
      ;;
    review)
      # devflow-run owns `pipeline` (written at its own Step 1, removed at its final step): its
      # presence alongside impl-base means THIS review is part of a run that already has an
      # implementation deliverable to review, so review inherits impl's id rather than minting
      # its own — a standalone review (no pipeline) always needs an explicit --baseline instead.
      if [ -s "$RUN_DIR/impl-base" ] && [ -f "$RUN_DIR/pipeline" ]; then
        new_id="impl-$(cat "$RUN_DIR/impl-base")"
      else
        [ -n "$baseline" ] || { echo "NO_BASELINE"; exit 2; }
        _devflow_passes_validate_id "--baseline" "$baseline"
        new_id="review-$baseline"
      fi
      ;;
  esac

  # Idempotent: re-running the SAME phase with the SAME inputs just re-writes the same id. A
  # DIFFERENT id recorded for the SAME phase is loud and refused (never a silent second budget
  # against a deliverable the caller thinks is still the first one); a different PHASE computing
  # its own (naturally different) id is expected and simply overwrites — deliverable-phase is
  # what lets this tell the two cases apart.
  local df="$RUN_DIR/deliverable" pf="$RUN_DIR/deliverable-phase"
  if [ -s "$df" ]; then
    local old_id old_phase
    old_id="$(cat "$df")"
    old_phase="$(cat "$pf" 2>/dev/null)"
    if [ "$old_id" != "$new_id" ] && [ "$old_phase" = "$phase" ]; then
      echo "DELIVERABLE_CHANGED old=$old_id new=$new_id"
      exit 8
    fi
  fi
  printf '%s\n' "$new_id" > "$df"
  printf '%s\n' "$phase" > "$pf"
  printf '%s\n' "$new_id"
  exit 0
}

# ── result-write (execution profiles: atomic result.yaml writes for all four skills) ────────
# Closes A6: every Finalize block writes its result block through this one mechanism —
# tmp-then-mv — instead of each skill redirecting straight into result.yaml and risking a
# truncated file if the write is interrupted partway.
cmd_result_write() {
  local path=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --path) _need_val result-write --path "$#"; path="$2"; shift 2 ;;
      *) echo "devflow: result-write: unknown flag '$1'" >&2; exit 2 ;;
    esac
  done
  [ -n "$path" ] || { echo "devflow: result-write: --path is required" >&2; exit 2; }
  local tmp="${path}.tmp.$$"
  if ! cat > "$tmp"; then
    echo "devflow: result-write: could not write '$tmp'" >&2
    rm -f "$tmp"
    exit 1
  fi
  if ! mv "$tmp" "$path"; then
    echo "devflow: result-write: could not move '$tmp' to '$path'" >&2
    rm -f "$tmp"
    exit 1
  fi
  exit 0
}

# Inputs: CODEX_EXIT, EVENTS, OUT, STDERR, BACKEND, CALL_RESULT, EXTRACTOR_FAILED.
# Returns 0 if the call is usable; non-zero (escalate) otherwise.
#
# There is deliberately no classification of WHY the backend failed. Guessing a cause from
# substrings in the CLI's stderr and its event stream meant the reviewer's own words — text
# derived from the repo under review — could steer devflow's diagnosis, and a python traceback
# read as an auth failure. The stderr tail says more than a label, and the caller escalates
# either way.
devflow_after_call() {
  if [ "${CODEX_EXIT:-1}" -eq 0 ] && [ -n "${CALL_RESULT:-}" ]; then return 0; fi

  # The one cause devflow knows positively rather than by inference.
  if [ "${EXTRACTOR_FAILED:-0}" = "1" ]; then
    echo "devflow: the verdict extractor could not run -> escalating. This is a devflow/python failure, not a reviewer verdict; retry the call." >&2
    return 1
  fi

  echo "devflow: the external call did not produce a usable verdict (exit ${CODEX_EXIT:-?}) -> escalating." >&2
  if [ -s "$STDERR" ]; then
    echo "devflow: last lines of $BACKEND stderr ($STDERR):" >&2
    tail -5 "$STDERR" >&2
  elif { [ "$BACKEND" = codex ] && [ ! -s "$EVENTS" ]; } || { [ "$BACKEND" != codex ] && [ ! -s "$OUT" ]; }; then
    # $EVENTS is only written on the codex path (claude's stdout goes to $OUT), so the
    # "wrote nothing at all" check has to look at whichever file this backend actually uses.
    echo "devflow: $BACKEND produced no output and no stderr — check its login/credentials and, for codex, codex.command_path." >&2
  fi
  return 1
}

cmd_run_external() {
  PHASE=""; local PROMPT_FILE=""; RESUME_ID=""; local ROLE="reviewer"; local FRESHNESS="false"; local FRESHNESS_FILE=""
  BACKEND=""; MODEL=""; EFFORT=""; SESSION_REUSE="true"
  while [ $# -gt 0 ]; do
    case "$1" in
      --phase)            _need_val run-external --phase "$#";        PHASE="$2"; shift 2 ;;
      --prompt-file)      _need_val run-external --prompt-file "$#";  PROMPT_FILE="$2"; shift 2 ;;
      --backend)          _need_val run-external --backend "$#";      BACKEND="$2"; shift 2 ;;
      --model)            _need_val run-external --model "$#";        MODEL="$2"; shift 2 ;;
      --effort)           _need_val run-external --effort "$#";       EFFORT="$2"; shift 2 ;;
      # An EMPTY value is legal and means "fresh session" (both backends branch on [ -n ] before
      # passing anything to the CLI), so callers pass it UNCONDITIONALLY — never spliced in with a
      # shell conditional. See "Always pass --resume unconditionally" in cross-tool-runner.md.
      --resume)           _need_val run-external --resume "$#";       RESUME_ID="$2"; shift 2 ;;
      --role)             _need_val run-external --role "$#";         ROLE="$2"; shift 2 ;;
      --no-session-reuse) SESSION_REUSE="false"; shift ;;
      # Take the freshness snapshot and promote it only if this call produced a real review.
      --freshness)        FRESHNESS="true"; shift ;;
      # Snapshot this one file instead of the worktree (the plan phase reviews a single file).
      --freshness-file)   _need_val run-external --freshness-file "$#"; FRESHNESS="true"; FRESHNESS_FILE="$2"; shift 2 ;;
      *) echo "devflow: run-external: unknown flag '$1'" >&2; exit 2 ;;
    esac
  done
  [ -n "$PHASE" ] || { echo "devflow: run-external: --phase is required" >&2; exit 2; }
  # --phase is spliced into artifact paths ($RUN_DIR/$PHASE-*.txt); --effort into a codex `-c`
  # TOML string. Restrict both to a safe token charset so neither can escape the path/string.
  case "$PHASE" in *[!A-Za-z0-9._-]*|.|..) echo "devflow: run-external: --phase must match [A-Za-z0-9._-]+ and not be '.' or '..'" >&2; exit 2 ;; esac
  [ -n "$PROMPT_FILE" ] && [ -f "$PROMPT_FILE" ] || { echo "devflow: run-external: --prompt-file <path> is required and must exist" >&2; exit 2; }
  case "$BACKEND" in codex|claude) ;; *) echo "devflow: run-external: --backend must be 'codex' or 'claude'" >&2; exit 2 ;; esac
  [ -n "$MODEL" ]  || { echo "devflow: run-external: --model is required"  >&2; exit 2; }
  [ -n "$EFFORT" ] || { echo "devflow: run-external: --effort is required" >&2; exit 2; }
  case "$EFFORT" in *[!A-Za-z0-9._-]*) echo "devflow: run-external: --effort must match [A-Za-z0-9._-]+" >&2; exit 2 ;; esac
  case "$ROLE" in reviewer|implementer) ;; *) echo "devflow: run-external: --role must be 'reviewer' or 'implementer'" >&2; exit 2 ;; esac
  # A write-mode call may edit the very tree it snapshots, so letting it promote a .tree would
  # let a call certify its own output as reviewed. Keep the gate on reviewer calls only.
  [ "$FRESHNESS" != "true" ] || [ "$ROLE" = "reviewer" ] \
    || { echo "devflow: run-external: --freshness is reviewer-only" >&2; exit 2; }
  PROMPT="$(cat "$PROMPT_FILE")"
  DEVFLOW_ROLE="$ROLE"   # devflow_run_external reads this to pick codex's sandbox mode

  # Resolve the execution binary from the TRUSTED config only (never a flag, never the
  # project file); claude always resolves via PATH.
  local BIN=""
  if [ "$BACKEND" = "codex" ]; then
    devflow_resolve_codex_bin      # sets CODEX_BIN
    BIN="$CODEX_BIN"
  else
    BIN="$(command -v claude)"
    [ -n "$BIN" ] || { echo "devflow: FATAL — claude CLI not found on PATH." >&2; exit 1; }
  fi

  # R3: claim the active-run lease for `dir --fresh` (see cmd_dir) right before the actual
  # long-running work starts — not on the flag-validation exits above, which never ran anything
  # a wipe could clobber. $$ is THIS script process, which stays alive for the whole poll loop
  # below, so its liveness is exactly what `dir --fresh` needs to check. Removed on this
  # function's one exit path (the `return` at the very end) — no trap, matching the rest of the
  # script's "hygiene, not a security boundary" posture: a killed process leaves a stale lease
  # that `dir --fresh` itself detects and discards via `kill -0`.
  : > "$RUN_DIR/.active-$$" 2>/dev/null

  # CALL_RESULT/SESSION_ID are only ever assigned past the poll loop in devflow_run_external
  # — its hard-cap timeout path `return`s before reaching that point. Initialize both so the
  # report below never crashes on exactly the failure path that most needs a clean report.
  CALL_RESULT=""; SESSION_ID=""

  # Snapshot BEFORE the call, promote AFTER it, and only on success. An unconditional write
  # would make the invariant vacuous: a call killed at the hard cap would leave a .tree matching
  # the current tree, so a later freshness check would "pass" on code no reviewer read.
  if [ "$FRESHNESS" = "true" ]; then
    [ -z "$FRESHNESS_FILE" ] || [ -f "$FRESHNESS_FILE" ] \
      || { echo "devflow: run-external: --freshness-file '$FRESHNESS_FILE' does not exist" >&2; exit 2; }
    # A snapshot that could not be taken is not evidence: promoting it later would give
    # freshness-check a `no-tree` reason for a call that did happen — the right refusal reported
    # as the wrong fact. devflow_snapshot_digest fails rather than hash an empty snapshot.
    devflow_snapshot_digest "$FRESHNESS_FILE" > "$RUN_DIR/$PHASE.tree.pending" || {
      rm -f "$RUN_DIR/$PHASE.tree.pending"
      echo "devflow: run-external: could not snapshot the review target — refusing a call whose review could never be gated." >&2; exit 1; }
  fi

  devflow_run_external "$BIN"
  devflow_after_call
  local after_exit=$?

  # Write the verdict BEFORE promoting the snapshot. The pair means "this verdict is about this
  # tree", and only one order fails safely: if anything dies between the two writes, a stale
  # .tree beside a fresh verdict merely forces another review, while a fresh .tree beside the
  # PREVIOUS round's verdict text reads as an approval of code this round rejected.
  # A FAILED write is the same hazard as the wrong order: the old verdict text survives, and
  # promoting on top of it produces a fresh .tree beside the PREVIOUS round's APPROVED. Ordering
  # alone does not cover it, so the write is checked.
  local verdict_written=1
  printf '%s\n' "$CALL_RESULT" > "$RUN_DIR/$PHASE-verdict.txt" \
    || { echo "devflow: could not write the verdict -> treating this call as unusable." >&2; after_exit=1; verdict_written=0; }

  if [ "$FRESHNESS" = "true" ]; then
    # devflow_after_call returns 0 only when the CLI exited 0 AND a verdict was extracted, so
    # this is the authoritative "the call is usable" answer — no stdout marker to parse.
    if [ "$after_exit" -eq 0 ]; then
      # A failed `mv` means this round produced no reviewed tree, and the pending file it left
      # behind is the failure path's to clean up.
      if ! mv "$RUN_DIR/$PHASE.tree.pending" "$RUN_DIR/$PHASE.tree"; then
        echo "devflow: could not promote the freshness snapshot -> treating this call as unusable." >&2
        rm -f "$RUN_DIR/$PHASE.tree.pending"
        after_exit=1
      fi
    else
      rm -f "$RUN_DIR/$PHASE.tree.pending"
    fi
  fi

  echo "RUN_DIR=$RUN_DIR"
  echo "PHASE=$PHASE"
  echo "EXIT=$CODEX_EXIT"
  # Blank on a failed write, exactly as TREE_FILE is on a failed promotion: that file then
  # holds the PREVIOUS round's text, and every skill tells the orchestrator to read the verdict AT
  # this path — handing it a path to stale text beside EXIT=0 is a report contradicting itself.
  if [ "$verdict_written" -eq 1 ]; then echo "VERDICT_FILE=$RUN_DIR/$PHASE-verdict.txt"
  else echo "VERDICT_FILE="; fi
  # No machine verdict parse. The orchestrator is an LLM that reads VERDICT_FILE and judges
  # approval itself — a bash token classifier would just be a second, more brittle decision on
  # the same text (it once misread "no blocking issues found. APPROVED" as ambiguous). EXIT
  # above is the only mechanical signal (did the CLI complete, or hit the hard cap); the verdict
  # text is data for the caller to read.
  echo "SESSION_ID=${SESSION_ID:-}"
  echo "SESSION_FILE=${SESSION_FILE:-}"
  if [ "$FRESHNESS" = "true" ]; then
    if [ "$after_exit" -eq 0 ]; then echo "TREE_FILE=$RUN_DIR/$PHASE.tree"
    else echo "TREE_FILE="; fi
  fi
  rm -f "$RUN_DIR/.active-$$"   # R3: release the active-run lease — this is the one exit path
  return "$after_exit"
}

# ── dispatcher ───────────────────────────────────────────────────────────────
main() {
  local cmd="${1:-}"; shift || true
  case "$cmd" in
    dir)              cmd_dir "$@" ;;
    run-external)     cmd_run_external "$@" ;;
    freshness-check)  cmd_freshness_check "$@" ;;
    scope-digest)     cmd_scope_digest "$@" ;;
    passes)           cmd_passes "$@" ;;
    preflight)        cmd_preflight "$@" ;;
    profile-init)     cmd_profile_init "$@" ;;
    deliverable-id)   cmd_deliverable_id "$@" ;;
    result-write)     cmd_result_write "$@" ;;
    *)
      {
        echo "usage: $(basename "$0") dir [--fresh] [--force] (--fresh exit 9 RUN_ACTIVE pid=<n> while a run is live; --force overrides)"
        echo "       $(basename "$0") run-external --backend <codex|claude> --model <m> --effort <e> --phase <p> --prompt-file <f> [--role reviewer|implementer] [--resume <id>] [--no-session-reuse] [--freshness | --freshness-file <path>]"
        echo "       $(basename "$0") freshness-check --phase <p> [--file <path>] | scope-digest [--base <sha>]"
        echo "       $(basename "$0") passes init --deliverable <id> --max <n> | passes reserve --deliverable <id> --call-id <cid> (exit 2 BUDGET_NOT_INITIALIZED, 3 BUDGET_EXHAUSTED, 9 CALL_ALREADY_CLOSED) | passes close --deliverable <id> --call-id <cid> | passes status --deliverable <id> | passes complete --deliverable <id> --scope <digest> --verdict <clean|blockers>"
        echo "       $(basename "$0") preflight --roles-file <path> --host <claude|codex|gemini|cursor|opencode> [--expect-host <h>] [--write-effective <path>] (exit 4 MISSING_AGENT, 5 NO_NAMED_AGENTS, 6 INVALID_PROFILE, 7 HOST_MISMATCH)"
        echo "       $(basename "$0") profile-init --roles-file <path> --host <claude|codex|gemini|cursor|opencode> [--expect-host <h>] (writes profile-active/max-passes/effective-roles.json; same exit codes as preflight, plus 2 for a bad --roles-file)"
        echo "       $(basename "$0") deliverable-id --phase <plan|impl|review> [--plan-path <p>] [--baseline <sha>] (exit 2 NO_IMPL_BASE/NO_BASELINE, 8 DELIVERABLE_CHANGED old=<x> new=<y>)"
        echo "       $(basename "$0") result-write --path <p> (reads the result body on stdin; writes it atomically; exit 0/1)"
      } >&2
      exit 2 ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
  exit $?
fi
