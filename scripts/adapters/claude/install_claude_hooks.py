#!/usr/bin/env python3
"""Add or remove Agent Island's hooks in a Claude Code user settings file.

Two hooks are added, both run with the system Python and both installed by install-app.sh:

* claude_approval_hook.py: approval requests (PermissionRequest) and the events the broker uses
  to withdraw cards and confirm results.
* claude_spool_hook.py: one-line status signals (no prompts, paths or tool input) that drive the
  island's sounds and notifications.

Other hooks in the file are left alone. A backup is written next to the file before any change.
If a managed policy only allows managed hooks, user hooks would be ignored, so nothing is changed.

Usage: install_claude_hooks.py [--settings FILE] [--dry-run] [--undo]
"""
import argparse
import json
import os
import pathlib
import shlex
import shutil
import sys
import tempfile
import time

SUPPORT = pathlib.Path.home() / "Library/Application Support/Agent Island"
BIN = SUPPORT / "bin"
APPROVAL_HOOK = BIN / "claude_approval_hook.py"
SPOOL_HOOK = BIN / "claude_spool_hook.py"
SPOOL = SUPPORT / "claude-spool-v1"
RUNTIME = f"/private/tmp/cc-socks/agent-island-{os.getuid()}-approval"
MANAGED = pathlib.Path("/Library/Application Support/ClaudeCode/managed-settings.json")

APPROVAL_EVENTS = ["PreToolUse", "PostToolUse", "PostToolUseFailure", "Stop", "StopFailure", "SessionEnd",
                   "UserPromptSubmit", "SubagentStop", "PreCompact"]
SPOOL_EVENTS = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure",
                "PermissionRequest", "Notification", "Stop", "StopFailure", "SessionEnd"]


def approval_command(wait=False):
    command = f"/usr/bin/python3 -I {shlex.quote(str(APPROVAL_HOOK))} --runtime {shlex.quote(RUNTIME)}"
    return command + " --timeout 3590" if wait else command


def spool_command():
    return f"/usr/bin/python3 -I {shlex.quote(str(SPOOL_HOOK))} --root {shlex.quote(str(SUPPORT))} --spool {shlex.quote(str(SPOOL))}"


def wanted():
    """Event name -> list of (command, timeout) this installer owns."""
    hooks = {"PermissionRequest": [(approval_command(wait=True), 3600)]}
    for event in APPROVAL_EVENTS:
        hooks.setdefault(event, []).append((approval_command(), 5))
    for event in SPOOL_EVENTS:
        hooks.setdefault(event, []).append((spool_command(), 5))
    return hooks


def ours(handler):
    command = handler.get("command") if isinstance(handler, dict) else None
    return isinstance(command, str) and (str(APPROVAL_HOOK) in command or str(SPOOL_HOOK) in command)


def strip(data):
    """Removes this installer's handlers, and groups left empty by that."""
    hooks = data.get("hooks")
    if not isinstance(hooks, dict):
        return 0
    removed = 0
    for event in list(hooks):
        groups = hooks[event] if isinstance(hooks[event], list) else []
        kept = []
        for group in groups:
            handlers = group.get("hooks") if isinstance(group, dict) else None
            if not isinstance(handlers, list):
                kept.append(group)
                continue
            left = [h for h in handlers if not ours(h)]
            removed += len(handlers) - len(left)
            if left:
                kept.append({**group, "hooks": left})
        if kept:
            hooks[event] = kept
        else:
            del hooks[event]
    if not hooks:
        del data["hooks"]
    return removed


def managed_only():
    try:
        return json.loads(MANAGED.read_text(encoding="utf-8")).get("allowManagedHooksOnly") is True
    except (OSError, ValueError, AttributeError):
        return False


def write(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=path.name + ".tmp-")
    with os.fdopen(fd, "w", encoding="utf-8") as out:
        json.dump(data, out, indent=2, ensure_ascii=False)
        out.write("\n")
    os.chmod(tmp, os.stat(path).st_mode & 0o777 if path.exists() else 0o600)
    os.replace(tmp, path)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--settings", default=str(pathlib.Path.home() / ".claude/settings.json"))
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--undo", action="store_true")
    args = parser.parse_args()
    path = pathlib.Path(args.settings)
    data = json.loads(path.read_text(encoding="utf-8")) if path.exists() else {}
    if not isinstance(data, dict):
        sys.exit(f"{path} is not a JSON object; nothing changed")
    stamp = time.strftime("%Y%m%d-%H%M%S")

    if args.undo:
        removed = strip(data)
        if not removed:
            print("Claude: nothing to remove")
            return 0
        if args.dry_run:
            print(f"Claude: would remove {removed} handler(s)")
            return 0
        shutil.copy2(path, f"{path}.island-backup-{stamp}")
        write(path, data)
        print(f"Claude: removed {removed} handler(s). Backup: {path}.island-backup-{stamp}")
        return 0

    if managed_only() and not args.dry_run:
        print("Claude: a managed policy on this Mac only allows managed hooks, so user hooks would be ignored. Skipped.")
        return 0
    if not APPROVAL_HOOK.exists() or not SPOOL_HOOK.exists():
        sys.exit("Claude: run scripts/install-app.sh first")
    strip(data)  # Reinstalling replaces older copies instead of adding a second set.
    hooks = data.setdefault("hooks", {})
    if not isinstance(hooks, dict):
        sys.exit(f"{path}: \"hooks\" is not an object; nothing changed")
    for event, handlers in wanted().items():
        hooks.setdefault(event, []).append({"hooks": [{"type": "command", "command": c, "timeout": t} for c, t in handlers]})
    if args.dry_run:
        print(json.dumps({"hooks": {e: hooks[e][-1:] for e in wanted()}}, indent=2, ensure_ascii=False))
        return 0
    # The spool hook writes only into a private directory owned by this user.
    SPOOL.mkdir(parents=True, exist_ok=True)
    os.chmod(SPOOL, 0o700)
    existed = path.exists()
    if existed:
        shutil.copy2(path, f"{path}.island-backup-{stamp}")
    write(path, data)
    print(f"Claude: hooks added to {path}" + (f". Backup: {path}.island-backup-{stamp}" if existed else ""))
    print("Claude: new sessions pick them up. A card appears whenever Claude asks for permission or asks a question.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
