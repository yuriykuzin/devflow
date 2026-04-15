---
name: devflow:sandbox-setup
description: Project onboarding wizard for sandbox configuration. Analyzes a project and generates .devflow/sandbox.yaml and hook scripts. Use when setting up sandbox support for a new project.
---

# Sandbox Setup Wizard

Analyze a project and generate sandbox configuration.

## Process

### Step 1: Analyze Project

Read these files to understand the project:

1. `docker-compose*.yml` — detect services (postgres, redis, temporal, etc.)
2. `Dockerfile*` — detect base image, user, language, package manager
3. `.env` / `.env.template` — detect DB vars, secret vars
4. `pyproject.toml` / `Gemfile` / `package.json` — detect framework
5. `manage.py` / `Rakefile` / `Makefile` — detect commands

### Step 2: Ask Clarifying Questions

One at a time:
- Which services should be shared vs per-sandbox?
- What's the test data strategy? (clone DB? seed script? empty?)
- Any management commands for test user/org setup?
- Which env vars need forwarding to the agent?

### Step 3: Generate Configuration

Create these files:

```
.devflow/
├── sandbox.yaml              # Project config
└── hooks/
    ├── data-create.sh        # Create isolated data (DB, cache, queues)
    ├── data-destroy.sh       # Destroy isolated data
    ├── deps-install.sh       # Install dependencies
    ├── migrate.sh            # Run migrations
    ├── on-create.sh          # Post-init setup (optional)
    ├── on-destroy.sh         # Pre-teardown cleanup (optional)
    └── healthcheck.sh        # Verify sandbox ready
```

Use the template at `sandbox/templates/sandbox.project.yaml` as a starting point.

### Step 4: Update .gitignore

Add:
```
# Devflow sandbox personal secrets (never committed)
.devflow/sandbox.env
.devflow/sandbox.runtime
```

**Important:** `sandbox.yaml` and `hooks/` MUST be committed for `git show main:` to work.

### Step 5: User Review

Present generated files for review and adjustment.

## Hook Guidelines

### data-create.sh (runs on HOST)
- Create DB role owned by sandbox, revoke PUBLIC
- `pg_dump --no-owner --no-acl` from source → `psql` to sandbox DB
- `REASSIGN OWNED` to sandbox role
- Allocate Redis DB via `sandbox-registry alloc-redis-db`
- Patch `.env` files in clone with sandbox credentials
- Write allocated resources to `.devflow/sandbox.runtime`

### data-destroy.sh (runs on HOST)
- Source `.devflow/sandbox.runtime` for resource info
- Best-effort: `dropdb`, `dropuser`, `redis-cli FLUSHDB`

### deps-install.sh (runs in CONTAINER)
- Python: `uv sync --frozen` or `pip install -r requirements.txt`
- Node: `npm ci` or `yarn install --frozen-lockfile`

### migrate.sh (runs in CONTAINER)
- Wait for DB: `pg_isready` loop
- Run migrations: `python manage.py migrate --noinput`

### healthcheck.sh (runs on HOST)
- Retry loop: `curl -f http://localhost:$DJANGO_PORT/health/`
