#!/usr/bin/env python3
"""Drive the REAL Claude Code CLI in an isolated environment against a fake local API.

What is real here: the Claude Code 2.1.x binary, its hook runner, its native
permission dialog, the system managed settings it loads, and any managed sibling hooks.
What is fake: the model (mock_anthropic.py) and every byte of conversation data.

What keeps it isolated:
  * HOME and CLAUDE_CONFIG_DIR point to a throwaway directory under --root.
  * The environment is built from scratch, so this session's variables do not leak in.
  * ANTHROPIC_BASE_URL points at 127.0.0.1; the caller's sandbox denies other egress.
  * Managed settings and network-guard files are read-only inputs here. Nothing writes them.

The first managed PermissionRequest handler runs "$HOME/.vibe-island/bin/vibe-island-bridge".
Under a throwaway HOME that resolves to slot_hook.py, so a real CLI can exercise a test hook
without any change to managed settings or to the user's real ~/.vibe-island.
"""
import json
import os
import pathlib
import pty
import re
import select
import shutil
import signal
import socket
import struct
import fcntl
import subprocess
import sys
import termios
import time

HERE = pathlib.Path(__file__).resolve().parent
CLAUDE = "/opt/homebrew/bin/claude"
ANSI = re.compile(rb"\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b[()][0-9A-Za-z]|\x1b[=>78DEHMNOZ]")


def refuse_if_island_running():
    """The installed managed hook runs in every Claude session, including these test sessions, and
    its runtime path cannot be changed. If the real island is up, a fictional request would pop up
    on the user's screen, and block the test until someone clicks it. So refuse to run."""
    path = f"/private/tmp/cc-socks/agent-island-{os.getuid()}-approval/broker.sock"
    probe = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    probe.settimeout(0.5)
    try:
        probe.connect(path)
    except OSError:
        return
    finally:
        probe.close()
    raise SystemExit("拒绝运行：真实小岛正在运行，测试请求会弹到屏幕上。请先退出小岛。")


