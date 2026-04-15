#!/bin/bash
# sandbox-up.sh — create & start a sandbox environment
# Implements the 16-step lifecycle from the sandbox design spec.
#
# Usage:
#   sandbox-up.sh --project /path/to/project --branch <branch> --agent <claude|codex>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SANDBOX_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REGISTRY="$SCRIPT_DIR/sandbox-registry.sh"
SANDBOX_ROOT="${DEVFLOW_SANDBOX_ROOT:-$HOME/.cache/devflow}/sandboxes"

# ── Parse arguments ──────────────────────────────────────────────
PROJECT=""
BRANCH=""
AGENT="claude"
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project) PROJECT="$2"; shift 2 ;;
    --branch)  BRANCH="$2"; shift 2 ;;
    --agent)   AGENT="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [ -z "$PROJECT" ] || [ -z "$BRANCH" ]; then
  echo "Usage: sandbox-up.sh --project <path> --branch <branch> [--agent claude|codex] [--dry-run]" >&2
  exit 1
fi

PROJECT="$(cd "$PROJECT" && pwd)"

# ── Step 1: Parse config from MAIN BRANCH ────────────────────────
echo "[sandbox-up] Step 1: Reading config from main branch..."

read_config() {
  local key="$1" default="${2:-}"
  local val
  val=$(echo "$SANDBOX_YAML" | yq -r ".$key // \"\"" 2>/dev/null) || val=""
  if [ -z "$val" ] || [ "$val" = "null" ]; then
    echo "$default"
  else
    echo "$val"
  fi
}

if SANDBOX_YAML=$(cd "$PROJECT" && git show main:.devflow/sandbox.yaml 2>/dev/null); then
  echo "[sandbox-up] Config read from git show main:.devflow/sandbox.yaml"
else
  echo "[sandbox-up] WARNING: reading config from working tree, not trusted ref"
  SANDBOX_YAML=$(cat "$PROJECT/.devflow/sandbox.yaml")
fi

PROJECT_SLUG=$(read_config "project_slug" "proj")
BASE_IMAGE=$(read_config "base_image" "")
COMPOSE_FILE_REL=$(read_config "compose_file" "docker-compose.local.yml")
HOOKS_DIR=$(read_config "hooks_dir" ".devflow/hooks")

# Read sandbox_services
DJANGO_COMMAND=$(echo "$SANDBOX_YAML" | yq -r '.sandbox_services.django.command // "/start"')
CELERY_COMMAND=$(echo "$SANDBOX_YAML" | yq -r '.sandbox_services.celeryworker.command // "/start-celeryworker"')

# Read env_files to copy
ENV_FILES_COPY=$(echo "$SANDBOX_YAML" | yq -r '.env_files.copy[]? // empty' 2>/dev/null || true)

# Read forward_env patterns
FORWARD_ENV=$(echo "$SANDBOX_YAML" | yq -r '.forward_env[]? // empty' 2>/dev/null || true)

# Read forward_auth paths
FORWARD_AUTH=$(echo "$SANDBOX_YAML" | yq -r '.forward_auth[]? // empty' 2>/dev/null || true)

# Read git config
GIT_SSH_KEY=$(read_config "git.ssh_key" "")
GIT_USER_NAME=$(read_config "git.user_name" "")
GIT_USER_EMAIL=$(read_config "git.user_email" "")

# Read MCP config
MCP_INHERIT=$(read_config "mcp_inherit" "true")
MCP_ALLOW=$(echo "$SANDBOX_YAML" | yq -r '.mcp_filter.allow[]? // empty' 2>/dev/null | tr '\n' ',' || true)
MCP_BLOCK=$(echo "$SANDBOX_YAML" | yq -r '.mcp_filter.block[]? // empty' 2>/dev/null | tr '\n' ',' || true)

if [ -z "$BASE_IMAGE" ]; then
  echo "ERROR: base_image not set in sandbox.yaml" >&2
  exit 1
fi

# ── Step 2: Generate sandbox ID ──────────────────────────────────
echo "[sandbox-up] Step 2: Generating sandbox ID..."

# Extract ticket from branch name (e.g., ONTO-123 from story/ONTO-123/...)
TICKET=$(echo "$BRANCH" | grep -oE '[A-Z]+-[0-9]+' | head -1 | tr '[:upper:]' '[:lower:]' | tr '-' '' || echo "dev")
if [ -z "$TICKET" ]; then TICKET="dev"; fi
RANDOM_HEX=$(openssl rand -hex 3)
SANDBOX_ID="${PROJECT_SLUG}-${TICKET}-${RANDOM_HEX}"
CLONE_PATH="$SANDBOX_ROOT/$SANDBOX_ID"
COMPOSE_PROJECT="sb-${SANDBOX_ID}"

