#!/usr/bin/env python3
"""Write minimal Claude hook signals to an explicitly selected private spool.

Pass --root and --spool as absolute paths; spool must be a private existing
subdirectory of root. No paths, prompts, tool input or credentials are written.
All failures are silent and exit 0 so observation cannot affect Claude's action.
This is unauthenticated, one-way status data, NEVER an approval mechanism.
"""
import fcntl
import json
import os
import re
import stat
import sys
import time
import uuid

CAP = 262144
MAX_INPUT = 1048576
EVENTS = frozenset(('SessionStart','UserPromptSubmit','PreToolUse','PostToolUse','PostToolUseFailure','PermissionRequest','Notification','Stop','StopFailure','SessionEnd'))
NOTIFICATIONS = frozenset(('permission_prompt','idle_prompt','elicitation_dialog','elicitation_url_dialog'))
SID = re.compile(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')


def open_directory(path):
    if not os.path.isabs(path) or any(x in ('.','..') for x in path.split('/') if x):
        raise ValueError('absolute canonical path required')
    fd = os.open('/',os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
    try:
        for part in (x for x in path.split('/') if x):
            newfd = os.open(part,os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,dir_fd=fd)
            os.close(fd); fd = newfd
        return fd
    except BaseException:
        os.close(fd); raise


def run():
    if len(sys.argv) != 5 or sys.argv[1] != '--root' or sys.argv[3] != '--spool': return
    root, spool = sys.argv[2].rstrip('/'), sys.argv[4].rstrip('/')
    if not root or not spool.startswith(root + '/'):
        return
    # Opening every component without following symlinks also avoids a path
    # escaping the selected root through an intermediate link.
    dirfd = open_directory(root)
    try:
        for part in spool[len(root)+1:].split('/'):
            if not part or part in ('.', '..'): return
            nextfd = os.open(part,os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,dir_fd=dirfd)
            os.close(dirfd); dirfd = nextfd
        d = os.fstat(dirfd)
        if d.st_uid != os.getuid() or stat.S_IMODE(d.st_mode) & 0o077: return
        raw = sys.stdin.buffer.read(MAX_INPUT + 1)
        if len(raw) > MAX_INPUT: return
        value = json.loads(raw)
        if not isinstance(value,dict) or value.get('agent_id'): return
        sid, event = value.get('session_id'), value.get('hook_event_name')
        if not isinstance(sid,str) or not SID.fullmatch(sid) or event not in EVENTS: return
        record = {'v':1,'id':str(uuid.uuid4()),'session_id':sid.lower(),'event':event,'time':time.time()}
        if event == 'Notification':
            typ = value.get('notification_type')
            if typ not in NOTIFICATIONS: return
            record['notification_type'] = typ
        data = (json.dumps(record,separators=(',',':'))+'\n').encode()
        fd = os.open('events.ndjson',os.O_WRONLY | os.O_CREAT | os.O_APPEND | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK,0o600,dir_fd=dirfd)
        try:
            st = os.fstat(fd)
            if not stat.S_ISREG(st.st_mode) or st.st_uid != os.getuid() or stat.S_IMODE(st.st_mode) & 0o077 or st.st_nlink != 1: return
            try: fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
            except BlockingIOError: return
            old_size = os.fstat(fd).st_size
            if old_size + len(data) > CAP: return
            # One append call under flock prevents cooperating writers interleaving.
            written = os.write(fd,data)
            if written != len(data):
                os.ftruncate(fd, old_size)
                return
        finally: os.close(fd)
    finally: os.close(dirfd)

if __name__ == '__main__':
    try: run()
    except (SystemExit, OSError, ValueError, TypeError, UnicodeError): pass
