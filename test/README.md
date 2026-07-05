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
bootstrap|scope|run-external ...`), the same way an agent does — never a same-process source
of extracted fragments. `40-killwait.sh` and `60-fallback.sh` additionally `source` the script
directly (its guarded `main` means sourcing does not auto-dispatch a subcommand) to unit-test
`devflow_kill_wait` / `devflow_after_call` in isolation with hand-crafted state.

The one external dependency — the `codex`/`claude` process launch — is replaced by
`lib/fake-codex`, a stub that emits canned JSONL events (`FAKE_CODEX_MODE=ok|linger|
ratelimit|auth|hang`; `hang` stays alive emitting nothing, to exercise the hard-cap timeout),
and `lib/fake-claude`, a stub for the default `backend: claude` path that prints a canned
`{"result":...,"session_id":...}` JSON object (`FAKE_CLAUDE_MODE=ok|ratelimit|auth|hang` —
no separate `linger` mode, since claude has no turn.completed-style mid-stream signal
distinct from process exit). Everything else in the runner (config merge, run.env freeze,
fingerprint reuse, polling, kill escalation, verdict extraction, scope building, fallback)
is real.

## Test seams

The runner reads two env overrides so tests don't wait real minutes; defaults are unchanged:

- `DEVFLOW_POLL_SCHEDULE` — backoff seconds (default `15 30 60 …`)
- `DEVFLOW_DRAIN_SCHEDULE` — post-completion drain sleeps (default `5 5 5 5 5 5`)

## Cases

| File | Covers |
|------|--------|
| `10-bootstrap` | `bootstrap`: run.env produced, binary resolved via `command_path`, personas cached as content, plan path avoids `docs/superpowers`, values round-trip, idempotent reuse (`REUSED=1`) |
| `20-reuse` | `bootstrap` reuse: unchanged config reuses the same RUN_DIR, a reaped RUN_DIR forces a fresh bootstrap, changed config invalidates, foreign env rejected (`devflow_env_valid`, white-box) |
| `30-invoke` | `run-external` on `backend: codex`: verdict + session captured, exit 0; `--no-session-reuse` ephemeral; `--resume` path; linger → completes then bounded drain; hang → poll exhausts → hard-cap kill 124; `VERDICT_STATUS` parsing (case/markdown/punctuation tolerance, `UNKNOWN` fallback) |
| `35-invoke-claude` | `run-external` on `backend: claude` (the config default): `.result`/`.session_id` JSON parsing, `command -v claude` resolution via PATH, `--resume`/`--permission-mode`/`--no-session-persistence` flag plumbing, hard-cap kill (no linger case — see above) |
| `40-killwait` | `devflow_kill_wait` (white-box) escalates to `-9` on a SIGTERM-ignoring child, returns bounded |
| `50-scope` | `scope <mode>`: per-mode file sets + diff command, untracked enumeration, branch base resolution, guard errors |
| `60-fallback` | `devflow_after_call` (white-box): success passes, rate-limit retries once via fallback, auth escalates w/o retry, empty fallback escalates |

## Requirements

`bash`, `git`, `python3` + PyYAML (same as the runner itself).
