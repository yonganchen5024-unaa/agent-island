#!/usr/bin/env python3
"""End-to-end tests of the Agent Island OpenCode adapter.

Real here: the OpenCode 1.18.x binary, its plugin host, its permission and question services, the
adapter in scripts/adapters/opencode, the real hook and broker. Fake here: the model (a local
OpenAI-compatible mock) and all data. This script plays the island UI over the broker's stdio.

Isolation: HOME and XDG_* point under a throwaway root, the environment is built from scratch.
Nothing reads or writes the real ~/.config/opencode, except that the coexistence cases load the
third-party plugin files from there, read-only and unchanged.

Run: TMPDIR=<dir>/ /usr/bin/python3 -I Tests/e2e/run_opencode_approval.py [--only NAME,NAME] [--out FILE]
"""
import argparse
import http.server
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
import subprocess
import sys
import tempfile
import termios
import fcntl
import threading
import time
import urllib.error
import urllib.request

HERE = pathlib.Path(__file__).resolve().parent
REPO = HERE.parent.parent
sys.path.insert(0, str(HERE))
from run_real_cli_approval import BrokerProc  # noqa: E402

OPENCODE = os.path.expanduser("~/.opencode/bin/opencode")
REAL_PLUGINS = pathlib.Path(os.path.expanduser("~/.config/opencode"))
ADAPTER = REPO / "scripts" / "adapters" / "opencode"
HOOK = REPO / "scripts" / "claude_approval_hook.py"
MOCK = HERE / "mock_kimi_openai.py"
API_PORT, SERVER_PORT = 17457, 17458
RUNTIME = "/private/tmp/cc-socks/island-opencode-test"
# Under the only directory where the sandbox allows unix sockets, for the fake original app.
SOCKET_HOME = pathlib.Path("/private/tmp/cc-socks/island-opencode-test-home")
ASK_ALL = {"bash": "ask", "edit": "ask"}
ANSI = re.compile(rb"\x1b\[[0-9;?<>=]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b[PX^_][^\x1b]*\x1b\\|\x1b[()][0-9A-Za-z]|\x1b[=>78DEHMNOZ]")

QUESTION_ARGS = {"questions": [{"question": "Fictional colour?", "header": "Colour", "options": [
    {"label": "Red", "description": "first"}, {"label": "Blue", "description": "second"}]}]}
MULTI_ARGS = {"questions": [{"question": "Fictional sizes?", "header": "Sizes", "multiple": True, "options": [
    {"label": "Small", "description": "s"}, {"label": "Large", "description": "l"}]}]}


def bash(keyword, command=None):
    return {"tool": "bash", "id": f"call_{keyword}", "args": {
        "command": command or f"echo fictional-output-{keyword}; echo x > marker-{keyword}.txt", "description": "fictional"}}


def turn(*items):
    return [list(items), [{"text": "finished-turn"}]]


KEYWORDS = ["allow", "deny", "elsewhereok", "elsewhereno", "abort", "kill9", "term", "fcrash", "fempty", "fgarbage", "fwrong",
            "fevent", "fexit2", "fhang", "fnobroker", "fpython", "fbrokerdeath", "fthrow", "finitthrow", "fsyntax", "status",
            "cfgallow", "cfgask", "coexno", "coexhold", "coexfirst", "coexdeny", "coexfast", "runmode", "tuiallow", "tuikey", "tuiesc", "tuihup"]
SCENARIOS = {f"KW_{k}": turn(bash(k)) for k in KEYWORDS}
SCENARIOS["KW_failtool"] = turn({"tool": "read", "id": "call_failtool", "args": {"filePath": "fictional-missing-file.txt"}})
SCENARIOS["KW_parallel"] = turn(bash("para"), bash("parb"))
SCENARIOS["KW_edit"] = turn({"tool": "write", "id": "call_edit", "args": {"filePath": "marker-edit.txt", "content": "fictional content\n"}})
SCENARIOS["KW_qanswer"] = turn({"tool": "question", "id": "call_qa", "args": QUESTION_ARGS})
SCENARIOS["KW_qmulti"] = turn({"tool": "question", "id": "call_qm", "args": MULTI_ARGS})
SCENARIOS["KW_qdeny"] = turn({"tool": "question", "id": "call_qd", "args": QUESTION_ARGS})
SCENARIOS["KW_qcfg"] = turn({"tool": "question", "id": "call_qc", "args": QUESTION_ARGS})
SCENARIOS["KW_qelse"] = turn({"tool": "question", "id": "call_qe", "args": QUESTION_ARGS})
SCENARIOS["KW_taskparent"] = turn({"tool": "task", "id": "call_task", "args": {
    "description": "fictional child", "prompt": "KW_taskchild do it", "subagent_type": "general"}})
SCENARIOS["KW_taskchild"] = turn(bash("child"))


def wait_until(predicate, timeout=20, step=0.05):
    end = time.time() + timeout
    while time.time() < end:
        value = predicate()
        if value:
            return value
        time.sleep(step)
    return predicate()


def hook_processes():
    # The watcher's own arguments name the hook too, so it has to be filtered out.
    out = subprocess.run(["/usr/bin/pgrep", "-fl", f"claude_approval_hook.py --runtime {RUNTIME}"], capture_output=True, text=True).stdout
    return [line.split()[0] for line in out.splitlines() if "agent-island-watch.py" not in line]


def watch_processes():
    out = subprocess.run(["/usr/bin/pgrep", "-f", f"agent-island-watch.py.*{RUNTIME}"], capture_output=True, text=True).stdout
    return [p for p in out.split()]


