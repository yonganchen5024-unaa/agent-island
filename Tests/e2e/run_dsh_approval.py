#!/usr/bin/env python3
"""End-to-end tests of the DSH (DeepSeek Harness) adapter: REAL dsh CLI, fake model.

What is real: the installed `dsh` launcher, its plugin loader, tool pipeline, approval service and
web host; scripts/adapters/dsh/agent-island-dsh.mjs; scripts/claude_approval_hook.py and the broker.
What is fake: the model (mock_kimi_openai.py speaks DeepSeek's chat-completions dialect), and the
island UI (the broker's stdio plays it, BrokerProc from run_real_cli_approval.py). `sandbox-exec`
cannot start inside the Claude sandbox, so sandbox confinement is not exercised; granted commands
run with `sandbox_permissions: danger-full-access`, which does not need it.

Isolation: HOME and DSH_HOME point to a throwaway directory, the environment is built from nothing,
only 127.0.0.1 is used, and the broker runs in /private/tmp/cc-socks/island-dsh-test. All prompts and
commands are fictional. Never touches ~/.dsh or the running Agent Island.

Run:  TMPDIR=<dir>/ /usr/bin/python3 -I Tests/e2e/run_dsh_approval.py [--only NAME ...] [--out FILE]
"""
import argparse
import base64
import glob
import http.client
import json
import os
import pathlib
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import uuid

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parent.parent
sys.path.insert(0, str(HERE))
from run_real_cli_approval import BrokerProc  # noqa: E402

NODE = "/opt/homebrew/opt/node@22/bin/node"
DSH_BIN = pathlib.Path.home() / ".local/lib/node_modules/@deepseek-ai/dsh/lib/bin.js"
MOCK = HERE / "mock_kimi_openai.py"
PLUGIN = ROOT / "scripts/adapters/dsh/agent-island-dsh.mjs"
HOOK = ROOT / "scripts/claude_approval_hook.py"
RUNTIME = "/private/tmp/cc-socks/island-dsh-test/rt"
MOCK_PORT = 17459
WEB_PORT = 17460
VIBE_PLUGIN_GLOB = str(pathlib.Path.home() / ".vibe-island/dsh-plugin/index-*.js")


def bash(command, escalate=True):
    args = {"command": command, "description": "fictional"}
    if escalate:
        args["sandbox_permissions"] = "danger-full-access"
        args["justification"] = "fictional test escalation"
    return {"tool": "bash", "args": args}


SCENARIOS = {
    "KW_ESCALATE": [[bash("echo fictional-run | tee marker.txt")], [{"text": "finished-turn"}]],
    "KW_NOESCALATE": [[bash("echo fictional-run | tee marker.txt", escalate=False)], [{"text": "finished-turn"}]],
    "KW_WRITE": [[{"tool": "write", "args": {"file_path": "fictional.txt", "content": "fictional"}}], [{"text": "finished-turn"}]],
    "KW_FSESC": [[{"tool": "write", "args": {"file_path": "escalated.txt", "content": "fictional", "sandbox_permissions": "danger-full-access",
                                             "justification": "fictional test escalation"}}], [{"text": "finished-turn"}]],
    "KW_ASK": [[{"tool": "ask_user_question", "args": {"questions": [{"id": "q1", "question": "Fictional?", "options": [{"label": "One"}, {"label": "Two"}]}]}}],
               [{"text": "finished-turn"}]],
}

RIVAL = """
// Test double of a second approval plugin that re-dispatches the request and races its own answer.
export const name = 'rival'
export function apply(ctx, config) {
  const clones = new WeakSet()
  ctx.on('approval/request', function (req, next) {
    if (clones.has(req)) return next()
    const abort = new AbortController()
    const copy = { ...req, signal: abort.signal }
    clones.add(copy)
    const chain = Promise.resolve().then(() => ctx.waterfall(this, 'approval/request', copy, () => Promise.resolve('unavailable')))
    const own = new Promise(resolve => { if (config.answerAfterMs >= 0) setTimeout(() => resolve('own'), config.answerAfterMs) })
    return Promise.race([chain, own]).then(value => {
      if (value !== 'own') return value
      abort.abort()
      return config.outcome
    })
  }, { prepend: true })
}
"""

SWITCHER = """
// Test double for the web UI's /permission picker: the same service call, on the first session only.
import { appendFileSync } from 'node:fs'
export const name = 'switcher'
export function apply(ctx, config) {
  let done = false
  ctx.on('session/created', session => {
    if (done) return
    done = true
    setTimeout(() => {
      try {
        ctx.get('permissionPresets').set(session, config.preset)
        appendFileSync(config.log, 'switched\\n')
      } catch (error) {
        appendFileSync(config.log, String(error) + '\\n')
      }
    }, 100)
  })
}
"""

