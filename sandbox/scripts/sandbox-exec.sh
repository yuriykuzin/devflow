#!/bin/bash
# sandbox-exec.sh — run a command inside a sandbox container
# Usage:
#   sandbox-exec.sh --id <sandbox-id> [--service django|celeryworker] -- <command...>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REGISTRY="$SCRIPT_DIR/sandbox-registry.sh"

TARGET_ID=""
SERVICE="django"
CMD_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --id)      TARGET_ID="$2"; shift 2 ;;
    --service) SERVICE="$2"; shift 2 ;;
    --)        shift; CMD_ARGS=("$@"); break ;;
    *)         echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [ -z "$TARGET_ID" ] || [ ${#CMD_ARGS[@]} -eq 0 ]; then
  echo "Usage: sandbox-exec.sh --id <id> [--service django|celeryworker] -- <command...>" >&2
  exit 1
fi

# Read registry for compose project name
info=$("$REGISTRY" read "$TARGET_ID" 2>/dev/null) || true
if [ -z "$info" ] || [ "$info" = "null" ]; then
  echo "ERROR: Sandbox $TARGET_ID not found in registry" >&2
  exit 1
fi

compose_project=$(echo "$info" | jq -r '.compose_project // empty')
if [ -z "$compose_project" ]; then
  echo "ERROR: No compose project for sandbox $TARGET_ID" >&2
  exit 1
fi

# Get container ID for the target service
container_id=$(docker compose -p "$compose_project" ps -q "$SERVICE" 2>/dev/null)
if [ -z "$container_id" ]; then
  echo "ERROR: Service '$SERVICE' not running in sandbox $TARGET_ID" >&2
  exit 1
fi

# Determine if interactive
EXEC_FLAGS="-i"
if [ -t 0 ] && [ -t 1 ]; then
  EXEC_FLAGS="-it"
fi

docker exec $EXEC_FLAGS "$container_id" "${CMD_ARGS[@]}"
