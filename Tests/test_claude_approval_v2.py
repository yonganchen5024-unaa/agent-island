"""Protocol v2 tests for the approval hook and broker, with fictional requests only.
Sockets live under /private/tmp/cc-socks, where the app keeps its real runtime directory; some
agent sandboxes only allow Unix sockets there."""
import hashlib, hmac, json, os, select, shutil, signal, socket, stat, subprocess, sys, tempfile, time, unittest
from pathlib import Path

BASE = Path(__file__).resolve().parents[1] / 'scripts'
BROKER, HOOK = BASE / 'claude_approval_broker.py', BASE / 'claude_approval_hook.py'
PY = '/usr/bin/python3'
SOCKS = '/private/tmp/cc-socks'


def canon(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=True).encode('ascii')


def sign(key, value):
    return hmac.new(key, canon(value), hashlib.sha256).hexdigest()


def digest(value):
    return hashlib.sha256(canon(value)).hexdigest()


def event(tool_input=None, session='s-1', tool='Bash', **extra):
    return {'hook_event_name': 'PermissionRequest', 'session_id': session, 'tool_name': tool,
            'tool_input': {'command': 'echo fictional'} if tool_input is None else tool_input, **extra}


class Base(unittest.TestCase):
    def setUp(self):
        os.makedirs(SOCKS, mode=0o700, exist_ok=True)
        self.temp = tempfile.mkdtemp(prefix='t-', dir=SOCKS)
        self.runtime = os.path.join(self.temp, 'rt')
        self.procs = []

    def tearDown(self):
        for proc in self.procs:
            if proc.poll() is None:
                proc.kill()
            proc.wait()
            for stream in (proc.stdin, proc.stdout, proc.stderr):
                if stream and not stream.closed:
                    stream.close()
        shutil.rmtree(self.temp, ignore_errors=True)

    def spawn_broker(self, *args):
        proc = subprocess.Popen([PY, '-I', '-u', str(BROKER), '--runtime-dir', self.runtime, *args],
                                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0)
        self.procs.append(proc)
        return proc

    def read(self, proc, timeout=4):
        ready, _, _ = select.select([proc.stdout], [], [], timeout)
        self.assertTrue(ready, 'broker produced no event')
        raw = bytearray()
        while not raw.endswith(b'\n'):
            chunk = os.read(proc.stdout.fileno(), 1)
            self.assertTrue(chunk, 'broker closed')
            raw.extend(chunk)
        return json.loads(raw)

    def read_type(self, proc, kind, timeout=4):
        end = time.time() + timeout
        while time.time() < end:
            message = self.read(proc, max(0.01, end - time.time()))
            if message['type'] == kind:
                return message
        self.fail('no %s event' % kind)

    def silent(self, proc, seconds=0.2):
        return not select.select([proc.stdout], [], [], seconds)[0]

    def hook(self, payload, *args, env=None):
        proc = subprocess.Popen([PY, '-I', str(HOOK), '--runtime', self.runtime, '--timeout', '30', *args],
                                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
        self.procs.append(proc)
        proc.stdin.write(json.dumps(payload).encode() if not isinstance(payload, bytes) else payload)
        proc.stdin.close()
        return proc

    def action(self, broker, **fields):
        broker.stdin.write((json.dumps({'op': 'decision', **fields}) + '\n').encode())

    def finish(self, hook):
        out = hook.stdout.read()
        self.assertEqual(hook.wait(timeout=5), 0)
        self.assertEqual(hook.stderr.read(), b'')
        return json.loads(out)['hookSpecificOutput']['decision'] if out else None

    def note(self, broker, name, session='s-1', **extra):
        self.read_type(broker, 'lifecycle') if False else None
        payload = {'hook_event_name': name, 'session_id': session, **extra}
        self.assertEqual(self.finish(self.hook(payload)), None)


class Decisions(Base):
    def test_allow_and_deny_are_one_shot(self):
        broker = self.spawn_broker()
        self.read_type(broker, 'ready')
        first, second = self.hook(event(session='first')), self.hook(event(session='second'))
        a, b = self.read_type(broker, 'request'), self.read_type(broker, 'request')
        self.assertNotEqual(a['nonce'], b['nonce'])
        for card in (a, b):
            self.action(broker, nonce=card['nonce'], decision='allow' if card['session_id'] == 'first' else 'deny', message='FICTIONAL 原因')
        self.assertEqual(self.finish(first), {'behavior': 'allow'})
        self.assertEqual(self.finish(second), {'behavior': 'deny', 'message': 'FICTIONAL 原因'})
        self.read_type(broker, 'delivered'); self.read_type(broker, 'delivered')
        self.action(broker, nonce=a['nonce'], decision='deny')
        self.assertEqual(self.read_type(broker, 'rejected')['reason'], 'no-longer-pending')

    def test_default_deny_message_is_not_empty(self):
        broker = self.spawn_broker(); self.read_type(broker, 'ready')
        hook = self.hook(event()); card = self.read_type(broker, 'request')
        self.action(broker, nonce=card['nonce'], decision='deny')
        self.assertTrue(self.finish(hook)['message'])

    def test_release_ends_the_hook_with_no_decision(self):
        broker = self.spawn_broker(); self.read_type(broker, 'ready')
        hook = self.hook(event()); card = self.read_type(broker, 'request')
        broker.stdin.write((json.dumps({'op': 'release', 'nonce': card['nonce']}) + '\n').encode())
        self.assertEqual(self.read_type(broker, 'resolved')['reason'], 'released')
        self.assertIsNone(self.finish(hook))

    def test_unknown_decision_and_nonce_do_nothing(self):
        broker = self.spawn_broker(); self.read_type(broker, 'ready')
        hook = self.hook(event()); card = self.read_type(broker, 'request')
        self.action(broker, nonce=card['nonce'], decision='maybe')
        self.action(broker, nonce='c' * 64, decision='allow')
        self.assertEqual(self.read_type(broker, 'rejected')['nonce'], 'c' * 64)
        self.assertIsNone(hook.poll())
        self.action(broker, nonce=card['nonce'], decision='allow')
        self.assertEqual(self.finish(hook), {'behavior': 'allow'})

    def test_answers_may_only_add_answers(self):
        questions = {'questions': [{'question': 'Q?', 'options': [{'label': 'A'}]}]}
        broker = self.spawn_broker(); self.read_type(broker, 'ready')
        hook = self.hook(event(questions, tool='AskUserQuestion')); card = self.read_type(broker, 'request')
        self.action(broker, nonce=card['nonce'], decision='answer', answers={'Q?': 'A'})
        self.assertEqual(self.finish(hook), {'behavior': 'allow', 'updatedInput': {**questions, 'answers': {'Q?': 'A'}}})

    def test_always_uses_only_a_suggestion_claude_offered(self):
        rule = {'type': 'addRules', 'rules': [{'toolName': 'Bash', 'ruleContent': 'echo:*'}], 'behavior': 'allow', 'destination': 'session'}
        broker = self.spawn_broker(); self.read_type(broker, 'ready')
        hook = self.hook(event(permission_suggestions=[rule])); card = self.read_type(broker, 'request')
        self.action(broker, nonce=card['nonce'], decision='allow', suggestion=5)
        self.assertEqual(self.read_type(broker, 'rejected')['reason'], 'invalid-suggestion')
        self.action(broker, nonce=card['nonce'], decision='allow', suggestion=0)
        self.assertEqual(self.finish(hook), {'behavior': 'allow', 'updatedPermissions': [rule]})


class FakeBroker(Base):
    """A hostile or broken server: the hook must print nothing unless the reply is exactly valid."""

    def run_reply(self, reply_for, payload=None):
        os.mkdir(self.runtime, 0o700)
        key = b'k' * 32
        path = os.path.join(self.runtime, 'key')
        fd = os.open(path, os.O_WRONLY | os.O_CREAT, 0o600); os.write(fd, key); os.close(fd)
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        server.bind(os.path.join(self.runtime, 'broker.sock')); os.chmod(os.path.join(self.runtime, 'broker.sock'), 0o600); server.listen(1)
        hook = self.hook(payload or event())
        server.settimeout(4)
        conn, _ = server.accept()
        data = bytearray()
        while not data.endswith(b'\n'):
            data.extend(conn.recv(65536))
        request = json.loads(data)['request']
        conn.sendall(reply_for(key, request))
        conn.close(); server.close()
        return self.finish(hook)

    def frame(self, key, body, mac=None):
        return canon({'response': body, 'mac': mac or sign(key, body)}) + b'\n'

    def test_valid_reply_is_accepted(self):
        self.assertEqual(self.run_reply(lambda k, r: self.frame(k, {'version': 2, 'nonce': r['nonce'], 'decision': 'allow'})), {'behavior': 'allow'})

    def test_bad_mac(self):
        self.assertIsNone(self.run_reply(lambda k, r: self.frame(k, {'version': 2, 'nonce': r['nonce'], 'decision': 'allow'}, '0' * 64)))

    def test_wrong_nonce(self):
        self.assertIsNone(self.run_reply(lambda k, r: self.frame(k, {'version': 2, 'nonce': 'e' * 64, 'decision': 'allow'})))

    def test_wrong_version(self):
        self.assertIsNone(self.run_reply(lambda k, r: self.frame(k, {'version': 1, 'nonce': r['nonce'], 'decision': 'allow'})))

    def test_unknown_decision(self):
        self.assertIsNone(self.run_reply(lambda k, r: self.frame(k, {'version': 2, 'nonce': r['nonce'], 'decision': 'ask'})))

    def test_garbage(self):
        self.assertIsNone(self.run_reply(lambda k, r: b'{not json\n'))

    def test_answer_that_changes_questions_is_refused(self):
        questions = {'questions': [{'question': 'Q?'}]}
        reply = lambda k, r: self.frame(k, {'version': 2, 'nonce': r['nonce'], 'decision': 'answer', 'updated_input': {'questions': [{'question': 'Other?'}], 'answers': {'Q?': 'A'}}})
        self.assertIsNone(self.run_reply(reply, event(questions, tool='AskUserQuestion')))

    def test_answer_that_adds_fields_is_refused(self):
        questions = {'questions': [{'question': 'Q?'}]}
        reply = lambda k, r: self.frame(k, {'version': 2, 'nonce': r['nonce'], 'decision': 'answer', 'updated_input': {**questions, 'answers': {'Q?': 'A'}, 'extra': 1}})
        self.assertIsNone(self.run_reply(reply, event(questions, tool='AskUserQuestion')))

    def test_rule_claude_did_not_offer_is_refused(self):
        rule = {'type': 'addRules', 'rules': [{'toolName': 'Bash'}], 'behavior': 'allow', 'destination': 'userSettings'}
        reply = lambda k, r: self.frame(k, {'version': 2, 'nonce': r['nonce'], 'decision': 'allow', 'updated_permissions': [rule]})
        self.assertIsNone(self.run_reply(reply))


class Failures(Base):
    def test_no_broker_returns_immediately_with_no_output(self):
        started = time.time()
        self.assertIsNone(self.finish(self.hook(event())))
        self.assertLess(time.time() - started, 2)

    def test_unsafe_runtime_is_refused(self):
        os.mkdir(self.runtime, 0o755)
        self.assertIsNone(self.finish(self.hook(event())))

    def test_malformed_stdin_is_silent(self):
        self.assertIsNone(self.finish(self.hook(b'{not json')))
        self.assertIsNone(self.finish(self.hook(b'[1,2]')))

    def test_bad_fields_are_silent(self):
        broker = self.spawn_broker(); self.read_type(broker, 'ready')
        for payload in (event(session='bad session!'), event(tool=''), {**event(), 'tool_input': 'text'}):
            self.assertIsNone(self.finish(self.hook(payload)))
        self.assertTrue(self.silent(broker))

    def test_managed_mode_refuses_an_untrusted_install(self):
        broker = self.spawn_broker(); self.read_type(broker, 'ready')
        hook = self.hook(event(), '--managed', '--target-uid', str(os.getuid()))
        self.assertIsNone(self.finish(hook))
        self.assertTrue(self.silent(broker))

    def test_invalid_mac_is_not_published(self):
        broker = self.spawn_broker(); self.read_type(broker, 'ready')
        request = {'version': 2, 'kind': 'permission', 'nonce': 'a' * 64, 'session_id': 's', 'tool_name': 'Bash', 'tool_input': {}, 'input_digest': digest({}), 'wait_seconds': 5}
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); conn.settimeout(2)
        conn.connect(os.path.join(self.runtime, 'broker.sock'))
        conn.sendall(canon({'request': request, 'mac': '0' * 64}) + b'\n')
        self.assertEqual(conn.recv(1), b''); conn.close()
        self.assertTrue(self.silent(broker))

    def test_replayed_nonce_is_not_published_twice(self):
        broker = self.spawn_broker(); self.read_type(broker, 'ready')
        key = Path(self.runtime, 'key').read_bytes()
        request = {'version': 2, 'kind': 'permission', 'nonce': 'b' * 64, 'session_id': 's', 'tool_name': 'Bash', 'tool_input': {}, 'input_digest': digest({}), 'wait_seconds': 5}
        frame = canon({'request': request, 'mac': sign(key, request)}) + b'\n'
        first = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); first.connect(os.path.join(self.runtime, 'broker.sock')); first.sendall(frame)
        self.assertEqual(self.read_type(broker, 'request')['nonce'], 'b' * 64)
        again = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); again.settimeout(2); again.connect(os.path.join(self.runtime, 'broker.sock')); again.sendall(frame)
        self.assertEqual(again.recv(1), b''); again.close(); first.close()
        self.assertEqual(self.read_type(broker, 'resolved')['reason'], 'hook-gone')

    def test_hook_exits_quietly_on_sigterm_and_card_ends(self):
        broker = self.spawn_broker(); self.read_type(broker, 'ready')
        hook = self.hook(event()); self.read_type(broker, 'request')
        hook.send_signal(signal.SIGTERM)
        self.assertIsNone(self.finish(hook))
        self.assertEqual(self.read_type(broker, 'resolved')['reason'], 'hook-gone')

    def test_hook_exits_when_claude_process_is_gone(self):
        broker = self.spawn_broker(); self.read_type(broker, 'ready')
        fake_claude = subprocess.Popen(['/bin/sleep', '60'])
        hook = self.hook(event(), env={'CLAUDE_PID': str(fake_claude.pid)})
        self.read_type(broker, 'request')
        fake_claude.kill(); fake_claude.wait()
        self.assertIsNone(self.finish(hook))
        self.assertEqual(self.read_type(broker, 'resolved', 5)['reason'], 'hook-gone')

    def test_broker_death_releases_the_hook(self):
        broker = self.spawn_broker(); self.read_type(broker, 'ready')
        hook = self.hook(event()); self.read_type(broker, 'request')
        broker.kill(); broker.wait()
        self.assertIsNone(self.finish(hook))

    def test_card_times_out(self):
        broker = self.spawn_broker('--deadline', '0.5'); self.read_type(broker, 'ready')
        hook = self.hook(event()); self.read_type(broker, 'request')
        self.assertEqual(self.read_type(broker, 'resolved')['reason'], 'timeout')
        self.assertIsNone(self.finish(hook))


