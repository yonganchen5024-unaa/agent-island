#!/usr/bin/env python3
"""End-to-end Codex approval tests: REAL Codex CLI binary, real hook and broker, fake model.

Real: the Codex 0.167 binary in app-server mode (what the desktop app runs), its TUI on a pty, and
`codex exec`; scripts/claude_approval_hook.py and claude_approval_broker.py.
Fake: the model (a local Responses API on 127.0.0.1:17455, mock_codex_responses.py) and all data.
Isolated: HOME and CODEX_HOME are throwaway directories; the environment is built from scratch.

Findings and how to read this file: docs/reference/agent-codex.md. Everything is fictional.

Run: TMPDIR=<dir>/ /usr/bin/python3 -I Tests/e2e/run_codex_approval.py [--only NAME] [--out FILE]
"""
import argparse
import fcntl
import json
import os
import pathlib
import pty
import re
import shlex
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import threading
import time

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parent.parent
sys.path.insert(0, str(HERE))
import run_real_cli_approval as rcli  # noqa: E402
from isolated_cli import TTY, pid_alive  # noqa: E402

CODEX = "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
PORT = 17455
HOOK = ROOT / "scripts" / "claude_approval_hook.py"
RUNTIME = "/private/tmp/cc-socks/island-codex-test"
DENY_TEXT = "FICTIONAL_DENY_REASON"

ESC = {"cmd": "echo fictional > marker.txt", "sandbox_permissions": "require_escalated", "justification": "fictional reason"}
ESC_DONE = [[{"call": "exec_command", "args": ESC, "id": "call_fictional"}], [{"text": "finished-turn"}]]
RM_NOTHING = {"cmd": "rm -rf ./fictional-nothing; echo fictional > marker.txt"}
SCENARIOS = {
    "KW_ESC": ESC_DONE,
    "KW_PLAIN": [[{"call": "exec_command", "args": {"cmd": "echo fictional > marker.txt"}}], [{"text": "finished-turn"}]],
    "KW_RMRF": [[{"call": "exec_command", "args": RM_NOTHING}], [{"text": "finished-turn"}]],
    "KW_RMPLAIN": [[{"call": "exec_command", "args": {"cmd": "rm ./fictional-nothing; echo fictional > marker.txt"}}], [{"text": "finished-turn"}]],
    "KW_ASK": [[{"call": "request_user_input", "args": {"questions": [{"id": "q1", "header": "Pick", "question": "Fictional?",
                                                                     "options": [{"label": "One", "description": "a"}, {"label": "Two", "description": "b"}]}]}}],
               [{"text": "finished-turn"}]],
    "KW_MCP_WRITE": [[{"call": "fictional_write", "namespace": "mcp__fictional", "args": {"value": "fictional"}}], [{"text": "finished-turn"}]],
    "KW_MCP_READ": [[{"call": "fictional_read", "namespace": "mcp__fictional", "args": {}}], [{"text": "finished-turn"}]],
    "KW_SUB": [[{"call": "spawn_agent", "namespace": "multi_agent_v1", "args": {"message": "KW_CHILD do"}}], [{"text": "finished-turn"}]],
    "KW_CHILD": [[{"call": "exec_command", "args": {"cmd": "echo child > child.txt", "sandbox_permissions": "require_escalated", "justification": "child reason"}}], [{"text": "child-done"}]],
    "KW_PATCH": [[{"call": "exec_command", "args": {"cmd": "apply_patch <<'EOF'\n*** Begin Patch\n*** Add File: ../fictional-outside.txt\n+fictional\n*** End Patch\nEOF"}}], [{"text": "finished-turn"}]],
}

PROBE_HOOK = r'''#!/usr/bin/python3 -I
import json,os,signal,sys,time
name,mode,log=sys.argv[1:4]
def rec(**k):
    with open(log,'a') as out: out.write(json.dumps({'name':name,'t':time.time(),'pid':os.getpid(),**k})+'\n')
def bye(sig,_): rec(ev='signal',sig=sig); os._exit(0)
signal.signal(signal.SIGTERM,bye); signal.signal(signal.SIGHUP,bye)
raw=sys.stdin.read()
try: data=json.loads(raw)
except ValueError: data={'raw':raw[:200]}
rec(ev='start',ppid=os.getppid(),payload=data)
for part in mode.split('+'):
    if part.startswith('sleep:'): time.sleep(float(part[6:]))
    elif part in ('allow','deny'):
        decision={'behavior':part}
        if part=='deny': decision['message']='FICTIONAL_SIBLING_DENY_'+name
        print(json.dumps({'hookSpecificOutput':{'hookEventName':'PermissionRequest','decision':decision}}),flush=True)
    elif part=='allow_updated':
        print(json.dumps({'hookSpecificOutput':{'hookEventName':'PermissionRequest','decision':{'behavior':'allow','updatedInput':{'command':'echo substituted'}}}}),flush=True)
    elif part=='garbage': print('{not json',flush=True)
    elif part=='crash': rec(ev='crash'); os._exit(1)
    elif part=='exit78': rec(ev='crash'); os._exit(78)
    elif part=='exit2': sys.stderr.write('FICTIONAL_EXIT2_REASON\n'); rec(ev='exit2'); os._exit(2)
rec(ev='end')
'''

MINI_MCP = r'''#!/usr/bin/python3 -I
import json,sys
for line in sys.stdin:
    try: m=json.loads(line)
    except ValueError: continue
    i=m.get('id'); me=m.get('method')
    if me=='initialize': r={'protocolVersion':m['params'].get('protocolVersion','2025-06-18'),'capabilities':{'tools':{}},'serverInfo':{'name':'fictional','version':'0'}}
    elif me=='tools/list': r={'tools':[{'name':'fictional_write','description':'fictional destructive tool','inputSchema':{'type':'object','properties':{'value':{'type':'string'}}},'annotations':{'destructiveHint':True,'readOnlyHint':False}},{'name':'fictional_read','description':'fictional read tool','inputSchema':{'type':'object','properties':{}},'annotations':{'readOnlyHint':True}}]}
    elif me=='tools/call': r={'content':[{'type':'text','text':'fictional-mcp-result'}]}
    elif i is None: continue
    else: r={}
    sys.stdout.write(json.dumps({'jsonrpc':'2.0','id':i,'result':r})+'\n'); sys.stdout.flush()
'''


