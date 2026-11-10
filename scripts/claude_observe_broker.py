#!/usr/bin/env python3
"""Local observation-only Claude event broker, with explicit stable runtime.

Newline JSON on stdout; closes when stdin closes. No response or decision channel.
The shared key and Unix permissions do not authenticate against same-UID processes.
"""
import argparse, collections, hashlib, hmac, json, os, re, secrets, selectors, signal, socket, sys, time
from pathlib import Path
from claude_approval_broker import StableRuntime, canonical

EVENTS={'SessionStart','UserPromptSubmit','PreToolUse','PostToolUse','PostToolUseFailure','Stop','StopFailure','SessionEnd','Notification','PermissionRequest'}
NOTIFICATIONS={'permission_prompt','idle_prompt','elicitation_dialog','elicitation_url_dialog','agent_needs_input'}
MAX_FRAME=16384; MAX_PEERS=32; MAX_NONCES=8192; MAX_WINDOWS=4096

def emit(value):sys.stdout.buffer.write(canonical(value)+b'\n');sys.stdout.buffer.flush()
class Observer:
 def __init__(self,path):
  self.runtime=StableRuntime(path);self.listener=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM);self.key=secrets.token_bytes(32)
  try:
   self.runtime.write_key(self.key);self.listener.bind(str(self.runtime.socket_path));os.chmod(self.runtime.socket_path,0o600);self.runtime.mark_socket();self.listener.listen(MAX_PEERS);self.listener.setblocking(False)
   self.selector=selectors.DefaultSelector();self.selector.register(self.listener,selectors.EVENT_READ,'listener');self.selector.register(sys.stdin.buffer,selectors.EVENT_READ,'stdin')
  except BaseException:
   self.listener.close();self.runtime.release();raise
  self.peers={};self.nonces=collections.OrderedDict();self.windows=collections.OrderedDict();self.last_events=collections.OrderedDict();self.running=True
 def close_peer(self,peer):
  self.peers.pop(peer,None)
  try:self.selector.unregister(peer)
  except Exception:pass
  peer.close()
 def accept(self):
  peer,_=self.listener.accept();peer.setblocking(False)
  if len(self.peers)>=MAX_PEERS:peer.close();return
  self.peers[peer]={'data':bytearray(),'expiry':time.monotonic()+2};self.selector.register(peer,selectors.EVENT_READ,'peer')
 def handle(self,peer):
  try:data=peer.recv(4096)
  except OSError:self.close_peer(peer);return
  if not data:self.close_peer(peer);return
  b=self.peers[peer]['data'];b.extend(data)
  if len(b)>MAX_FRAME:self.close_peer(peer);return
  if b'\n' not in b:return
  line,rest=bytes(b).split(b'\n',1);self.close_peer(peer)
  if rest:return
  try:
   outer=json.loads(line);event=outer['event'];signature=outer['mac']
   if set(outer)!={'event','mac'} or not isinstance(event,dict):return
   needed={'v','nonce','session_id','event','timestamp_ms','is_subagent'}
   if set(event) not in (needed,needed|{'notification_type'}):return
   nonce=event['nonce'];sid=event['session_id'];name=event['event'];timestamp=event['timestamp_ms']
   if event['v']!=1 or not isinstance(nonce,str) or not re.fullmatch('[0-9a-f]{64}',nonce) or nonce in self.nonces:return
   if not isinstance(sid,str) or not re.fullmatch('[A-Za-z0-9_-]{1,128}',sid) or name not in EVENTS or not isinstance(event['is_subagent'],bool) or not isinstance(timestamp,int) or isinstance(timestamp,bool) or abs(time.time_ns()//1_000_000-timestamp)>30000:return
   if name=='Notification':
    if event.get('notification_type') not in NOTIFICATIONS:return
   elif 'notification_type' in event:return
   expected=hmac.new(self.key,canonical(event),hashlib.sha256).hexdigest()
   if not isinstance(signature,str) or not hmac.compare_digest(signature,expected):return
   now=time.monotonic()
   while self.nonces and next(iter(self.nonces.values()))<now-60:self.nonces.popitem(last=False)
   if len(self.nonces)>=MAX_NONCES:return
   self.nonces[nonce]=now
   # Reject older observed timestamps for each session/lane. Equal timestamps
   # remain arrival-ordered; clock skew and process scheduling remain unknown.
   while self.last_events and next(iter(self.last_events.values()))[1]<now-60:self.last_events.popitem(last=False)
   lane=(sid,event['is_subagent']);previous=self.last_events.get(lane)
   if previous is not None and timestamp<previous[0]:return
   self.last_events[lane]=(timestamp,now);self.last_events.move_to_end(lane)
   while len(self.last_events)>MAX_WINDOWS:self.last_events.popitem(last=False)
   # Limit repetitive tool updates only; lifecycle and approval signals survive bursts.
   if name in ('PreToolUse','PostToolUse','PostToolUseFailure'):
    k=(sid,name,event['is_subagent']); window=self.windows.get(k,collections.deque())
    while window and window[0]<now-1:window.popleft()
    if len(window)>=20:return
    window.append(now);self.windows[k]=window;self.windows.move_to_end(k)
    while len(self.windows)>MAX_WINDOWS:self.windows.popitem(last=False)
   result={'type':'claude_event','session_id':sid,'event':name,'timestamp_ms':timestamp,'is_subagent':event['is_subagent']}
   if name=='Notification':result['notification_type']=event['notification_type']
   emit(result)
  except (ValueError,TypeError,KeyError,json.JSONDecodeError):return
 def run(self):
  emit({'type':'ready','socket':str(self.runtime.socket_path)})
  while self.running:
   for key,_ in self.selector.select(.2):
    if key.data=='listener':self.accept()
    elif key.data=='stdin':
     if not os.read(sys.stdin.fileno(),8192):self.running=False
    else:self.handle(key.fileobj)
   now=time.monotonic()
   for p,info in list(self.peers.items()):
    if now>info['expiry']:self.close_peer(p)
 def close(self):
  for p in list(self.peers):self.close_peer(p)
  self.selector.close();self.listener.close();self.runtime.release()
def main():
 os.umask(0o077);p=argparse.ArgumentParser();p.add_argument('--runtime-dir',required=True);a=p.parse_args()
 if not os.path.isabs(a.runtime_dir):p.error('runtime-dir must be absolute')
 obj=Observer(a.runtime_dir)
 def stop(_sig,_frame):obj.running=False
 signal.signal(signal.SIGTERM,stop);signal.signal(signal.SIGINT,stop)
 try:obj.run()
 finally:obj.close()
if __name__=='__main__':main()
