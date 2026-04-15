# Devflow Sandbox

Isolated Docker environments for AI agents (Claude Code, Codex CLI) to work safely on different branches simultaneously.

## Quick Start

```bash
# 1. Set up your project (one-time, ask the AI agent):
> devflow:sandbox-setup

# 2. Ensure shared infrastructure is running:
docker compose -f docker-compose.local.yml up -d postgres redis

# 3. Create a sandbox:
sandbox/scripts/sandbox-up.sh --project /path/to/project --branch story/ONTO-123/feature --agent claude

# 4. List active sandboxes:
sandbox/scripts/sandbox-list.sh

# 5. Run commands inside a sandbox:
sandbox/scripts/sandbox-exec.sh --id sk-onto123-a1b2c3 -- pytest

# 6. Tear down:
sandbox/scripts/sandbox-down.sh --id sk-onto123-a1b2c3
```

## Architecture

Each sandbox is a Docker Compose project with:
- **Filesystem isolation** — `read_only: true`, `cap_drop: ALL`, `no-new-privileges`
- **Data isolation** — per-sandbox DB role/database, Redis DB number, Temporal task queue
- **Auth inheritance** — host credentials mounted read-only at `/auth/`, copied to tmpfs `$HOME` on start
- **MCP inheritance** — host MCP config sanitized (secrets stripped), paths rewritten

Shared infrastructure (PostgreSQL, Redis, Temporal) runs once. Each sandbox gets isolated data within that shared infra via project-provided hooks.

## Project Configuration

Each project needs a `.devflow/` directory with:

```
.devflow/
├── sandbox.yaml              # Project config (committed)
└── hooks/                    # Lifecycle hooks (committed)
    ├── data-create.sh        # Create isolated DB/cache/queues (runs on HOST)
    ├── data-destroy.sh       # Teardown data (runs on HOST)
    ├── deps-install.sh       # Install dependencies (runs in CONTAINER)
    ├── migrate.sh            # Run migrations (runs in CONTAINER)
    ├── on-create.sh          # Post-init setup (runs in CONTAINER)
    ├── on-destroy.sh         # Pre-teardown cleanup (runs on HOST)
    └── healthcheck.sh        # Verify sandbox ready (runs on HOST)
```

See `templates/sandbox.project.yaml` for an annotated example.

## Scripts

| Script | Purpose |
|--------|---------|
| `scripts/sandbox-up.sh` | Create and start a sandbox |
| `scripts/sandbox-down.sh` | Teardown (supports `--all`, `--older-than`) |
| `scripts/sandbox-list.sh` | List active sandboxes |
| `scripts/sandbox-exec.sh` | Run commands inside a sandbox |
| `scripts/sandbox-registry.sh` | Internal registry operations |

## Security Model

- Containers run read-only with all capabilities dropped
- Auth tokens live only in tmpfs (lost on container stop)
- Hooks are read from `git show main:` (immutable ref)
- Agent container (django) gets auth; worker containers do not
- MCP config is sanitized on host before containers start

## Cleanup

```bash
# List all sandboxes:
sandbox/scripts/sandbox-list.sh

# Remove a specific sandbox:
sandbox/scripts/sandbox-down.sh --id <sandbox-id>

# Remove all:
sandbox/scripts/sandbox-down.sh --all

# Remove sandboxes older than 24 hours:
sandbox/scripts/sandbox-down.sh --older-than 24h
```

## Requirements

- Docker Desktop (macOS) or Docker Engine (Linux)
- `jq`, `yq` (for YAML parsing)
- `python3` (for MCP config sanitization)
