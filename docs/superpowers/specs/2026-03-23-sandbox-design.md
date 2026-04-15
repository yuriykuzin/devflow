# Devflow Sandbox: Isolated Environments for AI Agents

**Date:** 2026-03-23
**Status:** Approved (18 Codex gpt-5.4 review iterations — architecture, security, hooks model)

## Problem

Devflow orchestrates AI agents (Claude Code, Codex CLI) to plan, implement, and review code. These agents need `--dangerously-skip-permissions` (Claude) or `--full-auto` (Codex) to work autonomously. Running them directly on the host is unsafe — they can write anywhere, modify configs, and affect shared state.

Multiple agents need to work on different git branches simultaneously, each with its own Django server, Celery workers, Playwright browser testing, and database migrations — without interfering with each other or the developer's active work.

## Threat Model

**Primary goal:** prevent accidental damage to host filesystem and cross-sandbox interference.

**In scope:**
- Agent cannot write to host filesystem outside its sandbox
- Agent cannot corrupt other sandboxes' data (DB, files)
- Agent cannot modify host tool configurations
- Sandbox lifecycle is clean: create, use, destroy without residue

**Out of scope (Phase 2):**
- Protection against a deliberately hostile/compromised agent
- Credential exfiltration prevention (agents need auth tokens to function — read-only mounts prevent modification but not use)
- Network-level isolation (agents need internet for MCP servers, APIs, gh, jira)

**Acknowledged trade-offs:**
- Auth tokens mounted read-only can still be used by the agent (by design — the agent needs them). Scoped/short-lived tokens are a Phase 2 improvement.
- Containers on Docker Desktop can reach `host.docker.internal` and published host ports. We do not claim network isolation — only filesystem and data isolation.
- Redis DB numbers are a logical separation, not a security boundary. Any process with the Redis endpoint can `SELECT` another DB or run `FLUSHALL`. This is best-effort separation to prevent accidental cross-contamination. Phase 2: per-sandbox Redis instances.

## Goals

1. **Filesystem isolation** — agents cannot write outside their sandbox
2. **Parallel branches** — 2-6 sandboxes running simultaneously on different branches
3. **Full dev stack per sandbox** — Django, Celery, Playwright + Chromium, MCP servers
4. **Shared infrastructure server** — one PostgreSQL server, one Redis server (resource efficiency)
5. **Isolated data** — via project-provided hooks (data-create.sh / data-destroy.sh). devflow is DB-agnostic.
6. **Auth inheritance** — host tokens mounted read-only at `/auth/`, copied directly to tmpfs `$HOME` on every container start (never persisted to `/app/`)
7. **MCP inheritance** — host MCP config translated (inline secrets stripped), persisted to `/app/.devflow/mcp/` as env-var references only
8. **Internet access** — agents can reach external APIs (exa, Jira, GitHub, LiteLLM proxy)
9. **Configurable per-project** — universal engine in devflow, project-specific config in target repo
10. **Team-ready migration path** — starts gitignored, evolves into committed config

## Non-Goals

- Network isolation / firewall (agents need internet)
- Per-sandbox PostgreSQL server (one server, multiple databases + roles)
- Per-sandbox Redis server (Phase 2 — current: best-effort DB number separation)
- GUI / VS Code devcontainer integration (CLI-first)
- CI/CD integration (future scope)
- Protection against hostile agent (see Threat Model)

## Architecture

### Approach: Docker Compose Override

Each sandbox is a Docker Compose project that extends the project's existing compose file with a sandbox overlay. Shared infrastructure (PostgreSQL server, Redis server) runs on the host's existing compose stack. Per-sandbox services (Django, Celery) run in isolated containers.

```
HOST (macOS)
+================================================================+
|                                                                  |
|  SHARED INFRASTRUCTURE (existing docker-compose.local.yml)       |
|  +----------------------------------------------------------+   |
|  | PostgreSQL :5432           | Redis :6379                  |   |
|  | ├─ source_db (host dev)   | ├─ DB 0 (host dev)           |   |
|  | ├─ sb_sk_onto123_a1b2c3   | ├─ DB 1 (sandbox 1)          |   |
|  | └─ sb_sk_onto456_d4e5f6   | └─ DB 2 (sandbox 2)          |   |
|  |                            |                              |   |
|  | Temporal :7233 (shared, per-sandbox task queues)           |   |
|  +----------------------------------------------------------+   |
|         |  docker network: devflow-shared    |                   |
|         |                                    |                   |
|  SANDBOX 1 (compose project: sb-sk-onto123-a1b2c3)              |
|  +----------------------------------------------------------+   |
|  | sandbox-init (runs once → deps, migrate, hooks)            |   |
|  |   writes to /app/.devflow/ (persistent, shared)           |   |
|  |                                                            |   |
|  | django:8001 (depends_on: sandbox-init success)            |   |
|  |   entrypoint: copy /auth/* → $HOME (tmpfs), then exec    |   |
|  | celeryworker (depends_on: sandbox-init success)           |   |
|  |   entrypoint: no auth — app-only env vars                |   |
|  |                                                            |   |
|  | /app         ← git clone --reference (rw)                 |   |
|  | /auth/claude  ← host ~/.claude (READ-ONLY)                |   |
|  | /auth/codex   ← host ~/.codex/auth.json (READ-ONLY)      |   |
|  | /auth/gh      ← host ~/.config/gh (READ-ONLY)            |   |
|  | /auth/ssh     ← single key + known_hosts (READ-ONLY,opt) |   |
|  | $HOME         ← tmpfs (per-container, ephemeral)          |   |
|  |                                                            |   |
|  | DB: role sb_sk_onto123_a1b2c3 OWNS its database           |   |
|  |     PUBLIC revoked on DB + schema                         |   |
|  | Redis: DB 1 (best-effort)                                 |   |
|  | Temporal: queue = sb-sk-onto123-a1b2c3                    |   |
|  |                                                            |   |
|  | read_only: true | cap_drop: ALL | no_new_privileges       |   |
|  +----------------------------------------------------------+   |
+================================================================+
```