def serve_mock(argv):
    """Fake Responses API with namespaced tool calls, which MCP and multi-agent tools need."""
    import mock_codex_responses as mock
    original = mock.build_items

    def build_items(step):
        items = original(step)
        for entry, item in zip(step, items):
            if "namespace" in entry:
                item["namespace"] = entry["namespace"]
        return items
    mock.build_items = build_items
    sys.argv = ["mock"] + argv
    mock.main()


class AppServer:
    def __init__(self, env, extra=()):
        self.proc = subprocess.Popen([CODEX, *extra, "app-server"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=open(env.root / "as.stderr", "ab"), cwd=env.work, env=env.child_env())
        self.messages, self.lock, self.next_id = [], threading.Lock(), 0
        threading.Thread(target=self._read, daemon=True).start()
        self.call("initialize", {"clientInfo": {"name": "island_test", "title": "t", "version": "0"}, "capabilities": {"experimentalApi": True}})
        self._send({"method": "initialized"})

    def _read(self):
        for line in self.proc.stdout:
            try:
                value = json.loads(line)
            except ValueError:
                continue
            with self.lock:
                self.messages.append(value)

    def _send(self, value):
        self.proc.stdin.write((json.dumps(value) + "\n").encode())
        self.proc.stdin.flush()

    def snapshot(self):
        with self.lock:
            return list(self.messages)

    def call(self, method, params, timeout=30):
        self.next_id += 1
        ident = f"req-{self.next_id}"
        self._send({"id": ident, "method": method, "params": params})
        end = time.time() + timeout
        while time.time() < end:
            for item in self.snapshot():
                if item.get("id") == ident and "method" not in item:
                    if "error" in item:
                        raise RuntimeError(f"{method}: {item['error']}")
                    return item["result"]
            time.sleep(0.02)
        raise TimeoutError(method)

    def wait(self, predicate, timeout=20):
        end = time.time() + timeout
        while time.time() < end:
            for item in self.snapshot():
                if predicate(item):
                    return item
            time.sleep(0.03)
        return None

    def respond(self, message, result):
        self._send({"id": message["id"], "result": result})

    def requests(self):
        return [m for m in self.snapshot() if "method" in m and "id" in m]

    def close(self):
        if self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(8)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait()


class CodexEnv:
    def __init__(self, root, config=""):
        self.root = pathlib.Path(root)
        shutil.rmtree(self.root, ignore_errors=True)
        self.home = self.root / "home"
        self.codex_home = self.home / ".codex"
        self.work = self.root / "work"
        self.codex_home.mkdir(parents=True)
        self.work.mkdir(parents=True)
        (self.root / "probe.py").write_text(PROBE_HOOK)
        (self.root / "mcp.py").write_text(MINI_MCP)
        (self.root / "scenarios.json").write_text(json.dumps(SCENARIOS))
        self.hook_log = self.root / "hook.jsonl"
        self.api_log = self.root / "api.jsonl"
        real = os.path.realpath(self.work)
        (self.codex_home / "config.toml").write_text(
            'model_provider = "mock"\nmodel = "mock-model"\n' + config + f'''
[model_providers.mock]
name = "mock"
base_url = "http://127.0.0.1:{PORT}/v1"
wire_api = "responses"

[projects."{self.work}"]
trust_level = "trusted"

[projects."{real}"]
trust_level = "trusted"
''')
        self.server = subprocess.Popen([sys.executable, "-I", __file__, "--serve-mock", "--port", str(PORT),
                                        "--scenarios", str(self.root / "scenarios.json"), "--log", str(self.api_log)],
                                       stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        assert self.server.stdout.readline().strip() == b"ready"

    def child_env(self):
        return {"HOME": str(self.home), "CODEX_HOME": str(self.codex_home), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "LANG": "en_US.UTF-8", "USER": os.environ.get("USER", "apple"), "TERM": "xterm-256color",
                "TMPDIR": str(self.root) + "/", "COLUMNS": "160", "LINES": "50", "NO_PROXY": "127.0.0.1,localhost"}

    def stop(self):
        if self.server.poll() is None:
            self.server.terminate()
            self.server.wait(5)
        self.server.stdout.close()

    def probe(self, name, mode):
        return f"/usr/bin/python3 -I {shlex.quote(str(self.root / 'probe.py'))} {name} {mode} {shlex.quote(str(self.hook_log))}"

    @staticmethod
    def real_hook(timeout=3590):
        return f"/usr/bin/python3 -I {shlex.quote(str(HOOK))} --runtime {RUNTIME} --source codex --timeout {timeout}"

    def write_hooks(self, hooks):
        (self.codex_home / "hooks.json").write_text(json.dumps({"hooks": hooks}, indent=1))

    def trust_all(self, server=None):
        own = server is None
        server = server or AppServer(self)
        listing = server.call("hooks/list", {"cwds": [str(self.work)]})
        state = {h["key"]: {"trusted_hash": h["currentHash"]} for entry in listing["data"] for h in entry["hooks"]}
        result = server.call("config/batchWrite", {"edits": [{"keyPath": "hooks.state", "value": state, "mergeStrategy": "upsert"}], "reloadUserConfig": True})
        if own:
            server.close()
        return result

    def statuses(self, server=None):
        own = server is None
        server = server or AppServer(self)
        listing = server.call("hooks/list", {"cwds": [str(self.work)]})
        if own:
            server.close()
        return {h["key"].rsplit("/", 1)[-1]: h["trustStatus"] for entry in listing["data"] for h in entry["hooks"]}

    def hook_events(self):
        return [json.loads(l) for l in self.hook_log.read_text().splitlines()] if self.hook_log.exists() else []

    def outputs(self):
        records = [json.loads(l) for l in self.api_log.read_text().splitlines()] if self.api_log.exists() else []
        return [o for record in records for o in (record.get("outputs") or [])]

    def marker(self, name="marker.txt"):
        return (self.work / name).exists()


class CodexTTY(TTY):
    def __init__(self, env, extra=()):  # noqa: D107 - deliberately not calling TTY.__init__, which launches Claude
        self.master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 50, 160, 0, 0))
        self.proc = subprocess.Popen([CODEX, "--no-alt-screen", "--no-daemon", *extra], cwd=env.work, env=env.child_env(),
                                     stdin=slave, stdout=slave, stderr=slave, start_new_session=True, close_fds=True)
        os.close(slave)
        self.buffer, self.mark = bytearray(), 0