class Mock:
    def __init__(self, root):
        self.root, self.log, self.proc = root, root / "api.jsonl", None

    def start(self):
        (self.root / "scenarios.json").write_text(json.dumps(SCENARIOS))
        self.proc = subprocess.Popen([sys.executable, "-I", str(MOCK), "--port", str(API_PORT), "--scenarios",
                                      str(self.root / "scenarios.json"), "--log", str(self.log)], stdout=subprocess.PIPE)
        assert self.proc.stdout.readline().strip() == b"ready"

    def stop(self):
        if self.proc:
            self.proc.terminate()
            self.proc.wait(5)
            self.proc.stdout.close()
            self.proc = None

    def results(self, keyword):
        if not self.log.exists():
            return []
        found = []
        for line in self.log.read_text().splitlines():
            record = json.loads(line)
            if record.get("scenario") == f"KW_{keyword}":
                found.extend(r["content"] for r in record.get("tool_results", []))
        return found


class FakeOriginal:
    """Listens on the socket the real vibe-island.js connects to. Wire format read from that plugin."""

    def __init__(self, path, answer=None, delay=0.0):
        self.path, self.answer, self.delay = pathlib.Path(path), answer, delay
        self.frames, self.closed, self.server, self.running = [], [], None, False

    def start(self):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        if self.path.exists():
            self.path.unlink()
        self.server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.server.bind(str(self.path))
        self.server.listen(16)
        self.running = True
        threading.Thread(target=self.loop, daemon=True).start()

    def loop(self):
        while self.running:
            try:
                conn, _ = self.server.accept()
            except OSError:
                return
            threading.Thread(target=self.serve, args=(conn,), daemon=True).start()

    def serve(self, conn):
        data = b""
        try:
            while True:
                chunk = conn.recv(1 << 16)
                if not chunk:
                    break
                data += chunk
                if data.startswith(b"\x00vibe_wire2\n") and len(data) >= 16:
                    size = struct.unpack(">I", data[12:16])[0]
                    if len(data) >= 16 + size:
                        frame = json.loads(data[16:16 + size])
                        data = data[16 + size:]
                        self.frames.append(frame)
                        kind = frame.get("_raw", {}).get("event", {}).get("type")
                        if self.answer and kind == "permission.asked":
                            request = frame["_raw"]["event"]["data"]
                            body = {"_reply": {"to": frame["_await"]["key"], "deliver": {
                                "mode": "post", "origin_path": f"/permission/{request['id']}/reply", "body": self.answer}}}
                            payload = json.dumps(body).encode()
                            time.sleep(self.delay)
                            conn.sendall(struct.pack(">I", len(payload)) + payload)
        except OSError:
            pass
        finally:
            self.closed.append(time.time())
            conn.close()

    def stop(self):
        self.running = False
        if self.server:
            self.server.close()
        if self.path.exists():
            self.path.unlink()