### Sandbox ID Generation

Format: `{project_slug}-{ticket}-{random6}` where:
- `{project_slug}` = short project identifier (e.g., `sk` for skills-ontology, configurable in sandbox.yaml)
- `{ticket}` = extracted from branch name (e.g., `onto123` from `story/ONTO-123/...`)
- `{random6}` = 6-char random hex (e.g., `a1b2c3`)

Example: `sk-onto123-a1b2c3`. Globally unique across projects. Persisted in registry.

### Container Security Model

Each sandbox container runs with:

- `read_only: true` — root filesystem is read-only
- `tmpfs: [/tmp, /var/run, /home/dev-user]` — writable temp areas (per-container, ephemeral)
- `cap_drop: [ALL]` — no Linux capabilities
- `no_new_privileges: true` — cannot escalate
- `/app` is the only persistent writable mount (the cloned repo)
- Auth mounted at `/auth/*` (read-only) — host credentials
- `$HOME` is tmpfs — populated from `/auth/*` (ro mounts) on every container start
- Full outbound internet access

### What Sandboxes CAN and CANNOT Do

| CAN | CANNOT |
|-----|--------|
| Write to `/app` (its own clone) | Write to host filesystem |
| Read auth tokens (ro mount at `/auth/`) | Modify host `~/.claude`, `~/.codex`, `~/.config/gh` |
| Connect to its own sandbox DB (owned role, PUBLIC revoked) | Access source DB or other sandboxes' DBs |
| Use its assigned Redis DB number | — (best-effort: can technically SELECT other DBs) |
| Run Django/Celery/Playwright | Escalate privileges |
| Run Claude CLI / Codex CLI | See other sandboxes' files |
| Access internet (APIs, MCP) | — |
| Use auth tokens for API calls | Modify the auth tokens themselves |

### Git Clone Strategy

**`git clone --reference` instead of worktrees.**

Worktrees are unsuitable because their `.git` file points back to the main repo's shared git admin directory — creating shared mutable state across sandboxes inside containers.

Each sandbox gets a full `git clone`:

```bash
git clone \
  --reference /path/to/skills-ontology \
  --branch story/ONTO-123/new-skill-crud \
  git@github.com:studytube/skills-ontology.git \
  ~/.cache/devflow/sandboxes/sb-sk-onto123-a1b2c3
```

- `--reference` shares git objects with the main repo (saves ~90% disk)
- Each clone has its own independent `.git` directory
- Disk cost: ~10-20MB per sandbox

### Sandbox Root Directory

`~/.cache/devflow/sandboxes/` (configurable via `DEVFLOW_SANDBOX_ROOT`):
- Docker Desktop file sharing works reliably under `$HOME`
- Survives reboots (explicit cleanup via `sandbox-down.sh`)

## Data Isolation: Hooks-Based Model

Devflow does **not** implement database-specific isolation logic. Instead, it provides a generic hooks interface. The project provides executable hook scripts that handle data isolation for its specific stack.

### Hook Interface

devflow calls these hooks at lifecycle events, passing `$SANDBOX_ID` and other context as env vars:

| Hook | When | Purpose | Required? |
|------|------|---------|-----------|
| `hooks/data-create.sh` | sandbox-up, after clone | Create isolated data (DB, cache, queues) | No |
| `hooks/data-destroy.sh` | sandbox-down, after services stop | Destroy isolated data | No |
| `hooks/deps-install.sh` | sandbox-init, inside container | Install dependencies | No |
| `hooks/migrate.sh` | sandbox-init, after deps | Run migrations | No |
| `hooks/on-create.sh` | sandbox-init, after migrate | Post-init setup (seed data, test users) | No |
| `hooks/on-destroy.sh` | sandbox-down, before data-destroy | Pre-teardown cleanup | No |
| `hooks/healthcheck.sh` | sandbox-up, after compose up | Verify sandbox is ready | No |

All hooks are optional. Missing hooks are skipped. All hooks receive these env vars:
- `SANDBOX_ID` — unique sandbox identifier
- `SANDBOX_BRANCH` — git branch name
- `SANDBOX_PROJECT` — project root path
- `SANDBOX_CLONE` — clone path

### Runtime State File

Hooks that allocate resources (DB, Redis DB numbers, etc.) write state to a standard file so teardown hooks can find and free them:

**Path:** `{clone}/.devflow/sandbox.runtime`
**Format:** key=value, one per line (sourceable by bash)
**Lifecycle:** created by `data-create.sh`, read by `data-destroy.sh`, deleted on clone removal

```bash
# Written by data-create.sh:
DB_NAME=sb_sk_onto123_a1b2c3
DB_USER=sb_sk_onto123_a1b2c3
DB_PASSWORD=a1b2c3d4e5f6...
REDIS_DB=1
TEMPORAL_QUEUE=sb-sk-onto123-a1b2c3
```

devflow reads `sandbox.runtime` during teardown and passes its contents as env vars to `data-destroy.sh`. This keeps the state contract standard while allowing project-specific keys.

### Hook Execution Context

