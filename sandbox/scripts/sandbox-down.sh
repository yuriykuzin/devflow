#!/bin/bash
# sandbox-down.sh — idempotent sandbox teardown
# Usage:
#   sandbox-down.sh --id <sandbox-id>
#   sandbox-down.sh --all
#   sandbox-down.sh --older-than <duration>  (e.g., 24h, 2d)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REGISTRY="$SCRIPT_DIR/sandbox-registry.sh"
SANDBOX_ROOT="${DEVFLOW_SANDBOX_ROOT:-$HOME/.cache/devflow}/sandboxes"

# ── Parse arguments ──────────────────────────────────────────────
TARGET_ID=""
ALL=false
OLDER_THAN=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --id)         TARGET_ID="$2"; shift 2 ;;
    --all)        ALL=true; shift ;;
    --older-than) OLDER_THAN="$2"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [ -z "$TARGET_ID" ] && [ "$ALL" = false ] && [ -z "$OLDER_THAN" ]; then
  echo "Usage: sandbox-down.sh --id <id> | --all | --older-than <duration>" >&2
  exit 1
fi

# ── Helper: teardown a single sandbox ────────────────────────────
teardown_sandbox() {
  local id="$1"
  echo "[sandbox-down] Tearing down: $id"

  # Step 1: Read registry (brief lock)
  local info
  info=$("$REGISTRY" read "$id" 2>/dev/null) || true
  if [ -z "$info" ] || [ "$info" = "null" ]; then
    echo "[sandbox-down] Sandbox $id not found in registry — skipping."
    return 0
  fi

  local compose_project clone_path django_port
  compose_project=$(echo "$info" | jq -r '.compose_project // empty')
  clone_path=$(echo "$info" | jq -r '.clone_path // empty')
  django_port=$(echo "$info" | jq -r '.ports.django // empty')

  local failed=false

  # Step 2: Stop all sandbox services
  if [ -n "$compose_project" ]; then
    echo "  Stopping services..."
    docker compose -p "$compose_project" stop 2>/dev/null || true
  fi

  # Step 3: Run on-destroy hook (from host-side trusted path)
  local host_hooks="$SANDBOX_ROOT/.hooks-$id"
  if [ -x "$host_hooks/on-destroy.sh" ] && [ -f "${clone_path:-.}/.devflow/on_create.started" ] 2>/dev/null; then
    echo "  Running on-destroy hook..."
    SANDBOX_ID="$id" \
    SANDBOX_CLONE="$clone_path" \
      "$host_hooks/on-destroy.sh" 2>/dev/null || { echo "  WARNING: on-destroy hook failed" >&2; failed=true; }
  fi

  # Step 4: Docker compose down
  if [ -n "$compose_project" ]; then
    echo "  Removing containers..."
    docker compose -p "$compose_project" down --remove-orphans 2>/dev/null || true
  fi

  # Step 5: Run data-destroy hook (on host, from trusted path)
  if [ -x "$host_hooks/data-destroy.sh" ]; then
    echo "  Running data-destroy hook..."
    # Source sandbox.runtime for allocated resource info
    local runtime_env=""
    if [ -f "${clone_path:-.}/.devflow/sandbox.runtime" ] 2>/dev/null; then
      runtime_env=$(cat "$clone_path/.devflow/sandbox.runtime")
    fi
    (
      eval "$runtime_env" 2>/dev/null || true
      export SANDBOX_ID="$id"
      export SANDBOX_CLONE="$clone_path"
      "$host_hooks/data-destroy.sh"
    ) 2>/dev/null || { echo "  WARNING: data-destroy hook failed" >&2; failed=true; }
  fi

  # Step 6: Remove clone and host-side hooks
  if [ -n "$clone_path" ] && [ -d "$clone_path" ]; then
    echo "  Removing clone..."
    rm -rf "$clone_path"
  fi
  rm -rf "$host_hooks" 2>/dev/null || true

  # Step 7: Update registry (brief lock) — free port, deregister
  if [ -n "$django_port" ] && [ "$django_port" != "null" ]; then
    "$REGISTRY" free-port "$django_port" 2>/dev/null || true
  fi

  if [ "$failed" = true ]; then
    "$REGISTRY" status "$id" "cleanup_failed" 2>/dev/null || true
    echo "[sandbox-down] $id — cleanup_failed (some hooks failed)"
  else
    "$REGISTRY" deregister "$id" 2>/dev/null || true
    echo "[sandbox-down] $id — done."
  fi
}

# ── Main logic ───────────────────────────────────────────────────

if [ -n "$TARGET_ID" ]; then
  teardown_sandbox "$TARGET_ID"
  exit 0
fi

# Get all sandbox IDs
ALL_IDS=$("$REGISTRY" list 2>/dev/null | jq -r 'keys[]' 2>/dev/null || true)

if [ -z "$ALL_IDS" ]; then
  echo "[sandbox-down] No sandboxes found."
  exit 0
fi

if [ "$ALL" = true ]; then
  while IFS= read -r id; do
    [ -z "$id" ] && continue
    teardown_sandbox "$id"
  done <<< "$ALL_IDS"
  exit 0
fi

if [ -n "$OLDER_THAN" ]; then
  # Parse duration (e.g., 24h → 86400, 2d → 172800)
  duration_secs=0
  num="${OLDER_THAN%[hHdD]*}"
  unit="${OLDER_THAN##*[0-9]}"
  case "$unit" in
    h|H) duration_secs=$((num * 3600)) ;;
    d|D) duration_secs=$((num * 86400)) ;;
    *)   echo "ERROR: unsupported duration unit: $unit (use h or d)" >&2; exit 1 ;;
  esac

  now=$(date +%s)

  while IFS= read -r id; do
    [ -z "$id" ] && continue
    created=$("$REGISTRY" read "$id" 2>/dev/null | jq -r '.created_at // empty')
    if [ -n "$created" ]; then
      created_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$created" +%s 2>/dev/null || date -d "$created" +%s 2>/dev/null || echo 0)
      age=$((now - created_epoch))
      if [ "$age" -gt "$duration_secs" ]; then
        echo "[sandbox-down] $id is older than $OLDER_THAN (age: ${age}s)"
        teardown_sandbox "$id"
      fi
    fi
  done <<< "$ALL_IDS"
  exit 0
fi