class Env:
    """One isolated OpenCode server and one broker."""

    def __init__(self, root, mock, permission=None, env=None, plugin_text=None, extra_plugins=(), probe=False, broker=True, home=None, broken_plugin=None, serve=True):
        self.root, self.mock = root, mock
        self.home = pathlib.Path(home) if home else root / "home"
        self.cfg, self.work = root / "cfg", root / "work"
        self.permission = ASK_ALL if permission is None else permission
        self.extra_env = env or {}
        self.plugin_text, self.extra_plugins = plugin_text, extra_plugins
        self.probe = probe
        self.broker = None
        self.want_broker = broker
        self.broken_plugin = broken_plugin
        self.serve = serve
        self.proc = None

    def prepare(self):
        if self.root.exists():
            shutil.rmtree(self.root)
        for path in (self.home, self.work, self.root / "data", self.root / "state", self.root / "cache", self.cfg / "opencode" / "plugins"):
            path.mkdir(parents=True, exist_ok=True)
        plugins = self.cfg / "opencode" / "plugins"
        (plugins / "package.json").write_text('{"type":"module"}')
        (self.root / "models.json").write_text("{}")  # Without this, startup waits about 60 s on the blocked models fetch.
        (plugins / "agent-island.js").write_text(self.plugin_text or (ADAPTER / "agent-island.js").read_text())
        shutil.copy(ADAPTER / "agent-island-watch.py", plugins / "agent-island-watch.py")
        if self.probe:
            (plugins / "probe.js").write_text(PROBE_PLUGIN)
        if self.broken_plugin:
            (plugins / "broken.js").write_text(self.broken_plugin)
        for path in self.extra_plugins:
            os.symlink(path, plugins / path.name)
        config = {"$schema": "https://opencode.ai/config.json", "model": "mock/mock-model", "autoupdate": False, "share": "disabled",
                  "permission": self.permission,
                  "provider": {"mock": {"npm": "@ai-sdk/openai-compatible", "name": "Mock",
                                        "options": {"baseURL": f"http://127.0.0.1:{API_PORT}/v1", "apiKey": "fictional-test-key"},
                                        "models": {"mock-model": {"name": "Mock", "tool_call": True, "limit": {"context": 100000, "output": 4096}}}}}}
        (self.cfg / "opencode" / "opencode.json").write_text(json.dumps(config))

    def environ(self):
        env = {
            "HOME": str(self.home), "XDG_CONFIG_HOME": str(self.cfg), "XDG_DATA_HOME": str(self.root / "data"),
            "XDG_STATE_HOME": str(self.root / "state"), "XDG_CACHE_HOME": str(self.root / "cache"),
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TERM": "xterm-256color", "LANG": "en_US.UTF-8", "USER": os.environ.get("USER", "apple"),
            "TMPDIR": str(self.root) + "/", "OPENCODE_DISABLE_AUTOUPDATE": "1", "OPENCODE_DISABLE_MODELS_FETCH": "1",
            "OPENCODE_DISABLE_LSP_DOWNLOAD": "1", "OPENCODE_DISABLE_CLAUDE_CODE": "1", "OPENCODE_DISABLE_EXTERNAL_SKILLS": "1",
            "OPENCODE_DISABLE_DEFAULT_PLUGINS": "1", "OPENCODE_MODELS_PATH": str(self.root / "models.json"),
            # The blocked npm registry otherwise stalls plugin loading for about a minute.
            "npm_config_registry": f"http://127.0.0.1:{API_PORT}/", "BUN_CONFIG_REGISTRY": f"http://127.0.0.1:{API_PORT}/",
            "AGENT_ISLAND_RUNTIME": RUNTIME, "AGENT_ISLAND_HOOK": str(HOOK),
            "PROBE_LOG": str(self.root / "probe.jsonl"),
        }
        env.update(self.extra_env)
        return env

    def start_broker(self):
        self.broker = BrokerProc(runtime=RUNTIME)

    def start(self):
        self.prepare()
        if self.want_broker:
            self.start_broker()
        if not self.serve:
            return
        for _ in range(3):
            self.proc = subprocess.Popen([OPENCODE, "serve", "--port", str(SERVER_PORT), "--hostname", "127.0.0.1"], cwd=self.work,
                                         env=self.environ(), stdout=open(self.root / "server.out", "wb"), stderr=open(self.root / "server.err", "wb"), start_new_session=True)
            if wait_until(self.ready, 15, 0.1):
                return
            self.kill()
        raise RuntimeError("opencode serve did not start")

    def ready(self):
        if self.proc.poll() is not None:
            return False
        try:
            return self.http("GET", "/session")[0] == 200
        except OSError:
            return False

    def http(self, method, path, body=None):
        data = None if body is None else json.dumps(body).encode()
        request = urllib.request.Request(f"http://127.0.0.1:{SERVER_PORT}{path}", data=data, method=method, headers={
            "Content-Type": "application/json", "x-opencode-directory": str(self.work)})
        try:
            with urllib.request.urlopen(request, timeout=15) as reply:
                text = reply.read()
                return reply.status, json.loads(text) if text else None
        except urllib.error.HTTPError as error:
            return error.code, None

    def session(self):
        return self.http("POST", "/session", {"title": "fictional"})[1]["id"]

    def prompt(self, sid, keyword):
        return self.http("POST", f"/session/{sid}/prompt_async", {"parts": [{"type": "text", "text": f"KW_{keyword} please"}]})

    def pending(self):
        return self.http("GET", "/permission")[1] or []

    def questions(self):
        return self.http("GET", "/question")[1] or []

    def marker(self, keyword):
        return (self.work / f"marker-{keyword}.txt").exists()

    def reply(self, request, value, message=None):
        body = {"reply": value}
        if message:
            body["message"] = message
        return self.http("POST", f"/permission/{request['id']}/reply", body)[0]

    def kill(self):
        if self.proc and self.proc.poll() is None:
            try:
                os.killpg(self.proc.pid, signal.SIGKILL)
            except (ProcessLookupError, PermissionError):
                pass
            self.proc.wait(5)
        self.proc = None

    def stop(self):
        if self.proc and self.proc.poll() is None:
            self.proc.send_signal(signal.SIGTERM)
            try:
                self.proc.wait(8)
            except subprocess.TimeoutExpired:
                pass
        self.kill()
        if self.broker:
            self.broker.stop(kill=True)
            self.broker = None


PROBE_PLUGIN = """
import { appendFileSync } from "node:fs";
const log = (o) => { try { appendFileSync(process.env.PROBE_LOG, JSON.stringify(o) + "\\n"); } catch {} };
export const Probe = async () => ({
  event: async ({ event }) => { log({ kind: "event", type: event.type }); },
  "permission.ask": async () => { log({ kind: "PERMISSION_ASK_HOOK" }); },
});
"""


class PTY:
    def __init__(self, env):
        self.master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 50, 150, 0, 0))
        self.proc = subprocess.Popen([OPENCODE], cwd=env.work, env=env.environ(), stdin=slave, stdout=slave, stderr=slave, start_new_session=True, close_fds=True)
        os.close(slave)
        self.buffer = bytearray()

    def pump(self, seconds=0.1):
        end = time.time() + seconds
        while time.time() <= end:
            ready, _, _ = select.select([self.master], [], [], max(0, end - time.time()))
            if ready:
                try:
                    data = os.read(self.master, 1 << 16)
                except OSError:
                    return
                if not data:
                    return
                self.buffer.extend(data)
                if b"\x1b[6n" in data:
                    os.write(self.master, b"\x1b[1;1R")
                if b"\x1b[c" in data:
                    os.write(self.master, b"\x1b[?62c")

    def text(self):
        return ANSI.sub(b"", bytes(self.buffer)).decode("utf-8", "replace")

    def wait_for(self, pattern, timeout=30):
        regex = re.compile(pattern)
        end = time.time() + timeout
        while time.time() < end:
            self.pump(0.15)
            if regex.search(self.text()):
                return True
        return bool(regex.search(self.text()))

    def send(self, data):
        os.write(self.master, data)

    def close(self):
        if self.proc.poll() is None:
            try:
                os.killpg(self.proc.pid, signal.SIGKILL)
            except (ProcessLookupError, PermissionError):
                pass
            self.proc.wait(5)
        os.close(self.master)


