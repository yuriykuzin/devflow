# Cross-Tool Runner

Canonical procedure for external-CLI calls (review, resume, implementer handoff).
Referenced by `devflow:plan`, `devflow:implement`, `devflow:review`, and `devflow:run`.

**What lives in the script vs. what you do yourself.** The one thing that genuinely cannot
live in markdown is supervising a long (8–10 min) backend CLI: launch it detached, poll it
with backoff and a hard cap, kill the whole process group on timeout, fold in the
rate-limit/auth fallback, and capture the session id. A single Bash tool-call can't do that
(the host imposes its own short timeout, and Claude Code resets shell env + functions
between calls). So that — and only that — is `scripts/devflow-runner.sh run-external`, plus
a tiny `dir` helper for the run directory. **Config resolution and scope-pinning are your
job now**, done with a read of `.devflow.yaml` and plain `git` — no subcommand for either.

> **Rule:** EVERY external call in any devflow skill — fresh review, resume re-review, and
> implementer handoff/fix — MUST go through `bash "$RUNNER" run-external`. Do not hand-roll
> a one-off `codex exec` / `claude -p` invocation.

## Locate the runner

`$RUNNER` is `scripts/devflow-runner.sh` inside the devflow plugin root (the directory
containing `config.default.yaml` and `skills/`). Resolve it once per skill invocation:

