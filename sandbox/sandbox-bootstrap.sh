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
if [ -n "${GIT_USER_NAME:-}" ] || [ -n "${GIT_USER_EMAIL:-}" ]; then
  cat > $HOME/.gitconfig <<GITEOF
[user]
    name = ${GIT_USER_NAME:-}
    email = ${GIT_USER_EMAIL:-}
GITEOF
fi

# MCP config (non-secret, persisted in /app/.devflow/ by sandbox-mcp-sync.sh)
if [ -f /app/.devflow/mcp/settings.json ]; then
  cp /app/.devflow/mcp/settings.json $HOME/.claude/settings.json
fi

exec "$@"
