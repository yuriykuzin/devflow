# Devflow Roadmap Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Harden devflow from a working prototype to a release-ready v0.1 with verified integrations, proper licensing, CI checks, and Codex best-practice alignment.

**Architecture:** Tasks are grouped by priority tier (P1 → P3) and are largely independent within each tier. P1 tasks validate what was just built, P2 tasks fill obvious gaps, P3 tasks are forward-looking improvements. Each task produces a self-contained commit.

**Tech Stack:** Bash, Python3 (for JSON manipulation in install.sh), YAML config, GitHub Actions (CI)

---

## File Structure

```
devflow/
├── LICENSE                              # Create: MIT license text
├── AGENTS.md                            # Create: Codex-facing project map
├── .github/workflows/validate.yml       # Create: CI validation
├── .gitignore                           # Modify: add reports dir pattern
├── docs/devflow/reports/.gitkeep        # Create: empty marker
├── install.sh                           # Modify: test support
├── skills/devflow-review/SKILL.md       # Modify: codex exec review note
└── (no changes to other existing files for P3 — those are research/future)
```

---

## Priority 1 — Verify Recent Changes

### Task 1: Verify Claude Code discovers devflow skills after install

**Files:**
- Read: `install.sh`
- Read: `~/.claude/plugins/installed_plugins.json`
- Read: `~/.claude/settings.json`

- [ ] **Step 1: Run install.sh and capture output**

```bash
cd /path/to/devflow
./install.sh
```

Expected: output shows `✓` lines for Claude Code (symlink, registered, enabled).

- [ ] **Step 2: Verify symlink exists and points correctly**

```bash
ls -la ~/.claude/plugins/cache/local/devflow/0.1.0
# Should be symlink → /path/to/devflow
```

- [ ] **Step 3: Verify installed_plugins.json contains devflow@local**

```bash
python3 -c "
import json
with open('$HOME/.claude/plugins/installed_plugins.json') as f:
    d = json.load(f)
entry = d['plugins']['devflow@local']
print('OK:', entry[0]['installPath'])
"
```

Expected: prints the install path.

- [ ] **Step 4: Verify settings.json has devflow@local enabled**

```bash
python3 -c "
import json
with open('$HOME/.claude/settings.json') as f:
    d = json.load(f)
print('Enabled:', d['enabledPlugins'].get('devflow@local'))
"
```

Expected: `Enabled: True`

- [ ] **Step 5: Start a new Claude Code session and check skills list**

Start a fresh `claude` session in any project directory. The devflow skills (`devflow:plan`, `devflow:implement`, `devflow:review`, `devflow:run`, `using-devflow`) should appear in the available skills list.

If they do NOT appear:
- Check if Claude Code scans `skills/*/SKILL.md` or expects a different structure
- Compare with superpowers directory layout under `~/.claude/plugins/cache/claude-plugins-official/superpowers/`
- Adjust plugin structure or registration approach as needed

- [ ] **Step 6: Document findings**

If the approach works, no code changes needed — just confirm.
If adjustments were needed, commit them with a descriptive message.

---

### Task 2: Test install.sh --deploy, --uninstall, --status

**Files:**
- Read/Run: `install.sh`

- [ ] **Step 1: Test --status before any changes**

```bash
./install.sh --status
```

Expected: shows ✓ for installed integrations, status for Claude Code.

- [ ] **Step 2: Test --uninstall**

```bash
./install.sh --uninstall
```

Expected:
- Codex symlink removed
- Claude Code cache removed, entries removed from JSON files
- Windsurf symlinks removed (if present)
- Config kept

- [ ] **Step 3: Verify uninstall was clean**

```bash
./install.sh --status
```

Expected: all items show ✗ (not installed), except Config (kept).

Check Claude Code JSON files manually:
```bash
python3 -c "
import json
with open('$HOME/.claude/plugins/installed_plugins.json') as f:
    d = json.load(f)
print('devflow@local' not in d.get('plugins', {}))  # Should be True
"
```

- [ ] **Step 4: Test --deploy**

```bash
./install.sh --deploy
```

Expected:
- Files synced to `~/.codex/devflow/`
- All symlinks recreated pointing to `~/.codex/devflow/`
- Claude Code re-registered

- [ ] **Step 5: Verify deploy installation**

```bash
./install.sh --status
ls -la ~/.agents/skills/devflow
readlink ~/.claude/plugins/cache/local/devflow/0.1.0
```

Expected: symlinks point to `~/.codex/devflow/...` (not source repo).

- [ ] **Step 6: Re-install from source (restore normal state)**

```bash
./install.sh --uninstall
./install.sh
```

- [ ] **Step 7: Commit any fixes discovered during testing**

If install.sh needed adjustments, commit them:
```bash
git add install.sh
git commit -m "fix: install.sh issues found during integration testing"
```

---

## Priority 2 — Fill Gaps

