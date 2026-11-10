#!/usr/bin/env python3
"""GUI end-to-end: REAL Claude CLI -> real hook -> real broker -> real ClaudeApprovalBridge and
SwiftUI ApprovalCard (buttons pressed in-process) -> back to Claude, with a fake model.
Not covered: an on-screen pointer click and the app's panel window behaviour."""
import argparse, json, os, pathlib, select, shutil, subprocess, sys, tempfile, time
HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parent.parent
sys.path.insert(0, str(HERE))
from isolated_cli import Env
import run_real_cli_approval as R

SOURCES = ROOT / "Sources/IslandReplica"
SWIFT = [SOURCES / name for name in ("BarkNotifier.swift", "BarkEvents.swift", "ClaudeApprovalHint.swift", "ClaudeApprovalBridge.swift", "ClaudeApprovalView.swift", "IslandView.swift", "PixelActivity.swift", "SessionStore.swift", "SoundManager.swift", "Builtin8BitSynth.swift", "AgentUsageReader.swift")] + [HERE / "gui/main.swift"]


def build(out):
    result = subprocess.run(["swiftc", "-Onone", "-o", str(out), *map(str, SWIFT)], capture_output=True, text=True)
    if result.returncode:
        raise SystemExit("swiftc failed:\n" + result.stderr[-3000:])


class GUI:
    def __init__(self, exe, press, snapshot):
        args = [str(exe), "--broker", str(R.BROKER), "--runtime", R.RUNTIME, "--snapshot", str(snapshot)]
        for label in press:
            args += ["--click", label]
        self.proc = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        self.events, self.buffer = [], b""

    def poll(self, seconds=0.05):
        end = time.time() + seconds
        while time.time() < end:
            for tty in R.ACTIVE_TTY:
                tty.pump(0.01)
            ready, _, _ = select.select([self.proc.stdout], [], [], 0.02)
            if ready:
                chunk = os.read(self.proc.stdout.fileno(), 1 << 20)
                if not chunk:
                    return
                self.buffer += chunk
                while b"\n" in self.buffer:
                    line, self.buffer = self.buffer.split(b"\n", 1)
                    self.events.append(json.loads(line))

    def wait(self, predicate, timeout=20):
        end = time.time() + timeout
        while time.time() < end:
            self.poll(0.1)
            hit = next((e for e in self.events if predicate(e)), None)
            if hit:
                return hit
        return None

    def stop(self):
        self.proc.stdin.close()
        try:
            self.proc.wait(5)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            self.proc.wait(2)
        self.proc.stdout.close()


def run_case(env, exe, name, keyword, press, verify, shots, mode="default"):
    R.clean_workdir(env)
    gui = GUI(exe, press, pathlib.Path(shots) / name)
    tty = None
    checks = []
    def check(label, ok, detail=None):
        checks.append({"check": label, "ok": bool(ok), "detail": detail})
    try:
        check("service ready", gui.wait(lambda e: e["event"] == "state" and e["state"] == "ready", 8))
        tty = R.start_turn(env, keyword, mode)
        verify(env, gui, tty, check)
    except Exception as error:
        check("scenario raised", False, repr(error))
    finally:
        R.ACTIVE_TTY.clear()
        if tty:
            tty.close()
        gui.stop()
    passed = all(c["ok"] for c in checks)
    print(("PASS " if passed else "FAIL ") + name, flush=True)
    for c in checks:
        if not c["ok"]:
            print("   x", c["check"], str(c["detail"])[:400], flush=True)
    return {"name": name, "passed": passed, "checks": checks, "events": [e for e in gui.events if e["event"] != "pending"]}


def bark_messages(gui):
    return [json.loads(e["body"]) for e in gui.events if e["event"] == "bark"]


def check_phone(gui, check, title):
    """The phone gets the event, and never the command, the file names or the session name."""
    hit = gui.wait(lambda e: e["event"] == "bark" and json.loads(e["body"]).get("title") == title, 15)
    check("phone told: " + title, hit and hit["url"] == "https://api.day.app/push", gui.events[-3:])
    text = json.dumps(bark_messages(gui), ensure_ascii=False)
    check("nothing private in the push", not any(word in text for word in ("fictional-run", "marker", "虚构会话名", "KW_")), text)


def check_no_push_at_turn_end(gui, tty, check, expected):
    """The turn has ended by now. That alone tells the phone nothing."""
    tty.pump(4.0)
    gui.poll(0.2)
    titles = [m.get("title") for m in bark_messages(gui)]
    check("turn end is not pushed", len(titles) == expected, titles)


def verify_allow(env, gui, tty, check):
    pending = gui.wait(lambda e: e["event"] == "pending" and e["count"] == 1)
    check_phone(gui, check, "需要审批")
    check("card received complete input", pending and "echo fictional-run > marker.txt" in pending["inputs"][0], pending)
    check("button pressed", gui.wait(lambda e: e["event"] == "pressed" and e["label"] == "允许一次" and e["ok"]), gui.events)
    check("Claude outcome shown", gui.wait(lambda e: e["event"] == "outcome" and "Claude 已执行" in e["text"], 15), gui.events[-4:])
    tty.pump(1.0)
    check("tool really ran", (env.work / "marker.txt").exists())
    results = R.tool_results(env)
    check("model got success", results and not results[-1]["is_error"], results)
    check_no_push_at_turn_end(gui, tty, check, 1)


