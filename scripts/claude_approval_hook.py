#!/usr/bin/env python3
"""Hook client for the Agent Island approval broker (protocol v2), used by every agent.

--source names the agent (default claude). Other agents feed it the same JSON shape on stdin,
directly if their hooks are Claude-compatible or through an adapter, and read the same output.

One script serves two jobs, chosen by the event Claude sends on stdin:

* PermissionRequest: send the whole request to the broker and wait for one explicit
  allow, deny or answer. Print the decision only after it is authenticated.
* Lifecycle events (PreToolUse, PostToolUse, PostToolUseFailure, Stop, StopFailure,
  SessionEnd, UserPromptSubmit, SubagentStop, PreCompact): send a short note and exit immediately.

Behaviour measured on the real Claude Code 2.1.316 CLI (docs/reference/claude-approval-arbitration.md):

* Claude's native dialog stays open while this hook runs, and the first decision wins.
* Empty output with exit 0 leaves the native dialog in control. This script therefore
  prints nothing on every failure path. It never decides on its own and never exits 2.
* Answering the dialog in the terminal does NOT end this hook, so the broker closes the
  connection when it sees PostToolUse, and the hook then exits with no output.

Same-UID processes are outside the trust boundary: an HMAC key in an owner-only directory
stops other users and accidental cross-talk, not a process running as the same user.

Usage: claude_approval_hook.py --runtime DIR [--source NAME] [--managed --target-uid UID] [--timeout SEC]
"""
import argparse
import hashlib
import hmac
import json
import os
import re
import secrets
import select
import signal
import socket
import stat
import sys
import time

PROTOCOL = 2
MAX_INPUT = 8 * 1024 * 1024
MAX_RESPONSE = 8 * 1024 * 1024
LIFECYCLE_EVENTS = frozenset((
    'PreToolUse', 'PostToolUse', 'PostToolUseFailure', 'Stop', 'StopFailure',
    'SessionEnd', 'UserPromptSubmit', 'SubagentStop', 'PreCompact',
    'SessionStart', 'SubagentStart', 'PostCompact', 'Notification',
))
SOURCE = re.compile(r'^[a-z][a-z0-9-]{0,31}$')
TRUSTED_PATH = '/Library/Application Support/ClaudeCode/IslandReplica/managed_approval_hook.py'
SID = re.compile(r'^[A-Za-z0-9_:-]{1,128}$')


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=True).encode('ascii')


def sign(key, value):
    return hmac.new(key, canonical(value), hashlib.sha256).hexdigest()


# scripts/claude_observe_hook.py imports mac, owned_restricted and read_secret from here.
mac = sign


def digest(value):
    return hashlib.sha256(canonical(value)).hexdigest()


def trusted_installation():
    """A managed install must be root-owned all the way down, like the observer hook."""
    if os.path.abspath(__file__) != TRUSTED_PATH:
        return False
    parents = ('/Library', '/Library/Application Support', '/Library/Application Support/ClaudeCode',
               '/Library/Application Support/ClaudeCode/IslandReplica')
    for directory in parents:
        info = os.lstat(directory)
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != 0 or stat.S_IMODE(info.st_mode) & 0o022:
            return False
    info = os.lstat(TRUSTED_PATH)
    return stat.S_ISREG(info.st_mode) and info.st_uid == 0 and stat.S_IMODE(info.st_mode) == 0o644


def owned_private(path, kind):
    info = os.lstat(path)
    if info.st_uid != os.getuid() or info.st_mode & 0o077 or not kind(info.st_mode):
        raise ValueError('unsafe runtime path')
    return info


owned_restricted = owned_private


def read_secret(path):
    before = owned_private(path, stat.S_ISREG)
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        after = os.fstat(fd)
        if (before.st_dev, before.st_ino) != (after.st_dev, after.st_ino) or after.st_nlink != 1:
            raise ValueError('key changed')
        value = os.read(fd, 65)
    finally:
        os.close(fd)
    if len(value) != 32:
        raise ValueError('bad key')
    return value


def read_key(runtime):
    return read_secret(os.path.join(runtime, 'key'))


