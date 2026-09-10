#!/usr/bin/env bash
# Fix wave 2 — execution profiles: profile-init (Step 1's one call), deliverable-id (the one
# place a deliverable id is computed), result-write (atomic result.yaml), the CALL_ALREADY_CLOSED
# lease-guarded `dir --fresh` (already covered incrementally in 60-passes.sh/10-dir.sh; the
# RUN_ACTIVE lease itself lands here since it's new behaviour, not a format change to an
# existing assertion), and the R1 two-fallback JSON regression.
#
# DECISION-test-placement: every new R-block assertion (not just the three new subcommands)
# lives here rather than being scattered back into 10-dir.sh/65-preflight.sh — those two files
# stay byte-for-byte untouched per the implementation brief, which only permits 60-passes.sh to
# gain a message-format update. This file is the catch-all for "new fix-wave-2 behaviour, tested
# once, in one place."
set -u
. "$LIB/assert.sh"; . "$LIB/sandbox.sh"

mk_sandbox
run_dir_here

pi(){ ( cd "$REPO_FX" && bash "$RUNNER" profile-init "$@" ); }
did(){ ( cd "$REPO_FX" && bash "$RUNNER" deliverable-id "$@" ); }
rw(){ ( cd "$REPO_FX" && bash "$RUNNER" result-write "$@" ); }
dc(){ ( cd "$REPO_FX" && bash "$RUNNER" dir "$@" ); }
pf(){ ( cd "$REPO_FX" && bash "$RUNNER" preflight "$@" ); }

TD="$(mktemp -d "${TMPDIR:-/tmp}/devflow-profile.XXXXXX")"
AGENTS="$TD/agents"; mkdir -p "$AGENTS"
touch "$AGENTS/impl.md"   # "impl" resolves; "rev"/"ver" do not

off_json="$TD/off.json"
cat > "$off_json" <<JSON
{}
JSON

declared_json="$TD/declared.json"
cat > "$declared_json" <<JSON
{"roles": {"implementer": {"agent": ""}, "reviewer": {"agent": ""}, "verifier": {"agent": ""}}, "review": {"fallback_to_host": false}}
JSON

declared_mismatch_json="$TD/declared-mismatch.json"
cat > "$declared_mismatch_json" <<JSON
{"_manifest": {"host": "codex"}, "roles": {"implementer": {"agent": ""}, "reviewer": {"agent": ""}, "verifier": {"agent": ""}}, "review": {"fallback_to_host": false}}
JSON

active_bound_json="$TD/active-bound.json"
cat > "$active_bound_json" <<JSON
{"roles": {"implementer": {"agent": "impl"}, "reviewer": {"agent": ""}, "verifier": {"agent": ""}}, "review": {"fallback_to_host": false}}
JSON

active_maxpasses_json="$TD/active-maxpasses.json"
cat > "$active_maxpasses_json" <<JSON
{"roles": {"implementer": {"agent": ""}, "reviewer": {"agent": ""}, "verifier": {"agent": ""}}, "review": {"max_passes": 2, "fallback_to_host": false}}
JSON

missing_agent_json="$TD/missing-agent.json"
cat > "$missing_agent_json" <<JSON
{"roles": {"implementer": {"agent": ""}, "reviewer": {"agent": "rev"}, "verifier": {"agent": ""}}, "review": {"fallback_to_host": false}}
JSON

two_fallback_json="$TD/two-fallback.json"
cat > "$two_fallback_json" <<JSON
{"roles": {"implementer": {"agent": "rev"}, "reviewer": {"agent": "ver"}, "verifier": {"agent": ""}}, "review": {"fallback_to_host": true}}
JSON

invalid_json="$TD/invalid.json"
cat > "$invalid_json" <<JSON
{"executor_manifest": true}
JSON

# ── profile-init: off ────────────────────────────────────────────────────────────────────────
printf 'stale\n' > "$RUN_DIR/effective-roles.json"
out="$(DEVFLOW_AGENTS_DIR="$AGENTS" pi --roles-file "$off_json" --host claude 2>&1)"; rc=$?
is "$rc" "0" "profile-init: an empty roles-file is state=off, exit 0"
has "$out" "profile=off max_passes=0" "...reporting profile=off max_passes=0"
is "$(cat "$RUN_DIR/profile-active")" "off" "...profile-active is written as 'off'"
is "$(cat "$RUN_DIR/max-passes")" "0" "...max-passes is 0"
ok "[ ! -e '$RUN_DIR/effective-roles.json' ]" "...and a stale effective-roles.json is deleted, never left stale (R2)"

# ── profile-init: declared, no bindings, host matches -> exit 0 ─────────────────────────────
out="$(DEVFLOW_AGENTS_DIR="$AGENTS" pi --roles-file "$declared_json" --host claude 2>&1)"; rc=$?
is "$rc" "0" "profile-init: a roles-key-present-but-empty profile is state=declared, exit 0"
has "$out" "profile=declared max_passes=0" "...reporting profile=declared max_passes=0"
is "$(cat "$RUN_DIR/profile-active")" "declared" "...profile-active is written as 'declared'"
ok "[ -s '$RUN_DIR/effective-roles.json' ]" "...declared still writes effective-roles.json (preflight ran, per A12)"

