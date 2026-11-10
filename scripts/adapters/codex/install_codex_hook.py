#!/usr/bin/env python3
"""Add or remove the Agent Island PermissionRequest hook in a Codex hooks.json, and trust only it.

Codex runs a hook from hooks.json only after its hash is recorded under [hooks.state] in
config.toml, and the hook's key contains its position. So the hook is appended, never inserted,
and trust is written through Codex's own config API for this one hook only.

It never touches other hooks, approval_policy or sandbox settings. Backups are written next to
both files. Details and verification: docs/reference/agent-codex.md.

Usage: install_codex_hook.py [--codex-home DIR] [--codex BIN] [--dry-run] [--undo]
"""
import argparse
import json
import os
import pathlib
import shlex
import shutil
import subprocess
import sys
import tempfile
import time

CODEX_CANDIDATES = ["/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
                    "/Applications/Codex.app/Contents/Resources/codex"]
DEFAULT_CODEX = next((p for p in CODEX_CANDIDATES if os.access(p, os.X_OK)), None) or shutil.which("codex") or CODEX_CANDIDATES[0]
HOOK = os.path.expanduser("~/Library/Application Support/Agent Island/bin/claude_approval_hook.py")
RUNTIME = f"/private/tmp/cc-socks/agent-island-{os.getuid()}-approval"
TIMEOUT = 3600


def island_command(hook=HOOK, runtime=RUNTIME):
    return f"/usr/bin/python3 -I {shlex.quote(hook)} --runtime {shlex.quote(runtime)} --source codex --timeout {TIMEOUT - 10}"


class Server:
    def __init__(self, codex, codex_home):
        env = {**os.environ, "CODEX_HOME": str(codex_home)}
        self.proc = subprocess.Popen([codex, "app-server"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=env, cwd=str(codex_home))
        self.next_id = 0
        self.call("initialize", {"clientInfo": {"name": "agent_island_installer", "title": "Agent Island installer", "version": "1"}, "capabilities": {"experimentalApi": True}})
        self.proc.stdin.write(b'{"method":"initialized"}\n')
        self.proc.stdin.flush()

    def call(self, method, params):
        self.next_id += 1
        self.proc.stdin.write((json.dumps({"id": self.next_id, "method": method, "params": params}) + "\n").encode())
        self.proc.stdin.flush()
        while True:
            line = self.proc.stdout.readline()
            if not line:
                raise RuntimeError("codex app-server exited")
            message = json.loads(line)
            if message.get("id") == self.next_id and "method" not in message:
                if "error" in message:
                    raise RuntimeError(f"{method}: {message['error']}")
                return message["result"]

    def hooks(self, cwd):
        result = self.call("hooks/list", {"cwds": [str(cwd)]})
        return [h for entry in result["data"] for h in entry["hooks"]]

    def close(self):
        self.proc.stdin.close()
        self.proc.terminate()
        self.proc.wait(10)


def atomic_write(path, text):
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=path.name + ".tmp-")
    with os.fdopen(fd, "w", encoding="utf-8") as out:
        out.write(text)
    os.chmod(tmp, os.stat(path).st_mode & 0o777 if path.exists() else 0o644)
    os.replace(tmp, path)


def backup(path, stamp):
    if path.exists():
        shutil.copy2(path, f"{path}.island-backup-{stamp}")