def connect(runtime, connect_timeout):
    owned_private(runtime, stat.S_ISDIR)
    path = os.path.join(runtime, 'broker.sock')
    before = owned_private(path, stat.S_ISSOCK)
    key = read_key(runtime)
    conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        conn.settimeout(connect_timeout)
        conn.connect(path)
        after = owned_private(path, stat.S_ISSOCK)
        if (before.st_dev, before.st_ino) != (after.st_dev, after.st_ino):
            raise ValueError('socket changed')
    except BaseException:
        conn.close()
        raise
    return conn, key


def lifecycle(event, runtime, source):
    name = event.get('hook_event_name')
    sid = event.get('session_id')
    if name not in LIFECYCLE_EVENTS or not isinstance(sid, str) or not SID.fullmatch(sid):
        return
    # Only identifiers and a digest travel here: no tool input, output, or prompt text.
    note = {'version': PROTOCOL, 'kind': 'lifecycle', 'name': name, 'session_id': sid,
            'time': time.time(), 'agent_id': event.get('agent_id') if isinstance(event.get('agent_id'), str) else None}
    note['source'] = source
    # Set by adapters whose agent has no session registry, so the island can notice a killed process.
    if os.environ.get('AGENT_ISLAND_PID', '').isdigit():
        note['pid'] = int(os.environ['AGENT_ISLAND_PID'])
    if isinstance(event.get('cwd'), str) and len(event['cwd']) <= 4096:
        note['cwd'] = event['cwd']
    if isinstance(event.get('notification_type'), str) and len(event['notification_type']) <= 64:
        note['notification_type'] = event['notification_type']
    tool = event.get('tool_name')
    if isinstance(tool, str) and len(tool) <= 256:
        note['tool_name'] = tool
    tool_use_id = event.get('tool_use_id')
    if isinstance(tool_use_id, str) and len(tool_use_id) <= 256:
        note['tool_use_id'] = tool_use_id
    if isinstance(event.get('tool_input'), dict):
        note['input_digest'] = digest(event['tool_input'])
    if name == 'PostToolUse':
        response = event.get('tool_response')
        note['is_error'] = isinstance(response, str) and response.startswith('Error')
    elif name == 'PostToolUseFailure':
        note['is_error'] = True
    conn, key = connect(runtime, 0.25)
    with conn:
        conn.sendall(canonical({'event': note, 'mac': sign(key, note)}) + b'\n')


def claude_alive(pid):
    if pid is None:
        return True
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except OSError:
        return True
    return True


def receive_line(conn, deadline):
    """Wait for one line. Returns None on EOF, timeout, or if Claude has gone away.

    A Claude process that exits while its dialog is open does not always end this hook,
    and a shell may sit between us, so watch Claude's own PID as well as our parent.
    """
    parent = os.getppid()
    claude_pid = os.environ.get('CLAUDE_PID', '')
    claude_pid = int(claude_pid) if claude_pid.isdigit() else None
    data = bytearray()
    while len(data) <= MAX_RESPONSE:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return None
        ready, _, _ = select.select([conn], [], [], min(remaining, 1.0))
        if os.getppid() != parent or not claude_alive(claude_pid):
            return None
        if not ready:
            continue
        part = conn.recv(65536)
        if not part:
            return None
        data.extend(part)
        if b'\n' in data:
            line, rest = bytes(data).split(b'\n', 1)
            if rest:
                raise ValueError('unexpected data')
            return json.loads(line)
    raise ValueError('response too large')


def valid_answers(request_input, updated):
    """An updated input may only add answers: every original field must stay byte-identical."""
    if not isinstance(updated, dict) or set(updated) - set(request_input) - {'answers'}:
        return False
    if not isinstance(updated.get('answers'), dict) or not updated['answers']:
        return False
    return all(canonical(updated.get(k)) == canonical(v) for k, v in request_input.items())