### Task 3: Add LICENSE file

**Files:**
- Create: `LICENSE`

- [ ] **Step 1: Create MIT license file**

```text
MIT License

Copyright (c) 2026 Yuriy Kuzin

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

- [ ] **Step 2: Commit**

```bash
git add LICENSE
git commit -m "Add MIT LICENSE file (referenced in plugin manifests)"
```

---

### Task 4: Add AGENTS.md for Codex

**Files:**
- Create: `AGENTS.md`
- Reference: `README.md`, `skills/using-devflow/SKILL.md`

AGENTS.md should be a **map, not a manual** — short pointers to where things live and key rules, per OpenAI best practices.

- [ ] **Step 1: Create AGENTS.md**

```markdown
# Devflow — Agent Instructions

## What This Is

Cross-tool AI workflow orchestrator. Plans, implements, and reviews code using multiple AI tools (Claude Code, Codex CLI, Windsurf, Gemini CLI, Cursor).

## Key Files

- `skills/using-devflow/SKILL.md` — entry point, skill discovery, platform adaptation
- `skills/devflow-plan/SKILL.md` — plan with cross-tool review
- `skills/devflow-implement/SKILL.md` — implement with cross-tool review
- `skills/devflow-review/SKILL.md` — standalone cross-tool review
- `skills/devflow-run/SKILL.md` — full pipeline orchestrator
- `config.default.yaml` — configuration template
- `install.sh` — cross-platform installer

## Configuration

- Global: `~/.devflow/config.yaml`
- Project: `.devflow.yaml` in project root
- Project overrides global.

## Rules

