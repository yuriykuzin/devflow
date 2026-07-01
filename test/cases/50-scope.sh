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

cleanup_sandbox
report