def hook_entry(command, timeout=3600):
    return {"hooks": [{"type": "command", "command": command, "timeout": timeout}]}


def done(message):
    return message.get("method") == "turn/completed"


def wait_turn(server, timeout=15):
    return server.wait(done, timeout)


def is_approval(message):
    return "id" in message and "method" in message and message["method"].startswith("item/") and "requestApproval" in message["method"]


def approvals(server):
    return [m for m in server.requests() if is_approval(m)]


def start_thread(env, server, policy="on-request", sandbox="workspace-write", params=None):
    body = {"cwd": str(env.work), **({"approvalPolicy": policy} if policy else {}), **({"sandbox": sandbox} if sandbox else {}), **(params or {})}
    return server.call("thread/start", body)["thread"]["id"]


def run_turn(server, thread, keyword="KW_ESC go", extra=None):
    return server.call("turn/start", {"threadId": thread, "input": [{"type": "text", "text": keyword}], **(extra or {})})["turn"]["id"]


def setup(env, permission_hooks, extra_hooks=None, policy="on-request", sandbox="workspace-write", keyword="KW_ESC go", broker=True, params=None, turn_extra=None):
    env.write_hooks({"PermissionRequest": permission_hooks, **(extra_hooks or {})})
    env.trust_all()
    b = rcli.BrokerProc(runtime=RUNTIME) if broker else None
    server = AppServer(env)
    thread = start_thread(env, server, policy=policy, sandbox=sandbox, params=params)
    turn = run_turn(server, thread, keyword, turn_extra)
    return b, server, thread, turn


# ---- Cases: each records checks on the Case. Each case gets a fresh isolated environment. ----

def case_allow(env, case):
    broker, server, thread, _ = setup(env, [hook_entry(env.real_hook())])
    try:
        request = broker.next("request")
        case.check("card shows complete input incl. justification", request and request["tool_input"] == {"command": ESC["cmd"], "description": ESC["justification"]}, request)
        case.check("source is codex", request and request["source"] == "codex")
        case.check("session_id equals thread id", request and request["session_id"] == thread, thread)
        time.sleep(1)
        case.check("tool has not run before the decision", not env.marker())
        case.check("no native approval while the hook waits", not approvals(server), approvals(server))
        broker.decide(request["nonce"], "allow")
        case.check("delivered", broker.next("delivered", 10) is not None)
        case.check("turn finished", wait_turn(server) is not None)
        case.check("tool really ran", env.marker())
        out = env.outputs()
        case.check("model received success", out and "Process exited with code 0" in out[-1]["output"], out)
        case.check("no native approval at all", not approvals(server), approvals(server))
    finally:
        server.close()
        broker.stop()


def case_deny(env, case):
    broker, server, _, _ = setup(env, [hook_entry(env.real_hook())])
    try:
        request = broker.next("request")
        broker.decide(request["nonce"], "deny", message=DENY_TEXT)
        wait_turn(server)
        case.check("tool did not run", not env.marker())
        out = env.outputs()
        case.check("model received the denial reason", out and DENY_TEXT in out[-1]["output"], out)
        case.check("no native approval", not approvals(server))
    finally:
        server.close()
        broker.stop()


def case_release_to_native(env, case):
    broker, server, _, _ = setup(env, [hook_entry(env.real_hook())])
    try:
        request = broker.next("request")
        case.check("no native approval yet", not approvals(server))
        broker.proc.stdin.write((json.dumps({"op": "release", "nonce": request["nonce"]}) + "\n").encode())
        broker.proc.stdin.flush()
        resolved = broker.next("resolved", 10)
        case.check("released", resolved and resolved["reason"] == "released", resolved)
        approval = server.wait(is_approval, 10)
        case.check("native approval appears only after release", approval is not None)
        case.check("tool not yet run", not env.marker())
        server.respond(approval, {"decision": "accept"})
        wait_turn(server)
        case.check("native accept ran the tool", env.marker())
    finally:
        server.close()
        broker.stop()


def case_tui_allow(env, case):
    env.write_hooks({"PermissionRequest": [hook_entry(env.real_hook())]})
    env.trust_all()
    broker = rcli.BrokerProc(runtime=RUNTIME)
    tty = CodexTTY(env, ("-c", 'approval_policy="on-request"', "-c", 'sandbox_mode="workspace-write"'))
    rcli.ACTIVE_TTY[:] = [tty]
    try:
        case.check("tui ready", tty.wait_for(r"Ask Codex to do anything", 25))
        tty.pump(0.5)
        tty.set_mark()
        tty.submit("KW_ESC go")
        request = broker.next("request", 15)
        case.check("request reaches island", request is not None)
        tty.pump(1.5)
        screen = tty.text()
        case.check("TUI shows hook running, no native prompt", "Running hook" in screen and "Would you like" not in screen, screen[-300:])
        broker.decide(request["nonce"], "allow")
        case.check("tool ran", _wait_marker(env, tty))
        case.check("native prompt never shown", "Would you like" not in tty.text())
    finally:
        rcli.ACTIVE_TTY.clear()
        tty.close()
        broker.stop()


def _wait_marker(env, tty, timeout=10):
    end = time.time() + timeout
    while time.time() < end:
        tty.pump(0.1)
        if env.marker():
            return True
    return False


def case_tui_release_native_yes(env, case):
    env.write_hooks({"PermissionRequest": [hook_entry(env.real_hook())]})
    env.trust_all()
    broker = rcli.BrokerProc(runtime=RUNTIME)
    tty = CodexTTY(env, ("-c", 'approval_policy="on-request"', "-c", 'sandbox_mode="workspace-write"'))
    rcli.ACTIVE_TTY[:] = [tty]
    try:
        tty.wait_for(r"Ask Codex to do anything", 25)
        tty.pump(0.5)
        tty.set_mark()
        tty.submit("KW_ESC go")
        request = broker.next("request", 15)
        broker.proc.stdin.write((json.dumps({"op": "release", "nonce": request["nonce"]}) + "\n").encode())
        broker.proc.stdin.flush()
        case.check("native prompt appears after hook ends", tty.wait_for(r"Would you like", 10))
        tty.send(b"y")
        case.check("native yes runs tool", _wait_marker(env, tty, 8))
        late = broker.next("rejected", 1)
        case.check("no stray rejection", late is None)
    finally:
        rcli.ACTIVE_TTY.clear()
        tty.close()
        broker.stop()