| Hook | Runs on | Has auth? | Has network? |
|------|---------|-----------|-------------|
| `data-create.sh` | **Host** (before containers) | Host's own | Yes |
| `data-destroy.sh` | **Host** (after containers stop) | Host's own | Yes |
| `deps-install.sh` | sandbox-init container | No | Yes |
| `migrate.sh` | sandbox-init container | No | Yes |
| `on-create.sh` | sandbox-init container | No | Yes |
| `on-destroy.sh` | One-shot container | No | Yes |
| `healthcheck.sh` | **Host** | Host's own | Yes |

`data-create.sh` and `data-destroy.sh` run on the **host** because they often need privileged DB access (createuser, createdb) that the sandbox container's scoped role cannot perform.

### Example: skills-ontology (PostgreSQL + Redis + Temporal)

```bash
# .devflow/hooks/data-create.sh
#!/bin/bash
set -e
SANDBOX_PASS=$(openssl rand -hex 16)

# PostgreSQL: owned role + isolated DB
createuser "$SANDBOX_ID" --no-superuser --no-createdb --no-createrole
psql -c "ALTER USER $SANDBOX_ID WITH PASSWORD '$SANDBOX_PASS';"
createdb "$SANDBOX_ID" --owner="$SANDBOX_ID"
psql -c "REVOKE ALL ON DATABASE $SANDBOX_ID FROM PUBLIC;"
pg_dump --no-owner --no-acl skill_ontology_builder | psql -d "$SANDBOX_ID"
psql -d "$SANDBOX_ID" -c "
  REASSIGN OWNED BY CURRENT_USER TO $SANDBOX_ID;
  REVOKE ALL ON SCHEMA public FROM PUBLIC;
  GRANT ALL ON SCHEMA public TO $SANDBOX_ID;
"

# Patch .env in clone with sandbox DB credentials
sed -i '' "s|POSTGRES_DB=.*|POSTGRES_DB=$SANDBOX_ID|" "$SANDBOX_CLONE/.env"
sed -i '' "s|POSTGRES_USER=.*|POSTGRES_USER=$SANDBOX_ID|" "$SANDBOX_CLONE/.env"
sed -i '' "s|POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=$SANDBOX_PASS|" "$SANDBOX_CLONE/.env"

# Redis: assign next DB number (best-effort separation)
REDIS_DB=$(sandbox-registry alloc-redis-db)
sed -i '' "s|REDIS_URL=.*|REDIS_URL=redis://host.docker.internal:6379/$REDIS_DB|" "$SANDBOX_CLONE/.env"

# Temporal: unique task queue
sed -i '' "s|TEMPORAL_TASK_QUEUE=.*|TEMPORAL_TASK_QUEUE=sb-$SANDBOX_ID|" "$SANDBOX_CLONE/.env"

echo "DB_PASSWORD=$SANDBOX_PASS" >> "$SANDBOX_CLONE/.devflow/sandbox.runtime"
echo "REDIS_DB=$REDIS_DB" >> "$SANDBOX_CLONE/.devflow/sandbox.runtime"
```

```bash
# .devflow/hooks/data-destroy.sh
#!/bin/bash
dropdb "$SANDBOX_ID" 2>/dev/null || true
dropuser "$SANDBOX_ID" 2>/dev/null || true
source "$SANDBOX_CLONE/.devflow/sandbox.runtime" 2>/dev/null || true
sandbox-registry free-redis-db "${REDIS_DB:-}" 2>/dev/null || true
```

### Example: Rails + MySQL project

```bash
# .devflow/hooks/data-create.sh
#!/bin/bash
mysql -e "CREATE DATABASE sb_$SANDBOX_ID"
mysql -e "CREATE USER 'sb_$SANDBOX_ID'@'%' IDENTIFIED BY '$SANDBOX_PASS'"
mysql -e "GRANT ALL ON sb_$SANDBOX_ID.* TO 'sb_$SANDBOX_ID'@'%'"
mysqldump source_db | mysql sb_$SANDBOX_ID
```

### Example: SQLite project

```bash
# .devflow/hooks/data-create.sh
#!/bin/bash
cp "$SANDBOX_PROJECT/db.sqlite3" "$SANDBOX_CLONE/db.sqlite3"
```

## Auth and State Model

### Principle: Credentials Never Persisted to /app

Raw credentials (SSH keys, OAuth tokens, API keys) are **never written** to `/app/.devflow/` or any persistent storage. They exist only in:
- `/auth/*` — read-only mounts from host
- `$HOME` — tmpfs (ephemeral, per-container, lost on restart)

Only non-credential init artifacts are persisted to `/app/.devflow/`:
- `/app/.devflow/init.ok` — durable marker for deps/migrations
- `/app/.devflow/mcp/settings.json` — translated MCP config (no secrets — env vars provide API keys at runtime)
- `/app/.devflow/on_create.started`, `/app/.devflow/on_create.ok` — hook state

**Note on .env files:** The project's `.env` files are copied into the clone directory and contain app-level secrets (DB password, Django SECRET_KEY, etc.). These are necessary for Django to run but are scoped to the sandbox's own database. They are cleaned up on `sandbox-down`. This is the same trust model as the developer's own working copy.

### Two-Phase Approach: Persistent Init + Per-Start Bootstrap

1. **`sandbox-init` service** (runs once): does heavy one-time work. Has NO auth mounts — only `/app`:
   - Install dependencies (`uv sync`) — persisted in `/app` (venv/node_modules)
   - Run migrations — persisted in DB
   - Run `on_create` hooks
   - Write `/app/.devflow/init.ok`
   - Note: MCP config is pre-sanitized by host-side `sandbox-mcp-sync.sh` (step 9 of sandbox-up) and already present at `/app/.devflow/mcp/settings.json` before init starts

