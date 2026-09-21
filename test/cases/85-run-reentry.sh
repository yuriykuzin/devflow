#!/usr/bin/env bash
# devflow:run Step 0's re-entry gate (WIN-188 follow-up + fix wave F1/F2/F3/F4/F5): a context
# compaction re-entering Step 0 mid-run must not wipe RUN_DIR when an execution profile is
# bound — `dir --fresh` stays byte-for-byte the same unconditional wipe it always was (see
# 60-passes.sh:101-104); what changed is only WHETHER Step 0 calls it. There is no executable to
# invoke directly (Step 0 lives in skill markdown, not scripts/devflow-runner.sh), so this case
# mirrors the exact gate `skills/devflow-run/SKILL.md` Step 0 runs — same PROFILE_ACTIVE branch,
# same dir --check-active call (F5), same plan-path/feature-key logic (F3/F4), same refusal
# text — against the real runner subcommands it calls (`dir`, `dir --fresh`, `dir --check-active`,
# `passes ...`). If Step 0's bash and this mirror ever drift, only this comment ties them
# together; keep them in sync by hand.
set -u
. "$LIB/assert.sh"; . "$LIB/sandbox.sh"

mk_sandbox
run_dir_here

# _fhash FEAT -> the same hash Step 0 keys an unbound-plan feature on (F3/F4): shasum -a 256 of
# the FULL description, not a 40-char truncation.
_fhash(){ printf '%s' "$1" | shasum -a 256 | cut -d' ' -f1 | cut -c1-16; }

# step0 PROFILE_ACTIVE FEATURE_DESCRIPTION -> stdout "RUN_DIR=..." on success (rc 0), or the
# refusal line on stderr with rc 1. Mirrors skills/devflow-run/SKILL.md Step 0's "Set up the
# run once" block AFTER its resolve/PROFILE_ACTIVE derivation — profile_active is a parameter
# here, not derived from a real resolve. See step0_resolve_check below for the real resolve
# gate (F1), which this helper deliberately bypasses.
step0(){
  local profile_active="$1" feat="$2"
  (
    cd "$REPO_FX" || exit 1
    local rd pa fk fh fr held_hash held_epoch held_readable age out dc active_out active_rc
    rd="$(bash "$RUNNER" dir | sed -n 's/^RUN_DIR=//p')"
    pa="$profile_active"
    if [ "$pa" = 1 ]; then
      # F5: additive, non-destructive lease check — plain `dir` never reads .active-<pid>.
      active_out="$(bash "$RUNNER" dir --check-active)"; active_rc=$?
      if [ "$active_rc" -eq 9 ]; then
        echo "devflow: another devflow run is active in this checkout ($active_out) — RUN_ACTIVE." >&2
        exit 1
      fi
      fk="$rd/feature-key"
      if [ -s "$rd/plan-path" ] && [ -s "$fk" ]; then
        # F3: an established run STILL MID-FLIGHT (plan-path AND feature-key both survive) is
        # identified by its own persisted state — FEATURE_DESCRIPTION (retyped prose) is not
        # consulted at all. Only the 24h staleness check still applies. plan-path alone is NOT
        # enough (it deliberately outlives a finished run, DECISION-impl-base-cleanup) — the
        # fix-of-fix below.
        held_epoch="$(sed -n '2p' "$fk")"
        age=$(( $(date +%s) - ${held_epoch:-0} ))
        if [ "$age" -gt 86400 ]; then
          held_readable="$(sed -n '3p' "$fk")"
          echo "devflow: RUN_DIR is held by another run (feature=${held_readable:-?}, started epoch $held_epoch) — refusing to silently resume or wipe it. If that run is abandoned, re-run with: bash \"$RUNNER\" dir --fresh" >&2
          exit 1
        fi
      else
        # F4: key on a hash of the FULL description, not a 40-char truncated slug — two
        # different features must not collide on one shared prefix.
        fh="$(_fhash "$feat")"
        fr="$(printf '%s' "$feat" | tr '[:upper:] ' '[:lower:]-' | tr -cd 'a-z0-9-' | cut -c1-40)"
        fr="${fr:-feature}"
        if [ -s "$fk" ]; then
          held_hash="$(sed -n '1p' "$fk")"
          held_epoch="$(sed -n '2p' "$fk")"
          held_readable="$(sed -n '3p' "$fk")"
          age=$(( $(date +%s) - ${held_epoch:-0} ))
          if [ "$held_hash" != "$fh" ] || [ "$age" -gt 86400 ]; then
            echo "devflow: RUN_DIR is held by another run (feature=${held_readable:-?}, started epoch $held_epoch) — refusing to silently resume or wipe it. If that run is abandoned, re-run with: bash \"$RUNNER\" dir --fresh" >&2
            exit 1
          fi
        else
          printf '%s\n%s\n%s\n' "$fh" "$(date +%s)" "$fr" > "$fk"
        fi
      fi
    else
      out="$(bash "$RUNNER" dir --fresh)"; dc=$?
      if [ "$dc" -eq 9 ]; then
        echo "devflow: another devflow run is active in this checkout ($out) — RUN_ACTIVE." >&2
        exit 1
      fi
      rd="$(printf '%s\n' "$out" | sed -n 's/^RUN_DIR=//p')"
    fi
    : > "$rd/pipeline"
    echo "RUN_DIR=$rd"
  )
}

