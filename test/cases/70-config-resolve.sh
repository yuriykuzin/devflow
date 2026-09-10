#!/usr/bin/env bash
# devflow-config.py resolve: per-key merge (project > global > defaults, lists replaced whole)
# with the trust boundary from config.default.yaml — a project .devflow.yaml can never set
# roles.*.agent, review.max_passes, review.fallback_to_host (same rule as codex.command_path).
set -u
. "$LIB/assert.sh"

CFGC="$(cd "$(dirname "$RUNNER")" && pwd)/devflow-config.py"
DEFAULTS="$DEVFLOW_TEST_REPO/config.default.yaml"
TD="$(mktemp -d "${TMPDIR:-/tmp}/devflow-resolve.XXXXXX")"

resolve(){ python3 "$CFGC" resolve --defaults "$DEFAULTS" "$@"; }

# (1) no global, no project -> the shipped defaults come through untouched.
GLOBAL_MISSING="$TD/no-such-global.yaml"
PROJ_EMPTY="$TD/proj-empty"; mkdir -p "$PROJ_EMPTY"
out="$(resolve --global "$GLOBAL_MISSING" --project-root "$PROJ_EMPTY" 2>/dev/null)"
is "$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["roles"]["implementer"]["agent"])')" "" \
  "with no overrides, roles.implementer.agent is the shipped default (empty string)"
is "$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["review"]["max_passes"])')" "0" \
  "...and review.max_passes is the shipped default (0 = unlimited)"

# (2) global sets a real profile.
GLOBAL="$TD/global.yaml"
cat > "$GLOBAL" <<YAML
roles:
  implementer: { agent: implementer }
  reviewer:    { agent: reviewer, lens: architect }
  verifier:    { agent: verifier }
review:
  max_passes: 2
  fallback_to_host: false
YAML

# (3) project tries to override the trusted keys AND an untrusted one.
PROJ="$TD/proj"; mkdir -p "$PROJ"
cat > "$PROJ/.devflow.yaml" <<YAML
roles:
  implementer: { agent: hostile-agent }
review:
  max_passes: 999
external_review:
  from_claude: none
YAML

err="$TD/stderr.txt"
out="$(resolve --global "$GLOBAL" --project-root "$PROJ" 2>"$err")"
has "$(cat "$err")" "WARN ignored untrusted key roles.implementer.agent from .devflow.yaml" \
  "project override of roles.implementer.agent is rejected with a WARN"
has "$(cat "$err")" "WARN ignored untrusted key review.max_passes from .devflow.yaml" \
  "project override of review.max_passes is rejected with a WARN"

is "$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["roles"]["implementer"]["agent"])')" "implementer" \
  "...the GLOBAL value wins for roles.implementer.agent, not the project's"
is "$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["review"]["max_passes"])')" "2" \
  "...the GLOBAL value wins for review.max_passes, not the project's"
is "$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["external_review"]["from_claude"])')" "none" \
  "...but an UNTRUSTED key (external_review.from_claude) from the project DOES apply"
is "$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["roles"]["reviewer"]["lens"])')" "architect" \
  "...and roles.reviewer.lens (not trust-restricted) carries through from global"

# (4) a project CAN override an untrusted, ordinary key it legitimately owns.
PROJ2="$TD/proj2"; mkdir -p "$PROJ2"
cat > "$PROJ2/.devflow.yaml" <<YAML
backend: codex
YAML
out2="$(resolve --global "$GLOBAL" --project-root "$PROJ2" 2>/dev/null)"
is "$(printf '%s' "$out2" | python3 -c 'import json,sys; print(json.load(sys.stdin)["backend"])')" "codex" \
  "an ordinary (untrusted) key set by the project wins over global/defaults"

# (5) absence of a key is not the same as agent: "" — a global config that never mentions
# roles.verifier at all must still end up with the DEFAULT's explicit agent: "" (from
# config.default.yaml), not an absent key or a crash.
GLOBAL_PARTIAL="$TD/global-partial.yaml"
cat > "$GLOBAL_PARTIAL" <<YAML
roles:
  implementer: { agent: implementer }
YAML
out3="$(resolve --global "$GLOBAL_PARTIAL" --project-root "$PROJ_EMPTY" 2>/dev/null)"
is "$(printf '%s' "$out3" | python3 -c 'import json,sys; print(json.load(sys.stdin)["roles"]["implementer"]["agent"])')" "implementer" \
  "global sets roles.implementer.agent"
