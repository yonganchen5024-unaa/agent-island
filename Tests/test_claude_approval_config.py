import json,subprocess,sys,tempfile,unittest
from pathlib import Path
SCRIPT=Path(__file__).resolve().parents[1]/'scripts'/'claude_approval_config.py'
class Tests(unittest.TestCase):
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory();self.root=Path(self.tmp.name);self.p=self.root/'settings.json';self.runtime=self.root/'run'
 def tearDown(self):self.tmp.cleanup()
 def run_cli(self,action,runtime=True):
  a=[sys.executable,str(SCRIPT),'--settings',str(self.p)];a+=['--runtime-dir',str(self.runtime)] if runtime else [];a += [action]
  return subprocess.run(a,text=True,capture_output=True)
 def test_preserves_other_hooks_and_uninstalls(self):
  before={'theme':'dark','hooks':{'PermissionRequest':[{'matcher':'Bash','hooks':[{'type':'command','command':'existing'}]}],'Stop':[]}}
  raw=json.dumps(before).encode();self.p.write_bytes(raw)
  a=self.run_cli('plan');self.assertEqual(a.returncode,0);self.assertEqual(self.p.read_bytes(),raw);handler=json.loads(a.stdout)['planned_handler'];self.assertEqual(handler['timeout'],125)
  a=self.run_cli('install');self.assertEqual(a.returncode,0);self.assertEqual(Path(json.loads(a.stdout)['backup']).read_bytes(),raw)
  self.assertFalse(json.loads(self.run_cli('install').stdout)['changed'])
  self.assertEqual(self.run_cli('remove',False).returncode,0);self.assertEqual(json.loads(self.p.read_text()),before)
 def test_missing_root_and_empty_event_roundtrip(self):
  for before in ({},{'hooks':{}},{'hooks':{'PermissionRequest':[]}}):
   self.p.write_text(json.dumps(before));self.assertEqual(self.run_cli('install').returncode,0);self.assertEqual(self.run_cli('remove',False).returncode,0);self.assertEqual(json.loads(self.p.read_text()),before)
 def test_invalid_and_symlink_unchanged(self):
  for data in ('broken','{"hooks":{"PermissionRequest":null}}'):
   self.p.write_text(data);r=self.run_cli('install');self.assertNotEqual(r.returncode,0);self.assertEqual(self.p.read_text(),data)
  target=self.root/'target';target.write_text('{}');self.p.unlink();self.p.symlink_to(target);self.assertNotEqual(self.run_cli('install').returncode,0);self.assertEqual(target.read_text(),'{}')
