# Cross-Tool Runner

Canonical procedure for external-CLI calls (review, resume, implementer handoff).
Referenced by `devflow:plan`, `devflow:implement`, `devflow:review`, and `devflow:run`.

**Why this file is short:** the mechanics (config caching, binary resolution, async
launch, polling, kill escalation, scope pinning, rate-limit fallback) live in a real
script, `scripts/devflow-runner.sh`, not in markdown. Claude Code resets shell env and
functions between every Bash tool call — only cwd and the filesystem persist — so
transcribing bash out of a markdown file into Bash calls silently drops pieces (the
rate-limit/auth fallback, mandatory session capture) on every phase transition. A script
file you `bash` as a subprocess has no such problem: it recomputes its own state from
disk on every invocation. This file now only covers what an agent must decide (locate
the script, which subcommand, what prompt) — not how the subcommand works internally.

> **Rule:** EVERY external call in any devflow skill — fresh review, resume re-review,
> and implementer handoff/fix — MUST go through `bash "$RUNNER" run-external`. Do not
> hand-roll a one-off `codex exec` / `claude -p` invocation.

## Locate the runner

`$RUNNER` is `scripts/devflow-runner.sh` inside the devflow plugin root (the directory
containing `config.default.yaml` and `skills/`). Resolve it once per skill invocation:

```bash
# AGENT: on Claude Code, "Base directory for this skill" (shown in this skill's
# invocation preamble) is <plugin-root>/skills/<skill-name> — two directories up is the
# plugin root; prefer that when available. On other hosts, fall back to a filesystem
# search under the actual install locations: ~/.claude/plugins (Claude Code marketplace +
# plugin cache — both are full-tree rsync targets that include scripts/) and
# ~/.codex/devflow (the codex deploy target). Codex's own ~/.agents/skills/devflow is
# usually a symlink to just the plugin's skills/ dir — a `find` rooted there can never
# reach a sibling scripts/, so it's resolved separately below (readlink to the real
# skills/ dir, then check its sibling scripts/devflow-runner.sh directly) instead of
# being added as a search root.
if [ -z "${RUNNER:-}" ]; then
  _found="$(find ~/.claude/plugins ~/.codex/devflow -path '*/scripts/devflow-runner.sh' 2>/dev/null | head -1)"
  if [ -z "$_found" ] && [ -e ~/.agents/skills/devflow ]; then
    _real="$(cd ~/.agents/skills/devflow 2>/dev/null && pwd -P)"
    [ -n "$_real" ] && [ -f "$_real/../scripts/devflow-runner.sh" ] && _found="$_real/../scripts/devflow-runner.sh"
  fi
  if [ -z "$_found" ]; then
    echo "devflow: FATAL — could not locate scripts/devflow-runner.sh under ~/.claude/plugins, ~/.codex/devflow, or ~/.agents/skills/devflow." >&2
    echo "  If this skill's invocation preamble showed a 'Base directory for this skill' path (<plugin-root>/skills/<skill-name>), use <that path>/../../scripts/devflow-runner.sh directly." >&2
    exit 1
  fi
  RUNNER="$_found"
fi
```

In practice, just always invoke it as `bash "$RUNNER" <subcommand> ...` — the script
does not need to be executable itself (`install.sh` never `chmod`s it; a plain `bash`
invocation is enough). Re-run this locator snippet at the start of every skill's Step 1
(inline it — don't assume `$RUNNER` survives from an earlier Bash call, since only cwd
and the filesystem do).

## RUN_DIR is deterministic

Every subcommand derives `RUN_DIR` the same way — a hash of `git rev-parse
--show-toplevel`, rooted under `${TMPDIR:-/tmp}` rather than inside the repo tree (a
tracked, clone-delivered `run.env` at a predictable in-repo path would be a same-day
RCE — see "Security" below). It never depends on an exported env var or a `mktemp`
pointer file, so any subcommand call reconstructs it identically with no shared state.

Unlike the old in-repo `<project-root>/.devflow/run` path, this is a hash, not something
you can hand-recompute correctly in a one-liner (matching the script's exact hash-tool
fallback chain byte-for-byte is a maintenance trap waiting to drift). When *you* — the
agent — need `$RUN_DIR` in a fresh Bash call, get it from `bootstrap`'s own stdout
instead of recomputing it:

```bash
BOOT="$(bash "$RUNNER" bootstrap)"
RUN_DIR="$(printf '%s\n' "$BOOT" | sed -n 's/^RUN_DIR=//p')"
```

`bootstrap` is idempotent and cheap when reused (`REUSED=1`, no YAML re-read), so calling
it again purely to recover `$RUN_DIR` in a later Bash call costs nothing beyond one
subprocess launch.

