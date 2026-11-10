#!/usr/bin/env python3
"""Plan or explicitly edit Claude Code hook settings at a caller-selected path.

Usage: python3 claude_hooks_config.py --settings /absolute/settings.json --port 1234 [plan|install]
       python3 claude_hooks_config.py --settings /absolute/settings.json remove
Defaults to a read-only plan. No path under the user's home is selected implicitly.
Each modification preserves the original bytes in an adjacent unique backup.
"""
import argparse
import copy
import datetime
import fcntl
import json
import os
from pathlib import Path
import stat
import sys
import tempfile

MARKER = "IslandReplica event forwarder"
EMPTY_MARKER = "IslandReplica event forwarder (existing empty event)"
ROOT_MISSING_MARKER = "IslandReplica event forwarder (original hooks absent)"
ROOT_MISSING_EMPTY_MARKER = "IslandReplica event forwarder (original hooks absent, existing empty event)"
MARKERS = (MARKER, EMPTY_MARKER, ROOT_MISSING_MARKER, ROOT_MISSING_EMPTY_MARKER)
FORWARDER = str(Path(__file__).resolve().with_name("claude_hook_forward.py"))
PYTHON = "/usr/bin/python3"
EVENTS = ("SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure", "PermissionRequest", "Notification", "Stop", "StopFailure", "SessionEnd")


def ours(handler):
    if not isinstance(handler, dict) or handler.get("statusMessage") not in MARKERS:
        return False
    args = handler.get("args")
    return (handler.get("type") == "command" and handler.get("command") == PYTHON
            and isinstance(args, list) and len(args) == 3 and args[0] == FORWARDER
            and args[1] == "--port" and isinstance(args[2], str)
            and args[2].isdigit() and 1 <= int(args[2]) <= 65535)


def transform(original, mode, port):
    settings = copy.deepcopy(original)
    hooks = settings.get("hooks", {})
    if not isinstance(hooks, dict):
        raise ValueError("hooks must be an object")
    removed = 0
    empty_origins = set()
    root_missing = "hooks" not in settings
    # If prior handlers say the hooks object was absent, preserve that provenance
    # across port changes. Old unmarked installs cannot be inferred safely.
    for event in EVENTS:
        if event not in hooks:
            continue
        groups = hooks[event]
        if not isinstance(groups, list):
            raise ValueError("hooks for " + event + " must be an array")
        for group in groups:
            if not isinstance(group, dict) or not isinstance(group.get("hooks"), list):
                raise ValueError("malformed hook group for " + event)
            if any(ours(h) and h.get("statusMessage") in (ROOT_MISSING_MARKER, ROOT_MISSING_EMPTY_MARKER) for h in group["hooks"]):
                root_missing = True
    for event in EVENTS:
        if event not in hooks:
            continue
        groups = hooks[event]
        if not isinstance(groups, list):
            raise ValueError("hooks for " + event + " must be an array")
        if not groups:
            empty_origins.add(event)
        kept_groups = []
        removed_before_event = removed
        for group in groups:
            if not isinstance(group, dict) or not isinstance(group.get("hooks"), list):
                raise ValueError("malformed hook group for " + event)
            group = copy.deepcopy(group)
            before = len(group["hooks"])
            if any(ours(h) and h.get("statusMessage") in (EMPTY_MARKER, ROOT_MISSING_EMPTY_MARKER) for h in group["hooks"]):
                empty_origins.add(event)
            group["hooks"] = [handler for handler in group["hooks"] if not ours(handler)]
            removed += before - len(group["hooks"])
            # Only delete a group that became empty due to removal of our handler.
            if before != len(group["hooks"]) and not group["hooks"] and set(group) == {"hooks"}:
                continue
            kept_groups.append(group)
        if removed != removed_before_event:
            if kept_groups:
                hooks[event] = kept_groups
            elif event in empty_origins:
                hooks[event] = []
            elif event in hooks:
                del hooks[event]
    added = 0
    if mode in ("install", "plan"):
        for event in EVENTS:
            marker = (ROOT_MISSING_EMPTY_MARKER if event in empty_origins else ROOT_MISSING_MARKER) if root_missing else (EMPTY_MARKER if event in empty_origins else MARKER)
            handler = {"type": "command", "command": PYTHON, "args": [FORWARDER, "--port", str(port)], "timeout": 1, "statusMessage": marker}
            hooks.setdefault(event, []).append({"hooks": [handler]})
            added += 1
    if hooks:
        settings["hooks"] = hooks
    elif "hooks" in settings and removed and root_missing:
        del settings["hooks"]
    return settings, removed, added


