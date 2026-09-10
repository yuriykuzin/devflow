#!/usr/bin/env bash
# executor manifest (docs/contracts/executor-manifest-v1.md): devflow-config.py resolve merges
# it in and overrides inline roles/review; devflow-runner.sh preflight rejects a manifest built
# for a different host.
set -u
. "$LIB/assert.sh"

CFGC="$(cd "$(dirname "$RUNNER")" && pwd)/devflow-config.py"
DEFAULTS="$DEVFLOW_TEST_REPO/config.default.yaml"
TD="$(mktemp -d "${TMPDIR:-/tmp}/devflow-manifest.XXXXXX")"

resolve(){ python3 "$CFGC" resolve --defaults "$DEFAULTS" "$@"; }

# A manifest that overrides inline roles/review with different values, so a passing assertion
# proves the manifest actually won rather than just matching what was already inline.
MANIFEST="$TD/manifest.yaml"
cat > "$MANIFEST" <<YAML
executor_manifest: 1
producer: test-producer
host: claude
roles:
  implementer: { agent: manifest-implementer }
  reviewer:    { agent: manifest-reviewer, lens: architect }
  verifier:    { agent: manifest-verifier }
budgets:
  review_passes: 2
  fallback_to_host: false
YAML

GLOBAL="$TD/global.yaml"
cat > "$GLOBAL" <<YAML
roles:
  implementer: { agent: inline-implementer }
  reviewer:    { agent: inline-reviewer, lens: qa }
  verifier:    { agent: inline-verifier }
review:
  max_passes: 9
  fallback_to_host: true
executor_manifest: "$MANIFEST"
YAML

PROJ_EMPTY="$TD/proj-empty"; mkdir -p "$PROJ_EMPTY"

# (1) manifest overrides inline roles and review.
out="$(resolve --global "$GLOBAL" --project-root "$PROJ_EMPTY" 2>/dev/null)"
is "$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["roles"]["reviewer"]["lens"])')" "architect" \
  "manifest roles.reviewer.lens wins over inline"
is "$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["roles"]["implementer"]["agent"])')" "manifest-implementer" \
  "manifest roles.implementer.agent wins over inline"
is "$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["review"]["max_passes"])')" "2" \
  "manifest budgets.review_passes wins over inline review.max_passes"
is "$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["review"]["fallback_to_host"])')" "False" \
  "manifest budgets.fallback_to_host wins over inline review.fallback_to_host"
is "$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["_manifest"]["host"])')" "claude" \
  "_manifest.host is recorded in the resolved output"
is "$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["_manifest"]["producer"])')" "test-producer" \
  "_manifest.producer is recorded in the resolved output"

# (2) bad version -> exit 6, ERROR on stderr.
BAD_VERSION="$TD/bad-version.yaml"
cat > "$BAD_VERSION" <<YAML
executor_manifest: 2
host: claude
roles:
  implementer: { agent: x }
YAML
GLOBAL_BAD="$TD/global-bad-version.yaml"
cat > "$GLOBAL_BAD" <<YAML
executor_manifest: "$BAD_VERSION"
YAML
err="$TD/stderr-bad-version.txt"
resolve --global "$GLOBAL_BAD" --project-root "$PROJ_EMPTY" > /dev/null 2>"$err"; rc=$?
is "$rc" "6" "unsupported executor_manifest version -> exit 6"
has "$(cat "$err")" "ERROR executor_manifest version 2 unsupported" "...naming the unsupported version"

# (3) missing file -> exit 6, ERROR on stderr.
MISSING="$TD/does-not-exist.yaml"
GLOBAL_MISSING="$TD/global-missing.yaml"
cat > "$GLOBAL_MISSING" <<YAML
executor_manifest: "$MISSING"
YAML
err2="$TD/stderr-missing.txt"
resolve --global "$GLOBAL_MISSING" --project-root "$PROJ_EMPTY" > /dev/null 2>"$err2"; rc=$?
is "$rc" "6" "missing executor_manifest file -> exit 6"
has "$(cat "$err2")" "ERROR executor_manifest not found $MISSING" "...naming the missing path"

# (4) project-level executor_manifest is dropped by the trust filter, with the existing WARN.
PROJ_HOSTILE="$TD/proj-hostile"; mkdir -p "$PROJ_HOSTILE"
cat > "$PROJ_HOSTILE/.devflow.yaml" <<YAML
executor_manifest: "$MANIFEST"
YAML
err3="$TD/stderr-project.txt"
out3="$(resolve --global "$TD/global-empty.yaml" --project-root "$PROJ_HOSTILE" 2>"$err3")"
has "$(cat "$err3")" "WARN ignored untrusted key executor_manifest from .devflow.yaml" \
  "project-level executor_manifest is rejected with a WARN"
