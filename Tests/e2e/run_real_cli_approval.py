#!/usr/bin/env python3
"""End-to-end approval tests: REAL Claude Code CLI, real hook, real broker, fake model.

This script plays the part of the island UI by talking to the broker over stdio. It proves
Claude <-> hook <-> broker behaviour. It does not prove the SwiftUI buttons work; that is
covered separately. All prompts, commands and file contents are fictional.

Run:  /usr/bin/python3 -I Tests/e2e/run_real_cli_approval.py [--only NAME] [--out FILE]
"""
import argparse
import json
import os
import pathlib
import re
import select
import shutil
import subprocess
import sys
import tempfile
import time

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parent.parent
sys.path.insert(0, str(HERE))
from isolated_cli import Env, pid_alive  # noqa: E402

BROKER = ROOT / "scripts" / "claude_approval_broker.py"
HOOK = ROOT / "scripts" / "claude_approval_hook.py"
# Some agent sandboxes only allow Unix sockets under this directory.
RUNTIME = f"/private/tmp/cc-socks/island-e2e-{os.getuid()}-{os.getpid()}"
DIALOG = r"(?i)(do\s*you\s*want|1\.\s*Yes)"
QUESTION = {"questions": [{"question": "Fictional question?", "header": "Pick", "multiSelect": False,
                           "options": [{"label": "One", "description": "first"}, {"label": "Two", "description": "second"}]}]}


def bash(command, description="fictional"):
    return {"tool_use": "Bash", "input": {"command": command, "description": description}}


def long_inline_rm(pad_to=2300, last="echo fictional-run > marker.txt"):
    """A fictional `bash -c` script over 2000 characters with a variable rm, which Claude's own safety
    check asks about even in bypassPermissions. It only ever deletes inside the test's work folder."""
    head = "bash -c '\nS=./fictional-scratch\nW=$S/wk; rm -rf $W; mkdir -p $W/a\n"
    tail = f"{last}\n'"
    lines, size = [], len(head) + len(tail)
    while size < pad_to:
        line = f"echo fictional-padding-line-{len(lines):04d} >/dev/null\n"
        lines.append(line)
        size += len(line)
    return head + "".join(lines) + tail


SCENARIOS = {
    "KW_RMHINT": [[bash(long_inline_rm(), "Fictional build cleanup")], [{"text": "finished-turn"}]],
    "KW_SINGLE": [[bash("echo fictional-run > marker.txt")], [{"text": "finished-turn"}]],
    "KW_SLOW": [[bash("sleep 4; echo slow > marker.txt")], [{"text": "finished-turn"}]],
    "KW_PARREAD": [[{"tool_use": "Read", "input": {"file_path": "/etc/hosts"}, "id": "toolu_read_a"},
                    {"tool_use": "Read", "input": {"file_path": "/etc/hosts"}, "id": "toolu_read_b"},
                    {"tool_use": "Read", "input": {"file_path": "/etc/shells"}, "id": "toolu_read_c"}],
                   [{"text": "finished-turn"}]],
    "KW_ASK": [[{"tool_use": "AskUserQuestion", "input": QUESTION}], [{"text": "finished-turn"}]],
    "KW_TWICE": [[{"tool_use": "Read", "input": {"file_path": "/etc/hosts"}}], [{"tool_use": "Read", "input": {"file_path": "/etc/shells"}}], [{"text": "finished-turn"}]],
    "KW_DISGUISE": [[bash("echo safe‮ > marker.txt", "line one\nline two")], [{"text": "finished-turn"}]],
}


ACTIVE_TTY = []  # Claude stalls if nobody drains its terminal, so every wait also reads the pty.