# step0_resolve_check FEAT -> mirrors ONLY Step 0's F1 gate (the real config resolve, and its
# rc -> NEEDS_USER_DECISION/exit-1 stop) against the ACTUAL resolver — unlike step0() above,
# which takes profile_active as a parameter and never calls resolve at all.
step0_resolve_check(){
  local feat="$1"
  (
    cd "$REPO_FX" || exit 1
    local rd cfgc rrc
    rd="$(bash "$RUNNER" dir | sed -n 's/^RUN_DIR=//p')"
    cfgc="$(dirname "$RUNNER")/devflow-config.py"
    python3 "$cfgc" resolve --project-root . > "$rd/resolved-config.json"; rrc=$?
    if [ "$rrc" -ne 0 ]; then
      echo "devflow: could not resolve config at Step 0 (rc=$rrc) -> NEEDS_USER_DECISION. Nothing was wiped; see the resolver's error above." >&2
      exit 1
    fi
    echo "RUN_DIR=$rd"
  )
}

p(){ ( cd "$REPO_FX" && bash "$RUNNER" passes "$@" ); }

# ── (A) bound profile: a second Step 0 entry PRESERVES passes-<deliverable>.* and plan-path ──
out="$(step0 1 "feature alpha" 2>&1)"; rc=$?
is "$rc" "0" "profile bound: first Step 0 entry succeeds"
has "$out" "RUN_DIR=$RUN_DIR" "...and lands on the deterministic RUN_DIR"
ok "[ -s '$RUN_DIR/feature-key' ]" "...and writes feature-key on first entry"

p init --deliverable d1 --max 2 >/dev/null
p reserve --deliverable d1 --call-id c1 >/dev/null
printf 'docs/devflow/reports/2026-09-21-alpha.md\n' > "$RUN_DIR/plan-path"

out2="$(step0 1 "feature alpha" 2>&1)"; rc2=$?
is "$rc2" "0" "profile bound: second (re-entry) Step 0 call also succeeds"
has "$out2" "RUN_DIR=$RUN_DIR" "...and resumes the SAME RUN_DIR (no wipe)"

st="$(p status --deliverable d1)"
is "$st" "used=1 max=2 open=c1 done=no scope=-" "...pass-budget state for d1 survives the re-entry"
is "$(cat "$RUN_DIR/plan-path")" "docs/devflow/reports/2026-09-21-alpha.md" "...plan-path survives the re-entry"

# ── (B) no profile bound: a second entry still wipes (today's behaviour, unchanged) ─────────
( cd "$REPO_FX" && bash "$RUNNER" dir --fresh ) >/dev/null   # clean slate for this scenario
step0 0 "feature beta" >/dev/null 2>&1
p init --deliverable d2 --max 2 >/dev/null
p reserve --deliverable d2 --call-id c1 >/dev/null
printf 'docs/devflow/reports/2026-09-21-beta.md\n' > "$RUN_DIR/plan-path"

outB="$(step0 0 "feature beta" 2>&1)"; rcB=$?
is "$rcB" "0" "no profile: second Step 0 entry still succeeds"
stB="$(p status --deliverable d2)"
is "$stB" "used=0 max=- open= done=no scope=-" "...but wipes the pass-budget state, same as HEAD"
ok "[ ! -e '$RUN_DIR/plan-path' ]" "...and wipes plan-path too (unconditional --fresh, no special-casing)"

# ── (C) feature-key hash mismatch (no plan-path yet) -> refusal, escape hatch, RUN_DIR untouched
( cd "$REPO_FX" && bash "$RUNNER" dir --fresh ) >/dev/null
step0 1 "feature gamma" >/dev/null 2>&1
p init --deliverable d3 --max 1 >/dev/null
sentinel_before="$(cat "$RUN_DIR/feature-key")"

outC="$(step0 1 "a totally different feature" 2>&1)"; rcC=$?
is "$rcC" "1" "feature-key hash mismatch -> refusal, exit 1"
has "$outC" "held by another run" "...naming the held run"
has "$outC" "dir --fresh" "...and printing the exact escape-hatch command"
is "$(cat "$RUN_DIR/feature-key")" "$sentinel_before" "...feature-key itself is left untouched"
stC="$(p status --deliverable d3)"
is "$stC" "used=0 max=1 open= done=no scope=-" "...and RUN_DIR state (d3's budget) is left untouched, not wiped"