2. **Per-container entrypoint** (runs on every start): copies credentials from ro mounts to ephemeral `$HOME`:
   ```bash
   # Auth: copy from read-only /auth/* directly to tmpfs $HOME
   # Never persisted to /app — only lives in ephemeral tmpfs
   cp -a /auth/claude/. $HOME/.claude/ 2>/dev/null || true
   ...
   exec "$@"
   ```

This way:
- Credentials live only in tmpfs — disappear on container stop
- No credential residue on `cleanup_failed` or in the clone directory
- `/app/.devflow/` contains only non-sensitive init state

### Compose Service Model

```yaml
services:
  sandbox-init:
    # Init: NO auth mounts at all. MCP config is pre-sanitized on host
    # by sandbox-up.sh and written to /app/.devflow/mcp/ before
    # containers start. sandbox-init never sees raw host MCP config.
    image: ${SANDBOX_IMAGE}
    volumes:
      - ${CLONE_PATH}:/app
    tmpfs:
      - /tmp
      - /home/dev-user
    environment: &sandbox-env-init
      # Init-only env: app-level vars (DB connection, Django settings).
      # Does NOT include forward_env secrets (EXA_API_KEY, GITHUB_TOKEN, etc.)
      # — those go only to the agent container (django).
      # Hooks (deps-install, migrate, on-create) are script files, not env vars.
    command: /sandbox-init.sh
    read_only: true
    cap_drop: [ALL]
    security_opt: [no-new-privileges]

  django:
    # Django is the agent container — gets auth mounts for Claude/Codex/git
    image: ${SANDBOX_IMAGE}
    depends_on:
      sandbox-init:
        condition: service_completed_successfully
    volumes:
      - ${CLONE_PATH}:/app
      - ~/.claude:/auth/claude:ro
      - ~/.codex/auth.json:/auth/codex/auth.json:ro
      - ~/.config/gh:/auth/gh:ro
      # SSH key mount (if configured)
    tmpfs:
      - /tmp
      - /home/dev-user
    environment: *sandbox-env
    entrypoint: /sandbox-bootstrap.sh
    command: /start
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8000/health/"]
      interval: 5s
      retries: 12
    read_only: true
    cap_drop: [ALL]
    security_opt: [no-new-privileges]
    ports:
      - "${DJANGO_PORT}:8000"

  celeryworker:
    # Celeryworker: NO auth mounts, NO credential env vars
    image: ${SANDBOX_IMAGE}
    depends_on:
      sandbox-init:
        condition: service_completed_successfully
    volumes:
      - ${CLONE_PATH}:/app
    tmpfs:
      - /tmp
      - /home/dev-user
    environment: &sandbox-env-worker
      # Only app-level env vars (DB, Redis, Temporal, Django settings)
      # forward_env secrets (EXA_API_KEY, GITHUB_TOKEN, etc.) are NOT set here
      # See sandbox-up.sh: generates two env blocks — agent and worker
    entrypoint: /sandbox-bootstrap.sh
    command: /start-celeryworker
    read_only: true
    cap_drop: [ALL]
    security_opt: [no-new-privileges]
```

### sandbox-bootstrap.sh (runs on every container start)

```bash
#!/bin/bash
set -e

mkdir -p $HOME/.claude $HOME/.codex $HOME/.config/gh

# Copy credentials from read-only /auth/ mounts directly to tmpfs $HOME.
# These mounts only exist on containers that need them (django only).
# On celeryworker, /auth/ doesn't exist — all copies silently skip.
cp -a /auth/claude/. $HOME/.claude/ 2>/dev/null || true
cp -a /auth/codex/. $HOME/.codex/ 2>/dev/null || true
cp -a /auth/gh/. $HOME/.config/gh/ 2>/dev/null || true

# SSH: only a specific key is mounted (not entire ~/.ssh)
if [ -d /auth/ssh ]; then
  mkdir -p $HOME/.ssh
  # Copy only regular files (keys, known_hosts, config) — skip symlinks/sockets
  find /auth/ssh -maxdepth 1 -type f -exec cp {} $HOME/.ssh/ \;
  chmod 700 $HOME/.ssh
  # Set permissions per file type
  find $HOME/.ssh -name '*.pub' -exec chmod 644 {} \;
  find $HOME/.ssh -name 'known_hosts' -exec chmod 644 {} \;
  find $HOME/.ssh ! -name '*.pub' ! -name 'known_hosts' ! -name 'config' \
    -type f -exec chmod 600 {} \;
  chmod 644 $HOME/.ssh/config 2>/dev/null || true
fi

# Git identity: synthesize minimal .gitconfig (never copy raw host gitconfig)
if [ -n "$GIT_USER_NAME" ] || [ -n "$GIT_USER_EMAIL" ]; then
  cat > $HOME/.gitconfig <<GITEOF
[user]
    name = ${GIT_USER_NAME}
    email = ${GIT_USER_EMAIL}
GITEOF
fi

# MCP config (non-secret, persisted in /app/.devflow/ by sandbox-init)
if [ -f /app/.devflow/mcp/settings.json ]; then
  cp /app/.devflow/mcp/settings.json $HOME/.claude/settings.json
fi

exec "$@"
```

### sandbox-init.sh (runs once)

