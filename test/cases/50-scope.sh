#!/usr/bin/env bash
# Section C scope pinning: each SCOPE_MODE yields the right file set + DIFF_CMD on a
# fixture repo, untracked files are enumerated, branch base is resolved (never hardcoded).
set -u
. "$LIB/assert.sh"; . "$LIB/sandbox.sh"

mk_sandbox
cd "$REPO_FX"
MAIN="$(git symbolic-ref --short HEAD)"        # default branch name (main/master)
C1="$(git rev-parse HEAD)"                       # init commit

# second commit: change a.txt (enables last-commit / implementation)
printf 'v2\n' > a.txt; git add -A; git commit -qm c2

run_scope(){  # run_scope MODE  -> sets FILES/DIFF_CMD/UNTRACKED via the real Section C block
  SCOPE_MODE="$1"; REVIEW_BASE="${REVIEW_BASE:-}"; PR_NUMBER=""; : "${DEVFLOW_IMPL_BASE:=}" "${DEVFLOW_PLAN_PATH:=}"
  . "$EXTRACTED/c.sh"
}

# last-commit
run_scope last-commit
has "$FILES" "a.txt" "last-commit: a.txt in scope"
has "$DIFF_CMD" "git" "last-commit: DIFF_CMD is a git command"

# implementation (base = init commit)
DEVFLOW_IMPL_BASE="$C1" run_scope implementation
has "$FILES" "a.txt" "implementation: change since impl-base in scope"
has "$DIFF_CMD" "$C1" "implementation: DIFF_CMD pins the impl base sha"

# branch (base provided -> no gh/network); commit on a feature branch
git checkout -q -b feature
printf 'v2b\n' > b.txt; git add -A; git commit -qm c3
REVIEW_BASE="$MAIN" run_scope branch
has "$FILES" "b.txt" "branch: only branch-local change in scope"
hasnt "$FILES" "a.txt" "branch: base (merge-base) excludes pre-branch commits"
git checkout -q "$MAIN"

# working-tree modes: dirty the tree
printf 'v9\n' > a.txt                # unstaged
printf 'v9\n' > b.txt; git add b.txt # staged
printf 'new\n' > c.txt               # untracked

run_scope uncommitted
has "$FILES" "a.txt" "uncommitted: unstaged change in scope"

run_scope staged
has "$FILES" "b.txt" "staged: staged change in scope"
hasnt "$FILES" "a.txt" "staged: unstaged change NOT in staged scope"

# untracked enumeration (computed in every mode)
has "$UNTRACKED" "c.txt" "untracked file enumerated"

# files / plan modes carry agent-fill DIFF_CMD shapes
run_scope files
has "$DIFF_CMD" "git diff HEAD" "files mode: DIFF_CMD shape present"

DEVFLOW_PLAN_PATH="/tmp/some-plan.md" run_scope plan
has "$FILES" "/tmp/some-plan.md" "plan mode: FILES = the plan path"
has "$DIFF_CMD" "cat" "plan mode: DIFF_CMD reads the plan read-only"

# guards: a scope mode that can't resolve its base must fail loudly AND non-zero, never emit an
# empty scope (the exact bug scope-pinning prevents). Assert BOTH the message and the return code
# — a guard that only warns and then falls through to empty FILES would pass a message-only check.
# Throwaway repo with no remote/origin so branch-base resolution has nothing to fall back to.
mk_noremote(){ cd "$SB" && rm -rf noremote && mkdir noremote && cd noremote
  git init -q; git config user.email t@example.test; git config user.name tester; git config commit.gpgsign false
  printf 'x\n' > f.txt; git add -A; git commit -qm only; }

guard_err="$( mk_noremote
  SCOPE_MODE=branch REVIEW_BASE="" PR_NUMBER="" DEVFLOW_IMPL_BASE="" DEVFLOW_PLAN_PATH=""
  . "$EXTRACTED/c.sh" 2>&1 )"; guard_rc=$?
has  "$guard_err" "could not resolve a base" "branch scope with no base fails loudly (no silent empty scope)"
isnt "$guard_rc" "0"                          "branch scope with no base returns non-zero (aborts, not just warns)"

# non-empty but invalid impl base: must abort, not silently diff a bad ref down to an empty scope.
impl_err="$( mk_noremote
  SCOPE_MODE=implementation REVIEW_BASE="" PR_NUMBER="" DEVFLOW_IMPL_BASE="deadbeefdeadbeef" DEVFLOW_PLAN_PATH=""
  . "$EXTRACTED/c.sh" 2>&1 )"; impl_rc=$?
has  "$impl_err" "not a valid commit" "implementation scope with bad base fails loudly"
isnt "$impl_rc" "0"                   "implementation scope with bad base returns non-zero (no empty-scope diff)"

# HEAD^ missing: last-commit scope on a single-commit repo must abort, not diff a non-existent parent.
head_err="$( mk_noremote
  SCOPE_MODE=last-commit REVIEW_BASE="" PR_NUMBER="" DEVFLOW_IMPL_BASE="" DEVFLOW_PLAN_PATH=""
  . "$EXTRACTED/c.sh" 2>&1 )"; head_rc=$?
has  "$head_err" "needs a parent commit" "last-commit scope on a single-commit repo fails loudly"
isnt "$head_rc" "0"                       "last-commit scope with no HEAD^ returns non-zero"

# No common ancestor: branch scope against an unrelated-history base must abort, not emit scope from
# an empty merge-base. Build a second root via an orphan branch, then diff the original branch vs it.
mb_err="$(
  mk_noremote
  base_branch="$(git symbolic-ref --short HEAD)"
  git checkout -q --orphan unrelated; git rm -rfq .; printf 'z\n' > z.txt; git add -A; git commit -qm orphan
  git checkout -q "$base_branch"
  SCOPE_MODE=branch REVIEW_BASE="unrelated" PR_NUMBER="" DEVFLOW_IMPL_BASE="" DEVFLOW_PLAN_PATH=""
  . "$EXTRACTED/c.sh" 2>&1 )"; mb_rc=$?
has  "$mb_err" "no common ancestor" "branch scope with unrelated histories fails loudly"
isnt "$mb_rc" "0"                    "branch scope with empty merge-base returns non-zero"

cleanup_sandbox
report