is "$(printf '%s' "$out3" | python3 -c 'import json,sys; print(json.load(sys.stdin)["roles"]["verifier"]["agent"])')" "" \
  "...roles.verifier (absent from global) still resolves to the default's explicit agent:''"

# (6) trust bypass: a project file cannot neutralize the trust boundary by replacing a whole
# trusted PREFIX with something that isn't a mapping at all (`roles: junk`, `review: unlimited`)
# — that used to slip past the naive walk (nothing to delete "found"), then deep_merge replaced
# the entire prefix wholesale, erasing the GLOBAL-set roles/review outright.
PROJ_BYPASS="$TD/proj-bypass"; mkdir -p "$PROJ_BYPASS"
printf 'roles: junk\nreview: unlimited\n' > "$PROJ_BYPASS/.devflow.yaml"
err4="$TD/stderr-bypass.txt"
out4="$(resolve --global "$GLOBAL" --project-root "$PROJ_BYPASS" 2>"$err4")"
has "$(cat "$err4")" "WARN ignored untrusted key roles from .devflow.yaml" \
  "roles: junk (not a mapping) is rejected with a WARN naming the whole prefix"
has "$(cat "$err4")" "WARN ignored untrusted key review from .devflow.yaml" \
  "review: unlimited (not a mapping) is rejected with a WARN naming the whole prefix"
is "$(printf '%s' "$out4" | python3 -c 'import json,sys; print(json.load(sys.stdin)["roles"]["implementer"]["agent"])')" "implementer" \
  "...the GLOBAL roles survive intact (not wiped by the bypass attempt)"
is "$(printf '%s' "$out4" | python3 -c 'import json,sys; print(json.load(sys.stdin)["review"]["max_passes"])')" "2" \
  "...the GLOBAL review budget survives intact too"

# (7) an unparseable construct in a config file is reported as `<path>:<line>: <msg>` and
# exits 2 — never a traceback, never partial output on stdout.
PROJ_BAD="$TD/proj-bad"; mkdir -p "$PROJ_BAD"
printf 'backend: claude\nthis has no colon at all\n' > "$PROJ_BAD/.devflow.yaml"
err5="$TD/stderr-bad.txt"
out5="$(resolve --global "$GLOBAL" --project-root "$PROJ_BAD" 2>"$err5")"; rc5=$?
is "$rc5" "2" "an unparseable construct in a project file -> exit 2"
is "$out5" "" "...and nothing at all is printed to stdout"
has "$(cat "$err5")" "devflow-config: $PROJ_BAD/.devflow.yaml:2:" "...stderr names the exact file and line"

# (8) a block sequence at the SAME indent as its key (`personas:\n- architect`), not indented
# further, is equally valid YAML and must parse (not raise "not a 'key: value' line").
PROJ_SEQ="$TD/proj-seq"; mkdir -p "$PROJ_SEQ"
cat > "$PROJ_SEQ/.devflow.yaml" <<YAML
backend: claude
personas:
- architect
- security
YAML
err6="$TD/stderr-seq.txt"
out6="$(resolve --global "$GLOBAL" --project-root "$PROJ_SEQ" 2>"$err6")"; rc6=$?
is "$rc6" "0" "a block sequence at the key's own indent parses without error"
is "$(cat "$err6")" "" "...with nothing on stderr"
is "$(printf '%s' "$out6" | python3 -c 'import json,sys; print(json.load(sys.stdin)["personas"])')" "['architect', 'security']" \
  "...and parses into the expected list"

# (9) the YAML subset is normative, not best-effort: constructs outside it fail loudly
# (exit 2, source line number on stderr, nothing on stdout) instead of silently degrading.

# (9a) a flow collection nested inside another flow collection used to be silently flattened
# to a raw string (`roles.reviewer` == the literal text `'{ agent: alice }'`) instead of being
# parsed or rejected.
PROJ_NESTEDFLOW="$TD/proj-nestedflow"; mkdir -p "$PROJ_NESTEDFLOW"
printf 'roles: { reviewer: { agent: alice } }\n' > "$PROJ_NESTEDFLOW/.devflow.yaml"
err7="$TD/stderr-nestedflow.txt"
out7="$(resolve --global "$GLOBAL" --project-root "$PROJ_NESTEDFLOW" 2>"$err7")"; rc7=$?
is "$rc7" "2" "nested flow mapping is rejected"
is "$out7" "" "...and nothing is printed to stdout"
has "$(cat "$err7")" "$PROJ_NESTEDFLOW/.devflow.yaml:1:" "...naming the exact line"

