#!/usr/bin/env bash
set -euo pipefail

# Devflow installer — cross-tool AI workflow orchestration.
#
# Usage:
#   ./install.sh              Install (symlinks point to this directory)
#   ./install.sh --deploy     Copy files to ~/.codex/devflow/ then install from there
#   ./install.sh --uninstall  Remove all devflow integrations
#   ./install.sh --status     Show current installation status
#   ./install.sh --help       Show this help
#
# Development workflow:
#   1. Edit skills/workflows in your source repo
#   2. Run ./install.sh --deploy to sync to ~/.codex/devflow/ and re-link
#   3. All agents pick up changes immediately
#
# Integration control:
#   Edit ~/.devflow/config.yaml → integrations section to enable/disable tools.
#   Comment out a tool or set it to false to skip it during install.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_DIR="$HOME/.codex/devflow"
DEVFLOW_HOME="$SCRIPT_DIR"
DEVFLOW_VERSION="0.1.0"

usage() {
  sed -n '/^# Usage:/,/^$/p' "$0" | sed 's/^# //'
  echo ""
  echo "Development workflow:"
  echo "  Edit in source repo → ./install.sh --deploy → all agents updated"
  exit 0
}

# ---------------------------------------------------------------------------
# YAML helpers — minimal parser for the integrations section
# ---------------------------------------------------------------------------

