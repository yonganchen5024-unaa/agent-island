import hashlib,hmac,json,os,select,socket,subprocess,sys,tempfile,time,unittest
from pathlib import Path
S=Path(__file__).resolve().parents[1]/'scripts'; BROKER=S/'claude_observe_broker.py'; HOOK=S/'claude_observe_hook.py'; CONFIG=S/'claude_observe_config.py'
def canon(x):return json.dumps(x,sort_keys=True,separators=(',',':'),ensure_ascii=False).encode()
class ObserveTests(unittest.TestCase):
 def setUp(self):self.tmp=tempfile.TemporaryDirectory(prefix='obs-',dir='/tmp');self.root=Path(self.tmp.name)/'r';self.children=[]
 def tearDown(self):
  for p in self.children:
   if p.poll() is None:p.terminate()
   try:p.wait(timeout=3)
   except subprocess.TimeoutExpired:p.kill();p.wait()
   for f in (p.stdin,p.stdout,p.stderr):
    if f and not f.closed:f.close()
  self.tmp.cleanup()
 def spawn(self):
  p=subprocess.Popen([sys.executable,'-u',str(BROKER),'--runtime-dir',str(self.root)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,bufsize=0);self.children.append(p);return p
 def read(self,p,timeout=2):
  ready,_,_=select.select([p.stdout],[],[],timeout);self.assertTrue(ready);b=bytearray()
  while not b.endswith(b'\n'):
   c=os.read(p.stdout.fileno(),1);self.assertTrue(c);b.extend(c)
  return json.loads(b)
 def hook(self,event,subtype=None):
  value={'session_id':'fixture-123','hook_event_name':event,'prompt':'SECRET_PROMPT','tool_input':{'secret':'SECRET_TOOL'},'cwd':'SECRET_PATH'}
  if subtype:value['notification_type']=subtype
  start=time.monotonic();p=subprocess.run([sys.executable,str(HOOK),'--runtime-dir',str(self.root)],input=json.dumps(value),text=True,capture_output=True,timeout=2)
  self.assertEqual((p.returncode,p.stdout,p.stderr),(0,'',''));return time.monotonic()-start
 def send_wire(self,nonce,name='PreToolUse',key=None,timestamp=None):
  key=key or (self.root/'key').read_bytes();msg={'v':1,'nonce':nonce,'session_id':'fixture-123','event':name,'timestamp_ms':timestamp if timestamp is not None else time.time_ns()//1000000,'is_subagent':False}
  signature=hmac.new(key,canon(msg),hashlib.sha256).hexdigest()
  c=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM);c.settimeout(1);c.connect(str(self.root/'broker.sock'));c.sendall(canon({'event':msg,'mac':signature})+b'\n');c.close()
 def test_all_lifecycle_privacy_and_fast_permission(self):
  p=self.spawn();self.assertEqual(self.read(p)['type'],'ready')
  for name in ['SessionStart','UserPromptSubmit','PreToolUse','PostToolUse','PostToolUseFailure','Stop','StopFailure','SessionEnd','Notification','PermissionRequest']:
   t=self.hook(name,'permission_prompt' if name=='Notification' else None);event=self.read(p);self.assertEqual(event['event'],name);self.assertNotIn('SECRET',json.dumps(event));self.assertEqual(event['session_id'],'fixture-123')
   if name=='PermissionRequest':self.assertLess(t,1.0)
 def test_replay_throttle_and_priority(self):
  p=self.spawn();self.read(p)
  self.send_wire('a'*64);self.assertEqual(self.read(p)['event'],'PreToolUse')
  self.send_wire('a'*64);self.assertFalse(select.select([p.stdout],[],[],.1)[0])
  for i in range(19):self.send_wire(f'{i:064x}');self.read(p)
  self.send_wire('f'*64);self.assertFalse(select.select([p.stdout],[],[],.1)[0])
  self.send_wire('e'*64,'Stop');self.assertEqual(self.read(p)['event'],'Stop')
 def test_out_of_order_old_event_is_ignored(self):
  p=self.spawn();self.read(p);now=time.time_ns()//1000000
  self.send_wire('1'*64,'Stop',timestamp=now);self.assertEqual(self.read(p)['event'],'Stop')
  self.send_wire('2'*64,'PreToolUse',timestamp=now-1000);self.assertFalse(select.select([p.stdout],[],[],.1)[0])
 def test_singleton_crash_restart_and_fallback(self):
  p=self.spawn();ready=self.read(p);old=(self.root/'key').read_bytes();second=self.spawn();self.assertNotEqual(second.wait(timeout=2),0)
  p.kill();p.wait(timeout=2);self.assertLess(self.hook('PermissionRequest'),1.0)
  new=self.spawn();self.assertEqual(self.read(new)['socket'],ready['socket']);self.assertNotEqual(old,(self.root/'key').read_bytes())
  self.send_wire('d'*64,key=old);self.assertFalse(select.select([new.stdout],[],[],.1)[0]);self.hook('SessionStart');self.assertEqual(self.read(new)['event'],'SessionStart')
  new.stdin.close();new.wait(timeout=2);self.assertFalse((self.root/'broker.sock').exists());self.assertFalse((self.root/'key').exists())
 def test_installer_plan_idempotence_preserves(self):
  settings=Path(self.tmp.name)/'settings.json';before={'x':1,'hooks':{'PermissionRequest':[{'hooks':[{'type':'command','command':'original'}]}]}};raw=json.dumps(before).encode();settings.write_bytes(raw)
  def call(action,with_root=True):
   a=[sys.executable,str(CONFIG),'--settings',str(settings)];a+=['--runtime-dir',str(self.root)] if with_root else [];a += [action];return subprocess.run(a,text=True,capture_output=True)
  p=call('plan');self.assertEqual(p.returncode,0);self.assertEqual(settings.read_bytes(),raw);self.assertEqual(len(json.loads(p.stdout)['events']),10);self.assertEqual(json.loads(p.stdout)['planned_handlers']['PermissionRequest'][0]['args'][1:],['--runtime-dir',str(self.root)])
  p=call('install');self.assertEqual(p.returncode,0);self.assertEqual(Path(json.loads(p.stdout)['backup']).read_bytes(),raw)
  self.assertFalse(json.loads(call('install').stdout)['changed']);self.assertEqual(call('remove',False).returncode,0);self.assertEqual(json.loads(settings.read_text()),before)