class BrokerProc:
    def __init__(self, runtime=RUNTIME, deadline=None):
        args = ["/usr/bin/python3", "-I", "-u", str(BROKER), "--runtime-dir", runtime]
        if deadline:
            args += ["--deadline", str(deadline)]
        self.proc = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.events = []
        self.buffer = b""
        ready = self.next("ready", 5)
        assert ready, "broker did not become ready"

    def poll(self, seconds=0.05):
        end = time.time() + seconds
        while True:
            for tty in ACTIVE_TTY:
                tty.pump(0.01)
            ready, _, _ = select.select([self.proc.stdout], [], [], max(0, end - time.time()))
            if ready:
                chunk = os.read(self.proc.stdout.fileno(), 1 << 20)
                if not chunk:
                    return
                self.buffer += chunk
                while b"\n" in self.buffer:
                    line, self.buffer = self.buffer.split(b"\n", 1)
                    self.events.append(json.loads(line))
            if time.time() >= end:
                return

    def next(self, kind, timeout=20, seen=None, match=None):
        end = time.time() + timeout
        seen = seen if seen is not None else set()
        while time.time() < end:
            self.poll(0.05)
            for index, event in enumerate(self.events):
                if index not in seen and event["type"] == kind and (match is None or match(event)):
                    seen.add(index)
                    return event
        return None

    def of(self, kind):
        self.poll(0.02)
        return [e for e in self.events if e["type"] == kind]

    def decide(self, nonce, decision, **extra):
        line = json.dumps({"op": "decision", "nonce": nonce, "decision": decision, **extra}) + "\n"
        self.proc.stdin.write(line.encode())
        self.proc.stdin.flush()

    def stop(self, kill=False):
        if self.proc.poll() is None:
            self.proc.kill() if kill else self.proc.terminate()
            self.proc.wait(5)
        for stream in (self.proc.stdin, self.proc.stdout, self.proc.stderr):
            stream.close()


class Case:
    def __init__(self, env, name):
        self.env, self.name = env, name
        self.checks = []

    def check(self, label, ok, detail=None):
        self.checks.append({"check": label, "ok": bool(ok), "detail": detail})

    @property
    def passed(self):
        return all(c["ok"] for c in self.checks)


def install_slot(env, timeout=3590):
    """Point the managed "$HOME/.vibe-island/bin/vibe-island-bridge" handler at the real hook, in the test HOME only."""
    target = env.home / ".vibe-island" / "bin" / "vibe-island-bridge"
    target.write_text(
        "#!/bin/sh\ncase \"$*\" in *--task*) exit 0;; esac\n"
        f"exec /usr/bin/python3 -I '{HOOK}' --runtime '{RUNTIME}' --timeout {timeout}\n")
    target.chmod(0o755)


def clean_workdir(env):
    for f in env.work.glob("*.txt"):
        f.unlink()
    env.clear_logs()


def tool_results(env):
    records = [r for r in env.api_records() if r.get("kind") == "main" and r.get("tool_results")]
    return records[-1]["tool_results"] if records else []


def start_turn(env, keyword, mode="default"):
    tty = env.spawn_tty(mode=mode)
    tty.pump(3.5)
    tty.set_mark()
    tty.submit(f"{keyword} go")
    ACTIVE_TTY[:] = [tty]
    return tty


def hook_processes():
    """PIDs of hook clients for this runtime. /bin/ps cannot run in the sandbox, so use pgrep."""
    out = subprocess.run(["/usr/bin/pgrep", "-f", f"claude_approval_hook.py --runtime {RUNTIME}"], capture_output=True, text=True).stdout
    return [int(x) for x in out.split()]


def hooks_gone(timeout=3.0):
    end = time.time() + timeout
    while time.time() < end:
        if not hook_processes():
            return True
        time.sleep(0.1)
    return False


def press_no_with_feedback(tty):
    """Move to the dialog's last option (No), press Tab, type a reason, and submit."""
    text = tty.text()
    numbers = [int(n) for n in re.findall(r"(\d)\.\s*(?:Yes|No)", text)]
    for _ in range(max(numbers or [3]) - 1):
        tty.send(b"\x1b[B")
        tty.pump(0.2)
    tty.send(b"\t")
    tty.pump(0.4)
    tty.send(b"fictional feedback")
    tty.pump(0.4)
    tty.send(b"\r")


# ---- Scenarios. Each returns nothing and records checks on the Case. --------------------

def case_allow(env, case):
    broker = BrokerProc()
    tty = start_turn(env, "KW_SINGLE")
    try:
        request = broker.next("request")
        case.check("card shows complete input", request and request["tool_input"]["command"] == "echo fictional-run > marker.txt", request)
        case.check("request tied to its tool_use_id", request and str(request.get("tool_use_id")).startswith("toolu_mock_"))
        case.check("native dialog also visible", tty.wait_for(DIALOG, 10))
        case.check("tool has not run before the decision", not (env.work / "marker.txt").exists())
        broker.decide(request["nonce"], "allow")
        confirmed = broker.next("confirmed", 15)
        case.check("broker reports delivered then Claude confirmed", confirmed and confirmed["decision"] == "allow" and not confirmed["is_error"], confirmed)
        tty.pump(1.5)
        case.check("tool really ran", (env.work / "marker.txt").exists())
        results = tool_results(env)
        case.check("model received a success tool_result", results and not results[-1]["is_error"], results)
        case.check("terminal shows hook allowed it", "Allowed by PermissionRequest hook" in re.sub(r"\s+", " ", tty.text()))
    finally:
        tty.close()
        broker.stop()