# Check if a tool integration is enabled in config.
# Returns 0 (enabled) unless explicitly disabled or commented out.
# If no config or no integrations section exists, defaults to enabled.
integration_enabled() {
  local tool="$1"
  local config="$HOME/.devflow/config.yaml"
  [ ! -f "$config" ] && return 0
  grep -q "^integrations:" "$config" || return 0
  # Tool must appear uncommented with value "true" under integrations:
  awk -v tool="$tool" '
    /^integrations:/ { in_sect=1; next }
    in_sect && /^[^ #]/ { in_sect=0 }
    in_sect && $1 == tool":" { gsub(/[ \t]/, "", $2); print $2; found=1 }
    END { if (!found) print "true" }
  ' "$config" | head -1 | grep -qi "true"
}

# ---------------------------------------------------------------------------
# Deploy: copy source → ~/.codex/devflow/, then install from there
# ---------------------------------------------------------------------------

do_deploy() {
  echo "Devflow — deploying from $SCRIPT_DIR to $INSTALL_DIR"
  echo ""

  if [ "$SCRIPT_DIR" = "$INSTALL_DIR" ]; then
    echo "  ⚠ Source and install directories are the same — use ./install.sh without --deploy"
    exit 1
  fi

  mkdir -p "$INSTALL_DIR"

  # Sync all files except .git
  rsync -a --delete \
    --exclude '.git' \
    --exclude '.git/' \
    "$SCRIPT_DIR/" "$INSTALL_DIR/"

  echo "  ✓ Files synced to $INSTALL_DIR"

  # Remove old symlinks so install re-creates them pointing to INSTALL_DIR
  rm -f "$HOME/.agents/skills/devflow"
  rm -f "$HOME/.codeium/windsurf/windsurf/workflows"/devflow-*.md 2>/dev/null || true
  rm -f "$HOME/.claude/plugins/cache/local/devflow/$DEVFLOW_VERSION" 2>/dev/null || true

  # Install from the deployed copy
  DEVFLOW_HOME="$INSTALL_DIR"
  do_install
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

symlink_or_skip() {
  local src="$1" dest="$2" label="$3"
  if [ -L "$dest" ]; then
    local current
    current="$(readlink "$dest")"
    if [ "$current" = "$src" ]; then
      echo "  ✓ $label (already linked)"
      return
    fi
    rm "$dest"
  elif [ -e "$dest" ]; then
    echo "  ⚠ $label: $dest exists but is not a symlink — skipping (remove manually)"
    return
  fi
  ln -s "$src" "$dest"
  echo "  ✓ $label"
}

# Safe JSON manipulation via python3
json_set() {
  local file="$1" py_code="$2"
  python3 -c "
import json, sys
try:
    with open('$file', 'r') as f:
        data = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    data = {}
$py_code
with open('$file', 'w') as f:
    json.dump(data, f, indent=2)
    f.write('\n')
" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------

do_install() {
  echo "Devflow — installing from $DEVFLOW_HOME"
  echo ""

  # 1. Codex CLI — one directory symlink (Codex scans ~/.agents/skills/ recursively)
  echo "Codex CLI:"
  if integration_enabled "codex"; then
    mkdir -p "$HOME/.agents/skills"
    symlink_or_skip "$DEVFLOW_HOME/skills" "$HOME/.agents/skills/devflow" \
      "~/.agents/skills/devflow → skills/"
  else
    echo "  · skipped (disabled in config)"
  fi

  # 2. Windsurf — symlink workflow files (if Windsurf is installed)
  echo "Windsurf:"
  if integration_enabled "windsurf"; then
    local windsurf_dir="$HOME/.codeium/windsurf/windsurf/workflows"
    if [ -d "$HOME/.codeium/windsurf" ]; then
      mkdir -p "$windsurf_dir"
      for wf in "$DEVFLOW_HOME"/windsurf/devflow-*.md; do
        [ -f "$wf" ] || continue
        local name
        name="$(basename "$wf")"
        symlink_or_skip "$wf" "$windsurf_dir/$name" "$name"
      done
    else
      echo "  · not detected — skipped"
    fi
  else
    echo "  · skipped (disabled in config)"
  fi

  # 3. Claude Code — register as a local plugin
  echo "Claude Code:"
  if integration_enabled "claude-code"; then
    local claude_cache_dir="$HOME/.claude/plugins/cache/local/devflow"
    local claude_plugin_dir="$claude_cache_dir/$DEVFLOW_VERSION"

    if [ -d "$HOME/.claude" ]; then
      # Symlink plugin into cache
      mkdir -p "$claude_cache_dir"
      symlink_or_skip "$DEVFLOW_HOME" "$claude_plugin_dir" \
        "~/.claude/plugins/cache/local/devflow/$DEVFLOW_VERSION → $DEVFLOW_HOME"

      # Register in installed_plugins.json
      local installed_file="$HOME/.claude/plugins/installed_plugins.json"
      if [ -f "$installed_file" ]; then
        local ts
        ts="$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"
        if json_set "$installed_file" "
key = 'devflow@local'
if key not in data.get('plugins', {}):
    data.setdefault('plugins', {})[key] = [{
        'scope': 'user',
        'installPath': '$claude_plugin_dir',
        'version': '$DEVFLOW_VERSION',
        'installedAt': '$ts',
        'lastUpdated': '$ts'
    }]
    print('  ✓ registered in installed_plugins.json')
else:
    print('  ✓ already in installed_plugins.json')
"; then
          :
        else
          echo "  ⚠ could not update installed_plugins.json"
        fi
      fi

      # Enable in settings.json
      local settings_file="$HOME/.claude/settings.json"
      if [ -f "$settings_file" ]; then
        if json_set "$settings_file" "
key = 'devflow@local'
ep = data.setdefault('enabledPlugins', {})
if key not in ep:
    ep[key] = True
    print('  ✓ enabled in settings.json')
else:
    print('  ✓ already enabled in settings.json')
"; then
          :
        else
          echo "  ⚠ could not update settings.json"
        fi
      fi
    else
      echo "  · Claude Code not detected (~/.claude missing) — skipped"
    fi
  else
    echo "  · skipped (disabled in config)"
  fi

  # 4. Cursor — reads directly from repo (plugin.json)
  echo "Cursor:"
  echo "  ✓ reads from $DEVFLOW_HOME directly (no setup needed)"

  # 5. Gemini CLI — reads GEMINI.md + gemini-extension.json from repo
  echo "Gemini CLI:"
  echo "  ✓ reads from $DEVFLOW_HOME directly (no setup needed)"

  # 6. Config — create default if missing
  echo "Config:"
  if [ ! -f "$HOME/.devflow/config.yaml" ]; then
    mkdir -p "$HOME/.devflow"
    cp "$DEVFLOW_HOME/config.default.yaml" "$HOME/.devflow/config.yaml"
    echo "  ✓ created ~/.devflow/config.yaml"
  else
    echo "  · ~/.devflow/config.yaml already exists (kept)"
  fi

  echo ""
  echo "Done. Edit ~/.devflow/config.yaml to customize (including integrations)."
}

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------

do_uninstall() {
  echo "Devflow — uninstalling"
  echo ""

  # Codex
  [ -L "$HOME/.agents/skills/devflow" ] && rm "$HOME/.agents/skills/devflow" \
    && echo "  ✓ removed ~/.agents/skills/devflow" \
    || echo "  · Codex symlink not found"

  # Windsurf
  for wf in "$HOME/.codeium/windsurf/windsurf/workflows"/devflow-*.md; do
    [ -L "$wf" ] && rm "$wf" && echo "  ✓ removed $(basename "$wf")"
  done

  # Claude Code — remove from cache, installed_plugins.json, settings.json
  local claude_cache_dir="$HOME/.claude/plugins/cache/local/devflow"
  if [ -L "$claude_cache_dir/$DEVFLOW_VERSION" ] || [ -d "$claude_cache_dir" ]; then
    rm -rf "$claude_cache_dir"
    echo "  ✓ removed Claude Code plugin cache"
  else
    echo "  · Claude Code plugin cache not found"
  fi

  local installed_file="$HOME/.claude/plugins/installed_plugins.json"
  if [ -f "$installed_file" ]; then
    json_set "$installed_file" "
if 'devflow@local' in data.get('plugins', {}):
    del data['plugins']['devflow@local']
    print('  ✓ removed from installed_plugins.json')
" || true
  fi

  local settings_file="$HOME/.claude/settings.json"
  if [ -f "$settings_file" ]; then
    json_set "$settings_file" "
if 'devflow@local' in data.get('enabledPlugins', {}):
    del data['enabledPlugins']['devflow@local']
    print('  ✓ removed from settings.json')
" || true
  fi

  # Config is NOT removed (user data)
  echo "  · ~/.devflow/config.yaml kept (remove manually if desired)"
  echo ""
  echo "Done. The repo at $DEVFLOW_HOME is untouched."
}

# ---------------------------------------------------------------------------
# Status
# ---------------------------------------------------------------------------

do_status() {
  echo "Devflow installation status"
  echo ""

  # Codex
  if [ -L "$HOME/.agents/skills/devflow" ]; then
    echo "  ✓ Codex:       $(readlink "$HOME/.agents/skills/devflow")"
  else
    echo "  ✗ Codex:       not linked"
  fi

  # Windsurf
  local wf_dir="$HOME/.codeium/windsurf/windsurf/workflows"
  if [ -d "$HOME/.codeium/windsurf" ]; then
    local found=0
    for wf in "$wf_dir"/devflow-*.md; do
      [ -L "$wf" ] && found=$((found + 1))
    done
    echo "  ✓ Windsurf:    $found workflow symlinks in $wf_dir"
  else
    echo "  · Windsurf:    not installed"
  fi

  # Claude Code
  local claude_link="$HOME/.claude/plugins/cache/local/devflow/$DEVFLOW_VERSION"
  if [ -L "$claude_link" ]; then
    echo "  ✓ Claude Code: $(readlink "$claude_link")"
    # Check registration
    local installed_file="$HOME/.claude/plugins/installed_plugins.json"
    if [ -f "$installed_file" ] && python3 -c "
import json
with open('$installed_file') as f:
    d = json.load(f)
assert 'devflow@local' in d.get('plugins', {})
" 2>/dev/null; then
      echo "               registered in installed_plugins.json"
    else
      echo "               ⚠ symlinked but NOT registered in installed_plugins.json"
    fi
  else
    echo "  ✗ Claude Code: not installed"
  fi

  # Cursor
  local install_home="$DEVFLOW_HOME"
  [ -d "$INSTALL_DIR" ] && install_home="$INSTALL_DIR"
  if [ -f "$install_home/.cursor-plugin/plugin.json" ]; then
    echo "  ✓ Cursor:      plugin.json present in $install_home"
  else
    echo "  · Cursor:      plugin.json not found"
  fi

  # Gemini
  if [ -f "$install_home/GEMINI.md" ]; then
    echo "  ✓ Gemini:      GEMINI.md present in $install_home"
  else
    echo "  · Gemini:      GEMINI.md not found"
  fi

  # Config
  if [ -f "$HOME/.devflow/config.yaml" ]; then
    echo "  ✓ Config:      ~/.devflow/config.yaml"
  else
    echo "  ✗ Config:      missing"
  fi

  # Integration settings
  echo ""
  echo "Integration settings (from ~/.devflow/config.yaml):"
  if [ -f "$HOME/.devflow/config.yaml" ] && grep -q "^integrations:" "$HOME/.devflow/config.yaml"; then
    awk '/^integrations:/,/^[^ #]/' "$HOME/.devflow/config.yaml" | head -10
  else
    echo "  (no integrations section — all tools enabled by default)"
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

case "${1:-}" in
  --deploy)    do_deploy ;;
  --uninstall) do_uninstall ;;
  --status)    do_status ;;
  --help|-h)   usage ;;
  *)           do_install ;;
esac
