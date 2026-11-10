#!/usr/bin/python3 -I
"""Scriptable PermissionRequest test hook. Installed ONLY under a throwaway test HOME.

Behaviour comes from $HOME/slot-config.json: {"mode": ..., "delay": seconds}.
Modes: allow, deny, deny-interrupt, empty, block, crash, garbage, exit2, updated-input,
broker (forward to the isolated approval broker through scripts/claude_approval_hook.py).
Every lifecycle moment is appended to $HOME/slot-log.jsonl so tests can see when and
how Claude ends a pending hook. Contains no decision logic besides the configured mode.
"""
import json
import os
import select
import signal
import sys
import time

HOME = os.environ["HOME"]
LOG = os.path.join(HOME, "slot-log.jsonl")


def log(event, **fields):
    record = {"t": round(time.time(), 3), "pid": os.getpid(), "ppid": os.getppid(), "event": event, **fields}
    with open(LOG, "a", encoding="utf-8") as out:
        out.write(json.dumps(record, ensure_ascii=False) + "\n")


def on_signal(number, _frame):
    log("signal", signal=signal.Signals(number).name)
    os._exit(128 + number)


def respond(decision):
    sys.stdout.write(json.dumps({"hookSpecificOutput": {"hookEventName": "PermissionRequest", "decision": decision}}) + "\n")
    sys.stdout.flush()
    log("responded", decision=decision)


def main():
    for number in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT, signal.SIGPIPE):
        signal.signal(number, on_signal)
    raw = sys.stdin.buffer.read()
    event = json.loads(raw) if raw else {}
    config = json.load(open(os.path.join(HOME, "slot-config.json"), encoding="utf-8"))
    mode = config.get("mode", "empty")
    log("start", mode=mode, hook_input=event, env={k: v for k, v in os.environ.items() if k.startswith("CLAUDE") and "TOKEN" not in k})
    if event.get("hook_event_name") != "PermissionRequest":
        log("ignored-event", name=event.get("hook_event_name"))
        return 0
    delay = float(config.get("delay", 0))
    if delay:
        time.sleep(delay)
    if mode == "allow":
        respond({"behavior": "allow"})
    elif mode == "updated-input":
        respond({"behavior": "allow", "updatedInput": config["updated_input"]})
    elif mode == "deny":
        respond({"behavior": "deny", "message": config.get("message", "FICTIONAL_DENY_MESSAGE")})
    elif mode == "deny-interrupt":
        respond({"behavior": "deny", "message": "FICTIONAL_DENY_INTERRUPT", "interrupt": True})
    elif mode == "block":
        # Wait forever, while watching for parent death and the stdout pipe closing.
        parent = os.getppid()
        poller = select.poll()
        poller.register(1, select.POLLERR | select.POLLHUP)
        started = time.time()
        while time.time() - started < float(config.get("limit", 600)):
            ready = poller.poll(200)
            if ready:
                log("stdout-closed", revents=ready[0][1])
                return 0
            if os.getppid() != parent:
                log("parent-changed", new=os.getppid())
                return 0
        log("limit-reached")
    elif mode == "crash":
        log("crashing")
        os.kill(os.getpid(), signal.SIGKILL)
    elif mode == "garbage":
        sys.stdout.write("{not json at all\n")
        sys.stdout.flush()
        log("garbage-written")
    elif mode == "exit2":
        sys.stderr.write("FICTIONAL_EXIT2_STDERR\n")
        log("exit2")
        return 2
    else:
        log("empty")
    return 0


if __name__ == "__main__":
    code = main()
    log("exit", code=code)
    sys.exit(code)
