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
DEVFLOW_VERSION=""  # set by load_devflow_version from .claude-plugin/plugin.json
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
  opencode: true
  # cursor: true
  # gemini: true
EOF
  fi

  local tools=("codex" "claude-code" "opencode")
  local labels=("Codex CLI" "Claude Code" "opencode")
  local detected=()

  # Detect available tools
  command -v codex >/dev/null 2>&1 && detected+=("codex") || true
  [ -d "$HOME/.claude" ] && detected+=("claude-code") || true
  { command -v opencode >/dev/null 2>&1 || [ -d "$HOME/.config/opencode" ]; } && detected+=("opencode") || true

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
#
# scripts/devflow-runner.sh ships as a plain file under this tree — rsync -a below
# copies it like any other file. It is always invoked as `bash "$RUNNER" ...`, never
# executed directly, so no chmod +x step is needed here or anywhere else in this script.
# ---------------------------------------------------------------------------

do_deploy() {
  echo "Devflow — deploying from $SCRIPT_DIR to $INSTALL_DIR"
  echo ""

  if [ "$SCRIPT_DIR" = "$INSTALL_DIR" ]; then
    echo "  ⚠ Source and install directories are the same — use ./install.sh without --deploy"
    exit 1
  fi

  # Fail on a broken plugin.json before anything is synced or removed.
  load_devflow_version

  mkdir -p "$INSTALL_DIR"

  rsync -a --delete \
    --exclude '.git' \
    --exclude '.git/' \
    "$SCRIPT_DIR/" "$INSTALL_DIR/"

  echo "  ✓ Files synced to $INSTALL_DIR"

  # Remove the old Codex link so re-install points to INSTALL_DIR. The Claude cache is
  # kept: do_install copies the new version, repoints the registry, then prunes.
  rm -f "$HOME/.agents/skills/devflow"

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

# Read the version from .claude-plugin/plugin.json into DEVFLOW_VERSION; exit 1 if it is
# missing or unsafe (the value ends up in a cache path).
load_devflow_version() {
  local manifest="$SCRIPT_DIR/.claude-plugin/plugin.json" version
  version="$(python3 -c '
import json, re, sys
with open(sys.argv[1]) as f:
    version = json.load(f)["version"]
# Validate the raw string: $(...) would strip a trailing newline before bash sees it.
print(version if isinstance(version, str) and re.fullmatch(r"[0-9A-Za-z][0-9A-Za-z.+-]*", version) else "")
' "$manifest" 2>/dev/null)" || version=""
  if ! [[ "$version" =~ ^[0-9A-Za-z][0-9A-Za-z.+-]*$ ]]; then
    echo "  ✗ no valid \"version\" in $manifest" >&2
    exit 1
  fi
  DEVFLOW_VERSION="$version"
}

# Run py_code against the JSON file's contents as `data`, then write it back atomically
# (temp file in the real file's directory + os.replace). Symlinks and modes are kept.
# The py_code output is shown only after the write succeeded.
json_set() {
  local file="$1" py_code="$2"
  python3 -c "
import io, json, os, shutil, sys, tempfile
path = os.path.realpath(sys.argv[1])
try:
    with open(path, 'r') as f:
        data = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    data = {}
real_stdout, sys.stdout = sys.stdout, io.StringIO()
$py_code
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix='.json_set.')
try:
    with os.fdopen(fd, 'w') as f:
        json.dump(data, f, indent=2)
        f.write('\n')
    if os.path.exists(path):
        shutil.copymode(path, tmp)
    else:
        os.chmod(tmp, 0o644)
    os.replace(tmp, path)
except BaseException:
    if os.path.exists(tmp):
        os.unlink(tmp)
    raise
real_stdout.write(sys.stdout.getvalue())
" "$file" 2>/dev/null
}

# Print the installPath of every entry of plugin key $2 in registry file $1, one per line
# (trailing slash dropped). Fails if the registry cannot be read.
registry_install_paths() {
  python3 -c '
import json, sys
with open(sys.argv[1]) as f:
    entries = json.load(f).get("plugins", {}).get(sys.argv[2]) or []
for entry in entries:
    if isinstance(entry, dict) and entry.get("installPath"):
        print(entry["installPath"].rstrip("/"))
' "$1" "$2"
}

