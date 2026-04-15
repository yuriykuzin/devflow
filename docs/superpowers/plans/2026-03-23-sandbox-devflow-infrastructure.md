# Devflow Sandbox Infrastructure — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the universal sandbox engine in devflow — lifecycle scripts, Docker templates, registry, MCP sync, and AI skills that any project can use.

**Architecture:** Shell scripts orchestrate Docker Compose projects. A JSON registry tracks sandboxes with flock-based locking. Hooks delegate all project-specific logic. Two AI skills provide agent-friendly interfaces.

**Tech Stack:** Bash, Docker Compose, jq, flock, git

**Spec:** `docs/superpowers/specs/2026-03-23-sandbox-design.md`

---

## File Map

```
devflow/
├── sandbox/
│   ├── Dockerfile.sandbox              # NEW — generic sandbox image
│   ├── docker-compose.sandbox.yml      # NEW — compose template with security
│   ├── sandbox-init.sh                 # NEW — one-time init (calls project hooks)
│   ├── sandbox-bootstrap.sh            # NEW — per-container auth→$HOME entrypoint
│   ├── sandbox-mcp-sync.sh             # NEW — host-side MCP config translation
│   ├── scripts/
│   │   ├── sandbox-up.sh               # NEW — create & start sandbox
│   │   ├── sandbox-down.sh             # NEW — teardown (idempotent)
│   │   ├── sandbox-list.sh             # NEW — list active sandboxes
│   │   ├── sandbox-exec.sh             # NEW — run command in sandbox
│   │   └── sandbox-registry.sh         # NEW — registry helper (alloc/free/read/write)
│   ├── templates/
│   │   └── sandbox.project.yaml        # NEW — annotated example config
│   └── README.md                       # NEW — sandbox documentation
├── skills/
│   ├── devflow-sandbox/SKILL.md        # NEW — lifecycle skill
│   └── devflow-sandbox-setup/SKILL.md  # NEW — onboarding wizard skill
└── config.default.yaml                 # MODIFY — add sandbox section
```

---

### Task 1: Sandbox Registry Helper

The registry is the foundation — all other scripts depend on it.

**Files:**
- Create: `sandbox/scripts/sandbox-registry.sh`

- [ ] **Step 1: Create registry helper with core operations**

```bash
#!/bin/bash
# sandbox-registry.sh — atomic JSON registry with flock
# Usage:
#   sandbox-registry.sh init
#   sandbox-registry.sh read <id>
#   sandbox-registry.sh list
#   sandbox-registry.sh pre-register <id> <json-fields>
#   sandbox-registry.sh update <id> <key> <value>
#   sandbox-registry.sh deregister <id>
#   sandbox-registry.sh alloc-port
#   sandbox-registry.sh free-port <port>
#   sandbox-registry.sh alloc-redis-db
#   sandbox-registry.sh free-redis-db <db>
#   sandbox-registry.sh status <id> <status>
set -euo pipefail

REGISTRY_DIR="${DEVFLOW_SANDBOX_ROOT:-$HOME/.cache/devflow}"
REGISTRY_FILE="$REGISTRY_DIR/registry.json"
LOCK_FILE="$REGISTRY_DIR/registry.lock"

ensure_registry() {
  mkdir -p "$REGISTRY_DIR"
  if [ ! -f "$REGISTRY_FILE" ]; then
    echo '{"sandboxes":{},"next_redis_db":1,"allocated_ports":[]}' > "$REGISTRY_FILE"
  fi
}

# All mutations via flock + atomic rename
locked_write() {
  local tmp="$REGISTRY_FILE.tmp.$$"
  (
    flock -n 9 || { echo "ERROR: registry locked" >&2; exit 1; }
    cat "$REGISTRY_FILE" | eval "$1" > "$tmp"
    mv "$tmp" "$REGISTRY_FILE"
  ) 9>"$LOCK_FILE"
}

locked_read() {
  (
    flock -s 9
    cat "$REGISTRY_FILE" | eval "$1"
  ) 9>"$LOCK_FILE"
}

case "${1:-}" in
  init)
    ensure_registry
    ;;
  read)
    ensure_registry
    locked_read "jq -r '.sandboxes[\"$2\"]'"
    ;;
  list)
    ensure_registry
    locked_read "jq -r '.sandboxes'"
    ;;
  pre-register)
    ensure_registry
    id="$2"; shift 2
    locked_write "jq '.sandboxes[\"$id\"] = ($* | fromjson)'"
    ;;
  update)
    ensure_registry
    locked_write "jq '.sandboxes[\"$2\"].$3 = \"$4\"'"
    ;;
  status)
    ensure_registry
    locked_write "jq '.sandboxes[\"$2\"].status = \"$3\"'"
    ;;
  deregister)
    ensure_registry
    locked_write "jq 'del(.sandboxes[\"$2\"])'"
    ;;
  alloc-port)
    ensure_registry
    # Atomic read-modify-write: find next port AND register it
    locked_write "jq '
      (.allocated_ports) as \$ports |
      (8001 | until(. as \$p | \$ports | index(\$p) | not); . + 1)) as \$new |
      .allocated_ports += [\$new] |
      .last_allocated_port = \$new
    '"
    locked_read "jq -r '.last_allocated_port'"
    ;;
  free-port)
    ensure_registry
    locked_write "jq '.allocated_ports -= [$2]'"
    ;;
  alloc-redis-db)
    ensure_registry
    db=$(locked_read "jq -r '.next_redis_db'")
    locked_write "jq '.next_redis_db = ($db + 1)'"
    echo "$db"
    ;;
  free-redis-db)
    # Redis DB numbers are not reused (simple increment). No-op for now.
    ;;
  *)
    echo "Usage: sandbox-registry.sh {init|read|list|pre-register|update|status|deregister|alloc-port|free-port|alloc-redis-db|free-redis-db}" >&2
    exit 1
    ;;
esac
```

