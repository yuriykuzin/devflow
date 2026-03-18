# Gemini CLI Tool Mapping

Devflow skills use Claude Code tool names. When running under Gemini CLI, use these equivalents:

| Skill references | Gemini CLI equivalent |
|-----------------|----------------------|
| `Bash` | `run_shell_command` |
| `Read` | `read_file` |
| `Write` | `write_file` |
| `Edit` | `edit_file` |
| `Glob` | `list_directory` / shell `find` |
| `Grep` | `search_files` / shell `grep` |
| `Skill` (invoke) | `activate_skill` |
| `TodoWrite` | task tracking via shell |
| `Agent` (subagent) | not available — run sequentially |

## Notes

- Gemini CLI reads `GEMINI.md` and `gemini-extension.json` from the repo root.
- External CLI calls (`codex exec`, `claude -p`) work identically — they run via shell.
- Session files in `/tmp/devflow-*.session` are shared across all tools.