def case_tui_esc_cancels(env, case):
    env.write_hooks({"PermissionRequest": [hook_entry(env.real_hook())]})
    env.trust_all()
    broker = rcli.BrokerProc(runtime=RUNTIME)
    tty = CodexTTY(env, ("-c", 'approval_policy="on-request"', "-c", 'sandbox_mode="workspace-write"'))
    rcli.ACTIVE_TTY[:] = [tty]
    try:
        tty.wait_for(r"Ask Codex to do anything", 25)
        tty.pump(0.5)
        tty.set_mark()
        tty.submit("KW_ESC go")
        case.check("request reaches island", broker.next("request", 15) is not None)
        tty.pump(0.8)
        tty.send(b"\x1b")
        resolved = broker.next("resolved", 8)
        case.check("Esc withdraws the card", resolved and resolved["reason"] == "hook-gone", resolved)
        case.check("tool did not run", not env.marker())
    finally:
        rcli.ACTIVE_TTY.clear()
        tty.close()
        broker.stop()


def _failure(env, case, mode, expect_native=True):
    env.write_hooks({"PermissionRequest": [hook_entry(env.probe("H", mode))]})
    env.trust_all()
    server = AppServer(env)
    thread = start_thread(env, server)
    run_turn(server, thread)
    try:
        approval = server.wait(lambda m: is_approval(m) or done(m), 12)
        if expect_native:
            case.check(f"{mode}: falls back to the native approval", approval and is_approval(approval), approval and approval.get("method"))
            if approval and is_approval(approval):
                server.respond(approval, {"decision": "decline"})
                wait_turn(server)
        case.check(f"{mode}: tool did not run", not env.marker())
        return approval
    finally:
        server.close()


def case_failure_crash(env, case): _failure(env, case, "crash")
def case_failure_exit78(env, case): _failure(env, case, "exit78")  # what the original bridge's launcher exits with when its app is gone
def case_failure_empty(env, case): _failure(env, case, "empty")
def case_failure_garbage(env, case): _failure(env, case, "garbage")


def case_failure_updated_input(env, case):
    # Codex documents no input rewrite; the substituted command must never run.
    _failure(env, case, "allow_updated")
    case.check("substituted command never ran", not any("substituted" in (o.get("output") or "") for o in env.outputs()))


def case_failure_exit2_is_deny(env, case):
    approval = _failure(env, case, "exit2", expect_native=False)
    case.check("exit 2 is a denial, no native prompt", approval and done(approval), approval and approval.get("method"))
    case.check("stderr reaches the model as the reason", any("FICTIONAL_EXIT2_REASON" in o["output"] for o in env.outputs()), env.outputs())


def case_failure_hook_timeout(env, case):
    broker, server, _, _ = setup(env, [hook_entry(env.real_hook(timeout=2))])
    try:
        broker.next("request")
        resolved = broker.next("resolved", 10)
        case.check("hook gives up, card withdrawn", resolved and resolved["reason"] == "hook-gone", resolved)
        approval = server.wait(is_approval, 8)
        case.check("then native approval", approval is not None)
        case.check("no decision on timeout", not env.marker())
    finally:
        server.close()
        broker.stop()


def case_failure_codex_timeout(env, case):
    broker, server, _, _ = setup(env, [hook_entry(env.real_hook(), timeout=3)])
    try:
        case.check("card appears", broker.next("request") is not None)
        resolved = broker.next("resolved", 10)
        case.check("Codex kills the hook at its timeout, card withdrawn", resolved and resolved["reason"] == "hook-gone", resolved)
        approval = server.wait(is_approval, 8)
        case.check("then native approval", approval is not None)
        case.check("tool did not run", not env.marker())
    finally:
        server.close()
        broker.stop()


def case_failure_broker_absent(env, case):
    env.write_hooks({"PermissionRequest": [hook_entry(env.real_hook())]})
    env.trust_all()
    server = AppServer(env)
    thread = start_thread(env, server)
    started = time.time()
    run_turn(server, thread)
    try:
        approval = server.wait(is_approval, 12)
        case.check("native approval with no island", approval is not None, round(time.time() - started, 2))
        case.check("hook did not delay it", time.time() - started < 5, round(time.time() - started, 2))
        case.check("no auto allow", not env.marker())
    finally:
        server.close()


def case_failure_broker_dies(env, case):
    broker, server, _, _ = setup(env, [hook_entry(env.real_hook())])
    try:
        broker.next("request")
        broker.stop(kill=True)
        approval = server.wait(is_approval, 10)
        case.check("broker death falls back to native", approval is not None)
        case.check("tool did not run", not env.marker())
    finally:
        server.close()


def case_cancel_interrupt(env, case):
    broker, server, thread, turn = setup(env, [hook_entry(env.real_hook())])
    try:
        broker.next("request")
        before = time.time()
        server.call("turn/interrupt", {"threadId": thread, "turnId": turn})
        resolved = broker.next("resolved", 8)
        case.check("interrupt withdraws the card", resolved and resolved["reason"] == "hook-gone", resolved)
        case.check("quickly", time.time() - before < 4, round(time.time() - before, 2))
        finished = wait_turn(server)
        case.check("turn interrupted", finished and finished["params"]["turn"]["status"] == "interrupted", finished and finished["params"]["turn"]["status"])
        case.check("tool did not run", not env.marker())
    finally:
        server.close()
        broker.stop()


def case_cancel_server_killed(env, case):
    broker, server, _, _ = setup(env, [hook_entry(env.real_hook())])
    try:
        broker.next("request")
        server.proc.kill()
        server.proc.wait()
        resolved = broker.next("resolved", 8)
        case.check("SIGKILL of app-server withdraws the card (hook watches its parent)", resolved and resolved["reason"] == "hook-gone", resolved)
        case.check("tool did not run", not env.marker())
    finally:
        server.close()
        broker.stop()


