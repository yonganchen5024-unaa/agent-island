#!/usr/bin/env python3
"""Nonblocking, observation-only Claude CLI hook; never emits a decision.

The only argument is an explicit absolute private runtime directory. Every failure
is intentionally silent and exits 0, allowing Claude's normal flow to continue.
"""
import json, os, re, secrets, socket, sys, time
from pathlib import Path
from claude_approval_hook import canonical, mac, owned_restricted, read_secret
import stat

EVENTS={'SessionStart','UserPromptSubmit','PreToolUse','PostToolUse','PostToolUseFailure','Stop','StopFailure','SessionEnd','Notification','PermissionRequest'}
NOTIFICATIONS={'permission_prompt','idle_prompt','elicitation_dialog','elicitation_url_dialog','agent_needs_input'}
MAX_INPUT=1048576

def main():
    if len(sys.argv)!=3 or sys.argv[1]!='--runtime-dir' or not os.path.isabs(sys.argv[2]): return
    try:
        root=Path(sys.argv[2]);sock_path=root/'broker.sock';key_path=root/'key'
        owned_restricted(root,stat.S_ISDIR); before=owned_restricted(sock_path,stat.S_ISSOCK); key=read_secret(key_path)
        raw=sys.stdin.buffer.read(MAX_INPUT+1)
        if len(raw)>MAX_INPUT:return
        value=json.loads(raw)
        if not isinstance(value,dict):return
        sid=value.get('session_id'); name=value.get('hook_event_name')
        if not isinstance(sid,str) or not re.fullmatch(r'[A-Za-z0-9_-]{1,128}',sid) or name not in EVENTS:return
        item={'v':1,'nonce':secrets.token_hex(32),'session_id':sid,'event':name,'timestamp_ms':time.time_ns()//1_000_000,'is_subagent':bool(value.get('agent_id'))}
        if name=='Notification':
            subtype=value.get('notification_type')
            if subtype not in NOTIFICATIONS:return
            item['notification_type']=subtype
        message=canonical({'event':item,'mac':mac(key,item)})+b'\n'
        with socket.socket(socket.AF_UNIX,socket.SOCK_STREAM) as conn:
            conn.settimeout(.25);conn.connect(str(sock_path))
            after=owned_restricted(sock_path,stat.S_ISSOCK)
            if (before.st_dev,before.st_ino)!=(after.st_dev,after.st_ino):return
            conn.sendall(message)
    except (OSError,UnicodeError,TypeError,ValueError,KeyError,json.JSONDecodeError):return

if __name__=='__main__':main()
