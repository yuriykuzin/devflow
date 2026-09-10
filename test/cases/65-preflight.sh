#!/usr/bin/env bash
# preflight: checks whether every non-empty roles.*.agent binding is actually usable on the
# named host, BEFORE a phase starts calling it. An unresolvable binding is a hard error
# (exit 4/5), never a silent fallback, unless review.fallback_to_host explicitly says so.
set -u
. "$LIB/assert.sh"

TD="$(mktemp -d "${TMPDIR:-/tmp}/devflow-preflight.XXXXXX")"
pf(){ bash "$RUNNER" preflight "$@"; }

AGENTS="$TD/agents"; mkdir -p "$AGENTS"
touch "$AGENTS/implementer.md"     # "implementer" resolves; "reviewer" does not

full_no_fallback="$TD/full-no-fallback.json"
cat > "$full_no_fallback" <<JSON
{"roles": {"implementer": {"agent": "implementer"}, "reviewer": {"agent": "reviewer"}, "verifier": {"agent": ""}}, "review": {"fallback_to_host": false}}
JSON

full_fallback="$TD/full-fallback.json"
cat > "$full_fallback" <<JSON
{"roles": {"implementer": {"agent": "implementer"}, "reviewer": {"agent": "reviewer"}, "verifier": {"agent": ""}}, "review": {"fallback_to_host": true}}
JSON

empty="$TD/empty.json"
cat > "$empty" <<JSON
{"roles": {"implementer": {"agent": ""}, "reviewer": {"agent": ""}, "verifier": {"agent": ""}}, "review": {"fallback_to_host": false}}
JSON

# (1) claude host, a bound agent ("reviewer") not present under DEVFLOW_AGENTS_DIR -> exit 4.
out="$(DEVFLOW_AGENTS_DIR="$AGENTS" pf --roles-file "$full_no_fallback" --host claude 2>&1)"; rc=$?
is "$rc" "4" "claude host, unresolvable bound agent -> exit 4"
is "$out" "MISSING_AGENT reviewer=reviewer" "...naming exactly the missing role=agent"

# (2) same roles file, fallback_to_host: true -> exit 0, FALLBACK line instead.
out="$(DEVFLOW_AGENTS_DIR="$AGENTS" pf --roles-file "$full_fallback" --host claude 2>&1)"; rc=$?
is "$rc" "0" "fallback_to_host:true downgrades the missing agent to exit 0"
is "$out" "FALLBACK_TO_HOST reviewer=reviewer" "...printing FALLBACK_TO_HOST for the affected role"

# (3) claude host, every bound agent resolvable -> exit 0, no output.
resolvable="$TD/resolvable.json"
cat > "$resolvable" <<JSON
{"roles": {"implementer": {"agent": "implementer"}, "reviewer": {"agent": ""}, "verifier": {"agent": ""}}, "review": {"fallback_to_host": false}}
JSON
out="$(DEVFLOW_AGENTS_DIR="$AGENTS" pf --roles-file "$resolvable" --host claude 2>&1)"; rc=$?
is "$rc" "0" "claude host, all bound agents resolvable -> exit 0"
is "$out" "" "...and nothing is printed"

# (4) non-claude host with a non-empty binding, no fallback -> exit 5, named-agent delegation
# unsupported on that host.
out="$(pf --roles-file "$full_no_fallback" --host codex 2>&1)"; rc=$?
is "$rc" "5" "non-claude host with a bound agent (no fallback) -> exit 5"
is "$out" "NO_NAMED_AGENTS host=codex" "...naming the host that can't do named-agent delegation"

# (5) non-claude host, fallback_to_host:true -> exit 0, one FALLBACK_TO_HOST line per bound role.
out="$(pf --roles-file "$full_fallback" --host codex 2>&1)"; rc=$?
is "$rc" "0" "non-claude host, fallback_to_host:true -> exit 0"
has "$out" "FALLBACK_TO_HOST implementer=implementer" "...one line for the bound implementer"
has "$out" "FALLBACK_TO_HOST reviewer=reviewer" "...and one for the bound reviewer"

# (6) non-claude host, every binding empty -> exit 0 regardless of fallback.
out="$(pf --roles-file "$empty" --host codex 2>&1)"; rc=$?
is "$rc" "0" "non-claude host, all bindings empty -> exit 0"
is "$out" "" "...and nothing is printed"
out="$(pf --roles-file "$empty" --host claude 2>&1)"; rc=$?
is "$rc" "0" "claude host, all bindings empty -> exit 0 too"

