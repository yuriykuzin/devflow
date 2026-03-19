#!/usr/bin/env bash
set -euo pipefail

# Devflow installer — cross-tool AI workflow orchestration.
#
# Usage:
#   ./install.sh              Install for all enabled tools
#   ./install.sh --choose     Choose which tools to install for
#   ./install.sh --deploy     Copy files to ~/.codex/devflow/ then install
#   ./install.sh --uninstall  Remove all devflow integrations
#   ./install.sh --status     Show current installation status
#   ./install.sh --help       Show this help
#
# Integration control:
#   Run --choose to select tools interactively, or edit
#   ~/.devflow/config.yaml → integrations section to enable/disable tools.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_DIR="$HOME/.codex/devflow"
DEVFLOW_HOME="$SCRIPT_DIR"
DEVFLOW_VERSION="0.1.0"
CLAUDE_MKT="devflow-local"

usage() {
  sed -n '/^# Usage:/,/^$/p' "$0" | sed 's/^# //'
  echo ""
  echo "Examples:"
  echo "  ./install.sh                # Install for all detected/enabled tools"
  echo "  ./install.sh --choose       # Interactively select tools"
  echo "  ./install.sh --deploy       # Deploy to ~/.codex/devflow/ then install"
  exit 0
}

# ---------------------------------------------------------------------------
# YAML helpers
# ---------------------------------------------------------------------------

