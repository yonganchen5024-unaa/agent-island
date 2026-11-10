#!/usr/bin/env python3
"""Reports OpenCode sessions as ended when the OpenCode process is gone, however it went.

The plugin keeps this process's stdin open and writes one JSON object per line:
{"add": session_id, "cwd": dir} or {"del": session_id}. Closing stdin (normal exit, crash or
SIGKILL alike) sends SessionEnd for every session still open. It only ever sends SessionEnd.
"""
import argparse
import json
import signal
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument('--python', required=True)
    parser.add_argument('--hook', required=True)
    parser.add_argument('--runtime', required=True)
    args = parser.parse_args()
    # Only stdin closing ends this process, so a terminal hangup does not lose the SessionEnd.
    for name in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
        signal.signal(name, signal.SIG_IGN)
    alive = {}
    for line in sys.stdin:
        try:
            message = json.loads(line)
        except ValueError:
            continue
        if not isinstance(message, dict):
            continue
        if isinstance(message.get('add'), str):
            alive[message['add']] = message.get('cwd')
        elif isinstance(message.get('del'), str):
            alive.pop(message['del'], None)
    for session_id, cwd in alive.items():
        payload = json.dumps({'hook_event_name': 'SessionEnd', 'session_id': session_id, 'cwd': cwd}).encode()
        try:
            subprocess.run([args.python, '-I', args.hook, '--runtime', args.runtime, '--source', 'opencode'],
                           input=payload, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5)
        except (OSError, subprocess.SubprocessError):
            pass


if __name__ == '__main__':
    main()
