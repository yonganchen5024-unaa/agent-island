#!/usr/bin/env python3
"""Forward a minimal Claude Code command-hook event to an explicit loopback port.

Usage: claude_hook_forward.py --port PORT
Reads one JSON object from stdin. It never installs hooks or reads other files.
Unrecognized events and all errors are ignored; it writes nothing to stdout/stderr
and always exits successfully, so this observational hook cannot decide approvals.
See https://code.claude.com/docs/en/hooks .
"""
import json
import re
import socket
import sys

MAX_INPUT = 1_048_576
MAX_SESSION_ID = 128

# Static labels avoid forwarding prompt, paths, tool arguments, or tool output.
EVENTS = {
    "SessionStart": ("idle", "会话已启动"),
    "UserPromptSubmit": ("working", "正在处理"),
    "PreToolUse": ("working", "正在使用工具"),
    "PostToolUse": ("working", "正在处理"),
    "PostToolUseFailure": ("working", "工具未成功，继续处理"),
    "PermissionRequest": ("waiting", "等待权限确认"),
    "Stop": ("idle", "本轮已结束"),
    "StopFailure": ("error", "本轮异常结束"),
    "SessionEnd": ("SessionEnd", "会话已结束"),
}
NOTIFICATIONS = {
    "permission_prompt": ("waiting", "等待权限确认"),
    "elicitation_dialog": ("waiting", "等待输入"),
    "elicitation_url_dialog": ("waiting", "等待输入"),
    "agent_needs_input": ("waiting", "等待输入"),
    "idle_prompt": ("idle", "等待新消息"),
}


def main():
    if len(sys.argv) != 3 or sys.argv[1] != "--port":
        return
    try:
        port = int(sys.argv[2])
        if not 1 <= port <= 65535:
            return
        raw = sys.stdin.buffer.read(MAX_INPUT + 1)
        if len(raw) > MAX_INPUT:
            return
        body = json.loads(raw)
        if not isinstance(body, dict):
            return
        session_id, name = body.get("session_id"), body.get("hook_event_name")
        if not isinstance(session_id, str) or len(session_id) > MAX_SESSION_ID:
            return
        if not re.fullmatch(r"[A-Za-z0-9_-]+", session_id):
            return
        # Tool events from child agents share the parent session_id. Do not let
        # them overwrite the main session's state until child tracking exists.
        if body.get("agent_id"):
            return
        if name == "Notification":
            state = NOTIFICATIONS.get(body.get("notification_type"))
        else:
            state = EVENTS.get(name) if isinstance(name, str) else None
        if state is None:
            return
        status, detail = state
        event = {"sessionId": session_id, "event": status, "agent": "Claude Code", "detail": detail}
        data = (json.dumps(event, ensure_ascii=False, separators=(",", ":")) + "\n").encode("utf-8")
        with socket.create_connection(("127.0.0.1", port), timeout=0.25) as conn:
            conn.settimeout(0.25)
            conn.sendall(data)
    except (OSError, UnicodeError, ValueError, TypeError, json.JSONDecodeError):
        return


if __name__ == "__main__":
    main()
