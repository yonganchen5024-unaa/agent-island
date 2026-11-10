#!/usr/bin/env python3
"""Stdio/UI broker for claude_approval_hook.py (protocol v2). Never decides on its own.

Listens on a private socket and speaks newline JSON with the app over stdio:
events on stdout (ready, request, resolved, lifecycle), actions on stdin (decision).
Only an explicit UI action can authorize a decision. Same-UID processes are outside
its trust boundary. Request/outcome semantics were measured on the real Claude CLI:
see docs/reference/claude-approval-arbitration.md.
"""
import argparse
import errno
import fcntl
import hashlib
import hmac
import json
import os
from pathlib import Path
import re
import secrets
import selectors
import signal
import socket
import stat
import sys
import tempfile
import time
import unicodedata

PROTOCOL = 2
MAX_FRAME = 8 * 1024 * 1024
MAX_CLIENTS = 256
MAX_SEEN = 16384
MAX_UNCLAIMED = 4096
UNCLAIMED_TTL = 86400.0
DEFAULT_DEADLINE = 3600.0
MAX_DEADLINE = 86400.0
SESSION_ID = re.compile('[A-Za-z0-9_:-]{1,128}')
NONCE = re.compile('[0-9a-f]{64}')
# Events that prove a session's main loop is no longer waiting on any permission prompt.
TURN_OVER = frozenset(('Stop', 'StopFailure', 'SessionEnd', 'UserPromptSubmit'))