- Never invoke both `devflow:plan` AND `superpowers:writing-plans` for the same task — devflow delegates to superpowers internally.
- External review is the core value — never skip it.
- Don't auto-commit — leave changes in working directory for user review.
- Session reuse saves ~20k tokens per iteration — preserve session files in `/tmp/devflow-*.session`.
```

- [ ] **Step 2: Commit**

```bash
git add AGENTS.md
git commit -m "Add AGENTS.md for Codex best-practice alignment"
```

---

### Task 5: Decide docs/devflow/reports/ lifecycle and configure

**Files:**
- Create: `docs/devflow/reports/.gitkeep`
- Modify: `.gitignore`

Reports are **generated output** — they should not be committed by default, but the directory should exist so skills don't fail on first write.

- [ ] **Step 1: Create the reports directory with .gitkeep**

```bash
mkdir -p docs/devflow/reports
touch docs/devflow/reports/.gitkeep
```

- [ ] **Step 2: Add gitignore rule for report files but keep the directory**

Add to `.gitignore`:
```
# Devflow reports (generated output — commit selectively if desired)
docs/devflow/reports/*.md
```

- [ ] **Step 3: Commit**

```bash
git add .gitignore docs/devflow/reports/.gitkeep
git commit -m "Add reports directory with .gitkeep, ignore generated reports"
```

---

### Task 6: Add CI validation harness

**Files:**
- Create: `.github/workflows/validate.yml`

A lightweight CI job that catches the class of bugs found in the autoreview: broken references, missing files, invalid JSON, bash syntax errors.

- [ ] **Step 1: Create validation workflow**

```yaml
name: Validate

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  validate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Bash syntax check
        run: bash -n install.sh

      - name: JSON validity
        run: |
          python3 -m json.tool .claude-plugin/plugin.json > /dev/null
          python3 -m json.tool .cursor-plugin/plugin.json > /dev/null
          python3 -m json.tool gemini-extension.json > /dev/null

      - name: Required files exist
        run: |
          files=(
            "LICENSE"
            "README.md"
            "AGENTS.md"
            "GEMINI.md"
            "install.sh"
            "config.default.yaml"
            ".claude-plugin/plugin.json"
            ".cursor-plugin/plugin.json"
            "gemini-extension.json"
          )
          for f in "${files[@]}"; do
            [ -f "$f" ] || { echo "MISSING: $f"; exit 1; }
          done
          echo "All required files present."

      - name: Skill files exist
        run: |
          skills=(
            "skills/using-devflow/SKILL.md"
            "skills/devflow-plan/SKILL.md"
            "skills/devflow-implement/SKILL.md"
            "skills/devflow-review/SKILL.md"
            "skills/devflow-run/SKILL.md"
          )
          for s in "${skills[@]}"; do
            [ -f "$s" ] || { echo "MISSING: $s"; exit 1; }
          done
          echo "All skill files present."

      - name: Windsurf workflow files exist
        run: |
          workflows=(
            "windsurf/devflow-plan.md"
            "windsurf/devflow-implement.md"
            "windsurf/devflow-review.md"
            "windsurf/devflow-run.md"
          )
          for w in "${workflows[@]}"; do
            [ -f "$w" ] || { echo "MISSING: $w"; exit 1; }
          done
          echo "All workflow files present."

      - name: GEMINI.md includes resolve
        run: |
          # Check that all @./ includes in GEMINI.md point to existing files
          grep '^@\.\/' GEMINI.md | sed 's/^@//' | while read -r path; do
            [ -f "$path" ] || { echo "MISSING include: $path"; exit 1; }
          done
          echo "All GEMINI.md includes resolve."

      - name: No secrets in tracked files
        run: |
          # Quick scan for common secret patterns
          if grep -rIE '(ANTHROPIC_API_KEY|OPENAI_API_KEY|sk-[a-zA-Z0-9]{20,}|password\s*=\s*["\x27][^\x27"]+)' --include='*.md' --include='*.yaml' --include='*.json' --include='*.sh' .; then
            echo "Potential secrets found!"
            exit 1
          fi
          echo "No secrets detected."
```

- [ ] **Step 2: Commit**

```bash
git add .github/workflows/validate.yml
git commit -m "Add CI validation workflow (file checks, JSON, bash syntax, secrets)"
```

---

## Priority 3 — Forward-Looking Improvements

### Task 7: Research codex exec review for review-only flows

**Files:**
- Read: `skills/devflow-review/SKILL.md`
- Read: `windsurf/devflow-review.md`

This is a **research task** — no code changes unless the finding is clear-cut.

- [ ] **Step 1: Check current codex exec review capabilities**

```bash
codex exec --help 2>&1 | grep -A5 review || echo "No review subcommand"
```

- [ ] **Step 2: Compare with devflow's review skill**

Read `skills/devflow-review/SKILL.md`. Determine:
- Does `codex exec review` do the same thing (send code to a model for review)?
- Does it support session reuse?
- Does it support custom model/effort flags?
- Can devflow delegate to it, or does devflow's review add value beyond it?

- [ ] **Step 3: Document findings**

If `codex exec review` is a good fit: add a note to the review skill about using it as an alternative backend.
If not: document why devflow's custom approach is better.

No commit unless a code change is made.

---

### Task 8: Research structured Codex sessions via codex mcp-server

**Files:**
- Read: `skills/using-devflow/SKILL.md` (orchestration section)

This is a **research task** — evaluate whether codex mcp-server or Codex App Server would improve devflow's session management.

- [ ] **Step 1: Check if codex mcp-server is available locally**

```bash
which codex-mcp-server 2>/dev/null || codex mcp-server --help 2>&1 | head -20
```

- [ ] **Step 2: Evaluate benefits vs current approach**

Current: devflow shells out to `codex exec`, captures `--json` output, parses `thread_id`, resumes with `codex exec resume`.

MCP server approach: structured API calls, built-in session management, no shell parsing.

Consider:
- Is the MCP server stable / documented?
- Would it work across all platforms (Claude Code, Windsurf, Gemini)?
- Is the migration worth the complexity?

- [ ] **Step 3: Document findings as a decision record**

Create `docs/decisions/YYYY-MM-DD-session-management.md` if the finding warrants it.

---

### Task 9: Add PLANS.md convention

**Files:**
- Create: `PLANS.md`

- [ ] **Step 1: Create PLANS.md**

A lightweight convention file that tracks active and completed plans:

```markdown
# Devflow Plans

## Active

| Plan | Created | Status |
|------|---------|--------|
| [Roadmap](docs/superpowers/plans/2026-03-18-devflow-roadmap.md) | 2026-03-18 | In progress |

## Completed

(none yet)
```

- [ ] **Step 2: Commit**

```bash
git add PLANS.md
git commit -m "Add PLANS.md convention for tracking active/completed plans"
```

---

### Task 10: Research Claude Code marketplace publishing

This is a **research task** — no code changes.

- [ ] **Step 1: Check Claude Code marketplace requirements**

Research:
- How are plugins submitted to `claude-plugins-official`?
- Is there a separate registry for community plugins?
- What are the review requirements?
- Does publishing require changes to plugin.json?

- [ ] **Step 2: Document prerequisites**

List what needs to happen before devflow can be published:
- Plugin format compliance
- Testing requirements
- Documentation requirements
- Review process

- [ ] **Step 3: Create a tracking issue on GitHub**

```bash
gh issue create --title "Publish devflow to Claude Code marketplace" \
  --body "Prerequisites and steps for marketplace submission. See research notes."
```

---

## Execution Order

Recommended order respects dependencies:

1. **Task 1** — verify Claude Code integration (blocks everything else if broken)
2. **Task 2** — test install.sh lifecycle (validates the installer)
3. **Task 3** — LICENSE (quick win, unblocks CI)
4. **Task 4** — AGENTS.md (quick win, unblocks CI)
5. **Task 5** — reports directory lifecycle
6. **Task 6** — CI validation (depends on 3, 4 existing)
7. **Tasks 7-10** — P3 research/improvements (independent, any order)
