import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / 'scripts' / 'claude_hooks_config.py'

class HookConfigTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.path = Path(self.tmp.name) / 'settings.json'

    def tearDown(self):
        self.tmp.cleanup()

    def call(self, action, port=True):
        args = [sys.executable, str(SCRIPT), '--settings', str(self.path)]
        if port: args.extend(['--port', '34567'])
        args.append(action)
        return subprocess.run(args, capture_output=True, text=True)

    def test_preserves_other_hooks_and_restores(self):
        original = {'theme': 'dark', 'hooks': {'SessionStart': [{'hooks': [{'type': 'command', 'command': 'echo test'}]}]}}
        raw = json.dumps(original).encode()
        self.path.write_bytes(raw)
        result = self.call('plan'); self.assertEqual(result.returncode, 0); self.assertEqual(self.path.read_bytes(), raw)
        result = self.call('install'); self.assertEqual(result.returncode, 0)
        self.assertEqual(Path(json.loads(result.stdout)['backup']).read_bytes(), raw)
        self.assertFalse(json.loads(self.call('install').stdout)['changed'])
        result = self.call('remove', False); self.assertEqual(result.returncode, 0)
        self.assertEqual(json.loads(self.path.read_text()), original)

    def test_empty_root_restored(self):
        self.path.write_text('{}')
        self.assertEqual(self.call('install').returncode, 0)
        self.assertEqual(self.call('remove', False).returncode, 0)
        self.assertEqual(json.loads(self.path.read_text()), {})

    def test_invalid_hook_is_rejected_without_writes(self):
        raw = b'{"hooks":{"Stop":null}}'
        self.path.write_bytes(raw)
        result = self.call('install')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.path.read_bytes(), raw)
        self.assertNotIn('Traceback', result.stderr)

    def test_invalid_json_is_rejected_without_writes(self):
        raw = b'{broken'
        self.path.write_bytes(raw)
        self.assertNotEqual(self.call('install').returncode, 0)
        self.assertEqual(self.path.read_bytes(), raw)

if __name__ == '__main__': unittest.main()