def case_deny(env, case):
    broker = BrokerProc()
    tty = start_turn(env, "KW_SINGLE")
    try:
        request = broker.next("request")
        broker.decide(request["nonce"], "deny", message="FICTIONAL 用户拒绝原因")
        confirmed = broker.next("confirmed", 15)
        case.check("Claude confirmed the denial", confirmed and confirmed["decision"] == "deny" and confirmed["is_error"], confirmed)
        tty.pump(1.5)
        case.check("tool did not run", not (env.work / "marker.txt").exists())
        results = tool_results(env)
        case.check("model received the denial message", results and results[-1]["is_error"] and "FICTIONAL 用户拒绝原因" in results[-1]["content"], results)
    finally:
        tty.close()
        broker.stop()


def case_answered_in_terminal(env, case):
    broker = BrokerProc()
    tty = start_turn(env, "KW_SINGLE")
    try:
        request = broker.next("request")
        tty.wait_for(DIALOG, 10)
        pids = hook_processes()
        case.check("hook is waiting", len(pids) >= 1, pids)
        tty.send(b"1")
        tty.pump(0.3)
        tty.send(b"\r")
        resolved = broker.next("resolved", 15)
        case.check("card ended as answered elsewhere", resolved and resolved["reason"] == "answered-elsewhere", resolved)
        tty.pump(1.0)
        case.check("hook process exited", not [p for p in pids if pid_alive(p)], [p for p in pids if pid_alive(p)])
        case.check("tool ran from the terminal answer", (env.work / "marker.txt").exists())
        broker.decide(request["nonce"], "deny")
        rejected = broker.next("rejected", 5)
        case.check("late island click is refused and reported", rejected and rejected["reason"] == "no-longer-pending", rejected)
    finally:
        tty.close()
        broker.stop()


def case_esc_in_terminal(env, case):
    broker = BrokerProc()
    tty = start_turn(env, "KW_SINGLE")
    try:
        broker.next("request")
        tty.wait_for(DIALOG, 10)
        tty.pump(0.5)
        tty.send(b"\x1b")
        resolved = broker.next("resolved", 15)
        case.check("Esc cancels the card", resolved and resolved["reason"] == "hook-gone", resolved)
        case.check("tool did not run", not (env.work / "marker.txt").exists())
    finally:
        tty.close()
        broker.stop()


def case_no_with_feedback(env, case):
    broker = BrokerProc()
    tty = start_turn(env, "KW_SINGLE")
    try:
        broker.next("request")
        tty.wait_for(DIALOG, 10)
        tty.pump(0.8)
        press_no_with_feedback(tty)
        resolved = broker.next("resolved", 15)
        case.check("terminal denial with feedback ends the card", resolved is not None, resolved)
        case.check("tool did not run", not (env.work / "marker.txt").exists())
        case.check("hook client exited", hooks_gone(), hook_processes())
    finally:
        tty.close()
        broker.stop()


def case_session_exit(env, case):
    broker = BrokerProc()
    tty = start_turn(env, "KW_SINGLE")
    try:
        broker.next("request")
        tty.wait_for(DIALOG, 10)
    finally:
        ACTIVE_TTY.clear()
        tty.close()
    resolved = broker.next("resolved", 10)
    case.check("closing the session ends the card", resolved is not None, resolved)
    case.check("tool did not run", not (env.work / "marker.txt").exists())
    case.check("no hook client left behind", hooks_gone(), hook_processes())
    broker.stop()


def case_broker_absent(env, case):
    started = time.time()
    tty = start_turn(env, "KW_SINGLE")
    try:
        case.check("native dialog still appears with no island running", tty.wait_for(DIALOG, 15))
        case.check("hook does not linger", hooks_gone(), hook_processes())
        tty.pump(0.5)
        tty.send(b"1")
        tty.pump(0.3)
        tty.send(b"\r")
        tty.pump(2.0)
        case.check("terminal approval works", (env.work / "marker.txt").exists(), round(time.time() - started, 1))
    finally:
        tty.close()