- [ ] **Step 2: Test registry manually**

```bash
cd /Users/studytube/studytube/tmp/devflow
chmod +x sandbox/scripts/sandbox-registry.sh
sandbox/scripts/sandbox-registry.sh init
sandbox/scripts/sandbox-registry.sh alloc-port
sandbox/scripts/sandbox-registry.sh list
cat ~/.cache/devflow/registry.json
```
Expected: JSON with empty sandboxes, port 8001 allocated.

- [ ] **Step 3: Commit**

```bash
git add sandbox/scripts/sandbox-registry.sh
git commit -m "feat(sandbox): add registry helper with flock-based locking"
```

---

### Task 2: Dockerfile.sandbox

**Files:**
- Create: `sandbox/Dockerfile.sandbox`

- [ ] **Step 1: Create the Dockerfile**

Per spec — extends any base image, adds AI CLIs + Playwright + gh + MCP packages. Pinned versions. Copies init/bootstrap scripts.

```dockerfile
ARG BASE_IMAGE
FROM ${BASE_IMAGE} AS sandbox

USER root

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    && rm -rf /var/lib/apt/lists/*

ENV PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright
RUN python -m playwright install --with-deps chromium

ARG CLAUDE_CODE_VERSION=1.0.33
RUN npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}

ARG CODEX_VERSION=0.115.0
RUN npm install -g @openai/codex@${CODEX_VERSION}

RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y gh \
    && rm -rf /var/lib/apt/lists/*

ARG MCP_PLAYWRIGHT_VERSION=0.3.0
ARG EXA_MCP_VERSION=1.2.0
ARG ATLASSIAN_MCP_VERSION=0.2.0
RUN npm install -g \
    @anthropic-ai/mcp-playwright@${MCP_PLAYWRIGHT_VERSION} \
    exa-mcp-server@${EXA_MCP_VERSION} \
    @anthropic-ai/mcp-atlassian@${ATLASSIAN_MCP_VERSION}

COPY sandbox-init.sh sandbox-bootstrap.sh sandbox-mcp-sync.sh /
RUN chmod +x /sandbox-init.sh /sandbox-bootstrap.sh /sandbox-mcp-sync.sh

RUN chown -R dev-user:dev-user /opt/ms-playwright

USER dev-user
```

- [ ] **Step 2: Commit**

```bash
git add sandbox/Dockerfile.sandbox
git commit -m "feat(sandbox): add Dockerfile.sandbox with AI CLIs and Playwright"
```

---

### Task 3: sandbox-init.sh and sandbox-bootstrap.sh

**Files:**
- Create: `sandbox/sandbox-init.sh`
- Create: `sandbox/sandbox-bootstrap.sh`

- [ ] **Step 1: Create sandbox-init.sh** — runs once inside container, calls project hooks from `/app/.devflow/hooks/`, no auth mounts. Full code in spec section "sandbox-init.sh".

- [ ] **Step 2: Create sandbox-bootstrap.sh** — per-container entrypoint, copies auth from `/auth/*` to tmpfs `$HOME`, synthesizes `.gitconfig`. Full code in spec section "sandbox-bootstrap.sh".

- [ ] **Step 3: Commit**

```bash
git add sandbox/sandbox-init.sh sandbox/sandbox-bootstrap.sh
git commit -m "feat(sandbox): add sandbox-init.sh and sandbox-bootstrap.sh"
```