echo "[sandbox-up] Sandbox ID: $SANDBOX_ID"

# ── Step 3: Locked registration ─────────────────────────────────
echo "[sandbox-up] Step 3: Registering sandbox..."

DJANGO_PORT=$("$REGISTRY" alloc-port)
REDIS_DB=$("$REGISTRY" alloc-redis-db)

CREATED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
"$REGISTRY" pre-register "$SANDBOX_ID" "{
  \"status\": \"creating\",
  \"project\": \"$PROJECT\",
  \"project_slug\": \"$PROJECT_SLUG\",
  \"branch\": \"$BRANCH\",
  \"clone_path\": \"$CLONE_PATH\",
  \"compose_project\": \"$COMPOSE_PROJECT\",
  \"agent\": \"$AGENT\",
  \"ports\": {\"django\": $DJANGO_PORT},
  \"redis_db\": $REDIS_DB,
  \"created_at\": \"$CREATED_AT\"
}"

# ── Step 4: Rollback trap ───────────────────────────────────────
cleanup_on_failure() {
  local exit_code=$?
  echo "[sandbox-up] ERROR: Cleaning up after failure..." >&2
  # Stop containers if started
  docker compose -p "$COMPOSE_PROJECT" down 2>/dev/null || true
  # Remove clone
  rm -rf "$CLONE_PATH" 2>/dev/null || true
  # Remove host-side hooks
  rm -rf "$SANDBOX_ROOT/.hooks-$SANDBOX_ID" 2>/dev/null || true
  # Free allocated resources
  "$REGISTRY" free-port "$DJANGO_PORT" 2>/dev/null || true
  # Update registry
  "$REGISTRY" deregister "$SANDBOX_ID" 2>/dev/null || true
  echo "[sandbox-up] Cleanup complete." >&2
  exit "${exit_code:-1}"
}
trap cleanup_on_failure ERR

if [ "$DRY_RUN" = true ]; then
  echo "[sandbox-up] DRY RUN — would create sandbox $SANDBOX_ID"
  echo "  Project: $PROJECT"
  echo "  Branch: $BRANCH"
  echo "  Agent: $AGENT"
  echo "  Clone: $CLONE_PATH"
  echo "  Django port: $DJANGO_PORT"
  echo "  Redis DB: $REDIS_DB"
  echo "  Base image: $BASE_IMAGE"
  # Clean up registration
  "$REGISTRY" free-port "$DJANGO_PORT" 2>/dev/null || true
  "$REGISTRY" deregister "$SANDBOX_ID" 2>/dev/null || true
  trap - ERR
  exit 0
fi

# ── Step 5: Clone repo ──────────────────────────────────────────
echo "[sandbox-up] Step 5: Cloning repo..."

mkdir -p "$SANDBOX_ROOT"
REMOTE=$(cd "$PROJECT" && git remote get-url origin 2>/dev/null || echo "$PROJECT")
git clone --reference "$PROJECT" --branch "$BRANCH" "$REMOTE" "$CLONE_PATH"

# ── Step 6: Copy .env files ─────────────────────────────────────
echo "[sandbox-up] Step 6: Copying env files..."

if [ -n "$ENV_FILES_COPY" ]; then
  while IFS= read -r env_file; do
    [ -z "$env_file" ] && continue
    src="$PROJECT/$env_file"
    dst="$CLONE_PATH/$env_file"
    if [ -f "$src" ]; then
      mkdir -p "$(dirname "$dst")"
      cp "$src" "$dst"
      echo "  Copied: $env_file"
    else
      echo "  WARNING: $env_file not found in project" >&2
    fi
  done <<< "$ENV_FILES_COPY"
fi

# ── Step 7: Stage trusted hooks ─────────────────────────────────
echo "[sandbox-up] Step 7: Staging hooks..."

HOST_HOOKS_DIR="$SANDBOX_ROOT/.hooks-$SANDBOX_ID"
CONTAINER_HOOKS_DIR="$CLONE_PATH/.devflow/hooks"
mkdir -p "$HOST_HOOKS_DIR" "$CONTAINER_HOOKS_DIR"