def case_broker_dies(env, case):
    broker = BrokerProc()
    tty = start_turn(env, "KW_SINGLE")
    try:
        broker.next("request")
        tty.wait_for(DIALOG, 10)
        broker.stop(kill=True)
        tty.pump(1.5)
        case.check("hook exits when island dies", hooks_gone(), hook_processes())
        case.check("tool still pending", not (env.work / "marker.txt").exists())
        tty.send(b"1")
        tty.pump(0.3)
        tty.send(b"\r")
        tty.pump(2.0)
        case.check("terminal dialog still decides", (env.work / "marker.txt").exists())
    finally:
        tty.close()


def case_hook_timeout(env, case):
    install_slot(env, timeout=3)
    broker = BrokerProc()
    tty = start_turn(env, "KW_SINGLE")
    try:
        broker.next("request")
        tty.wait_for(DIALOG, 10)
        resolved = broker.next("resolved", 10)
        case.check("hook timeout ends the card", resolved and resolved["reason"] == "hook-gone", resolved)
        case.check("no decision was made on timeout", not (env.work / "marker.txt").exists())
        tty.pump(0.5)
        tty.send(b"1")
        tty.pump(0.3)
        tty.send(b"\r")
        tty.pump(2.0)
        case.check("native dialog still decides after timeout", (env.work / "marker.txt").exists())
    finally:
        tty.close()
        broker.stop()
        install_slot(env)


def case_parallel(env, case):
    broker = BrokerProc()
    tty = start_turn(env, "KW_PARREAD")
    try:
        seen = set()
        requests = [broker.next("request", 15, seen) for _ in range(3)]
        case.check("three parallel requests give three cards", all(requests), [r and r["tool_input"] for r in requests])
        ids = sorted(r["tool_use_id"] for r in requests)
        case.check("each card has a distinct tool_use_id", ids == ["toolu_read_a", "toolu_read_b", "toolu_read_c"], ids)
        hosts = [r for r in requests if r["tool_input"]["file_path"] == "/etc/hosts"]
        shells = [r for r in requests if r["tool_input"]["file_path"] == "/etc/shells"][0]
        broker.decide(hosts[0]["nonce"], "allow")
        broker.decide(hosts[1]["nonce"], "deny", message="FICTIONAL_DENY_SECOND")
        broker.decide(shells["nonce"], "allow")
        seen = set()
        confirmed = [broker.next("confirmed", 15, seen) for _ in range(3)]
        case.check("each decision confirmed once", all(confirmed), confirmed)
        tty.pump(1.5)
        results = {r["tool_use_id"]: r for r in tool_results(env)}
        hosts_results = [results[i] for i in ("toolu_read_a", "toolu_read_b")] if len(results) == 3 else []
        case.check("identical calls: one allowed, one denied", sorted(r["is_error"] for r in hosts_results) == [False, True], results)
        case.check("distinct call: allowed", results.get("toolu_read_c", {}).get("is_error") is False)
        case.check("denial message reached the model", any("FICTIONAL_DENY_SECOND" in r["content"] for r in hosts_results))
    finally:
        tty.close()
        broker.stop()


def case_question(env, case):
    broker = BrokerProc()
    tty = start_turn(env, "KW_ASK")
    try:
        request = broker.next("request")
        case.check("question request reaches the card", request and request["tool_name"] == "AskUserQuestion", request and request["tool_name"])
        broker.decide(request["nonce"], "answer", answers={"Fictional question?": "Two"})
        confirmed = broker.next("confirmed", 15)
        case.check("Claude confirmed the answer", confirmed and not confirmed["is_error"], confirmed)
        tty.pump(1.5)
        results = tool_results(env)
        case.check("model received the chosen answer", results and '"Two"' in results[-1]["content"], results)
    finally:
        tty.close()
        broker.stop()