is "$(printf '%s' "$out3" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("_manifest", {}))')" "{}" \
  "...and no manifest is applied (project could not set it)"

# (5) preflight: a manifest built for a different host than the one actually running -> exit 7.
ROLES_FILE="$TD/roles-for-preflight.json"
resolve --global "$GLOBAL" --project-root "$PROJ_EMPTY" > "$ROLES_FILE" 2>/dev/null
out5="$(bash "$RUNNER" preflight --roles-file "$ROLES_FILE" --host codex 2>&1)"; rc=$?
is "$rc" "7" "preflight: manifest host (claude) differs from the running host (codex) -> exit 7"
is "$out5" "HOST_MISMATCH manifest=claude host=codex" "...naming manifest host and running host"

# (6) preflight: matching host -> no mismatch (falls through to the usual claude-agent checks).
out6="$(bash "$RUNNER" preflight --roles-file "$ROLES_FILE" --host claude 2>&1)"; rc=$?
isnt "$rc" "7" "preflight: manifest host matches the running host -> no HOST_MISMATCH"

# (7) a manifest using a nested block mapping (`roles:\n  reviewer:\n    agent: ...\n    lens: ...`)
# parses fine — not just the one-line flow-mapping form used above.
NESTED="$TD/nested.yaml"
cat > "$NESTED" <<YAML
executor_manifest: 1
host: claude
roles:
  reviewer:
    agent: reviewer
    lens: qa
YAML
GLOBAL_NESTED="$TD/global-nested.yaml"
cat > "$GLOBAL_NESTED" <<YAML
executor_manifest: "$NESTED"
YAML
out7="$(resolve --global "$GLOBAL_NESTED" --project-root "$PROJ_EMPTY" 2>/dev/null)"
is "$(printf '%s' "$out7" | python3 -c 'import json,sys; print(json.load(sys.stdin)["roles"]["reviewer"]["lens"])')" "qa" \
  "manifest with a nested block mapping parses (roles.reviewer.lens == qa)"

# (8) `fallback_to_host: yes` unquoted in YAML parses as the boolean true (YAML 1.1), not the
# string "yes" — so it's a VALID profile and preflight applies the fallback rather than
# rejecting it as INVALID_PROFILE.
YESNO="$TD/yesno.yaml"
cat > "$YESNO" <<YAML
executor_manifest: 1
host: claude
roles:
  reviewer: { agent: reviewer }
budgets:
  fallback_to_host: yes
YAML
GLOBAL_YESNO="$TD/global-yesno.yaml"
cat > "$GLOBAL_YESNO" <<YAML
executor_manifest: "$YESNO"
YAML
ROLES_YESNO="$TD/roles-yesno.json"
resolve --global "$GLOBAL_YESNO" --project-root "$PROJ_EMPTY" > "$ROLES_YESNO" 2>/dev/null
is "$(python3 -c 'import json; print(json.load(open("'"$ROLES_YESNO"'"))["review"]["fallback_to_host"])')" "True" \
  "fallback_to_host: yes (unquoted) resolves to the boolean True, not the string 'yes'"
out8="$(bash "$RUNNER" preflight --roles-file "$ROLES_YESNO" --host codex --expect-host claude 2>&1)"; rc=$?
is "$rc" "0" "...so preflight treats it as a valid, true fallback_to_host (not INVALID_PROFILE)"
has "$out8" "FALLBACK_TO_HOST reviewer=reviewer" "...and applies the fallback"

# (9) a relative executor_manifest path (docs/contracts/executor-manifest-v1.md) resolves
# against $HOME, not the process cwd: place the manifest under a fake $HOME, then resolve from
# an unrelated cwd and confirm it's still found and its roles win.
OLDHOME="$HOME"
export HOME="$TD/fakehome"
mkdir -p "$HOME/rel"
cat > "$HOME/rel/manifest.yaml" <<YAML
executor_manifest: 1
host: claude
roles:
  reviewer: { agent: relhome-reviewer }
YAML
GLOBAL_REL="$TD/global-rel.yaml"
cat > "$GLOBAL_REL" <<YAML
executor_manifest: "rel/manifest.yaml"
YAML
OTHER_CWD="$TD/other-cwd"; mkdir -p "$OTHER_CWD"
out9="$(cd "$OTHER_CWD" && resolve --global "$GLOBAL_REL" --project-root "$PROJ_EMPTY" 2>/dev/null)"
is "$(printf '%s' "$out9" | python3 -c 'import json,sys; print(json.load(sys.stdin)["roles"]["reviewer"]["agent"])')" "relhome-reviewer" \
  "relative executor_manifest path resolves against \$HOME, not the process cwd"
export HOME="$OLDHOME"

rm -rf "$TD"
report