# (9b) a `---` document marker (multi-document YAML) is rejected rather than silently parsing
# only the first document.
PROJ_MULTIDOC="$TD/proj-multidoc"; mkdir -p "$PROJ_MULTIDOC"
printf -- '---\nbackend: claude\n' > "$PROJ_MULTIDOC/.devflow.yaml"
err8="$TD/stderr-multidoc.txt"
out8="$(resolve --global "$GLOBAL" --project-root "$PROJ_MULTIDOC" 2>"$err8")"; rc8=$?
is "$rc8" "2" "multi-document YAML is rejected"
has "$(cat "$err8")" "$PROJ_MULTIDOC/.devflow.yaml:1:" "...naming the '---' line"

# (9c) a top-level line that is mis-indented relative to the block it belongs to used to be
# silently dropped (`_parse_block` just stopped consuming) instead of being reported.
PROJ_TRAILING="$TD/proj-trailing"; mkdir -p "$PROJ_TRAILING"
cat > "$PROJ_TRAILING/.devflow.yaml" <<YAML
backend: claude
review:
  max_passes: 1
  fallback_to_host: false
   stray: mis-indented
YAML
err9="$TD/stderr-trailing.txt"
out9="$(resolve --global "$GLOBAL" --project-root "$PROJ_TRAILING" 2>"$err9")"; rc9=$?
is "$rc9" "2" "trailing content after the top-level block is rejected"
has "$(cat "$err9")" "$PROJ_TRAILING/.devflow.yaml:5:" "...naming the mis-indented line"

# (10) validate_profile (devflow-config.py fields): an execution profile with a malformed
# `roles`/role shape is INVALID_PROFILE, exit 6 — before this fix these were silently accepted
# or skipped (`roles: []` was skipped entirely as "not a dict"; `agent: ""` inside a dict role
# stays a valid, explicit "use the default execution path" sentinel, see the DECISION comment
# next to validate_profile in scripts/devflow-config.py).
fields(){ python3 "$CFGC" fields "$@"; }

ROLES_EMPTY_LIST="$TD/roles-empty-list.yaml"
printf 'roles: []\n' > "$ROLES_EMPTY_LIST"
out10="$(fields "$ROLES_EMPTY_LIST" 2>&1)"; rc10=$?
is "$rc10" "6" "roles: [] (not a mapping) -> INVALID_PROFILE, exit 6"
has "$out10" "INVALID_PROFILE" "...with the INVALID_PROFILE marker"

ROLES_EMPTY_STR="$TD/roles-empty-str.yaml"
printf 'roles: ""\n' > "$ROLES_EMPTY_STR"
out11="$(fields "$ROLES_EMPTY_STR" 2>&1)"; rc11=$?
is "$rc11" "6" 'roles: "" (not a mapping) -> INVALID_PROFILE, exit 6'

ROLES_STR_ROLE="$TD/roles-str-role.yaml"
printf 'roles: { reviewer: "" }\n' > "$ROLES_STR_ROLE"
out12="$(fields "$ROLES_STR_ROLE" 2>&1)"; rc12=$?
is "$rc12" "6" 'roles.reviewer: "" (not a mapping) -> INVALID_PROFILE, exit 6'

ROLES_LENS_EMPTY="$TD/roles-lens-empty.yaml"
cat > "$ROLES_LENS_EMPTY" <<YAML
roles:
  reviewer:
    lens: ""
YAML
out13="$(fields "$ROLES_LENS_EMPTY" 2>&1)"; rc13=$?
is "$rc13" "0" 'roles.reviewer.lens: "" stays valid (config.default.yaml ships this exact shape)'

ROLES_LENS_NONSTRING="$TD/roles-lens-nonstring.yaml"
cat > "$ROLES_LENS_NONSTRING" <<YAML
roles:
  reviewer:
    lens: 5
YAML
out13b="$(fields "$ROLES_LENS_NONSTRING" 2>&1)"; rc13b=$?
is "$rc13b" "6" "roles.reviewer.lens: 5 (not a string) -> INVALID_PROFILE, exit 6"

ROLES_AGENT_EMPTY="$TD/roles-agent-empty.yaml"
cat > "$ROLES_AGENT_EMPTY" <<YAML
roles:
  reviewer:
    agent: ""
YAML
out14="$(fields "$ROLES_AGENT_EMPTY" 2>&1)"; rc14=$?
is "$rc14" "0" 'roles.reviewer.agent: "" stays valid (explicit default-execution-path sentinel)'

rm -rf "$TD"
report