def canonical(value): return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=True).encode('ascii')
def signature(key, value): return hmac.new(key, canonical(value), hashlib.sha256).hexdigest()
def emit(event):
    sys.stdout.buffer.write(json.dumps(event, sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode('utf-8', 'backslashreplace') + b'\n'); sys.stdout.buffer.flush()

def visible_text(text):
    """Make characters that could disguise a command visible: format controls and lone surrogates."""
    out = []
    for ch in text:
        code = ord(ch)
        if 0xD800 <= code <= 0xDFFF or unicodedata.category(ch) in ('Cf', 'Zl', 'Zp', 'Co', 'Cn'):
            out.append('\\u%04x' % code if code <= 0xFFFF else '\\U%08x' % code)
        else:
            out.append(ch)
    return ''.join(out)

def visible(value):
    if isinstance(value, str): return visible_text(value)
    if isinstance(value, list): return [visible(v) for v in value]
    if isinstance(value, dict): return {visible_text(k): visible(v) for k, v in value.items()}
    return value

class StableRuntime:
    """Private fixed paths guarded by a persistent lock; not same-UID isolation."""
    marker_text = b"agent-island-approval-runtime-v1\n"
    def __init__(self, directory):
        if not os.path.isabs(directory): raise ValueError('runtime path must be absolute')
        self.root = Path(directory); self.lock_fd = None
        self.key_identity = None; self.socket_identity = None
        self.secret_path = self.root/'key'; self.socket_path = self.root/'broker.sock'
        created = False
        try:
            # /private/tmp is emptied on reboot, so the parent directory may be missing too.
            os.makedirs(self.root.parent, mode=0o700, exist_ok=True)
            try: os.mkdir(self.root, 0o700); created = True
            except FileExistsError: pass
            self.check(self.root, stat.S_ISDIR, 0o700)
            marker = self.root/'runtime.marker'
            if not os.path.lexists(marker):
                # An interrupted first start may leave an empty owner-only dir.
                # Refuse to adopt a directory containing unrecognized files.
                if not created and list(self.root.iterdir()): raise ValueError('runtime marker missing')
                try:
                    fd = os.open(marker, os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW, 0o600)
                except FileExistsError: pass
                else:
                    with os.fdopen(fd,'wb') as out: out.write(self.marker_text)
            marker_info = self.check(marker, stat.S_ISREG, 0o600)
            fd = os.open(marker, os.O_RDONLY|os.O_NOFOLLOW)
            try:
                info = os.fstat(fd)
                if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077 or (info.st_dev,info.st_ino)!=(marker_info.st_dev,marker_info.st_ino): raise ValueError('invalid runtime marker')
                marker_bytes = os.read(fd,256)
            finally: os.close(fd)
            if marker_bytes != self.marker_text:
                # Recover only a provably incomplete first write in an otherwise
                # empty private runtime. Do not modify unknown marker contents.
                if not self.marker_text.startswith(marker_bytes) or {p.name for p in self.root.iterdir()} != {'runtime.marker'}: raise ValueError('invalid runtime marker')
                fd = os.open(marker, os.O_WRONLY|os.O_NOFOLLOW)
                try:
                    info = os.fstat(fd)
                    if (info.st_dev,info.st_ino)!=(marker_info.st_dev,marker_info.st_ino): raise ValueError('runtime marker changed')
                    os.ftruncate(fd,0); os.write(fd,self.marker_text); os.fsync(fd)
                finally: os.close(fd)
            lock_path = self.root/'broker.lock'
            self.lock_fd = os.open(lock_path, os.O_RDWR|os.O_CREAT|os.O_NOFOLLOW, 0o600)
            info = os.fstat(self.lock_fd)
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077: raise ValueError('invalid runtime lock')
            try: fcntl.flock(self.lock_fd, fcntl.LOCK_EX|fcntl.LOCK_NB)
            except BlockingIOError as exc: raise ValueError('approval broker already running') from exc
            self.remove_stale_socket()
            if os.path.lexists(self.secret_path): self.check(self.secret_path,stat.S_ISREG,0o600)
        except BaseException:
            if self.lock_fd is not None: os.close(self.lock_fd); self.lock_fd=None
            raise
    @staticmethod
    def check(path, kind, expected):
        info = os.lstat(path)
        if info.st_uid != os.getuid() or not kind(info.st_mode) or stat.S_IMODE(info.st_mode) != expected: raise ValueError('unsafe runtime path')
        return info
    def remove_stale_socket(self):
        if not os.path.lexists(self.socket_path): return
        before = self.check(self.socket_path,stat.S_ISSOCK,0o600)
        probe = socket.socket(socket.AF_UNIX,socket.SOCK_STREAM); probe.settimeout(.2)
        try:
            probe.connect(str(self.socket_path))
        except OSError as exc:
            if exc.errno not in (errno.ECONNREFUSED,errno.ENOENT): raise ValueError('cannot confirm old socket is stale') from exc
        else: raise ValueError('another socket is active')
        finally: probe.close()
        try: after = self.check(self.socket_path,stat.S_ISSOCK,0o600)
        except FileNotFoundError: return
        if (before.st_dev,before.st_ino)!=(after.st_dev,after.st_ino): raise ValueError('socket changed while checking')
        self.socket_path.unlink()
    def write_key(self, key):
        path = self.root/('key.tmp-'+secrets.token_hex(12))
        fd = os.open(path,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
        try:
            with os.fdopen(fd,'wb') as out: out.write(key); out.flush(); os.fsync(out.fileno())
            os.replace(path,self.secret_path)
            info=self.check(self.secret_path,stat.S_ISREG,0o600); self.key_identity=(info.st_dev,info.st_ino)
        finally:
            try: path.unlink()
            except FileNotFoundError: pass
    def mark_socket(self):
        info=self.check(self.socket_path,stat.S_ISSOCK,0o600); self.socket_identity=(info.st_dev,info.st_ino)
    def release(self):
        for path, identity, kind in ((self.socket_path,self.socket_identity,stat.S_ISSOCK),(self.secret_path,self.key_identity,stat.S_ISREG)):
            if identity is None: continue
            try:
                info=self.check(path,kind,0o600)
                if (info.st_dev,info.st_ino)==identity: path.unlink()
            except (FileNotFoundError,ValueError): pass
        if self.lock_fd is not None: os.close(self.lock_fd); self.lock_fd=None

class Broker:
    def __init__(self, deadline=DEFAULT_DEADLINE, runtime_dir=None):
        self.stable = StableRuntime(runtime_dir) if runtime_dir else None
        self.root = self.stable.root if self.stable else Path(tempfile.mkdtemp(prefix='island-', dir='/tmp'))
        self.secret_path = self.root/'key'; self.socket_path = self.root/'broker.sock'
        self.key = secrets.token_bytes(32)
        self.listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            if self.stable: self.stable.write_key(self.key)
            else:
                fd = os.open(self.secret_path, os.O_CREAT|os.O_EXCL|os.O_WRONLY|os.O_NOFOLLOW, 0o600)
                with os.fdopen(fd,'wb') as file: file.write(self.key)
            self.listener.bind(str(self.socket_path)); os.chmod(self.socket_path,0o600)
            if self.stable: self.stable.mark_socket()
        except BaseException:
            self.listener.close()
            if self.stable: self.stable.release()
            raise
        self.listener.listen(MAX_CLIENTS); self.listener.setblocking(False)
        self.selector = selectors.DefaultSelector()
        self.selector.register(self.listener, selectors.EVENT_READ, 'listener')
        self.selector.register(sys.stdin.buffer, selectors.EVENT_READ, 'stdin')
        self.peers = {}        # socket -> connection state
        self.cards = {}        # nonce -> a pending request, in arrival order
        self.settling = {}     # nonce -> a decision delivered to its hook, awaiting Claude's outcome event
        self.unclaimed = []    # PreToolUse notes not yet tied to a permission request
        self.seen = set(); self.input = bytearray()
        self.deadline = deadline; self.running = True

    # --- Connection handling -------------------------------------------------
    def drop_peer(self, peer):
        self.peers.pop(peer, None)
        try: self.selector.unregister(peer)
        except Exception: pass
        peer.close()

    def resolve(self, nonce, reason):
        """End a pending card. Closing the socket makes the hook exit with no output."""
        card = self.cards.pop(nonce, None)
        if card is None: return
        emit({'type':'resolved', 'nonce':nonce, 'reason':reason})
        self.drop_peer(card['peer'])

    def accept(self):
        peer, _ = self.listener.accept(); peer.setblocking(False)
        if len(self.peers) >= MAX_CLIENTS: peer.close(); return
        self.peers[peer] = {'buffer':bytearray(), 'nonce':None, 'expires':time.monotonic()+10.0}
        self.selector.register(peer, selectors.EVENT_READ, 'peer')

    def peer_gone(self, peer, reason):
        nonce = self.peers.get(peer, {}).get('nonce')
        if nonce is not None and nonce in self.cards: self.resolve(nonce, reason)
        else: self.drop_peer(peer)

    def handle_peer(self, peer):
        try: chunk = peer.recv(65536)
        except OSError: self.peer_gone(peer, 'hook-gone'); return
        # EOF on a pending card means Claude cancelled the hook, or the hook gave up.
        if not chunk: self.peer_gone(peer, 'hook-gone'); return
        info = self.peers[peer]
        if info['nonce'] is not None: self.peer_gone(peer, 'protocol-error'); return
        buffer = info['buffer']; buffer.extend(chunk)
        if len(buffer) > MAX_FRAME: self.drop_peer(peer); emit({'type':'oversize'}); return
        if b'\n' not in buffer: return
        line, rest = bytes(buffer).split(b'\n', 1)
        if rest: self.drop_peer(peer); return
        try:
            message = json.loads(line)
            if not isinstance(message, dict): raise ValueError()
            if set(message) == {'event','mac'}: self.lifecycle(message); self.drop_peer(peer); return
            if set(message) != {'request','mac'}: raise ValueError()
            card = self.parse_request(message)
        except (ValueError,TypeError,KeyError,UnicodeError): self.drop_peer(peer); return
        nonce = card['nonce']
        self.seen.add(nonce); info['nonce'] = nonce; info['expires'] = None
        card.update(peer=peer, tool_use_id=self.claim_tool_use(card), expires=time.monotonic()+min(self.deadline, card['wait_seconds']+5))
        self.cards[nonce] = card
        emit({'type':'request', 'source':card.get('source', 'claude'), 'nonce':nonce, 'session_id':card['session_id'], 'tool_name':visible_text(card['tool_name']),
              'tool_input':visible(card['tool_input']),
              'tool_input_text':visible_text(json.dumps(card['tool_input'], indent=2, sort_keys=False, ensure_ascii=False)),
              'tool_use_id':card['tool_use_id'], 'agent_id':card.get('agent_id'), 'agent_type':card.get('agent_type'),
              'cwd':visible_text(card.get('cwd') or ''), 'permission_mode':card.get('permission_mode'),
              'permission_suggestions':visible(card.get('permission_suggestions') or []), 'mcp_server':visible(card.get('mcp_server'))})

    def parse_request(self, message):
        body = message['request']; mac = message['mac']
        if not isinstance(body, dict) or not isinstance(mac, str) or not hmac.compare_digest(signature(self.key, body), mac): raise ValueError()
        nonce, sid, tool, tool_input = body['nonce'], body['session_id'], body['tool_name'], body['tool_input']
        if body['version'] != PROTOCOL or body['kind'] != 'permission': raise ValueError()
        if not isinstance(nonce, str) or not NONCE.fullmatch(nonce) or nonce in self.seen or len(self.seen) >= MAX_SEEN: raise ValueError()
        if not isinstance(sid, str) or not SESSION_ID.fullmatch(sid): raise ValueError()
        if not isinstance(tool, str) or not 0 < len(tool) <= 256 or not isinstance(tool_input, dict): raise ValueError()
        source = body.get('source', 'claude')
        if not isinstance(source, str) or not re.fullmatch('[a-z][a-z0-9-]{0,31}', source): raise ValueError()
        wait = body.get('wait_seconds')
        if isinstance(wait, bool) or not isinstance(wait, (int, float)) or not 0 < wait <= MAX_DEADLINE: raise ValueError()
        return dict(body)

    # --- Tying a request to its tool call --------------------------------------
    def claim_tool_use(self, card):
        """PermissionRequest carries no tool_use_id, but its PreToolUse note does. Calls with an
        identical session, agent, tool and input are interchangeable, so oldest-first is safe."""
        key = (card.get('source', 'claude'), card['session_id'], card.get('agent_id'), card['tool_name'], card['input_digest'])
        for index, note in enumerate(self.unclaimed):
            if note['key'] == key:
                del self.unclaimed[index]
                return note['tool_use_id']
        return None

    def lifecycle(self, message):
        body = message['event']; mac = message['mac']
        if not isinstance(body, dict) or not isinstance(mac, str) or not hmac.compare_digest(signature(self.key, body), mac): raise ValueError()
        if body.get('version') != PROTOCOL or body.get('kind') != 'lifecycle': raise ValueError()
        name, sid = body.get('name'), body.get('session_id')
        if not isinstance(name, str) or not isinstance(sid, str) or not SESSION_ID.fullmatch(sid): raise ValueError()
        agent, tool, tool_use_id, digest = body.get('agent_id'), body.get('tool_name'), body.get('tool_use_id'), body.get('input_digest')
        source = body.get('source', 'claude')  # The installed Claude hook predates this field.
        if not isinstance(source, str) or not re.fullmatch('[a-z][a-z0-9-]{0,31}', source): raise ValueError()
        if name == 'PreToolUse':
            if isinstance(tool_use_id, str):
                now = time.monotonic()
                self.unclaimed = [n for n in self.unclaimed if now - n['at'] < UNCLAIMED_TTL][-MAX_UNCLAIMED:]
                self.unclaimed.append({'key':(source, sid, agent, tool, digest), 'tool_use_id':tool_use_id, 'at':now})
        elif name in ('PostToolUse', 'PostToolUseFailure'):
            self.tool_finished(sid, agent, tool, tool_use_id, digest, bool(body.get('is_error')))
        elif name in TURN_OVER:
            self.turn_over(sid, name)
        cwd, notification, pid = body.get('cwd'), body.get('notification_type'), body.get('pid')
        emit({'type':'lifecycle', 'source':source, 'name':name, 'session_id':sid, 'agent_id':agent, 'tool_name':tool if isinstance(tool, str) else None,
              'tool_use_id':tool_use_id if isinstance(tool_use_id, str) else None, 'cwd':visible_text(cwd) if isinstance(cwd, str) else None,
              'pid':pid if isinstance(pid, int) and not isinstance(pid, bool) and 0 < pid < 2**31 else None,
              'notification_type':notification if isinstance(notification, str) else None})

    def tool_finished(self, sid, agent, tool, tool_use_id, digest, is_error):
        def same_call(card):
            if card['session_id'] != sid or card.get('agent_id') != agent or card['tool_name'] != tool: return False
            if tool_use_id and card.get('tool_use_id'): return card['tool_use_id'] == tool_use_id
            return card['input_digest'] == digest
        self.unclaimed = [n for n in self.unclaimed if n['tool_use_id'] != tool_use_id]
        for nonce, card in list(self.settling.items()):
            if same_call(card):
                del self.settling[nonce]
                emit({'type':'confirmed', 'nonce':nonce, 'decision':card['decision'], 'is_error':is_error})
                return
        for nonce, card in list(self.cards.items()):
            if same_call(card):
                # Claude finished this call without an island click: someone else answered it.
                self.resolve(nonce, 'answered-elsewhere')
                return

    def turn_over(self, sid, name):
        # Only the main loop's cards are ended here: a subagent can outlive a user prompt event, and
        # a background subagent's command can still be running after the main turn has stopped.
        def ended(card):
            return card['session_id'] == sid and (name == 'SessionEnd' or not card.get('agent_id'))
        for nonce, card in list(self.cards.items()):
            if ended(card):
                self.resolve(nonce, 'turn-ended')
        for nonce, card in list(self.settling.items()):
            if ended(card):
                del self.settling[nonce]
                emit({'type':'unconfirmed', 'nonce':nonce, 'reason':name})

    # --- UI actions ---------------------------------------------------------
    def decide(self, command):
        nonce, decision = command.get('nonce'), command.get('decision')
        if not isinstance(nonce, str) or decision not in ('allow', 'deny', 'answer'): return
        card = self.cards.get(nonce)
        if card is None:
            emit({'type':'rejected', 'nonce':nonce, 'reason':'no-longer-pending'}); return
        body = {'version':PROTOCOL, 'nonce':nonce, 'decision':decision}
        message = command.get('message')
        if decision == 'deny' and isinstance(message, str) and message.strip():
            body['message'] = message.strip()
        suggestion = command.get('suggestion')
        if decision == 'allow' and suggestion is not None:
            # Adopt exactly one rule Claude itself offered for this request, by position.
            offered = card.get('permission_suggestions') or []
            if isinstance(suggestion, bool) or not isinstance(suggestion, int) or not 0 <= suggestion < len(offered):
                emit({'type':'rejected', 'nonce':nonce, 'reason':'invalid-suggestion'}); return
            body['updated_permissions'] = [offered[suggestion]]
        if decision == 'answer':
            answers = command.get('answers')
            if not isinstance(answers, dict) or not answers or not all(isinstance(k, str) and isinstance(v, str) for k, v in answers.items()):
                emit({'type':'rejected', 'nonce':nonce, 'reason':'invalid-answers'}); return
            body['updated_input'] = {**card['tool_input'], 'answers':answers}
        frame = canonical({'response':body, 'mac':signature(self.key, body)}) + b'\n'
        peer = card['peer']
        try:
            peer.setblocking(True); peer.settimeout(1.0); peer.sendall(frame)
        except OSError:
            self.resolve(nonce, 'delivery-failed'); return
        del self.cards[nonce]
        # Codex is hooked for PermissionRequest only, so no outcome event will come. "Delivered" is
        # the last thing that can truthfully be said about it.
        if card.get('source', 'claude') != 'codex':
            self.settling[nonce] = {**{k:card.get(k) for k in ('session_id','agent_id','tool_name','input_digest','tool_use_id')},
                                    'decision':decision, 'at':time.monotonic()}
        # Delivered to the hook only. Claude's own outcome arrives later as 'confirmed'.
        emit({'type':'delivered', 'nonce':nonce, 'decision':decision})
        self.drop_peer(peer)

    def handle_action(self, line):
        try: command = json.loads(line)
        except ValueError: return
        if not isinstance(command, dict): return
        if command.get('op') == 'decision': self.decide(command)
        # The app declines to handle this request. The hook exits with no output and no decision.
        elif command.get('op') == 'release' and isinstance(command.get('nonce'), str): self.resolve(command['nonce'], 'released')

    def process_stdin(self):
        try: chunk = os.read(sys.stdin.fileno(), 65536)
        except OSError: self.running = False; return
        if not chunk: self.running = False; return
        self.input.extend(chunk)
        if len(self.input) > MAX_FRAME: self.running = False; return
        while b'\n' in self.input:
            line, _, remainder = self.input.partition(b'\n'); self.input = bytearray(remainder)
            self.handle_action(line)

    def tick(self):
        now = time.monotonic()
        for peer, info in list(self.peers.items()):
            if info['expires'] is not None and now >= info['expires']: self.drop_peer(peer)
        for nonce, card in list(self.cards.items()):
            if now >= card['expires']: self.resolve(nonce, 'timeout')
        # A tool may run for a long time, so a missing outcome is reported, not treated as failure.
        for nonce, card in list(self.settling.items()):
            if now - card['at'] > self.deadline:
                del self.settling[nonce]; emit({'type':'unconfirmed', 'nonce':nonce, 'reason':'no-event'})

    def run(self):
        emit({'type':'ready', 'protocol':PROTOCOL, 'socket':str(self.socket_path), 'secret_file':str(self.secret_path)})
        while self.running:
            for key, _ in self.selector.select(timeout=0.2):
                if key.data == 'listener': self.accept()
                elif key.data == 'stdin': self.process_stdin()
                elif key.fileobj in self.peers: self.handle_peer(key.fileobj)
            self.tick()

    def close(self):
        for nonce in list(self.cards): self.resolve(nonce, 'shutdown')
        for peer in list(self.peers): self.drop_peer(peer)
        self.selector.close(); self.listener.close()
        if self.stable:
            self.stable.release()
        else:
            for path in (self.socket_path, self.secret_path):
                try: path.unlink()
                except FileNotFoundError: pass
            try: self.root.rmdir()
            except OSError: pass

def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser()
    parser.add_argument('--deadline', type=float, default=DEFAULT_DEADLINE)
    parser.add_argument('--runtime-dir', help='explicit private persistent runtime directory')
    args = parser.parse_args()
    if not 0 < args.deadline <= MAX_DEADLINE: parser.error('deadline out of range')
    broker = Broker(args.deadline, args.runtime_dir)
    def stop(_sig, _frame): broker.running = False
    signal.signal(signal.SIGTERM, stop); signal.signal(signal.SIGINT, stop)
    try: broker.run()
    finally: broker.close()

if __name__ == '__main__': main()