# Extract hooks from trusted ref (main branch)
extract_hook() {
  local hook_name="$1"
  local hook_content
  if hook_content=$(cd "$PROJECT" && git show "main:$HOOKS_DIR/$hook_name" 2>/dev/null); then
    echo "$hook_content" > "$HOST_HOOKS_DIR/$hook_name"
    chmod +x "$HOST_HOOKS_DIR/$hook_name"
    echo "$hook_content" > "$CONTAINER_HOOKS_DIR/$hook_name"
    chmod +x "$CONTAINER_HOOKS_DIR/$hook_name"
    echo "  Staged: $hook_name"
  fi
}

for hook in data-create.sh data-destroy.sh deps-install.sh migrate.sh on-create.sh on-destroy.sh healthcheck.sh; do
  extract_hook "$hook"
done

# ── Step 8: Run data-create.sh (on host) ────────────────────────
if [ -x "$HOST_HOOKS_DIR/data-create.sh" ]; then
  echo "[sandbox-up] Step 8: Running data-create hook..."
  SANDBOX_ID="$SANDBOX_ID" \
  SANDBOX_BRANCH="$BRANCH" \
  SANDBOX_PROJECT="$PROJECT" \
  SANDBOX_CLONE="$CLONE_PATH" \
    "$HOST_HOOKS_DIR/data-create.sh"
else
  echo "[sandbox-up] Step 8: No data-create hook — skipping."
fi

# ── Step 9: Build sandbox image ─────────────────────────────────
echo "[sandbox-up] Step 9: Building sandbox image..."

SANDBOX_IMAGE="devflow-sandbox-${PROJECT_SLUG}:latest"
docker build \
  --build-arg "BASE_IMAGE=$BASE_IMAGE" \
  -t "$SANDBOX_IMAGE" \
  -f "$SANDBOX_DIR/Dockerfile.sandbox" \
  "$SANDBOX_DIR"

# ── Step 10: Sanitize MCP config ────────────────────────────────
if [ "$MCP_INHERIT" = "true" ]; then
  echo "[sandbox-up] Step 10: Sanitizing MCP config..."
  SANDBOX_MCP_ALLOW="$MCP_ALLOW" \
  SANDBOX_MCP_BLOCK="$MCP_BLOCK" \
    "$SANDBOX_DIR/sandbox-mcp-sync.sh" "$CLONE_PATH"
else
  echo "[sandbox-up] Step 10: MCP inheritance disabled — skipping."
fi

# ── Step 11: Generate compose override ───────────────────────────
echo "[sandbox-up] Step 11: Generating compose files..."

COMPOSE_DIR="$CLONE_PATH/.devflow/compose"
mkdir -p "$COMPOSE_DIR"

# Generate env files for sandbox
# Base env (shared: app-level vars)
SANDBOX_ENV_FILE="$COMPOSE_DIR/sandbox.env"
touch "$SANDBOX_ENV_FILE"

# Agent env (forward_env secrets — django only)
SANDBOX_AGENT_ENV_FILE="$COMPOSE_DIR/agent.env"
touch "$SANDBOX_AGENT_ENV_FILE"
if [ -n "$FORWARD_ENV" ]; then
  while IFS= read -r pattern; do
    [ -z "$pattern" ] && continue
    # Handle wildcard patterns like LITELLM_PROXY_*
    if [[ "$pattern" == *"*"* ]]; then
      prefix="${pattern%\*}"
      env | grep "^${prefix}" >> "$SANDBOX_AGENT_ENV_FILE" 2>/dev/null || true
    else
      val="${!pattern:-}"
      if [ -n "$val" ]; then
        echo "${pattern}=${val}" >> "$SANDBOX_AGENT_ENV_FILE"
      fi
    fi
  done <<< "$FORWARD_ENV"
fi

# Worker env (no secrets)
SANDBOX_WORKER_ENV_FILE="$COMPOSE_DIR/worker.env"
touch "$SANDBOX_WORKER_ENV_FILE"

# Git identity
if [ -z "$GIT_USER_NAME" ]; then
  GIT_USER_NAME=$(git config --global user.name 2>/dev/null || echo "")
fi
if [ -z "$GIT_USER_EMAIL" ]; then
  GIT_USER_EMAIL=$(git config --global user.email 2>/dev/null || echo "")
