# Result contract v1 (draft until first independent implementation)

An **agnostic** contract in the opposite direction from the executor manifest: a process layer
(devflow or any other) reports the outcome of a phase or pipeline back to whatever execution
layer invoked it, without either side naming the other. Any execution layer may consume this
file; devflow does not depend on any specific one.

## Schema

```yaml
result_contract: 1
status: DONE | NEEDS_USER_DECISION | FAILED
deliverable: <id>
scope_digest: <digest>
revision_reviewed: <sha | null>
revision_final: <sha | null>
passes: { used: 2, max: 2 }
evidence: [ {kind: tests|lint|verifier|external_review, ref: <path|cmd>, ref_type: cmd|path, summary: <1 line>} ]
blockers: [ {id: <finding id>, summary: <1 line>} ]
artifacts_dir: <RUN_DIR>
artifact_path: <path>          # only present when the deliverable has no revision (see below)
```

A `DONE` example lives at `docs/contracts/examples/result.example.yaml`; a
`NEEDS_USER_DECISION` example with open blockers lives at
`docs/contracts/examples/result.needs-user-decision.example.yaml`; a `FAILED` example (a
tool/environment failure, not a content verdict) lives at
`docs/contracts/examples/result.failed.example.yaml`; an internal-only-review `DONE` example
(no external call at all) lives at `docs/contracts/examples/result.internal-only.example.yaml`.

## Fields

| Field | Meaning |
|---|---|
| `result_contract` | Contract major version. A consumer that only understands major version 1 MUST reject any other value — see "Versioning" below. |
| `status` | `DONE` — the deliverable is finished and passed its review/verify gates. `NEEDS_USER_DECISION` — the pass budget (or another stop-state) was reached with open blockers; a human call is required before continuing. `FAILED` — the phase could not produce a usable result (e.g. a tool/environment failure, not a content verdict). |
| `deliverable` | Identifier of the reviewed unit — the same id used with `devflow-runner.sh passes reserve/close/status --deliverable`. The id's exact format (e.g. `plan-<sha256 of plan path>`, `impl-<base sha>`, `review-<merge-base sha>`) is an implementation detail of the producer; a consumer treats it as an **opaque string** to carry through, never to parse or interpret. |
| `scope_digest` | The working-tree digest (`devflow-runner.sh scope-digest`) at the point of the last review pass — the same content-addressed snapshot the freshness gate trusts. Lets a consumer tell whether a later claim about this deliverable is about the same tree state. |
| `revision_reviewed` | The revision (e.g. git SHA) the last review pass actually read. `null` before the first review pass has happened. |
| `revision_final` | The revision after any fix waves that followed that review. Equal to `revision_reviewed` when nothing changed after the last review; `null` before the first review pass (same as `revision_reviewed`). Reports distinguish these two explicitly so a reader can tell "reviewed code" from "code as shipped." |
| `passes.used` / `passes.max` | How many review passes this deliverable has consumed against its budget (`max: 0` = unlimited), mirroring `devflow-runner.sh passes status --deliverable <id>`. |
| `evidence` | List of `{kind, ref, ref_type, summary}`. `kind` is one of `tests`, `lint`, `verifier`, `external_review` (open to other values a consumer doesn't need to recognise to remain compliant). `ref` points at a command or an artifact path; `ref_type` says which — `cmd` (re-run `ref` to reproduce) or `path` (read the file at `ref`). `summary` is one line, not a paraphrase of the evidence itself. |
| `blockers` | List of `{id, summary}` open findings that must be resolved before `status` can become `DONE`. Empty when there are none. |
| `artifacts_dir` | The process layer's own working directory for this run (devflow's `RUN_DIR`). The consumer is expected to record this path, not read inside it — the process layer's internal file layout is not part of this contract. |
| `artifact_path` | Only present when the deliverable has no git revision to point at — e.g. the plan phase, reviewing a plan document rather than committed code. Names the reviewed artifact's path directly; `revision_reviewed`/`revision_final` stay `null` on this path rather than being filled with a placeholder. |

## Normative cases

- **Revisions null before first review**: `revision_reviewed` and `revision_final` are `null`
  until a review pass has actually happened — never an empty string, never omitted.
- **Plan phase / non-git artifacts**: a deliverable that isn't a git-tracked revision (the plan
  phase, reviewing a plan document) reports its target via `artifact_path` instead;
  `revision_reviewed`/`revision_final` stay `null` on this path.
- **`deliverable` is opaque**: a consumer carries the id through untouched — it must never parse
  or assume a shape for it, even though the producer's own ids happen to follow a pattern (see
  the `deliverable` field above).
- **`evidence[].ref_type`**: every evidence entry names whether `ref` is a `cmd` to re-run or a
  `path` to read; a consumer must not guess this from the string's shape.
- **`scope_digest`**: present on every result, `DONE` or not — it identifies the tree state a
  status claim is about, independent of whether that state ever got a git revision.
- **`FAILED` is a tool/environment verdict, not a content one**: `status: FAILED` means the phase
  itself could not produce a usable result — an external reviewer call that errored or returned
  no verdict, a CLI/environment failure — never "the reviewer found problems". A completed
  review that leaves open findings is `NEEDS_USER_DECISION` (with `blockers` populated), not
  `FAILED`; conflating the two would make a human read "the run is broken" when the run actually
  succeeded and simply disagreed with the change. A `FAILED` example lives at
  `docs/contracts/examples/result.failed.example.yaml`.
- **Internal-only completion**: a deliverable reviewed entirely by internal personas (no
  external-review call at all) still reports a full result: `scope_digest`, `passes.used`/`max`,
  and its `evidence` entries (kind `verifier`/`tests`/`lint` as applicable) are populated exactly
  as on a path that did call out to an external reviewer. What makes such a deliverable
  re-review-skippable later is `devflow-runner.sh passes complete --deliverable <id> --scope
  <digest>` having been called at the end of that pass — not whether an external call happened.
  An example lives at `docs/contracts/examples/result.internal-only.example.yaml`.

## Producer / consumer

- **Produced by** a process layer (L2) at the end of a phase or pipeline, written to
  `$RUN_DIR/result.yaml` and echoed in the phase's final message. `devflow` is one example
  producer.
- **Consumed by** an execution layer (L1), which copies the fields it needs into its own task
  ledger/report and does not read anything else inside `artifacts_dir`. `claude-orchestrator` is
  one example consumer.
- **Devflow does not depend on any specific execution layer** to read this file — an unread
  result is simply never surfaced anywhere, which is no different from devflow running without
  any execution layer at all today.

## Versioning

`result_contract` is a **major version**. A consumer that only understands version `N` MUST
reject any result whose `result_contract` is not exactly `N` — never guess-parse an unknown major
as if it were compatible. A future incompatible schema change (removing or repurposing a field,
changing `status`'s enum) bumps this integer; an additive, backward-compatible change (a new
optional field, a new `evidence[].kind` value) does not require a version bump.