class Case:
    def __init__(self, env):
        self.env, self.checks, self.notes, self.seen = env, [], {}, set()

    def check(self, name, ok, detail=None):
        self.checks.append({"name": name, "ok": bool(ok), "detail": detail})

    @property
    def broker(self):
        return self.env.broker

    def event(self, kind, timeout=15, match=None):
        return self.broker.next(kind, timeout, self.seen, match)

    def request(self, timeout=20):
        return self.event("request", timeout)

    def lifecycle(self):
        self.broker.poll(0.05)
        return [e for e in self.broker.events if e["type"] == "lifecycle"]

    def names(self):
        return [e["name"] for e in self.lifecycle()]


def stays_pending(case, keyword, seconds=2.5):
    """Nothing may answer: the request stays pending and the tool has not run."""
    env = case.env
    first = wait_until(env.pending, 15)
    case.check("request reached OpenCode's prompt", first)
    time.sleep(seconds)
    case.check("still pending after the hook path failed", env.pending(), [p["permission"] for p in env.pending()])
    case.check("tool did not run", not env.marker(keyword))
    case.check("no tool result reached the model", not env.mock.results(keyword))
    return first[0] if first else None


def own_prompt_still_works(case, keyword, request):
    env = case.env
    case.check("OpenCode's own reply is accepted", request and env.reply(request, "once") == 200)
    case.check("tool runs after that reply", wait_until(lambda: env.marker(keyword), 10))


def case_allow(case):
    env = case.env
    sid = env.session()
    env.prompt(sid, "allow")
    request = case.request()
    case.check("card appears", request and request["source"] == "opencode", request and request["tool_name"])
    case.check("tool name is Bash", request and request["tool_name"] == "Bash")
    case.check("full command shown", request and "marker-allow" in request["tool_input"]["command"])
    case.check("not yet run", not env.marker("allow"))
    case.check("carries the call id", request and request.get("tool_use_id") == "call_allow", request and request.get("tool_use_id"))
    env.broker.decide(request["nonce"], "allow")
    case.check("delivered", case.event("delivered"))
    case.check("tool executed", wait_until(lambda: env.marker("allow"), 10))
    results = wait_until(lambda: env.mock.results("allow"), 10)
    case.check("model got success result", results and "fictional-output-allow" in results[0], results)
    case.check("confirmed by PostToolUse", case.event("confirmed"))
    case.check("request no longer pending", not env.pending())


def case_deny(case):
    env = case.env
    sid = env.session()
    env.prompt(sid, "deny")
    request = case.request()
    env.broker.decide(request["nonce"], "deny", message="fictional deny reason")
    results = wait_until(lambda: env.mock.results("deny"), 10)
    case.check("tool did not run", not env.marker("deny"))
    case.check("model got the rejection and the reason", results and "fictional deny reason" in results[0], results)
    case.check("confirmed via tool failure event", case.event("confirmed"))


def case_elsewhere(case, keyword, value):
    env = case.env
    sid = env.session()
    env.prompt(sid, keyword)
    request = case.request()
    pending = wait_until(env.pending, 5)
    case.check("OpenCode's own prompt coexists with the card", pending and request)
    case.check("hook is running", hook_processes())
    start = time.time()
    env.reply(pending[0], value)
    resolved = case.event("resolved", 5)
    case.check("card withdrawn after answer elsewhere", resolved, resolved and resolved.get("reason"))
    case.notes["withdraw_seconds"] = round(time.time() - start, 3)
    case.check("hook ended, no hook left", wait_until(lambda: not hook_processes(), 5))
    if value == "once":
        case.check("tool executed", wait_until(lambda: env.marker(keyword), 10))
    else:
        time.sleep(1.5)
        case.check("tool did not run", not env.marker(keyword))


def case_abort(case):
    env = case.env
    sid = env.session()
    env.prompt(sid, "abort")
    case.request()
    env.http("POST", f"/session/{sid}/abort")
    resolved = case.event("resolved", 8)
    case.check("card withdrawn on abort", resolved, resolved and resolved.get("reason"))
    case.check("hook ended", wait_until(lambda: not hook_processes(), 5))
    case.check("tool did not run", not env.marker("abort"))
    case.check("Stop after abort", wait_until(lambda: "Stop" in case.names(), 5), case.names())


def case_kill9(case):
    env = case.env
    sid = env.session()
    env.prompt(sid, "kill9")
    case.request()
    case.check("hook and watcher running", hook_processes() and watch_processes())
    os.killpg(env.proc.pid, signal.SIGKILL)
    env.proc.wait(5)
    resolved = case.event("resolved", 8)
    case.check("card withdrawn after SIGKILL", resolved, resolved and resolved.get("reason"))
    case.check("hook gone", wait_until(lambda: not hook_processes(), 5))
    case.check("SessionEnd from watcher", case.event("lifecycle", 8, lambda e: e["name"] == "SessionEnd"))
    case.check("watcher gone", wait_until(lambda: not watch_processes(), 8))
    case.check("tool did not run", not env.marker("kill9"))


def case_term(case):
    env = case.env
    sid = env.session()
    env.prompt(sid, "term")
    case.request()
    env.proc.send_signal(signal.SIGTERM)
    resolved = case.event("resolved", 10)
    case.check("card withdrawn on SIGTERM", resolved, resolved and resolved.get("reason"))
    case.check("SessionEnd", case.event("lifecycle", 8, lambda e: e["name"] == "SessionEnd"))
    case.check("no leftovers", wait_until(lambda: not hook_processes() and not watch_processes(), 8))
    case.check("tool did not run", not env.marker("term"))