class Env:
    def __init__(self, root, port=17469):
        self.root = pathlib.Path(root)
        self.port = port
        self.home = self.root / "home"
        self.work = self.root / "work"
        self.api_log = self.root / "api.jsonl"
        self.server = None

    def prepare(self, scenarios, slot=True):
        if self.root.exists():
            shutil.rmtree(self.root)
        self.work.mkdir(parents=True)
        (self.home / ".claude").mkdir(parents=True)
        (self.root / "scenarios.json").write_text(json.dumps(scenarios, ensure_ascii=False))
        state = {
            "hasCompletedOnboarding": True, "lastOnboardingVersion": "2.1.316", "numStartups": 5,
            "bypassPermissionsModeAccepted": True, "autoUpdates": False,
            "customApiKeyResponses": {"approved": ["fictional-test-key"[-20:]], "rejected": []},
            "theme": "dark", "officialMarketplaceAutoInstallAttempted": True,
            "projects": {str(self.work): {"hasTrustDialogAccepted": True, "hasCompletedProjectOnboarding": True,
                                          "projectOnboardingSeenCount": 5, "allowedTools": []}},
        }
        real_work = os.path.realpath(self.work)
        state["projects"][real_work] = state["projects"][str(self.work)]
        (self.home / ".claude.json").write_text(json.dumps(state))
        (self.home / ".claude" / ".claude.json").write_text(json.dumps(state))
        if slot:
            bin_dir = self.home / ".vibe-island" / "bin"
            bin_dir.mkdir(parents=True)
            target = bin_dir / "vibe-island-bridge"
            shutil.copy(HERE / "slot_hook.py", target)
            target.chmod(0o755)
        self.slot_config({"mode": "empty"})

    def slot_config(self, config):
        (self.home / "slot-config.json").write_text(json.dumps(config, ensure_ascii=False))

    def slot_log(self):
        path = self.home / "slot-log.jsonl"
        return [json.loads(l) for l in path.read_text().splitlines()] if path.exists() else []

    def api_records(self):
        return [json.loads(l) for l in self.api_log.read_text().splitlines()] if self.api_log.exists() else []

    def clear_logs(self):
        for path in (self.home / "slot-log.jsonl", self.api_log):
            if path.exists():
                path.unlink()

    def start_server(self, real_island_ok=False):
        if not real_island_ok:
            refuse_if_island_running()
        self.server = subprocess.Popen(
            [sys.executable, "-I", str(HERE / "mock_anthropic.py"), "--port", str(self.port),
             "--scenarios", str(self.root / "scenarios.json"), "--log", str(self.api_log)],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        assert self.server.stdout.readline().strip() == b"ready"

    def stop_server(self):
        if self.server:
            self.server.terminate()
            self.server.wait(5)
            self.server = None

    def child_env(self, extra=None):
        env = {
            "HOME": str(self.home), "CLAUDE_CONFIG_DIR": str(self.home / ".claude"),
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin", "TERM": "xterm-256color",
            "LANG": "en_US.UTF-8", "USER": os.environ.get("USER", "apple"), "COLUMNS": "160", "LINES": "50",
            "TMPDIR": str(self.root) + "/",
            "ANTHROPIC_BASE_URL": f"http://127.0.0.1:{self.port}", "ANTHROPIC_API_KEY": "fictional-test-key",
            "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1", "DISABLE_AUTOUPDATER": "1", "DISABLE_TELEMETRY": "1",
            "DISABLE_ERROR_REPORTING": "1", "CLAUDE_CODE_DISABLE_TERMINAL_TITLE": "1",
        }
        env.update(extra or {})
        return env

    def run_print(self, prompt, mode="default", timeout=60, extra_args=(), extra_env=None):
        return subprocess.run(
            [CLAUDE, "-p", prompt, "--permission-mode", mode, "--output-format", "json", "--model", "claude-mock",
             *extra_args],
            cwd=self.work, env=self.child_env(extra_env), capture_output=True, text=True, timeout=timeout,
            stdin=subprocess.DEVNULL)

    def spawn_tty(self, mode="default", extra_args=(), extra_env=None):
        return TTY(self, mode, extra_args, extra_env)


class TTY:
    """A real interactive CLI on a pty. Rendered text is scanned with ANSI codes removed."""

    def __init__(self, env, mode, extra_args, extra_env):
        self.master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 50, 160, 0, 0))
        self.proc = subprocess.Popen(
            [CLAUDE, "--permission-mode", mode, "--model", "claude-mock", *extra_args],
            cwd=env.work, env=env.child_env(extra_env), stdin=slave, stdout=slave, stderr=slave,
            start_new_session=True, close_fds=True)
        os.close(slave)
        self.buffer = bytearray()
        self.mark = 0

    def pump(self, seconds=0.1):
        if self.master < 0:
            return
        end = time.time() + seconds
        while True:
            remaining = max(0, end - time.time())
            ready, _, _ = select.select([self.master], [], [], remaining)
            if ready:
                try:
                    data = os.read(self.master, 65536)
                except OSError:
                    return
                if not data:
                    return
                self.buffer.extend(data)
                # Answer terminal capability queries so the UI does not stall on them.
                if b"\x1b[c" in data or b"\x1b[0c" in data:
                    os.write(self.master, b"\x1b[?1;2c")
                if b"\x1b[6n" in data:
                    os.write(self.master, b"\x1b[1;1R")
            if time.time() >= end:
                return

    def text(self, since_mark=True):
        raw = bytes(self.buffer[self.mark:] if since_mark else self.buffer)
        return ANSI.sub(b"", raw).decode("utf-8", "replace")

    def set_mark(self):
        self.pump(0.05)
        self.mark = len(self.buffer)

    def wait_for(self, pattern, timeout=30):
        regex = re.compile(pattern)
        end = time.time() + timeout
        while time.time() < end:
            self.pump(0.15)
            if regex.search(self.text()):
                return True
            if self.proc.poll() is not None:
                self.pump(0.2)
                return bool(regex.search(self.text()))
        return False

    def send(self, data):
        os.write(self.master, data if isinstance(data, bytes) else data.encode())

    def submit(self, text):
        # Paste-safe: type, let the input settle, then press Return.
        self.send(text)
        self.pump(0.6)
        self.send(b"\r")

    def alive(self):
        return self.proc.poll() is None

    def close(self):
        if self.master < 0:
            return
        if self.alive():
            try:
                os.killpg(self.proc.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            for _ in range(30):
                if not self.alive():
                    break
                self.pump(0.1)
            if self.alive():
                # macOS answers EPERM for a group whose members are all exiting, so this is not an error.
                try:
                    os.killpg(self.proc.pid, signal.SIGKILL)
                except (ProcessLookupError, PermissionError):
                    pass
        self.proc.wait(5)
        os.close(self.master)
        self.master = -1


def pid_alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