# ── profile-init: declared, manifest host mismatch -> HOST_MISMATCH surfaces, exit 7 ────────
out="$(DEVFLOW_AGENTS_DIR="$AGENTS" pi --roles-file "$declared_mismatch_json" --host claude 2>&1)"; rc=$?
is "$rc" "7" "profile-init: declared state still runs preflight -> HOST_MISMATCH, exit 7, with no bindings at all"
has "$out" "HOST_MISMATCH manifest=codex host=claude" "...naming the mismatched hosts"

# ── profile-init: active via a bound agent -> exit 0, effective-roles.json carries the binding
out="$(DEVFLOW_AGENTS_DIR="$AGENTS" pi --roles-file "$active_bound_json" --host claude 2>&1)"; rc=$?
is "$rc" "0" "profile-init: a bound agent makes the profile active, exit 0"
has "$out" "profile=active max_passes=0" "...reporting profile=active (bound agent, max_passes still 0)"
is "$(cat "$RUN_DIR/profile-active")" "active" "...profile-active is written as 'active'"
is "$(python3 -c "import json;print(json.load(open('$RUN_DIR/effective-roles.json'))['implementer'])")" "impl" \
  "...effective-roles.json carries the resolved implementer binding"

# ── profile-init: active via max_passes>0 alone (no bindings) ──────────────────────────────
out="$(DEVFLOW_AGENTS_DIR="$AGENTS" pi --roles-file "$active_maxpasses_json" --host claude 2>&1)"; rc=$?
is "$rc" "0" "profile-init: max_passes>0 alone also makes the profile active, exit 0"
has "$out" "profile=active max_passes=2" "...reporting profile=active max_passes=2"
is "$(cat "$RUN_DIR/max-passes")" "2" "...max-passes file carries the validated integer"

# ── profile-init: MISSING_AGENT passes through as exit 4, and leaves no effective-roles.json ─
out="$(DEVFLOW_AGENTS_DIR="$AGENTS" pi --roles-file "$missing_agent_json" --host claude 2>&1)"; rc=$?
is "$rc" "4" "profile-init: an unresolvable bound agent (no fallback) -> exit 4"
has "$out" "MISSING_AGENT reviewer=rev" "...naming the missing role=agent"
ok "[ ! -e '$RUN_DIR/effective-roles.json' ]" "...and no effective-roles.json is left behind on a hard failure"

# ── profile-init: INVALID_PROFILE passes through as exit 6 ─────────────────────────────────
out="$(pi --roles-file "$invalid_json" --host claude 2>&1)"; rc=$?
is "$rc" "6" "profile-init: an invalid profile shape -> exit 6"
has "$out" "INVALID_PROFILE" "...with the INVALID_PROFILE marker"

# ── profile-init: usage guards ──────────────────────────────────────────────────────────────
out="$(pi --roles-file "$TD/does-not-exist.json" --host claude 2>&1)"; rc=$?
is "$rc" "2" "profile-init: a --roles-file that doesn't exist is a usage error, exit 2"
out="$(pi --roles-file "$off_json" --host bogus 2>&1)"; rc=$?
is "$rc" "2" "profile-init: an unknown --host is a usage error, exit 2"

# ── R1: two fallbacks still produce valid JSON (the $(printf ...) newline-stripping bug) ────
eff="$TD/effective-roles-two-fallback.json"
out="$(DEVFLOW_AGENTS_DIR="$AGENTS" pf --roles-file "$two_fallback_json" --host claude --write-effective "$eff" 2>&1)"; rc=$?
is "$rc" "0" "R1: preflight with two missing agents + fallback_to_host:true still exits 0"
python3 -m json.tool "$eff" >/dev/null 2>&1
is "$?" "0" "R1: --write-effective's output is still valid JSON with two fallback records"
is "$(python3 -c "import json;print(len(json.load(open('$eff'))['fallbacks']))")" "2" \
  "...and both fallback records made it in (not merged into one malformed line)"

# ── deliverable-id: impl phase without impl-base -> NO_IMPL_BASE, exit 2 ────────────────────
rm -f "$RUN_DIR/deliverable" "$RUN_DIR/deliverable-phase" "$RUN_DIR/impl-base" "$RUN_DIR/pipeline"
out="$(did --phase impl 2>&1)"; rc=$?
is "$rc" "2" "deliverable-id: --phase impl with no impl-base -> exit 2"
is "$out" "NO_IMPL_BASE" "...with the exact NO_IMPL_BASE marker"