# ── (D) feature-key older than 24h -> same refusal, even with a matching feature ────────────
( cd "$REPO_FX" && bash "$RUNNER" dir --fresh ) >/dev/null
step0 1 "feature delta" >/dev/null 2>&1
p init --deliverable d4 --max 1 >/dev/null
stale_epoch=$(( $(date +%s) - 90000 ))   # 25h ago
printf '%s\n%s\n%s\n' "$(_fhash "feature delta")" "$stale_epoch" "feature-delta" > "$RUN_DIR/feature-key"

outD="$(step0 1 "feature delta" 2>&1)"; rcD=$?
is "$rcD" "1" "feature-key older than 24h -> refusal, exit 1, even for the SAME feature"
has "$outD" "held by another run" "...naming the held run"
has "$outD" "dir --fresh" "...and printing the exact escape-hatch command"
stD="$(p status --deliverable d4)"
is "$stD" "used=0 max=1 open= done=no scope=-" "...and RUN_DIR state (d4's budget) is left untouched, not wiped"

# ── (E) F5: a live .active-<pid> lease stops the profile-active branch — no concurrency check
# existed there before this fix; must not truncate pipeline.
( cd "$REPO_FX" && bash "$RUNNER" dir --fresh ) >/dev/null
step0 1 "feature epsilon" >/dev/null 2>&1
printf 'not-empty\n' > "$RUN_DIR/pipeline"
sleep 100 & sleeper_pid=$!
: > "$RUN_DIR/.active-$sleeper_pid"

outE="$(step0 1 "feature epsilon" 2>&1)"; rcE=$?
is "$rcE" "1" "F5: a live .active-<pid> lease stops the profile-active branch, exit 1"
has "$outE" "RUN_ACTIVE" "...naming RUN_ACTIVE"
is "$(cat "$RUN_DIR/pipeline")" "not-empty" "...and does not truncate pipeline"

kill "$sleeper_pid" 2>/dev/null; wait "$sleeper_pid" 2>/dev/null
rm -f "$RUN_DIR/.active-$sleeper_pid"

# ── (F) F1: an unresolvable global config (executor_manifest points nowhere) -> Step 0's REAL
# resolve fails closed: exit 1, RUN_DIR state left untouched (never falls through to the wipe).
# Exercises the real resolve -> PROFILE_ACTIVE derivation, not the profile_active parameter
# step0() takes above.
( cd "$REPO_FX" && bash "$RUNNER" dir --fresh ) >/dev/null
p init --deliverable d6 --max 2 >/dev/null
p reserve --deliverable d6 --call-id c1 >/dev/null
printf 'docs/devflow/reports/2026-09-21-zeta.md\n' > "$RUN_DIR/plan-path"

cat >> "$HOME/.devflow/config.yaml" <<YAML
executor_manifest: "$SB/no-such-manifest.yaml"
YAML

outF="$(step0_resolve_check "feature zeta" 2>&1)"; rcF=$?
is "$rcF" "1" "F1: an unresolvable config -> Step 0 exits non-zero"
has "$outF" "NEEDS_USER_DECISION" "...reporting NEEDS_USER_DECISION, not silently proceeding"
stF="$(p status --deliverable d6)"
is "$stF" "used=1 max=2 open=c1 done=no scope=-" "...and RUN_DIR state (d6's budget) is still there afterwards, never wiped"
is "$(cat "$RUN_DIR/plan-path")" "docs/devflow/reports/2026-09-21-zeta.md" "...plan-path is still there afterwards too"

# ── (G) F2: after a terminal Finalize (pipeline + feature-key removed, same as Step 4 and the
# terminal error exits), a brand-new feature's first Step 0 entry succeeds instead of hitting
# the stale feature-key refusal, and the OLD deliverable's budget is left untouched (not wiped,
# but also no longer referenced by anything new) — the new feature never gets routed onto it.
( cd "$REPO_FX" && bash "$RUNNER" dir --fresh ) >/dev/null
step0 1 "feature theta" >/dev/null 2>&1
p init --deliverable d7 --max 1 >/dev/null
p reserve --deliverable d7 --call-id c1 >/dev/null
rm -f "$RUN_DIR/pipeline" "$RUN_DIR/feature-key"   # Finalize (Step 4) / terminal error exits