## Subcommands

### `bootstrap [--fresh]`

Resolves config + personas + backend binary once per (project, plugin) pair and freezes
them into `$RUN_DIR/run.env`. Safe to call at the start of every phase — it reuses the
existing `run.env` when the project/plugin/config fingerprint are unchanged, and only
re-reads YAML when something changed. `--fresh` forces a rebuild (deletes the run
directory first).

```bash
bash "$RUNNER" bootstrap
# stdout: RUN_DIR=<path>
#         REUSED=0|1
```

Values frozen into `run.env` (loaded automatically by every later subcommand call — you
do not need to `source` it yourself for the *script* to see them): `BACKEND`,
`REVIEWER_MODEL`, `REVIEWER_EFFORT`, `IMPLEMENTER_MODEL`, `IMPLEMENTER_EFFORT`,
`SESSION_REUSE`, `FALLBACK_COMMAND`, `CODEX_BIN`, `CLAUDE_BIN`, `PERSONAS_REF`,
`DEVFLOW_PLAN_PATH`, `PLAN_SESSION_FILE`, `DEVFLOW_PLUGIN_DIR`, `DEVFLOW_PROJECT_ROOT`,
`DEVFLOW_CFG_FINGERPRINT`. If *you* (the agent) need one of these values in your own
shell — e.g. `DEVFLOW_PLAN_PATH` — sourcing the file for read access within a single Bash
call is safe (it's plain `KEY=VALUE` assignments); it just never needs to *survive* to
the next call:

```bash
set -a; . "$RUN_DIR/run.env"; set +a
echo "$DEVFLOW_PLAN_PATH"
```

If `bootstrap` fails (no codex binary supports `exec --json`, no `claude` on PATH, or
PyYAML unavailable), it prints a `devflow: FATAL —` line explaining the fix and exits
non-zero. Surface that message to the user; do not silently retry.

**Standalone invocations and `--fresh`:** `RUN_DIR` is keyed only on the project root, so
if you invoke a devflow skill standalone (not via `devflow:run`) weeks after a previous
run in the same checkout, `bootstrap` may reuse a `run.env` whose session files
(`plan-review.session`, `final-review.session`, ...) point at long-expired external-tool
sessions. The config-fingerprint check catches *config* drift, not *time* drift. If a
`--resume` call fails because the session id is gone/expired, or you know you're starting
an unrelated review in an old checkout, pass `bootstrap --fresh` to force a clean
`RUN_DIR` rather than debugging a stale-session error.

### `scope <mode> [flags]`

Builds the SCOPE block for the requested changeset and prints it to stdout — prepend it
verbatim to the review/plan prompt you write to `--prompt-file`.

| Mode | Flags | Notes |
|------|-------|-------|
| `uncommitted` | — | `git diff HEAD` |
| `staged` | — | `git diff --cached` |
| `last-commit` | — | needs a parent commit |
| `implementation` | `--impl-base <sha>` | diff since the pre-implementation commit |
| `branch` | `--base <ref>` (optional) | PR base → origin/HEAD → main/master, in that order |
| `pr` | `--pr <number>` | via `gh pr diff` |
| `files` | `-- <path> [<path> ...]` | explicit file list |
| `plan` | `--plan-path <path>` (or `$DEVFLOW_PLAN_PATH`) | read-only, reviews the plan file itself |

```bash
bash "$RUNNER" scope uncommitted
bash "$RUNNER" scope implementation --impl-base "$DEVFLOW_IMPL_BASE"
bash "$RUNNER" scope branch --base origin/main
bash "$RUNNER" scope files -- src/foo.py src/bar.py
```

A mode that can't resolve its base (no origin remote, invalid `--impl-base`, no `HEAD^`,
no common ancestor) fails loudly with a non-zero exit and an explanatory stderr line —
never emits an empty scope. Treat a non-zero exit here as a hard stop, not something to
paper over with a wider or empty scope.

### `run-external --phase <name> --prompt-file <path> [flags]`

Launches the external call (non-blocking internally — the script polls its own child
with backoff and a hard cap; it returns only when the call is done, killed, or timed
out), extracts the verdict text and session id, and prints a small `KEY=VALUE` report.

| Flag | Required | Meaning |
|------|----------|---------|
| `--phase <name>` | yes | `plan-review` \| `impl-review` \| `final-review` \| etc. — namespaces the output files under `$RUN_DIR` |
| `--prompt-file <path>` | yes | the full prompt (SCOPE block + review instructions), written to a file first — never pass it inline, shell-quoting a multi-KB prompt is a footgun |
| `--role reviewer\|implementer` | no (default `reviewer`) | picks `REVIEWER_*` vs `IMPLEMENTER_*` model/effort from `run.env` |
| `--resume <session-id>` | no | resume that session instead of starting fresh |
| `--permission-mode <mode>` | no (default `plan`) | `plan` for review, `default` for implementer handoff (claude backend only) |
| `--no-session-reuse` | no | ephemeral call — no session persisted |

