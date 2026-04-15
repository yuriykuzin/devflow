#!/bin/bash
# sandbox-mcp-sync.sh — host-side MCP config translation
# Reads host MCP config, strips inline secrets, rewrites paths,
# writes sanitized config to {clone}/.devflow/mcp/settings.json
#
# Usage: sandbox-mcp-sync.sh <clone_path> [allow_filter] [block_filter]
#
# Env: SANDBOX_MCP_ALLOW, SANDBOX_MCP_BLOCK (comma-separated server names)
set -euo pipefail

CLONE_PATH="${1:?Usage: sandbox-mcp-sync.sh <clone_path>}"
MCP_ALLOW="${SANDBOX_MCP_ALLOW:-}"
MCP_BLOCK="${SANDBOX_MCP_BLOCK:-}"

HOST_MCP_CONFIG="$HOME/.claude/settings.json"
OUTPUT_DIR="$CLONE_PATH/.devflow/mcp"
OUTPUT_FILE="$OUTPUT_DIR/settings.json"

if [ ! -f "$HOST_MCP_CONFIG" ]; then
  echo "[mcp-sync] No host MCP config at $HOST_MCP_CONFIG — skipping."
  exit 0
fi

mkdir -p "$OUTPUT_DIR"

# Use Python3 for JSON processing (available on macOS and most Linux systems)
RESULT=$(python3 -c "
import json, sys, os, re

config_path = '$HOST_MCP_CONFIG'
allow_str = '$MCP_ALLOW'
block_str = '$MCP_BLOCK'
clone_path = '$CLONE_PATH'

with open(config_path) as f:
    config = json.load(f)

# Extract mcpServers section
mcp_servers = config.get('mcpServers', {})
if not mcp_servers:
    # Try projects key structure
    for key in config:
        if isinstance(config[key], dict) and 'mcpServers' in config[key]:
            mcp_servers = config[key]['mcpServers']
            break

if not mcp_servers:
    print('[mcp-sync] No MCP servers found in config — skipping.', file=sys.stderr)
    sys.exit(0)

allow = [s.strip() for s in allow_str.split(',') if s.strip()] if allow_str else []
block = [s.strip() for s in block_str.split(',') if s.strip()] if block_str else []

filtered = {}
for name, server_config in mcp_servers.items():
    # Apply allow filter (if set, only include matching)
    if allow and name not in allow:
        continue
    # Apply block filter
    if block and name in block:
        continue
    filtered[name] = server_config

# Sanitize: strip inline env secrets, replace with \${VAR} references
secret_pattern = re.compile(r'^(sk-|xoxb-|ghp_|gho_|glpat-|AKIA)', re.IGNORECASE)

for name, server_config in filtered.items():
    env = server_config.get('env', {})
    if isinstance(env, dict):
        sanitized_env = {}
        for key, value in env.items():
            if isinstance(value, str) and (secret_pattern.match(value) or len(value) > 40):
                # Replace with env var reference
                sanitized_env[key] = '\${' + key + '}'
            else:
                sanitized_env[key] = value
        server_config['env'] = sanitized_env

    # Rewrite host paths to /app
    args = server_config.get('args', [])
    if isinstance(args, list):
        home = os.path.expanduser('~')
        server_config['args'] = [
            a.replace(home, '/app').replace(clone_path, '/app') if isinstance(a, str) else a
            for a in args
        ]

    # Check command paths
    cmd = server_config.get('command', '')
    if isinstance(cmd, str):
        home = os.path.expanduser('~')
        server_config['command'] = cmd.replace(home, '/app').replace(clone_path, '/app')

output = {'mcpServers': filtered}
output_json = json.dumps(output, indent=2)

# Final validation: ensure no literal API keys in output
for line in output_json.split('\n'):
    for pattern in ['sk-', 'xoxb-', 'ghp_', 'gho_', 'glpat-', 'AKIA']:
        # Only flag if it looks like a real key (not a \${VAR} reference)
        stripped = line.strip().strip('\"').strip(',')
        if pattern in stripped and '\${' not in stripped and len(stripped) > 20:
            print(f'[mcp-sync] WARNING: possible secret in output line: {line.strip()[:60]}...', file=sys.stderr)

print(output_json)
")

if [ -n "$RESULT" ]; then
  echo "$RESULT" > "$OUTPUT_FILE"
  echo "[mcp-sync] Wrote sanitized MCP config to $OUTPUT_FILE"
fi