outG="$(step0 1 "an entirely unrelated feature" 2>&1)"; rcG=$?
is "$rcG" "0" "F2: a brand-new feature after Finalize is NOT refused by the old feature-key"
has "$outG" "RUN_DIR=$RUN_DIR" "...and lands on the same checkout's RUN_DIR"
st7="$(p status --deliverable d7)"
is "$st7" "used=1 max=1 open=c1 done=no scope=-" "...the OLD deliverable's budget is untouched (no wipe), just no longer inherited"

# ── (G2) the plan-path bypass requires feature-key too: plan-path ALONE (which legitimately
# outlives a finished run — DECISION-impl-base-cleanup leaves plan-path/impl-base alone at
# Finalize) must not let an unrelated NEW feature silently resume a finished run's identity.
# This is scenario G but WITH plan-path actually populated before Finalize — the common case,
# since every completed run has one (Phase 1 writes it).
( cd "$REPO_FX" && bash "$RUNNER" dir --fresh ) >/dev/null
step0 1 "feature theta with a plan" >/dev/null 2>&1
theta_key_hash="$(sed -n '1p' "$RUN_DIR/feature-key")"
p init --deliverable dtheta --max 2 >/dev/null
p reserve --deliverable dtheta --call-id c1 >/dev/null
printf 'docs/devflow/reports/2026-09-21-theta.md\n' > "$RUN_DIR/plan-path"
printf 'deadbeef\n' > "$RUN_DIR/impl-base"

# Mid-flight re-entry (feature-key still present, run not yet finalized): F3 still holds —
# resumes without consulting FEATURE_DESCRIPTION, budget untouched.
outG2mid="$(step0 1 "feature theta with a plan" 2>&1)"; rcG2mid=$?
is "$rcG2mid" "0" "F3 still holds: a mid-flight re-entry (feature-key present) resumes"
stG2mid="$(p status --deliverable dtheta)"
is "$stG2mid" "used=1 max=2 open=c1 done=no scope=-" "...and its pass budget is untouched by the resume"

# Finalize: only pipeline + feature-key are cleared (plan-path/impl-base deliberately survive)
# — this is the actual state a finished run leaves behind.
rm -f "$RUN_DIR/pipeline" "$RUN_DIR/feature-key"

outG2="$(step0 1 "an entirely different next feature" 2>&1)"; rcG2=$?
is "$rcG2" "0" "a genuinely new feature after Finalize is NOT silently resumed via lingering plan-path"
ok "[ -s '$RUN_DIR/feature-key' ]" "...and a fresh feature-key is written for it (identity re-established, not skipped)"
is "$(sed -n '1p' "$RUN_DIR/feature-key")" "$(_fhash "an entirely different next feature")" "...keyed to the NEW feature's own hash"
isnt "$(sed -n '1p' "$RUN_DIR/feature-key")" "$theta_key_hash" "...not theta's hash (no silent inheritance of its identity)"
stG2theta="$(p status --deliverable dtheta)"
is "$stG2theta" "used=1 max=2 open=c1 done=no scope=-" "...theta's OLD pass budget is left alone (not wiped), and the new feature is never routed onto it"
is "$(cat "$RUN_DIR/impl-base")" "deadbeef" "...theta's impl-base file is untouched too (out of scope, DECISION-impl-base-cleanup)"

# ── (H) F3: once plan-path exists, a re-typed/reworded description resumes rather than refuses
( cd "$REPO_FX" && bash "$RUNNER" dir --fresh ) >/dev/null
step0 1 "WIN-188: add ElevenLabs voiceover to the course player" >/dev/null 2>&1
p init --deliverable d9 --max 2 >/dev/null
p reserve --deliverable d9 --call-id c1 >/dev/null
printf 'docs/devflow/reports/2026-09-21-voiceover.md\n' > "$RUN_DIR/plan-path"

outH="$(step0 1 "add voiceover to the course player" 2>&1)"; rcH=$?
is "$rcH" "0" "F3: a reworded re-typed description resumes once plan-path exists (not refused)"
stH="$(p status --deliverable d9)"
is "$stH" "used=1 max=2 open=c1 done=no scope=-" "...and the established run's pass budget survives the reword"

# ── (I) F4: two descriptions sharing a 40-char prefix get DIFFERENT keys (no plan yet) ───────
( cd "$REPO_FX" && bash "$RUNNER" dir --fresh ) >/dev/null
step0 1 "add voiceover support to the course player, phase 1" >/dev/null 2>&1
p init --deliverable d10 --max 1 >/dev/null
sentinel_i="$(cat "$RUN_DIR/feature-key")"

outI="$(step0 1 "add voiceover support to the course player, phase 2" 2>&1)"; rcI=$?
is "$rcI" "1" "F4: same 40-char prefix, different description still refuses (distinct hash key)"
is "$(cat "$RUN_DIR/feature-key")" "$sentinel_i" "...feature-key untouched (no silent inheritance of phase 1's state)"

cleanup_sandbox
report