def read_target(path):
    if path.is_symlink():
        raise ValueError("settings path cannot be a symbolic link")
    if path.exists():
        if not path.is_file():
            raise ValueError("settings path must be a regular file")
        raw = path.read_bytes()
        data = json.loads(raw.decode("utf-8"))
        if not isinstance(data, dict):
            raise ValueError("settings JSON must be an object")
        return raw, data, stat.S_IMODE(path.stat().st_mode)
    if not path.parent.is_dir():
        raise ValueError("settings parent directory must exist")
    return None, {}, 0o600


def commit(path, original, mode, encoded):
    backup = None
    if original is not None:
        stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
        backup = path.with_name(path.name + ".island-backup-" + stamp)
        with open(backup, "xb") as f:
            os.chmod(backup, mode)
            f.write(original)
            f.flush()
            os.fsync(f.fileno())
    temporary = None
    try:
        fd, temporary = tempfile.mkstemp(prefix=".island-settings-", dir=path.parent)
        with os.fdopen(fd, "wb") as f:
            os.fchmod(f.fileno(), mode)
            f.write(encoded)
            f.flush()
            os.fsync(f.fileno())
        if path.is_symlink() or (original is None and path.exists()) or (original is not None and (not path.exists() or path.read_bytes() != original)):
            raise ValueError("settings changed during operation; no replacement made")
        os.replace(temporary, path)
        temporary = None
    finally:
        if temporary is not None:
            os.unlink(temporary)
    return str(backup) if backup else None


def lock_for_write(path):
    """Serialize cooperating invocations. External editors do not honor this lock."""
    lock_path = path.with_name(path.name + ".island.lock")
    fd = os.open(lock_path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            raise ValueError("lock path must be a regular file")
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            raise ValueError("another IslandReplica settings operation is in progress") from exc
        return fd
    except BaseException:
        os.close(fd)
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("plan", "install", "remove"), nargs="?", default="plan")
    parser.add_argument("--settings", required=True, help="absolute path of the explicitly selected settings.json")
    parser.add_argument("--port", type=int, help="explicit local event port, required for plan/install")
    args = parser.parse_args()
    path = Path(args.settings)
    if not path.is_absolute():
        parser.error("--settings must be an absolute path")
    if args.action != "remove" and (args.port is None or not 1 <= args.port <= 65535):
        parser.error("--port must be between 1 and 65535 for plan/install")
    lock_fd = None
    try:
        if args.action != "plan":
            lock_fd = lock_for_write(path)
        raw, original, mode = read_target(path)
        new, removed, added = transform(original, args.action, args.port)
        changed = new != original
        result = {"action": args.action, "path": str(path), "changed": changed, "removed_handlers": removed, "added_handlers": added, "events": list(EVENTS) if added else [], "backup": None}
        if args.action != "plan" and changed:
            encoded = (json.dumps(new, ensure_ascii=False, indent=2) + "\n").encode("utf-8")
            result["backup"] = commit(path, raw, mode, encoded)
        print(json.dumps(result, ensure_ascii=False))
    except (OSError, UnicodeError, ValueError, json.JSONDecodeError) as exc:
        print("settings operation failed: " + str(exc), file=sys.stderr)
        return 1
    finally:
        if lock_fd is not None:
            os.close(lock_fd)
    return 0


if __name__ == "__main__":
    sys.exit(main())