def verify_deny(env, gui, tty, check):
    gui.wait(lambda e: e["event"] == "pending" and e["count"] == 1)
    check("button pressed", gui.wait(lambda e: e["event"] == "pressed" and e["label"] == "拒绝" and e["ok"]), gui.events)
    check("Claude outcome shown", gui.wait(lambda e: e["event"] == "outcome" and "按拒绝处理" in e["text"], 15), gui.events[-4:])
    tty.pump(1.0)
    check("tool did not run", not (env.work / "marker.txt").exists())
    results = R.tool_results(env)
    check("model got the island's denial", results and results[-1]["is_error"] and "小岛上拒绝" in results[-1]["content"], results)


def verify_question(env, gui, tty, check):
    check("question card shown", gui.wait(lambda e: e["event"] == "pending" and e["tools"] == ["AskUserQuestion"]))
    check_phone(gui, check, "有问题等待回答")
    check("option pressed", gui.wait(lambda e: e["event"] == "pressed" and e["label"] == "Two" and e["ok"]), gui.events)
    check("submit pressed", gui.wait(lambda e: e["event"] == "pressed" and e["label"] == "提交回答" and e["ok"]), gui.events)
    check("Claude outcome shown", gui.wait(lambda e: e["event"] == "outcome" and "已收到回答" in e["text"], 15), gui.events[-4:])
    tty.pump(1.0)
    results = R.tool_results(env)
    check("model got the chosen answer", results and '"Two"' in results[-1]["content"], results)
    # PreToolUse and PermissionRequest both announce it, and that must be one push.
    check_no_push_at_turn_end(gui, tty, check, 1)


def verify_no_press_terminal(env, gui, tty, check):
    gui.wait(lambda e: e["event"] == "pending" and e["count"] == 1)
    tty.wait_for(R.DIALOG, 10)
    tty.pump(1.2)
    tty.send(b"1")
    tty.pump(0.3)
    tty.send(b"\r")
    check("card withdrawn with truthful text", gui.wait(lambda e: e["event"] == "outcome" and "已在其他地方处理" in e["text"], 15), gui.events[-4:])
    check("card removed", gui.wait(lambda e: e["event"] == "pending" and e["count"] == 0, 5))


def verify_rm_hint(env, gui, tty, check):
    # bypassPermissions sends no ordinary requests, but Claude's own rm check still asks.
    pending = gui.wait(lambda e: e["event"] == "pending" and e["count"] == 1, 25)
    check("Claude asked despite bypass", pending and pending["modes"] == ["bypassPermissions"], pending and pending["modes"])
    check("card lists the rm", pending and "rm -rf $W" in pending["hints"][0], pending and pending["hints"])
    check("card names the cause as a guess", pending and "小岛推断" in pending["hintTitles"][0], pending and pending["hintTitles"])
    check("complete input still there", pending and "fictional-padding-line-0000" in pending["inputs"][0])
    check("tool has not run before the decision", not (env.work / "marker.txt").exists())
    check("button pressed", gui.wait(lambda e: e["event"] == "pressed" and e["label"] == "允许一次" and e["ok"]), gui.events[-3:])
    check("Claude outcome shown", gui.wait(lambda e: e["event"] == "outcome" and "Claude 已执行" in e["text"], 20), gui.events[-4:])
    tty.pump(1.0)
    check("tool really ran", (env.work / "marker.txt").exists())


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--shots", required=True)
    parser.add_argument("--press-hint", default="允许一次@581,313")
    parser.add_argument("--out")
    args = parser.parse_args()
    os.makedirs(args.shots, exist_ok=True)
    root = tempfile.mkdtemp(prefix="gui-", dir=os.environ.get("TMPDIR", "/tmp"))
    exe = pathlib.Path(root) / "harness"
    build(exe)
    env = Env(os.path.join(root, "env"))
    env.prepare(R.SCENARIOS)
    R.install_slot(env)
    env.start_server()
    report = {"cases": []}
    try:
        report["cases"].append(run_case(env, exe, "allow", "KW_SINGLE", ["允许一次@581,233"], verify_allow, args.shots))
        report["cases"].append(run_case(env, exe, "deny", "KW_SINGLE", ["拒绝@434,233"], verify_deny, args.shots))
        report["cases"].append(run_case(env, exe, "question", "KW_ASK", ["Two@320,188", "提交回答@581,229"], verify_question, args.shots))
        report["cases"].append(run_case(env, exe, "terminal_answer", "KW_SINGLE", [], verify_no_press_terminal, args.shots))
        report["cases"].append(run_case(env, exe, "question_bypass", "KW_ASK", ["Two@320,188", "提交回答@581,229"], verify_question, args.shots, mode="bypassPermissions"))
        report["cases"].append(run_case(env, exe, "rm_hint", "KW_RMHINT", [args.press_hint], verify_rm_hint, args.shots, mode="bypassPermissions"))
    finally:
        env.stop_server()
        shutil.rmtree(R.RUNTIME, ignore_errors=True)
        shutil.rmtree(root, ignore_errors=True)
    if args.out:
        pathlib.Path(args.out).write_text(json.dumps(report, ensure_ascii=False, indent=1))
    failed = sum(not c["passed"] for c in report["cases"])
    print(f"{len(report['cases']) - failed}/{len(report['cases'])} passed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
