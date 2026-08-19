# devflow test harness

Offline, deterministic tests for `scripts/devflow-runner.sh`.

## Run

```bash
bash test/run.sh          # all cases
bash test/run.sh 30 60    # only cases whose filename starts 30 / 60
```

No API token, no network. Runs in throwaway sandboxes, ~seconds.

## How it stays honest

Every case invokes the **real** `scripts/devflow-runner.sh` as a subprocess (`bash "$RUNNER"
dir|run-external ...`), the same way an agent does — never a same-process source
of extracted fragments. `40-killwait.sh` additionally `source`s the script directly (its guarded
`main` means sourcing does not auto-dispatch a subcommand) to unit-test `devflow_kill_wait` in
isolation with hand-crafted state.

The one external dependency — the `codex`/`claude` process launch — is replaced by
`lib/fake-codex`, a stub that emits canned JSONL events (`FAKE_CODEX_MODE=ok|linger|
auth|hang`; `auth` is just a generic hard failure — the runner no longer classifies *why* a
backend failed, so the mode name only describes what the stub prints; `hang` stays alive emitting
nothing, to exercise the hard-cap timeout),
and `lib/fake-claude`, a stub for the default `backend: claude` path that prints a canned
`{"result":...,"session_id":...}` JSON object (`FAKE_CLAUDE_MODE=ok|auth|hang` —
no separate `linger` mode, since claude has no turn.completed-style mid-stream signal
distinct from process exit). Everything else in the runner (RUN_DIR derivation + 0700 create,
codex-binary resolution from trusted config, polling, kill escalation, verdict extraction) is
real.

## Test seams

The runner reads two env overrides so tests don't wait real minutes; defaults are unchanged:

- `DEVFLOW_POLL_SCHEDULE` — backoff seconds (default `15 30 60 …`)
- `DEVFLOW_DRAIN_SCHEDULE` — post-completion drain sleeps (default `5 5 5 5 5 5`)

## Cases

| File | Covers |
|------|--------|
| `10-dir` | `dir`: emits the deterministic RUN_DIR (created 0700); `dir --fresh` wipes stale phase-session files and re-emits a clean RUN_DIR |
| `15-gc` | `dir`'s opportunistic GC of sibling run dirs: prunes an OLD sibling, keeps one inside the TTL, never prunes the current RUN_DIR, and a non-numeric `DEVFLOW_RUN_TTL_DAYS` disables the sweep. Reroots `DEVFLOW_RUN_HOME` into the sandbox so it can only ever touch its own dirs |
| `30-invoke` | `run-external` on `backend: codex`: required-flag validation (`--backend`/`--model`/`--effort`); verdict text captured to `VERDICT_FILE` verbatim (no machine parse) + session captured, exit 0; `--no-session-reuse` ephemeral; `--resume` path, plus the caller contract that an EMPTY `--resume` is accepted and means "fresh" (never `exec resume`) so skills can pass it unconditionally; linger → completes, bounded drain, reaped as success (exit 0, verdict survives); hang → poll exhausts → hard-cap kill 124; reviewer read-only vs implementer `--full-auto` |
| `35-invoke-claude` | `run-external` on `backend: claude`: `.result`/`.session_id` JSON parsing, `command -v claude` resolution via PATH, write posture derived from `--role` (reviewer → `--permission-mode plan`, implementer → `default`), `--resume`/`--no-session-persistence` flag plumbing (incl. an empty `--resume` meaning "fresh" — the flag is left off the claude command line), hard-cap kill (no linger case — see above) |
| `40-killwait` | `devflow_kill_wait` (white-box) escalates to `-9` on a SIGTERM-ignoring child, returns bounded |
| `45-trust-boundary` | `command_path` is honoured ONLY from `~/.devflow/config.yaml`, never a project `.devflow.yaml`: a repo-planted binary named by project config never runs; the global-config codex wins |
| `50-freshness` | the freshness gate: a digest is promoted only by a call that produced a usable verdict; content edits to an already-modified file are detected; an external diff driver cannot blind the snapshot; a failed promotion or a failed verdict write consumes nothing and reports empty values; a snapshot that cannot be taken is `REASON=snapshot-failed`, never FRESH |
| `55-guards` | RUN_DIR is not under a write-mode writable root; `devflow-json.py`'s exit-code contract (3 = ran/nothing usable, 2 = wrong argv); a broken extractor is reported as a devflow failure, not an empty verdict; a `command_path` that is missing, non-executable, or fails the `exec --json` probe aborts instead of silently substituting another binary |

## Requirements

`bash`, `git`, `python3` (stdlib only — the runner parses config with `awk` and JSON with
`scripts/devflow-json.py`; no PyYAML, no `jq`). Same as the runner itself.

## Known coverage gaps

Consciously not covered by the offline harness (documented rather than tested, to keep the
suite fast and dependency-free — a deliberate minimalism trade-off):

- **Real backend I/O** — every case uses `fake-codex`/`fake-claude` stubs. Only **codex** has
  a real-CLI smoke test (`test/smoke-real-codex.sh`, opt-in, needs a token, not in CI); it
  hardcodes `--backend codex`. **claude** — the shipped default (`config.default.yaml`) — has
  NO real-CLI validation at any level: `fake-claude`'s assumed `.result`/`.session_id` JSON
  shape and its flag set (`--permission-mode`, `--effort`, `--resume`,
  `--no-session-persistence`) are unverified against a real `claude` binary.
- **`devflow-json.py` fail-closed paths** — partly covered as of `55-guards.sh`, which calls
  the extractor directly and asserts its exit-code contract (3 = ran, nothing usable; 2 = wrong
  argv; 0 = value) for a stream with no `turn.completed` and for an unreadable input, plus one
  `run-external` call whose extractor cannot run at all. Still untested: a `turn.failed` /
  `is_error` stream, and a session id failing the strict-token check.
- **Concurrency** — nothing guards a RUN_DIR against a concurrent `dir --fresh` any more (the
  PID-lease mechanism was removed as over-engineering for a single-user tool). The guarantee is
  worktree = safe-parallel, same-checkout = serial, and it is documented rather than enforced.
- **A hostile local uid** — RUN_DIR is created 0700 and nothing more: no ownership assertion, no
  symlink rejection. Out of scope by design for a personal tool.
- **Config-parse edge cases** — the `awk` reader of `command_path` is
  tested for the happy path and the trust boundary (`45-trust-boundary`), not for malformed
  YAML, comments-in-odd-places, or duplicate keys.
- **Shell-portability of the skill snippets** — `30`/`35` assert the runner's *side* of the
  empty-`--resume` contract, but nothing checks that the `bash "$RUNNER" run-external …` lines
  inside `skills/**/SKILL.md` still honour it. A snippet regressing to
  `${RESUME_ID:+--resume "$RESUME_ID"}` breaks only under zsh (the host agents' shell), and the
  suite runs under bash, so it would stay green. Verified by hand on change.