# ── deliverable-id: impl phase computes impl-<impl-base>, persists it, idempotent ──────────
printf 'abc123\n' > "$RUN_DIR/impl-base"
out="$(did --phase impl 2>&1)"; rc=$?
is "$rc" "0" "deliverable-id: --phase impl with impl-base present -> exit 0"
is "$out" "impl-abc123" "...prints impl-<impl-base>"
is "$(cat "$RUN_DIR/deliverable")" "impl-abc123" "...and persists it to \$RUN_DIR/deliverable"
out2="$(did --phase impl 2>&1)"; rc2=$?
is "$rc2" "0" "deliverable-id: re-running the SAME phase with the SAME impl-base is idempotent"
is "$out2" "impl-abc123" "...same id, no error"

# ── deliverable-id: review phase WITH pipeline inherits impl's id, not --baseline ───────────
# (still recorded phase="impl" here -> a DIFFERENT phase ("review") is free to overwrite even
# though the id changes, per the idempotency rule below.)
: > "$RUN_DIR/pipeline"
out="$(did --phase review --baseline deadbeef 2>&1)"; rc=$?
is "$rc" "0" "deliverable-id: --phase review with impl-base AND pipeline -> exit 0"
is "$out" "impl-abc123" "...inherits impl's id (devflow-run owns the pipeline) instead of minting review-<baseline>"

# ── deliverable-id: review phase without pipeline needs --baseline -> NO_BASELINE, exit 2 ───
rm -f "$RUN_DIR/deliverable" "$RUN_DIR/deliverable-phase" "$RUN_DIR/pipeline"
out="$(did --phase review 2>&1)"; rc=$?
is "$rc" "2" "deliverable-id: --phase review, no pipeline, no --baseline -> exit 2"
is "$out" "NO_BASELINE" "...with the exact NO_BASELINE marker"

# ── deliverable-id: review phase without pipeline, --baseline given -> review-<sha> ─────────
out="$(did --phase review --baseline deadbeef 2>&1)"; rc=$?
is "$rc" "0" "deliverable-id: --phase review with --baseline (no pipeline) -> exit 0"
is "$out" "review-deadbeef" "...prints review-<baseline>"

# ── deliverable-id: DELIVERABLE_CHANGED when the SAME phase would now compute a DIFFERENT id ─
out="$(did --phase review --baseline cafef00d 2>&1)"; rc=$?
is "$rc" "8" "deliverable-id: the SAME phase computing a DIFFERENT id -> exit 8, never a silent overwrite"
is "$out" "DELIVERABLE_CHANGED old=review-deadbeef new=review-cafef00d" "...naming old and new"
is "$(cat "$RUN_DIR/deliverable")" "review-deadbeef" "...and the recorded deliverable is left untouched"

# ── deliverable-id: plan phase hashes --plan-path (not its contents) ───────────────────────
rm -f "$RUN_DIR/deliverable" "$RUN_DIR/deliverable-phase"
out="$(did --phase plan --plan-path "/tmp/some/plan.md" 2>&1)"; rc=$?
is "$rc" "0" "deliverable-id: --phase plan with --plan-path -> exit 0"
has "$out" "plan-" "...prints a plan-<16-hex-char> id"
out="$(did --phase plan 2>&1)"; rc=$?
is "$rc" "2" "deliverable-id: --phase plan without --plan-path is a usage error, exit 2"

# ── result-write: stdin -> tmp -> mv, no .tmp.* left behind ─────────────────────────────────
result_path="$RUN_DIR/result.yaml"
out="$(printf 'status: DONE\n' | rw --path "$result_path" 2>&1)"; rc=$?
is "$rc" "0" "result-write: writes stdin to --path, exit 0"
is "$(cat "$result_path")" "status: DONE" "...and the file holds exactly the stdin body"
leftover="$(find "$RUN_DIR" -maxdepth 1 -name 'result.yaml.tmp.*' 2>/dev/null)"
is "$leftover" "" "...and leaves no .tmp.* file behind"
out="$(rw 2>&1)"; rc=$?
is "$rc" "2" "result-write: --path is required, usage error exit 2"

# ── dir --fresh: refuses while a run is active (a live lease), --force overrides ───────────
: > "$RUN_DIR/.active-$$"   # this test shell's own pid -- alive for the duration of this case
out="$(dc --fresh 2>&1)"; rc=$?
is "$rc" "9" "dir --fresh refuses while a run is active"
is "$out" "RUN_ACTIVE pid=$$" "...naming exactly the live pid"
ok "[ -e '$RUN_DIR/.active-'$$ ]" "...and the lease itself is left in place (this run is still active)"
out="$(dc --fresh --force 2>&1)"; rc=$?
is "$rc" "0" "dir --fresh --force overrides an active lease"

# ── dir --fresh: a stale lease (pid not alive) is ignored and removed, not refused ──────────
( exit 0 ) & deadpid=$!
wait "$deadpid" 2>/dev/null
: > "$RUN_DIR/.active-$deadpid"
out="$(dc --fresh 2>&1)"; rc=$?
is "$rc" "0" "dir --fresh ignores a stale lease (pid no longer answers kill -0)"
ok "[ ! -e '$RUN_DIR/.active-'$deadpid ]" "...and removes the stale lease file"

rm -rf "$TD"
cleanup_sandbox
report
