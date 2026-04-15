# Skills-Ontology Sandbox Config — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create the project-specific sandbox configuration and hook scripts for skills-ontology, enabling sandboxed development with PostgreSQL, Redis, Temporal, Django, and Celery.

**Architecture:** `.devflow/` directory in skills-ontology with sandbox.yaml config and 7 hook scripts. Hooks handle PostgreSQL role/DB creation, Redis DB allocation, Temporal task queue setup, uv dependency install, Django migrations, test org creation, and healthcheck.

**Tech Stack:** Bash, PostgreSQL client tools (createuser/createdb/psql/pg_dump), Redis, uv, Django manage.py

**Spec:** `docs/superpowers/specs/2026-03-23-sandbox-design.md` (section "Example: skills-ontology")

**Depends on:** Plan 1 (devflow sandbox infrastructure) — specifically `sandbox-registry.sh` for Redis DB allocation.

---

## File Map

```
skills-ontology/
├── .devflow/
│   ├── sandbox.yaml                # NEW — project sandbox config
│   ├── sandbox.env                 # NEW — personal secret overrides (gitignored)
│   └── hooks/
│       ├── data-create.sh          # NEW — PostgreSQL + Redis + Temporal isolation
│       ├── data-destroy.sh         # NEW — teardown DB + Redis + Temporal
│       ├── deps-install.sh         # NEW — uv sync --frozen
│       ├── migrate.sh              # NEW — manage.py migrate
│       ├── on-create.sh            # NEW — ensure_test_user + clone_org
│       ├── on-destroy.sh           # NEW — delete cloned org
│       └── healthcheck.sh          # NEW — curl Django /health/
├── .gitignore                      # MODIFY — add .devflow/sandbox.env
└── (existing files unchanged)
```

---

### Task 1: sandbox.yaml

**Files:**
- Create: `skills-ontology/.devflow/sandbox.yaml`

- [ ] **Step 1: Create the config file**

```yaml
project_slug: sk
base_image: skill_ontology_builder_local_django
compose_file: docker-compose.local.yml
shared_services: [postgres, redis, temporal_server]

sandbox_services:
  django:
    command: /start
    healthcheck: "curl -f http://localhost:8000/health/ || exit 1"
  celeryworker:
    command: /start-celeryworker

env_files:
  copy: [.env, .envs/.local/.django, .envs/.local/.postgres]

hooks_dir: .devflow/hooks

forward_env:
  - EXA_API_KEY
  - JIRA_API_TOKEN
  - GITHUB_TOKEN
  - "LITELLM_PROXY_*"
  - "AGNO_*"

forward_auth: [~/.claude, ~/.codex/auth.json, ~/.config/gh]

git:
  ssh_key: ""
  user_name: ""
  user_email: ""

mcp_inherit: true
mcp_filter:
  allow: []
  block: []
```

- [ ] **Step 2: Commit**

---

### Task 2: data-create.sh (PostgreSQL + Redis + Temporal)

**Files:**
- Create: `skills-ontology/.devflow/hooks/data-create.sh`

- [ ] **Step 1: Create the script**

```bash
#!/bin/bash
# data-create.sh — create isolated PostgreSQL DB, Redis DB, Temporal queue
# Runs on HOST. Env: SANDBOX_ID, SANDBOX_CLONE, SANDBOX_PROJECT
set -euo pipefail

echo "[data-create] Creating isolated data for sandbox: $SANDBOX_ID"

SANDBOX_PASS=$(openssl rand -hex 16)

# PostgreSQL: owned role + isolated DB
createuser "$SANDBOX_ID" --no-superuser --no-createdb --no-createrole 2>/dev/null || true
psql -c "ALTER USER \"$SANDBOX_ID\" WITH PASSWORD '$SANDBOX_PASS';"
createdb "$SANDBOX_ID" --owner="$SANDBOX_ID"
psql -c "REVOKE ALL ON DATABASE \"$SANDBOX_ID\" FROM PUBLIC;"

SOURCE_DB="skill_ontology_builder"
pg_dump --no-owner --no-acl "$SOURCE_DB" | psql -d "$SANDBOX_ID" > /dev/null

psql -d "$SANDBOX_ID" -c "
  REASSIGN OWNED BY CURRENT_USER TO \"$SANDBOX_ID\";
  REVOKE ALL ON SCHEMA public FROM PUBLIC;
  GRANT ALL ON SCHEMA public TO \"$SANDBOX_ID\";
"
psql -c "REVOKE ALL ON DATABASE \"$SOURCE_DB\" FROM \"$SANDBOX_ID\";" 2>/dev/null || true

# Patch .env (macOS sed syntax)
ENV_FILE="$SANDBOX_CLONE/.env"
if [ -f "$ENV_FILE" ]; then
  sed -i '' "s|POSTGRES_DB=.*|POSTGRES_DB=$SANDBOX_ID|" "$ENV_FILE"
  sed -i '' "s|POSTGRES_USER=.*|POSTGRES_USER=$SANDBOX_ID|" "$ENV_FILE"
  sed -i '' "s|POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=$SANDBOX_PASS|" "$ENV_FILE"
fi

# Redis: allocate DB number
REDIS_DB=$(sandbox-registry alloc-redis-db 2>/dev/null || echo "1")
sed -i '' "s|REDIS_URL=.*|REDIS_URL=redis://host.docker.internal:6379/$REDIS_DB|" "$ENV_FILE" 2>/dev/null || true
sed -i '' "s|CELERY_BROKER_URL=.*|CELERY_BROKER_URL=redis://host.docker.internal:6379/$REDIS_DB|" "$ENV_FILE" 2>/dev/null || true

# Temporal: unique task queue
TEMPORAL_QUEUE="sb-$SANDBOX_ID"
grep -q "TEMPORAL_TASK_QUEUE" "$ENV_FILE" 2>/dev/null && \
  sed -i '' "s|TEMPORAL_TASK_QUEUE=.*|TEMPORAL_TASK_QUEUE=$TEMPORAL_QUEUE|" "$ENV_FILE" || \
  echo "TEMPORAL_TASK_QUEUE=$TEMPORAL_QUEUE" >> "$ENV_FILE"

# Also patch .envs/.local/.postgres
PG_ENV="$SANDBOX_CLONE/.envs/.local/.postgres"
if [ -f "$PG_ENV" ]; then
  sed -i '' "s|POSTGRES_DB=.*|POSTGRES_DB=$SANDBOX_ID|" "$PG_ENV"
  sed -i '' "s|POSTGRES_USER=.*|POSTGRES_USER=$SANDBOX_ID|" "$PG_ENV"
  sed -i '' "s|POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=$SANDBOX_PASS|" "$PG_ENV"
fi

# Write runtime state
mkdir -p "$SANDBOX_CLONE/.devflow"
cat > "$SANDBOX_CLONE/.devflow/sandbox.runtime" <<EOF
DB_NAME=$SANDBOX_ID
DB_USER=$SANDBOX_ID
DB_PASSWORD=$SANDBOX_PASS
REDIS_DB=$REDIS_DB
TEMPORAL_QUEUE=$TEMPORAL_QUEUE
EOF

echo "[data-create] Done."
```