def permission(event, runtime, wait_seconds, source):
    sid, tool, tool_input = event.get('session_id'), event.get('tool_name'), event.get('tool_input')
    if not isinstance(sid, str) or not SID.fullmatch(sid) or not isinstance(tool, str) or not 0 < len(tool) <= 256:
        return
    if not isinstance(tool_input, dict):
        return
    nonce = secrets.token_hex(32)
    request = {
        'version': PROTOCOL, 'kind': 'permission', 'nonce': nonce, 'session_id': sid, 'tool_name': tool,
        'tool_input': tool_input, 'input_digest': digest(tool_input), 'wait_seconds': wait_seconds, 'source': source,
    }
    for field in ('agent_id', 'agent_type', 'prompt_id', 'cwd', 'permission_mode', 'transcript_path'):
        value = event.get(field)
        if isinstance(value, str) and len(value) <= 4096:
            request[field] = value
    suggestions = event.get('permission_suggestions')
    if isinstance(suggestions, list):
        request['permission_suggestions'] = suggestions
    server = event.get('mcp_server')
    if isinstance(server, dict):
        request['mcp_server'] = server
    conn, key = connect(runtime, 1.0)
    with conn:
        conn.settimeout(5.0)
        conn.sendall(canonical({'request': request, 'mac': sign(key, request)}) + b'\n')
        conn.settimeout(None)
        reply = receive_line(conn, time.monotonic() + wait_seconds)
    if not isinstance(reply, dict) or set(reply) != {'response', 'mac'}:
        return
    body, mac = reply['response'], reply['mac']
    if not isinstance(body, dict) or not isinstance(mac, str) or not hmac.compare_digest(sign(key, body), mac):
        return
    if body.get('version') != PROTOCOL or body.get('nonce') != nonce:
        return
    choice = body.get('decision')
    if choice == 'allow':
        decision = {'behavior': 'allow'}
        updates = body.get('updated_permissions')
        if updates is not None:
            # A persistent rule must be one Claude offered for this request, unchanged.
            offered = {canonical(item) for item in (suggestions if isinstance(suggestions, list) else [])}
            if not isinstance(updates, list) or not updates or any(canonical(item) not in offered for item in updates):
                return
            decision['updatedPermissions'] = updates
    elif choice == 'answer':
        # Questions are answered through updatedInput, the only form Claude accepts for them.
        if not valid_answers(tool_input, body.get('updated_input')):
            return
        decision = {'behavior': 'allow', 'updatedInput': body['updated_input']}
    elif choice == 'deny':
        message = body.get('message')
        decision = {'behavior': 'deny', 'message': message if isinstance(message, str) and message else '用户在小岛上拒绝了这次工具请求。'}
    else:
        return
    output = {'hookSpecificOutput': {'hookEventName': 'PermissionRequest', 'decision': decision}}
    sys.stdout.write(json.dumps(output, separators=(',', ':')) + '\n')
    sys.stdout.flush()


def main():
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument('--runtime', required=True)
    parser.add_argument('--timeout', type=float, default=3590.0)
    parser.add_argument('--managed', action='store_true')
    parser.add_argument('--target-uid', type=int)
    parser.add_argument('--source', default='claude')
    args = parser.parse_args()
    if not os.path.isabs(args.runtime) or not 0 < args.timeout <= 86400 or not SOURCE.fullmatch(args.source):
        return
    if args.managed and (args.target_uid is None or os.getuid() != args.target_uid or not trusted_installation()):
        return
    # SIGTERM is how Claude cancels a pending hook. Leave quietly; the closed socket is the signal.
    signal.signal(signal.SIGTERM, lambda *_: os._exit(0))
    signal.signal(signal.SIGHUP, lambda *_: os._exit(0))
    signal.signal(signal.SIGPIPE, signal.SIG_DFL)
    raw = sys.stdin.buffer.read(MAX_INPUT + 1)
    if len(raw) > MAX_INPUT:
        return
    event = json.loads(raw)
    if not isinstance(event, dict):
        return
    if event.get('hook_event_name') == 'PermissionRequest':
        permission(event, args.runtime, args.timeout, args.source)
    else:
        lifecycle(event, args.runtime, args.source)


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, TypeError, KeyError, UnicodeError, SystemExit):
        # Empty output with exit 0 leaves Claude's native dialog in control.
        pass
    sys.exit(0)
