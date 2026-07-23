#!/usr/bin/env python3
"""Extract shell-safe fields from Codex JSONL or Claude JSON using only stdlib."""
import json
import re
import sys


SESSION_TOKEN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,255}$")


def fail():
    raise SystemExit(1)


def codex(path):
    result = ""
    session = ""
    events = []
    with open(path, encoding="utf-8") as stream:
        for raw in stream:
            if not raw.strip():
                continue
            try:
                event = json.loads(raw)
            except (json.JSONDecodeError, UnicodeDecodeError):
                fail()
            if not isinstance(event, dict):
                fail()
            events.append(event)
            if not session and isinstance(event.get("thread_id"), str):
                session = event["thread_id"]
            item = event.get("item")
            if (
                event.get("type") == "item.completed"
                and isinstance(item, dict)
                and item.get("type") == "agent_message"
                and isinstance(item.get("text"), str)
            ):
                result = item["text"]
    if not events or events[-1].get("type") != "turn.completed":
        fail()
    if any(event.get("type") == "turn.failed" for event in events):
        fail()
    return result, session


def claude(path):
    with open(path, encoding="utf-8") as stream:
        payload = json.load(stream)
    if not isinstance(payload, dict):
        fail()
    # Fail closed on an error payload, mirroring codex()'s turn.failed guard: claude -p can
    # emit {"is_error": true, ..., "result": "<error msg>"} while still exiting 0, and without
    # this a failed turn's error text would be handed back as a usable verdict.
    if payload.get("is_error") or str(payload.get("subtype", "")).startswith("error"):
        fail()
    result = payload.get("result", "")
    session = payload.get("session_id", "")
    return (result if isinstance(result, str) else "", session if isinstance(session, str) else "")


def main():
    if len(sys.argv) != 4 or sys.argv[1] not in {"codex", "claude"} or sys.argv[2] not in {"result", "session"}:
        fail()
    try:
        result, session = codex(sys.argv[3]) if sys.argv[1] == "codex" else claude(sys.argv[3])
    except (OSError, json.JSONDecodeError, UnicodeDecodeError):
        fail()
    value = result if sys.argv[2] == "result" else session
    # Bash variables cannot contain NUL; emitting it would silently delete the byte and
    # could turn an untrusted near-verdict into an accepted token.
    if "\x00" in value:
        fail()
    if sys.argv[2] == "session" and value and not SESSION_TOKEN.fullmatch(value):
        fail()
    sys.stdout.write(value)


if __name__ == "__main__":
    main()