```bash
#!/bin/bash
set -e

# Skip one-time work if already done (durable marker)
if [ -f /app/.devflow/init.ok ]; then
  echo "[sandbox-init] Already initialized, skipping."
  exit 0
fi

echo "[sandbox-init] Starting first-time initialization..."
mkdir -p /app/.devflow

# 1. Run deps-install hook (if present)
if [ -x /app/.devflow/hooks/deps-install.sh ]; then
  echo "[sandbox-init] Installing dependencies..."
  /app/.devflow/hooks/deps-install.sh
fi

# 2. Run migrate hook (if present)
if [ -x /app/.devflow/hooks/migrate.sh ]; then
  echo "[sandbox-init] Running migrations..."
  /app/.devflow/hooks/migrate.sh
fi

# 3. Run on-create hook (if present, with state tracking)
if [ -x /app/.devflow/hooks/on-create.sh ]; then
  echo "[sandbox-init] Running on-create hook..."
  touch /app/.devflow/on_create.started
  /app/.devflow/hooks/on-create.sh
  touch /app/.devflow/on_create.ok
fi

# 4. Durable marker (guards deps/migrations — hook state tracked separately)
touch /app/.devflow/init.ok
echo "[sandbox-init] First-time initialization complete."
```

### No sandbox-persist-auth.sh Needed

Credentials are **never persisted** to `/app/.devflow/`. The `sandbox-bootstrap.sh` entrypoint copies directly from `/auth/*` (ro mounts) to `$HOME` (tmpfs) on every container start. This means:
- No credential files on disk after container stops
- No residue on `cleanup_failed`
- `/auth/*` mounts only present on containers that need them (django only)

## MCP Inheritance

All MCP servers run **inside** the sandbox container.

`sandbox-mcp-sync.sh` runs **on the host** (inside `sandbox-up.sh`, step 9), NOT inside any container. This ensures branch-controlled code never sees raw host MCP config:

1. Read host MCP config from `~/.claude/settings.json` (host filesystem, not mounted)
2. Filter via allowlist/blocklist from sandbox.yaml
3. **Strip inline secrets** — remove literal `env` values. Replace with `${ENV_VAR_NAME}` references that resolve at runtime from the container's environment. Skip entries with un-convertible token-bearing `args`.
4. Rewrite host paths → container paths (`~/project` → `/app`)
5. Write sanitized config to `{clone_path}/.devflow/mcp/settings.json`

**Secret enforcement:** The written MCP config must not contain any literal API keys, tokens, or passwords. `sandbox-mcp-sync.sh` validates this before writing. The sanitization runs on the host before any container starts — sandbox-branch code never has access to the raw host config.

**Inside containers:** `sandbox-bootstrap.sh` copies the pre-sanitized `/app/.devflow/mcp/settings.json` to `$HOME/.claude/settings.json`. Actual secret values (e.g., `EXA_API_KEY`) are provided via env vars on the django (agent) container only.

### MCP Server Categories

| Category | Example | Strategy |
|----------|---------|----------|
| API-based | exa, Atlassian | Copy as-is, env vars from `forward_env` |
| Browser-based | Playwright | Rewrite to use container's Chromium |
| Filesystem-based | filesystem MCP | Rewrite paths to `/app` |
| Host-dependent | custom local tools | Skip with warning |

## Repo Split

### devflow/

```
devflow/
├── sandbox/
│   ├── Dockerfile.sandbox
│   ├── docker-compose.sandbox.yml    # Template
│   ├── sandbox-init.sh               # One-time: deps, migrate, hooks (no auth/MCP)
│   ├── sandbox-bootstrap.sh          # Per-container: auth → $HOME, then exec
│   ├── sandbox-mcp-sync.sh           # Translate host MCP config (no secrets)
│   ├── scripts/
│   │   ├── sandbox-up.sh
│   │   ├── sandbox-down.sh
│   │   ├── sandbox-list.sh
│   │   └── sandbox-exec.sh
│   ├── templates/
│   │   └── sandbox.project.yaml
│   └── README.md
├── skills/
│   ├── devflow-sandbox/SKILL.md         # Skill: sandbox lifecycle (up/down/list)
│   └── devflow-sandbox-setup/SKILL.md   # Skill: project onboarding wizard
└── config.default.yaml
```

### {project}/.devflow/

```
{project}/
├── .devflow/
│   ├── hooks/                # Project-specific hook scripts
│   │   ├── data-create.sh   # Create isolated data (DB, cache, queues)
│   │   ├── data-destroy.sh  # Destroy isolated data
│   │   ├── deps-install.sh  # Install dependencies
│   │   ├── migrate.sh       # Run migrations
│   │   ├── on-create.sh     # Post-init setup (optional)
│   │   ├── on-destroy.sh    # Pre-teardown cleanup (optional)
│   │   └── healthcheck.sh   # Verify sandbox ready
│   ├── sandbox.yaml
│   └── sandbox.env           # gitignored forever
├── .gitignore                # + .devflow/sandbox.env
└── docker-compose.local.yml
```

## Project Configuration: sandbox.yaml

