# devflow test harness

Offline, deterministic tests for `skills/using-devflow/references/cross-tool-runner.md`.

## Run

```bash
bash test/run.sh          # all cases
bash test/run.sh 30 60    # only cases whose filename starts 30 / 60
```

No API token, no network. Runs in throwaway sandboxes under `$TMPDIR`, ~seconds.

## How it stays honest

`lib/extract-bash.py` pulls the **real** ```bash blocks out of `cross-tool-runner.md`
(grouped by section: A.1/A.2/A.3 → `a1/a2/a3.sh`, Section B/C/D → `b/c/d.sh`) and the
cases `source` those. Edit the skill spec and the next run tests the new code — there is
no hand-maintained copy to drift.

The one external dependency — the `codex`/`claude` process launch — is replaced by
`lib/fake-codex`, a stub that emits canned JSONL events (`FAKE_CODEX_MODE=ok|linger|
ratelimit|auth`). Everything else in the runner (config merge, run.env freeze, fingerprint
reuse, polling, kill escalation, verdict extraction, scope building, fallback) is real.

## Test seams

The runner reads two env overrides so tests don't wait real minutes; defaults are unchanged:

- `DEVFLOW_POLL_SCHEDULE` — backoff seconds (default `15 30 60 …`)
- `DEVFLOW_DRAIN_SCHEDULE` — post-completion drain sleeps (default `5 5 5 5 5 5`)

## Cases

| File | Covers |
|------|--------|
| `10-bootstrap` | Section A: run.env produced, binary resolved via `command_path`, personas cached as content, plan path avoids `docs/superpowers`, values round-trip |
| `20-reuse` | Section A.2: valid env reused (same RUN_DIR), changed config invalidates, foreign env rejected |
| `30-invoke` | Section B: verdict + session captured, exit 0; `session_reuse=false` ephemeral; linger → bounded drain → kill 124 |
| `40-killwait` | `devflow_kill_wait` escalates to `-9` on a SIGTERM-ignoring child, returns bounded |
| `50-scope` | Section C: per-mode file sets + DIFF_CMD, untracked enumeration, branch base resolution |
| `60-fallback` | Section D: success passes, rate-limit retries once via fallback, auth escalates w/o retry, empty fallback escalates |

## Requirements

`bash`, `git`, `python3` + PyYAML (same as the runner itself).
