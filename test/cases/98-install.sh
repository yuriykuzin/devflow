#!/usr/bin/env bash
# install.sh (Claude Code integration): the version comes from plugin.json, and the cache
# dir, installed_plugins.json and settings.json stay consistent across install/deploy/status.
# Every run uses a throwaway HOME under a mktemp dir — never the real one.
set -u
. "$LIB/assert.sh"

command -v rsync >/dev/null 2>&1 || { echo "FAIL: rsync is required for this case" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 is required for this case" >&2; exit 1; }

REPO_ROOT="$DEVFLOW_TEST_REPO"
TD="$(mktemp -d "${TMPDIR:-/tmp}/devflow-install.XXXXXX")"
RESTORE_DIR=""
cleanup(){
  [ -n "$RESTORE_DIR" ] && chmod 755 "$RESTORE_DIR" 2>/dev/null
  chmod -R u+rwx "$TD" 2>/dev/null
  rm -rf "$TD"
}
trap cleanup EXIT

KEY="devflow@devflow-local"
V="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$REPO_ROOT/.claude-plugin/plugin.json")"

# fresh_home NAME: new sandbox HOME with only Claude Code enabled; refuses a HOME outside $TD.
fresh_home(){
  export HOME="$TD/$1/home"
  case "$HOME" in "$TD"/*) ;; *) echo "REFUSING to run outside the sandbox: $HOME" >&2; exit 2 ;; esac
  mkdir -p "$HOME/.claude" "$HOME/.devflow"
  cat > "$HOME/.devflow/config.yaml" <<YAML
integrations:
  codex: false
  claude-code: true
  opencode: false
YAML
  PLUGINS="$HOME/.claude/plugins"
  CACHE="$PLUGINS/cache/devflow-local/devflow"
  REG="$PLUGINS/installed_plugins.json"
}

# run_install ARGS...: install.sh from the repo copy $INSTALL_SRC, output merged, sandbox only.
INSTALL_SRC="$REPO_ROOT"
run_install(){
  case "$HOME" in "$TD"/*) ;; *) echo "REFUSING to run outside the sandbox: $HOME" >&2; return 2 ;; esac
  bash "$INSTALL_SRC/install.sh" "$@" 2>&1
}

# seed_registry [SCOPE=VERSION]...: write the key with one stale entry per arg (dir created,
# fake gitCommitSha, old installedAt); no args -> the key holds an empty list.
seed_registry(){
  mkdir -p "$PLUGINS"
  local spec
  for spec in "$@"; do mkdir -p "$CACHE/${spec#*=}"; done
  python3 -c '
import json, sys
cache, path, key = sys.argv[1:4]
entries = []
for spec in sys.argv[4:]:
    scope, version = spec.split("=")
    entries.append({"scope": scope, "installPath": f"{cache}/{version}", "version": version,
                    "installedAt": "2020-01-01T00:00:00.000Z",
                    "lastUpdated": "2020-01-01T00:00:00.000Z", "gitCommitSha": "abc"})
with open(path, "w") as f:
    json.dump({"version": 2, "plugins": {key: entries}}, f)
' "$CACHE" "$REG" "$KEY" "$@"
}

# jq_py FILE EXPR: evaluate a Python expression over the parsed JSON file as `d`.
jq_py(){ python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$1" "$2"; }
entry(){ jq_py "$REG" "d['plugins']['$KEY'][$1]$2"; }
versions_on_disk(){ ls "$CACHE" | tr '\n' ' '; }
mode_of(){ python3 -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777))' "$1"; }

# (1) plain install repoints a stale entry, keeps installedAt, drops gitCommitSha, prunes old dir.
fresh_home plain
seed_registry user=0.0.1
out="$(run_install)"; rc=$?
is "$rc" "0" "plain install exits 0"
ok "[ -d '$CACHE/$V' ]" "cache/<mkt>/devflow/$V (version from plugin.json) exists"
is "$(entry 0 "['installPath']")" "$CACHE/$V" "registry installPath points to the new version dir"
is "$(entry 0 "['version']")" "$V" "registry version is the plugin.json version"
is "$(entry 0 "['installedAt']")" "2020-01-01T00:00:00.000Z" "installedAt is preserved"
is "$(entry 0 ".get('gitCommitSha')")" "None" "stale gitCommitSha is dropped"
ok "[ ! -e '$CACHE/0.0.1' ]" "the stale 0.0.1 dir is pruned"
is "$(versions_on_disk)" "$V " "no other version dirs remain"

# (2) --status right after a good install: the real version path, no dangling warning.
out="$(run_install --status)"
has "$out" "$CACHE/$V" "--status prints the version path"
hasnt "$out" "missing" "--status shows no 'missing' warning"

# (3) --deploy twice (sandbox ~/.codex/devflow): the registry path exists on disk both times.
fresh_home deploy
seed_registry user=0.0.1
for n in 1 2; do
  out="$(run_install --deploy)"; rc=$?
  is "$rc" "0" "--deploy run $n exits 0"
  ok "[ -d \"$(entry 0 "['installPath']")\" ]" "after --deploy run $n the registry installPath exists"
done

# (4) multi-entry key: BOTH entries move to the new version, both old dirs are pruned.
fresh_home multi
seed_registry user=0.0.1 project=0.0.2
out="$(run_install)"
is "$(entry 0 "['installPath']")" "$CACHE/$V" "multi-entry: user entry repointed"
is "$(entry 1 "['installPath']")" "$CACHE/$V" "multi-entry: project entry repointed"
is "$(entry 1 "['scope']")" "project" "multi-entry: project scope kept"
is "$(versions_on_disk)" "$V " "multi-entry: both old dirs are gone"

# (5) empty list under the key -> one user entry for the new version.
fresh_home empty
seed_registry
out="$(run_install)"
is "$(jq_py "$REG" "len(d['plugins']['$KEY'])")" "1" "empty list: one entry created"
is "$(entry 0 "['scope']")" "user" "...with user scope"
is "$(entry 0 "['installPath']")" "$CACHE/$V" "...pointing to the new version dir"

# (6) dangling registry: remove the current version dir by hand -> --status warns.
rm -rf "$CACHE/$V"
out="$(run_install --status)"
has "$out" "registry points to missing $CACHE/$V" "dangling registry path is reported by --status"

# (7) json_set is atomic: a failing write leaves the registry untouched and nothing is pruned.
fresh_home atomic
seed_registry user=$V
run_install >/dev/null
seed_registry user=0.0.1
mkdir -p "$CACHE/0.0.9"
cp "$REG" "$TD/registry.before"
if [ "$(id -u)" = "0" ]; then
  echo "  skip - atomic json_set case: running as root, chmod cannot deny the temp file"
else
  RESTORE_DIR="$PLUGINS"
  chmod 555 "$PLUGINS"
  out="$(run_install)"
  chmod 755 "$PLUGINS"; RESTORE_DIR=""
  has "$out" "could not register plugin" "failed registry write is reported"
  ok "cmp -s '$REG' '$TD/registry.before'" "installed_plugins.json is byte-identical after the failed write"
  ok "[ -d '$CACHE/0.0.1' ]" "the stale version dir is not pruned"
  ok "[ -d '$CACHE/0.0.9' ]" "an unregistered orphan dir survives too (prune skipped)"
fi

# (8) a symlinked settings.json stays a symlink; the target gets the update; its mode is kept.
fresh_home symlink
mkdir -p "$TD/symlink/other"
printf '{}\n' > "$TD/symlink/other/real-settings.json"
chmod 640 "$TD/symlink/other/real-settings.json"
ln -s "$TD/symlink/other/real-settings.json" "$HOME/.claude/settings.json"
out="$(run_install)"
ok "[ -L '$HOME/.claude/settings.json' ]" "settings.json is still a symlink"
has "$(cat "$TD/symlink/other/real-settings.json")" "enabledPlugins" "the symlink target holds the update"
is "$(mode_of "$TD/symlink/other/real-settings.json")" "0o640" "the target's mode is unchanged"

# (9)+(10) a repo copy with a bad plugin.json: --uninstall still works, install refuses.
BAD_SRC="$TD/bad-repo"
rsync -a --exclude '.git' "$REPO_ROOT/" "$BAD_SRC/"
INSTALL_SRC="$BAD_SRC"
printf '{ not json' > "$BAD_SRC/.claude-plugin/plugin.json"
fresh_home uninstall
out="$(run_install --uninstall)"; rc=$?
is "$rc" "0" "--uninstall works with a broken plugin.json"

printf '{"version": "../x"}\n' > "$BAD_SRC/.claude-plugin/plugin.json"
fresh_home badversion
out="$(run_install)"; rc=$?
isnt "$rc" "0" "install with version '../x' exits non-zero"
has "$out" "no valid \"version\"" "...and says why"
ok "[ ! -e '$PLUGINS' ]" "...and writes nothing under the sandbox plugins dir"

# (11) a version with a trailing newline is refused (the shell would strip it from $(...)).
printf '{"version": "0.2.0\\n"}\n' > "$BAD_SRC/.claude-plugin/plugin.json"
fresh_home newlineversion
out="$(run_install)"; rc=$?
is "$rc" "1" "install with version '0.2.0\\n' exits 1"
has "$out" "no valid \"version\"" "...and says why"

# (12) a failing rm -rf of an old version dir does not abort the install.
INSTALL_SRC="$REPO_ROOT"
fresh_home prunefail
seed_registry user=0.0.1
mkdir -p "$CACHE/0.0.9/sub"
touch "$CACHE/0.0.9/sub/file"
if [ "$(id -u)" = "0" ]; then
  echo "  skip - prune failure case: running as root, chmod cannot make rm fail"
else
  chmod 555 "$CACHE/0.0.9/sub"
  out="$(run_install)"; rc=$?
  chmod -R u+w "$CACHE/0.0.9"
  is "$rc" "0" "install exits 0 when an old dir cannot be pruned"
  has "$out" "could not prune 0.0.9" "...and reports the dir"
  ok "[ -f '$HOME/.claude/settings.json' ]" "...and settings.json is written"
  has "$(cat "$HOME/.claude/settings.json")" "enabledPlugins" "...with the plugin enabled"
fi

report
