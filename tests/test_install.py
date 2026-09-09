"""Offline integration tests: every install targets a temporary directory."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest

REPO = Path(__file__).resolve().parents[1]
RUNNER = REPO / '.codex/skills/consensus/scripts/worker.sh'


class InstallTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='consensus-test-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.claude = self.root / 'claude'
        self.codex = self.root / 'codex'
        self.env = dict(os.environ, PATH=f'{self.bin}:{os.environ["PATH"]}',
                        CLAUDE_DIR=str(self.claude), CODEX_DIR=str(self.codex),
                        FIXTURE_REPO=str(REPO), TARGET='claude', REF='test-ref')
        self.env.pop('AI_CONSENSUS_WORKER_ACTIVE', None)
        self.script('curl', r'''
import os, pathlib, sys, time
args = sys.argv[1:]
url = next(a for a in args if a.startswith('https://'))
rel = url.split('/ai-consensus-skill/', 1)[1].split('/', 1)[1]
if os.environ.get('FAIL_DOWNLOAD') == rel:
    sys.exit(22)
if os.environ.get('HOOK_TEST'):
    if rel == 'VERSION':
        with open(os.environ['HOOK_CALLS'], 'a') as f: f.write('check\n')
        gate = os.environ.get('HOOK_GATE')
        if gate:
            pathlib.Path(gate + '.ready').touch()
            while not pathlib.Path(gate + '.release').exists(): time.sleep(.01)
        print('9.9.9')
    elif rel == 'install.sh':
        if os.environ.get('HOOK_REAL_INSTALL'):
            print((pathlib.Path(os.environ['FIXTURE_REPO']) / 'install.sh').read_text())
        else:
            print('printf "%s\\n" "$@" > "$HOOK_ARGS"')
    if rel in ('VERSION', 'install.sh'):
        sys.exit(0)
data = (pathlib.Path(os.environ['FIXTURE_REPO']) / rel).read_bytes()
if '-o' in args:
    pathlib.Path(args[args.index('-o') + 1]).write_bytes(data)
else:
    sys.stdout.buffer.write(data)
''')
        self.script('mv', r'''
import os, pathlib, shutil, sys, time
src, dst = [a for a in sys.argv[1:] if a != '-f']
if dst.endswith('/worker.sh') and not os.access(src, os.X_OK):
    sys.exit('runner published without executable permissions')
gate = os.environ.get('INSTALL_GATE')
if gate and dst.endswith('/consensus/SKILL.md'):
    pathlib.Path(gate + '.ready').touch()
    while not pathlib.Path(gate + '.release').exists(): time.sleep(.01)
shutil.move(src, dst)
''')

    def script(self, name, source):
        import sys
        p = self.bin / name
        p.write_text(f'#!{sys.executable}\n' + source)
        p.chmod(0o755)

    def install(self, target='both', **overrides):
        return subprocess.run(['/bin/bash', str(REPO / 'install.sh'), '--target', target],
                              env=dict(self.env, **overrides), capture_output=True,
                              text=True, timeout=20)

    def assert_ok(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def wait_file(self, path):
        deadline = time.monotonic() + 10
        while not path.exists():
            if time.monotonic() > deadline:
                self.fail(f'timed out waiting for {path}')
            time.sleep(.01)

    def background(self, command, env):
        log = (self.root / f'process-{time.time_ns()}.log').open('w+')
        proc = subprocess.Popen(command, env=env, stdout=log, stderr=log)
        def cleanup():
            if proc.poll() is None:
                proc.kill()
            proc.wait(timeout=10)
            log.close()
        self.addCleanup(cleanup)
        return proc

    def test_both_and_reinstall_publish_same_executable_runner(self):
        self.assert_ok(self.install())
        for target in (self.claude, self.codex):
            runner = target / 'skills/consensus/scripts/worker.sh'
            self.assertEqual(runner.read_bytes(), RUNNER.read_bytes())
            self.assertFalse(runner.is_symlink())
            self.assertTrue(os.access(runner, os.X_OK))
            self.assertFalse((target / '.ai-consensus-skill.install-lock').exists())
            self.assertIn('ref=test-ref', (target / '.ai-consensus-skill.version').read_text())
        self.assert_ok(self.install())
        settings = json.loads((self.claude / 'settings.json').read_text())
        self.assertEqual(len(settings['hooks']['SessionStart']), 1)

    def test_claude_only_installs_shared_runner_without_codex_target(self):
        self.assert_ok(self.install('claude'))
        self.assertFalse(self.codex.exists())
        self.assertEqual((self.claude / 'skills/consensus/scripts/worker.sh').read_bytes(),
                         RUNNER.read_bytes())

    def test_download_failure_leaves_existing_install_unchanged(self):
        self.assert_ok(self.install())
        before = {str(p): p.read_bytes() for p in self.root.rglob('*') if p.is_file()}
        result = self.install(FAIL_DOWNLOAD='.codex/skills/consensus/scripts/worker.sh')
        self.assertNotEqual(result.returncode, 0)
        after = {str(p): p.read_bytes() for p in self.root.rglob('*') if p.is_file()}
        self.assertEqual(before, after)

    def test_second_target_busy_releases_first_without_publishing(self):
        lock = self.codex / '.ai-consensus-skill.install-lock'
        lock.mkdir(parents=True)
        result = self.install()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('locked', result.stderr)
        self.assertTrue(lock.exists())
        self.assertFalse((self.claude / '.ai-consensus-skill.install-lock').exists())
        self.assertFalse((self.claude / 'skills').exists())

    def test_concurrent_installer_cannot_publish_into_locked_target(self):
        gate = self.root / 'install-gate'
        proc = self.background(['/bin/bash', str(REPO / 'install.sh'), '--target', 'both'],
                               dict(self.env, INSTALL_GATE=str(gate)))
        self.wait_file(Path(str(gate) + '.ready'))
        try:
            peer = self.install('codex')
            self.assertNotEqual(peer.returncode, 0)
            self.assertIn('locked', peer.stderr)
            self.assertFalse((self.codex / 'skills').exists())
        finally:
            Path(str(gate) + '.release').touch()
        self.assertEqual(proc.wait(timeout=20), 0)
        self.assertFalse((self.codex / '.ai-consensus-skill.install-lock').exists())

    def test_signal_during_lock_acquisition_cleans_owned_lock(self):
        self.script('mkdir', r'''
import os, signal, subprocess, sys
rc = subprocess.call(['/bin/mkdir', *sys.argv[1:]])
if rc == 0 and any(a.endswith('.ai-consensus-skill.install-lock') for a in sys.argv[1:]):
    os.kill(os.getppid(), signal.SIGTERM)
sys.exit(rc)
''')
        result = self.install('claude')
        self.assertEqual(result.returncode, 143)
        self.assertFalse((self.claude / '.ai-consensus-skill.install-lock').exists())
        self.assertFalse((self.claude / 'skills').exists())

    def test_signal_during_hook_lock_acquisition_cleans_owned_lock(self):
        self.script('mkdir', r'''
import os, signal, subprocess, sys
rc = subprocess.call(['/bin/mkdir', *sys.argv[1:]])
if rc == 0 and any(a.endswith('.ai-consensus-skill.update-lock') for a in sys.argv[1:]):
    os.kill(os.getppid(), signal.SIGTERM)
sys.exit(rc)
''')
        result = subprocess.run(['/bin/bash', str(REPO / '.claude/scripts/ai-consensus-check-update.sh')],
                                env=self.hook_env(), capture_output=True, text=True, timeout=10)
        self.assert_ok(result)
        self.assertFalse((self.claude / '.ai-consensus-skill.update-lock').exists())
        self.assertFalse((self.root / 'calls').exists())

    def test_alias_paths_share_lock(self):
        self.codex.mkdir()
        alias = self.root / 'alias'
        alias.symlink_to(self.codex, target_is_directory=True)
        (self.codex / '.ai-consensus-skill.install-lock').mkdir()
        result = self.install('codex', CODEX_DIR=str(alias))
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((self.codex / '.ai-consensus-skill.install-lock').exists())

    def hook_env(self, **overrides):
        self.claude.mkdir(exist_ok=True)
        (self.claude / '.ai-consensus-skill.version').write_text('version=1.0.0\nref=main\n')
        return dict(self.env, HOOK_TEST='1', HOOK_ARGS=str(self.root / 'args'),
                    HOOK_CALLS=str(self.root / 'calls'), AI_CONSENSUS_AUTO_UPDATE='1',
                    AI_CONSENSUS_UPDATE_INTERVAL='1', **overrides)

    def test_update_hook_explicitly_targets_claude(self):
        for target in ('codex', 'both'):
            with self.subTest(target=target):
                stamp = self.claude / '.ai-consensus-skill.update-check'
                stamp.unlink(missing_ok=True)
                result = subprocess.run(['/bin/bash', str(REPO / '.claude/scripts/ai-consensus-check-update.sh')],
                                        env=self.hook_env(TARGET=target), capture_output=True,
                                        text=True, timeout=10)
                self.assert_ok(result)
                self.assertEqual((self.root / 'args').read_text(), '--target\nclaude\n')

    def test_manual_pin_during_auto_update_is_preserved(self):
        gate = self.root / 'hook-gate'
        env = self.hook_env(HOOK_GATE=str(gate), HOOK_REAL_INSTALL='1')
        cmd = ['/bin/bash', str(REPO / '.claude/scripts/ai-consensus-check-update.sh')]
        proc = self.background(cmd, env)
        self.wait_file(Path(str(gate) + '.ready'))
        try:
            self.assert_ok(self.install('claude', REF='my-pinned-branch'))
            state = (self.claude / '.ai-consensus-skill.version').read_bytes()
            self.assertIn(b'ref=my-pinned-branch', state)
        finally:
            Path(str(gate) + '.release').touch()
        self.assertEqual(proc.wait(timeout=20), 0)
        self.assertEqual((self.claude / '.ai-consensus-skill.version').read_bytes(), state)
        output = next(self.root.glob('process-*.log')).read_text()
        self.assertIn('auto-update skipped', output)
        self.assertNotIn('auto-updated', output)
        self.assertFalse((self.claude / '.ai-consensus-skill.install-lock').exists())

    def test_unchanged_auto_update_state_allows_install(self):
        self.assert_ok(self.install('claude'))
        state = (self.claude / '.ai-consensus-skill.version').read_text().rstrip('\n')
        self.assert_ok(self.install('claude', REF='new-release',
                                   AI_CONSENSUS_EXPECTED_CLAUDE_STATE=state))
        self.assertIn('ref=new-release', (self.claude / '.ai-consensus-skill.version').read_text())

    def test_concurrent_hooks_only_check_once(self):
        gate = self.root / 'hook-gate'
        env = self.hook_env(HOOK_GATE=str(gate))
        cmd = ['/bin/bash', str(REPO / '.claude/scripts/ai-consensus-check-update.sh')]
        proc = self.background(cmd, env)
        self.wait_file(Path(str(gate) + '.ready'))
        try:
            peer = subprocess.run(cmd, env=env, capture_output=True, text=True, timeout=5)
            self.assert_ok(peer)
            self.assertEqual(peer.stdout, '')
        finally:
            Path(str(gate) + '.release').touch()
        self.assertEqual(proc.wait(timeout=10), 0)
        self.assertEqual((self.root / 'calls').read_text(), 'check\n')
        self.assertFalse((self.claude / '.ai-consensus-skill.update-lock').exists())

    def test_nested_worker_fails_before_launching_cli(self):
        prompt = self.root / 'prompt'
        prompt.write_text('review')
        result = subprocess.run(['/bin/bash', str(RUNNER), 'codex', '--prompt-file', str(prompt)],
                                env=dict(self.env, AI_CONSENSUS_WORKER_ACTIVE='1'),
                                capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 1)
        self.assertIn('[Codex FAILED] nested consensus worker invocation refused', result.stdout)

    def test_child_receives_guard_and_unique_output_files(self):
        self.script('codex', r'''
import os, pathlib, sys, time
assert os.environ.get('AI_CONSENSUS_WORKER_ACTIVE') == '1'
args = sys.argv
out = pathlib.Path(args[args.index('-o') + 1])
prompt = sys.stdin.read()
assert 'You are a delegated reviewer.' in prompt
# Overlap invocations so reused output paths would produce a wrong answer.
time.sleep(.1)
out.write_text(prompt.rsplit('\n', 1)[-1])
''')
        jobs = []
        for i in range(2):
            prompt = self.root / f'prompt-{i}'
            prompt.write_text(f'answer-{i}')
            jobs.append(subprocess.Popen(['/bin/bash', str(RUNNER), 'codex', '--prompt-file',
                                          str(prompt), '--cwd', str(self.root), '--effort', 'high'],
                                         env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                         text=True))
        for i, job in enumerate(jobs):
            out, err = job.communicate(timeout=10)
            self.assertEqual(job.returncode, 0, err)
            self.assertEqual(out, f'[Codex effort=high]\nanswer-{i}\n')


if __name__ == '__main__':
    unittest.main()
