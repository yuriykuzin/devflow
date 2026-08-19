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
# `--fresh` is an UNCONDITIONAL wipe: nothing checks whether a call is still in flight. Run it
# while a `run-external` is running in the same checkout and that call's session/output files
# are deleted under it, silently. Devflow used to hold a PID lease to refuse exactly this; the
# lease was removed as over-engineering for a single-user tool, so the rule is now a convention,
# not an enforced guarantee: one pipeline per checkout at a time, parallel work in git
# worktrees (a worktree has its own repo root, so its own RUN_DIR hash).
cmd_dir() {
  local fresh=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --fresh) fresh=1; shift ;;
      *) echo "devflow: dir: unknown flag '$1'" >&2; exit 2 ;;
    esac
  done
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
devflow_snapshot_source() {
  if [ -n "${1:-}" ]; then cat -- "$1"; else devflow_tree_snapshot; fi
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
  devflow_snapshot_source "${1:-}" > "$snap" 2>"$snaperr"
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
( TOP="$(git rev-parse --show-toplevel)" || exit 1
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
    DIFF_BASE="$HEAD_OID"
  else
    printf '@unborn HEAD\n'
    # Asked for, not hardcoded: the empty-tree oid differs under objectFormat=sha256, and the
    # absence of -w is what keeps this read-only (it computes an oid, it writes no object).
    DIFF_BASE="$(git hash-object -t tree /dev/null)" || exit 1
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
      # An EMPTY value is legal and means "fresh session" (both backends branch on [ -n ] before
      # passing anything to the CLI), so callers pass it UNCONDITIONALLY — never spliced in with a
      # shell conditional. See "Always pass --resume unconditionally" in cross-tool-runner.md.
      --resume)           _need_val --resume "$#";       RESUME_ID="$2"; shift 2 ;;
      --role)             _need_val --role "$#";         ROLE="$2"; shift 2 ;;
      --no-session-reuse) SESSION_REUSE="false"; shift ;;
      # Take the freshness snapshot and promote it only if this call produced a real review.
      --freshness)        FRESHNESS="true"; shift ;;
      # Snapshot this one file instead of the worktree (the plan phase reviews a single file).
      --freshness-file)   _need_val --freshness-file "$#"; FRESHNESS="true"; FRESHNESS_FILE="$2"; shift 2 ;;
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
  return "$after_exit"
}

# ── dispatcher ───────────────────────────────────────────────────────────────
main() {
  local cmd="${1:-}"; shift || true
  case "$cmd" in
    dir)              cmd_dir "$@" ;;
    run-external)     cmd_run_external "$@" ;;
    freshness-check)  cmd_freshness_check "$@" ;;
    *) echo "usage: $(basename "$0") dir [--fresh] | run-external --backend <codex|claude> --model <m> --effort <e> --phase <p> --prompt-file <f> [--role reviewer|implementer] [--resume <id>] [--no-session-reuse] [--freshness | --freshness-file <path>] | freshness-check --phase <p> [--file <path>]" >&2; exit 2 ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
  exit $?
fi