```bash
# AGENT: on Claude Code, "Base directory for this skill" (shown in this skill's invocation
# preamble) is <plugin-root>/skills/<skill-name> — two directories up is the plugin root;
# prefer that when available. On other hosts, fall back to a filesystem search under the
# actual install locations: ~/.claude/plugins (Claude Code marketplace + plugin cache) and
# ~/.codex/devflow (the codex deploy target). Codex's own ~/.agents/skills/devflow is
# usually a symlink to just the plugin's skills/ dir — a `find` rooted there can never reach
# a sibling scripts/, so it's resolved separately (readlink to the real skills/ dir, then
# check its sibling scripts/devflow-runner.sh directly).
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

Always invoke it as `bash "$RUNNER" <subcommand> ...` — the script does not need to be
executable (`install.sh` never `chmod`s it). Re-run this locator at the start of every
skill's Step 1 (inline it — `$RUNNER` does not survive from an earlier Bash call; only cwd
and the filesystem do).

## RUN_DIR is deterministic

`RUN_DIR` is a hash of `git rev-parse --show-toplevel`, rooted under `${TMPDIR:-/tmp}` — not
inside the repo tree (a tracked, clone-delivered file at a predictable in-repo path would be
a same-day RCE — see "Security"). It never depends on an exported env var or a `mktemp`
pointer, so every subcommand reconstructs it identically with no shared state. It's a hash,
not something to hand-recompute in a one-liner (matching the script's hash-tool fallback
chain byte-for-byte is a drift trap). When *you* need `$RUN_DIR` in a fresh Bash call, get
it from `dir`:

```bash
RUN_DIR="$(bash "$RUNNER" dir | sed -n 's/^RUN_DIR=//p')"
```

`RUN_DIR` is also your scratch store across Bash calls. Env vars don't survive between Bash
tool-calls, but `RUN_DIR` and its files do — so a value one step computes and a later step
needs (the pre-implementation commit, the plan path) goes in a file there, e.g.
`printf '%s\n' "$SHA" > "$RUN_DIR/impl-base"` then `cat "$RUN_DIR/impl-base"` later. Session
ids work the same way — `run-external` writes `$RUN_DIR/<phase>.session` for you.

## Subcommands

### `dir [--fresh]`

Prints `RUN_DIR=<path>` for this project (created 0700, owned by you, never a symlink).
`--fresh` wipes the directory first, to start a clean run — clearing a prior feature's phase
session files so they aren't silently resumed. `--fresh` refuses (non-zero, `refusing to
wipe`) while another devflow run is still in flight in the same `RUN_DIR`, so it can never
pull the rug out from under a live call.

```bash
bash "$RUNNER" dir            # RUN_DIR=<path>
bash "$RUNNER" dir --fresh    # wipe + recreate, then RUN_DIR=<path>
```

Use `--fresh` when starting an unrelated feature in a checkout that already has an old run,
or when a `--resume` fails because the session id is gone/expired — rather than debugging a
stale-session error.

Every `dir` call also opportunistically GCs *abandoned sibling* run dirs. This matters because
`RUN_DIR` is keyed on the git top-level: a worktree-per-feature workflow mints a fresh hash
every run, so `--fresh` reuse never reclaims them and they would otherwise pile up in
`${TMPDIR:-/tmp}` forever. A sibling is reclaimed only when it is all three of: **ours** (uid
match — never another user's dir on a shared `/tmp`), **idle** (no live PID leased under
`.pids/` — the same liveness test `dir --fresh` honours, so a running call is never reclaimed
even if its dir looks old), and **old** (dir mtime more than `DEVFLOW_RUN_TTL_DAYS` full days
ago; default 7, rounded down). The age is measured from last *use*, not creation — every
`dir` / `run-external` call touches its own `RUN_DIR` — so a steadily-reused checkout is never
pruned mid-project. The current `RUN_DIR` is always excluded. Set `DEVFLOW_RUN_TTL_DAYS` to a
non-number to disable the sweep.

### `run-external --backend <b> --model <m> --effort <e> --phase <p> --prompt-file <f> [flags]`

Launches the external call (non-blocking internally — the script polls its own child with
backoff and a hard cap; it returns only when the call is done, killed, or timed out),
extracts the verdict text and session id, and prints a small `KEY=VALUE` report.

| Flag | Required | Meaning |
|------|----------|---------|
| `--backend codex\|claude` | yes | which CLI to drive — from `.devflow.yaml` (see below) |
| `--model <name>` | yes | the model for this role — from config |
| `--effort <level>` | yes | reasoning effort for this role — from config |
| `--phase <name>` | yes | `plan-review` \| `impl-review` \| `final-review` \| etc. — namespaces the output files under `$RUN_DIR` |
| `--prompt-file <path>` | yes | the full prompt (SCOPE block + review instructions), written to a file first — never inline; shell-quoting a multi-KB prompt is a footgun |
| `--role reviewer\|implementer` | no (default `reviewer`) | `reviewer` runs the backend read-only; `implementer` gets workspace-write. This alone sets the write posture — the runner derives it (claude `--permission-mode plan`/`default`, codex read-only/`--full-auto`); there is no separate permission flag. Does NOT pick the model — you pass that explicitly |
| `--resume <session-id>` | no | resume that session instead of starting fresh. An **empty value is legal and means "fresh"**, so pass it unconditionally — see below |
| `--no-session-reuse` | no | ephemeral call — no session persisted |

The binary that actually runs (and the rate-limit `fallback_command`) is resolved by the
script itself from the trusted config only — you never pass a binary path. `--model` /
`--effort` / `--backend` are not exec-path keys, so you supply them from config.

```bash
printf '%s\n\n%s\n' "$SCOPE_BLOCK" "$REVIEW_INSTRUCTIONS" > "$RUN_DIR/prompt.txt"
bash "$RUNNER" run-external --backend "$BACKEND" --model "$MODEL" --effort "$EFFORT" \
  --phase plan-review --prompt-file "$RUN_DIR/prompt.txt"