# Check if a tool integration is enabled in config.
# Returns 0 (enabled) unless explicitly disabled or commented out.
# If no config or no integrations section exists, defaults to enabled.
integration_enabled() {
  local tool="$1"
  local config="$HOME/.devflow/config.yaml"
  [ ! -f "$config" ] && return 0
  grep -q "^integrations:" "$config" || return 0
  awk -v tool="$tool" '
    /^integrations:/ { in_sect=1; next }
    in_sect && /^[^ #]/ { in_sect=0 }
    in_sect && $1 == tool":" { gsub(/[ \t]/, "", $2); print $2; found=1 }
    END { if (!found) print "true" }
  ' "$config" | head -1 | grep -qi "true"
}

# Set a tool integration in config.yaml
set_integration() {
  local tool="$1" enabled="$2"
  local config="$HOME/.devflow/config.yaml"
  [ ! -f "$config" ] && return

  if [ "$enabled" = "true" ]; then
    # Uncomment or set to true
    if grep -qE "^\s*#\s*${tool}:" "$config"; then
      sed -i.bak "s/^[[:space:]]*#[[:space:]]*${tool}:.*$/  ${tool}: true/" "$config"
      rm -f "$config.bak"
    elif grep -qE "^\s*${tool}:" "$config"; then
      sed -i.bak "s/^\([[:space:]]*\)${tool}:.*$/\1${tool}: true/" "$config"
      rm -f "$config.bak"
    fi
  else
    # Comment out
    if grep -qE "^\s*${tool}:\s*true" "$config"; then
      sed -i.bak "s/^\([[:space:]]*\)${tool}: true/\1# ${tool}: true/" "$config"
      rm -f "$config.bak"
    fi
  fi
}

# ---------------------------------------------------------------------------
# Interactive tool selection
# ---------------------------------------------------------------------------

do_choose() {
  echo "Devflow — choose integrations"
  echo ""

  # Ensure config exists first
  if [ ! -f "$HOME/.devflow/config.yaml" ]; then
    mkdir -p "$HOME/.devflow"
    cp "$DEVFLOW_HOME/config.default.yaml" "$HOME/.devflow/config.yaml"
  fi

  # Ensure integrations section exists
  if ! grep -q "^integrations:" "$HOME/.devflow/config.yaml"; then
    cat >> "$HOME/.devflow/config.yaml" << 'EOF'

# Tool integrations — comment out to skip during install/uninstall.
integrations:
  codex: true
  claude-code: true
  windsurf: true
  # cursor: true
  # gemini: true
EOF
  fi

  local tools=("codex" "claude-code" "windsurf")
  local labels=("Codex CLI" "Claude Code" "Windsurf")
  local detected=()

  # Detect available tools
  command -v codex >/dev/null 2>&1 && detected+=("codex") || true
  [ -d "$HOME/.claude" ] && detected+=("claude-code") || true
  [ -d "$HOME/.codeium/windsurf" ] && detected+=("windsurf") || true

  echo "Available tools:"
  echo ""
  for i in "${!tools[@]}"; do
    local tool="${tools[$i]}"
    local label="${labels[$i]}"
    local status="  "
    local det=""

    if integration_enabled "$tool"; then
      status="✓ "
    fi

    # Check if detected
    for d in "${detected[@]}"; do
      [ "$d" = "$tool" ] && det=" (detected)" && break
    done

    echo "  $((i+1)). [$status] $label$det"
  done

  echo ""
  echo "Enter numbers to toggle (e.g. '1 3'), 'all', 'none', or Enter to confirm:"
  read -r choice

  case "$choice" in
    all)
      for tool in "${tools[@]}"; do
        set_integration "$tool" "true"
      done
      echo "  ✓ All tools enabled"
      ;;
    none)
      for tool in "${tools[@]}"; do
        set_integration "$tool" "false"
      done
      echo "  ✓ All tools disabled"
      ;;
    "")
      echo "  ✓ Keeping current selections"
      ;;
    *)
      for num in $choice; do
        local idx=$((num - 1))
        if [ "$idx" -ge 0 ] && [ "$idx" -lt "${#tools[@]}" ]; then
          local tool="${tools[$idx]}"
          if integration_enabled "$tool"; then
            set_integration "$tool" "false"
            echo "  · Disabled ${labels[$idx]}"
          else
            set_integration "$tool" "true"
            echo "  ✓ Enabled ${labels[$idx]}"
          fi
        fi
      done
      ;;
  esac

  echo ""
  do_install
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

  rsync -a --delete \
    --exclude '.git' \
    --exclude '.git/' \
    "$SCRIPT_DIR/" "$INSTALL_DIR/"

  echo "  ✓ Files synced to $INSTALL_DIR"

  # Remove old installations so re-install points to INSTALL_DIR
  rm -f "$HOME/.agents/skills/devflow"
  rm -f "$HOME/.codeium/windsurf/windsurf/workflows"/devflow-*.md 2>/dev/null || true
  rm -rf "$HOME/.claude/plugins/cache/$CLAUDE_MKT/devflow" 2>/dev/null || true

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

  # 1. Codex CLI
  echo "Codex CLI:"
  if integration_enabled "codex"; then
    if command -v codex >/dev/null 2>&1 || [ -d "$HOME/.agents" ]; then
      mkdir -p "$HOME/.agents/skills"
      symlink_or_skip "$DEVFLOW_HOME/skills" "$HOME/.agents/skills/devflow" \
        "~/.agents/skills/devflow → skills/"
    else
      echo "  · not detected — skipped"
    fi
  else
    echo "  · skipped (disabled in config)"
  fi

  # 2. Windsurf
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

  # 3. Claude Code — proper marketplace-based installation
  #    Creates a local marketplace with marketplace.json, copies plugin
  #    to cache, and registers in installed_plugins.json + settings.json.
  echo "Claude Code:"
  if integration_enabled "claude-code"; then
    if [ -d "$HOME/.claude" ]; then
      local mkt_dir="$HOME/.claude/plugins/marketplaces/$CLAUDE_MKT"
      local cache_dir="$HOME/.claude/plugins/cache/$CLAUDE_MKT/devflow"
      local plugin_dir="$cache_dir/$DEVFLOW_VERSION"
      local plugin_key="devflow@$CLAUDE_MKT"

      # Create marketplace with proper marketplace.json
      mkdir -p "$mkt_dir/.claude-plugin"
      cat > "$mkt_dir/.claude-plugin/marketplace.json" << 'MKEOF'
{
  "$schema": "https://anthropic.com/claude-code/marketplace.schema.json",
  "name": "devflow-local",
  "description": "Local devflow plugin installation",
  "owner": {"name": "devflow-installer"},
  "plugins": [
    {
      "name": "devflow",
      "description": "Cross-tool development workflow orchestrator",
      "source": "./plugins/devflow",
      "category": "development"
    }
  ]
}
MKEOF
      # Also put a copy of the plugin in the marketplace plugins dir
      mkdir -p "$mkt_dir/plugins/devflow"
      rsync -a --delete \
        --exclude '.git' --exclude '.git/' \
        "$DEVFLOW_HOME/" "$mkt_dir/plugins/devflow/"
      echo "  ✓ marketplace created at $mkt_dir"

      # Register marketplace in known_marketplaces.json
      local mkt_file="$HOME/.claude/plugins/known_marketplaces.json"
      [ -f "$mkt_file" ] || echo '{}' > "$mkt_file"
      if [ -f "$mkt_file" ]; then
        json_set "$mkt_file" "