def failure(keyword, needs_broker=True):
    def run(case):
        env = case.env
        sid = env.session()
        env.prompt(sid, keyword)
        request = stays_pending(case, keyword)
        own_prompt_still_works(case, keyword, request)
    run.__name__ = f"case_{keyword}"
    return run


def case_broker_death(case):
    env = case.env
    sid = env.session()
    env.prompt(sid, "fbrokerdeath")
    case.request()
    env.broker.stop(kill=True)
    env.broker = None
    request = stays_pending(case, "fbrokerdeath")
    case.check("hook exited on its own", wait_until(lambda: not hook_processes(), 5))
    own_prompt_still_works(case, "fbrokerdeath", request)


def case_parallel(case):
    env = case.env
    sid = env.session()
    env.prompt(sid, "parallel")
    first = case.request()
    second = case.event("request", 8)
    case.notes["cards"] = bool(first) + bool(second)
    if second is None:
        case.notes["serial"] = "OpenCode asked one at a time"
        env.broker.decide(first["nonce"], "allow")
        second = case.event("request", 10)
    case.check("both calls reach a card", first and second)
    env.broker.decide(second["nonce"], "deny", message="fictional parallel deny")
    case.check("denied call did not run on deny", wait_until(lambda: not env.pending(), 10))
    time.sleep(1)
    case.notes["markers"] = {"para": env.marker("para"), "parb": env.marker("parb")}


def case_question(case, keyword, multi=False):
    env = case.env
    sid = env.session()
    env.prompt(sid, keyword)
    request = case.request()
    case.check("question card", request and request["tool_name"] == "AskUserQuestion", request and request["tool_input"])
    pending = wait_until(env.questions, 5)
    case.check("OpenCode's own question is pending too", pending)
    question = request["tool_input"]["questions"][0]["question"]
    answer = "Small, Large" if multi else "Blue"
    env.broker.decide(request["nonce"], "answer", answers={question: answer})
    results = wait_until(lambda: env.mock.results(keyword), 10)
    case.check("model received the answer", results and all(v in results[0] for v in answer.split(", ")), results)
    case.check("question no longer pending", not env.questions())


def case_question_deny(case):
    env = case.env
    sid = env.session()
    env.prompt(sid, "qdeny")
    request = case.request()
    env.broker.decide(request["nonce"], "deny")
    case.check("question rejected", wait_until(lambda: not env.questions(), 8))
    case.check("turn ends", wait_until(lambda: "Stop" in case.names(), 10), case.names())
    # Measured: a dismissed question stops the turn, so the model is not called again.
    case.notes["model_called_after_dismiss"] = bool(env.mock.results("qdeny"))
    messages = env.http("GET", f"/session/{sid}/message")[1] or []
    parts = [p for m in messages for p in m.get("parts", []) if p.get("type") == "tool"]
    case.check("tool part records the dismissal", parts and parts[-1]["state"]["status"] == "error" and "dismissed" in parts[-1]["state"].get("error", ""), [p["state"].get("error") for p in parts])


def case_question_elsewhere(case):
    env = case.env
    sid = env.session()
    env.prompt(sid, "qelse")
    case.request()
    pending = wait_until(env.questions, 5)
    env.http("POST", f"/question/{pending[0]['id']}/reply", {"answers": [["Red"]]})
    case.check("card withdrawn", case.event("resolved", 5))
    case.check("hook ended", wait_until(lambda: not hook_processes(), 5))


def case_edit(case):
    env = case.env
    sid = env.session()
    env.prompt(sid, "edit")
    request = case.request()
    case.check("write shows as Write with file_path", request and request["tool_name"] == "Write" and request["tool_input"]["file_path"] == "marker-edit.txt", request and request["tool_name"])
    case.check("full content is in the input", request and "fictional content" in request["tool_input"]["content"])
    env.broker.decide(request["nonce"], "allow")
    case.check("file written", wait_until(lambda: env.marker("edit"), 10))
    case.check("confirmed", case.event("confirmed"))


def case_subagent(case):
    env = case.env
    sid = env.session()
    env.prompt(sid, "taskparent")
    request = case.request()
    case.check("child request carries parent session and agent id", request and request["session_id"] == sid and request["agent_id"] and request["agent_id"] != sid, request and [request["session_id"], request["agent_id"]])
    env.broker.decide(request["nonce"], "allow")
    case.check("child tool ran", wait_until(lambda: env.marker("child"), 15))
    names = wait_until(lambda: "SubagentStop" in case.names() and case.names(), 15)
    case.check("SubagentStart and SubagentStop", names and "SubagentStart" in names, names)


def case_status(case):
    env = case.env
    sid = env.session()
    env.prompt(sid, "status")
    request = case.request()
    case.check("SessionStart first, prompt, then tool start", wait_until(lambda: {"SessionStart", "UserPromptSubmit", "PreToolUse"} <= set(case.names()), 5), case.names())
    env.broker.decide(request["nonce"], "allow")
    wait_until(lambda: "Stop" in case.names(), 15)
    names = case.names()
    case.notes["sequence"] = names
    for earlier, later in (("SessionStart", "UserPromptSubmit"), ("UserPromptSubmit", "PreToolUse"), ("PreToolUse", "PostToolUse"), ("PostToolUse", "Stop")):
        case.check(f"{earlier} before {later}", earlier in names and later in names and names.index(earlier) < names.index(later))
    case.check("exactly one Stop", names.count("Stop") == 1, names.count("Stop"))
    case.check("all carry the session id and cwd", all(e["session_id"] == sid and e["cwd"] for e in case.lifecycle()))
    env.http("DELETE", f"/session/{sid}")
    case.check("SessionEnd on delete", case.event("lifecycle", 5, lambda e: e["name"] == "SessionEnd"))
    sid2 = env.session()
    env.prompt(sid2, "failtool")
    case.check("tool error is PostToolUseFailure", case.event("lifecycle", 10, lambda e: e["name"] == "PostToolUseFailure" and e["session_id"] == sid2))