---

### Task 4: sandbox-mcp-sync.sh

Host-side MCP config translation. Strips inline secrets, rewrites paths. Python3 for JSON processing.

**Files:**
- Create: `sandbox/sandbox-mcp-sync.sh`

- [ ] **Step 1: Create the script** — reads `~/.claude/settings.json`, filters by allowlist/blocklist, strips inline env secrets (replaces with `${VAR}` refs), rewrites host paths to `/app`, validates no literal API keys in output, writes to `{clone}/.devflow/mcp/settings.json`.

- [ ] **Step 2: Test with sample MCP config**
- [ ] **Step 3: Commit**

---

### Task 5: docker-compose.sandbox.yml Template

**Files:**
- Create: `sandbox/docker-compose.sandbox.yml`

- [ ] **Step 1: Create the compose template** — per spec's Compose Service Model. Template with `${VARIABLES}` substituted by sandbox-up.sh at runtime. Security: `read_only: true`, `cap_drop: ALL`, `no-new-privileges`. Auth mounts only on django.

- [ ] **Step 2: Commit**

---

### Task 6: sandbox-up.sh

The main orchestrator (~200 lines bash). Implements full 16-step lifecycle from spec.

**Files:**
- Create: `sandbox/scripts/sandbox-up.sh`

- [ ] **Step 1: Create sandbox-up.sh** — Key patterns:
  - Config read: `git show main:.devflow/sandbox.yaml | yq` (requires yq). Fallback: if `git show main:` fails (config not yet on main), read from working tree with a warning: "WARNING: reading config from working tree, not trusted ref"
  - ID generation: `{slug}-{ticket}-$(openssl rand -hex 3)`
  - Lock: subshell with `flock -n 9`
  - Trap: `trap 'cleanup_on_failure' ERR`
  - Clone: `git clone --reference $PROJECT --branch $BRANCH $REMOTE $CLONE_PATH`
  - Hook staging to TWO locations (host-side + container-side)
  - Compose: `docker compose -p $COMPOSE_PROJECT -f $COMPOSE_FILE up -d`

- [ ] **Step 2: Test with dry-run**
- [ ] **Step 3: Commit**

---

### Task 7: sandbox-down.sh

**Files:**
- Create: `sandbox/scripts/sandbox-down.sh`

- [ ] **Step 1: Create sandbox-down.sh** — idempotent teardown per spec. Supports `--all` and `--older-than 24h`. Brief locks only.
- [ ] **Step 2: Test no-op on nonexistent ID**
- [ ] **Step 3: Commit**

---

### Task 8: sandbox-list.sh and sandbox-exec.sh

**Files:**
- Create: `sandbox/scripts/sandbox-list.sh`
- Create: `sandbox/scripts/sandbox-exec.sh`

- [ ] **Step 1: Create sandbox-list.sh** — reads registry, formats table
- [ ] **Step 2: Create sandbox-exec.sh** — `docker exec` wrapper
- [ ] **Step 3: Commit**

---

### Task 9: Template sandbox.project.yaml

**Files:**
- Create: `sandbox/templates/sandbox.project.yaml`

- [ ] **Step 1: Create annotated template** — full example with all options documented
- [ ] **Step 2: Commit**

---

### Task 10: AI Skills

**Files:**
- Create: `skills/devflow-sandbox/SKILL.md`
- Create: `skills/devflow-sandbox-setup/SKILL.md`

- [ ] **Step 1: Create devflow:sandbox skill** — lifecycle (up/down/list), must end with cleanup suggestion
- [ ] **Step 2: Create devflow:sandbox-setup skill** — onboarding wizard, analyzes project, generates config + hooks
- [ ] **Step 3: Commit**

---

### Task 11: Update config.default.yaml and README

**Files:**
- Modify: `config.default.yaml`
- Create: `sandbox/README.md`

- [ ] **Step 1: Add sandbox section to config**
- [ ] **Step 2: Create README** — user-facing docs from spec's User Guide
- [ ] **Step 3: Commit**

---

### Task 12: Integration Test — End-to-End

Requires Plan 2 (skills-ontology hooks) to be complete first.

- [ ] **Step 1: E2E test with skills-ontology**

```bash
# Ensure shared infra running
docker compose -f docker-compose.local.yml up -d postgres redis temporal_server

# Create sandbox
sandbox-up.sh --project /path/to/skills-ontology --branch main --agent claude

# Verify
sandbox-list.sh
sandbox-exec.sh --id <id> -- uv run python manage.py check

# Teardown
sandbox-down.sh --id <id>
sandbox-list.sh  # should be empty
```

- [ ] **Step 2: Commit any fixes**