def groups_with(data, command):
    groups = data.get("hooks", {}).get("PermissionRequest", [])
    return [i for i, g in enumerate(groups) if any(h.get("command") == command for h in g.get("hooks", []))]


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--codex-home", default=os.path.expanduser("~/.codex"))
    parser.add_argument("--codex", default=DEFAULT_CODEX)
    parser.add_argument("--hook", default=HOOK, help=argparse.SUPPRESS)
    parser.add_argument("--runtime", default=RUNTIME, help=argparse.SUPPRESS)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--undo", action="store_true")
    args = parser.parse_args()
    home = pathlib.Path(args.codex_home)
    hooks_path, config_path = home / "hooks.json", home / "config.toml"
    data = json.loads(hooks_path.read_text(encoding="utf-8")) if hooks_path.exists() else {"hooks": {}}
    command = island_command(args.hook, args.runtime)
    existing = groups_with(data, command)
    stamp = time.strftime("%Y%m%d-%H%M%S")

    if args.undo:
        if not existing:
            print("nothing to remove: the Agent Island hook is not in hooks.json")
            return 0
        if args.dry_run:
            print(f"would remove {len(existing)} group(s) at PermissionRequest index {existing}")
            return 0
        backup(hooks_path, stamp)
        backup(config_path, stamp)
        server = Server(args.codex, home)
        try:
            removed = {h["key"] for h in server.hooks(home) if h.get("command") == command}
            data["hooks"]["PermissionRequest"] = [g for i, g in enumerate(data["hooks"]["PermissionRequest"]) if i not in existing]
            atomic_write(hooks_path, json.dumps(data, indent=2, ensure_ascii=False) + "\n")
            for key in removed:
                server.call("config/batchWrite", {"edits": [{"keyPath": 'hooks.state."%s"' % key, "value": None, "mergeStrategy": "replace"}], "reloadUserConfig": False})
            print(f"removed. backups: *.island-backup-{stamp}. Restart Codex or start a new thread.")
        finally:
            server.close()
        return 0

    if existing:
        # Another tool may have reordered hooks.json, which changes this hook's key and loses its trust.
        server = Server(args.codex, home)
        try:
            ours = [h for h in server.hooks(home) if h.get("command") == command]
            if not ours or ours[0]["trustStatus"] == "trusted":
                print("already installed at PermissionRequest index", existing)
                return 0
            if args.dry_run:
                print(f"would re-trust {ours[0]['key']} (status {ours[0]['trustStatus']})")
                return 0
            backup(config_path, stamp)
            server.call("config/batchWrite", {"edits": [{"keyPath": "hooks.state", "value": {ours[0]["key"]: {"trusted_hash": ours[0]["currentHash"]}}, "mergeStrategy": "upsert"}], "reloadUserConfig": False})
            print(f"re-trusted {ours[0]['key']} (was {ours[0]['trustStatus']})")
            return 0
        finally:
            server.close()
    groups = data.setdefault("hooks", {}).setdefault("PermissionRequest", [])
    index = len(groups)
    entry = {"hooks": [{"type": "command", "command": command, "timeout": TIMEOUT}]}
    if args.dry_run:
        print("would append to PermissionRequest at index", index)
        print(json.dumps(entry, indent=2, ensure_ascii=False))
        return 0
    server = Server(args.codex, home)
    try:
        before = {h["key"]: h["trustStatus"] for h in server.hooks(home)}
        backup(hooks_path, stamp)
        backup(config_path, stamp)
        groups.append(entry)
        atomic_write(hooks_path, json.dumps(data, indent=2, ensure_ascii=False) + "\n")
        try:
            ours = [h for h in server.hooks(home) if h.get("command") == command]
            if len(ours) != 1 or not ours[0]["key"].endswith(f":permission_request:{index}:0"):
                raise RuntimeError("Codex did not list the new hook where expected")
            server.call("config/batchWrite", {"edits": [{"keyPath": "hooks.state", "value": {ours[0]["key"]: {"trusted_hash": ours[0]["currentHash"]}}, "mergeStrategy": "upsert"}], "reloadUserConfig": False})
            after = {h["key"]: h["trustStatus"] for h in server.hooks(home)}
            changed = {k: (v, after.get(k)) for k, v in before.items() if after.get(k) != v}
            if after.get(ours[0]["key"]) != "trusted" or changed:
                raise RuntimeError(f"verification failed: {ours[0]['key']}={after.get(ours[0]['key'])}, changed={changed}")
        except Exception:
            for path in (hooks_path, config_path):
                if os.path.exists(f"{path}.island-backup-{stamp}"):
                    shutil.copy2(f"{path}.island-backup-{stamp}", path)
            print("failed; hooks.json and config.toml restored from the backups", file=sys.stderr)
            raise
        print(f"installed at {ours[0]['key']} (trusted). backups: *.island-backup-{stamp}. Takes effect for new threads.")
        return 0
    finally:
        server.close()


if __name__ == "__main__":
    sys.exit(main())
