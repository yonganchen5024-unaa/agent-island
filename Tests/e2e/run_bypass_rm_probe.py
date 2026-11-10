#!/usr/bin/env python3
"""Which commands still ask in bypassPermissions, and does a subagent's decision survive the main
turn ending? Real: the Claude Code binary, its permission checks and dialog, its hooks. Fake: the
model and every command. Every deletion target is inside this test's throwaway folder.
Run with the real island stopped: the managed hook would otherwise put these on the user's screen."""
import argparse, json, os, pathlib, re, shutil, sys, tempfile, time
HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from isolated_cli import Env
import run_real_cli_approval as R


def pad(lines):
    return "".join(f"echo fictional-padding-line-{i:04d} >/dev/null\n" for i in range(lines))


def inline(root, inner_size, guard=False, rm=True):
    target = '"${W:?}"' if guard else "$W"
    head = f"S={root}/scratch\nW=$S/wk; " + (f"rm -rf {target}; " if rm else "") + "mkdir -p $W/a\n"
    size = max(0, inner_size - len(head) - 12)
    return head + pad(size // 39) + "echo done\n"


def wrap(inner, tail=""):
    return f"bash -c '\n{inner}'" + (f"\n{tail}" if tail else "")


def replica(root, tail=False, awk=True):
    """Fictional stand-ins following the structure of a real request that asked with no long script."""
    body = (f"S={root}/scratch\nC=~/build/demo; T={root}/tools\nP={root}/out/patch.diff\n"
            "W=$S/wk; rm -rf $W; mkdir -p $W/a; cd $W; git init -q .\n"
            "rsync -a --exclude build --exclude .gradle $C/a/b a/\ngit add -A >/dev/null\n"
            "rsync -a --delete --exclude build --exclude .gradle $C/a/c/ a/c/\ngit add -A . >/dev/null\n"
            'git -c core.quotepath=false diff --cached --binary --no-color > "$P"\n'
            "git diff --cached --stat --no-color | cut -c1-80\n"
            'cd $C && git apply --check "$P" && echo "git apply --check ok"\n'
            'echo "a $(grep -c "^diff --git" "$P")；b $(grep -c $(printf "\\x00") "$P")；c $(grep -c "x" "$P")；d $(grep -c y "$P")"\n'
            "cd $C; git diff --stat -- a/b/c/d/e | wc -l\n"
            'ls -l ~/build/a "$P"\n')
    if awk:
        body += 'ls -l ~/build/a | awk "{print \\$5, \\$6, \\$7, \\$8}"\n'
    after = ("grep -n -E 'a|b|c|d =' ~/x/y/z/build.gradle | cut -c1-80 | head -5; "
             "grep -n 'x' ~/x/y/z/build.gradle | cut -c1-80") if tail else ""
    return wrap(body, after)


def cases(root):
    long_body = inline(root, 3000)
    return {
        "short_1000": wrap(inline(root, 1000)),
        "len_1900": wrap(inline(root, 1900)),
        "len_1990": wrap(inline(root, 1990)),
        "len_2050": wrap(inline(root, 2050)),
        "len_2100": wrap(inline(root, 2100)),
        "len_3700": wrap(inline(root, 3700)),
        "long_no_rm": wrap(inline(root, 3000, rm=False)),
        "long_guarded": wrap(inline(root, 3000, guard=True)),
        "short_guarded": wrap(inline(root, 1000, guard=True)),
        "short_literal": f"bash -c 'rm -rf {root}/scratch/literal; echo done'",
        "long_top_level": long_body,
        "script_file": f"cat > {root}/run.sh <<'FILE'\n{long_body}FILE\nbash {root}/run.sh",
        "short_tail": wrap(inline(root, 1000), "grep -n 'x' ~/x/y/z/build.gradle | cut -c1-80"),
        "replica_asked": replica(root, tail=True, awk=True),
        "replica_no_tail": replica(root, tail=False, awk=True),
        "replica_no_awk": replica(root, tail=True, awk=False),
        "replica_plain": replica(root, tail=False, awk=False),
    }


def reason_of(text):
    flat = re.sub(r"\s+", "", text)
    return [tag for tag, phrase in (("could-not-check", "couldnotcheck"), ("runtime-target", "knownonlywhenitruns"),
                                    ("dangerous-rm", "Dangerousrm"), ("dialog", "Doyouwant")) if phrase in flat]


def run_case(env, name):
    env.clear_logs()
    env.slot_config({"mode": "empty"})
    tty = R.start_turn(env, f"KW_P_{name}_", "bypassPermissions")
    asked, finished = None, False
    end = time.time() + 20
    try:
        while time.time() < end and not asked and not finished:
            tty.pump(0.2)
            for record in env.slot_log():
                hook = record.get("hook_input") or {}
                if record.get("event") == "start" and hook.get("hook_event_name") == "PermissionRequest":
                    asked = hook
            finished = bool(R.tool_results(env))
        tty.pump(2.5)
        text = tty.text()
    finally:
        R.ACTIVE_TTY.clear()
        tty.close()
    return {"name": name, "asked": bool(asked), "finished_without_asking": finished and not asked, "reason": reason_of(text),
            "permission_mode": asked and asked.get("permission_mode"), "suggestions": asked and len(asked.get("permission_suggestions") or [])}


def run_subagent(env):
    """A background subagent is allowed, then the main turn ends while its command is still running."""
    R.install_slot(env)
    env.clear_logs()
    broker = R.BrokerProc()
    tty = R.start_turn(env, "KW_SUBMAIN", "bypassPermissions")
    try:
        request = broker.next("request", 30)
        if not request:
            return {"name": "subagent_settle", "error": "no request", "events": [e["type"] for e in broker.events]}
        broker.decide(request["nonce"], "allow")
        started = time.time()
        end = started + 40
        ended = None
        while time.time() < end:
            broker.poll(0.2)
            ended = next((e for e in broker.events if e["type"] in ("confirmed", "unconfirmed")), None)
            if ended:
                break
        stop_seen = any(e["type"] == "lifecycle" and e.get("name") == "Stop" for e in broker.events)
        return {"name": "subagent_settle", "agent_id_present": bool(request.get("agent_id")), "agent_type": request.get("agent_type"),
                "permission_mode": request.get("permission_mode"), "main_stop_seen": stop_seen,
                "ended_as": ended and ended["type"], "ended_reason": ended and ended.get("reason"),
                "seconds_after_allow": ended and round(time.time() - started, 1)}
    finally:
        R.ACTIVE_TTY.clear()
        tty.close()
        broker.stop()
        shutil.rmtree(R.RUNTIME, ignore_errors=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--out")
    parser.add_argument("--only", choices=["shapes", "subagent"])
    args = parser.parse_args()
    root = tempfile.mkdtemp(prefix="rmprobe-", dir=os.environ.get("TMPDIR", "/tmp"))
    env = Env(os.path.join(root, "env"))
    shapes = cases(os.path.join(root, "env"))
    scenarios = {"KW_SUBMAIN": [[{"tool_use": "Agent", "input": {"description": "Fictional", "prompt": "KW_SUBINNER go", "subagent_type": "general-purpose", "run_in_background": True}}],
                                [R.bash("sleep 6; echo main-done")], [{"text": "finished-turn"}]],
                 "KW_SUBINNER": [[R.bash(R.long_inline_rm(last="sleep 14; echo sub-done > sub.txt"), "Fictional subagent cleanup")], [{"text": "sub-finished"}]]}
    for name, command in shapes.items():
        scenarios[f"KW_P_{name}_"] = [[R.bash(command, "Fictional " + name)], [{"text": "finished-turn"}]]
    env.prepare(scenarios)
    env.start_server()
    report = {"version": os.path.basename(os.path.dirname(os.path.realpath("/opt/homebrew/bin/claude"))), "shapes": [], "subagent": None,
              "lengths": {name: len(command) for name, command in shapes.items()}}
    try:
        if args.only != "subagent":
            for name in shapes:
                result = run_case(env, name)
                report["shapes"].append(result)
                print(f"{name:18} len {len(shapes[name]):5} asked={result['asked']!s:5} {result['reason']} mode={result['permission_mode']} sugg={result['suggestions']}", flush=True)
        if args.only != "shapes":
            report["subagent"] = run_subagent(env)
            print(report["subagent"], flush=True)
    finally:
        env.stop_server()
        shutil.rmtree(root, ignore_errors=True)
    if args.out:
        pathlib.Path(args.out).write_text(json.dumps(report, ensure_ascii=False, indent=1))
    return 0


if __name__ == "__main__":
    sys.exit(main())
