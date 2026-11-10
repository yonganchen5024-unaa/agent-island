#!/usr/bin/env python3
"""Explicit plan/install/remove for an experimental Claude approval hook.

No default settings path; plan is read-only. Never execute against real settings
without choosing the exact path and reviewing plan output. Uses a cooperative
lock and creates a backup, but cannot lock unrelated editors.
"""
import argparse
import copy
import json
import os
from pathlib import Path
import sys
import claude_hooks_config as shared

HOOK=str(Path(__file__).resolve().with_name('claude_approval_hook.py'))
PYTHON='/usr/bin/python3'
MARK='Agent Island approval bridge (experimental)'
MARK_MISSING='Agent Island approval bridge (original hooks absent)'
MARK_EMPTY='Agent Island approval bridge (original empty event)'
MARK_BOTH='Agent Island approval bridge (original hooks absent, empty event)'
MARKS=(MARK, MARK_MISSING, MARK_EMPTY, MARK_BOTH)

def ours(h):
    if not isinstance(h,dict) or h.get('type')!='command' or h.get('command')!=PYTHON or h.get('statusMessage') not in MARKS: return False
    a=h.get('args')
    return isinstance(a,list) and len(a)==7 and a[0]==HOOK and a[1]=='--socket' and a[3]=='--secret-file' and a[5:] == ['--timeout','120'] and isinstance(a[2],str) and isinstance(a[4],str) and a[2].endswith('/broker.sock') and a[4].endswith('/key') and Path(a[2]).parent==Path(a[4]).parent

def transform(original,action,runtime):
    data=copy.deepcopy(original); root_missing='hooks' not in data
    hooks=data.get('hooks',{})
    if not isinstance(hooks,dict):raise ValueError('hooks must be an object')
    existing='PermissionRequest' in hooks
    groups=hooks.get('PermissionRequest',[])
    if not isinstance(groups,list):raise ValueError('PermissionRequest hooks must be an array')
    empty_original=existing and not groups
    kept=[]; removed=0
    for group in groups:
        if not isinstance(group,dict) or not isinstance(group.get('hooks'),list):raise ValueError('malformed hook group')
        group=copy.deepcopy(group); handlers=group['hooks']
        for h in handlers:
            if ours(h):
                root_missing |= h.get('statusMessage') in (MARK_MISSING,MARK_BOTH)
                empty_original |= h.get('statusMessage') in (MARK_EMPTY,MARK_BOTH)
        group['hooks']=[h for h in handlers if not ours(h)]; removed += len(handlers)-len(group['hooks'])
        if len(handlers)!=len(group['hooks']) and not group['hooks'] and set(group)=={'hooks'}:continue
        kept.append(group)
    handler=None
    if action in ('plan','install'):
        label=MARK_BOTH if root_missing and empty_original else MARK_MISSING if root_missing else MARK_EMPTY if empty_original else MARK
        handler={'type':'command','command':PYTHON,'args':[HOOK,'--socket',str(runtime/'broker.sock'),'--secret-file',str(runtime/'key'),'--timeout','120'],'timeout':125,'statusMessage':label}
        kept.append({'hooks':[handler]})
    if kept: hooks['PermissionRequest']=kept
    elif removed and empty_original: hooks['PermissionRequest']=[]
    elif removed: hooks.pop('PermissionRequest',None)
    if hooks: data['hooks']=hooks
    elif removed and root_missing: data.pop('hooks',None)
    return data,removed,handler

def main():
    ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('action',nargs='?',choices=('plan','install','remove'),default='plan');ap.add_argument('--settings',required=True);ap.add_argument('--runtime-dir')
    a=ap.parse_args();path=Path(a.settings);runtime=Path(a.runtime_dir) if a.runtime_dir else None
    if not path.is_absolute():ap.error('--settings must be absolute')
    if a.action!='remove' and (runtime is None or not runtime.is_absolute() or len(os.fsencode(str(runtime/'broker.sock'))) > 103):ap.error('--runtime-dir must be absolute and socket path at most 103 bytes')
    lock=None
    try:
        if a.action!='plan':lock=shared.lock_for_write(path)
        raw,original,mode=shared.read_target(path);new,removed,handler=transform(original,a.action,runtime);changed=new!=original;backup=None
        if a.action!='plan' and changed:
            backup=shared.commit(path,raw,mode,(json.dumps(new,ensure_ascii=False,indent=2)+'\n').encode())
        print(json.dumps({'action':a.action,'path':str(path),'changed':changed,'removed_handlers':removed,'planned_handler':handler,'backup':backup},ensure_ascii=False))
    except (OSError,UnicodeError,ValueError,json.JSONDecodeError) as e:
        print('approval settings operation failed: '+str(e),file=sys.stderr);return 1
    finally:
        if lock is not None:os.close(lock)
    return 0
if __name__=='__main__':sys.exit(main())
