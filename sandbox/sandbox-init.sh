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