```bash
printf '%s\n' "$SCOPE_BLOCK" "$REVIEW_INSTRUCTIONS" > "$RUN_DIR/prompt.txt"
bash "$RUNNER" run-external --phase plan-review --prompt-file "$RUN_DIR/prompt.txt"
# stdout:
#   RUN_DIR=<path>
#   PHASE=plan-review
#   EXIT=<codex/claude process exit code, or 124 on a hard-cap/lingering kill>
#   VERDICT_FILE=<path to the full verdict text>
#   VERDICT_STATUS=APPROVED|ISSUES|CHANGES_REQUESTED|UNKNOWN
#   SESSION_ID=<id, or empty>
#   SESSION_FILE=<path — read this to resume next iteration>
```

`VERDICT_STATUS=UNKNOWN` means none of the three known tokens appeared anywhere in the
verdict text (the external tool didn't follow the requested response format) — **do not
treat UNKNOWN as a silent pass or fail**. Read `VERDICT_FILE` yourself and decide from the
actual text before proceeding.

`run-external` folds in the old rate-limit/auth fallback automatically: a transient rate
limit retries once via `fallback_command` (new session id); an auth/capability failure
(bad login, missing `--json`, empty event stream) escalates immediately without burning
a retry. Either way, `run-external` exits non-zero and prints a `devflow:` stderr line
explaining which branch fired — read stderr, not just the exit code, before deciding how
to escalate to the user.

**Session capture is automatic and mandatory** — `SESSION_FILE` is written on every call,
including calls that turn out to be the last one in a phase. Read it with
`cat "$SESSION_FILE"` and pass its content as `--resume` on the next iteration; this is
what keeps the fix → re-review loop cheap (~20k tokens saved per resumed call) instead of
degrading to a fresh, context-less review.

## Security

`RUN_DIR` lives under `${TMPDIR:-/tmp}`, not inside the repo — a hostile clone must never
be able to *deliver* a tracked `run.env`/`config.env` into a path the script later
sources. Every subcommand additionally refuses to source `run.env` (and refuses to trust
an already-loaded one, via `devflow_require_valid_env` in `scope`/`run-external`) unless
it's owned by the current user, not group/other-writable, and not a symlink. `RUN_DIR`
itself is created with mode 0700 and an ownership check before anything touches it,
closing the predictable-shared-`/tmp`-path pre-planting attack.

`codex.command_path` and `codex.fallback_command` — the two config keys that name an
executable to run — are resolved **only** from the plugin default and
`~/.devflow/config.yaml`, never from a project-level `.devflow.yaml`. A committed project
config choosing `backend`/models/`session_reuse` is fine; a committed project config
choosing *which binary gets executed* is not — that's a clone shipping its own payload
and pointing devflow at it.

## Async execution — how to launch `run-external`

The script's own poll loop already respects `DEVFLOW_POLL_SCHEDULE`/an ~8-10min hard cap
internally; you never need an outer poll loop of your own. What you choose is only *how
you launch the one call*:

- **Claude Code**: launch with the Bash tool's `run_in_background: true`. You get a
  single completion notification when it's done; read the output at that point. Do not
  poll with repeated foreground Bash calls — cwd persists between them but each call
  still pays tool-call overhead for nothing, since the script's internal poll loop is
  already doing the waiting.
- **Other hosts (Windsurf/Gemini/Cursor/Codex-as-host)**: a plain foreground/blocking
  call to `bash "$RUNNER" run-external ...` is fine — the script backgrounds its own
  `codex`/`claude` child internally regardless of how it itself was launched; only the
  *host's* invocation of the script needs to not impose its own short timeout on top.

## Putting it together (per phase)

```bash
BOOT="$(bash "$RUNNER" bootstrap)"
RUN_DIR="$(printf '%s\n' "$BOOT" | sed -n 's/^RUN_DIR=//p')"
bash "$RUNNER" scope plan > "$RUN_DIR/scope.txt"
printf '%s\n\n%s\n' "$(cat "$RUN_DIR/scope.txt")" "$REVIEW_PROMPT_BODY" > "$RUN_DIR/prompt.txt"
bash "$RUNNER" run-external --phase plan-review --prompt-file "$RUN_DIR/prompt.txt"

# read results
cat "$RUN_DIR/plan-review-verdict.txt"                          # full text
RESUME_ID="$(cat "$RUN_DIR/plan-review.session" 2>/dev/null)"   # for the next iteration
```