def case_duplicate_click(env, case):
    broker = BrokerProc()
    tty = start_turn(env, "KW_SLOW")
    try:
        request = broker.next("request")
        broker.decide(request["nonce"], "allow")
        broker.decide(request["nonce"], "deny")
        rejected = broker.next("rejected", 5)
        case.check("second click refused", rejected and rejected["reason"] == "no-longer-pending", rejected)
        delivered = broker.of("delivered")
        case.check("exactly one delivery", len(delivered) == 1 and delivered[0]["decision"] == "allow", delivered)
        case.check("no confirmation claimed while the tool still runs", not broker.of("confirmed"))
        confirmed = broker.next("confirmed", 12)
        case.check("confirmation arrives when the tool finishes", confirmed and confirmed["decision"] == "allow", confirmed)
        tty.pump(1.0)
        case.check("first click won", (env.work / "marker.txt").exists())
    finally:
        tty.close()
        broker.stop()


def case_always(env, case):
    broker = BrokerProc()
    tty = start_turn(env, "KW_TWICE")
    try:
        request = broker.next("request")
        offered = request["permission_suggestions"]
        case.check("Claude offered a rule for this directory", bool(offered), offered)
        broker.decide(request["nonce"], "allow", suggestion=0)
        first = broker.next("confirmed", 15)
        case.check("first read confirmed", first and first["decision"] == "allow", first)
        end = time.time() + 8
        while time.time() < end and len(tool_results(env)) < 2:
            broker.poll(0.1)
        requests = broker.of("request")
        case.check("adopted rule means no second request", len(requests) == 1, len(requests))
        results = tool_results(env)
        case.check("model got both file contents", len(results) == 2 and not any(r["is_error"] for r in results), [r["is_error"] for r in results])
    finally:
        tty.close()
        broker.stop()


def case_disguised_text(env, case):
    broker = BrokerProc()
    tty = start_turn(env, "KW_DISGUISE")
    try:
        request = broker.next("request")
        case.check("bidi control shown as a visible escape", "\\u202e" in request["tool_input_text"] and "‮" not in request["tool_input_text"], request["tool_input_text"])
        case.check("raw control absent from structured input too", "‮" not in request["tool_input"]["command"])
    finally:
        tty.close()
        broker.stop()


CASES = [
    ("allow", case_allow), ("deny", case_deny), ("answered_in_terminal", case_answered_in_terminal),
    ("esc_in_terminal", case_esc_in_terminal), ("no_with_feedback", case_no_with_feedback),
    ("session_exit", case_session_exit), ("broker_absent", case_broker_absent), ("broker_dies", case_broker_dies),
    ("hook_timeout", case_hook_timeout), ("parallel", case_parallel), ("question", case_question),
    ("duplicate_click", case_duplicate_click), ("disguised_text", case_disguised_text), ("always", case_always),
]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--only", action="append")
    parser.add_argument("--out")
    args = parser.parse_args()
    version = subprocess.run(["/opt/homebrew/bin/claude", "--version"], capture_output=True, text=True).stdout.strip()
    root = tempfile.mkdtemp(prefix="iso-", dir=os.environ.get("TMPDIR", "/tmp"))
    env = Env(os.path.join(root, "env"))
    env.prepare(SCENARIOS)
    install_slot(env)
    env.start_server()
    os.makedirs("/private/tmp/cc-socks", mode=0o700, exist_ok=True)
    report = {"claude_version": version, "started": time.strftime("%Y-%m-%dT%H:%M:%S"), "cases": []}
    failed = 0
    try:
        for name, function in CASES:
            if args.only and name not in args.only:
                continue
            clean_workdir(env)
            case = Case(env, name)
            try:
                function(env, case)
            except Exception as error:  # A crash in one scenario is a failure, not a test-run abort.
                case.check("scenario raised", False, repr(error))
            failed += not case.passed
            report["cases"].append({"name": name, "passed": case.passed, "checks": case.checks})
            print(("PASS " if case.passed else "FAIL ") + name, flush=True)
            for check in case.checks:
                if not check["ok"]:
                    print("   x", check["check"], str(check["detail"])[:300], flush=True)
            ACTIVE_TTY.clear()
            for pid in hook_processes():
                os.kill(pid, 15)
    finally:
        env.stop_server()
        shutil.rmtree(RUNTIME, ignore_errors=True)
        shutil.rmtree(root, ignore_errors=True)
    if args.out:
        pathlib.Path(args.out).write_text(json.dumps(report, ensure_ascii=False, indent=1))
    print(f"{len(report['cases']) - failed}/{len(report['cases'])} passed on {version}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