FAKE_HOOKS = {
    "crash": "import sys; sys.exit(7)",
    "empty": "pass",
    "garbage": "print('not json at all')",
    "half": """import sys; sys.stdout.write('{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"')""",
    "wrong_event": """print('{"hookSpecificOutput":{"hookEventName":"PreToolUse","decision":{"behavior":"allow"}}}')""",
    "stderr_allow": """import sys; sys.stderr.write('{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}')""",
    "updated_input": """print('{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow","updatedInput":{"command":"echo tampered"}}}}')""",
    "ask_behavior": """print('{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"ask"}}}')""",
    "hang": "import time; time.sleep(120)",
}


class Env:
    def __init__(self, base, name):
        self.root = pathlib.Path(base) / name
        self.home = self.root / "home"
        self.work = self.root / "work"
        self.work.mkdir(parents=True)
        (self.home / ".dsh").mkdir(parents=True)
        self.env = {"HOME": str(self.home), "DSH_HOME": str(self.home / ".dsh"), "PATH": "/usr/bin:/bin",
                    "DSH_TELEMETRY_DISABLED": "1", "DEEPSEEK_API_KEY": "fictional-key",
                    "DEEPSEEK_BASE_URL": f"http://127.0.0.1:{MOCK_PORT}", "LANG": "en_US.UTF-8"}

    def write_overlay(self, inserts):
        lines = ["- insert:"]
        for item in inserts:
            lines.append(f"    - id: {item['id']}")
            lines.append(f"      name: {json.dumps(item['name'])}")
            if item.get("config"):
                lines.append(f"      config: {json.dumps(item['config'])}")
        path = self.root / "overlay.yml"
        path.write_text("\n".join(lines) + "\n")
        return path

    def island(self, hook=None, runtime=RUNTIME, timeout=30):
        return {"id": "agent-island", "name": str(PLUGIN),
                "config": {"hook": str(hook or HOOK), "runtime": runtime, "timeoutSeconds": timeout}}

    def stub_sandbox_exec(self):
        """sandbox-exec cannot start inside the Claude sandbox. This stand-in only runs the command, so
        DSH's approval logic can be observed for ordinary calls. Confinement itself is NOT tested."""
        bin_dir = self.root / "bin"
        bin_dir.mkdir(exist_ok=True)
        stub = bin_dir / "sandbox-exec"
        stub.write_text('#!/bin/sh\nwhile [ $# -gt 0 ]; do case "$1" in -p|-f|-n|-D) shift 2;; --) shift; break;; *) break;; esac; done\nexec "$@"\n')
        stub.chmod(0o755)
        return {"PATH": f"{bin_dir}:/usr/bin:/bin"}

    def fake_hook(self, code):
        path = self.root / "fake_hook.py"
        path.write_text(code)
        return path

    def rival(self, config):
        path = self.root / "rival.mjs"
        path.write_text(RIVAL)
        return {"id": "rival", "name": str(path), "config": config}


class Headless:
    def __init__(self, env, overlay, task, extra_env=None):
        self.proc = subprocess.Popen(
            [NODE, str(DSH_BIN), "--profile", "headless", "--patch", str(overlay), task], cwd=env.work,
            env={**env.env, **(extra_env or {})}, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            start_new_session=True, text=True)

    def wait(self, timeout=60):
        try:
            out, err = self.proc.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            out, err = self.proc.communicate()
        return out, err