- [ ] **Step 2: Make executable and commit**

```bash
chmod +x .devflow/hooks/data-create.sh
git add .devflow/hooks/data-create.sh
git commit -m "feat(sandbox): add data-create hook (PostgreSQL + Redis + Temporal)"
```

---

### Task 3: data-destroy.sh

**Files:**
- Create: `skills-ontology/.devflow/hooks/data-destroy.sh`

- [ ] **Step 1: Create the script**

```bash
#!/bin/bash
# data-destroy.sh — teardown sandbox data. Runs on HOST. Best-effort.
set -uo pipefail

echo "[data-destroy] Tearing down data for sandbox: $SANDBOX_ID"

if [ -f "$SANDBOX_CLONE/.devflow/sandbox.runtime" ]; then
  source "$SANDBOX_CLONE/.devflow/sandbox.runtime"
fi

# PostgreSQL
psql -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$SANDBOX_ID';" 2>/dev/null || true
dropdb "$SANDBOX_ID" 2>/dev/null || true
dropuser "$SANDBOX_ID" 2>/dev/null || true

# Redis
if [ -n "${REDIS_DB:-}" ]; then
  redis-cli -n "$REDIS_DB" FLUSHDB 2>/dev/null || true
  sandbox-registry free-redis-db "$REDIS_DB" 2>/dev/null || true
fi

echo "[data-destroy] Done."
```

- [ ] **Step 2: Make executable and commit**

---

### Task 4: deps-install.sh and migrate.sh

- [ ] **Step 1: Create deps-install.sh** — `uv sync --frozen` inside container
- [ ] **Step 2: Create migrate.sh** — wait for DB with `pg_isready`, then `manage.py migrate --noinput`
- [ ] **Step 3: Make executable and commit**

---

### Task 5: on-create.sh and on-destroy.sh

- [ ] **Step 1: Create on-create.sh** — `ensure_test_user` + `clone_org --suffix $SANDBOX_ID` (graceful skip if commands missing)
- [ ] **Step 2: Create on-destroy.sh** — `delete_org --suffix $SANDBOX_ID` (idempotent)
- [ ] **Step 3: Make executable and commit**

---

### Task 6: healthcheck.sh

- [ ] **Step 1: Create healthcheck.sh** — curl `localhost:$PORT/health/` with 60-retry loop
- [ ] **Step 2: Make executable and commit**

---

### Task 7: .gitignore Update

**Important:** `sandbox.yaml` and `hooks/` MUST be committed to main for `git show main:` to work. Only `sandbox.env` and `sandbox.runtime` stay gitignored.

- [ ] **Step 1: Add to .gitignore**

```
# Devflow sandbox personal secrets (never committed)
.devflow/sandbox.env
.devflow/sandbox.runtime
```

- [ ] **Step 2: Commit**

---

### Task 8: Create sandbox.env (personal secrets)

- [ ] **Step 1: Create placeholder file** (gitignored, never committed)
- [ ] **Step 2: Verify it's gitignored**

---

### Task 9: Verify Django management commands exist

- [ ] **Step 1: Check `ensure_test_user`** — `grep -r "ensure_test_user" apps/`
- [ ] **Step 2: Check `clone_org` / `delete_org`** — `grep -r "clone_org\|delete_org" apps/`
- [ ] **Step 3: Document missing commands** in `.devflow/README.md` as follow-up tasks