```yaml
# --- PROJECT ---
project_slug: sk                # short unique ID for this project

# --- BASE IMAGE ---
base_image: skill_ontology_builder_local_django
# Contract: Debian-based, dev-user (uid 1000), Python, Node.js
# DB-specific tools (e.g., postgresql-client) should be in the base image, not here

# --- COMPOSE ---
compose_file: docker-compose.local.yml
shared_services: [postgres, redis, temporal_server]

sandbox_services:
  django:
    command: /start
    healthcheck: "curl -f http://localhost:8000/health/ || exit 1"
  celeryworker:
    command: /start-celeryworker

# --- ENV FILES ---
env_files:
  copy: [.env, .envs/.local/.django, .envs/.local/.postgres]
  # Patching is handled by hooks/data-create.sh (project-specific)

# --- HOOKS ---
# All hooks are optional. Scripts must be executable.
# devflow passes SANDBOX_ID, SANDBOX_BRANCH, SANDBOX_PROJECT, SANDBOX_CLONE as env.
# Hook scripts dir, relative to project root.
# TRUST: hooks are read from `git show main:.devflow/hooks/` (same trusted ref
# as sandbox.yaml and docker-compose). Host-executed hooks (data-create.sh,
# data-destroy.sh, healthcheck.sh) NEVER come from the sandbox branch.
hooks_dir: .devflow/hooks

# --- HOST ENV FORWARDING ---
forward_env: [EXA_API_KEY, JIRA_API_TOKEN, GITHUB_TOKEN, "LITELLM_PROXY_*", "AGNO_*"]

# --- AUTH (read-only at /auth/) ---
# Auth mounts — mounted read-only at /auth/ inside containers that need them.
# NOTE: ~/.ssh and ~/.gitconfig are NOT forwarded by default (security risk).
# Use git_ssh_key to forward a specific key, and git_identity for user.name/email.
forward_auth: [~/.claude, ~/.codex/auth.json, ~/.config/gh]

# --- GIT AUTH ---
git:
  # SSH key for git operations inside sandbox.
  # Default: not set (git uses HTTPS via gh CLI auth).
  # If set, only THIS specific key file is forwarded (not entire ~/.ssh/).
  ssh_key: ""                    # e.g., "~/.ssh/id_ed25519"
  # known_hosts: forwarded automatically if ssh_key is set
  # Git identity (for commits). Synthesized into a minimal .gitconfig.
  # Raw ~/.gitconfig is NEVER copied (may contain host-specific credential
  # helpers, includes, gpg config, hooks, etc. that break in container).
  user_name: ""                  # e.g., "Yuriy Kuzin"
  user_email: ""                 # e.g., "yuriy@studytube.nl"
  # If empty, sandbox-up.sh reads from host via:
  #   git config --global user.name / git config --global user.email
  # and passes values as GIT_USER_NAME / GIT_USER_EMAIL env vars to container.
  # The raw ~/.gitconfig file is NEVER mounted or copied.

# --- MCP ---
mcp_inherit: true
mcp_filter:
  allow: []
  block: []

# Hooks are executable scripts in .devflow/hooks/ (see hooks_dir above).
# No inline hook commands in sandbox.yaml — use script files instead.
```

## Sandbox Lifecycle

### sandbox-up.sh

```
sandbox-up.sh \
  --project /path/to/skills-ontology \
  --branch story/ONTO-123/new-skill-crud \
  --agent claude
```

**Steps (with pre-registration, locked allocation, and trap-backed rollback):**

1. **Parse config from MAIN BRANCH** — read `{project}/.devflow/sandbox.yaml` AND `{project}/docker-compose.local.yml` (the base compose file) from the project's default branch via `git show main:.devflow/sandbox.yaml` and `git show main:docker-compose.local.yml` (immutable ref, not the mutable working tree), NOT from the sandbox clone. This prevents a malicious branch from widening `forward_env`, `forward_auth`, `base_image`, `hooks`, adding `privileged` mounts, or injecting services. The sandbox branch only controls application code inside `/app`. The compose override generated by devflow further restricts any base compose settings (forces `read_only: true`, `cap_drop: ALL`, etc.).
2. **Generate sandbox ID** — `{project_slug}-{ticket}-{random6}`
3. **Locked registration phase** (runs as a subshell holding the lock):
   ```bash
   (
     flock -n 9 || exit 1
     # Check registry — if ID exists and is running, exit 0
     # Pre-register — write status: creating
     # Allocate resources — Redis DB, host port
     # Write registry atomically (rename)
   ) 9>~/.cache/devflow/registry.lock
   ```
   Lock is released when subshell exits — before any other work.
4. **Install rollback trap** — `trap 'sandbox-cleanup-internal $ID' ERR EXIT` (calls internal cleanup function that does NOT reacquire the lock for resource-freeing — it uses a separate `--skip-lock` path or inline cleanup)
5. **Clone repo** — `git clone --reference ...`
6. **Copy .env files** — from project root to clone
7. **Stage trusted hooks** — extract hooks from trusted ref into TWO locations:
   - **Host-side:** `{sandbox_root}/.hooks-{id}/` (outside the clone, not accessible from container). Host-executed hooks (`data-create.sh`, `data-destroy.sh`, `healthcheck.sh`) always run from here. Cannot be tampered with by sandbox code.
   - **Container-side:** `{clone}/.devflow/hooks/` (inside /app, writable). Container-executed hooks (`deps-install.sh`, `migrate.sh`, `on-create.sh`) run from here. These hooks run project code that the sandbox already has write access to — the threat model does not protect against sandbox self-modification.
   - **Teardown hooks** (`on-destroy.sh`, `data-destroy.sh`) run from the **host-side** trusted path, never from /app.
8. **Run `hooks/data-create.sh`** (on host, from host-side trusted path) — project-specific data isolation.
9. **Build sandbox image** — cached across sandboxes
10. **Sanitize MCP config (on host)** — `sandbox-mcp-sync.sh` strips inline secrets, writes to `{clone}/.devflow/mcp/settings.json`
11. **Generate compose override** — base compose from main branch (trusted), overlay forces security constraints
12. **Docker compose up** — `sandbox-init` runs `hooks/deps-install.sh`, `hooks/migrate.sh`, `hooks/on-create.sh` → then `django` + `celeryworker` start
13. **Run `hooks/healthcheck.sh`** (on host) — or default `curl` healthcheck
14. **Update registry** — `status: running` (acquire lock, atomic write, release)
15. **Clear trap**
16. **Start agent** — `docker exec -it ... claude --dangerously-skip-permissions`

**Deadlock prevention:** The lock is only held during the registration subshell (step 3) and the final status update (step 14). The rollback trap (step 4) uses an internal cleanup path that does not reacquire the registry lock — it cleans up Docker/DB/filesystem resources directly, then updates the registry in a separate locked section after cleanup is complete.