fi
{
  echo "GIT_USER_NAME=$GIT_USER_NAME"
  echo "GIT_USER_EMAIL=$GIT_USER_EMAIL"
} >> "$SANDBOX_AGENT_ENV_FILE"

# Generate auth-mounts compose override for django
AUTH_OVERRIDE="$COMPOSE_DIR/docker-compose.auth.yml"
cat > "$AUTH_OVERRIDE" <<EOF
services:
  django:
    volumes:
EOF

# Add auth mounts
if [ -n "$FORWARD_AUTH" ]; then
  while IFS= read -r auth_path; do
    [ -z "$auth_path" ] && continue
    expanded="${auth_path/#\~/$HOME}"
    if [ -e "$expanded" ]; then
      # Derive mount target from path
      case "$auth_path" in
        */.claude*)    target="/auth/claude" ;;
        */.codex*)     target="/auth/codex" ;;
        */.config/gh*) target="/auth/gh" ;;
        *)             target="/auth/$(basename "$auth_path")" ;;
      esac
      echo "      - ${expanded}:${target}:ro" >> "$AUTH_OVERRIDE"
    fi
  done <<< "$FORWARD_AUTH"
fi

# Add SSH key mount if configured
if [ -n "$GIT_SSH_KEY" ]; then
  expanded_key="${GIT_SSH_KEY/#\~/$HOME}"
  if [ -f "$expanded_key" ]; then
    echo "      - $(dirname "$expanded_key"):/auth/ssh:ro" >> "$AUTH_OVERRIDE"
  fi
fi

# Export variables for compose substitution
export SANDBOX_IMAGE CLONE_PATH DJANGO_PORT SANDBOX_ENV_FILE SANDBOX_AGENT_ENV_FILE SANDBOX_WORKER_ENV_FILE
export DJANGO_COMMAND CELERY_COMMAND

# ── Step 12: Docker compose up ───────────────────────────────────
echo "[sandbox-up] Step 12: Starting containers..."

# Ensure network exists
docker network create devflow-shared 2>/dev/null || true

docker compose \
  -p "$COMPOSE_PROJECT" \
  -f "$SANDBOX_DIR/docker-compose.sandbox.yml" \
  -f "$AUTH_OVERRIDE" \
  up -d

# ── Step 13: Run healthcheck ────────────────────────────────────
if [ -x "$HOST_HOOKS_DIR/healthcheck.sh" ]; then
  echo "[sandbox-up] Step 13: Running healthcheck hook..."
  SANDBOX_ID="$SANDBOX_ID" \
  SANDBOX_BRANCH="$BRANCH" \
  SANDBOX_PROJECT="$PROJECT" \
  SANDBOX_CLONE="$CLONE_PATH" \
  DJANGO_PORT="$DJANGO_PORT" \
    "$HOST_HOOKS_DIR/healthcheck.sh"
else
  echo "[sandbox-up] Step 13: Waiting for Django healthcheck..."
  for i in $(seq 1 60); do
    if curl -sf "http://localhost:$DJANGO_PORT/health/" > /dev/null 2>&1; then
      echo "  Django healthy on :$DJANGO_PORT"
      break
    fi
    if [ "$i" -eq 60 ]; then
      echo "  WARNING: Healthcheck timed out after 60 attempts" >&2
    fi
    sleep 2
  done
fi

# ── Step 14: Update registry ────────────────────────────────────
echo "[sandbox-up] Step 14: Updating registry..."
"$REGISTRY" status "$SANDBOX_ID" "running"

# ── Step 15: Clear trap ─────────────────────────────────────────
trap - ERR

# ── Step 16: Report ─────────────────────────────────────────────
echo ""
echo "=========================================="
echo " Sandbox ready: $SANDBOX_ID"
echo "=========================================="
echo "  Branch:     $BRANCH"
echo "  Agent:      $AGENT"
echo "  Django:     http://localhost:$DJANGO_PORT"
echo "  Clone:      $CLONE_PATH"
echo "  Compose:    $COMPOSE_PROJECT"
echo ""
echo "  Start agent:"
if [ "$AGENT" = "claude" ]; then
  echo "    docker exec -it \$(docker compose -p $COMPOSE_PROJECT ps -q django) claude --dangerously-skip-permissions"
else
  echo "    docker exec -it \$(docker compose -p $COMPOSE_PROJECT ps -q django) codex --full-auto"
fi
echo ""
echo "  Teardown:"
echo "    sandbox-down.sh --id $SANDBOX_ID"
echo "=========================================="
