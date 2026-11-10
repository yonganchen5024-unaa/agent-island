#!/usr/bin/env python3
"""Show a fictional request on the REAL running island, from a REAL Claude CLI with a fake model.

  --answer-in-terminal   nobody needs to click: the test answers in the terminal after a pause
                         (checks hook -> running app, the withdrawal, and the audit log)
  --wait-for-click SEC   waits for a person to click the card on screen, then reports what the
                         model actually received. This is the on-screen click acceptance.

--runtime defaults to the app's real broker directory. Under --managed the slot stays empty and
the system's managed handler does the work, which also exercises the installed configuration.
The only command the card can run is writing a fictional marker file in a throwaway directory.
"""
import argparse, json, os, pathlib, sys, tempfile, shutil, time
HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from isolated_cli import Env
import run_real_cli_approval as R

parser = argparse.ArgumentParser()
parser.add_argument("--answer-in-terminal", action="store_true")
parser.add_argument("--wait-for-click", type=float)
parser.add_argument("--managed", action="store_true", help="use the installed managed handler instead of the test slot")
parser.add_argument("--race-allow-after", type=float, help="with --managed: the test slot also answers allow after this many seconds")
args = parser.parse_args()
uid = os.getuid()
runtime = f"/private/tmp/cc-socks/agent-island-{uid}-approval"
root = tempfile.mkdtemp(prefix="app-", dir=os.environ.get("TMPDIR", "/tmp"))
env = Env(os.path.join(root, "env"))
env.prepare({"KW_SINGLE": R.SCENARIOS["KW_SINGLE"]})
if args.managed:
    env.slot_config({"mode": "allow", "delay": args.race_allow_after} if args.race_allow_after else {"mode": "empty"})
else:
    R.RUNTIME = runtime
    R.install_slot(env)
env.start_server(real_island_ok=True)  # This one shows a card on the real island on purpose.
tty = R.start_turn(env, "KW_SINGLE")
marker = env.work / "marker.txt"
outcome = {}
try:
    outcome["native_dialog_visible"] = tty.wait_for(R.DIALOG, 15)
    if args.answer_in_terminal:
        tty.pump(3.0)
        tty.send(b"1"); tty.pump(0.3); tty.send(b"\r")
        tty.pump(3.0)
    elif args.wait_for_click or args.race_allow_after:
        print(f"waiting up to {args.wait_for_click or args.race_allow_after + 8}s for a decision...", flush=True)
        end = time.time() + (args.wait_for_click or args.race_allow_after + 8)
        while time.time() < end and not R.tool_results(env):
            tty.pump(0.2)
        tty.pump(1.5)
    outcome["tool_ran"] = marker.exists()
    outcome["model_saw"] = R.tool_results(env)
    text = " ".join(tty.text().split())
    outcome["terminal_says_hook_allowed"] = "Allowed by PermissionRequest hook" in text
    outcome["terminal_says_hook_denied"] = "Denied by PermissionRequest hook" in text
finally:
    tty.close()
    env.stop_server()
    shutil.rmtree(root, ignore_errors=True)
print(json.dumps(outcome, ensure_ascii=False, indent=1))