**On failure:** the trap cleans up whatever was partially created (DB, containers, clone), then acquires the lock briefly to deregister or mark as `cleanup_failed`.

### sandbox-down.sh (idempotent)

```
sandbox-down.sh --id sk-onto123-a1b2c3
```

1. **Read registry** (brief lock: acquire, read, release) — get sandbox metadata
2. **Stop all sandbox services** — `docker compose stop` (stops all services in the compose project, not hardcoded names). This prevents running services from touching DB/Redis while teardown proceeds. Uses sandbox's compose project name so only sandbox services are affected. Skip if services not up.
3. **Run `hooks/on-destroy.sh`** — via one-shot container if `/app/.devflow/on_create.started` exists. Idempotent. Runs even if main services never started.
4. **Docker compose down** — remove all containers, networks
5. **Run `hooks/data-destroy.sh`** (on host, from host-side trusted path) — project-specific teardown (drop DB, free Redis, etc.)
6. **Remove clone** — `rm -rf {sandbox_root}/sb-{id}`
7. **Update registry** (brief lock: acquire, update, release) — release allocated ports. If all succeeded: **deregister**. If any failed: `status: cleanup_failed`.

**Lock discipline in teardown:** The registry lock is held only for brief read/write operations (steps 1 and 7), never across slow operations (compose stop, DB drop, clone removal). This prevents one teardown from blocking concurrent sandbox creates.

Non-existent ID → no-op.

### sandbox-list.sh

```
ID                    BRANCH                              AGENT   DJANGO   DB                     REDIS  STATUS
sk-onto123-a1b2c3     story/ONTO-123/new-skill-crud       claude  :8001    sb_sk_onto123_a1b2c3   DB 1   running
sk-onto456-d4e5f6     bugfix/ONTO-456/fix-export          codex   :8002    sb_sk_onto456_d4e5f6   DB 2   running
sk-onto789-g7h8i9     story/ONTO-789/add-analytics        claude  —        —                      —      cleanup_failed
```

### Sandbox Registry

`~/.cache/devflow/registry.json` — all mutations under `flock`, writes via atomic rename.

```json
{
  "sandboxes": {
    "sk-onto123-a1b2c3": {
      "project": "/path/to/skills-ontology",
      "project_slug": "sk",
      "branch": "story/ONTO-123/new-skill-crud",
      "clone_path": "~/.cache/devflow/sandboxes/sb-sk-onto123-a1b2c3",
      "compose_project": "sb-sk-onto123-a1b2c3",
      "agent": "claude",
      "db_name": "sb_sk_onto123_a1b2c3",
      "db_user": "sb_sk_onto123_a1b2c3",
      "redis_db": 1,
      "temporal_queue": "sb-sk-onto123-a1b2c3",
      "ports": {"django": 8001},
      "created_at": "2026-03-23T14:30:00Z",
      "status": "running"
    }
  },
  "next_redis_db": 3,
  "allocated_ports": [8001, 8002]
}
```

## Dockerfile.sandbox

```dockerfile
ARG BASE_IMAGE
FROM ${BASE_IMAGE} AS sandbox

# Contract: Debian-based, dev-user (uid 1000), Python, Node.js

USER root

# System dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Playwright + Chromium
ENV PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright
RUN python -m playwright install --with-deps chromium

# Claude Code CLI
ARG CLAUDE_CODE_VERSION=1.0.33
RUN npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}

# Codex CLI
ARG CODEX_VERSION=0.115.0
RUN npm install -g @openai/codex@${CODEX_VERSION}

# GitHub CLI
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y gh \
    && rm -rf /var/lib/apt/lists/*

# MCP server packages
ARG MCP_PLAYWRIGHT_VERSION=0.3.0
ARG EXA_MCP_VERSION=1.2.0
ARG ATLASSIAN_MCP_VERSION=0.2.0
RUN npm install -g \
    @anthropic-ai/mcp-playwright@${MCP_PLAYWRIGHT_VERSION} \
    exa-mcp-server@${EXA_MCP_VERSION} \
    @anthropic-ai/mcp-atlassian@${ATLASSIAN_MCP_VERSION}

# Sandbox scripts
COPY sandbox-init.sh sandbox-bootstrap.sh sandbox-mcp-sync.sh /
RUN chmod +x /sandbox-init.sh /sandbox-bootstrap.sh /sandbox-mcp-sync.sh

RUN chown -R dev-user:dev-user /opt/ms-playwright

USER dev-user
```

## Resource Estimates (2-6 sandboxes)

| Resource | Shared (1x) | Per Sandbox | 6 Sandboxes Total |
|----------|-------------|-------------|-------------------|
| PostgreSQL server | ~200MB RAM | +50MB per DB | ~500MB |
| Redis server | ~50MB RAM | — | ~50MB |
| Temporal | ~300MB RAM | — | ~300MB |
| Django + Celery | — | ~400MB | ~2.4GB |
| Chromium (headless) | — | ~200MB (when active) | ~1.2GB |
| Disk (clone) | — | ~15MB | ~90MB |
| Sandbox image | ~2GB (shared) | — | ~2GB |
| **TOTAL** | **~2.5GB** | **~650MB** | **~6.5GB RAM** |

ARM64 (Apple Silicon): all components support `linux/arm64`.

## AI Skills

### `devflow:sandbox-setup` — Project Onboarding Wizard

AI skill that analyzes a project and generates sandbox configuration. Run once per project.

