#!/usr/bin/env bash
# scope: each mode yields the right file set + diff command on a fixture repo, untracked
# files are enumerated, branch base is resolved (never hardcoded).
set -u
. "$LIB/assert.sh"; . "$LIB/sandbox.sh"

mk_sandbox
cd "$REPO_FX"
MAIN="$(git symbolic-ref --short HEAD)"        # default branch name (main/master)
C1="$(git rev-parse HEAD)"                       # init commit

# second commit: change a.txt (enables last-commit / implementation)
printf 'v2\n' > a.txt; git add -A; git commit -qm c2

run_scope(){ bash "$RUNNER" scope "$@"; }        # -> prints the SCOPE block to stdout

# clean-tree boundary: a legitimately empty scope (nothing changed) is NOT a guard failure —
# only a base-resolution failure should abort; zero changed files on a clean tree (right
# after the commit above, before anything gets dirtied below) must still exit 0 with an
# (intentionally) empty file list.
clean_out="$(run_scope uncommitted)"; clean_rc=$?
is    "$clean_rc" "0"     "uncommitted scope on a clean tree exits 0 (not a guard failure)"
hasnt "$clean_out" "a.txt" "uncommitted scope on a clean tree lists no files"

# last-commit
out="$(run_scope last-commit)"
has "$out" "a.txt" "last-commit: a.txt in scope"
has "$out" "git" "last-commit: DIFF_CMD is a git command"

# implementation (base = init commit)
out="$(run_scope implementation --impl-base "$C1")"
has "$out" "a.txt" "implementation: change since impl-base in scope"
has "$out" "$C1" "implementation: DIFF_CMD pins the impl base sha"

# branch (base provided -> no gh/network); commit on a feature branch
git checkout -q -b feature
printf 'v2b\n' > b.txt; git add -A; git commit -qm c3
out="$(run_scope branch --base "$MAIN")"
has "$out" "b.txt" "branch: only branch-local change in scope"
hasnt "$out" "a.txt" "branch: base (merge-base) excludes pre-branch commits"
git checkout -q "$MAIN"

# working-tree modes: dirty the tree
printf 'v9\n' > a.txt                # unstaged
printf 'v9\n' > b.txt; git add b.txt # staged
printf 'new\n' > c.txt               # untracked

out="$(run_scope uncommitted)"
has "$out" "a.txt" "uncommitted: unstaged change in scope"

out="$(run_scope staged)"
has "$out" "b.txt" "staged: staged change in scope"
hasnt "$out" "a.txt" "staged: unstaged change NOT in staged scope"

# untracked enumeration (computed in every mode) — checked against the staged-mode output above
has "$out" "c.txt" "untracked file enumerated"

# files / plan modes carry agent-fill DIFF_CMD shapes
out="$(run_scope files -- a.txt b.txt)"
has "$out" "git diff HEAD" "files mode: DIFF_CMD shape present"
has "$out" "a.txt" "files mode: first explicit path listed in scope"
has "$out" "b.txt" "files mode: second explicit path listed in scope"

out="$(run_scope plan --plan-path /tmp/some-plan.md)"
has "$out" "/tmp/some-plan.md" "plan mode: FILES = the plan path"
has "$out" "cat" "plan mode: DIFF_CMD reads the plan read-only"

# guards: a scope mode that can't resolve its base must fail loudly AND non-zero, never emit an
# empty scope (the exact bug scope-pinning prevents). Assert BOTH the message and the return code
# — a guard that only warns and then falls through to empty FILES would pass a message-only check.
# Throwaway repo with no remote/origin so branch-base resolution has nothing to fall back to.
mk_noremote(){ cd "$SB" && rm -rf noremote && mkdir noremote && cd noremote
  git init -q; git config user.email t@example.test; git config user.name tester; git config commit.gpgsign false
  printf 'x\n' > f.txt; git add -A; git commit -qm only; }

guard_err="$( mk_noremote; run_scope branch 2>&1 )"; guard_rc=$?
has  "$guard_err" "could not resolve a base" "branch scope with no base fails loudly (no silent empty scope)"
isnt "$guard_rc" "0"                          "branch scope with no base returns non-zero (aborts, not just warns)"