class Failing(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        return

    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length") or 0))
        self.send_response(400)
        data = b'{"error":{"message":"fictional failure"}}'
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


def case_model_error(case):
    env = case.env
    env.mock.stop()
    http.server.ThreadingHTTPServer.allow_reuse_address = True
    server = http.server.ThreadingHTTPServer(("127.0.0.1", API_PORT), Failing)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        sid = env.session()
        env.prompt(sid, "status")
        failure_event = case.event("lifecycle", 15, lambda e: e["name"] == "StopFailure")
        case.check("model error is StopFailure", failure_event and failure_event["session_id"] == sid)
        time.sleep(1.5)
        case.check("no Stop after the failure", "Stop" not in case.names(), case.names())
    finally:
        server.shutdown()
        server.server_close()
        env.mock.start()


def case_config_allow(case):
    env = case.env
    sid = env.session()
    env.prompt(sid, "cfgallow")
    case.check("tool ran without asking", wait_until(lambda: env.marker("cfgallow"), 12))
    case.check("no card under permission=allow", not [e for e in env.broker.events if e["type"] == "request"])
    case.check("no pending request", not env.pending())


def case_config_ask(case):
    env = case.env
    sid = env.session()
    env.prompt(sid, "cfgask")
    request = case.request()
    case.check("OPENCODE_PERMISSION turns on asking for one launch", request and request["tool_name"] == "Bash")
    env.broker.decide(request["nonce"], "allow")
    case.check("tool ran", wait_until(lambda: env.marker("cfgask"), 10))
    log = [json.loads(l) for l in (env.root / "probe.jsonl").read_text().splitlines()]
    case.check("permission.asked event fired", any(o.get("type") == "permission.asked" for o in log))
    case.check("permission.ask plugin hook never fired", not any(o["kind"] == "PERMISSION_ASK_HOOK" for o in log))


def coex_plugins():
    paths = [REAL_PLUGINS / "plugins" / "vibe-island.js", REAL_PLUGINS / "plugins" / "push-notify.js", REAL_PLUGINS / "plugin" / "agent-hud.js"]
    return [p for p in paths if p.exists()]


def coexist_allow(case, keyword, original=None):
    env = case.env
    if original:
        original.start()
    sid = env.session()
    env.prompt(sid, keyword)
    request = case.request()
    if original:
        case.check("the original plugin also received the request", wait_until(lambda: any(f.get("_raw", {}).get("event", {}).get("type") == "permission.asked" for f in original.frames), 8))
    start = time.time()
    env.broker.decide(request["nonce"], "allow")
    case.check("tool ran without waiting for the other plugins", wait_until(lambda: env.marker(keyword), 8))
    case.notes["allow_to_run_seconds"] = round(time.time() - start, 3)
    case.check("no pending left", not env.pending())
    if original:
        case.check("original plugin's connection released", wait_until(lambda: original.closed, 8))


def coexist_deny(case, keyword, original):
    env = case.env
    original.start()
    sid = env.session()
    env.prompt(sid, keyword)
    request = case.request()
    wait_until(lambda: original.frames, 8)
    env.broker.decide(request["nonce"], "deny", message="fictional coexist deny")
    results = wait_until(lambda: env.mock.results(keyword), 8)
    case.check("deny took effect immediately", results and "fictional coexist deny" in results[0], results)
    case.check("tool did not run", not env.marker(keyword))
    case.check("original plugin's connection released", wait_until(lambda: original.closed, 8))


def coexist_first(case, keyword, original):
    env = case.env
    original.start()
    sid = env.session()
    env.prompt(sid, keyword)
    case.check("our card appears before the original answers", case.request())
    resolved = case.event("resolved", 10)
    case.check("our card is withdrawn when the original answers first", resolved, resolved and resolved.get("reason"))
    case.check("the first answer (allow) took effect", wait_until(lambda: env.marker(keyword), 8))
    case.check("hook ended", wait_until(lambda: not hook_processes(), 5))


def coexist_instant(case, keyword, original):
    env = case.env
    original.start()
    sid = env.session()
    env.prompt(sid, keyword)
    case.check("the first answer took effect", wait_until(lambda: env.marker(keyword), 10))
    case.check("no hook left", wait_until(lambda: not hook_processes(), 5))
    time.sleep(0.5)
    env.broker.poll(0.05)
    requests = [e["nonce"] for e in env.broker.events if e["type"] == "request"]
    ended = [e["nonce"] for e in env.broker.events if e["type"] == "resolved"]
    case.notes["cards_seen"] = len(requests)
    case.check("no card is left showing", set(requests) <= set(ended), {"requests": len(requests), "ended": len(ended)})


def case_run_mode(case):
    env = case.env
    result = subprocess.run([OPENCODE, "run", "KW_runmode please"], cwd=env.work, env=env.environ(), stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=40)
    case.notes["exit_code"] = result.returncode
    case.check("opencode run exits", True)
    case.check("no tool ran", not env.marker("runmode"))
    case.check("no watcher or hook left behind", wait_until(lambda: not hook_processes() and not watch_processes(), 8))


def tui_start(case):
    env = case.env
    terminal = PTY(env)
    case.terminal = terminal
    ready = terminal.wait_for(r"Ask anything|ctrl\+p|/help", 30)
    case.check("TUI started", ready, terminal.text()[-300:] if not ready else None)
    return terminal


def tui_prompt(case, terminal, keyword):
    terminal.send(f"KW_{keyword} please".encode())
    terminal.pump(0.8)
    terminal.send(b"\r")
    request = None
    end = time.time() + 25
    while not request and time.time() < end:
        terminal.pump(0.15)
        case.broker.poll(0.02)
        request = next((e for i, e in enumerate(case.broker.events) if e["type"] == "request" and i not in case.seen), None)
    if request:
        case.seen.add(case.broker.events.index(request))
    case.check("card appears from the TUI", request, terminal.text()[-300:] if not request else None)
    found = terminal.wait_for(r"Permission required|Allow once|△", 10)
    case.check("TUI shows its own permission prompt", found)
    return request


def case_tui_allow(case):
    terminal = tui_start(case)
    env = case.env
    request = tui_prompt(case, terminal, "tuiallow")
    env.broker.decide(request["nonce"], "allow")
    done = False
    end = time.time() + 12
    while time.time() < end and not done:
        terminal.pump(0.2)
        done = env.marker("tuiallow")
    case.check("tool ran after island decision in TUI mode", done)


def case_tui_key(case):
    terminal = tui_start(case)
    env = case.env
    tui_prompt(case, terminal, "tuikey")
    terminal.pump(0.5)
    terminal.send(b"\r")  # Allow once is the default choice.
    end = time.time() + 12
    done = False
    while time.time() < end and not done:
        terminal.pump(0.2)
        done = env.marker("tuikey")
    case.check("tool ran after TUI key", done)
    resolved = None
    end = time.time() + 6
    while time.time() < end and not resolved:
        terminal.pump(0.1)
        case.broker.poll(0.02)
        resolved = next((e for e in case.broker.events if e["type"] == "resolved"), None)
    case.check("card withdrawn after the TUI answered", resolved, resolved and resolved.get("reason"))
    case.check("hook ended", wait_until(lambda: not hook_processes(), 5))


def case_tui_esc(case):
    terminal = tui_start(case)
    env = case.env
    tui_prompt(case, terminal, "tuiesc")
    terminal.pump(0.5)
    terminal.send(b"\x1b")  # Esc rejects at once.
    resolved = None
    end = time.time() + 6
    while time.time() < end and not resolved:
        terminal.pump(0.1)
        case.broker.poll(0.02)
        resolved = next((e for e in case.broker.events if e["type"] == "resolved"), None)
    case.check("card withdrawn after TUI rejected", resolved, resolved and resolved.get("reason"))
    case.check("tool did not run", not env.marker("tuiesc"))


def case_tui_hangup(case):
    terminal = tui_start(case)
    env = case.env
    tui_prompt(case, terminal, "tuihup")
    os.killpg(terminal.proc.pid, signal.SIGHUP)
    resolved = ended = None
    end = time.time() + 10
    while time.time() < end and not (resolved and ended):
        terminal.pump(0.1)
        case.broker.poll(0.02)
        resolved = resolved or next((e for e in case.broker.events if e["type"] == "resolved"), None)
        ended = ended or next((e for e in case.broker.events if e["type"] == "lifecycle" and e["name"] == "SessionEnd"), None)
    case.check("card withdrawn when the terminal closes", resolved, resolved and resolved.get("reason"))
    case.check("SessionEnd when the terminal closes", ended)
    case.check("no hook left", wait_until(lambda: not hook_processes(), 8))
    # OpenCode 1.18.31 itself outlives SIGHUP here, with a no-op plugin as well (measured), and the
    # watcher correctly waits for that process. The kill9 case covers the watcher going with it.
    case.notes["watcher_alive_after_hangup"] = bool(watch_processes())
    case.check("tool did not run", not env.marker("tuihup"))


def case_config_allow_question(case):
    env = case.env
    sid = env.session()
    env.prompt(sid, "qcfg")
    request = case.request()
    case.check("question still reaches the island under permission=allow", request and request["tool_name"] == "AskUserQuestion")
    env.broker.decide(request["nonce"], "answer", answers={request["tool_input"]["questions"][0]["question"]: "Red"})
    results = wait_until(lambda: env.mock.results("qcfg"), 10)
    case.check("answer delivered", results and "Red" in results[0], results)


def make_fake_hooks(directory):
    bodies = {
        "crash": 'raise RuntimeError("fictional crash")',
        "empty": "",
        "garbage": 'print("not json at all")',
        "wrong": 'import json;print(json.dumps({"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"maybe"}}}))',
        "event": 'import json;print(json.dumps({"hookSpecificOutput":{"hookEventName":"PreToolUse","decision":{"behavior":"allow"}}}))',
        "exit2": 'import json,sys;print(json.dumps({"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}));sys.exit(2)',
        "hang": "import time;time.sleep(3600)",
    }
    paths = {}
    for name, body in bodies.items():
        path = directory / f"hook_{name}.py"
        path.write_text(body + "\n")
        paths[name] = str(path)
    return paths


def plugin_with_throw():
    return (ADAPTER / "agent-island.js").read_text().replace("function handle(event) {", 'function handle(event) {\n    throw new Error("fictional injected failure");', 1)


def init_throw():
    return (ADAPTER / "agent-island.js").read_text().replace("export const AgentIslandAdapter = async ({ client, directory }) => {", 'export const AgentIslandAdapter = async ({ client, directory }) => {\n  throw new Error("fictional init failure");', 1)


def build_cases(hooks):
    c = {}
    def add(name, fn, **kw):
        c[name] = (fn, kw)
    add("allow", case_allow)
    add("deny", case_deny)
    add("edit", case_edit)
    add("elsewhere_allow", lambda k: case_elsewhere(k, "elsewhereok", "once"))
    add("elsewhere_reject", lambda k: case_elsewhere(k, "elsewhereno", "reject"))
    add("abort", case_abort)
    add("kill9", case_kill9)
    add("sigterm", case_term)
    for name, key, hook in (("hook_crash", "fcrash", "crash"), ("hook_empty", "fempty", "empty"), ("hook_garbage", "fgarbage", "garbage"),
                            ("hook_wrong_behavior", "fwrong", "wrong"), ("hook_wrong_event", "fevent", "event"), ("hook_exit2_allow", "fexit2", "exit2"), ("hook_hang", "fhang", "hang")):
        add(name, failure(key), env={"AGENT_ISLAND_HOOK": hooks[hook]})
    add("no_broker", failure("fnobroker"), broker=False)
    add("python_missing", failure("fpython"), env={"AGENT_ISLAND_PYTHON": "/nonexistent/python3"})
    add("broker_death", case_broker_death)
    add("plugin_event_throws", failure("fthrow"), plugin_text=plugin_with_throw())
    add("plugin_init_throws", failure("finitthrow"), plugin_text=init_throw())
    add("plugin_syntax_error", failure("fsyntax"), plugin_text="this is not valid javascript (")
    add("parallel", case_parallel)
    add("subagent", case_subagent)
    add("question_answer", lambda k: case_question(k, "qanswer"))
    add("question_multi", lambda k: case_question(k, "qmulti", True))
    add("question_deny", case_question_deny)
    add("question_elsewhere", case_question_elsewhere)
    add("status", case_status)
    add("model_error", case_model_error)
    add("config_allow", case_config_allow, permission="allow")
    add("config_allow_question", case_config_allow_question, permission="allow")
    add("config_one_launch_ask", case_config_ask, permission="allow", probe=True,
        env={"OPENCODE_PERMISSION": json.dumps(ASK_ALL)})
    extra = tuple(coex_plugins())
    add("coexist_original_not_running", lambda k: coexist_allow(k, "coexno"), extra_plugins=extra, home=SOCKET_HOME)
    socket_path = SOCKET_HOME / ".vibe-island" / "run" / "vibe-island.sock"
    add("coexist_original_holds", lambda k: coexist_allow(k, "coexhold", FakeOriginal(socket_path)), extra_plugins=extra, home=SOCKET_HOME)
    add("coexist_island_deny", lambda k: coexist_deny(k, "coexdeny", FakeOriginal(socket_path)), extra_plugins=extra, home=SOCKET_HOME)
    add("coexist_original_first", lambda k: coexist_first(k, "coexfirst", FakeOriginal(socket_path, {"reply": "once"}, delay=1.0)), extra_plugins=extra, home=SOCKET_HOME)
    add("coexist_original_instant", lambda k: coexist_instant(k, "coexfast", FakeOriginal(socket_path, {"reply": "once"})), extra_plugins=extra, home=SOCKET_HOME)
    add("run_mode", case_run_mode, serve=False)
    add("tui_allow", case_tui_allow)
    add("tui_key", case_tui_key)
    add("tui_esc", case_tui_esc)
    add("tui_hangup", case_tui_hangup)
    return c


def cleanup_runtime():
    shutil.rmtree(RUNTIME, ignore_errors=True)
    shutil.rmtree(SOCKET_HOME, ignore_errors=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--only")
    parser.add_argument("--out")
    args = parser.parse_args()
    root = pathlib.Path(tempfile.mkdtemp(prefix="island-opencode-", dir=os.environ.get("TMPDIR")))
    hooks = make_fake_hooks(root)
    cases = build_cases(hooks)
    names = args.only.split(",") if args.only else list(cases)
    mock = Mock(root)
    mock.start()
    report = {"opencode": subprocess.run([OPENCODE, "--version"], capture_output=True, text=True).stdout.strip(), "cases": {}}
    failed = 0
    try:
        for name in names:
            fn, kw = cases[name]
            cleanup_runtime()
            env = Env(root / "e" / name, mock, **kw)
            case = Case(env)
            case.terminal = None
            started = time.time()
            error = None
            try:
                env.start()
                fn(case)
            except Exception as exc:  # A scenario that blows up counts as failed, keeps the run going.
                error = f"{type(exc).__name__}: {exc}"
            finally:
                if case.terminal:
                    case.terminal.close()
                env.stop()
            good = error is None and all(c["ok"] for c in case.checks)
            failed += not good
            report["cases"][name] = {"ok": good, "error": error, "seconds": round(time.time() - started, 1), "checks": case.checks, "notes": case.notes}
            print(("PASS" if good else "FAIL"), name, round(time.time() - started, 1), flush=True)
            if not good:
                print(json.dumps({"error": error, "bad": [c for c in case.checks if not c["ok"]]}, ensure_ascii=False)[:900], flush=True)
    finally:
        mock.stop()
        cleanup_runtime()
    report["passed"] = len(names) - failed
    report["failed"] = failed
    if args.out:
        pathlib.Path(args.out).write_text(json.dumps(report, ensure_ascii=False, indent=1))
    print(f"{report['passed']}/{len(names)} passed", flush=True)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