class Correlation(Base):
    def setUp(self):
        super().setUp()
        self.broker = self.spawn_broker()
        self.read_type(self.broker, 'ready')

    def pre(self, tool_use_id, tool_input=None, session='s-1', agent=None):
        payload = {'hook_event_name': 'PreToolUse', 'session_id': session, 'tool_name': 'Bash', 'tool_use_id': tool_use_id,
                   'tool_input': {'command': 'echo fictional'} if tool_input is None else tool_input}
        if agent:
            payload['agent_id'] = agent
        self.assertIsNone(self.finish(self.hook(payload)))
        self.read_type(self.broker, 'lifecycle')

    def post(self, tool_use_id, tool_input=None, response=None, session='s-1', agent=None):
        payload = {'hook_event_name': 'PostToolUse', 'session_id': session, 'tool_name': 'Bash', 'tool_use_id': tool_use_id,
                   'tool_input': {'command': 'echo fictional'} if tool_input is None else tool_input, 'tool_response': response if response is not None else {'stdout': ''}}
        if agent:
            payload['agent_id'] = agent
        self.assertIsNone(self.finish(self.hook(payload)))

    def test_request_is_tied_to_its_tool_use_id(self):
        self.pre('toolu_1')
        self.hook(event())
        self.assertEqual(self.read_type(self.broker, 'request')['tool_use_id'], 'toolu_1')

    def test_identical_calls_claim_ids_oldest_first(self):
        self.pre('toolu_a'); self.pre('toolu_b')
        self.hook(event()); self.hook(event())
        ids = {self.read_type(self.broker, 'request')['tool_use_id'] for _ in range(2)}
        self.assertEqual(ids, {'toolu_a', 'toolu_b'})

    def test_answered_elsewhere_ends_only_that_card(self):
        self.pre('toolu_a'); self.pre('toolu_b', {'command': 'echo other'})
        first = self.hook(event()); second = self.hook(event({'command': 'echo other'}))
        self.read_type(self.broker, 'request'); self.read_type(self.broker, 'request')
        self.post('toolu_a')
        self.assertEqual(self.read_type(self.broker, 'resolved')['reason'], 'answered-elsewhere')
        self.assertIsNone(self.finish(first))
        self.assertIsNone(second.poll())

    def test_post_without_id_falls_back_to_input_digest(self):
        hook = self.hook(event()); self.read_type(self.broker, 'request')
        self.assertIsNone(self.finish(self.hook({'hook_event_name': 'PostToolUse', 'session_id': 's-1', 'tool_name': 'Bash', 'tool_input': {'command': 'echo fictional'}, 'tool_response': {}})))
        self.assertEqual(self.read_type(self.broker, 'resolved')['reason'], 'answered-elsewhere')
        self.assertIsNone(self.finish(hook))

    def test_other_session_and_agent_do_not_end_a_card(self):
        self.pre('toolu_1')
        hook = self.hook(event()); self.read_type(self.broker, 'request')
        self.post('toolu_9', session='s-2')
        self.post('toolu_8', agent='agent-1')
        self.assertIsNone(hook.poll())

    def test_decision_is_confirmed_only_by_claudes_event(self):
        self.pre('toolu_1')
        hook = self.hook(event()); card = self.read_type(self.broker, 'request')
        self.action(self.broker, nonce=card['nonce'], decision='allow')
        self.assertEqual(self.read_type(self.broker, 'delivered')['decision'], 'allow')
        self.assertEqual(self.finish(hook), {'behavior': 'allow'})
        self.assertTrue(self.silent(self.broker))
        self.post('toolu_1')
        confirmed = self.read_type(self.broker, 'confirmed')
        self.assertEqual((confirmed['decision'], confirmed['is_error']), ('allow', False))

    def test_denial_outcome_is_flagged_as_error(self):
        self.pre('toolu_1')
        self.hook(event()); card = self.read_type(self.broker, 'request')
        self.action(self.broker, nonce=card['nonce'], decision='deny')
        self.read_type(self.broker, 'delivered')
        self.post('toolu_1', response='Error: FICTIONAL')
        self.assertTrue(self.read_type(self.broker, 'confirmed')['is_error'])

    def test_stop_ends_main_loop_cards_but_not_subagent_cards(self):
        main = self.hook(event()); self.read_type(self.broker, 'request')
        sub = self.hook(event(agent_id='agent-1')); self.read_type(self.broker, 'request')
        self.assertIsNone(self.finish(self.hook({'hook_event_name': 'Stop', 'session_id': 's-1'})))
        self.assertEqual(self.read_type(self.broker, 'resolved')['reason'], 'turn-ended')
        self.assertIsNone(self.finish(main))
        self.assertIsNone(sub.poll())
        self.assertIsNone(self.finish(self.hook({'hook_event_name': 'SessionEnd', 'session_id': 's-1'})))
        self.assertEqual(self.read_type(self.broker, 'resolved')['reason'], 'turn-ended')
        self.assertIsNone(self.finish(sub))

    def test_stop_reports_an_unconfirmed_decision(self):
        self.hook(event()); card = self.read_type(self.broker, 'request')
        self.action(self.broker, nonce=card['nonce'], decision='allow')
        self.read_type(self.broker, 'delivered')
        self.assertIsNone(self.finish(self.hook({'hook_event_name': 'Stop', 'session_id': 's-1'})))
        self.assertEqual(self.read_type(self.broker, 'unconfirmed')['reason'], 'Stop')

    def test_main_stop_leaves_a_subagent_decision_waiting_for_its_result(self):
        self.hook(event(agent_id='agent-1')); card = self.read_type(self.broker, 'request')
        self.action(self.broker, nonce=card['nonce'], decision='allow')
        self.read_type(self.broker, 'delivered')
        for name in ('Stop', 'StopFailure', 'UserPromptSubmit'):
            self.assertIsNone(self.finish(self.hook({'hook_event_name': name, 'session_id': 's-1'})))
        self.post('toolu_none', agent='agent-1')
        confirmed = self.read_type(self.broker, 'confirmed')
        self.assertEqual((confirmed['nonce'], confirmed['decision'], confirmed['is_error']), (card['nonce'], 'allow', False))

    def test_session_end_still_closes_a_subagent_decision(self):
        self.hook(event(agent_id='agent-1')); card = self.read_type(self.broker, 'request')
        self.action(self.broker, nonce=card['nonce'], decision='allow')
        self.read_type(self.broker, 'delivered')
        self.assertIsNone(self.finish(self.hook({'hook_event_name': 'SessionEnd', 'session_id': 's-1'})))
        self.assertEqual(self.read_type(self.broker, 'unconfirmed')['reason'], 'SessionEnd')

    def test_lifecycle_frames_carry_no_tool_content(self):
        os.makedirs(self.temp + '/spy', mode=0o700)
        spy_runtime = self.temp + '/spy/rt'
        os.mkdir(spy_runtime, 0o700)
        path = spy_runtime + '/key'; fd = os.open(path, os.O_WRONLY | os.O_CREAT, 0o600); os.write(fd, b'k' * 32); os.close(fd)
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); server.bind(spy_runtime + '/broker.sock'); os.chmod(spy_runtime + '/broker.sock', 0o600); server.listen(1); server.settimeout(3)
        payload = {'hook_event_name': 'PostToolUse', 'session_id': 's-1', 'tool_name': 'Bash', 'tool_use_id': 't', 'tool_input': {'command': 'FICTIONAL_SECRET_INPUT'}, 'tool_response': {'stdout': 'FICTIONAL_SECRET_OUTPUT'}, 'prompt': 'FICTIONAL_SECRET_PROMPT'}
        proc = subprocess.Popen([PY, '-I', str(HOOK), '--runtime', spy_runtime], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE); self.procs.append(proc)
        proc.stdin.write(json.dumps(payload).encode()); proc.stdin.close()
        conn, _ = server.accept(); data = conn.recv(65536); conn.close(); server.close()
        self.assertNotIn(b'FICTIONAL_SECRET', data)