# stdout:
#   RUN_DIR=<path>
#   PHASE=plan-review
#   EXIT=<backend process exit code, or 124 on a hard-cap kill (poll schedule exhausted with no completion)>
#   VERDICT_FILE=<path to the full verdict text>
#   SESSION_ID=<id, or empty>
#   SESSION_FILE=<path — read this to resume next iteration>
```

There is deliberately **no machine-parsed verdict status**. You are the orchestrator (an
LLM) — read `VERDICT_FILE` and decide from the actual text whether it is an approval or asks
for changes. A bash token classifier would just be a second, more brittle decision on the
same prose. `EXIT` is the only mechanical signal: `0` = the call completed and `VERDICT_FILE`
holds the reviewer's answer; `124` = the call was killed at the hard cap (infra failure — no
usable verdict), so retry or surface it, don't read it as a rejection.

`run-external` folds in the rate-limit/auth fallback automatically: a transient rate limit
retries once via `fallback_command` (new session id); an auth/capability failure (bad login,
missing `--json`, empty event stream) escalates immediately without burning a retry. On any
escalation outcome (the fallback retry also failed, or an auth/capability failure) it exits
non-zero and prints a `devflow:` stderr line saying which branch fired; a **successful**
fallback retry exits `0` with a usable verdict and a fresh session id. Read stderr, not just
the exit code, before escalating to the user.

**Session capture is automatic and mandatory** — `SESSION_FILE` is written on every call.
Read it with `cat "$SESSION_FILE"` and pass its content as `--resume` next iteration; this
keeps the fix → re-review loop cheap (~20k tokens saved per resumed call) instead of
degrading to a fresh, context-less review.

**Always pass `--resume "$RESUME_ID"` unconditionally** — an empty value means "start fresh",
which is normally the first-iteration case, so no conditional is needed:

```bash
RESUME_ID="$(cat "$RUN_DIR/plan-review.session" 2>/dev/null)"   # empty on the first iteration
bash "$RUNNER" run-external --backend "$BACKEND" --model "$MODEL" --effort "$EFFORT" \
  --phase plan-review --prompt-file "$RUN_DIR/prompt.txt" --resume "$RESUME_ID"
