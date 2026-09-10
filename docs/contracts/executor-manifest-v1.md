# Executor manifest v1 (draft until first independent implementation)

An **agnostic** contract between an execution layer (whatever decides *who* runs implementer/
reviewer/verifier work — claude-orchestrator or any other) and a process layer (whatever decides
*what happens in what order* — devflow or any other). Neither side names the other: devflow does
not import or depend on any specific execution layer, and any execution layer that can produce
this file, in this shape, can drive devflow's execution profiles. See design rationale in the
project that generates your copy of this file; devflow only consumes it.

## Schema

```yaml
executor_manifest: 1
producer: claude-orchestrator          # informational — who generated this file
host: claude                           # host whose agent names are used below
roles:
  implementer: { agent: implementer }
  reviewer:    { agent: reviewer, lens: architect }
  verifier:    { agent: verifier }
budgets:
  review_passes: 2                     # per deliverable; 0 = unlimited
  fallback_to_host: false
```

An example file lives at `docs/contracts/examples/executor-manifest.example.yaml`.

## Fields

| Field | Meaning |
|---|---|
| `executor_manifest` | Contract major version. A consumer that only understands major version 1 MUST reject any other value — see "Versioning" below. |
| `producer` | Free-text, informational only. Names whatever generated the file (e.g. `claude-orchestrator`). Never used to decide behaviour. |
| `host` | The host tool whose named-agent delegation the `roles.*.agent` values refer to (e.g. `claude`, `codex`, `gemini`, `cursor`, `opencode`). A process layer running under a *different* host than this must treat the manifest as inapplicable to that run (devflow's `preflight --expect-host` reports this as `HOST_MISMATCH`). |
| `roles.implementer.agent` | Name of the host subagent that performs implementation-role work (plan tasks, fix waves, handoffs). |
| `roles.reviewer.agent` | Name of the host subagent that performs a review pass. |
| `roles.reviewer.lens` | Optional. The review lens/persona this pass uses (e.g. `architect`, `security`, `qa`) — recorded in reports, not trust-restricted. |
| `roles.verifier.agent` | Name of the host subagent that confirms a result (tests, exit codes, revision). |
| `budgets.review_passes` | Maximum reviewer passes a single deliverable may consume (0 = unlimited). One pass = one reviewer call (internal agent or external CLI) over a deliverable's agreed scope; passes are counted per deliverable, not per phase. |
| `budgets.fallback_to_host` | If `true`, an explicitly bound but unresolvable agent falls back to the process layer's own default execution path instead of failing preflight — the fallback is always reported (one line per affected role), never applied without a trace. If `false` (default), an unresolvable named agent is a hard preflight error. |

## Normative cases

- **Inline-only profile**: an executor manifest is entirely optional. The inline `roles:`/
  `review:` block under `~/.devflow/config.yaml` (see `config.default.yaml`) is a complete,
  standalone way to configure execution profiles — a manifest is a layered override on top of
  it, never a requirement.
- **Partial manifest**: a manifest need not bind every role. A role absent from the manifest's
  `roles` mapping inherits that role's value from the inline config underneath (roles merge
  key-by-key, not as an all-or-nothing block). A role present in the manifest with `agent: ""`
  is different from an absent role: it explicitly selects the default execution path for that
  role, overriding whatever the inline config set.
- **Relative `executor_manifest` path**: when the `executor_manifest` value in the *global*
  config (`~/.devflow/config.yaml`) is a relative path (not starting with `~` or `/`), it is
  resolved against `$HOME`, not the project root or the process's current working directory —
  consistent with `executor_manifest` being honoured only from the global config layer.

## Producer / consumer

- **Produced by** an execution layer (L1): whatever registry of agents/roles knows which named
  subagent fills which role on the current host. `claude-orchestrator` is one example producer —
  it generates this file from agent frontmatter (`executor_role: implementer|reviewer|verifier`,
  optional `lens:`) so the agent catalogue stays the single source of truth.
- **Consumed by** a process layer (L2): whatever decides phase-by-phase what happens next.
  `devflow` is one example consumer — it reads the manifest at config-resolve time (see
  `scripts/devflow-config.py resolve`) and again at `devflow-runner.sh preflight` before a phase
  starts calling any bound agent.
- **Devflow does not depend on any specific execution layer.** Without a manifest installed
  (`executor_manifest: ""` in `~/.devflow/config.yaml`, the shipped default), devflow falls back
  to whatever `roles`/`review` are set inline in `.devflow.yaml`/`~/.devflow/config.yaml` — a
  manifest is a layered override, not the only way to get agent bindings or a pass budget. It is
  only true that there are **no agent bindings** without either an inline `roles.*.agent` or a
  manifest; `review.max_passes` set inline still applies with no manifest at all (see the
  "Inline-only profile" case above and `config.default.yaml`). Any other execution layer — or a
  hand-written file — that produces a manifest in this exact shape is equally valid; devflow
  never checks who produced it beyond the informational `producer` field.

## Supported YAML subset (normative)

Every file this contract touches (`~/.devflow/config.yaml`, project `.devflow.yaml`, an executor
manifest itself) is parsed by `scripts/devflow-config.py`'s own YAML-subset parser, not a general
YAML library. The supported subset is:

- 2-space block indentation; block mappings (`key:` / `key: value`) and block sequences, either
  indented under their key or at the SAME indent as the key (`- item`).
- **One level** of flow collection: a one-line flow mapping (`{ k: v, k2: v2 }`) or flow list
  (`[a, b]`). A flow collection nested inside another flow collection (`{ k: { nested: v } }`) is
  **not supported** — write it as a block mapping instead (`k:\n  nested: v`).
- Scalars: quoted strings (`'...'`/`"..."`), bare words, ints, floats, booleans (`true`/`false`/
  `yes`/`no`/`on`/`off`, any case), and `null`/`~`.
- `#` comments (outside quotes).
- Exactly **one YAML document** per file — a `---`/`...` document-separator line is rejected, not
  silently truncated to the first document.

Anything outside this subset (nested flow collections, multiple documents, anchors/aliases,
block scalars `|`/`>`, tags, and any top-level line the parser cannot place in the block it
started) is a hard parse error: `devflow-config: <path>:<line>: <message>` on stderr, exit `2`,
nothing on stdout — never a best-effort partial parse.

## Versioning

`executor_manifest` is a **major version**. A consumer that only understands version `N` MUST
reject any manifest whose `executor_manifest` is not exactly `N` — never guess-parse an unknown
major as if it were compatible. devflow's resolver rejects an unsupported version with
`ERROR executor_manifest version <v> unsupported` and exits `6`. A future incompatible schema
change bumps this integer; an additive, backward-compatible change (a new optional field) does
not require a version bump.