def case_cancel_server_stops(env, case):
    broker, server, _, _ = setup(env, [hook_entry(env.real_hook())])
    try:
        broker.next("request")
        server.close()
        resolved = broker.next("resolved", 8)
        case.check("graceful exit withdraws the card", resolved and resolved["reason"] == "hook-gone", resolved)
        case.check("tool did not run", not env.marker())
    finally:
        broker.stop()


def case_duplicate_click(env, case):
    broker, server, _, _ = setup(env, [hook_entry(env.real_hook())])
    try:
        request = broker.next("request")
        broker.decide(request["nonce"], "allow")
        broker.decide(request["nonce"], "deny", message=DENY_TEXT)
        rejected = broker.next("rejected", 6)
        case.check("second click refused", rejected and rejected["reason"] == "no-longer-pending", rejected)
        wait_turn(server)
        case.check("first click won", env.marker())
    finally:
        server.close()
        broker.stop()


def _siblings(env, case, spec, island_decision, expect_marker, label):
    """Install the island hook and sibling probes, decide on the island at t≈0, and time the outcome."""
    env.write_hooks({"PermissionRequest": [hook_entry(env.real_hook())] + [hook_entry(env.probe(n, m), t) for n, m, t in spec]})
    env.trust_all()
    broker = rcli.BrokerProc(runtime=RUNTIME)
    server = AppServer(env)
    thread = start_thread(env, server)
    run_turn(server, thread)
    try:
        request = broker.next("request")
        decided_at = time.time()
        if island_decision == "allow":
            broker.decide(request["nonce"], "allow")
        else:
            broker.decide(request["nonce"], "deny", message=DENY_TEXT)
        finished = wait_turn(server, 30)
        elapsed = round(time.time() - decided_at, 2)
        case.check(f"{label}: turn completes", finished is not None)
        case.check(f"{label}: tool ran == {expect_marker}", env.marker() == expect_marker)
        return elapsed, env.outputs()
    finally:
        server.close()
        broker.stop()


def case_sibling_allow_waits(env, case):
    elapsed, _ = _siblings(env, case, [("HUD", "sleep:5", 60)], "allow", True, "island allow, sibling slow")
    case.check("decision waits for the sibling hook (about 5 s)", elapsed >= 4.5, elapsed)


def case_sibling_fast_no_delay(env, case):
    elapsed, _ = _siblings(env, case, [("HUD", "empty", 60)], "allow", True, "island allow, sibling exits at once")
    case.check("no noticeable delay", elapsed < 3, elapsed)


def case_sibling_hung_until_timeout(env, case):
    elapsed, _ = _siblings(env, case, [("HUD", "sleep:300", 4)], "allow", True, "island allow, sibling hung with short timeout")
    case.check("blocked until the sibling's own timeout (4 s)", 3.5 <= elapsed < 8, elapsed)


def case_sibling_deny_beats_island(env, case):
    _, out = _siblings(env, case, [("HUD", "deny", 60)], "allow", False, "island allow, sibling deny")
    case.check("sibling's denial reached the model", any("FICTIONAL_SIBLING_DENY" in o["output"] for o in out), out)


def case_island_deny_beats_sibling(env, case):
    _, out = _siblings(env, case, [("HUD", "allow", 60)], "deny", False, "island deny, sibling allow")
    case.check("island denial reached the model", any(DENY_TEXT in o["output"] for o in out), out)


def case_real_siblings_absent(env, case):
    # Real binaries, in the sandboxed, isolated environment, with their apps not running here.
    for label, command in (("Agent HUD", ["/Applications/Agent HUD Open.app/Contents/MacOS/Agent HUD Open", "--permission-hook", "codex"]),
                           ("original bridge", [os.path.expanduser("~/.vibe-island/bin/vibe-island-bridge"), "--source", "codex"])):
        if not os.path.exists(command[0]):
            case.check(f"{label}: installed", False, "not installed")
            continue
        payload = json.dumps({"session_id": "01a1be48-a2d2-7640-a668-7bb1877c676e", "cwd": str(env.work), "hook_event_name": "PermissionRequest",
                              "model": "mock", "permission_mode": "default", "tool_name": "Bash", "tool_input": {"command": "echo fictional"}})
        started = time.time()
        result = subprocess.run(command, input=payload.encode(), capture_output=True, timeout=10,
                                env={"HOME": str(env.home), "PATH": "/usr/bin:/bin", "CODEX_HOME": str(env.codex_home)})
        elapsed = round(time.time() - started, 3)
        case.check(f"{label}: exits at once with no decision on stdout", elapsed < 1 and b"decision" not in result.stdout, {"elapsed": elapsed, "exit": result.returncode, "stdout": result.stdout[:80].decode("utf-8", "replace")})


def _mode_case(env, case, label, config_lines, keyword, policy, sandbox, expect_request, hooks_extra=None):
    env2 = CodexEnv(env.root.parent / (env.root.name + "-" + label), config_lines)
    try:
        env2.write_hooks({"PermissionRequest": [hook_entry(env2.probe("PR", "empty"))], **(hooks_extra or {})})
        env2.trust_all()
        server = AppServer(env2)
        thread = start_thread(env2, server, policy=policy, sandbox=sandbox)
        run_turn(server, thread, keyword)
        result = server.wait(lambda m: done(m) or "requestApproval" in str(m.get("method")) or "elicitation" in str(m.get("method")), 15)
        if result and "id" in result and "method" in result:
            if "elicitation" in result["method"]:
                server.respond(result, {"action": "cancel", "content": None})
            else:
                server.respond(result, {"decision": "decline"})
            wait_turn(server, 8)
        server.close()
        fired = [e for e in env2.hook_events() if e["ev"] == "start"]
        case.check(f"{label}: PermissionRequest fired == {expect_request}", bool(fired) == expect_request, [(e["payload"].get("tool_name"), e["payload"].get("permission_mode")) for e in fired])
        return fired, env2.outputs()
    finally:
        env2.stop()
        shutil.rmtree(env2.root, ignore_errors=True)


DANGER = 'sandbox_mode = "danger-full-access"\n'


def mcp_config(env):
    return DANGER + f'[mcp_servers.fictional]\ncommand = "/usr/bin/python3"\nargs = ["-I", "{env.root / "mcp.py"}"]\n'


