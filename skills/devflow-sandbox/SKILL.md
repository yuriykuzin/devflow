---
name: devflow:sandbox
description: Sandbox lifecycle management — create, list, and destroy isolated sandbox environments for AI agents. Use when the user wants to spin up, check, or tear down sandboxes.
---

# Sandbox Lifecycle

Manage isolated sandbox environments for AI agent development.

## Commands

Parse the user's intent and run the appropriate command:

### Create a sandbox

```
sandbox-up.sh --project <path> --branch <branch> --agent <claude|codex>
```

- Resolve the project path (default: current working directory)
- If user references a PR number, resolve the branch: `gh pr view <number> --json headRefName -q .headRefName`
- Default agent: read from `config.default.yaml` backend setting

### List sandboxes

```
sandbox-list.sh
```

### Destroy a sandbox

```
sandbox-down.sh --id <sandbox-id>
sandbox-down.sh --all
sandbox-down.sh --older-than 24h
```

### Execute a command in a sandbox

```
sandbox-exec.sh --id <sandbox-id> -- <command...>
```

## Scripts Location

All scripts are in the devflow repo at `sandbox/scripts/`.

## Cleanup Rule

**Every sandbox interaction MUST end with a cleanup suggestion.** After completing work in a sandbox, you MUST either:

1. Clean up the sandbox (if user confirms)
2. List remaining sandboxes with resource usage
3. Suggest a cleanup command for later

Example endings:
- "Sandbox `sk-onto123-a1b2c3` is still running on :8001. Want me to clean it up?"
- "You have 4 active sandboxes. Run `sandbox-list.sh` to review."
- "Sandbox `sk-onto789-g7h8i9` has been idle for 6 hours. Consider cleaning up with `sandbox-down.sh --id sk-onto789-g7h8i9`."

## Typical Flows

### PR Review in Sandbox
1. Resolve PR head ref: `gh pr view <number> --json headRefName -q .headRefName`
2. `sandbox-up.sh --project . --branch <ref> --agent claude`
3. Run tests, review code inside sandbox
4. Report results
5. **Suggest cleanup**

### Parallel Branch Testing
1. Create sandboxes for each branch
2. Run tests in parallel
3. Report results
4. **Suggest cleanup for all**
