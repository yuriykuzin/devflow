#!/bin/bash
# sandbox-registry.sh — atomic JSON registry with portable locking
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
LOCK_DIR="$REGISTRY_DIR/registry.lock.d"

ensure_registry() {
  mkdir -p "$REGISTRY_DIR"
  if [ ! -f "$REGISTRY_FILE" ]; then
    echo '{"sandboxes":{},"next_redis_db":1,"allocated_ports":[]}' > "$REGISTRY_FILE"
  fi
}

# Portable locking: mkdir is atomic on all POSIX systems
acquire_lock() {
  local max_wait=10 i=0
  while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    i=$((i + 1))
    if [ $i -ge $max_wait ]; then
      echo "ERROR: registry locked (timeout after ${max_wait}s)" >&2
      exit 1
    fi
    sleep 1
  done
  trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT
}

release_lock() {
  rmdir "$LOCK_DIR" 2>/dev/null || true
}

# All mutations via lock + atomic rename
locked_write() {
  local tmp="$REGISTRY_FILE.tmp.$$"
  acquire_lock
  eval "$1" < "$REGISTRY_FILE" > "$tmp"
  mv "$tmp" "$REGISTRY_FILE"
  release_lock
}

locked_read() {
  acquire_lock
  eval "$1" < "$REGISTRY_FILE"
  release_lock
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
    locked_write "jq --argjson data '$*' '.sandboxes[\"$id\"] = \$data'"
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
    # Two-step: read ports, compute next free, then write atomically
    ports_json=$(locked_read "jq -c '.allocated_ports'")
    new_port=$(echo "$ports_json" | jq '[range(8001;9000)] - . | .[0]')
    locked_write "jq '.allocated_ports += [$new_port] | .last_allocated_port = $new_port'"
    echo "$new_port"
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
