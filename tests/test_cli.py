"""The parts of the CLI that work without Steam: status, verify, doctor,
install --dry-run and the parser surface. Everything runs in a temp HOME with
fake systemctl/steam, so nothing touches the real machine."""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LUNA = ROOT / 'scripts' / 'luna.py'


class CliTestCase(unittest.TestCase):
    def setUp(self):
        self.home = Path(tempfile.mkdtemp(prefix='luna-cli-'))
        self.addCleanup(shutil.rmtree, self.home, ignore_errors=True)
        self.bin = self.home / 'bin'
        self.bin.mkdir()
        self.log = self.home / 'systemctl.log'
        for name in ('systemctl', 'steam'):
            script = self.bin / name
            script.write_text('#!/bin/sh\necho "%s $*" >>"%s"\nexit 0\n' % (name, self.log))
            script.chmod(0o755)

    def luna(self, *args, **kwargs):
        env = dict(os.environ, HOME=str(self.home),
                   PATH='%s:%s' % (self.bin, os.environ.get('PATH', '')))
        env.pop('LUNA_HOME', None)
        return subprocess.run([sys.executable, str(LUNA)] + list(args),
                              capture_output=True, text=True, env=env,
                              cwd=str(ROOT), timeout=300, **kwargs)

    def fake_home(self):
        return self.home / '.local' / 'share' / 'Luna'

    def test_help_lists_the_public_commands(self):
        result = self.luna('--help')
        self.assertEqual(result.returncode, 0, result.stderr)
        for command in ('install', 'uninstall', 'status', 'verify', 'doctor',
                        'launchers', 'steam', 'update', 'release', 'backup',
                        'restore', 'timer', 'check'):
            self.assertIn(command, result.stdout)
        for gone in ('bootstrap', 'reconcile', 'update-all', 'vendor'):
            self.assertNotIn(' ' + gone + ' ', result.stdout)

    def test_verify_matches_the_manifest(self):
        result = self.luna('verify')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('OK: the payloads match the manifest.', result.stdout)

    def test_status_on_a_bare_home(self):
        result = self.luna('status')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('manifest   : 6 add-on(s) pinned', result.stdout)
        self.assertIn('new', result.stdout)

    def test_doctor_reports_a_bare_home(self):
        result = self.luna('doctor')
        self.assertIn('luna       :', result.stdout)
        self.assertIn('steam      :', result.stdout)

    def test_install_dry_run_writes_nothing(self):
        result = self.luna('install', '--dry-run')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('DRY RUN', result.stdout)
        self.assertFalse((self.fake_home() / 'addons').exists(), 'the dry run must not write payloads')
        self.assertFalse((self.fake_home() / 'bin').exists(), 'the dry run must not build')

    def test_install_writes_the_tree_and_the_unit(self):
        result = self.luna('install', '--no-steam-machine')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        home = self.fake_home()
        self.assertTrue((home / 'bin' / 'luna-host').is_file())
        self.assertTrue((home / 'lua' / 'luna' / 'boot.lua').is_file())
        for addon in ('playtime', 'presence', 'compressor', 'sgdb', 'graphics'):
            self.assertTrue((home / 'addons' / addon / 'plugin.json').is_file(), addon)
        unit = self.home / '.config/systemd/user/luna-host.service'
        self.assertIn('ExecStart=%s/bin/luna-host' % home, unit.read_text())
        self.assertIn('enable luna-host.service', self.log.read_text())
        launcher = self.home / '.local/bin/luna'
        self.assertTrue(launcher.is_file())
        self.assertIn('$LUNA_HOME/state/luna.py', launcher.read_text())
        status = self.luna('status')
        self.assertIn('host       : present', status.stdout)
        installed = self.luna('uninstall')
        self.assertEqual(installed.returncode, 0, installed.stdout + installed.stderr)
        self.assertFalse((home / 'addons' / 'playtime').exists())
        self.assertFalse(unit.exists())


if __name__ == '__main__':
    unittest.main()