impl_err="$( mk_noremote; run_scope implementation --impl-base deadbeefdeadbeef 2>&1 )"; impl_rc=$?
has  "$impl_err" "not a valid commit" "implementation scope with bad base fails loudly"
isnt "$impl_rc" "0"                   "implementation scope with bad base returns non-zero (no empty-scope diff)"

head_err="$( mk_noremote; run_scope last-commit 2>&1 )"; head_rc=$?
has  "$head_err" "needs a parent commit" "last-commit scope on a single-commit repo fails loudly"
isnt "$head_rc" "0"                       "last-commit scope with no HEAD^ returns non-zero"

# No common ancestor: branch scope against an unrelated-history base must abort, not emit scope from
# an empty merge-base. Build a second root via an orphan branch, then diff the original branch vs it.
mb_err="$(
  mk_noremote
  base_branch="$(git symbolic-ref --short HEAD)"
  git checkout -q --orphan unrelated; git rm -rfq .; printf 'z\n' > z.txt; git add -A; git commit -qm orphan
  git checkout -q "$base_branch"
  run_scope branch --base unrelated 2>&1 )"; mb_rc=$?
has  "$mb_err" "no common ancestor" "branch scope with unrelated histories fails loudly"
isnt "$mb_rc" "0"                    "branch scope with empty merge-base returns non-zero"

# --pr missing: distinct from the gh-failure guard below — this rejects before ever shelling out to gh.
pr_flag_err="$(run_scope pr 2>&1)"; pr_flag_rc=$?
has  "$pr_flag_err" "needs --pr" "pr scope with no --pr flag fails loudly"
isnt "$pr_flag_rc" "0"             "pr scope with no --pr flag returns non-zero"

# pr gh-failure guard: --pr given but `gh` itself fails (bad PR number, no auth, no network) —
# must abort like the other base-resolution guards above, never emit a scope with empty FILES.
mk_fake_gh_failing(){
  mkdir -p "$SB/fakebin"
  cat > "$SB/fakebin/gh" <<'EOF'
#!/usr/bin/env bash
echo "gh: pull request not found" >&2
exit 1
EOF
  chmod +x "$SB/fakebin/gh"
}
mk_fake_gh_failing
gh_err="$(cd "$REPO_FX" && PATH="$SB/fakebin:$PATH" run_scope pr --pr 9999 2>&1)"; gh_rc=$?
has  "$gh_err" "gh pr diff 9999 failed" "pr scope with failing gh fails loudly (no silent empty scope)"
isnt "$gh_rc" "0"                       "pr scope with failing gh returns non-zero"

# Flag with no value (missing argument): ensure proper error message, not raw "unbound variable" bash error
base_flag_err="$(run_scope branch --base 2>&1)"; base_flag_rc=$?
has  "$base_flag_err" "devflow: scope: --base requires a value" "--base as last arg fails with devflow message"
isnt "$base_flag_rc" "0"                                        "--base as last arg returns non-zero"

pr_flag_err="$(run_scope pr --pr 2>&1)"; pr_flag_rc=$?
has  "$pr_flag_err" "devflow: scope: --pr requires a value" "--pr as last arg fails with devflow message"
isnt "$pr_flag_rc" "0"                                      "--pr as last arg returns non-zero"

impl_base_flag_err="$(run_scope branch --impl-base 2>&1)"; impl_base_flag_rc=$?
has  "$impl_base_flag_err" "devflow: scope: --impl-base requires a value" "--impl-base as last arg fails with devflow message"
isnt "$impl_base_flag_rc" "0"                                             "--impl-base as last arg returns non-zero"

plan_path_flag_err="$(run_scope branch --plan-path 2>&1)"; plan_path_flag_rc=$?
has  "$plan_path_flag_err" "devflow: scope: --plan-path requires a value" "--plan-path as last arg fails with devflow message"
isnt "$plan_path_flag_rc" "0"                                            "--plan-path as last arg returns non-zero"

cleanup_sandbox
report