if '$CLAUDE_MKT' not in data:
    data['$CLAUDE_MKT'] = {
        'source': {'source': 'github', 'repo': 'yuriykuzin/devflow'},
        'installLocation': '$mkt_dir',
        'lastUpdated': '$(date -u +%Y-%m-%dT%H:%M:%S.000Z)'
    }
    print('  ✓ marketplace registered')
else:
    data['$CLAUDE_MKT']['lastUpdated'] = '$(date -u +%Y-%m-%dT%H:%M:%S.000Z)'
    print('  ✓ marketplace already registered')
" || echo "  ⚠ could not register marketplace"
      fi

      # Copy plugin files to cache
      mkdir -p "$plugin_dir"
      rsync -a --delete \
        --exclude '.git' --exclude '.git/' \
        "$DEVFLOW_HOME/" "$plugin_dir/"
      echo "  ✓ plugin cached at $plugin_dir"

      # Register in installed_plugins.json
      local installed_file="$HOME/.claude/plugins/installed_plugins.json"
      [ -f "$installed_file" ] || echo '{"version": 2, "plugins": {}}' > "$installed_file"
      if [ -f "$installed_file" ]; then
        local ts
        ts="$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"
        json_set "$installed_file" "
key = '$plugin_key'
if key not in data.get('plugins', {}):
    data.setdefault('plugins', {})[key] = [{
        'scope': 'user',
        'installPath': '$plugin_dir',
        'version': '$DEVFLOW_VERSION',
        'installedAt': '$ts',
        'lastUpdated': '$ts'
    }]
    print('  ✓ registered in installed_plugins.json')
else:
    print('  ✓ already registered')
" || echo "  ⚠ could not register plugin"
      fi

      # Enable in settings.json
      local settings_file="$HOME/.claude/settings.json"
      [ -f "$settings_file" ] || echo '{}' > "$settings_file"
      if [ -f "$settings_file" ]; then
        json_set "$settings_file" "
key = '$plugin_key'
ep = data.setdefault('enabledPlugins', {})
if key not in ep:
    ep[key] = True
    print('  ✓ enabled in settings.json')
else:
    print('  ✓ already enabled')
" || echo "  ⚠ could not enable plugin"
      fi

      echo ""
      echo "  Note: restart Claude Code to load devflow skills."
      echo "  If skills don't appear, start with: claude --plugin-dir $DEVFLOW_HOME"
    else
      echo "  · Claude Code not detected — skipped"
    fi
  else
    echo "  · skipped (disabled in config)"
  fi

  # 4. Cursor
  echo "Cursor:"
  echo "  ✓ reads from $DEVFLOW_HOME directly (no setup needed)"

  # 5. Gemini CLI
  echo "Gemini CLI:"
  echo "  ✓ reads from $DEVFLOW_HOME directly (no setup needed)"

  # 6. Config
  echo "Config:"
  if [ ! -f "$HOME/.devflow/config.yaml" ]; then
    mkdir -p "$HOME/.devflow"
    cp "$DEVFLOW_HOME/config.default.yaml" "$HOME/.devflow/config.yaml"
    echo "  ✓ created ~/.devflow/config.yaml"
  else
    echo "  · ~/.devflow/config.yaml already exists (kept)"
  fi

  echo ""
  echo "Done. Run --choose to change tools, or edit ~/.devflow/config.yaml."
}

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------