```
User: "devflow:sandbox-setup"

Agent:
  1. Reads docker-compose*.yml → detects services (postgres, redis, temporal, etc.)
  2. Reads Dockerfile → detects base image, user, language, package manager
  3. Reads .env / .env.template → detects DB vars, secret vars
  4. Reads pyproject.toml / Gemfile / package.json → detects framework
  5. Asks clarifying questions (shared services? test data strategy?)
  6. GENERATES:
     - .devflow/sandbox.yaml
     - .devflow/hooks/data-create.sh
     - .devflow/hooks/data-destroy.sh
     - .devflow/hooks/deps-install.sh
     - .devflow/hooks/migrate.sh
     - .devflow/hooks/on-create.sh (optional)
     - .devflow/hooks/on-destroy.sh (optional)
     - .devflow/hooks/healthcheck.sh
  7. Adds .devflow/sandbox.env to .gitignore
  8. User reviews and adjusts
```

### `devflow:sandbox` — Sandbox Lifecycle Skill

AI skill for day-to-day sandbox use. The primary entry point for developers.

```
User: "devflow:sandbox up --branch story/ONTO-123/new-skill-crud"
User: "spin up a sandbox for PR #892"
User: "devflow:sandbox list"
User: "devflow:sandbox down sk-onto123-a1b2c3"
```

## User Guide: How to Use Sandboxing

### First-Time Setup (once per project)

```bash
# 1. In your project, ask the AI agent to set up sandbox config:
> devflow:sandbox-setup

# 2. Agent analyzes your project and generates .devflow/ config
# 3. Review the generated files, adjust as needed
# 4. Make sure shared infrastructure is running:
docker compose -f docker-compose.local.yml up -d postgres redis
```

### Quick Flow: PR Review in Sandbox

The most common use case — review and test a PR in an isolated sandbox:

```
User: "Review PR #892 in a sandbox"

Agent (devflow:sandbox skill):
  1. Resolves PR head ref without mutating host: gh pr view 892 --json headRefName -q .headRefName
  2. Runs: sandbox-up.sh --project . --branch <pr-head-ref> --agent claude
     → clones repo, runs data-create hook, starts services
  3. Inside sandbox:
     - Reads the PR diff
     - Runs tests (pytest / manage.py test)
     - Starts Django, runs Playwright browser tests
     - Reviews code quality
  4. Reports results to user
  5. Suggests: "Sandbox sk-onto892-x1y2z3 is still running.
     Want me to clean it up, or keep it for manual testing?"

User: "Clean it up"
Agent: sandbox-down.sh --id sk-onto892-x1y2z3
  → stops services, runs data-destroy hook, removes clone
  → "Sandbox cleaned up. DB dropped, clone removed."
```

### Quick Flow: Full Devflow in Sandbox

End-to-end feature development with cross-tool review:

```
User: "devflow:run 'add caching for /skills endpoint' in a sandbox"

Agent:
  Phase 1 — PLAN (in sandbox):
    1. sandbox-up.sh --branch main --agent claude
    2. Claude brainstorms + writes plan inside sandbox
    3. Codex reviews the plan (cross-tool)

  Phase 2 — IMPLEMENT (in sandbox):
    4. Claude implements (or Codex, per config)
    5. Cross-tool code review
    6. Playwright browser tests inside sandbox

  Phase 3 — DELIVER:
    7. Agent pushes branch from sandbox, creates PR
    8. Reports results
    9. Suggests cleanup: "Want me to tear down the sandbox?"

User: "Yes, clean up"
Agent: sandbox-down.sh → clean teardown
```

### Quick Flow: Parallel Branch Testing

Test multiple branches simultaneously:

```
User: "Set up sandboxes for ONTO-123 and ONTO-456"

Agent:
  1. sandbox-up.sh --branch story/ONTO-123/... --agent claude
     → sk-onto123-a1b2c3 running on :8001
  2. sandbox-up.sh --branch bugfix/ONTO-456/... --agent codex
     → sk-onto456-d4e5f6 running on :8002
  3. Runs tests in both sandboxes in parallel
  4. Reports: "ONTO-123: 3 tests failed. ONTO-456: all passing."

User: "Clean up ONTO-456, keep ONTO-123"
Agent: sandbox-down.sh --id sk-onto456-d4e5f6
```

### Sandbox Cleanup

Sandboxes consume resources. Clean up when done:

```bash
# List active sandboxes:
sandbox-list.sh

# Clean up a specific sandbox:
sandbox-down.sh --id sk-onto123-a1b2c3

# Clean up ALL sandboxes:
sandbox-down.sh --all

# Clean up sandboxes older than 24h:
sandbox-down.sh --older-than 24h
```

**Cleanup hints the agent should provide after completing work:**

- "Sandbox `sk-onto123-a1b2c3` is still running on :8001. Want me to clean it up?"
- "You have 4 active sandboxes using ~3GB RAM. Run `sandbox-list.sh` to review."
- "Sandbox `sk-onto789-g7h8i9` has been idle for 6 hours. Consider cleaning up."

**The `devflow:sandbox` skill should always end with a cleanup suggestion.** This is enforced in the skill definition — the agent MUST either:
1. Clean up the sandbox (if user confirms)
2. List remaining sandboxes with resource usage
3. Suggest a cleanup command for later

### Minimal Flow (30-second version)

The absolute fastest path from "I want to test this branch" to "done":

```
User: "sandbox up story/ONTO-123/new-skill-crud"

→ [sandbox creates in ~60s: clone, DB, deps, migrate, services]
→ "Sandbox sk-onto123-a1b2c3 ready. Django on :8001."

User: "run tests"

→ [agent runs pytest + playwright inside sandbox]
→ "17 passed, 2 failed. See report."

User: "sandbox down"

→ [teardown in ~10s: services, DB, clone]
→ "Sandbox cleaned up."
```