class Sources(Base):
    def test_codex_decision_is_only_ever_delivered(self):
        broker = self.spawn_broker(); self.read_type(broker, 'ready')
        self.hook(event(), '--source', 'codex'); card = self.read_type(broker, 'request')
        self.action(broker, nonce=card['nonce'], decision='allow')
        self.read_type(broker, 'delivered')
        self.assertIsNone(self.finish(self.hook({'hook_event_name': 'SessionEnd', 'session_id': 's-1'})))
        # A decision left "settling" would be reported as unconfirmed here, just before the lifecycle event.
        self.assertEqual(self.read(broker)['type'], 'lifecycle')

    def test_codex_hand_back_ends_the_hook_with_no_decision(self):
        broker = self.spawn_broker(); self.read_type(broker, 'ready')
        proc = self.hook(event(), '--source', 'codex'); card = self.read_type(broker, 'request')
        self.action(broker, nonce=card['nonce'], op='release')
        self.assertEqual(self.read_type(broker, 'resolved')['reason'], 'released')
        self.assertIsNone(self.finish(proc))

    def test_lifecycle_passes_the_adapter_pid_only_when_valid(self):
        broker = self.spawn_broker(); self.read_type(broker, 'ready')
        note = {'hook_event_name': 'Stop', 'session_id': 's-1'}
        self.finish(self.hook(note, '--source', 'dsh', env={'AGENT_ISLAND_PID': '4242'}))
        self.assertEqual(self.read_type(broker, 'lifecycle')['pid'], 4242)
        self.finish(self.hook(note, '--source', 'dsh', env={'AGENT_ISLAND_PID': 'not-a-pid'}))
        self.assertIsNone(self.read_type(broker, 'lifecycle')['pid'])
        self.finish(self.hook(note, '--source', 'dsh'))
        self.assertIsNone(self.read_type(broker, 'lifecycle')['pid'])

    def test_source_reaches_the_card_and_lifecycle(self):
        broker = self.spawn_broker(); self.read_type(broker, 'ready')
        self.hook(event(), '--source', 'kimi')
        self.assertEqual(self.read_type(broker, 'request')['source'], 'kimi')
        self.assertIsNone(self.finish(self.hook({'hook_event_name': 'SessionStart', 'session_id': 'ses_1', 'cwd': '/fictional/project'}, '--source', 'opencode')))
        note = self.read_type(broker, 'lifecycle')
        self.assertEqual((note['source'], note['name'], note['cwd']), ('opencode', 'SessionStart', '/fictional/project'))

    def test_frames_from_the_installed_claude_hook_still_work(self):
        # The managed copy sends no source field. It is what real Claude sessions run.
        broker = self.spawn_broker(); self.read_type(broker, 'ready')
        installed = Path(__file__).resolve().parents[1] / 'deliverables' / 'Claude受管审批方案' / 'managed_approval_hook.py'
        if not installed.exists():
            self.skipTest('the older managed hook copy is kept locally only')
        proc = subprocess.Popen([PY, '-I', str(installed), '--runtime', self.runtime, '--timeout', '30'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.procs.append(proc)
        proc.stdin.write(json.dumps(event()).encode()); proc.stdin.close()
        card = self.read_type(broker, 'request')
        self.assertEqual(card['source'], 'claude')
        self.action(broker, nonce=card['nonce'], decision='allow')
        self.assertEqual(self.finish(proc), {'behavior': 'allow'})

    def test_bad_source_is_silent(self):
        broker = self.spawn_broker(); self.read_type(broker, 'ready')
        self.assertIsNone(self.finish(self.hook(event(), '--source', 'Bad Source!')))
        self.assertTrue(self.silent(broker))

    def test_same_digest_in_other_source_does_not_claim_tool_use_id(self):
        broker = self.spawn_broker(); self.read_type(broker, 'ready')
        self.assertIsNone(self.finish(self.hook({'hook_event_name': 'PreToolUse', 'session_id': 's-1', 'tool_name': 'Bash', 'tool_use_id': 'toolu_x', 'tool_input': {'command': 'echo fictional'}}, '--source', 'kimi')))
        self.read_type(broker, 'lifecycle')
        self.hook(event())
        self.assertIsNone(self.read_type(broker, 'request')['tool_use_id'])


class Display(Base):
    def test_full_input_and_invisible_characters_are_visible(self):
        broker = self.spawn_broker(); self.read_type(broker, 'ready')
        text = 'echo a‮b​c 中文\n第二行'
        self.hook(event({'command': text}))
        card = self.read_type(broker, 'request')
        self.assertIn('\\u202e', card['tool_input_text']); self.assertIn('\\u200b', card['tool_input_text'])
        self.assertNotIn('‮', card['tool_input_text'])
        self.assertIn('中文', card['tool_input_text'])
        self.assertEqual(card['tool_input']['command'], 'echo a\\u202eb\\u200bc 中文\n第二行')

    def test_large_input_is_delivered_whole(self):
        broker = self.spawn_broker(); self.read_type(broker, 'ready')
        body = 'x' * (2 * 1024 * 1024)
        hook = self.hook(event({'content': body}))
        card = self.read_type(broker, 'request', 8)
        self.assertEqual(card['tool_input']['content'], body)
        self.action(broker, nonce=card['nonce'], decision='deny')
        self.assertEqual(self.finish(hook)['behavior'], 'deny')

    def test_lone_surrogate_does_not_break_the_channel(self):
        broker = self.spawn_broker(); self.read_type(broker, 'ready')
        self.hook(b'{"hook_event_name":"PermissionRequest","session_id":"s","tool_name":"Bash","tool_input":{"command":"a\\ud800b"}}')
        card = self.read_type(broker, 'request')
        self.assertIn('\\ud800', card['tool_input_text'])


class Runtime(Base):
    def test_singleton_restart_rotates_key_and_cleans_up(self):
        one = self.spawn_broker(); self.read_type(one, 'ready')
        old = Path(self.runtime, 'key').read_bytes()
        self.assertEqual(stat.S_IMODE(os.stat(self.runtime).st_mode), 0o700)
        self.assertEqual(stat.S_IMODE(os.lstat(self.runtime + '/broker.sock').st_mode), 0o600)
        second = self.spawn_broker(); self.assertNotEqual(second.wait(timeout=4), 0); self.assertIsNone(one.poll())
        one.kill(); one.wait()
        new = self.spawn_broker(); self.read_type(new, 'ready')
        self.assertNotEqual(Path(self.runtime, 'key').read_bytes(), old)
        new.stdin.close(); self.assertEqual(new.wait(timeout=4), 0)
        self.assertFalse(os.path.exists(self.runtime + '/broker.sock')); self.assertFalse(os.path.exists(self.runtime + '/key'))

    def test_missing_parent_directory_is_created_privately(self):
        self.runtime = os.path.join(self.temp, 'missing-parent', 'rt')
        broker = self.spawn_broker(); self.read_type(broker, 'ready')
        self.assertEqual(stat.S_IMODE(os.stat(os.path.dirname(self.runtime)).st_mode), 0o700)

    def test_symlink_and_unmarked_directory_are_refused(self):
        os.symlink(self.temp, self.runtime)
        self.assertNotEqual(self.spawn_broker().wait(timeout=4), 0); os.unlink(self.runtime)
        os.mkdir(self.runtime, 0o700); Path(self.runtime, 'unrelated').write_text('safe')
        self.assertNotEqual(self.spawn_broker().wait(timeout=4), 0)
        self.assertEqual(Path(self.runtime, 'unrelated').read_text(), 'safe')


if __name__ == '__main__':
    unittest.main()