do_uninstall() {
  echo "Devflow — uninstalling"
  echo ""

  # Codex
  [ -L "$HOME/.agents/skills/devflow" ] && rm "$HOME/.agents/skills/devflow" \
    && echo "  ✓ removed Codex symlink" \
    || echo "  · Codex: not installed"

  # Windsurf
  local wf_found=0
  for wf in "$HOME/.codeium/windsurf/windsurf/workflows"/devflow-*.md; do
    [ -L "$wf" ] && rm "$wf" && echo "  ✓ removed $(basename "$wf")" && wf_found=1
  done
  [ "$wf_found" = "0" ] && echo "  · Windsurf: not installed"

  # Claude Code — remove marketplace, cache, and registrations
  local mkt_dir="$HOME/.claude/plugins/marketplaces/$CLAUDE_MKT"
  [ -d "$mkt_dir" ] && rm -rf "$mkt_dir" \
    && echo "  ✓ removed Claude Code marketplace"

  local cache_dir="$HOME/.claude/plugins/cache/$CLAUDE_MKT"
  [ -d "$cache_dir" ] && rm -rf "$cache_dir" \
    && echo "  ✓ removed Claude Code cache"

  # Also clean up old "local" marketplace from previous installs
  local old_cache="$HOME/.claude/plugins/cache/local/devflow"
  [ -d "$old_cache" ] && rm -rf "$old_cache"

  local plugin_key="devflow@$CLAUDE_MKT"
  local installed_file="$HOME/.claude/plugins/installed_plugins.json"
  if [ -f "$installed_file" ]; then
    json_set "$installed_file" "
for key in ['$plugin_key', 'devflow@local']:
    if key in data.get('plugins', {}):
        del data['plugins'][key]
        print(f'  ✓ removed {key} from installed_plugins.json')
" || true
  fi

  local settings_file="$HOME/.claude/settings.json"
  if [ -f "$settings_file" ]; then
    json_set "$settings_file" "
for key in ['$plugin_key', 'devflow@local']:
    if key in data.get('enabledPlugins', {}):
        del data['enabledPlugins'][key]
        print(f'  ✓ removed {key} from settings.json')
" || true
  fi

  local mkt_file="$HOME/.claude/plugins/known_marketplaces.json"
  if [ -f "$mkt_file" ]; then
    json_set "$mkt_file" "
for key in ['$CLAUDE_MKT', 'local']:
    if key in data:
        del data[key]
        print(f'  ✓ removed {key} from known_marketplaces.json')
" || true
  fi

  echo "  · ~/.devflow/config.yaml kept (remove manually if desired)"
  echo ""
  echo "Done."
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
    echo "  ✗ Codex:       not installed"
  fi

  # Windsurf
  local wf_dir="$HOME/.codeium/windsurf/windsurf/workflows"
  if [ -d "$HOME/.codeium/windsurf" ]; then
    local found=0
    for wf in "$wf_dir"/devflow-*.md; do
      [ -L "$wf" ] && found=$((found + 1))
    done
    echo "  ✓ Windsurf:    $found workflow(s) in $wf_dir"
  else
    echo "  · Windsurf:    not detected"
  fi

  # Claude Code
  local plugin_dir="$HOME/.claude/plugins/cache/$CLAUDE_MKT/devflow/$DEVFLOW_VERSION"
  if [ -d "$plugin_dir" ]; then
    echo "  ✓ Claude Code: $plugin_dir"
    local installed_file="$HOME/.claude/plugins/installed_plugins.json"
    local plugin_key="devflow@$CLAUDE_MKT"
    if [ -f "$installed_file" ] && python3 -c "
import json
with open('$installed_file') as f:
    d = json.load(f)
assert '$plugin_key' in d.get('plugins', {})
" 2>/dev/null; then
      echo "               registered as $plugin_key"
    else
      echo "               ⚠ cached but not registered"
    fi
  else
    echo "  ✗ Claude Code: not installed"
  fi

  # Cursor
  local install_home="$DEVFLOW_HOME"
  [ -d "$INSTALL_DIR" ] && install_home="$INSTALL_DIR"
  if [ -f "$install_home/.cursor-plugin/plugin.json" ]; then
    echo "  ✓ Cursor:      reads from $install_home"
  fi

  # Gemini
  if [ -f "$install_home/GEMINI.md" ]; then
    echo "  ✓ Gemini:      reads from $install_home"
  fi

  # Config
  if [ -f "$HOME/.devflow/config.yaml" ]; then
    echo "  ✓ Config:      ~/.devflow/config.yaml"
  else
    echo "  ✗ Config:      missing"
  fi

  # Integration settings
  echo ""
  echo "Integration settings:"
  if [ -f "$HOME/.devflow/config.yaml" ] && grep -q "^integrations:" "$HOME/.devflow/config.yaml"; then
    awk '/^integrations:/{found=1} found' "$HOME/.devflow/config.yaml" | head -10
  else
    echo "  (all tools enabled by default)"
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

case "${1:-}" in
  --deploy)    do_deploy ;;
  --choose)    do_choose ;;
  --uninstall) do_uninstall ;;
  --status)    do_status ;;
  --help|-h)   usage ;;
  *)           do_install ;;
esac