# Remove version dirs under cache dir $1 that are neither $2 (the current one) nor an
# installPath of any registry entry for key $4 in registry file $3.
prune_old_versions() {
  local cache_dir="$1" keep_dir="$2" registry_file="$3" plugin_key="$4"
  local registered dir
  registered="$(registry_install_paths "$registry_file" "$plugin_key" 2>/dev/null)" || {
    echo "  ⚠ could not re-read registry — old versions not pruned"
    return 0
  }
  for dir in "$cache_dir"/*/; do
    [ -d "$dir" ] || continue
    dir="${dir%/}"
    [ "$dir" = "$keep_dir" ] && continue
    grep -qxF -- "$dir" <<< "$registered" && continue
    rm -rf "$dir" || { echo "  ⚠ could not prune $(basename "$dir")"; continue; }
    echo "  ✓ pruned old version $(basename "$dir")"
  done
}

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------

do_install() {
  load_devflow_version
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

  # 2. Claude Code — proper marketplace-based installation
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
        # Every entry of the key is repointed (the cache is a working-tree copy, so a
        # stale gitCommitSha is dropped); a missing or empty key gets one user entry.
        if json_set "$installed_file" "
key = '$plugin_key'
plugins = data.setdefault('plugins', {})
if not plugins.get(key):
    plugins[key] = [{
        'scope': 'user',
        'installPath': '$plugin_dir',
        'version': '$DEVFLOW_VERSION',
        'installedAt': '$ts',
        'lastUpdated': '$ts'
    }]
    print('  ✓ registered in installed_plugins.json')
else:
    for entry in plugins[key]:
        entry['installPath'] = '$plugin_dir'
        entry['version'] = '$DEVFLOW_VERSION'
        entry['lastUpdated'] = '$ts'
        entry.pop('gitCommitSha', None)
    print('  ✓ registry updated in installed_plugins.json')
"; then
          # Registry now points at plugin_dir: safe to drop versions nothing references.
          prune_old_versions "$cache_dir" "$plugin_dir" "$installed_file" "$plugin_key"
        else
          echo "  ⚠ could not register plugin"
        fi
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

  # 3. opencode — a flat skills dir: one symlink PER SKILL, not one for the whole tree.
  #    opencode discovers ~/.config/opencode/skills/<name>/SKILL.md, so a single
  #    skills/ -> devflow/skills symlink would hide every skill one level too deep.
  echo "opencode:"
  if integration_enabled "opencode"; then
    if command -v opencode >/dev/null 2>&1 || [ -d "$HOME/.config/opencode" ]; then
      mkdir -p "$HOME/.config/opencode/skills"
      for skill_dir in "$DEVFLOW_HOME"/skills/*/; do
        [ -d "$skill_dir" ] || continue
        local skill_name
        skill_name="$(basename "$skill_dir")"
        symlink_or_skip "${skill_dir%/}" "$HOME/.config/opencode/skills/$skill_name" \
          "~/.config/opencode/skills/$skill_name"
      done
    else
      echo "  · not detected — skipped"
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

  # opencode — one symlink per skill; only remove links that point into devflow, so a
  # same-named skill the user installed from elsewhere is left alone.
  local oc_dir="$HOME/.config/opencode/skills" oc_removed=0
  if [ -d "$oc_dir" ]; then
    for link in "$oc_dir"/*; do
      [ -L "$link" ] || continue
      case "$(readlink "$link")" in
        "$DEVFLOW_HOME"/skills/*|"$INSTALL_DIR"/skills/*|"$HOME"/.claude/plugins/cache/"$CLAUDE_MKT"/*)
          rm "$link"; oc_removed=$((oc_removed+1)) ;;
      esac
    done
  fi
  [ "$oc_removed" -gt 0 ] && echo "  ✓ removed $oc_removed opencode skill symlink(s)" \
    || echo "  · opencode: not installed"

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

  # Claude Code
  load_devflow_version
  local plugin_dir="$HOME/.claude/plugins/cache/$CLAUDE_MKT/devflow/$DEVFLOW_VERSION"
  local installed_file="$HOME/.claude/plugins/installed_plugins.json"
  local plugin_key="devflow@$CLAUDE_MKT"
  local registered="" reg_path
  [ -f "$installed_file" ] && registered="$(registry_install_paths "$installed_file" "$plugin_key" 2>/dev/null)" || true
  if [ -d "$plugin_dir" ]; then
    echo "  ✓ Claude Code: $plugin_dir"
    if [ -n "$registered" ]; then
      echo "               registered as $plugin_key"
    else
      echo "               ⚠ cached but not registered"
    fi
  else
    echo "  ✗ Claude Code: not installed"
  fi
  # Independent of the current version dir: a registry entry may point somewhere gone.
  while IFS= read -r reg_path; do
    if [ -n "$reg_path" ] && [ ! -d "$reg_path" ]; then
      echo "               ⚠ registry points to missing $reg_path"
    fi
  done <<< "$registered"

  # opencode
  local oc_dir="$HOME/.config/opencode/skills" oc_n=0
  if [ -d "$oc_dir" ]; then
    for link in "$oc_dir"/*; do
      [ -L "$link" ] || continue
      case "$(readlink "$link")" in
        */devflow/skills/*|*/devflow-local/devflow/*/skills/*) oc_n=$((oc_n+1)) ;;
      esac
    done
  fi
  if [ "$oc_n" -gt 0 ]; then
    echo "  ✓ opencode:    $oc_n skill(s) linked in ~/.config/opencode/skills"
  else
    echo "  ✗ opencode:    not installed"
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
