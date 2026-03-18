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

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_DIR="$HOME/.codex/devflow"
DEVFLOW_HOME="$SCRIPT_DIR"

usage() {
  sed -n '/^# Usage:/,/^$/p' "$0" | sed 's/^# //'
  echo ""
  echo "Development workflow:"
  echo "  Edit in source repo → ./install.sh --deploy → all agents updated"
  exit 0
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

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------

do_install() {
  echo "Devflow — installing from $DEVFLOW_HOME"
  echo ""

  # 1. Codex CLI — one directory symlink (Codex scans ~/.agents/skills/ recursively)
  echo "Codex CLI:"
  mkdir -p "$HOME/.agents/skills"
  symlink_or_skip "$DEVFLOW_HOME/skills" "$HOME/.agents/skills/devflow" \
    "~/.agents/skills/devflow → skills/"

  # 2. Windsurf — symlink workflow files (if Windsurf is installed)
  echo "Windsurf:"
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

  # 3. Claude Code / Cursor — read directly from repo, nothing to do
  echo "Claude Code / Cursor:"
  echo "  ✓ reads from $DEVFLOW_HOME directly (no setup needed)"

  # 4. Gemini CLI — reads GEMINI.md + gemini-extension.json from repo
  echo "Gemini CLI:"
  echo "  ✓ reads from $DEVFLOW_HOME directly (no setup needed)"

  # 5. Config — create default if missing
  echo "Config:"
  if [ ! -f "$HOME/.devflow/config.yaml" ]; then
    mkdir -p "$HOME/.devflow"
    cp "$DEVFLOW_HOME/config.default.yaml" "$HOME/.devflow/config.yaml"
    echo "  ✓ created ~/.devflow/config.yaml"
  else
    echo "  · ~/.devflow/config.yaml already exists (kept)"
  fi

  echo ""
  echo "Done. Edit ~/.devflow/config.yaml to customize."
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
    echo "  ✓ Codex:     $(readlink "$HOME/.agents/skills/devflow")"
  else
    echo "  ✗ Codex:     not linked"
  fi

  # Windsurf
  local wf_dir="$HOME/.codeium/windsurf/windsurf/workflows"
  if [ -d "$HOME/.codeium/windsurf" ]; then
    local found=0
    for wf in "$wf_dir"/devflow-*.md; do
      [ -L "$wf" ] && found=$((found + 1))
    done
    echo "  ✓ Windsurf:  $found workflow symlinks in $wf_dir"
  else
    echo "  · Windsurf:  not installed"
  fi

  # Claude Code / Cursor
  local install_home="$DEVFLOW_HOME"
  [ -d "$INSTALL_DIR" ] && install_home="$INSTALL_DIR"
  if [ -f "$install_home/.claude-plugin/plugin.json" ]; then
    echo "  ✓ Claude:    plugin.json present"
  fi
  if [ -f "$install_home/.cursor-plugin/plugin.json" ]; then
    echo "  ✓ Cursor:    plugin.json present"
  fi

  # Config
  if [ -f "$HOME/.devflow/config.yaml" ]; then
    echo "  ✓ Config:    ~/.devflow/config.yaml"
  else
    echo "  ✗ Config:    missing"
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