def case_modes(env, case):
    env.stop()  # each mode below starts its own environment on the same port
    m = [("dfa_default_plain", DANGER, "KW_PLAIN go", None, None, False),
         ("dfa_default_escalated", DANGER, "KW_ESC go", None, None, False),
         ("dfa_default_rm_plain", DANGER, "KW_RMPLAIN go", None, None, False),
         ("dfa_default_rm_rf", DANGER, "KW_RMRF go", None, None, True),
         ("never_plain", DANGER, "KW_PLAIN go", "never", "danger-full-access", False),
         ("never_rm_rf", DANGER, "KW_RMRF go", "never", "danger-full-access", False),
         ("workspace_on_request_escalated", "", "KW_ESC go", "on-request", "workspace-write", True),
         ("workspace_on_request_patch_outside", "", "KW_PATCH go", "on-request", "workspace-write", True)]
    for label, cfg, keyword, policy, sandbox, expect in m:
        fired, out = _mode_case(env, case, label, cfg, keyword, policy, sandbox, expect)
        if label == "never_rm_rf":
            case.check("never + rm -rf is refused by Codex without a hook", out and "rejected" in out[-1]["output"].lower(), out)
        if label == "workspace_on_request_patch_outside":
            case.check("patch request names apply_patch", fired and fired[0]["payload"].get("tool_name") == "apply_patch", fired and fired[0]["payload"].get("tool_name"))


def case_mcp_modes(env, case):
    env.stop()
    mcp = mcp_config(env)
    for label, keyword, policy, sandbox, expect in (("mcp_destructive_dfa_default", "KW_MCP_WRITE go", None, None, True),
                                                    ("mcp_readonly_dfa_default", "KW_MCP_READ go", None, None, False),
                                                    ("mcp_destructive_never", "KW_MCP_WRITE go", "never", "danger-full-access", False)):
        fired, _ = _mode_case(env, case, label, mcp, keyword, policy, sandbox, expect)
        if label == "mcp_destructive_dfa_default" and fired:
            case.check("MCP request names the tool and passes arguments", fired[0]["payload"].get("tool_name") == "mcp__fictional__fictional_write" and fired[0]["payload"].get("tool_input") == {"value": "fictional"}, fired[0]["payload"])


def case_exec_never_asks(env, case):
    # codex exec has no one to ask: even with -c approval_policy="on-request" it refuses at "never",
    # and PermissionRequest hooks do not fire. So hooks cannot approve anything in exec.
    env.write_hooks({"PermissionRequest": [hook_entry(env.probe("H", "allow"))]})
    env.trust_all()
    result = subprocess.run([CODEX, "exec", "--skip-git-repo-check", "-c", 'approval_policy="on-request"', "-s", "workspace-write", "KW_ESC go"],
                            cwd=env.work, env=env.child_env(), capture_output=True, timeout=45, stdin=subprocess.DEVNULL)
    case.check("exec exits", result.returncode == 0, result.stderr[-300:].decode("utf-8", "replace"))
    case.check("no PermissionRequest hook in exec", not env.hook_events(), env.hook_events())
    case.check("tool refused, not run", not env.marker() and any("approval policy is Never" in o["output"] for o in env.outputs()), env.outputs())


def case_questions(env, case):
    env.write_hooks({"PermissionRequest": [hook_entry(env.probe("PR", "empty"))], "PreToolUse": [hook_entry(env.probe("PRE", "empty"))], "PostToolUse": [hook_entry(env.probe("POST", "empty"))]})
    env.trust_all()
    server = AppServer(env)
    thread = start_thread(env, server)
    run_turn(server, thread, "KW_ASK go", {"collaborationMode": {"mode": "plan", "settings": {"model": "mock-model"}}})
    try:
        question = server.wait(lambda m: m.get("method") == "item/tool/requestUserInput", 12)
        case.check("question goes to the app-server client", question is not None)
        fired = [e["name"] for e in env.hook_events() if e["ev"] == "start"]
        case.check("no PermissionRequest for a question", "PR" not in fired, fired)
        case.check("PreToolUse fires for it", "PRE" in fired, fired)
        if question:
            server.respond(question, {"answers": {"q1": {"answers": ["Two"]}}})
            wait_turn(server, 8)
            case.check("only the client's answer reaches the model", any('"Two"' in o["output"] for o in env.outputs()), env.outputs())
    finally:
        server.close()


def case_question_default_mode_refused(env, case):
    env.write_hooks({"PermissionRequest": [hook_entry(env.probe("PR", "empty"))]})
    env.trust_all()
    server = AppServer(env)
    run_turn(server, start_thread(env, server), "KW_ASK go")
    try:
        wait_turn(server, 8)
        case.check("request_user_input unavailable in Default mode", any("unavailable in Default mode" in o["output"] for o in env.outputs()), env.outputs())
    finally:
        server.close()