```

An empty session file is not *always* a first iteration — a prior call can exit `124`, or
`--no-session-reuse` can have suppressed capture. That is harmless for a re-review prompt that
carries its own context, but if your prompt assumes the resumed session already knows the plan
or the diff, test `[ -s "$RUN_DIR/<phase>.session" ]` first and inline that context into the
prompt when it is empty.

Do **not** splice the flag in with `${RESUME_ID:+--resume "$RESUME_ID"}`. That idiom depends on
the shell word-splitting an unquoted expansion: bash and sh do, **zsh does not** — under zsh it
arrives as a single `--resume <id>` argument and the runner rejects it with
`run-external: unknown flag`, exit 2, so every resumed iteration fails to launch. Host agents run
these snippets through whatever shell their Bash tool uses (zsh on macOS), so the quoted,
unconditional form is the only portable one.

## Config: what to read, and pass as flags

Read the merged config once at the start of a skill and carry the values into your
`run-external` flags. There is no config subcommand — you merge three layers directly, each
overriding the next: **`.devflow.yaml`** (project root) → **`~/.devflow/config.yaml`**
(global; the recommended install copies `config.default.yaml` here) → the plugin's
**`config.default.yaml`** (built-in defaults). For any key, the first layer that sets it
wins; don't skip the global layer, or a user's global `backend:`/`model:` is silently ignored
on a project with no `.devflow.yaml`. From the merged result:

- `backend` (`codex` | `claude`) → `--backend`
- for that backend, the **reviewer** or **implementer** block's `model` + `effort` →
  `--model` / `--effort` (reviewer for review calls, implementer for handoff/fix calls)
- `session_reuse: false` → add `--no-session-reuse`
- `output_dir` (default `docs/devflow/reports`) → where plans/reports are saved; if it's
  under `docs/superpowers` (untracked-unsafe), fall back to writing plans under `$RUN_DIR`

`command_path` / `fallback_command` are the exception — you never read or pass those; the
script resolves them itself from the trusted files (see Security).

## Scope: pin the review to one changeset (plain git)

Prepend a SCOPE block to the review prompt so the reviewer inspects ONLY the intended
changeset. Build it from the file list for the mode you need:

| Mode | Files | Diff command to cite in the block |
|------|-------|-----------------------------------|
| uncommitted | `git diff --name-only HEAD` | `git diff HEAD -- <files>` |
| staged | `git diff --cached --name-only` | `git diff --cached -- <files>` |
| last-commit | `git diff --name-only HEAD^ HEAD` | `git show HEAD` |
| implementation | `git diff --name-only "$BASE"` | `git diff "$BASE" -- <files>` |
| branch | `git diff --name-only "$MB" HEAD` | `git diff "$MB"..HEAD -- <files>` |
| pr | `gh pr diff <n> --name-only` | `gh pr diff <n>` |
| files | the explicit paths | `git diff HEAD -- <those paths>` |
| plan | the plan file path | `(read-only) cat <plan-path>` |

Also list untracked files: `git ls-files --others --exclude-standard`.

**Guard, don't paper over — a mode that can't resolve its base must STOP, never emit an
empty scope** (an empty scope silently reviews nothing):
- `implementation`: `BASE` is the pre-implementation commit (read `$RUN_DIR/impl-base`).
  Verify it first — `git rev-parse --verify -q "$BASE^{commit}"` — and abort if invalid.
- `last-commit`: abort if `git rev-parse --verify -q HEAD^` fails (single-commit repo).
- `branch`: resolve `MB` as `git merge-base HEAD "$BASE"`, where `$BASE` is, in order:
  a `BASE` you already set (e.g. from a `--base` the user gave) → `git symbolic-ref --short
  refs/remotes/origin/HEAD` (the remote's default branch) → `origin/main`. Abort if
  `merge-base` is empty (shallow clone / unrelated histories). (To review a PR against its
  own base, use `pr` mode, which resolves the base via `gh`.)
- `pr`: abort if `gh pr diff <n>` fails (auth/network/bad number).

Example SCOPE block:

```
SCOPE: Review ONLY this changeset. Inspect it with: git diff HEAD -- <files>
Files in scope:
<the file list + any untracked files>
Anything outside this changeset -> list under OUT_OF_SCOPE and do NOT block on it.
```

## Security

`RUN_DIR` lives under `${TMPDIR:-/tmp}`, not inside the repo — a hostile clone must never be
able to *deliver* a tracked file into a path the script later reads. `RUN_DIR` is created
mode 0700 with an ownership + symlink check before anything touches it, closing the
predictable-shared-`/tmp`-path pre-planting attack.

`codex.command_path` and `codex.fallback_command` — the two config keys that name an
executable to run — are resolved **only** from the plugin default and
`~/.devflow/config.yaml`, never from a project-level `.devflow.yaml`, and only inside the
script (never via a flag you pass). A committed project config choosing `backend` / models /
`session_reuse` is fine; a committed project config choosing *which binary gets executed* is
not — that's a clone shipping its own payload and pointing devflow at it.

## Async execution — how to launch `run-external`

The script's own poll loop already respects `DEVFLOW_POLL_SCHEDULE` / an ~8–10min hard cap
internally; you never need an outer poll loop. You only choose *how you launch the one call*:

- **Claude Code**: launch with the Bash tool's `run_in_background: true`. You get one
  completion notification; read the output then. Do not poll with repeated foreground Bash
  calls — the script's internal poll loop is already doing the waiting.
- **Other hosts (Gemini/Cursor/Codex-as-host)**: a plain foreground/blocking call
  is fine — the script backgrounds its own `codex`/`claude` child internally regardless of
  how it was launched; only the *host's* invocation must not impose its own short timeout.

## Putting it together (per phase)

```bash
# 1) locate $RUNNER (snippet above), then:
RUN_DIR="$(bash "$RUNNER" dir | sed -n 's/^RUN_DIR=//p')"

# 2) read config from .devflow.yaml -> BACKEND / MODEL / EFFORT (reviewer block here)

# 3) build the SCOPE block from plain git (mode table above)
#    ... assemble "$SCOPE_BLOCK" ...

# 4) write the prompt and make the call
printf '%s\n\n%s\n' "$SCOPE_BLOCK" "$REVIEW_PROMPT_BODY" > "$RUN_DIR/prompt.txt"
RESUME_ID="$(cat "$RUN_DIR/plan-review.session" 2>/dev/null)"   # empty on first iteration
bash "$RUNNER" run-external --backend "$BACKEND" --model "$MODEL" --effort "$EFFORT" \
  --phase plan-review --prompt-file "$RUN_DIR/prompt.txt" --resume "$RESUME_ID"

# 5) read results
cat "$RUN_DIR/plan-review-verdict.txt"    # full verdict text
```
