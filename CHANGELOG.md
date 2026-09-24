# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

## [0.2.0] - 2026-09-24

### Added

- `roles`/`review` execution-profile config (`config.default.yaml`, `~/.devflow/config.yaml`):
  binds devflow's process roles (`implementer`, `reviewer`, `verifier`) to named host subagents
  and caps reviewer passes per deliverable via `review.max_passes` /
  `review.fallback_to_host`. Trust-restricted the same way as `codex.command_path` — a project
  `.devflow.yaml` can never set these (`roles.reviewer.lens` excepted).
- `executor_manifest` config key: points at a file conforming to the new
  `docs/contracts/executor-manifest-v1.md` contract; when set, its `roles` and
  `budgets.review_passes`/`budgets.fallback_to_host` override the inline `roles`/`review`
  above. Global-only, same trust rule. `devflow-config.py resolve` validates the manifest's
  version and `host` field and adds a `_manifest: {path, host, producer}` key to its resolved
  output.
- `scripts/devflow-runner.sh passes init --deliverable <id> --max <n>`: fixes the review-pass
  budget for a deliverable's life (exit `8` `BUDGET_ALREADY_SET max=<old>` on a conflicting
  re-init; `dir --fresh` is the only reset).
- `scripts/devflow-runner.sh passes reserve|close|status --deliverable <id>`: the pass-budget
  accounting a `review.max_passes` limit is enforced against — one file per deliverable in
  `RUN_DIR`, reservation before a call, idempotent re-reservation of the same `--call-id`.
  `reserve` no longer takes `--max`; it reads the budget `init` fixed and exits `2`
  `BUDGET_NOT_INITIALIZED` if `init` was never called, `3` `BUDGET_EXHAUSTED` if the budget is
  used up, `9` `CALL_ALREADY_CLOSED` if that `--call-id` was already reserved and closed (do not
  re-dispatch; reuse the recorded verdict).
- `scripts/devflow-runner.sh profile-init --roles-file <path> --host <claude|codex|gemini|cursor|opencode>
  [--expect-host <h>]`: writes `profile-active`/`max-passes`/`effective-roles.json` for the run;
  same exit codes as `preflight`, plus `2` for a bad `--roles-file`.
- `scripts/devflow-runner.sh deliverable-id --phase <plan|impl|review> [--plan-path <p>]
  [--baseline <sha>]`: computes and records the deliverable id a phase's pass budget is keyed on;
  exit `2` `NO_IMPL_BASE`/`NO_BASELINE`, `8` `DELIVERABLE_CHANGED old=<x> new=<y>`.
- `scripts/devflow-runner.sh result-write --path <p>`: reads the result body on stdin and writes
  it atomically to `<p>`; exit `0`/`1`.
- `scripts/devflow-runner.sh passes complete --deliverable <id> --scope <digest> --verdict
  <clean|blockers>`: writes the deliverable's `.done` completion record (used by the
  no-double-review check) once every reservation on it is closed; exit `1` if any remain open.
- `scripts/devflow-runner.sh preflight --roles-file <path> --host <h> [--expect-host <h>]
  [--write-effective <path>]`: checks, before a phase starts calling a bound agent, whether the
  host supports named-agent delegation at all and whether each bound agent actually resolves;
  also rejects an executor manifest built for a different host (`HOST_MISMATCH`, exit 7) than
  the one running. `--write-effective <path>` writes `effective-roles.json` on the exit-`0`
  path — the resolved role bindings, with any fallback applied and listed in `fallbacks[]` —
  which is the only place a skill reads bindings from after preflight.
- `scripts/devflow-runner.sh scope-digest [--base <sha>]`: prints a stable digest of the current
  working tree (tracked + untracked, dirty included), reusing the existing freshness-gate
  snapshot code. Recorded as `result.yaml`'s `scope_digest` and passed to `passes complete
  --scope`.
- `$RUN_DIR/result.yaml`: the result contract, written by skills on every terminal path (`DONE`
  / `NEEDS_USER_DECISION` / `FAILED`) per `docs/contracts/result-contract-v1.md`.
- `docs/contracts/executor-manifest-v1.md` and `docs/contracts/result-contract-v1.md`: two
  versioned, agnostic data contracts (with examples under `docs/contracts/examples/`) — an
  execution layer's role/budget bindings flowing into devflow, and devflow's phase/pipeline
  outcome flowing back out. Neither devflow nor any execution layer is named as a dependency of
  the other; the contracts are the only shared surface.
- README "Execution profiles (optional)" section documenting all of the above: the full runner
  CLI (`init`/`reserve`/`close`/`status`/`complete`/`preflight`/`scope-digest`), the full
  exit-code table (`2`/`3`/`4`/`5`/`6`/`7`/`8`), and how to opt out.
- `python3` is now a hard runtime dependency, used by `scripts/devflow-config.py` to resolve
  execution-profile config.

### Changed

- `result.yaml` is now written on every phase end (additive) — the one behavioural change that
  applies even with no profile configured. Every other addition above is inert until explicitly
  configured: `roles.*.agent: ""`, `review.max_passes: 0`, and `executor_manifest: ""` are the
  shipped defaults, and with them devflow's execution is otherwise identical to before this
  feature existed.

### Notes

- **Unit of budget**: a pass, not a phase or a call in general — one reviewer call (internal
  agent or external CLI) over a deliverable's agreed scope. `implement`'s and `run`'s review of
  the same deliverable share one budget; they are not separately metered.
- **Fallback semantics**: `review.fallback_to_host: true` downgrades an unresolvable named-agent
  binding from a hard preflight error to a reported fallback (`FALLBACK_TO_HOST role=agent`) onto
  devflow's default execution path — never a silent substitution.
- **Model precedence**: when a role is bound to a named agent, that agent's own model/effort
  configuration wins; `persona_tiers` (model/effort per persona) only applies on the default,
  unbound execution path.
- **Reviewed vs final revision**: the result contract (`docs/contracts/result-contract-v1.md`)
  reports `revision_reviewed` (what the last review pass actually read) and `revision_final`
  (what shipped after any subsequent fix waves) as two distinct fields — a consumer should never
  assume they're the same revision.
- **`scope_digest`**: `scripts/devflow-runner.sh scope-digest` prints a content-addressed digest
  of the working tree (tracked + untracked, dirty included), reusing the freshness gate's
  existing snapshot code rather than a second, differently-forgeable notion of "what changed".
  Skills record it in `result.yaml` and pass it to `passes complete --scope`; `devflow-run`'s
  no-double-review check compares it against the digest already recorded in a deliverable's
  `.done` file.

### Fixed

- `devflow:run` Step 0 called `dir --fresh` unconditionally, wiping `RUN_DIR` (and the pass
  ledger's anti-replay guard along with it) on every re-entry, including a post-compaction
  resume — so every compaction re-paid every external review pass. Step 0 now takes a plain
  `dir` (no wipe) when an execution profile is active, keyed against a `feature-key` file so a
  resume cannot silently pick up an unrelated feature's state; the no-profile path is
  unchanged. Adds `scripts/devflow-runner.sh dir --check-active`, a non-destructive lease
  check, so the resume-safe path keeps the `RUN_ACTIVE` concurrency stop without wiping
  anything.
- `.claude-plugin/marketplace.json` was missing since the repo's first commit, so
  `claude plugin marketplace update` / `update` / `install` all failed to resolve this plugin
  against any marketplace — every fix pushed here was unreachable by any update path. Added.