class Web:
    def __init__(self, env, overlay, extra_env=None):
        self.env = env
        self.proc = subprocess.Popen(
            [NODE, str(DSH_BIN), "--profile", "web", "--patch", str(overlay), "--host", "127.0.0.1", "--port", str(WEB_PORT)],
            cwd=env.work, env={**env.env, **(extra_env or {})}, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            start_new_session=True, text=True)
        self.frames = []
        self.lock = threading.Lock()
        self.mux_ready = threading.Event()
        self.mux_error = None
        threading.Thread(target=self._mux, daemon=True).start()
        if not self.mux_ready.wait(45):
            self.stop(signal.SIGKILL)
            raise RuntimeError(f"web mux never connected: {self.mux_error!r}")

    def call(self, method, payload):
        conn = http.client.HTTPConnection("127.0.0.1", WEB_PORT, timeout=10)
        body = json.dumps({"type": "client-request", "rpcId": str(uuid.uuid4()), "method": method, "payload": payload})
        conn.request("POST", f"/api/{method}", body, {"content-type": "application/json"})
        data = conn.getresponse().read()
        conn.close()
        return json.loads(data)

    def respond(self, rpc_id, value):
        conn = http.client.HTTPConnection("127.0.0.1", WEB_PORT, timeout=10)
        body = json.dumps({"type": "client-response", "rpcId": rpc_id, "result": {"ok": True, "value": value}})
        conn.request("POST", "/api/respond", body, {"content-type": "application/json"})
        data = conn.getresponse().read()
        conn.close()
        return json.loads(data)

    def _mux(self):
        """Minimal WebSocket client for /api/events.mux (the web UI's downlink), stdlib only."""
        try:
            sock, buffer = self._upgrade()
            if sock is None:
                return
            self.mux_ready.set()

            def need(n):
                nonlocal buffer
                while len(buffer) < n:
                    chunk = sock.recv(1 << 20)
                    if not chunk:
                        raise EOFError
                    buffer += chunk
                head, buffer = buffer[:n], buffer[n:]
                return head

            message = b""
            while True:
                b0, b1 = need(2)
                length = b1 & 0x7f
                if length == 126:
                    length = int.from_bytes(need(2), "big")
                elif length == 127:
                    length = int.from_bytes(need(8), "big")
                data = need(length)
                opcode = b0 & 0x0f
                if opcode in (1, 0):
                    message += data
                    if b0 & 0x80:
                        frame = json.loads(message)
                        message = b""
                        with self.lock:
                            self.frames.append(frame)
                elif opcode == 9:
                    mask = os.urandom(4)
                    sock.sendall(bytes([0x8a, 0x80 | len(data)]) + mask + bytes(c ^ mask[i % 4] for i, c in enumerate(data)))
                elif opcode == 8:
                    return
        except Exception as error:
            self.mux_error = error

    def _upgrade(self):
        """The API answers before the WebSocket route exists, so retry until the server says 101."""
        end = time.time() + 40
        while time.time() < end:
            try:
                sock = socket.create_connection(("127.0.0.1", WEB_PORT), timeout=600)
                key = base64.b64encode(os.urandom(16)).decode()
                sock.sendall((f"GET /api/events.mux HTTP/1.1\r\nHost: 127.0.0.1:{WEB_PORT}\r\nUpgrade: websocket\r\n"
                              f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n").encode())
                buffer = b""
                while b"\r\n\r\n" not in buffer:
                    chunk = sock.recv(4096)
                    if not chunk:
                        raise OSError("closed during upgrade")
                    buffer += chunk
                head, rest = buffer.split(b"\r\n\r\n", 1)
                if head.startswith(b"HTTP/1.1 101"):
                    return sock, rest
                self.mux_error = head[:80]
                sock.close()
            except OSError as error:
                self.mux_error = error
            time.sleep(0.25)
        return None, b""

    def wait_frame(self, kind, timeout=20, seen=None):
        seen = seen if seen is not None else set()
        end = time.time() + timeout
        while time.time() < end:
            with self.lock:
                frames = list(self.frames)
            for index, frame in enumerate(frames):
                payload = frame.get("payload") or frame
                if index not in seen and payload.get("type") == kind:
                    seen.add(index)
                    return frame, payload
            time.sleep(0.05)
        return None, None

    def create(self):
        reply = self.call("session.create", {"cwd": str(self.env.work)})
        return reply["result"]["value"]["sessionId"]

    def prompt(self, sid, text):
        return self.call("session.prompt", {"sessionId": sid, "mode": "queue", "content": [{"type": "text", "text": text}]})

    def stop(self, sig=signal.SIGTERM):
        if self.proc.poll() is None:
            self.proc.send_signal(sig)
            try:
                self.proc.wait(10)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait(5)
        self.proc.stdout.close()
        self.proc.stderr.close()


class Case:
    def __init__(self, name):
        self.name, self.checks, self.notes = name, [], {}

    def check(self, label, ok, detail=None):
        self.checks.append({"check": label, "ok": bool(ok), "detail": detail})

    def note(self, key, value):
        self.notes[key] = value

    @property
    def passed(self):
        return all(c["ok"] for c in self.checks)


def api_log():
    path = pathlib.Path(MockServer.log)
    return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []


def tool_results(scenario):
    found = []
    for record in api_log():
        if record.get("kind") == "main" and record.get("scenario") == scenario:
            for item in record.get("tool_results", []):
                if item not in found:
                    found.append(item)
    return found


class MockServer:
    log = None
    proc = None

    @classmethod
    def start(cls, base):
        cls.log = os.path.join(base, "api.jsonl")
        scenarios = os.path.join(base, "scenarios.json")
        pathlib.Path(scenarios).write_text(json.dumps(SCENARIOS))
        cls.proc = subprocess.Popen(["/usr/bin/python3", "-I", str(MOCK), "--port", str(MOCK_PORT), "--scenarios", scenarios, "--log", cls.log],
                                    stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        assert cls.proc.stdout.readline().strip() == "ready"

    @classmethod
    def clear(cls):
        pathlib.Path(cls.log).write_text("")

    @classmethod
    def stop(cls):
        cls.proc.terminate()
        cls.proc.wait(5)


def web_frame_payload(frame):
    return frame.get("payload") or frame


def lifecycle_names(broker):
    return [e["name"] for e in broker.of("lifecycle")]


def wait_gone(paths_pred, timeout=8):
    end = time.time() + timeout
    while time.time() < end:
        if paths_pred():
            return True
        time.sleep(0.1)
    return False


def hook_children(pid):
    """Direct children of `pid` whose command line runs our hook. `pgrep -P` is safe in the sandbox."""
    out = subprocess.run(["/usr/bin/pgrep", "-P", str(pid), "-f", "claude_approval_hook"], capture_output=True, text=True).stdout
    return [int(x) for x in out.split()]


def headless_decision(base, case, decision, expect_marker, expect_substring):
    env = Env(base, case.name)
    broker = BrokerProc(runtime=RUNTIME)
    try:
        run = Headless(env, env.write_overlay([env.island()]), "KW_ESCALATE fictional task")
        request = broker.next("request", 30)
        case.check("broker received PermissionRequest", request is not None)
        if request:
            case.check("source is dsh", request.get("source") == "dsh", request.get("source"))
            case.check("tool input is complete", "echo fictional-run | tee marker.txt" in str(request.get("tool_input", request)), request)
            case.check("session id matches the DSH form", str(request.get("session_id", "")).startswith("session-"), request.get("session_id"))
            case.check("no always-allow offered", not request.get("permission_suggestions"), request.get("permission_suggestions"))
            case.check("request bound to its tool call", str(request.get("tool_use_id", "")).startswith("call_mock_"), request.get("tool_use_id"))
            case.check("marker absent before the decision", not (env.work / "marker.txt").exists())
            broker.decide(request["nonce"], decision)
        out, err = run.wait(30)
        case.note("exit", run.proc.returncode)
        case.check("dsh exits 0", run.proc.returncode == 0, err[-300:])
        case.check("marker state", (env.work / "marker.txt").exists() == expect_marker)
        results = tool_results("KW_ESCALATE")
        case.check("fake model received the tool result", any(expect_substring in r["content"] for r in results), results)
        case.note("tool_result", results)
        time.sleep(0.5)
        names = lifecycle_names(broker)
        case.note("lifecycle", names)
        if decision == "allow":
            case.check("status order", [n for n in ("SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop", "SessionEnd")
                                        if n in names] == ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop", "SessionEnd"], names)
        resolved = broker.of("resolved")
        case.note("broker_resolved", resolved)
    finally:
        broker.stop()


def scenario_allow(base, case):
    headless_decision(base, case, "allow", True, "fictional")


def scenario_deny(base, case):
    headless_decision(base, case, "deny", False, "rejected")


def failure_headless(base, case, hook_code=None, broker_up=True, timeout=30, runtime=RUNTIME):
    """Without any answerer in headless DSH, a failed hook must end as a denial, never as a grant."""
    env = Env(base, case.name)
    broker = BrokerProc(runtime=RUNTIME) if broker_up else None
    try:
        hook = env.fake_hook(hook_code) if hook_code else HOOK
        run = Headless(env, env.write_overlay([env.island(hook=hook, timeout=timeout, runtime=runtime)]), "KW_ESCALATE fictional task")
        out, err = run.wait(timeout + 40)
        case.note("exit", run.proc.returncode)
        results = tool_results("KW_ESCALATE")
        case.note("tool_result", results)
        case.check("command did not run", not (env.work / "marker.txt").exists())
        case.check("model told no approval channel", any("no approval channel" in r["content"] for r in results), results)
        case.check("the model call completed", run.proc.returncode == 0, err[-300:])
    finally:
        if broker:
            broker.stop()


def failure_web(base, case, hook_code, outcome, marker):
    """A failed hook leaves DSH's own web answerer in control: its card stays and decides."""
    env = Env(base, case.name)
    broker = BrokerProc(runtime=RUNTIME)
    web = Web(env, env.write_overlay([env.island(hook=env.fake_hook(hook_code))]))
    try:
        sid = web.create()
        web.prompt(sid, "KW_ESCALATE fictional task")
        frame, payload = web.wait_frame("approval/requested", 30)
        case.check("DSH web still asks", payload is not None)
        time.sleep(2)
        case.check("command did not run while waiting", not (env.work / "marker.txt").exists())
        case.check("no decision made without the web answer", not any((f.get("payload") or f).get("type") == "approval/resolved" for f in web.frames))
        answer = web.respond(frame["rpcId"], {"sessionId": sid, "approvalId": payload["approvalId"], "outcome": outcome})
        case.check("web accepted the answer", answer.get("accepted") is True, answer)
        ok = wait_gone(lambda: (env.work / "marker.txt").exists() == marker and tool_results("KW_ESCALATE"), 15)
        case.check("marker state after web answer", ok and (env.work / "marker.txt").exists() == marker)
    finally:
        web.stop()
        broker.stop()


FAILURES = {name: code for name, code in FAKE_HOOKS.items() if name not in ("hang",)}


def scenario_broker_absent(base, case):
    failure_headless(base, case, broker_up=False, runtime="/private/tmp/cc-socks/island-dsh-test/absent")


def scenario_hook_timeout(base, case):
    """The real hook gives up after its timeout while the broker keeps the card; nobody clicks."""
    env = Env(base, case.name)
    broker = BrokerProc(runtime=RUNTIME)
    try:
        run = Headless(env, env.write_overlay([env.island(timeout=2)]), "KW_ESCALATE fictional task")
        request = broker.next("request", 30)
        case.check("broker saw the request", request is not None)
        start = time.time()
        run.wait(20)
        case.note("seconds_to_end", round(time.time() - start, 1))
        results = tool_results("KW_ESCALATE")
        case.check("command did not run", not (env.work / "marker.txt").exists())
        case.check("model told no approval channel", any("no approval channel" in r["content"] for r in results), results)
        case.check("card withdrawn after hook timeout", wait_gone(lambda: broker.of("resolved"), 5), broker.of("resolved"))
    finally:
        broker.stop()


def scenario_hook_hang(base, case):
    """A hook that hangs past its timeout gets killed by the plugin (timeout + 3 s), then denied."""
    env = Env(base, case.name)
    broker = BrokerProc(runtime=RUNTIME)
    try:
        run = Headless(env, env.write_overlay([env.island(hook=env.fake_hook(FAKE_HOOKS["hang"]), timeout=2)]), "KW_ESCALATE fictional task")
        run.wait(30)
        results = tool_results("KW_ESCALATE")
        case.note("tool_result", results)
        case.check("command did not run", not (env.work / "marker.txt").exists())
        case.check("model told no approval channel", any("no approval channel" in r["content"] for r in results), results)
    finally:
        broker.stop()


def web_case(base, case, inserts_fn, drive):
    env = Env(base, case.name)
    broker = BrokerProc(runtime=RUNTIME)
    web = Web(env, env.write_overlay(inserts_fn(env)))
    try:
        sid = web.create()
        web.prompt(sid, "KW_ESCALATE fictional task")
        drive(env, broker, web, sid)
    finally:
        web.stop()
        broker.stop()


def scenario_web_native_first(base, case):
    def drive(env, broker, web, sid):
        request = broker.next("request", 30)
        frame, payload = web.wait_frame("approval/requested", 30)
        case.check("island card and web card coexist", request is not None and payload is not None, {"island": request is not None, "web": payload is not None})
        children = hook_children(web.proc.pid)
        case.check("hook is still waiting", len(children) >= 1, children)
        web.respond(frame["rpcId"], {"sessionId": sid, "approvalId": payload["approvalId"], "outcome": "allowed-once"})
        case.check("command ran", wait_gone(lambda: (env.work / "marker.txt").exists(), 15))
        case.check("island card withdrawn", wait_gone(lambda: broker.of("resolved"), 8), broker.of("resolved"))
        case.note("broker_resolved", broker.of("resolved"))
        case.check("hook gone after web answer", wait_gone(lambda: not hook_children(web.proc.pid), 8), hook_children(web.proc.pid))
    web_case(base, case, lambda env: [env.island()], drive)


def scenario_web_island_first(base, case):
    def drive(env, broker, web, sid):
        request = broker.next("request", 30)
        frame, payload = web.wait_frame("approval/requested", 30)
        case.check("both cards exist", request is not None and payload is not None, {"island": request is not None, "web": payload is not None})
        broker.decide(request["nonce"], "allow")
        case.check("command ran", wait_gone(lambda: (env.work / "marker.txt").exists(), 15))
        resolved_frame, resolved = web.wait_frame("approval/resolved", 10)
        case.check("web card withdrawn", resolved is not None, resolved)
        case.note("web_resolved", resolved)
    web_case(base, case, lambda env: [env.island()], drive)


def scenario_web_island_deny(base, case):
    def drive(env, broker, web, sid):
        request = broker.next("request", 30)
        frame, payload = web.wait_frame("approval/requested", 30)
        broker.decide(request["nonce"], "deny")
        case.check("model told of the rejection", wait_gone(lambda: tool_results("KW_ESCALATE"), 15), tool_results("KW_ESCALATE"))
        results = tool_results("KW_ESCALATE")
        case.note("tool_result", results)
        case.check("rejected reaches model", any("rejected" in r["content"] for r in results))
        case.check("command did not run", not (env.work / "marker.txt").exists())
        resolved_frame, resolved = web.wait_frame("approval/resolved", 10)
        case.check("web card withdrawn", resolved is not None, resolved)
    web_case(base, case, lambda env: [env.island()], drive)


def scenario_web_cancel(base, case):
    def drive(env, broker, web, sid):
        request = broker.next("request", 30)
        case.check("broker saw the request", request is not None)
        children = hook_children(web.proc.pid)
        reply = web.call("session.cancel", {"sessionId": sid})
        case.note("cancel_reply", reply)
        case.check("hook ended on cancel", wait_gone(lambda: not hook_children(web.proc.pid), 8), children)
        case.check("island card withdrawn", wait_gone(lambda: broker.of("resolved"), 8), broker.of("resolved"))
        case.note("broker_resolved", broker.of("resolved"))
        time.sleep(1)
        case.check("command did not run", not (env.work / "marker.txt").exists())
    web_case(base, case, lambda env: [env.island()], drive)


def scenario_web_sigterm(base, case):
    def drive(env, broker, web, sid):
        request = broker.next("request", 30)
        case.check("broker saw the request", request is not None)
        web.proc.send_signal(signal.SIGTERM)
        case.check("island card withdrawn on SIGTERM", wait_gone(lambda: broker.of("resolved"), 12), broker.of("resolved"))
        case.check("SessionEnd delivered on SIGTERM", wait_gone(lambda: "SessionEnd" in lifecycle_names(broker), 12), lifecycle_names(broker))
        case.note("lifecycle", lifecycle_names(broker))
        case.check("command did not run", not (env.work / "marker.txt").exists())
    web_case(base, case, lambda env: [env.island()], drive)


def scenario_web_sigkill(base, case):
    def drive(env, broker, web, sid):
        request = broker.next("request", 30)
        case.check("broker saw the request", request is not None)
        children = hook_children(web.proc.pid)
        web.proc.send_signal(signal.SIGKILL)
        web.proc.wait(5)
        case.check("hook left on its own", wait_gone(lambda: not any(_alive(c) for c in children), 6), children)
        case.check("island card withdrawn", wait_gone(lambda: broker.of("resolved"), 8), broker.of("resolved"))
        names = lifecycle_names(broker)
        case.note("lifecycle", names)
        case.check("no SessionEnd is possible after SIGKILL", "SessionEnd" not in names, names)
        case.check("command did not run", not (env.work / "marker.txt").exists())
    web_case(base, case, lambda env: [env.island()], drive)


def _alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def scenario_policy_never(base, case):
    """DSH's `danger-full-access` preset: never asks, and rejects rather than grants."""
    env = Env(base, case.name)
    broker = BrokerProc(runtime=RUNTIME)
    try:
        run = Headless(env, env.write_overlay([env.island()]), "KW_ESCALATE fictional task", {"DSH_PERMISSION_MODE": "danger-full-access"})
        run.wait(30)
        results = tool_results("KW_ESCALATE")
        case.note("tool_result", results)
        case.check("no request reached the island", len(broker.of("request")) == 0)
        case.note("marker_exists", (env.work / "marker.txt").exists())
    finally:
        broker.stop()


def scenario_profile_patch_block(base, case):
    """The block from docs/reference/agent-dsh.md, appended after a Vibe-style managed block in the profile's own patch file.
    The test adds a config line so that it reaches the test broker, never the real one."""
    env = Env(base, case.name)
    subprocess.run([NODE, str(DSH_BIN), "--profile", "headless", "--dump-config"], cwd=env.work, env=env.env, capture_output=True, timeout=30)
    patch = env.home / ".dsh/profiles/headless/cordis.patch.yml"
    case.check("profile initialised", patch.exists())
    vibe = glob.glob(VIBE_PLUGIN_GLOB)
    managed = ("# >>> vibe-island managed block >>> do not edit; remove the whole block to uninstall\n- insert:\n    - id: vibe-island\n"
               f"      name: {vibe[0]}\n# <<< vibe-island managed block <<<\n") if vibe else ""
    config = json.dumps({"hook": str(HOOK), "runtime": RUNTIME, "timeoutSeconds": 30})
    block = ("# >>> agent-island >>> remove this block to uninstall\n- insert:\n    - id: agent-island\n"
             f"      name: {json.dumps(str(PLUGIN))}\n      config: {config}\n# <<< agent-island <<<\n")
    # A freshly generated patch file holds a bare `[]`, which cannot be appended to. The user's real files do not.
    existing = patch.read_text()
    if existing.rstrip().endswith("[]"):
        existing = existing.rstrip()[:-2]
    patch.write_text(existing + managed + block)
    empty = env.root / "empty.yml"
    empty.write_text("[]\n")
    broker = BrokerProc(runtime=RUNTIME)
    try:
        run = Headless(env, empty, "KW_ESCALATE fictional task")
        request = broker.next("request", 30)
        case.check("loaded from the profile patch", request is not None)
        if request:
            broker.decide(request["nonce"], "allow")
        run.wait(30)
        case.check("command ran after allow", (env.work / "marker.txt").exists())
    finally:
        broker.stop()


def scenario_session_switch(base, case):
    """Default danger-full-access (no prompts); one session is switched through the service behind /permission.
    Only that session asks. The /permission command itself travels over the UI's channel and is not driven here."""
    env = Env(base, case.name)
    broker = BrokerProc(runtime=RUNTIME)
    switcher = env.root / "switcher.mjs"
    switcher.write_text(SWITCHER)
    inserts = [env.island(), {"id": "switcher", "name": str(switcher), "config": {"preset": "workspace-write", "log": str(env.root / "switch.log")}}]
    web = Web(env, env.write_overlay(inserts), {"DSH_PERMISSION_MODE": "danger-full-access", **env.stub_sandbox_exec()})
    try:
        sid = web.create()
        time.sleep(1)
        switch_log = env.root / "switch.log"
        case.note("switch_log", switch_log.read_text() if switch_log.exists() else None)
        case.check("preset switched", switch_log.exists() and "switched" in switch_log.read_text())
        web.prompt(sid, "KW_ESCALATE fictional task")
        request = broker.next("request", 30)
        case.check("switched session asks", request is not None)
        case.note("frames_after_switch", [str(web_frame_payload(f))[:300] for f in web.frames if web_frame_payload(f).get("event", {}).get("type") in ("permission/preset", "sandbox/mode", "approval/policy", "tool/result", "turn/end")])
        case.note("tool_result", tool_results("KW_ESCALATE"))
        if request:
            broker.decide(request["nonce"], "allow")
        case.check("command ran after allow", wait_gone(lambda: (env.work / "marker.txt").exists(), 15))
        other = web.create()
        before = len(broker.of("request"))
        web.prompt(other, "KW_NOESCALATE fictional task")
        time.sleep(4)
        case.check("the other session still has danger-full-access default (no prompt)", len(broker.of("request")) == before, broker.of("request"))
    finally:
        web.stop()
        broker.stop()


def scenario_no_escalation(base, case):
    """Under the default workspace-write + ask, an ordinary bash call runs without asking (sandbox-exec stubbed)."""
    env = Env(base, case.name)
    broker = BrokerProc(runtime=RUNTIME)
    try:
        run = Headless(env, env.write_overlay([env.island()]), "KW_NOESCALATE fictional task", env.stub_sandbox_exec())
        run.wait(30)
        results = tool_results("KW_NOESCALATE")
        case.note("tool_result", results)
        case.check("no request reached the island", len(broker.of("request")) == 0)
        case.check("the command really ran", (env.work / "marker.txt").exists() and any("fictional-run" in r["content"] for r in results), results)
    finally:
        broker.stop()


def scenario_write_tool(base, case):
    env = Env(base, case.name)
    broker = BrokerProc(runtime=RUNTIME)
    try:
        run = Headless(env, env.write_overlay([env.island()]), "KW_WRITE fictional task")
        run.wait(30)
        results = tool_results("KW_WRITE")
        case.note("tool_result", results)
        case.check("no request reached the island", len(broker.of("request")) == 0)
        case.check("the file was written", (env.work / "fictional.txt").exists(), results)
    finally:
        broker.stop()


def scenario_fs_escalation(base, case):
    """The file tools have the same escalation path as bash, under their own tool names."""
    env = Env(base, case.name)
    broker = BrokerProc(runtime=RUNTIME)
    try:
        run = Headless(env, env.write_overlay([env.island()]), "KW_FSESC fictional task")
        request = broker.next("request", 30)
        case.check("broker received the request", request is not None)
        if request:
            case.check("tool name is write", request.get("tool_name") == "write", request.get("tool_name"))
            case.check("complete input shown", "escalated.txt" in str(request.get("tool_input")), request.get("tool_input"))
            case.check("file absent before the decision", not (env.work / "escalated.txt").exists())
            broker.decide(request["nonce"], "allow")
        run.wait(30)
        case.check("file written after allow", (env.work / "escalated.txt").exists(), tool_results("KW_FSESC"))
    finally:
        broker.stop()


def scenario_question_headless(base, case):
    env = Env(base, case.name)
    broker = BrokerProc(runtime=RUNTIME)
    try:
        run = Headless(env, env.write_overlay([env.island()]), "KW_ASK fictional task")
        run.wait(30)
        results = tool_results("KW_ASK")
        case.note("tool_result", results)
        case.check("no island request is made for questions", len(broker.of("request")) == 0)
        case.check("headless does not offer the question tool", any("unknown tool" in r["content"] for r in results), results)
    finally:
        broker.stop()


def scenario_question_web(base, case):
    def drive(env, broker, web, sid):
        frame, payload = web.wait_frame("question/requested", 20)
        case.check("question appears on the web only", payload is not None)
        case.check("no island request", len(broker.of("request")) == 0)
        answer = web.respond(frame["rpcId"], {"sessionId": sid, "answer": {"answers": [{"id": "q1", "selected": ["One"]}]}})
        case.note("answer", answer)
        case.check("answer accepted", answer.get("accepted") is True, answer)
        case.check("model got the answer", wait_gone(lambda: any("One" in r["content"] for r in tool_results("KW_ASK")), 15), tool_results("KW_ASK"))
    env = Env(base, case.name)
    broker = BrokerProc(runtime=RUNTIME)
    web = Web(env, env.write_overlay([env.island()]))
    try:
        sid = web.create()
        web.prompt(sid, "KW_ASK fictional task")
        drive(env, broker, web, sid)
    finally:
        web.stop()
        broker.stop()


def scenario_rival_front_stalls(base, case):
    """Second plugin first in chain, re-dispatches and never answers: the island still decides."""
    def drive(env, broker, web, sid):
        request = broker.next("request", 30)
        case.check("island asked exactly once", request is not None)
        time.sleep(1)
        case.check("no duplicate cards", len(broker.of("request")) == 1, len(broker.of("request")))
        broker.decide(request["nonce"], "allow")
        case.check("command ran", wait_gone(lambda: (env.work / "marker.txt").exists(), 15))
    web_case(base, case, lambda env: [env.island(), env.rival({"answerAfterMs": -1, "outcome": "rejected"})], drive)


def scenario_island_front_with_rival(base, case):
    """Island first in chain, second plugin behind it re-dispatches: no loop, no duplicates."""
    def drive(env, broker, web, sid):
        request = broker.next("request", 30)
        case.check("island asked", request is not None)
        time.sleep(1)
        case.check("no duplicate cards", len(broker.of("request")) == 1, len(broker.of("request")))
        broker.decide(request["nonce"], "allow")
        case.check("command ran", wait_gone(lambda: (env.work / "marker.txt").exists(), 15))
    web_case(base, case, lambda env: [env.rival({"answerAfterMs": -1, "outcome": "rejected"}), env.island()], drive)


def scenario_rival_decides_first(base, case):
    """The other plugin denies at 1 s while the island card waits: its decision wins, nothing runs."""
    def drive(env, broker, web, sid):
        request = broker.next("request", 30)
        case.check("island asked", request is not None)
        case.check("nothing ran", wait_gone(lambda: tool_results("KW_ESCALATE"), 15) and not (env.work / "marker.txt").exists(), tool_results("KW_ESCALATE"))
        case.note("tool_result", tool_results("KW_ESCALATE"))
        case.check("rejected reaches model", any("rejected" in r["content"] for r in tool_results("KW_ESCALATE")))
        case.check("hook withdrawn on the rival's decision", wait_gone(lambda: not hook_children(web.proc.pid), 8), hook_children(web.proc.pid))
    web_case(base, case, lambda env: [env.island(), env.rival({"answerAfterMs": 1000, "outcome": "rejected"})], drive)


def scenario_vibe_plugin_mounted(base, case):
    """The real Vibe Island DSH plugin file, mounted next to ours under the isolated HOME."""
    paths = glob.glob(VIBE_PLUGIN_GLOB)
    if not paths:
        case.check("Vibe plugin file exists", False, "not installed")
        return

    def drive(env, broker, web, sid):
        request = broker.next("request", 30)
        case.check("island asked exactly once", request is not None)
        time.sleep(1)
        case.check("no duplicate cards", len(broker.of("request")) == 1, len(broker.of("request")))
        broker.decide(request["nonce"], "allow")
        case.check("command ran", wait_gone(lambda: (env.work / "marker.txt").exists(), 15))
    web_case(base, case, lambda env: [env.island(), {"id": "vibe-island", "name": paths[0]}], drive)


CASES = [
    ("allow", scenario_allow),
    ("deny", scenario_deny),
    ("broker_absent", scenario_broker_absent),
    ("hook_timeout", scenario_hook_timeout),
    ("hook_hang", scenario_hook_hang),
    ("web_native_first", scenario_web_native_first),
    ("web_island_first", scenario_web_island_first),
    ("web_island_deny", scenario_web_island_deny),
    ("web_cancel", scenario_web_cancel),
    ("web_sigterm", scenario_web_sigterm),
    ("web_sigkill", scenario_web_sigkill),
    ("policy_never", scenario_policy_never),
    ("session_switch", scenario_session_switch),
    ("profile_patch_block", scenario_profile_patch_block),
    ("no_escalation", scenario_no_escalation),
    ("write_tool", scenario_write_tool),
    ("fs_escalation", scenario_fs_escalation),
    ("question_headless", scenario_question_headless),
    ("question_web", scenario_question_web),
    ("rival_front_stalls", scenario_rival_front_stalls),
    ("island_front_with_rival", scenario_island_front_with_rival),
    ("rival_decides_first", scenario_rival_decides_first),
    ("vibe_plugin_mounted", scenario_vibe_plugin_mounted),
]
for hook_name, hook_code in FAILURES.items():
    CASES.append((f"headless_{hook_name}", lambda base, case, code=hook_code: failure_headless(base, case, hook_code=code)))
    CASES.append((f"web_{hook_name}_then_reject", lambda base, case, code=hook_code: failure_web(base, case, code, "rejected", False)))
CASES.append(("web_crash_then_allow", lambda base, case: failure_web(base, case, FAKE_HOOKS["crash"], "allowed-once", True)))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--only", nargs="*")
    parser.add_argument("--out")
    args = parser.parse_args()
    version = subprocess.run([NODE, str(DSH_BIN), "--version"], capture_output=True, text=True).stdout.strip()
    base = tempfile.mkdtemp(prefix="dsh-e2e-", dir=os.environ.get("TMPDIR", "/tmp"))
    os.makedirs("/private/tmp/cc-socks/island-dsh-test", exist_ok=True)
    MockServer.start(base)
    report = {"dsh_version": version, "started": time.strftime("%Y-%m-%dT%H:%M:%S"), "cases": []}
    failed = 0
    try:
        for name, function in CASES:
            if args.only and name not in args.only:
                continue
            MockServer.clear()
            case = Case(name)
            try:
                function(base, case)
            except Exception as error:  # A crash in one scenario is a failure, not an abort.
                case.check("scenario raised", False, repr(error))
            failed += not case.passed
            report["cases"].append({"name": name, "passed": case.passed, "checks": case.checks, "notes": case.notes})
            print(("PASS " if case.passed else "FAIL ") + name, flush=True)
            for check in case.checks:
                if not check["ok"]:
                    print("   x", check["check"], str(check["detail"])[:400], flush=True)
    finally:
        MockServer.stop()
        shutil.rmtree(base, ignore_errors=True)
        shutil.rmtree("/private/tmp/cc-socks/island-dsh-test/rt", ignore_errors=True)
    if args.out:
        pathlib.Path(args.out).write_text(json.dumps(report, ensure_ascii=False, indent=1))
    print(f"{len(report['cases']) - failed}/{len(report['cases'])} passed on {version}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