def case_lifecycle_events(env, case):
    names = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop", "SessionEnd"]
    env.write_hooks({"PermissionRequest": [hook_entry(env.probe("PermissionRequest", "allow"))], **{n: [hook_entry(env.probe(n, "empty"))] for n in names}})
    env.trust_all()
    server = AppServer(env)
    thread = start_thread(env, server)
    run_turn(server, thread)
    wait_turn(server)
    server.close()
    time.sleep(1.5)
    events = [e for e in env.hook_events() if e["ev"] == "start"]
    order = [e["name"] for e in events]
    case.check("event order", order == ["SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "PostToolUse", "Stop", "SessionEnd"], order)
    by = {e["name"]: e["payload"] for e in events}
    case.check("tool events carry tool_use_id", by["PreToolUse"].get("tool_use_id") == "call_fictional" and by["PostToolUse"].get("tool_use_id") == "call_fictional", by["PreToolUse"].get("tool_use_id"))
    case.check("PermissionRequest has no tool_use_id", "tool_use_id" not in by["PermissionRequest"])
    case.check("PermissionRequest input adds description, unlike Pre/Post", by["PermissionRequest"]["tool_input"].get("description") == ESC["justification"] and "description" not in by["PreToolUse"]["tool_input"], [by["PermissionRequest"]["tool_input"], by["PreToolUse"]["tool_input"]])
    case.check("SessionStart source startup", by["SessionStart"].get("source") == "startup", by["SessionStart"].get("source"))


def case_subagent_payload(env, case):
    env.write_hooks({"PermissionRequest": [hook_entry(env.probe("PR", "allow"))]})
    env.trust_all()
    server = AppServer(env)
    thread = start_thread(env, server)
    run_turn(server, thread, "KW_SUB go")
    try:
        end = time.time() + 15
        while time.time() < end and not env.marker("child.txt"):
            time.sleep(0.1)
        fired = [e["payload"] for e in env.hook_events() if e["ev"] == "start"]
        child = next((p for p in fired if p.get("agent_id")), None)
        case.check("subagent's request reaches the hook", child is not None, fired)
        if child:
            case.check("session_id is the main thread and agent_id is set", child["session_id"] == thread and bool(child.get("agent_type")), child)
    finally:
        server.close()


def case_lifecycle_digest_gap(env, case):
    # With lifecycle events installed, the broker gets a card with no tool_use_id and input_digest
    # differing from Pre/Post, so an allow is never "confirmed". Pinned here so the fix can be seen.
    hooks = {"PreToolUse": [hook_entry(env.real_hook(), timeout=5)], "PostToolUse": [hook_entry(env.real_hook(), timeout=5)], "Stop": [hook_entry(env.real_hook(), timeout=5)]}
    broker, server, _, _ = setup(env, [hook_entry(env.real_hook())], extra_hooks=hooks)
    try:
        request = broker.next("request")
        case.check("no tool_use_id bound (input differs from PreToolUse)", request and request.get("tool_use_id") is None, request and request.get("tool_use_id"))
        broker.decide(request["nonce"], "allow")
        wait_turn(server)
        case.check("tool ran", env.marker())
        case.check("allow is reported unconfirmed, not confirmed", broker.next("unconfirmed", 5) is not None and not broker.of("confirmed"), broker.of("confirmed"))
    finally:
        server.close()
        broker.stop()


def case_trust_states(env, case):
    a = env.probe("A", "empty")
    env.write_hooks({"PermissionRequest": [hook_entry(a, 60)]})
    case.check("new hook is untrusted", env.statuses() == {"hooks.json:permission_request:0:0": "untrusted"}, env.statuses())
    server = AppServer(env)
    run_turn(server, start_thread(env, server))
    approval = server.wait(is_approval, 10)
    case.check("untrusted hook does not run", not env.hook_events(), env.hook_events())
    case.check("native prompt instead", approval is not None)
    server.respond(approval, {"decision": "decline"})
    wait_turn(server, 5)
    server.close()
    env.hook_log.unlink(missing_ok=True)
    env.trust_all()
    case.check("after config/batchWrite: trusted", env.statuses() == {"hooks.json:permission_request:0:0": "trusted"}, env.statuses())
    text = (env.codex_home / "config.toml").read_text()
    case.check("trust is written to config.toml hooks.state", "[hooks.state." in text and ":permission_request:0:0" in text and "trusted_hash" in text)
    env.write_hooks({"PermissionRequest": [hook_entry(a, 61)]})
    case.check("changing timeout makes it modified", env.statuses() == {"hooks.json:permission_request:0:0": "modified"}, env.statuses())
    env.write_hooks({"PermissionRequest": [hook_entry(a, 60)]})
    env.trust_all()
    b = env.probe("B", "empty")
    env.write_hooks({"PermissionRequest": [hook_entry(a, 60), hook_entry(b, 60)]})
    st = env.statuses()
    case.check("appending keeps earlier hooks trusted", st.get("hooks.json:permission_request:0:0") == "trusted" and st.get("hooks.json:permission_request:1:0") == "untrusted", st)
    env.write_hooks({"PermissionRequest": [hook_entry(b, 60), hook_entry(a, 60)]})
    st = env.statuses()
    case.check("inserting first shifts keys and loses trust", st.get("hooks.json:permission_request:0:0") == "modified", st)


def case_trust_hot_reload(env, case):
    env.write_hooks({"Stop": [hook_entry(env.probe("S0", "empty"), 5)]})
    env.trust_all()
    server = AppServer(env)
    old_thread = start_thread(env, server)
    env.write_hooks({"Stop": [hook_entry(env.probe("S0", "empty"), 5)], "PermissionRequest": [hook_entry(env.probe("LATE", "empty"), 5)]})
    env.trust_all()  # a separate process, like an installer running while the desktop app is open
    case.check("running server sees the new hook as trusted", env.statuses(server).get("hooks.json:permission_request:0:0") == "trusted", env.statuses(server))
    run_turn(server, old_thread)
    first = server.wait(lambda m: done(m) or is_approval(m), 10)
    if first and is_approval(first):
        server.respond(first, {"decision": "decline"})
    wait_turn(server, 5)
    case.check("a thread already loaded does not get it", not any(e["name"] == "LATE" for e in env.hook_events()), env.hook_events())
    env.hook_log.unlink(missing_ok=True)
    run_turn(server, start_thread(env, server))
    second = server.wait(lambda m: is_approval(m) and m["params"]["threadId"] != old_thread, 10)
    if second:
        server.respond(second, {"decision": "decline"})
    time.sleep(0.5)
    case.check("a new thread on the same server does", any(e["name"] == "LATE" and e["ev"] == "start" for e in env.hook_events()), env.hook_events())
    server.close()


def case_desktop_flags(env, case):
    # The running desktop app launches: codex -c features.code_mode_host=true app-server --analytics-default-enabled
    env.write_hooks({"PermissionRequest": [hook_entry(env.probe("H", "allow"))]})
    env.trust_all()
    server = AppServer(env, extra=("-c", "features.code_mode_host=true"))
    try:
        run_turn(server, start_thread(env, server))
        wait_turn(server)
        case.check("hooks run with the desktop app's flags", env.marker() and any(e["ev"] == "start" for e in env.hook_events()), env.hook_events())
    finally:
        server.close()


def case_installer(env, case):
    # Against an isolated copy shaped like the real file: two existing PermissionRequest hooks, trusted.
    installer = ROOT / "scripts" / "adapters" / "codex" / "install_codex_hook.py"
    fake_hook = str(env.root / "island hook.py")
    a, b = env.probe("HUD", "empty"), env.probe("BRIDGE", "empty")
    env.write_hooks({"PermissionRequest": [{**hook_entry(a, 86400), "matcher": ""}, hook_entry(b, 7200)], "Stop": [hook_entry(b, 5)]})
    env.trust_all()
    before = (env.codex_home / "config.toml").read_text()
    args = [sys.executable, "-I", str(installer), "--codex-home", str(env.codex_home), "--codex", CODEX, "--hook", fake_hook, "--runtime", RUNTIME]
    run = lambda *x: subprocess.run([*args, *x], capture_output=True, text=True, timeout=60, env=env.child_env(), cwd=env.work)
    dry = run("--dry-run")
    case.check("dry run writes nothing", dry.returncode == 0 and len(json.loads((env.codex_home / "hooks.json").read_text())["hooks"]["PermissionRequest"]) == 2, dry.stdout)
    first = run()
    case.check("install succeeds", first.returncode == 0, first.stdout + first.stderr)
    statuses = env.statuses()
    case.check("appended at index 2 and trusted", statuses.get("hooks.json:permission_request:2:0") == "trusted", statuses)
    case.check("existing hooks stay trusted", statuses.get("hooks.json:permission_request:0:0") == "trusted" and statuses.get("hooks.json:permission_request:1:0") == "trusted" and statuses.get("hooks.json:stop:0:0") == "trusted", statuses)
    second = run()
    case.check("idempotent", "already installed" in second.stdout, second.stdout)
    after = (env.codex_home / "config.toml").read_text()
    case.check("config.toml only gained the trust entry", after.startswith(before.rstrip()) and after.count(":permission_request:2:0") == 1, after[-300:])
    case.check("backups written", len(list(env.codex_home.glob("*.island-backup-*"))) == 2)
    undone = run("--undo")
    case.check("undo removes the trust entry too", ":permission_request:2:0" not in (env.codex_home / "config.toml").read_text())
    case.check("undo removes it", undone.returncode == 0 and len(json.loads((env.codex_home / "hooks.json").read_text())["hooks"]["PermissionRequest"]) == 2, undone.stdout + undone.stderr)
    statuses = env.statuses()
    case.check("after undo the other hooks are still trusted", statuses.get("hooks.json:permission_request:0:0") == "trusted" and statuses.get("hooks.json:permission_request:1:0") == "trusted" and "hooks.json:permission_request:2:0" not in statuses, statuses)
    # Another tool inserting a hook before ours shifts its key, which silently loses its trust.
    run()
    moved = json.loads((env.codex_home / "hooks.json").read_text())
    moved["hooks"]["PermissionRequest"].insert(0, hook_entry(env.probe("NEW", "empty"), 5))
    (env.codex_home / "hooks.json").write_text(json.dumps(moved))
    case.check("an inserted hook costs ours its trust", env.statuses().get("hooks.json:permission_request:3:0") == "untrusted", env.statuses())
    again = run()
    case.check("re-running the installer re-trusts it", "re-trusted" in again.stdout and env.statuses().get("hooks.json:permission_request:3:0") == "trusted", again.stdout + str(env.statuses()))


CASES = [case_allow, case_deny, case_release_to_native, case_tui_allow, case_tui_release_native_yes, case_tui_esc_cancels,
         case_failure_crash, case_failure_exit78, case_failure_empty, case_failure_garbage, case_failure_updated_input, case_failure_exit2_is_deny,
         case_failure_hook_timeout, case_failure_codex_timeout, case_failure_broker_absent, case_failure_broker_dies,
         case_cancel_interrupt, case_cancel_server_killed, case_cancel_server_stops, case_duplicate_click,
         case_sibling_allow_waits, case_sibling_fast_no_delay, case_sibling_hung_until_timeout, case_sibling_deny_beats_island, case_island_deny_beats_sibling,
         case_real_siblings_absent, case_modes, case_mcp_modes, case_exec_never_asks, case_questions, case_question_default_mode_refused,
         case_lifecycle_events, case_subagent_payload, case_lifecycle_digest_gap, case_trust_states, case_trust_hot_reload, case_desktop_flags, case_installer]


def kill_stray_hooks():
    found = subprocess.run(["/usr/bin/pgrep", "-f", f"claude_approval_hook.py --runtime {RUNTIME}"], capture_output=True, text=True).stdout.split()
    for pid in found:
        try:
            os.kill(int(pid), signal.SIGKILL)
        except ProcessLookupError:
            pass


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--only", action="append")
    parser.add_argument("--out")
    args = parser.parse_args()
    version = subprocess.run([CODEX, "--version"], capture_output=True, text=True).stdout.strip()
    root = tempfile.mkdtemp(prefix="codex-e2e-", dir=os.environ.get("TMPDIR", "/tmp"))
    os.makedirs("/private/tmp/cc-socks", mode=0o700, exist_ok=True)
    report = {"codex_version": version, "started": time.strftime("%Y-%m-%dT%H:%M:%S"), "data": "fictional only; fake local model", "cases": []}
    failed = 0
    try:
        for function in CASES:
            name = function.__name__[5:]
            if args.only and name not in args.only:
                continue
            shutil.rmtree(RUNTIME, ignore_errors=True)
            env = CodexEnv(os.path.join(root, name))
            case = rcli.Case(env, name)
            try:
                function(env, case)
            except Exception as error:  # A crash in one scenario is a failure, not a test-run abort.
                case.check("scenario raised", False, repr(error))
            kill_stray_hooks()
            env.stop()
            failed += not case.passed
            report["cases"].append({"name": name, "passed": case.passed, "checks": case.checks})
            print(("PASS " if case.passed else "FAIL ") + name, flush=True)
            for check in case.checks:
                if not check["ok"]:
                    print("   x", check["check"], str(check["detail"])[:400], flush=True)
    finally:
        shutil.rmtree(RUNTIME, ignore_errors=True)
        shutil.rmtree(root, ignore_errors=True)
    if args.out:
        pathlib.Path(args.out).write_text(json.dumps(report, ensure_ascii=False, indent=1, default=str))
    print(f"{len(report['cases']) - failed}/{len(report['cases'])} passed on {version}")
    return 1 if failed else 0


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--serve-mock":
        serve_mock(sys.argv[2:])
    else:
        sys.exit(main())
