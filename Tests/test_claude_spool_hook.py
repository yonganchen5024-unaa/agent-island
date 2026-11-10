import concurrent.futures, json, os, subprocess, sys, tempfile, unittest
from pathlib import Path
SCRIPT = Path(__file__).resolve().parents[1] / 'scripts' / 'claude_spool_hook.py'
PAYLOAD = {'session_id':'6a23744f-577f-4da6-9c19-66035cd2a001','hook_event_name':'PermissionRequest','prompt':'PRIVATE_SECRET','tool_input':{'path':'PRIVATE_PATH'}}
class Checks(unittest.TestCase):
 def setUp(self):
  self.temp = tempfile.TemporaryDirectory(); self.root = Path(self.temp.name).resolve(); self.spool = self.root/'queue'; self.spool.mkdir(mode=0o700)
 def tearDown(self): self.temp.cleanup()
 def send(self, payload=PAYLOAD, root=None, spool=None):
  p = subprocess.run([sys.executable,str(SCRIPT),'--root',str(root or self.root),'--spool',str(spool or self.spool)],input=json.dumps(payload),text=True,capture_output=True,timeout=3)
  self.assertEqual(p.returncode,0); self.assertEqual(p.stdout,''); self.assertEqual(p.stderr,'')
 def test_minimal_signal(self):
  self.send(); raw=(self.spool/'events.ndjson').read_text(); self.assertNotIn('PRIVATE',raw)
  o=json.loads(raw); self.assertEqual(set(o),{'v','id','session_id','event','time'}); self.assertEqual(o['event'],'PermissionRequest')
  self.assertEqual((self.spool/'events.ndjson').stat().st_mode & 0o777,0o600)
 def test_symlink_and_fifo_are_not_followed_or_blocking(self):
  target=self.root/'target'; target.write_text('unchanged'); (self.spool/'events.ndjson').symlink_to(target)
  self.send(); self.assertEqual(target.read_text(),'unchanged')
  (self.spool/'events.ndjson').unlink(); os.mkfifo(self.spool/'events.ndjson',0o600)
  self.send(); self.assertTrue((self.spool/'events.ndjson').is_fifo())
 def test_outside_and_untrusted_dir(self):
  outside=self.root.parent/'not-an-island-target'; self.send(spool=outside)
  self.spool.chmod(0o755); self.send(); self.assertFalse((self.spool/'events.ndjson').exists())
 def test_hardlink_and_symlink_directory_are_rejected(self):
  target = self.root/'target'; target.write_text('unchanged'); target.chmod(0o600)
  os.link(target,self.spool/'events.ndjson'); self.send(); self.assertEqual(target.read_text(),'unchanged')
  (self.spool/'events.ndjson').unlink(); self.spool.rmdir(); self.spool.symlink_to(self.root, target_is_directory=True)
  self.send(); self.assertFalse((self.root/'events.ndjson').exists())
 def test_capacity_and_unrecognized_are_fail_closed(self):
  dest=self.spool/'events.ndjson'; dest.write_bytes(b'x'*262144); dest.chmod(0o600)
  self.send(); self.assertEqual(dest.stat().st_size,262144)
  self.send({'session_id':PAYLOAD['session_id'],'hook_event_name':'MadeUp'})
  self.assertEqual(dest.stat().st_size,262144)
 def test_concurrent_writers_do_not_interleave(self):
  with concurrent.futures.ThreadPoolExecutor(max_workers=12) as pool:
   list(pool.map(lambda _: self.send(), range(40)))
  lines=(self.spool/'events.ndjson').read_text().splitlines()
  self.assertGreater(len(lines),0)
  for line in lines: self.assertEqual(json.loads(line)['event'],'PermissionRequest')
if __name__ == '__main__': unittest.main()
