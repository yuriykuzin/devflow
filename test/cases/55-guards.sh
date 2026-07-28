#!/usr/bin/env bash
# Two guards against SILENT substitution — both were found by hammering the harness, where each
# produced an intermittently red suite that looked like a timing flake:
#   1. the verdict extractor failing to RUN is not the same as a reviewer producing nothing;
#   2. a configured codex.command_path whose probe fails must never be replaced by another
#      binary (in the sandbox that meant the real, network-calling codex CLI ran instead of the
#      stub — a test suite quietly making API calls).
set -u
export DEVFLOW_POLL_SCHEDULE="1 1 1 1 1 1 1 1 1 1"
. "$LIB/assert.sh"; . "$LIB/sandbox.sh"

mk_sandbox
run_dir_here
cd "$REPO_FX"
PF="$SB/prompt.txt"; printf 'review this\n' > "$PF"
JSONC="$(cd "$(dirname "$RUNNER")" && pwd)/devflow-json.py"

# --- the gate's artifacts must not sit in a write-mode call's writable root -------------------
# `--role implementer` runs codex --full-auto (sandbox_mode=workspace-write), whose default
# writable roots include $TMPDIR and /tmp, and claude --permission-mode default has no OS sandbox
# at all. RUN_DIR holds <phase>.tree and <phase>-verdict.txt, so a RUN_DIR under either root lets
# a FIX call forge its own APPROVED plus a matching snapshot — the reviewer-only guard becomes
# decorative. Asserting the location is the only test that can catch a regression here: the
# sandbox's own HOME lives under $TMPDIR, so this checks the prefix devflow chose, not the
# absolute path.
case "$RUN_DIR" in
  "$HOME"/.devflow/run/*) ok "true" "RUN_DIR is under \$HOME/.devflow/run, not a write-mode writable root" ;;
  *) ok "false" "RUN_DIR is under \$HOME/.devflow/run (got: $RUN_DIR)" ;;
esac

# --- the extractor's exit codes are a CONTRACT, not an accident ------------------------------
# 3 = "I ran; there is no usable value here" (fail closed). Anything else = "I could not run",
# which the runner must report differently. A shared code makes the two indistinguishable.
printf '{"type":"thread.started","thread_id":"t1"}\n' > "$SB/no-completed.jsonl"
out="$(python3 "$JSONC" codex result "$SB/no-completed.jsonl" 2>&1)"; rc=$?
is "$rc" "3" "a stream with no turn.completed exits 3 (ran, nothing usable)"
is "$out" "" "...and prints nothing"
python3 "$JSONC" codex result "$SB/does-not-exist.jsonl" >/dev/null 2>&1
is "$?" "3" "an unreadable input is also a fail-closed 3, not a crash"
# A wrong argv is devflow miscalling its own helper, i.e. a "could not run" cause — it must NOT
# share the content-side 3, or a renamed field would report a good review as an empty verdict.
python3 "$JSONC" bogus result "$SB/no-completed.jsonl" >/dev/null 2>&1
is "$?" "2" "a bad source argument is a usage error (2), not a content verdict (3)"
python3 "$JSONC" codex result >/dev/null 2>&1
is "$?" "2" "...and so is a missing argument"
printf '{"type":"thread.started","thread_id":"t1"}\n{"type":"item.completed","item":{"type":"agent_message","text":"APPROVED"}}\n{"type":"turn.completed"}\n' > "$SB/good.jsonl"
is "$(python3 "$JSONC" codex result "$SB/good.jsonl")" "APPROVED" "a complete stream still yields its verdict on exit 0"

# --- a broken extractor must be reported AS a devflow failure, not as an empty verdict -------
# Reproduced the way it actually happened: a runner copy with no devflow-json.py beside it, so
# python3 exits 2. The call still fails closed; the point is that it says WHY.
cp "$RUNNER" "$SB/lonely-runner.sh"
out="$( ( cd "$REPO_FX" && bash "$SB/lonely-runner.sh" run-external --backend codex --model gpt-5.5 \
          --effort high --phase lonely --prompt-file "$PF" ) 2>&1 )"; rc=$?
isnt "$rc" "0" "a call whose extractor cannot run is unusable"
has "$out" "verdict extractor could not run" "...and says the extractor itself failed"
hasnt "$out" "for an unknown reason" "...instead of blaming the reviewer for an empty verdict"

# --- a configured command_path is a trust boundary: no silent substitution -------------------
# A probe failure used to fall through to /opt/homebrew/bin/codex, /usr/local/bin/codex, then
# `which -a codex` — i.e. the real CLI, with whatever credentials are lying around.
printf '#!/bin/sh\necho "no json support here"\nexit 0\n' > "$SB/bad-codex"; chmod +x "$SB/bad-codex"
cat > "$HOME/.devflow/config.yaml" <<YAML
codex:
  command_path: "$SB/bad-codex"
YAML
out="$( ( cd "$REPO_FX" && bash "$RUNNER" run-external --backend codex --model gpt-5.5 \
          --effort high --phase badbin --prompt-file "$PF" ) 2>&1 )"; rc=$?
isnt "$rc" "0" "a command_path that fails the capability probe aborts the call"
has "$out" "did not pass the 'exec --json' probe" "...naming the probe that failed"
has "$out" "Refusing to run a different codex binary" "...and refusing to substitute another binary"
ok "[ ! -e '$RUN_DIR/badbin-events.jsonl' ]" "...having launched no external tool at all"

# The more common misconfiguration is not a wrong binary but a DANGLING path — a moved install, a
# typo. The first version of this guard sat inside the candidate loop, past `[ -x "$cand" ]`, so a
# missing path was skipped rather than refused and resolution fell through to the system codex:
# the same silent substitution, reached by the likelier route. Both must refuse.
cat > "$HOME/.devflow/config.yaml" <<YAML
codex:
  command_path: "$SB/does-not-exist-codex"
YAML
out="$( ( cd "$REPO_FX" && bash "$RUNNER" run-external --backend codex --model gpt-5.5 \
          --effort high --phase gonebin --prompt-file "$PF" ) 2>&1 )"; rc=$?
isnt "$rc" "0" "a command_path that does not exist aborts the call"
has "$out" "is missing or not executable" "...saying the path itself is the problem"
has "$out" "Refusing to run a different codex binary" "...and refusing to substitute another binary"
ok "[ ! -e '$RUN_DIR/gonebin-events.jsonl' ]" "...having launched no external tool at all"

printf '#!/bin/sh\nexit 0\n' > "$SB/noexec-codex"; chmod 444 "$SB/noexec-codex"
cat > "$HOME/.devflow/config.yaml" <<YAML
codex:
  command_path: "$SB/noexec-codex"
YAML
out="$( ( cd "$REPO_FX" && bash "$RUNNER" run-external --backend codex --model gpt-5.5 \
          --effort high --phase noexecbin --prompt-file "$PF" ) 2>&1 )"; rc=$?
isnt "$rc" "0" "a command_path that exists but is not executable also aborts"
has "$out" "is missing or not executable" "...with the same refusal"
chmod 644 "$SB/noexec-codex"

cleanup_sandbox
report
