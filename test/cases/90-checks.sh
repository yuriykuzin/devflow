#!/usr/bin/env bash
# checks run: discovery vs config, all commands run even after a failure, exit codes, the
# status line is written LAST (a self-forged pass is overwritten; a killed run leaves none),
# a check that edits the tree fails, an invalid config never destroys the last real result.
set -u
. "$LIB/assert.sh"; . "$LIB/sandbox.sh"

mk_sandbox
run_dir_here
c(){ ( cd "$REPO_FX" && bash "$RUNNER" checks run "$@" ); }
st(){ cat "$RUN_DIR/checks.status" 2>/dev/null; }
txt(){ cat "$RUN_DIR/checks.txt" 2>/dev/null; }
jcfg(){ python3 -c 'import json,sys; json.dump({"checks":{"commands":sys.argv[2:]}}, open(sys.argv[1],"w"))' "$@"; }

# (1) nothing configured, nothing discoverable -> none, exit 3.
out="$(c)"; rc=$?
is "$rc" "3" "no checks anywhere -> exit 3"
has "$out" "CHECKS=none" "...prints CHECKS=none"
has "$(st)" "status=none" "...status line says none"
has "$(st)" "source=discovered" "...and records that discovery was used"

# (2) discovered test/run.sh -> pass.
mkdir -p "$REPO_FX/test"; printf 'echo fixture-ok\n' > "$REPO_FX/test/run.sh"
out="$(c)"; rc=$?
is "$rc" "0" "discovered test/run.sh passes -> exit 0"
has "$(st)" "status=pass" "...status=pass"
has "$(st)" "ran=1" "...one command ran"
has "$(txt)" '### $ bash test/run.sh' "...the discovered command is recorded"
has "$(txt)" "fixture-ok" "...with its output"
has "$(txt)" "### exit=0" "...and its exit code"

# (3) config commands override discovery.
jcfg "$SB/cfg.json" "echo from-config"
out="$(c --config "$SB/cfg.json")"; rc=$?
is "$rc" "0" "config commands -> exit 0"
has "$(st)" "source=config" "...source=config"
hasnt "$(txt)" "bash test/run.sh" "...discovery is not used when config names commands"

# (4) a failing command: every command still runs, the exit code is recorded.
jcfg "$SB/fail.json" "exit 7" "echo second-ran"
out="$(c --config "$SB/fail.json")"; rc=$?
is "$rc" "1" "a failing check -> exit 1"
has "$(txt)" "### exit=7" "...its exit code is recorded"
has "$(txt)" "second-ran" "...and the next command still ran"
has "$(st)" "status=fail" "...status=fail"
has "$(st)" "ran=2 failed=1" "...counts are right"

# (5) invalid config -> exit 2, INVALID_CHECKS, and the previous status survives.
printf '{"checks":{"commands":"make test"}}' > "$SB/bad.json"
out="$(c --config "$SB/bad.json")"; rc=$?
is "$rc" "2" "non-list checks.commands -> exit 2"
has "$out" "INVALID_CHECKS" "...with an INVALID_CHECKS line"
has "$(st)" "status=fail" "...and the last real status is untouched"

# (6) a check that forges its own pass is overwritten by the real outcome.
jcfg "$SB/forge.json" "echo 'status=pass digest=x base=- source=config ran=1 failed=0' > '$RUN_DIR/checks.status'; exit 1"
out="$(c --config "$SB/forge.json")"; rc=$?
is "$rc" "1" "self-forging check still fails"
has "$(st)" "status=fail" "...the forged status=pass is overwritten"

# (7) a check that edits the tree is a fail (its pass would describe a tree that no longer exists).
jcfg "$SB/mut.json" "echo x >> a.txt"
out="$(c --config "$SB/mut.json")"; rc=$?
is "$rc" "1" "a tree-mutating check -> exit 1"
has "$(txt)" "tree changed while checks ran" "...and says why"
has "$(txt)" "###   a.txt" "...names the path it changed (N4)"
has "$(txt)" ".gitignore" "...and suggests .gitignore (N4)"
git -C "$REPO_FX" checkout -q -- a.txt

# (8) a killed run leaves NO status file (never a stale pass).
jcfg "$SB/ok.json" "true"; c --config "$SB/ok.json" >/dev/null
jcfg "$SB/slow.json" "sleep 3"
( cd "$REPO_FX" && exec bash "$RUNNER" checks run --config "$SB/slow.json" ) >/dev/null 2>&1 &
pid=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do grep -q 'sleep 3' "$RUN_DIR/checks.txt" 2>/dev/null && break; sleep 0.2; done
kill -9 "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
ok "[ ! -e '$RUN_DIR/checks.status' ]" "a killed checks run leaves no checks.status"

# (9) discovery (white-box): placeholder npm test skipped, lockfile picks the manager, all sources listed.
D="$SB/disc"; mkdir -p "$D/spec"
printf '{"scripts":{"test":"echo \\"Error: no test specified\\" && exit 1","lint":"eslint ."}}' > "$D/package.json"
: > "$D/yarn.lock"
printf 'test:\n\t@true\nlint:\n\t@true\n' > "$D/Makefile"
: > "$D/Gemfile"; : > "$D/.rubocop.yml"
printf '[tool.pytest.ini_options]\n' > "$D/pyproject.toml"
list="$( . "$RUNNER"; _devflow_checks_discover "$D" )"
has "$list" "make test" "discovery: Makefile test target"
has "$list" "make lint" "discovery: Makefile lint target"
has "$list" "yarn run lint" "discovery: package.json lint via the yarn lockfile"
hasnt "$list" "run test" "discovery: npm's 'no test specified' placeholder is skipped"
has "$list" "bundle exec rspec" "discovery: Gemfile + spec/"
has "$list" "bundle exec rubocop" "discovery: Gemfile + .rubocop.yml"
has "$list" "python3 -m pytest" "discovery: [tool.pytest] in pyproject.toml"

# (10) usage errors.
( cd "$REPO_FX" && bash "$RUNNER" checks bogus ) >/dev/null 2>&1; is "$?" "2" "unknown checks subcommand -> exit 2"
c --config "$SB/no-such.json" >/dev/null 2>&1; is "$?" "2" "--config naming a missing file -> exit 2"

cleanup_sandbox
report