# (7) usage guards
out="$(pf --roles-file "$empty" --host bogus-host 2>&1)"; rc=$?
isnt "$rc" "0" "an unknown --host is a usage error"
out="$(pf --roles-file "$TD/does-not-exist.json" --host claude 2>&1)"; rc=$?
isnt "$rc" "0" "a --roles-file that doesn't exist is a usage error"

# (8) --write-effective writes effective-roles.json on the exit-0 path, with a fallback
# reflected as agent -> "" and listed under fallbacks[].
eff="$TD/effective-roles.json"
out="$(DEVFLOW_AGENTS_DIR="$AGENTS" pf --roles-file "$full_fallback" --host claude --write-effective "$eff" 2>&1)"; rc=$?
is "$rc" "0" "fallback_to_host:true + --write-effective still exits 0"
ok "[ -s '$eff' ]" "...and writes effective-roles.json"
is "$(python3 -c "import json;print(json.load(open('$eff'))['implementer'])")" "implementer" \
  "...implementer (resolved fine) keeps its bound agent"
is "$(python3 -c "import json;print(json.load(open('$eff'))['reviewer'])")" "" \
  "...reviewer (fell back) is blanked to the default execution path"
is "$(python3 -c "import json;print(json.load(open('$eff'))['fallbacks'])")" \
  "[{'role': 'reviewer', 'requested': 'reviewer'}]" "...and is listed under fallbacks[]"

# (9) a resolvable roles-file with no fallback needed still writes effective-roles.json with
# an empty fallbacks[] and roles.reviewer.lens carried through.
eff2="$TD/effective-roles2.json"
resolvable_lens="$TD/resolvable-lens.json"
cat > "$resolvable_lens" <<JSON
{"roles": {"implementer": {"agent": "implementer"}, "reviewer": {"agent": "", "lens": "qa"}, "verifier": {"agent": ""}}, "review": {"fallback_to_host": false}}
JSON
out="$(DEVFLOW_AGENTS_DIR="$AGENTS" pf --roles-file "$resolvable_lens" --host claude --write-effective "$eff2" 2>&1)"; rc=$?
is "$rc" "0" "fully resolvable roles-file + --write-effective exits 0"
is "$(python3 -c "import json;print(json.load(open('$eff2'))['reviewer_lens'])")" "qa" \
  "...reviewer_lens carries through to effective-roles.json"
is "$(python3 -c "import json;print(json.load(open('$eff2'))['fallbacks'])")" "[]" \
  "...fallbacks[] is empty when nothing fell back"

# (10) INVALID_PROFILE: an unresolvable-typed profile is rejected before any agent checks,
# exit 6, never the exit 0/4/5 an ordinary binding check would give it.
bad_manifest_bool="$TD/bad-manifest-bool.json"
cat > "$bad_manifest_bool" <<JSON
{"executor_manifest": true, "roles": {"implementer": {"agent": ""}, "reviewer": {"agent": ""}, "verifier": {"agent": ""}}}
JSON
out="$(pf --roles-file "$bad_manifest_bool" --host claude 2>&1)"; rc=$?
is "$rc" "6" "executor_manifest: true (not 1) -> INVALID_PROFILE, exit 6"
has "$out" "INVALID_PROFILE" "...with the INVALID_PROFILE marker"

bad_max="$TD/bad-max.json"
cat > "$bad_max" <<JSON
{"roles": {"implementer": {"agent": ""}, "reviewer": {"agent": ""}, "verifier": {"agent": ""}}, "review": {"max_passes": -1}}
JSON
out="$(pf --roles-file "$bad_max" --host claude 2>&1)"; rc=$?
is "$rc" "6" "review.max_passes: -1 -> INVALID_PROFILE, exit 6"

bad_role="$TD/bad-role.json"
cat > "$bad_role" <<JSON
{"roles": {"typo_role": {"agent": "x"}}}
JSON
out="$(pf --roles-file "$bad_role" --host claude 2>&1)"; rc=$?
is "$rc" "6" "an unknown role name -> INVALID_PROFILE, exit 6"

bad_fallback_str="$TD/bad-fallback-str.json"
cat > "$bad_fallback_str" <<JSON
{"roles": {"implementer": {"agent": ""}}, "review": {"fallback_to_host": "yes"}}
JSON
out="$(pf --roles-file "$bad_fallback_str" --host claude 2>&1)"; rc=$?
is "$rc" "6" "review.fallback_to_host: \"yes\" (a string, not a boolean) -> INVALID_PROFILE, exit 6"

rm -rf "$TD"
report
