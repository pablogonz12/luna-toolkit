#!/usr/bin/env python3
#!/usr/bin/env python3
"""Luna - Steam add-on host and tools.

luna-host attaches to a normally launched Steam over its CEF debugging port and
loads the add-ons from $LUNA_HOME/addons into the client's UI. This command
installs, verifies and maintains that tree.

usage:
    luna install [--only NAME] [--dry-run] [--force]
                                        write the add-ons and the host unit
    luna uninstall [--only NAME]        remove them again
    luna status [--strict]              what is installed and whether it drifted
    luna verify                         payloads against vendor/MANIFEST.json
    luna doctor                         environment diagnostics
    luna launchers [--dry-run]          SteamOS Mode launcher shortcuts
    luna steam status|pin|unpin|cache|recover|update|cancel|lock|unlock|history
                                        pin and roll back the Steam client build
    luna release [--out DIR] [--publish]  build a bundle tarball (+ sha256)
    luna update --bundle FILE | --url URL | --latest [--dry-run]
                                        verify and install a released bundle
    luna backup [--out DIR]             snapshot Luna's data (playtime, presence,
                                        HLTB, SGDB key, artwork, settings)
    luna restore ARCHIVE [--force]      restore a backup
    luna timer on|off|status            unattended update check
    luna check [--force]                update check as JSON (used by the menu)

Exit codes (scripts can rely on these):
    0  success / healthy
    1  corrupt or incomplete state (also: a failed run)
    2  refused by an environment guard (Steam is running)
    3  installed payloads differ; re-run with --force
    4  the host binary could not be built
    5  another luna command holds the single-writer lock; nothing was changed
    6  `luna status`: payloads differ from the pinned copy (a local edit or
       drift); corruption always reports 1 instead
"""
import argparse
import contextlib
import hashlib
import http.server
import io
import json
import lzma
import os
import re
import shlex
import shutil
import signal
import stat
import struct
import subprocess
import sys
import tarfile
import tempfile
import threading
import time
import urllib.error
import urllib.request
import zipfile
import zlib
from pathlib import Path, PurePosixPath
ROOT = Path(__file__).resolve().parents[1]
MANIFEST_PATH = ROOT / 'vendor' / 'MANIFEST.json'

# Installed as one set. luna-host discovers them from the directory and sorts
# them, so this order is only for reporting.
ADDONS = ('luna', 'sgdb', 'graphics', 'playtime', 'presence', 'compressor')
# install_bundle runs luna.py from an unpacked bundle, and write_tooling copies
# it to <luna_tools_dir()>/luna.py. Neither place is a checkout, so the support
# tree (add-on sources and the manifest) is deployed beside the copy as
# <tools>/runtime and becomes ROOT.
_INSTALLED_ROOT = Path(__file__).resolve().parent / 'runtime'
if _INSTALLED_ROOT.is_dir() and (_INSTALLED_ROOT / 'vendor' / 'MANIFEST.json').is_file():
    ROOT = _INSTALLED_ROOT
MANIFEST_PATH = ROOT / 'vendor' / 'MANIFEST.json'
# Installed as one set. luna-host discovers them from the directory and sorts
# them, so this order is only for reporting; "luna" is the menu shell and the
# others are the feature add-ons.
ADDONS = ('luna', 'sgdb', 'graphics', 'playtime', 'presence', 'compressor')
# Files that make up one add-on, as (path in this repo, path under sls-addons/<name>).
ADDON_FILES = {
    'luna': (
        ('plugin/backend/main.lua', 'backend/main.lua'),
        ('plugin/public/agent.js', 'public/agent.js'),
        ('plugin/public/panel.js', 'public/panel.js'),
        ('plugin/plugin.json', 'plugin.json'),
    ),
    'sgdb': (
        ('plugin/backend/main.lua', 'backend/main.lua'),
        ('plugin/plugin.json', 'plugin.json'),
    ),
    'graphics': (
        ('plugin/backend/main.lua', 'backend/main.lua'),
        ('plugin/plugin.json', 'plugin.json'),
    ),
    'playtime': (
        ('plugin/backend/main.lua', 'backend/main.lua'),
        ('plugin/public/agent.js', 'public/agent.js'),
        ('plugin/public/panel.js', 'public/panel.js'),
        ('plugin/plugin.json', 'plugin.json'),
    ),
    'presence': (
        ('plugin/backend/main.lua', 'backend/main.lua'),
        ('plugin/public/agent.js', 'public/agent.js'),
        ('plugin/public/panel.js', 'public/panel.js'),
        ('plugin/plugin.json', 'plugin.json'),
    ),
    'compressor': (
        ('plugin/backend/main.lua', 'backend/main.lua'),
        ('plugin/public/panel.js', 'public/panel.js'),
        ('plugin/plugin.json', 'plugin.json'),
    ),
}
EXIT_OK = 0
EXIT_CORRUPT = 1
EXIT_REFUSED = 2
EXIT_NEEDS_FORCE = 3
EXIT_PATCH = 4
EXIT_BUSY = 5
EXIT_MODIFIED = 6
EXIT_EPILOG = ('exit codes: 0 ok, 1 corrupt or failed, 2 refused, 3 needs --force, '
               '4 patcher failed, 5 another luna command is running, '
               '6 status: payload differs from the pinned copy (local edit or drift; '
               'pass --strict to report it as 1)')
# Set for a child `install` spawned by an owner that already holds the lock
# (install_bundle, the timer): the lock is ours, a second acquire would refuse.
LOCK_HELD_ENV = 'LUNA_LOCK_HELD'
_VDF_TOKEN = re.compile(r'"((?:[^"\\]|\\.)*)"|([{}])')
def _vdf_unescape(text):
    return text.replace('\\\\', '\x00').replace('\\"', '"').replace('\x00', '\\')
def parse_vdf(text):
    """Minimal Valve KeyValues parser: quoted strings, braces, last-wins."""
    root = {}
    stack = [root]
    key = None
    for match in _VDF_TOKEN.finditer(text):
        brace = match.group(2)
        if brace == '{':
            child = {}
            if key is not None:
                stack[-1][key] = child
                key = None
            stack.append(child)
        elif brace == '}':
            if len(stack) > 1:
                stack.pop()
            key = None
        else:
            value = _vdf_unescape(match.group(1))
            if key is None:
                key = value
            else:
                stack[-1][key] = value
                key = None
    return root
def _steam_user_configs():
    root = home() / '.local/share/Steam/userdata'
    if not root.is_dir():
        return []
    return sorted(path for path in root.iterdir()
                  if (path / 'config' / 'localconfig.vdf').is_file())
def home():
    return Path(os.environ.get('HOME') or Path.home())
def addons_dir():
    """Where luna-host loads add-ons from: one directory per add-on."""
    return luna_home() / 'addons'


def data_dir():
    """Add-on state: playtime ledgers, presence, artwork, settings."""
    return luna_home() / 'data'


def luna_home():
    """Luna's own home: the plugin host, its Lua tree, add-ons and host state."""
    return Path(os.environ.get('LUNA_HOME') or (home() / '.local/share/Luna'))


def host_state_path():
    return luna_home() / 'host.json'


def luna_tools_dir():
    """Machine-local tooling: the standalone updater copy and its units."""
    return luna_home() / 'state'

def machine_id():
    """Stable per-machine id. Machine-local on purpose (never synced): it is
    how one machine tells its own heartbeat apart from the other's."""
    path = luna_tools_dir() / 'machine-id'
    try:
        existing = path.read_text().strip()
        if existing:
            return existing
    except OSError:
        pass
    import uuid
    ident = uuid.uuid4().hex[:12]
    try:
        luna_tools_dir().mkdir(parents=True, exist_ok=True)
        path.write_text(ident + '\n')
    except OSError:
        pass
    return ident
HEARTBEAT_PRUNE = 7 * 24 * 3600
def heartbeat_dir():
    """Synced heartbeats: data_dir *is* shared between machines, so each
    machine's periodic check-in is visible to the other."""
    return data_dir() / 'heartbeats'
def write_heartbeat():
    """Record this machine's presence for the other machine to see."""
    try:
        directory = heartbeat_dir()
        directory.mkdir(parents=True, exist_ok=True)
        entry = {'machine': machine_id(),
                 'at': int(time.time()),
                 'steamRunning': bool(steam_running()),
                 'luna': installed_version()}
        (directory / (entry['machine'] + '.json')).write_text(json.dumps(entry) + '\n')
        now = time.time()
        for child in directory.glob('*.json'):
            try:
                if now - child.stat().st_mtime > HEARTBEAT_PRUNE:
                    child.unlink()
            except OSError:
                pass
    except OSError:
        pass
def read_json_file(path):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return None
def write_json_file(path, data):
    """Atomic: the Lua backend reads these files while Python writes them."""
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix='.' + path.name + '.', dir=str(path.parent))
    try:
        with os.fdopen(fd, 'w') as handle:
            handle.write(json.dumps(data, indent=2, sort_keys=True) + '\n')
        os.chmod(tmp, 0o644)
        os.replace(tmp, path)
    except BaseException:
        with contextlib.suppress(OSError):
            os.unlink(tmp)
        raise
    return path
# A hung gh must not hang its caller: the Health page waits on `check`, and a
# oneshot timer unit that never exits is never started again.
GH_TIMEOUT = 30
GH_DOWNLOAD_TIMEOUT = 600
def find_gh():
    """The gh CLI, from PATH or the usual user locations."""
    found = shutil.which('gh')
    if found:
        return found
    for candidate in (home() / '.local/bin/gh', Path('/usr/local/bin/gh'), Path('/usr/bin/gh')):
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return str(candidate)
    return None
def installed_version():
    """The luna add-on version actually on disk.

    Read from the installed payload first, so the standalone updater copy (which
    has no repository around it) reports the truth too.
    """
    for candidate in (addons_dir() / 'luna' / 'plugin.json',
                      payload_path('luna', 'plugin/plugin.json')):
        try:
            return str(json.loads(candidate.read_text()).get('version', '?'))
        except (OSError, ValueError):
            continue
    return '?'
def version_key(text):
    """Sortable tuple for tags like v0.14.3 or 0.14.3-rc1 (best effort)."""
    numbers = []
    for part in str(text or '').strip().lstrip('v').replace('-', '.').split('.'):
        digits = ''.join(ch for ch in part if ch.isdigit())
        numbers.append(int(digits) if digits else 0)
    while len(numbers) < 3:
        numbers.append(0)
    return tuple(numbers[:3])
def payload_path(addon, source_rel):
    """Where a payload file lives in this repo (mirrors the add-on project)."""
    return ROOT / 'addons' / addon / source_rel
def sha256(path):
    digest = hashlib.sha256()
    with open(path, 'rb') as handle:
        for block in iter(lambda: handle.read(1 << 20), b''):
            digest.update(block)
    return digest.hexdigest()
def process_running(name):
    """True when a process with this exact name belongs to this user."""
    try:
        result = subprocess.run(['pgrep', '-u', str(os.getuid()), '-x', name],
                                capture_output=True, text=True)
    except FileNotFoundError:
        return False
    # pgrep's contract is the exit status; it prints PIDs but the status is what
    # says whether anything matched.
    return result.returncode == 0
def load_manifest():
    if not MANIFEST_PATH.is_file():
        raise SystemExit('FAIL: %s is missing; run scripts/make-manifest.py' % MANIFEST_PATH)
    return json.loads(MANIFEST_PATH.read_text())
def addon_version(name):
    payload = payload_path(name, 'plugin/plugin.json')
    if not payload.is_file():
        return '?'
    try:
        return json.loads(payload.read_text()).get('version', '?')
    except ValueError:
        return '?'
def steam_running():
    """The single answer to "is Steam up?" (client or its webhelper)."""
    return bool(process_running('steam') or process_running('steamwebhelper'))
def luna_host_running():
    """True while the luna-host helper that serves the menu is running."""
    return bool(process_running('luna-host') or process_running('luna_host'))
def refuse_reasons(for_install):
    """Environment problems that must stop an install or uninstall."""
    reasons = []
    if steam_running():
        reasons.append('Steam is running. Close it completely (Steam -> Exit) before changing Luna.')
    if luna_host_running() and not steam_running():
        # The unit restarts; a copy written now is loaded on the next start.
        print('host      : luna-host is running; it reloads the add-ons on its next start')
    return reasons
def plan(targets):
    """What would change on disk: (addon, label, source, dest, state)."""
    rows = []
    for name in targets:
        for source_rel, dest_rel in ADDON_FILES[name]:
            source = payload_path(name, source_rel)
            dest = addons_dir() / name / dest_rel
            rows.append((name, dest_rel, source, dest, file_state(source, dest)))
    return rows
def file_state(source, dest):
    if not source.is_file():
        return 'missing-source'
    if not dest.is_file():
        return 'new'
    if sha256(source) == sha256(dest):
        return 'same'
    return 'differs'
def selected_addons(options):
    if options.only:
        for name in options.only:
            if name not in ADDONS:
                raise SystemExit('FAIL: unknown add-on %r (known: %s)' % (name, ', '.join(ADDONS)))
        return tuple(name for name in ADDONS if name in options.only)
    return tuple(ADDONS)
def installed_addons():
    return tuple(name for name in ADDONS if (addons_dir() / name).is_dir())
def install_marker_path():
    return luna_tools_dir() / 'install-in-progress.json'
def write_install_marker(targets, force=False):
    """Record that payloads are being written, before the first byte changes.

    A kill -9 (or a power cut) leaves this file behind, so `luna status` and
    `luna doctor` can say "the last install was interrupted" instead of
    pretending a half-written tree is installed.
    """
    path = install_marker_path()
    try:
        write_json_file(path, {'pid': os.getpid(), 'at': int(time.time()),
                               'addons': list(targets), 'force': bool(force)})
    except OSError as error:
        print('  WARN: could not write the install marker: %s' % error, file=sys.stderr)
    return path
def clear_install_marker():
    try:
        install_marker_path().unlink()
    except OSError:
        pass
def archive_previous(differing, reason='undo'):
    """Copy every payload --force is about to overwrite; returns the root dir.

    The bytes stay under <tools>/undo/<timestamp>/ with the same relative
    layout, so a local hotfix can always be recovered by hand.
    """
    if not differing:
        return None
    stamp = time.strftime('%Y%m%d-%H%M%S')
    root = luna_tools_dir() / reason / stamp
    suffix = 0
    while root.exists():
        suffix += 1
        root = luna_tools_dir() / reason / ('%s-%d' % (stamp, suffix))
    for addon, label, source, dest, state in differing:
        target = root / addon / label
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(dest, target)
    return root
class Apply:
    """Write files, remembering how to put the previous state back."""

    def __init__(self):
        self.undo = []
        self.did_patch = False

    def write(self, source, dest):
        dest.parent.mkdir(parents=True, exist_ok=True)
        if dest.is_file():
            self.undo.append(('restore', dest, dest.read_bytes()))
        else:
            self.undo.append(('remove', dest, None))
        data = source.read_bytes()
        # Per-run unique name: two writers can never share one temp file.
        fd, temporary = tempfile.mkstemp(prefix='.%s.' % dest.name, suffix='.luna-tmp',
                                         dir=dest.parent)
        try:
            with os.fdopen(fd, 'wb') as out:
                out.write(data)
            os.chmod(temporary, 0o644)
            os.replace(temporary, dest)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)

    def mkdir(self, path):
        if not path.is_dir():
            path.mkdir(parents=True, exist_ok=True)
            self.undo.append(('rmdir', path, None))

    def rollback(self):
        """Undo every recorded step; returns how many could not be undone."""
        failures = 0
        for action, target, payload in reversed(self.undo):
            try:
                if action == 'restore':
                    target.write_bytes(payload)
                elif action == 'remove':
                    if target.exists():
                        target.unlink()
                elif action == 'rmdir':
                    shutil.rmtree(target, ignore_errors=True)
            except OSError as error:
                failures += 1
                print('  WARN: rollback could not restore %s: %s' % (target, error), file=sys.stderr)
        if self.did_patch:
            result = patcher('uninstall')
            if result.returncode != 0:
                failures += 1
                print('  WARN: could not revert the boot.lua patch: %s'
                      % (result.stderr.strip() or result.stdout.strip()), file=sys.stderr)
        return failures
def cmd_status(options):
    targets = selected_addons(options)
    manifest = load_manifest()
    installed = installed_addons()
    print('home       : %s' % luna_home())
    print('processes  : steam=%s luna-host=%s' % (steam_running(), luna_host_running()))
    print('units      : %s (%s)' % (HOST_UNIT, unit_state(HOST_UNIT)))
    interrupted = read_json_file(install_marker_path()) or {}
    if interrupted:
        print('note       : last install was interrupted (pid %s, started %s); run: luna install --force'
              % (interrupted.get('pid') or '?',
                 time.strftime('%Y-%m-%d %H:%M:%S', time.localtime(int(interrupted.get('at') or 0)))
                 if interrupted.get('at') else 'unknown time'))
    rows = plan(targets)
    print('%-9s %-22s %s' % ('add-on', 'file', 'state'))
    degraded = bool(interrupted)
    modified = False
    for addon, label, source, dest, state in rows:
        print('%-9s %-22s %s' % (addon, label, state))
        if state == 'differs':
            # Somebody (or another tool) changed an installed payload. That is
            # a local edit or drift, not corruption: its own exit code, so a
            # script can tell "review this" from "this tree is broken".
            modified = True
        if state == 'missing-source':
            degraded = True
        if state == 'new' and addon in installed:
            # The directory claims the add-on is present but an expected
            # file is missing: that is corruption, not a fresh install.
            degraded = True
    for name in targets:
        if name not in installed:
            print('note       : %s is not installed' % name)
    print('host       : %s' % ('present' if host_binary().is_file() else 'not built'))
    print('data       : %s' % ('present' if data_dir().is_dir() else 'absent'))
    print('manifest   : %d add-on(s) pinned' % len(manifest.get('addons', {})))
    if degraded:
        return EXIT_CORRUPT
    if modified:
        if getattr(options, 'strict', False):
            return EXIT_CORRUPT
        return EXIT_MODIFIED
    return EXIT_OK
def write_install_snapshot():
    """Record what this installer put on disk, for the Health page.

    Versions and sources identify the release; file hashes let the Health
    page report drift without a checkout. The full pins stay in
    vendor/MANIFEST.json (and in `luna verify`).
    """
    manifest = load_manifest()
    files = {}
    for name in ADDONS:
        entry = (manifest.get('addons', {}).get(name) or {}).get('files', {})
        hashes = {}
        for rel, meta in entry.items():
            path = payload_path(name, meta.get('source_path', ''))
            try:
                hashes[rel] = sha256(path) if path.is_file() else ''
            except OSError:
                hashes[rel] = ''
        files[name] = hashes
    snapshot = {
        'generated': manifest.get('generated', ''),
        'installedAt': int(time.time()),
        'source': repo_revision(),
        'versions': {name: addon_version(name) for name in ADDONS},
        'sources': {name: str((manifest.get('addons', {}).get(name) or {})
                              .get('source_commit', ''))[:12] for name in ADDONS},
        'files': files,
    }
    path = addons_dir() / 'luna-manifest.json'
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(snapshot, indent=2, sort_keys=True) + '\n')
    return path
def repo_revision():
    try:
        result = subprocess.run(['git', '-C', str(ROOT), 'rev-parse', '--short', 'HEAD'],
                                capture_output=True, text=True)
        if result.returncode == 0:
            return result.stdout.strip()
    except OSError:
        pass
    return ''
def _manifest_problems(manifest, root):
    """Payload bytes vs manifest pins, for a checkout or an extracted bundle."""
    problems = []
    for name in ADDONS:
        entry = manifest.get('addons', {}).get(name)
        if not entry:
            problems.append('manifest has no entry for %s' % name)
            continue
        for rel, meta in entry.get('files', {}).items():
            path = root / 'addons' / name / meta['source_path']
            if not path.is_file():
                problems.append('missing payload %s/%s' % (name, rel))
                continue
            if sha256(path) != meta['sha256']:
                problems.append('payload %s/%s does not match the manifest' % (name, rel))
    for rel, meta in manifest.get('shared', {}).items():
        path = root / rel
        if not path.is_file():
            problems.append('missing shared file %s' % rel)
        elif sha256(path) != meta['sha256']:
            problems.append('shared file %s does not match the manifest' % rel)
    return problems
def cmd_release(options):
    """Build a bundle another machine can install with `luna update`."""
    manifest = load_manifest()  # fail early when the pins are missing
    problems = _manifest_problems(manifest, ROOT)
    if problems:
        print('REFUSING to release: the working tree does not match the manifest:')
        for problem in problems:
            print('  - %s' % problem)
        print('Run the release only from a tree that verifies clean.', file=sys.stderr)
        return 1
    version = addon_version('luna')
    out_dir = Path(options.out).expanduser() if options.out else ROOT / 'dist'
    out_dir.mkdir(parents=True, exist_ok=True)
    name = 'luna-%s' % version
    bundle = out_dir / (name + '.tar.gz')
    entries = [
        ('addons', ROOT / 'addons'),
        ('vendor/MANIFEST.json', MANIFEST_PATH),
         ('scripts/luna.py', ROOT / 'scripts' / 'luna.py'),
        ('scripts/steam-machine.py', ROOT / 'scripts' / 'steam-machine.py'),
    ]
    # Luna's own plugin host: prebuilt binary + Lua tree, so a bundle install
    # needs no compiler. Not manifest-pinned (built locally); verified by bundle sha256.
    host_bin = host_source() / 'bin' / 'luna-host'
    if not host_bin.is_file() and (host_source() / 'Makefile').is_file():
        ensure_host_built()
    if host_bin.is_file() and (host_source() / 'lua').is_dir():
        entries.append(('host/bin/luna-host', host_bin))
        entries.append(('host/lua', host_source() / 'lua'))
    else:
        print('warning: no luna-host binary; the bundle will not carry the host', file=sys.stderr)
    readme = ROOT / 'README.md'
    if readme.is_file():
        entries.append(('README.md', readme))
    changelog = ROOT / 'CHANGELOG.md'
    if changelog.is_file():
        entries.append(('CHANGELOG.md', changelog))
    with tarfile.open(bundle, 'w:gz') as tar:
        for arcname, path in entries:
            tar.add(path, arcname='%s/%s' % (name, arcname), recursive=path.is_dir())
    digest = sha256(bundle)
    checksum = out_dir / (bundle.name + '.sha256')
    checksum.write_text('%s  %s\n' % (digest, bundle.name))
    print('bundle : %s' % bundle)
    print('sha256 : %s' % digest)
    print('version: %s (%s)' % (version, ', '.join('%s %s' % (n, addon_version(n)) for n in ADDONS)))
    if options.publish:
        gh = shutil.which('gh')
        if not gh:
            print('gh CLI not found; publish manually: %s' % bundle, file=sys.stderr)
            return 1
        tag = 'v%s' % version
        view = subprocess.run([gh, 'release', 'view', tag], capture_output=True, text=True)
        if view.returncode == 0:
            args = [gh, 'release', 'upload', tag, str(bundle), str(checksum), '--clobber']
        else:
            args = [gh, 'release', 'create', tag, str(bundle), str(checksum),
                    '--title', 'Luna %s' % version,
                    '--notes', ('Luna %s: pinned payloads plus scripts/luna.py.\n\n'
                                'Install on another machine: `luna update --latest` (needs gh).'
                                % version)]
        result = subprocess.run(args, capture_output=True, text=True)
        if result.returncode != 0:
            print('gh failed: %s' % (result.stderr.strip() or result.stdout.strip()), file=sys.stderr)
            return 1
        print('published: %s' % tag)
    return EXIT_OK
def cmd_update(options):
    """Verify a released bundle and install it with the bundled script."""
    lock_path = _update_lock()
    acquired, reason = _acquire_lock(lock_path)
    if not acquired:
        print('REFUSING: %s' % reason, file=sys.stderr)
        return EXIT_BUSY
    temp_dir = Path(tempfile.mkdtemp(prefix='luna-update-'))
    try:
        bundle = None
        if options.bundle:
            bundle = Path(options.bundle).expanduser()
        elif options.latest:
            tag, tag_error = latest_release()
            if not tag:
                print('gh release lookup failed: %s' % tag_error, file=sys.stderr)
                return 1
            bundle, error = download_release(tag, temp_dir)
            if bundle is None:
                print('gh release download failed: %s' % error, file=sys.stderr)
                return 1
        elif options.url:
            bundle = temp_dir / 'luna-bundle.tar.gz'
            try:
                urllib.request.urlretrieve(options.url, bundle)
            except Exception as error:  # noqa: BLE001 - report the URL failure
                print('download failed: %s' % error, file=sys.stderr)
                return 1
            try:
                urllib.request.urlretrieve(options.url + '.sha256', str(bundle) + '.sha256')
            except Exception:  # noqa: BLE001 - the sidecar is optional for --url
                pass
            if not Path(str(bundle) + '.sha256').is_file():
                print('warning: no .sha256 beside the URL; the bundled manifest is still verified, '
                      'but prefer --latest or a checksum-signed source', file=sys.stderr)
        else:
            print('Point at a bundle: --bundle FILE, --url URL or --latest', file=sys.stderr)
            return 2
        return install_bundle(bundle, only=options.only, dry_run=options.dry_run)
    finally:
        shutil.rmtree(temp_dir, ignore_errors=True)
        _release_lock(lock_path)
LUNA_REPO = 'pgm1207/Luna'
UPDATE_TTL = 6 * 3600
def gh_json(args):
    gh = find_gh()
    if not gh:
        return None, 'the gh CLI is not installed (update checks use your own GitHub auth)'
    try:
        result = subprocess.run([gh] + args, capture_output=True, text=True, timeout=GH_TIMEOUT)
    except subprocess.TimeoutExpired:
        return None, 'gh did not answer within %d seconds' % GH_TIMEOUT
    if result.returncode != 0:
        return None, (result.stderr.strip() or result.stdout.strip() or 'gh failed')
    try:
        return json.loads(result.stdout), ''
    except ValueError:
        return None, 'gh returned something that is not JSON'
def latest_release():
    data, error = gh_json(['release', 'view', '--json', 'tagName,assets', '-R', LUNA_REPO])
    if data is None:
        return '', error
    return str(data.get('tagName') or ''), ''
def update_source():
    """Where the latest version comes from (shown beside the version)."""
    return 'GitHub releases of %s (via gh)' % LUNA_REPO
def _compare_fields(installed, latest):
    """available / newerThanLatest / note for an installed version against the latest release."""
    if not latest:
        return {'available': False, 'newerThanLatest': False, 'note': ''}
    newer = version_key(latest) > version_key(installed)
    ahead = version_key(installed) > version_key(latest)
    return {'available': newer, 'newerThanLatest': ahead,
            'note': 'installed %s is newer than the latest release %s; nothing to update' % (installed, latest)
            if ahead else ''}
def check_updates(force=False):
    """Compare the installed version with the newest release; cached for 6h."""
    cache_path = luna_tools_dir() / 'update-check.json'
    cached = read_json_file(cache_path) or {}
    now = int(time.time())
    installed = installed_version()
    if (not force and cached.get('latest') and cached.get('checkedAt') and not cached.get('checkError')
            and now - int(cached['checkedAt']) < UPDATE_TTL):
        cached['installed'] = installed
        cached.update(_compare_fields(installed, str(cached.get('latest') or '')))
        cached['source'] = update_source()
        return cached
    latest, error = latest_release()
    if not latest and error:
        # A failed lookup keeps the last known release, so an offline check
        # does not hide an update that was already found.
        latest = str(cached.get('latest') or '')
    report = {
        'installed': installed,
        'latest': latest,
        'checkedAt': now,
        'checkError': error,
        'source': update_source(),
    }
    report.update(_compare_fields(installed, latest))
    write_json_file(cache_path, report)
    return report
def _safe_extract(bundle, extract_dir):
    """Unpack without allowing absolute paths or parent-directory escapes."""
    with tarfile.open(bundle) as tar:
        members = tar.getmembers()
        for member in members:
            name = member.name
            if not name or name.startswith('/') or '..' in Path(name).parts:
                raise ValueError('REFUSING: unsafe path in bundle: %r' % name)
        try:
            tar.extractall(extract_dir, filter='data')
        except TypeError:  # Python < 3.12 has no extraction filter
            tar.extractall(extract_dir)
def install_bundle(bundle, only=None, dry_run=False):
    """Verify a bundle and run the installer inside it."""
    bundle = Path(bundle)
    if not bundle.is_file():
        print('bundle not found: %s' % bundle, file=sys.stderr)
        return 2
    checksum_file = Path(str(bundle) + '.sha256')
    if checksum_file.is_file():
        expected = checksum_file.read_text().split()[0].strip().lower()
        actual = sha256(bundle)
        if expected != actual:
            print('REFUSING: sha256 mismatch (bundle %s, sidecar %s)'
                  % (actual[:12], expected[:12]), file=sys.stderr)
            return 1
        print('sha256 : verified (%s)' % actual[:12])
    else:
        print('note   : no .sha256 beside the bundle; the payload hashes in the '
              'bundled manifest are still enforced')
    with tempfile.TemporaryDirectory(prefix='luna-bundle-') as work:
        extract_dir = Path(work) / 'unpacked'
        extract_dir.mkdir()
        try:
            _safe_extract(bundle, extract_dir)
        except (tarfile.TarError, ValueError, OSError) as error:
            print('REFUSING: cannot safely unpack the bundle: %s' % error, file=sys.stderr)
            return 1
        roots = [entry for entry in extract_dir.iterdir() if entry.is_dir()]
        root = roots[0] if len(roots) == 1 else extract_dir
        script = root / 'scripts' / 'luna.py'
        if not script.is_file():
            print('REFUSING: the bundle does not contain scripts/luna.py', file=sys.stderr)
            return 1
        version = '?'
        bundled_manifest = root / 'vendor' / 'MANIFEST.json'
        if not bundled_manifest.is_file():
            print('REFUSING: the bundle does not contain vendor/MANIFEST.json', file=sys.stderr)
            return 1
        try:
            manifest = json.loads(bundled_manifest.read_text())
            version = str((manifest.get('addons', {}).get('luna') or {})
                          .get('plugin_version', '?'))
        except ValueError:
            print('REFUSING: the bundled manifest is not valid JSON', file=sys.stderr)
            return 1
        problems = _manifest_problems(manifest, root)
        if problems:
            print('REFUSING: the bundle contents do not match its own manifest:')
            for problem in problems:
                print('  - %s' % problem, file=sys.stderr)
            return 1
        print('bundle : %s (Luna %s, manifest verified)' % (bundle.name, version))
        # Add-on updates must not undo a deliberate client update from Health.
        command = [sys.executable, str(script), 'install', '--force']
        for name in only or []:
            command += ['--only', name]
        if dry_run:
            command.append('--dry-run')
        result = subprocess.run(command, env=dict(os.environ, LUNA_KEEP_STEAM_CLIENT='1',
                                                  **{LOCK_HELD_ENV: '1'}))
        return result.returncode
def download_release(tag, work):
    """Fetch a release's bundle + checksum with the user's gh auth."""
    gh = find_gh()
    if not gh:
        return None, 'the gh CLI is not installed'
    if not tag:
        return None, 'no release tag to download'
    try:
        result = subprocess.run([gh, 'release', 'download', tag,
                                 '--pattern', 'luna-*.tar.gz',
                                 '--pattern', 'luna-*.tar.gz.sha256',
                                 '--dir', str(work), '--clobber', '-R', LUNA_REPO],
                                capture_output=True, text=True, timeout=GH_DOWNLOAD_TIMEOUT)
    except subprocess.TimeoutExpired:
        return None, 'the release download did not finish within %d seconds' % GH_DOWNLOAD_TIMEOUT
    if result.returncode != 0:
        return None, (result.stderr.strip() or result.stdout.strip() or 'download failed')
    found = sorted(work.glob('luna-*.tar.gz'))
    if not found:
        return None, 'the release has no bundle asset'
    bundle = found[-1]
    if not Path(str(bundle) + '.sha256').is_file():
        return None, 'the release has no checksum sidecar; refusing an unauthenticated bundle'
    return bundle, ''
def _update_lock():
    """Single writer lock for *every* mutating command.

    Timer, menu, `luna install`, uninstall, launchers, host, backup and restore
    all take this one file, so two writers can never interleave payload bytes
    or fight over boot.lua. The name is historical (tests and old units know it).
    """
    tools = luna_tools_dir()
    try:
        tools.mkdir(parents=True, exist_ok=True)
    except OSError:
        pass
    return tools / 'update.lock'
LOCK_TTL = 3600
CHECK_LOCK_TTL = 600
def _lock_owner(lock_path):
    """(pid, started) recorded by the lock owner, or (0, 0) when unreadable."""
    try:
        info = json.loads(lock_path.read_text())
        return int(info.get('pid') or 0), int(info.get('at') or 0)
    except (OSError, ValueError, TypeError, AttributeError):
        return 0, 0
def _pid_cmdline(pid):
    """/proc/<pid>/cmdline as one string; '' when unreadable."""
    try:
        return Path('/proc/%d/cmdline' % int(pid)).read_bytes().replace(b'\0', b' ').decode('utf-8', 'replace')
    except (OSError, ValueError):
        return ''
def _busy_message(lock_path):
    """One wording for every refusal, so callers and the panel agree."""
    pid, started = _lock_owner(lock_path)
    when = (time.strftime('%Y-%m-%d %H:%M:%S', time.localtime(started))
            if started else 'unknown time')
    return ('another luna command is already running (pid %s, started %s); '
            'nothing was changed, try again when it finishes' % (pid or '?', when))
def _acquire_lock(lock_path, ttl=LOCK_TTL):
    """Claim the lock; clear it when stale (dead owner or too old).

    Returns (True, '') on success or (False, reason). A kill -9 between
    acquire and release must never wedge updates forever.
    """
    try:
        fd = os.open(str(lock_path), os.O_CREAT | os.O_EXCL | os.O_WRONLY)
    except FileExistsError:
        pass
    except OSError:
        return True, ''
    else:
        try:
            os.write(fd, json.dumps(
                {'pid': os.getpid(), 'at': int(time.time())}).encode())
        finally:
            os.close(fd)
        return True, ''
    owner, started = _lock_owner(lock_path)
    alive = False
    if owner > 0:
        try:
            os.kill(owner, 0)
            alive = True
        except (OSError, ProcessLookupError, PermissionError):
            alive = False
    if alive and time.time() - started >= ttl:
        # Never take the lock from a live luna process: a stalled installer must
        # be killed by its own timeout, not raced by a second writer. Only an
        # unrelated process that inherited a reused pid is treated as stale.
        cmdline = _pid_cmdline(owner)
        if cmdline and 'luna' not in cmdline.lower():
            alive = False
    if alive:
        return False, _busy_message(lock_path)
    try:
        lock_path.unlink()
    except OSError:
        pass
    try:
        fd = os.open(str(lock_path), os.O_CREAT | os.O_EXCL | os.O_WRONLY)
    except (FileExistsError, OSError):
        return False, _busy_message(lock_path)
    try:
        os.write(fd, json.dumps({'pid': os.getpid(), 'at': int(time.time())}).encode())
    finally:
        os.close(fd)
    return True, ''
def _release_lock(lock_path):
    try:
        lock_path.unlink()
    except OSError:
        pass
def lock_inherited():
    """True when an owner that already holds the lock spawned this process."""
    return os.environ.get(LOCK_HELD_ENV) == '1'
def run_locked(func, options):
    """Run a mutating handler under the single writer lock.

    Non-blocking: a second invocation reports who holds the lock and exits
    EXIT_BUSY (distinct from success and from every refusal code).
    """
    if lock_inherited():
        return func(options)
    lock_path = _update_lock()
    acquired, reason = _acquire_lock(lock_path)
    if not acquired:
        print('REFUSING: %s' % reason, file=sys.stderr)
        return EXIT_BUSY
    try:
        return func(options)
    finally:
        _release_lock(lock_path)
def locked(func):
    """Decorator form used by the dispatch table."""
    def wrapper(options):
        return run_locked(func, options)
    wrapper.__name__ = getattr(func, '__name__', 'locked')
    wrapper.__doc__ = func.__doc__
    return wrapper
CLI_LAUNCHER = '''#!/bin/sh
# Managed by Luna: runs the tooling copy under $LUNA_HOME/state.
LUNA_HOME="${LUNA_HOME:-$HOME/.local/share/Luna}"
if [ ! -f "$LUNA_HOME/state/luna.py" ]; then
  echo "luna: no tooling copy found; run the installer again" >&2
  exit 1
fi
exec python3 "$LUNA_HOME/state/luna.py" "$@"
'''
def runtime_sources():
    """(relative path, source) for the support tree an installed copy needs."""
    rels = ['scripts/luna.py', 'scripts/steam-machine.py',
            'vendor/MANIFEST.json', 'install.sh', 'uninstall.sh']
    for name in ADDONS:
        for source_rel, _dest in ADDON_FILES[name]:
            rels.append('addons/%s/%s' % (name, source_rel))
    return [(rel, ROOT / rel) for rel in rels]
RUNTIME_MANIFEST = 'RUNTIME.json'
def _file_sha256(path):
    digest = hashlib.sha256()
    with open(path, 'rb') as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b''):
            digest.update(chunk)
    return digest.hexdigest()
def deploy_runtime(tools=None, luna_source=None):
    """Copy the manifest, add-on sources and scripts to <tools>/runtime.

    Staged in runtime.new, RUNTIME.json (sha256 of the luna.py it belongs to and of
    every file) written last, then swapped in with renames, so an interrupted
    install never leaves a half-new tree that looks complete. Returns the
    relative paths whose source was missing.
    """
    tools = Path(tools or luna_tools_dir())
    dest = tools / 'runtime'
    luna_source = Path(luna_source or __file__).resolve()
    missing = []
    try:
        if dest.resolve() == ROOT.resolve():  # running from the installed copy: nothing to stage
            missing = [rel for rel, source in runtime_sources() if not source.is_file()]
            if not (dest / RUNTIME_MANIFEST).is_file() and not missing:
                _write_runtime_manifest(dest, [rel for rel, _s in runtime_sources()], luna_source)
            return missing
    except OSError:
        pass
    stage, old = tools / 'runtime.new', tools / 'runtime.old'
    shutil.rmtree(stage, ignore_errors=True)
    copied = []
    for rel, source in runtime_sources():
        if not source.is_file():
            missing.append(rel)
            continue
        target = stage / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)
        copied.append(rel)
    _write_runtime_manifest(stage, copied, luna_source)
    shutil.rmtree(old, ignore_errors=True)
    if dest.exists():
        os.replace(dest, old)
    os.replace(stage, dest)
    shutil.rmtree(old, ignore_errors=True)
    return missing
def _write_runtime_manifest(directory, rels, luna_source):
    manifest = {'lunaSha256': _file_sha256(luna_source),
                'files': {rel: _file_sha256(Path(directory) / rel) for rel in rels
                          if (Path(directory) / rel).is_file()}}
    tmp = Path(directory) / (RUNTIME_MANIFEST + '.tmp')
    tmp.write_text(json.dumps(manifest, sort_keys=True))
    os.replace(tmp, Path(directory) / RUNTIME_MANIFEST)
RUNTIME_REPAIR = ('repair: run `python3 <checkout or unpacked release>/scripts/luna.py install --force` '
                  '(it redeploys the runtime tree)')
def runtime_problems(full=False):
    """Does <tools>/runtime belong to the luna.py that is running? Only the installed
    copy is checked (a checkout has no runtime tree). Cheap: manifest, luna.py hash and
    file presence; full also hashes every file and refuses an interrupted install."""
    if ROOT != _INSTALLED_ROOT:
        return []
    tools = _INSTALLED_ROOT.parent
    if not _INSTALLED_ROOT.is_dir() and (tools / 'runtime.old').is_dir():
        with contextlib.suppress(OSError):  # interrupted swap: put the old tree back
            os.replace(tools / 'runtime.old', _INSTALLED_ROOT)
    manifest = read_json_file(_INSTALLED_ROOT / RUNTIME_MANIFEST)
    bad = 'runtime tree does not match this luna.py'
    if not isinstance(manifest, dict):
        return ['%s (no %s); %s' % (bad, RUNTIME_MANIFEST, RUNTIME_REPAIR)]
    problems = []
    try:
        if manifest.get('lunaSha256') != _file_sha256(Path(__file__).resolve()):
            problems.append('%s (luna.py changed since the tree was deployed)' % bad)
    except OSError:
        problems.append('%s (luna.py unreadable)' % bad)
    for rel, digest in sorted((manifest.get('files') or {}).items()):
        path = _INSTALLED_ROOT / rel
        try:
            if not path.is_file() or (full and _file_sha256(path) != digest):
                problems.append('%s (%s %s)' % (bad, rel, 'missing' if not path.is_file() else 'differs'))
                if len(problems) > 3:
                    break
        except OSError:
            problems.append('%s (%s unreadable)' % (bad, rel))
    if full and install_marker_path().is_file():
        problems.append('a previous Luna install was interrupted (%s present)' % install_marker_path())
    return ['%s; %s' % (problems[0], RUNTIME_REPAIR)] + problems[1:] if problems else []
def write_tooling():
    """Keep a standalone tooling copy the timer and `luna` can run without a checkout.

    Called both by the installer (from a checkout) and by the copy itself, so
    the source is *this* file, never a fixed path relative to it.
    """
    tools = luna_tools_dir()
    tools.mkdir(parents=True, exist_ok=True)
    target = tools / 'luna.py'
    source = Path(__file__).resolve()
    try:
        same = source.samefile(target)
    except OSError:
        same = False
    # runtime first, luna.py last: RUNTIME.json names its hash
    missing = deploy_runtime(tools, source)
    if not same:
        shutil.copy2(source, target)
        target.chmod(0o755)
    launcher = home() / '.local/bin/luna'
    wanted = CLI_LAUNCHER.encode()
    if launcher.is_symlink():
        print('WARNING: %s is a symlink; left untouched' % launcher, file=sys.stderr)
    elif launcher.is_file() and launcher.read_bytes() != wanted and target.name in launcher.read_text(
            errors='replace'):
        pass  # a launcher already pointing at the installed copy is fine
    elif launcher.is_file() and launcher.read_bytes() != wanted:
        print('WARNING: custom command %s preserved; run python3 %s instead'
              % (launcher, target), file=sys.stderr)
    else:
        launcher.parent.mkdir(parents=True, exist_ok=True)
        tmp = launcher.with_name('luna.luna-tmp')
        tmp.write_bytes(wanted)
        tmp.chmod(0o755)
        os.replace(tmp, launcher)
    if missing:
        print('WARNING: the tooling copy is incomplete: %s' % ', '.join(missing), file=sys.stderr)


def unit_paths():
    unit_dir = home() / '.config/systemd/user'
    return unit_dir, unit_dir / 'luna-autoupdate.service', unit_dir / 'luna-autoupdate.timer'
def cmd_check(options):
    """Print the update check as JSON (the Luna menu reads it).

    Single-flight: the menu can spawn `check` on every page load, but only one
    may hold the check lock (pid liveness, not a timestamp window). A second
    invocation answers "busy" instead of racing for the same gh release.
    """
    lock = luna_tools_dir() / 'check.lock'
    acquired, reason = _acquire_lock(lock, ttl=CHECK_LOCK_TTL)
    if not acquired:
        print(json.dumps({'result': 'busy', 'reason': reason}, sort_keys=True))
        return EXIT_OK
    try:
        write_heartbeat()
        print(json.dumps(check_updates(force=getattr(options, 'force', False)), sort_keys=True))
        return EXIT_OK
    finally:
        _release_lock(lock)
def cmd_timer(options):
    """Enable, disable or report the unattended-update timer."""
    unit_dir, service, timer = unit_paths()
    if options.action == 'status':
        enabled = subprocess.run(['systemctl', '--user', 'is-enabled', 'luna-autoupdate.timer'],
                                 capture_output=True, text=True)
        active = subprocess.run(['systemctl', '--user', 'is-active', 'luna-autoupdate.timer'],
                                capture_output=True, text=True)
        print(json.dumps({'enabled': enabled.stdout.strip() or 'unknown',
                          'active': active.stdout.strip() or 'unknown',
                          'units': str(unit_dir)}, sort_keys=True))
        return EXIT_OK
    if options.action == 'on':
        write_tooling()
        unit_dir.mkdir(parents=True, exist_ok=True)
        service.write_text(
            '[Unit]\n'
            'Description=SLS Luna updates (applies a newer release when Steam is closed)\n'
            'After=graphical-session.target\n\n'
            '[Service]\n'
            'Type=oneshot\n'
            'Environment=PATH=%%h/.local/bin:/usr/local/bin:/usr/bin\n'
            'ExecStart=%s %s autoupdate\n' % (sys.executable, luna_tools_dir() / 'luna.py'))
        timer.write_text(
            '[Unit]\n'
            'Description=Check the SLS Luna release channel every 30 minutes\n\n'
            '[Timer]\n'
            'OnCalendar=*:0/30\n'
            'Persistent=true\n'
            'RandomizedDelaySec=120\n\n'
            '[Install]\n'
            'WantedBy=timers.target\n')
        subprocess.run(['systemctl', '--user', 'daemon-reload'], capture_output=True)
        result = subprocess.run(['systemctl', '--user', 'enable', '--now', 'luna-autoupdate.timer'],
                                capture_output=True, text=True)
        if result.returncode != 0:
            print('FAILED: %s' % (result.stderr.strip() or result.stdout.strip()), file=sys.stderr)
            return 1
        print('unattended updates: on (%s)' % timer)
        return EXIT_OK
    if options.action == 'off':
        subprocess.run(['systemctl', '--user', 'disable', '--now', 'luna-autoupdate.timer'],
                       capture_output=True)
        for path in (timer, service):
            if path.exists():
                path.unlink()
        subprocess.run(['systemctl', '--user', 'daemon-reload'], capture_output=True)
        print('unattended updates: off')
        return EXIT_OK
    print('unknown timer action: %s' % options.action, file=sys.stderr)
    return 2
HOST_UNIT_MARK = '# Managed by Luna: host v1'
HOST_UNIT = 'luna-host.service'
def host_source():
    """Where the host sources/binary come from: a checkout or an extracted bundle."""
    return Path(os.environ.get('LUNA_HOST_SRC') or (ROOT / 'host'))
def host_binary():
    return luna_home() / 'bin' / 'luna-host'
def host_unit_path():
    return home() / '.config/systemd/user' / HOST_UNIT
def systemctl_user(*args):
    try:
        return subprocess.run(['systemctl', '--user'] + list(args), capture_output=True, text=True)
    except FileNotFoundError:
        return subprocess.CompletedProcess(args, 127, '', 'systemctl not found')
def ensure_host_built():
    """Make sure the host binary exists (release bundles ship it prebuilt)."""
    source = host_source()
    binary = source / 'bin' / 'luna-host'
    if binary.is_file():
        return binary
    if not (source / 'Makefile').is_file():
        print('host      : no luna-host binary and no sources at %s; skipped' % source, file=sys.stderr)
        return None
    print('host      : building luna-host (make -C %s)' % source)
    try:
        result = subprocess.run(['make', '-C', str(source)], capture_output=True, text=True)
    except FileNotFoundError:
        print('host      : WARN: make is not installed; luna-host not built', file=sys.stderr)
        return None
    if result.returncode != 0 or not binary.is_file():
        tail = (result.stderr or result.stdout).strip().splitlines()[-5:]
        print('host      : WARN: the luna-host build failed:\n    %s' % '\n    '.join(tail), file=sys.stderr)
        return None
    return binary
def _replace_tree(source, dest):
    staging = dest.with_name(dest.name + '.luna-new')
    shutil.rmtree(staging, ignore_errors=True)
    shutil.copytree(source, staging, ignore=shutil.ignore_patterns('__pycache__', '*.pyc'))
    shutil.rmtree(dest, ignore_errors=True)
    os.replace(staging, dest)
def host_unit_text():
    return (
        HOST_UNIT_MARK + '\n'
        '[Unit]\n'
        "Description=Luna plugin host (injects Luna's add-ons into Steam)\n"
        'After=graphical-session.target\n\n'
        '[Service]\n'
        'Type=simple\n'
        'Environment=LUNA_HOME=%s\n'
        'Environment=LUNA_LUA_DIR=%s\n'
        'ExecStart=%s\n'
        'Restart=always\n'
        'RestartSec=5\n\n'
        '[Install]\n'
        'WantedBy=default.target\n' % (luna_home(), luna_home() / 'lua', host_binary()))
def install_luna_host(dry_run=False):
    """Deploy luna-host, its Lua tree, the add-ons and the user unit into
    LUNA_HOME. Failures warn; the add-on install goes on."""
    if dry_run:
        print('host      : would install luna-host, its Lua tree, add-ons and %s into %s'
              % (HOST_UNIT, luna_home()))
        return
    binary = ensure_host_built()
    if binary is None:
        return
    source_lua = host_source() / 'lua'
    if not source_lua.is_dir():
        print('host      : WARN: %s is missing; luna-host not installed' % source_lua, file=sys.stderr)
        return
    try:
        target_bin = host_binary()
        target_bin.parent.mkdir(parents=True, exist_ok=True)
        tmp = target_bin.with_name('luna-host.luna-tmp')
        shutil.copy2(binary, tmp)
        tmp.chmod(0o755)
        os.replace(tmp, target_bin)
        _replace_tree(source_lua, luna_home() / 'lua')
        (luna_home() / 'state').mkdir(parents=True, exist_ok=True)
        unit = host_unit_path()
        text = host_unit_text()
        changed = False
        if unit.is_file() and HOST_UNIT_MARK not in unit.read_text(errors='replace'):
            print('host      : %s is not Luna-managed; left in place' % unit, file=sys.stderr)
        elif not unit.is_file() or unit.read_text() != text:
            unit.parent.mkdir(parents=True, exist_ok=True)
            unit.write_text(text)
            changed = True
        if changed:
            systemctl_user('daemon-reload')
        systemctl_user('enable', HOST_UNIT)
    except OSError as error:
        print('host      : WARN: could not install luna-host: %s' % error, file=sys.stderr)
        return
    print('host      : luna-host installed in %s' % luna_home())
    print('host      : restart %s to load this version' % HOST_UNIT)
# Files under $LUNA_HOME/data/ that make up a backup.
# Volatile compressor state (jobs, logs, queue, status) is deliberately left
# out: it is rebuilt on the next run. Everything here is small, local JSON.
BACKUP_PATHS = (
    'playtime',
    'presence.json',
    'hltb.json',
    'hltb-library.json',
    'luna.json',
    'sgdb.json',
    'compressor/settings.json',
)
def _backup_entries():
    """(relative path, absolute path) pairs that exist right now."""
    base = data_dir()
    entries = []
    for rel in BACKUP_PATHS:
        path = base / rel
        if path.is_dir():
            for child in sorted(path.rglob('*')):
                if child.is_file():
                    entries.append((str(child.relative_to(base)), child))
        elif path.is_file():
            entries.append((rel, path))
    return entries
def cmd_backup(options):
    """Write one archive with the Luna user data plus a hash manifest."""
    entries = _backup_entries()
    if not entries:
        print('nothing to back up: %s holds no Luna data' % data_dir())
        return EXIT_OK
    out_dir = Path(options.out).expanduser() if options.out else Path(tempfile.gettempdir())
    out_dir.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime('%Y%m%d-%H%M%S')
    archive = out_dir / ('luna-backup-%s.tar.gz' % stamp)
    manifest = {'created': int(time.time()),
                'createdBy': installed_version(),
                'files': {rel: sha256(path) for rel, path in entries}}
    with tempfile.TemporaryDirectory(prefix='luna-backup-') as work:
        stage = Path(work) / 'stage'
        (stage / 'data').mkdir(parents=True)
        for rel, path in entries:
            dest = stage / 'data' / rel
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(path, dest)
        (stage / 'manifest.json').write_text(json.dumps(manifest, indent=2, sort_keys=True) + '\n')
        with tarfile.open(archive, 'w:gz') as tar:
            tar.add(stage / 'manifest.json', arcname='luna-backup/manifest.json')
            tar.add(stage / 'data', arcname='luna-backup/data')
    print('backup : %s (%d file(s))' % (archive, len(entries)))
    print('note   : includes the SteamGridDB API key (sgdb.json); keep the archive private')
    return EXIT_OK
def cmd_restore(options):
    """Restore a backup archive after validating its manifest.

    Refuses while Steam or the sidecar runs (same rule as install), and never
    overwrites a file that is newer than the archived copy unless --force.
    """
    archive = Path(options.archive).expanduser() if options.archive else None
    if not archive or not archive.is_file():
        print('backup archive not found: %s' % (options.archive or ''), file=sys.stderr)
        return 2
    if steam_running():
        print('REFUSING to restore: Steam is running. '
              'Close it completely (Steam -> Exit) first.')
        return EXIT_REFUSED
    with tempfile.TemporaryDirectory(prefix='luna-restore-') as work:
        extract_dir = Path(work) / 'unpacked'
        extract_dir.mkdir()
        try:
            _safe_extract(archive, extract_dir)
        except (tarfile.TarError, ValueError, OSError) as error:
            print('REFUSING: cannot safely unpack the archive: %s' % error, file=sys.stderr)
            return 1
        roots = [entry for entry in extract_dir.iterdir() if entry.is_dir()]
        root = roots[0] if len(roots) == 1 else extract_dir
        manifest_path = root / 'manifest.json'
        data_root = root / 'data'
        if not manifest_path.is_file() or not data_root.is_dir():
            print('REFUSING: not a Luna backup (manifest.json + data/ required)', file=sys.stderr)
            return 1
        try:
            manifest = json.loads(manifest_path.read_text())
            pinned = manifest.get('files') or {}
        except ValueError:
            print('REFUSING: the backup manifest is not valid JSON', file=sys.stderr)
            return 1
        if not isinstance(pinned, dict):
            print('REFUSING: the backup manifest has no file list', file=sys.stderr)
            return 1
        problems, restored, skipped = [], 0, 0
        for rel in sorted(pinned):
            if '..' in Path(rel).parts or rel.startswith('/'):
                problems.append('unsafe path in manifest: %r' % rel)
                continue
            source = data_root / rel
            if not source.is_file():
                problems.append('archive is missing backed-up file: %s' % rel)
                continue
            if sha256(source) != pinned[rel]:
                problems.append('archived file does not match the manifest: %s' % rel)
                continue
            dest = data_dir() / rel
            if dest.is_file() and not options.force:
                try:
                    newer = dest.stat().st_mtime > source.stat().st_mtime
                except OSError:
                    newer = False
                if newer:
                    print('skip   : %s (current copy is newer; re-run with --force to overwrite)' % rel)
                    skipped += 1
                    continue
            dest.parent.mkdir(parents=True, exist_ok=True)
            tmp = dest.with_name(dest.name + '.luna-tmp')
            shutil.copy2(source, tmp)
            os.replace(tmp, dest)
            restored += 1
        if problems:
            print('REFUSING: the backup did not validate:')
            for problem in problems:
                print('  - %s' % problem, file=sys.stderr)
            return 1
    print('restored %d file(s), skipped %d newer file(s)' % (restored, skipped))
    return EXIT_OK


    print('restored %d file(s), skipped %d newer file(s)' % (restored, skipped))
    return EXIT_OK
def steam_home():
    native = home() / '.local/share/Steam'
    alternate = home() / '.steam/steam'
    return alternate.resolve() if not native.exists() and alternate.is_dir() else native
def steam_client_build():
    """Verified installed binaries, then the on-disk manifest, then runtime logs.

    A package manifest alone does NOT prove that its client was extracted.
    The install receipt is preferred only while the core executable hashes match.
    Newer clients log "Client version: 0" at startup, so a zero report is
    treated as "no information" rather than a build number.
    """
    receipt = read_json_file(luna_tools_dir() / 'steam-client-installed.json') or {}
    core = receipt.get('core') or {}
    if core:
        try:
            if all(sha256(steam_home() / _steam_payload_path(name)) == digest
                   for name, digest in core.items()):
                return str(receipt.get('build') or '')
        except (OSError, ValueError):
            pass
    try:
        manifest = (steam_home() / 'package' / 'steam_client_ubuntu12.manifest').read_text(
            encoding='utf-8', errors='replace')
        found = re.findall(r'"version"\s+"(\d+)"', manifest)
        manifest_build = next((build for build in reversed(found) if build != '0'), '')
        if manifest_build:
            return manifest_build
    except OSError:
        pass
    log = steam_home() / 'logs' / 'console_log.txt'
    try:
        size = log.stat().st_size
    except OSError:
        size = 0
    if size:
        try:
            with open(log, 'rb') as handle:
                handle.seek(max(0, size - 65536))
                tail = handle.read().decode('utf-8', errors='replace')
            found = [build for build in re.findall(r'Client version:\s*(\d+)', tail)
                     if build != '0']
            if found:
                return found[-1]
        except OSError:
            pass
    return ''
STEAM_CFG_BLOCK = ('BootStrapperInhibitAll=enable\n'
                     'BootStrapperForceSelfUpdate=disable\n')
# The hard lock (`luna steam lock`) also stops the launch-time update check and
# is written to both spellings of the file name that Steam's bootstrapper reads.
STEAM_HARD_CFG_BLOCK = ('BootStrapperInhibitAll=enable\n'
                        'BootStrapperInhibitUpdateOnLaunch=enable\n'
                        'BootStrapperForceSelfUpdate=false\n')
_STEAM_CFG_KEYS = re.compile(
    r'\s*BootStrapper(?:InhibitAll|InhibitUpdateOnLaunch|ForceSelfUpdate)\s*=', re.I)
def steam_cfg_path():
    return steam_home() / 'steam.cfg'
def steam_cfg_paths():
    """Both spellings the bootstrapper honors (distinct files on Linux)."""
    return [steam_home() / 'Steam.cfg', steam_home() / 'steam.cfg']
def steam_updates_blocked():
    try:
        content = steam_cfg_path().read_text()
    except OSError:
        return False
    return bool(re.search(r'^\s*BootStrapperInhibitAll\s*=\s*enable\s*$', content, re.M | re.I))
def ensure_steam_cfg_block(paths=None, block=None):
    """Write the bootstrapper inhibit block; Steam honors it on next launch.

    While a hard lock is recorded the hard block goes to both cfg files, so
    every code path that re-applies the block keeps the lock intact.
    """
    hard = steam_hard_lock_active()
    if block is None:
        block = STEAM_HARD_CFG_BLOCK if hard else STEAM_CFG_BLOCK
    if paths is None:
        paths = steam_cfg_paths() if hard else [steam_cfg_path()]
    for path in paths:
        path.parent.mkdir(parents=True, exist_ok=True)
        try:
            previous = path.read_text()
        except FileNotFoundError:
            previous = ''
        lines = [line for line in previous.splitlines() if not _STEAM_CFG_KEYS.match(line)]
        path.write_text('\n'.join(lines + block.splitlines()) + '\n')
    return paths[-1]
def remove_steam_cfg_block(paths=None):
    """Remove the block only if the file holds exactly what Luna wrote.

    Returns True when every file that held a Luna block was removed.
    """
    removed, kept = False, False
    for path in (paths if paths is not None else [steam_cfg_path()]):
        try:
            content = path.read_text()
        except OSError:
            continue
        if content in (STEAM_CFG_BLOCK, STEAM_HARD_CFG_BLOCK):
            try:
                path.unlink()
                removed = True
            except OSError:
                kept = True
        elif any(_STEAM_CFG_KEYS.match(line) for line in content.splitlines()):
            kept = True
    return removed and not kept
def pacman_conf_path():
    return Path(os.environ.get('LUNA_PACMAN_CONF', '/etc/pacman.conf'))
def pacman_steam_state():
    """Is the Steam client pacman-managed, and is it ignored on updates?

    No root needed: `pacman -Q` answers the first, the conf file the second.
    """
    managed, ignored = False, False
    try:
        result = subprocess.run(['pacman', '-Q', 'steam'],
                                capture_output=True, text=True, timeout=15)
        managed = result.returncode == 0
    except (OSError, subprocess.SubprocessError):
        return managed, ignored
    if not managed:
        return managed, ignored
    try:
        content = pacman_conf_path().read_text()
    except OSError:
        return managed, ignored
    for line in content.splitlines():
        stripped = line.split('#', 1)[0].strip()
        if not stripped or '=' not in stripped:
            continue
        key, _, value = stripped.partition('=')
        if key.strip().lower() == 'ignorepkg' and 'steam' in value.split():
            ignored = True
    return managed, ignored
def steam_pin_path():
    return luna_tools_dir() / 'steam-pin.json'
def steam_cache_dir():
    return luna_tools_dir() / 'steam-client-cache'
def steam_pin_copy_path():
    return luna_state_dir() / 'steam-pin.json'
def read_steam_pin():
    pin = read_json_file(steam_pin_path())
    if not isinstance(pin, dict) or not pin:
        pin = read_json_file(steam_pin_copy_path())  # the tools dir was replaced by a base install
    return pin if isinstance(pin, dict) else {}
def sync_steam_pin_copy():
    """Keep a second copy of the pin in Luna's state dir (best effort, quiet)."""
    try:
        pin = read_json_file(steam_pin_path())
        if isinstance(pin, dict) and pin and read_json_file(steam_pin_copy_path()) != pin:
            write_json_file(steam_pin_copy_path(), pin)
    except OSError:
        pass
def remove_steam_pin():
    for path in (steam_pin_path(), steam_pin_copy_path()):
        try:
            path.unlink()
        except OSError:
            pass
def steam_hard_lock_active():
    """Is the ubuntu12 rollback + read-only package lock recorded in the pin?"""
    lock = read_steam_pin().get('hardLock')
    return isinstance(lock, dict) and bool(lock)
def new_steam_pin(build):
    """A pin record for `build`; carries an active hard lock forward."""
    pin = {'clientBuild': str(build), 'launcher': steam_launcher_hashes(),
           'at': int(time.time()), 'by': installed_version()}
    lock = read_steam_pin().get('hardLock')
    if isinstance(lock, dict) and lock:
        pin['hardLock'] = lock
    return pin
@contextlib.contextmanager
def steam_package_writable():
    """Let Luna write into SDIR/package despite the hard lock's read-only bit.

    A no-op when the directory is writable and no hard lock is recorded;
    otherwise (Luna's hard lock, or a read-only bit left by a manual/community
    lock) it is made writable and put back to read-only afterwards, even if
    the work raises.
    """
    package = steam_home() / 'package'
    relock = package.is_dir() and (steam_hard_lock_active() or not os.access(package, os.W_OK))
    if relock:
        package.chmod(package.stat().st_mode | stat.S_IWUSR)
    try:
        yield
    finally:
        if relock and package.is_dir():
            package.chmod(package.stat().st_mode & ~(stat.S_IWUSR | stat.S_IWGRP | stat.S_IWOTH))
def _package_stats(root, with_hash=False):
    """Fingerprint of a package tree: {rel: [size, mtime_ns]} (+ sha256)."""
    stats = {}
    for path in sorted(root.rglob('*')):
        if path.is_file():
            try:
                st = path.stat()
                entry = [st.st_size, st.st_mtime_ns]
                if with_hash:
                    entry.append(sha256(path))
                stats[str(path.relative_to(root))] = entry
            except OSError:
                pass
    return stats
def _cache_manifest():
    manifest = read_json_file(steam_cache_dir() / 'manifest.json')
    return manifest if isinstance(manifest, dict) else {}
def _stats_match(left, right):
    """Size+mtime comparison (hashes, when present, are ignored: fast path)."""
    if not set(left).issubset(right):
        return False
    return all(left[key][:2] == right[key][:2] for key in left)
def packages_match_cache():
    """Do the installed packages still match the cached build?

    None when there is no usable cache; otherwise a size+mtime comparison,
    which is instant and catches any client update or partial download.
    """
    manifest = _cache_manifest()
    if not manifest or not (steam_cache_dir() / 'package').is_dir():
        return None
    target = steam_home() / 'package'
    if not target.is_dir():
        return False
    return _stats_match(manifest, _package_stats(target))
def _package_read_only():
    try:
        return not (steam_home() / 'package').stat().st_mode & stat.S_IWUSR
    except OSError:
        return False
def steam_state():
    """Everything the menu and preflight report about the Steam client."""
    build = steam_client_build()
    pin = read_steam_pin()
    pinned = str(pin.get('clientBuild') or '')
    cache_marker = steam_cache_dir() / 'build.txt'
    try:
        cached = cache_marker.read_text().strip()
    except OSError:
        cached = ''
    cache_ready = bool(cached) and (steam_cache_dir() / 'package').is_dir()
    packages_match = packages_match_cache() if cache_ready else None
    receipt = read_json_file(luna_tools_dir() / 'steam-client-installed.json') or {}
    binaries_match = None
    if receipt.get('core'):
        try:
            binaries_match = all(sha256(steam_home() / _steam_payload_path(name)) == digest
                                 for name, digest in receipt['core'].items())
        except (OSError, ValueError):
            binaries_match = False
    if cache_ready:
        match = packages_match is True and binaries_match is not False and build == pinned
    else:
        match = bool(build and pinned and build == pinned)
    current_hashes = steam_launcher_hashes()
    pinned_hashes = pin.get('launcher') or {}
    tools_drift = [name for name, digest in current_hashes.items()
                   if digest and pinned_hashes.get(name) and digest != pinned_hashes[name]]
    pacman_managed, pacman_ignored = pacman_steam_state()
    return {
        'build': build,
        'pinned': pinned,
        'match': match,
        'packagesMatch': packages_match,
        'binariesMatch': binaries_match,
        'updatesBlocked': steam_updates_blocked(),
        'launcher': current_hashes,
        'launcherDrift': tools_drift,
        'cachedBuild': cached,
        'cacheReady': cache_ready,
        'pacmanManaged': pacman_managed,
        'pacmanIgnored': pacman_ignored,
        'hardLock': bool(pin.get('hardLock')),
        'packageReadOnly': _package_read_only(),
    }
def cached_client_build():
    try:
        return (steam_cache_dir() / 'build.txt').read_text().strip()
    except OSError:
        return ''
def steam_pending_path():
    return luna_tools_dir() / 'pending-steam.json'
def read_steam_pending():
    pending = read_json_file(steam_pending_path())
    return pending if isinstance(pending, dict) else {}
def steam_sh_path():
    override = os.environ.get('LUNA_STEAM_SH')
    if override:
        return Path(override)
    return steam_home() / 'steam.sh'
def _steam_force_update():
    """Run the Steam bootstrapper's forced update and exit.

    Called only with Steam closed. Returns (ok, message). The update block
    is lifted for the run and re-applied afterwards either way.
    """
    if steam_hard_lock_active():
        return False, ('the Steam hard lock is active (package/ read-only, ubuntu12 rollback); '
                       'run: luna steam unlock --now to let Steam update')
    try:
        _steam_client_closed()
    except ValueError as error:
        return False, str(error)
    had_block = steam_updates_blocked()
    try:
        steam_cfg_path().unlink()
    except OSError:
        pass
    try:
        result = subprocess.run([str(steam_sh_path()), '-forcesteamupdate',
                                 '-forcepackagedownload', '-exitsteam'],
                                capture_output=True, text=True, timeout=600)
    except (OSError, subprocess.SubprocessError, subprocess.TimeoutExpired) as error:
        result = None
        failure = str(error)
    if had_block:
        try:
            ensure_steam_cfg_block()
        except OSError:
            pass
    if result is None:
        return False, 'could not run the Steam updater: %s' % failure
    if result.returncode != 0:
        tail = (result.stderr.strip() or result.stdout.strip())[-500:]
        return False, 'Steam updater exited %d: %s' % (result.returncode, tail)
    # The bootstrapper relaunches Steam after a successful update even with
    # -exitsteam. Shut it back down gracefully: the caller asked for Steam to
    # stay closed. Never kill processes; report if it is still up.
    note = ('; block re-applied' if had_block
            else '; updates currently allowed - pin the new build to block them')
    if steam_running():
        try:
            subprocess.run([str(steam_sh_path()), '-shutdown'],
                           capture_output=True, text=True, timeout=30)
        except (OSError, subprocess.SubprocessError, subprocess.TimeoutExpired):
            pass
        deadline = time.monotonic() + 60
        while deadline > time.monotonic():
            if not (steam_running()):
                break
            time.sleep(2)
        if steam_running():
            return False, ('Steam updated but is still running after a shutdown request; '
                           'close it completely (Steam -> Exit) before pinning or installing' + note)
    return True, 'Steam client updated by Valve' + note
def prune_steam_client_backups(keep=5):
    """Keep only the newest `keep` client rollback backups.

    Each successful client install/recovery retains a full rollback copy, so
    without pruning this directory grows without bound. Only directories whose
    names are nanosecond timestamps (written by this installer) are touched;
    anything else is left alone.
    """
    backups = luna_tools_dir() / 'steam-client-backups'
    try:
        entries = [entry for entry in backups.iterdir()
                   if entry.is_dir() and entry.name.isdigit()]
    except OSError:
        return 0
    entries.sort(key=lambda entry: int(entry.name))
    removed = 0
    for entry in entries[:-keep] if len(entries) > keep else []:
        try:
            shutil.rmtree(entry, ignore_errors=False)
            removed += 1
        except OSError:
            pass
    return removed
def _cache_client_packages(build):
    """Snapshot the installed package tree into the local cache.

    The cached manifest must describe `build`; a stale on-disk manifest (or a
    mislabeled earlier cache) is refused instead of silently relabeled.
    """
    source = steam_home() / 'package'
    cache = steam_cache_dir()
    try:
        installed_manifest = (source / STEAM_MANIFEST_NAME).read_text(
            encoding='utf-8', errors='replace')
    except OSError:
        raise ValueError('no Steam package manifest at %s' % (source / STEAM_MANIFEST_NAME))
    found = re.findall(r'"version"\s+"(\d+)"', installed_manifest)
    installed_build = next((item for item in reversed(found) if item != '0'), '')
    if installed_build != build:
        raise ValueError('installed packages describe build %s, not %s; refusing to mislabel the cache'
                         % (installed_build or 'unknown', build))
    if cache.exists():
        shutil.rmtree(cache, ignore_errors=True)
    shutil.copytree(source, cache / 'package', symlinks=False)
    # copytree preserves the hard lock's read-only bit; the cache must stay deletable.
    (cache / 'package').chmod((cache / 'package').stat().st_mode | stat.S_IWUSR)
    (cache / 'build.txt').write_text(build + '\n')
    write_json_file(cache / 'manifest.json', _package_stats(cache / 'package', with_hash=True))
    return cache
STEAM_COMPAT_BUILD = '1791918634'
STEAM_COMPAT_MANIFEST_SHA256 = 'a87699c36d28721af5ca6ade7276f506d22a11f9829747167d96845fc080afa5'
STEAM_ARCHIVE_BASE = ('https://web.archive.org/web/20261014104109if_/'
                      'http://media.steampowered.com/client/')
STEAM_MANIFEST_NAME = 'steam_client_ubuntu12.manifest'
STEAM_CORE_FILES = ('ubuntu12_32/steam', 'ubuntu12_32/steamclient.so',
                    'ubuntu12_64/steamwebhelper')
def _steam_payload_path(name):
    """Valve ZIPs use both slash styles. Never accept account/game/cache paths."""
    path = PurePosixPath(name.replace('\\', '/'))
    protected = {'config', 'userdata', 'steamapps', 'appcache', 'logs', 'depotcache', 'package'}
    if (path.is_absolute() or not path.parts or '..' in path.parts
            or ':' in str(path) or path.parts[0].startswith('.')
            or path.parts[0].lower() in protected):
        raise ValueError('unsafe/protected Steam payload path: %s' % name)
    return path
def _steam_package_entries(data, want):
    manifest = parse_vdf(data.decode('utf-8'))
    body = manifest.get('ubuntu12') or {}
    if body.get('version') != want:
        raise ValueError('Steam manifest is not build %s' % want)
    entries = []
    for values in body.values():
        if not isinstance(values, dict) or 'file' not in values:
            continue
        compressed = 'zipvz' in values
        name = values.get('zipvz') if compressed else values['file']
        digest = values.get('sha2vz' if compressed else 'sha2', '')
        if (not re.fullmatch(r'[A-Za-z0-9_.-]+', name or '')
                or not re.fullmatch(r'[0-9a-f]{64}', digest)):
            raise ValueError('unsafe package name or missing SHA256 in Steam manifest')
        entries.append((name, digest, compressed))
    if not entries:
        raise ValueError('Steam manifest has no verified packages')
    return entries
def _download_steam_file(url, destination, expected, limit=512 * 1024 * 1024):
    request = urllib.request.Request(url, headers={'User-Agent': 'Luna-Steam-Installer'})
    with urllib.request.urlopen(request, timeout=60) as source, open(destination, 'wb') as out:
        size = 0
        while True:
            chunk = source.read(1024 * 1024)
            if not chunk:
                break
            size += len(chunk)
            if size > limit:
                raise ValueError('Steam download exceeds size limit')
            out.write(chunk)
    if sha256(destination) != expected:
        raise ValueError('Steam download SHA256 mismatch: %s' % url)
def _stage_steam_payload(packages, data, want, destination):
    """Verify each package, decode VZip and extract ONLY official client files."""
    entries = {}
    total = 0
    destination.mkdir()
    for name, expected, compressed in _steam_package_entries(data, want):
        source = packages / name
        if source.is_symlink() or sha256(source) != expected:
            raise ValueError('Steam package SHA256 mismatch: %s' % name)
        raw = source.read_bytes()
        if compressed:
            if raw[:3] != b'VZa' or raw[-2:] != b'zv' or len(raw) < 22:
                raise ValueError('invalid Steam VZip header: %s' % name)
            prop = raw[7]
            dictionary = struct.unpack('<I', raw[8:12])[0]
            if prop >= 225 or dictionary > 128 * 1024 * 1024:
                raise ValueError('invalid Steam LZMA properties')
            filters = [{'id': lzma.FILTER_LZMA1, 'dict_size': dictionary,
                        'lc': prop % 9, 'lp': (prop // 9) % 5, 'pb': prop // 45}]
            crc, size = struct.unpack('<II', raw[-10:-2])
            if size > 1024 * 1024 * 1024:
                raise ValueError('Steam archive exceeds size limit')
            decoder = lzma.LZMADecompressor(format=lzma.FORMAT_RAW, filters=filters)
            raw = decoder.decompress(raw[12:-10], max_length=size + 1)
            if not decoder.eof or len(raw) != size or zlib.crc32(raw) != crc:
                raise ValueError('Steam VZip integrity check failed: %s' % name)
        with zipfile.ZipFile(io.BytesIO(raw)) as archive:
            for item in archive.infolist():
                relative = _steam_payload_path(item.filename)
                target = destination / relative
                if not target.parent.resolve().is_relative_to(destination.resolve()):
                    raise ValueError('Steam archive traverses a symlink: %s' % relative)
                if item.is_dir():
                    target.mkdir(parents=True, exist_ok=True)
                    continue
                total += item.file_size
                if item.file_size > 512 * 1024 * 1024 or total > 4 * 1024 * 1024 * 1024:
                    raise ValueError('Steam payload exceeds size limit')
                content = archive.read(item)  # also verifies ZIP CRC
                link = stat.S_ISLNK(item.external_attr >> 16)
                if link:
                    link_target = content.decode('utf-8')
                    if not (target.parent / link_target).resolve().is_relative_to(destination.resolve()):
                        raise ValueError('Steam symlink escapes payload: %s' % relative)
                info = {'sha256': hashlib.sha256(content).hexdigest(), 'link': link}
                key = str(relative)
                if key in entries:
                    if entries[key] != info:
                        raise ValueError('conflicting Steam archive entry: %s' % key)
                    continue
                target.parent.mkdir(parents=True, exist_ok=True)
                if link:
                    target.symlink_to(link_target)
                else:
                    target.write_bytes(content)
                    # Valve's ZIPs mark Linux executables as 0666, even ELF files.
                    target.chmod(0o755 if content.startswith((b'\x7fELF', b'#!')) else 0o644)
                    stamp = time.mktime((*item.date_time, 0, 0, -1))
                    os.utime(target, (stamp, stamp))
                entries[key] = info
    if not set(STEAM_CORE_FILES).issubset(entries):
        raise ValueError('Steam payload is missing core client executables')
    return entries
def _steam_client_closed():
    if any(process_running(name) for name in ('steam', 'steamwebhelper')):
        raise ValueError('Steam is running; close it completely first')
def _install_steam_payload(payload, entries, want, packages):
    """Install extracted binaries transactionally (package/ unlocked meanwhile)."""
    with steam_package_writable():
        return _install_steam_payload_locked(payload, entries, want, packages)
def _install_steam_payload_locked(payload, entries, want, packages):
    """Install extracted binaries transactionally; retain a machine-local backup."""
    _steam_client_closed()
    root = steam_home().resolve()
    backup = luna_tools_dir() / 'steam-client-backups' / str(time.time_ns())
    backup.mkdir(parents=True)
    changed = []
    targets = []
    for name, info in entries.items():
        target = root / _steam_payload_path(name)
        try:
            if target.is_symlink() != info['link']:
                raise OSError('different file type')
            content = os.readlink(target).encode() if info['link'] else target.read_bytes()
            same = hashlib.sha256(content).hexdigest() == info['sha256']
            source = payload / name
            if same and (info['link'] or stat.S_IMODE(target.stat().st_mode) == stat.S_IMODE(source.stat().st_mode)):
                continue
        except OSError:
            pass
        targets.append((target, payload / name))
    data = (packages / STEAM_MANIFEST_NAME).read_bytes()
    for name in [STEAM_MANIFEST_NAME] + [entry[0] for entry in _steam_package_entries(data, want)]:
        source, target = packages / name, root / 'package' / name
        # Preserve package stats so Health can cheaply compare the installed cache.
        if (not target.is_file() or target.is_symlink()
                or source.stat().st_size != target.stat().st_size
                or source.stat().st_mtime_ns != target.stat().st_mtime_ns
                or sha256(source) != sha256(target)):
            targets.append((target, source))
    # Save/update the receipt and cfg in the same transaction as the binaries.
    receipt = luna_tools_dir() / 'steam-client-installed.json'
    marker = root / '.steam-enable-steamrt64-client'
    saved = []
    try:
        for index, (target, _) in enumerate(targets + [(receipt, None), (steam_cfg_path(), None), (marker, None)]):
            if not target.parent.resolve().is_relative_to(root) and target != receipt:
                raise ValueError('Steam destination escapes its root: %s' % target)
            if target.exists() and not target.is_symlink() and not target.is_file():
                raise ValueError('Steam destination is not a regular file: %s' % target)
            previous = backup / str(index)
            exists = target.exists() or target.is_symlink()
            if exists:
                shutil.copy2(target, previous, follow_symlinks=False)
            saved.append((target, previous if exists else None))
        write_json_file(backup / 'restore.json', {
            'build': want, 'files': [{'path': str(path), 'backup': old.name if old else None}
                                    for path, old in saved]})
        _steam_client_closed()  # recheck after slow backup/extraction
        for target, source in targets:
            target.parent.mkdir(parents=True, exist_ok=True)
            temp = target.with_name(target.name + '.luna-new')
            if temp.exists() or temp.is_symlink():
                raise ValueError('Steam temporary destination already exists: %s' % temp)
            try:
                shutil.copy2(source, temp, follow_symlinks=False)
                os.replace(temp, target)
            finally:
                if temp.exists() or temp.is_symlink():
                    temp.unlink()
            changed.append(target)
        for name, info in entries.items():
            target = root / name
            content = os.readlink(target).encode() if info['link'] else target.read_bytes()
            if hashlib.sha256(content).hexdigest() != info['sha256']:
                raise ValueError('installed Steam client verification failed: %s' % name)
        for target in (receipt, steam_cfg_path(), marker):
            changed.append(target)
        if marker.exists() or marker.is_symlink():
            marker.unlink()
        ensure_steam_cfg_block()
        write_json_file(receipt, {'build': want, 'at': int(time.time()), 'backup': str(backup),
                                 'core': {name: entries[name]['sha256'] for name in STEAM_CORE_FILES}})
    except Exception:
        for target, previous in reversed(saved):
            if target not in changed:
                continue
            if target.exists() or target.is_symlink():
                target.unlink()
            if previous is not None:
                shutil.copy2(previous, target, follow_symlinks=False)
        raise
    return backup
def ensure_compatible_steam():
    """Default install policy: fetch/verify the pinned Valve build, then extract it."""
    try:
        _steam_client_closed()
        if read_steam_pending():
            raise ValueError('a Steam task is queued; run: luna steam cancel before installing')
        if not (steam_home() / 'steam.sh').is_file():
            raise ValueError('Steam must be installed and opened once before installing Luna')
        tools = luna_tools_dir()
        tools.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix='steam-client-stage-', dir=tools) as temporary:
            work = Path(temporary)
            packages = work / 'package'
            packages.mkdir()
            manifest = packages / STEAM_MANIFEST_NAME
            sources = (steam_home() / 'package', steam_cache_dir() / 'package')
            for source in sources:
                candidate = source / STEAM_MANIFEST_NAME
                if candidate.is_file() and sha256(candidate) == STEAM_COMPAT_MANIFEST_SHA256:
                    shutil.copy2(candidate, manifest)
                    break
            else:
                _download_steam_file(STEAM_ARCHIVE_BASE + 'steam_client_ubuntu12', manifest,
                                     STEAM_COMPAT_MANIFEST_SHA256, limit=1024 * 1024)
            data = manifest.read_bytes()
            for name, digest, _ in _steam_package_entries(data, STEAM_COMPAT_BUILD):
                destination = packages / name
                for source in sources:
                    candidate = source / name
                    if candidate.is_file() and not candidate.is_symlink() and sha256(candidate) == digest:
                        shutil.copy2(candidate, destination)
                        break
                else:
                    print('steam     : downloading %s' % name, flush=True)
                    try:
                        _download_steam_file('https://client-update.steamstatic.com/' + name, destination, digest)
                    except (OSError, ValueError):
                        _download_steam_file(STEAM_ARCHIVE_BASE + name, destination, digest)
            entries = _stage_steam_payload(packages, data, STEAM_COMPAT_BUILD, work / 'payload')
            # Keep a complete verified cache, not a copy of stale installed metadata.
            cache = steam_cache_dir()
            replacement = work / 'cache'
            prepared_stats = _package_stats(packages, with_hash=True)
            reuse_cache = (cached_client_build() == STEAM_COMPAT_BUILD
                           and _package_stats(cache / 'package', with_hash=True) == prepared_stats)
            if not reuse_cache:
                shutil.copytree(packages, replacement / 'package')
                (replacement / 'build.txt').write_text(STEAM_COMPAT_BUILD + '\n')
                write_json_file(replacement / 'manifest.json', prepared_stats)
            backup = _install_steam_payload(work / 'payload', entries, STEAM_COMPAT_BUILD, packages)
            if reuse_cache:
                write_json_file(cache / 'manifest.json', prepared_stats)
            else:
                if cache.exists():
                    os.replace(cache, backup / 'previous-cache')
                try:
                    os.replace(replacement, cache)
                except OSError:
                    if (backup / 'previous-cache').exists():
                        os.replace(backup / 'previous-cache', cache)
                    raise
            write_json_file(steam_pin_path(), new_steam_pin(STEAM_COMPAT_BUILD))
            pruned = prune_steam_client_backups()
        return True, ('installed and verified Steam client %s executables; updates blocked; backup: %s%s. '
                      'Runtime version will be confirmed on the next Steam launch.'
                      % (STEAM_COMPAT_BUILD, backup,
                         '; pruned %d old backup(s)' % pruned if pruned else ''))
    except (OSError, ValueError, lzma.LZMAError, zipfile.BadZipFile) as error:
        return False, 'Steam client installation failed (not reported as a downgrade): %s' % error
def _recover_steam_client(want):
    """Restore and verify actual cached Steam client executables for `want`.

    Returns (ok, message). Rechecks that Steam is closed internally,
    verifies and extracts the packages, retains a rollback backup, and blocks
    self-updates. Copying package metadata alone can never report success.
    """
    if cached_client_build() != want or not (steam_cache_dir() / 'package').is_dir():
        return False, 'no cache for build %s; run: luna steam cache (Steam closed)' % want
    manifest = _cache_manifest()
    if manifest:
        cached_stats = {}
        for path in sorted((steam_cache_dir() / 'package').rglob('*')):
            if path.is_file():
                try:
                    cached_stats[str(path.relative_to(steam_cache_dir() / 'package'))] = True
                except OSError:
                    pass
        problems = [rel for rel, entry in manifest.items()
                    if not isinstance(entry, list) or len(entry) < 3]
        if problems or set(cached_stats) != set(manifest):
            return False, 'the cache is incomplete; re-run: luna steam cache (Steam closed)'
        for rel, entry in manifest.items():
            try:
                if sha256(steam_cache_dir() / 'package' / rel) != entry[2]:
                    return False, ('the cache failed its own integrity check (%s changed); '
                                     're-run: luna steam cache (Steam closed)' % rel)
            except OSError as error:
                return False, 'cannot read the cache: %s' % error
    # A package-only swap is not a recovery. Extract and verify the executables
    # first; never report success solely from build.txt or a copied manifest.
    try:
        _steam_client_closed()
        packages = steam_cache_dir() / 'package'
        data = (packages / STEAM_MANIFEST_NAME).read_bytes()
        if want == STEAM_COMPAT_BUILD and hashlib.sha256(data).hexdigest() != STEAM_COMPAT_MANIFEST_SHA256:
            raise ValueError('cached compatibility manifest SHA256 mismatch')
        with tempfile.TemporaryDirectory(prefix='steam-recover-', dir=luna_tools_dir()) as work:
            payload = Path(work) / 'payload'
            entries = _stage_steam_payload(packages, data, want, payload)
            backup = _install_steam_payload(payload, entries, want, packages)
    except (OSError, ValueError, lzma.LZMAError, zipfile.BadZipFile) as error:
        return False, 'could not recover Steam client executables: %s' % error
    pruned = prune_steam_client_backups()
    return True, ('recovered and verified Steam client %s executables; updates blocked; backup: %s%s'
                  % (want, backup, '; pruned %d old backup(s)' % pruned if pruned else ''))
def _apply_steam_update():
    """Valve-driven client update with the block lifted, then re-blocked.

    Called only with Steam closed (timer or --now). On success the local
    package cache is stale by definition and is dropped, so a later recover
    can never restore the pre-update build by accident.
    """
    ok, message = _steam_force_update()
    if not ok:
        return False, message
    try:
        shutil.rmtree(steam_cache_dir(), ignore_errors=True)
    except OSError:
        pass
    try:
        steam_pending_path().unlink()
    except OSError:
        pass
    build = steam_client_build()
    note = ('; cache is now stale and was dropped - re-pin after verifying, then re-cache'
            if not build else '; re-pin the new build %s after verifying, then re-cache' % build)
    return True, message + note
def _find_steam_dir():
    """First Steam root that has a package/ dir, symlinks resolved."""
    candidates = [steam_home(), home() / '.local/share/Steam', home() / '.steam/steam',
                  home() / '.steam/root',
                  home() / '.var/app/com.valvesoftware.Steam/.local/share/Steam']
    for candidate in candidates:
        if (candidate / 'package').is_dir():
            return candidate.resolve()
    return None
def _steam_package_set_readonly(package, readonly):
    mode = package.stat().st_mode
    package.chmod(mode & ~0o222 if readonly else mode | stat.S_IWUSR)
def _http_get(url, limit=64 * 1024 * 1024):
    request = urllib.request.Request(url, headers={'User-Agent': 'Luna-Steam-Installer'})
    with urllib.request.urlopen(request, timeout=60) as source:
        data = source.read(limit + 1)
    if len(data) > limit:
        raise ValueError('download exceeds the size limit: %s' % url)
    return data
def _manifest_version(data):
    text = data.decode('utf-8', errors='replace') if isinstance(data, bytes) else data
    found = [item for item in re.findall(r'"version"\s+"(\d+)"', text) if item != '0']
    return found[0] if found else ''
def obtain_pinned_manifest(say):
    """The pinned known-good ubuntu12 manifest bytes, or None when it cannot be obtained.

    Order: Luna cache, then the pinned SteamTracking commit. A copy whose sha256 or
    version differs from the pins raises ValueError (fail closed, never used).
    """
    cached = steam_cache_dir() / 'package' / STEAM_MANIFEST_NAME
    try:
        data = cached.read_bytes()
        if hashlib.sha256(data).hexdigest() == KNOWN_GOOD_MANIFEST_SHA256:
            say('using the pinned ubuntu12 manifest from the Luna cache')
            return data
    except OSError:
        pass
    try:
        data = _http_get(KNOWN_GOOD_MANIFEST_URL)
    except (OSError, urllib.error.URLError) as error:
        say('WARN: could not download the pinned manifest (%s)' % error)
        return None
    if hashlib.sha256(data).hexdigest() != KNOWN_GOOD_MANIFEST_SHA256:
        raise ValueError('the manifest downloaded from SteamTracking %s does not match the pinned sha256; '
                         'refusing' % KNOWN_GOOD_MANIFEST_COMMIT[:12])
    if _manifest_version(data) != KNOWN_GOOD_UBUNTU12_BUILD:
        raise ValueError('the pinned manifest has version %s, expected %s; refusing'
                         % (_manifest_version(data), KNOWN_GOOD_UBUNTU12_BUILD))
    say('downloaded the pinned ubuntu12 manifest (SteamTracking %s)' % KNOWN_GOOD_MANIFEST_COMMIT[:12])
    return data
class ManifestServer:
    """127.0.0.1 server: the pinned manifest for the manifest paths, 302 to Valve's CDN otherwise."""

    MANIFEST_PATHS = ('steam_client_ubuntu12', 'steam_client_ubuntu12.manifest', 'client/steam_client_ubuntu12')

    def __init__(self, data):
        outer = self
        self.hits = 0

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):  # noqa: N802
                path = self.path.split('?', 1)[0].lstrip('/')
                if path in outer.MANIFEST_PATHS:
                    outer.hits += 1
                    self.send_response(200)
                    self.send_header('Content-Type', 'application/octet-stream')
                    self.send_header('Content-Length', str(len(data)))
                    self.end_headers()
                    self.wfile.write(data)
                    return
                if path.startswith('client/'):
                    path = path[len('client/'):]
                self.send_response(302)
                self.send_header('Location', STEAM_CDN + path)
                self.send_header('Content-Length', '0')
                self.end_headers()

            do_HEAD = do_GET  # noqa: N815

            def log_message(self, *args):
                pass

        self.server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        self.port = self.server.server_address[1]
        self.url = 'http://127.0.0.1:%d' % self.port

    def __enter__(self):
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        return self

    def __exit__(self, *exc):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(5)
def _pinned_rollback(sdir, data, say):
    """Run the launcher against the local manifest server; True once a manifest request was served."""
    candidates = [path for path in (sdir / 'ubuntu12_32' / 'steam', sdir / 'steam.sh') if path.is_file()]
    for launcher in candidates:
        with ManifestServer(data) as server:
            say('running %s against the local pinned manifest server (%s)' % (launcher.name, server.url))
            try:
                subprocess.run([str(launcher), '-forcemanifestsuffix', 'ubuntu12', '-forcesteamupdate',
                                '-forcepackagedownload', '-overridepackageurl', server.url, '-exitsteam'],
                               timeout=3600)  # a non-zero exit is tolerated
            except (OSError, subprocess.SubprocessError) as error:
                say('WARN: %s failed: %s' % (launcher.name, error))
            if server.hits > 0:
                return True
        say('WARN: %s never asked for the manifest; trying the next launcher' % launcher.name)
    return False
def _rollback_steam_client(sdir, say):
    """Kill Steam, wipe the steamrt64 client packages and fetch the ubuntu12 client.

    Returns (ok, message). Never touches the cfg/pin; the caller locks only
    after this succeeded. The bootstrapper download is ~500 MB.
    """
    package = sdir / 'package'
    binary = sdir / 'ubuntu12_32' / 'steam'
    if not binary.is_file():
        binary = sdir / 'steam.sh'
    if not binary.is_file():
        return False, 'no Steam launcher found under %s' % sdir
    try:
        pinned = obtain_pinned_manifest(say)
    except ValueError as error:
        return False, 'REFUSING: %s' % error
    uid = str(os.getuid())
    say('stopping Steam')
    for name in ('steam', 'steamwebhelper'):
        subprocess.run(['pkill', '-9', '-u', uid, '-x', name], capture_output=True)
    time.sleep(2)
    _steam_package_set_readonly(package, False)
    for stale in package.glob('steam_client_steamrt64*'):
        stale.unlink()
    for stale in luna_state_dir().glob('safe_mode*'):
        stale.unlink()
    say('downloading the ubuntu12 client (about 500 MB); this can take a while')
    if pinned is not None:
        if not _pinned_rollback(sdir, pinned, say):
            return False, ('the Steam launcher never requested the pinned manifest, so the rollback did '
                           'not happen; package/ was left writable. Run: luna steam recover (offline) or retry')
        return True, 'ubuntu12 client downloaded (pinned manifest %s)' % KNOWN_GOOD_UBUNTU12_BUILD
    say('WARN: the pinned manifest is unavailable; falling back to the current ubuntu12 manifest from '
        "Valve's CDN, which Valve may have retired (SteamTracking deleted it on 2026-11-12)")
    # The Luna block would inhibit this very download; it is re-applied by the caller.
    try:
        subprocess.run([str(binary), '-forcemanifestsuffix', 'ubuntu12', '-exitsteam'],
                       timeout=3600)  # a non-zero exit is tolerated, as in the community script
    except (OSError, subprocess.SubprocessError) as error:
        return False, 'Steam bootstrapper failed: %s' % error
    return True, 'ubuntu12 client downloaded'
def _lock_steam_client(force, confirm):
    """`luna steam lock`: roll back to the ubuntu12 client and hard-lock updates."""
    sdir = _find_steam_dir()
    if sdir is None:
        return 1, 'no Steam installation with a package/ directory found'
    if sdir != steam_home().resolve():
        return 1, ('Steam found at %s, but Luna manages %s; refusing to lock a layout it '
                   'cannot pin' % (sdir, steam_home()))
    if read_steam_pending():
        return EXIT_REFUSED, 'a Steam task is queued; run: luna steam cancel first'
    running = [name for name in ('steam', 'steamwebhelper') if process_running(name)]
    if running and not force and not confirm():
        return EXIT_REFUSED, ('REFUSING: Steam is running and lock must kill it (kill -9, unsaved '
                              'state is lost). Close it, or re-run with --force.')

    def say(text):
        print('lock    : %s' % text, flush=True)

    if steamos_gaming_mode():
        say('WARN: SteamOS Gaming Mode detected; run lock from Desktop Mode')
    # The bootstrapper must be free to download: lift Luna's block for the run.
    had_block = steam_updates_blocked() or steam_hard_lock_active()
    remove_steam_cfg_block(steam_cfg_paths())
    try:
        ok, message = _rollback_steam_client(sdir, say)
    except OSError as error:
        ok, message = False, 'rollback failed: %s' % error
    if not ok:
        if had_block:
            ensure_steam_cfg_block()
        return 1, message
    say(message)
    build = steam_client_build()
    if not build:
        if had_block:
            ensure_steam_cfg_block()
        return 1, ('rolled back, but the client build cannot be determined; launch Steam once '
                   'and re-run: luna steam lock')
    tools = luna_tools_dir()
    tools.mkdir(parents=True, exist_ok=True)
    # Pin first (carrying the lock marker) so every block/cfg helper agrees.
    pin = new_steam_pin(build)
    pin['hardLock'] = {'rollback': 'ubuntu12', 'at': int(time.time()), 'by': installed_version()}
    write_json_file(steam_pin_path(), pin)
    # The old receipt/cache describe the previous build and would read as drift.
    shutil.rmtree(steam_cache_dir(), ignore_errors=True)
    try:
        write_json_file(tools / 'steam-client-installed.json', {
            'build': build, 'at': int(time.time()), 'backup': '',
            'core': {name: sha256(sdir / _steam_payload_path(name)) for name in STEAM_CORE_FILES}})
    except (OSError, ValueError):
        try:
            (tools / 'steam-client-installed.json').unlink()
        except OSError:
            pass
    try:
        _cache_client_packages(build)
    except (OSError, ValueError) as error:
        say('warning: could not cache build %s (%s); run: luna steam cache' % (build, error))
    ensure_steam_cfg_block()
    _steam_package_set_readonly(sdir / 'package', True)
    if luna_state_dir().is_dir():
        (luna_state_dir() / 'boot_fail_count').write_text('0\n')
    say(note if code == 0 else 'WARN: %s' % note)
    return 0, ('Steam rolled back to the ubuntu12 client (build %s), pinned and hard-locked: '
               'Steam.cfg + steam.cfg written, package/ read-only. Undo: luna steam unlock' % build)
def flatpak_steam_only():
    return (home() / '.var/app/com.valvesoftware.Steam').is_dir() and not steam_home().is_dir()
FLATPAK_WARNING = 'WARN: Steam is the Flatpak build; Luna supports native Steam only'
def steamos_gaming_mode():
    try:
        text = Path(OS_RELEASE_PATH).read_text()
    except OSError:
        return False
    if not re.search(r'^ID="?steamos"?\s*$', text, re.M):
        return False
    try:
        return subprocess.run(['pgrep', '-u', str(os.getuid()), '-f', 'gamescope-session'],
                              capture_output=True).returncode == 0
    except OSError:
        return False
def _notify(title, text):
    """Best-effort desktop notification; never fails the job."""
    if os.environ.get('LUNA_NO_NOTIFY'):
        return
    try:
        subprocess.run(['notify-send', '-a', 'Luna', title, text], capture_output=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        pass
def _launch_steam_detached():
    try:
        subprocess.Popen(['setsid', 'steam'], stdin=subprocess.DEVNULL,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                         start_new_session=True)
        return True
    except OSError as error:
        print('could not launch Steam: %s' % error, file=sys.stderr)
        return False
def _close_steam_gracefully(timeout=90):
    """`steam -shutdown`, then wait for the client to exit. True when it is gone."""
    if not process_running('steam'):
        return True
    try:
        subprocess.run(['steam', '-shutdown'], capture_output=True, timeout=30)
    except (OSError, subprocess.SubprocessError):
        pass
    for _ in range(timeout):
        if not process_running('steam'):
            return True
        time.sleep(1)
    return False
def _unlock_steam_client(now):
    """`luna steam unlock`: undo the hard lock and the pin."""
    package = steam_home() / 'package'
    if package.is_dir():
        _steam_package_set_readonly(package, False)
        print('package/ is writable again')
    if remove_steam_cfg_block(steam_cfg_paths()):
        print('update block removed: Steam may update itself again')
    elif any(path.exists() for path in steam_cfg_paths()):
        print('note: Steam.cfg/steam.cfg left in place (they hold more than the Luna block)')
    try:
        steam_pin_path().unlink()
        remove_steam_pin()
        print('pin and hard-lock marker removed')
    except OSError:
        print('no pin to remove')
    if now:
        if process_running('steam'):
            print('Steam is already running; restart it to let it self-update')
        else:
            try:
                subprocess.Popen(['setsid', 'steam'], stdin=subprocess.DEVNULL,
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                 start_new_session=True)
                print('Steam launched; it will self-update to the latest client')
            except OSError as error:
                print('could not launch Steam: %s' % error, file=sys.stderr)
                return 1
    return EXIT_OK
def cmd_steam(options):
    """Pin, cache and recover the Steam client build (see `luna steam --help`)."""
    action = getattr(options, 'steam_action', '') or 'status'
    if action == 'status':
        state = steam_state()
        print('client : %s' % (state['build'] or 'unknown (Steam never logged a version here)'))
        print('pinned : %s' % (state['pinned'] or 'none (run: luna steam pin)'))
        print('packages: %s' % ('match the pin' if state['match']
                                 else 'DIFFER from the pin - run: luna steam recover (Steam closed)'
                                 if state['pinned'] and state['cacheReady']
                                 else 'unknown (no cache)'))
        print('updates: %s' % ('blocked (steam.cfg)' if state['updatesBlocked'] else 'NOT blocked'))
        if state['hardLock']:
            print('lock   : HARD (ubuntu12 rollback, package/ %s)'
                  % ('read-only' if state['packageReadOnly']
                     else 'WRITABLE - re-run: luna steam lock'))
        if state['pacmanManaged']:
            print('pacman : Steam is system-managed%s'
                  % (', ignored on updates' if state['pacmanIgnored']
                     else ' and NOT ignored - add "IgnorePkg = steam" to /etc/pacman.conf (needs sudo)'))
        for name, digest in sorted(state['launcher'].items()):
            print('%-16s %s' % (name + ':', digest[:12] if digest else '(missing)'))
        if state['launcherDrift']:
            print('WARN   : the Steam launcher changed since the pin: %s'
                  % ', '.join(state['launcherDrift']))
        for line in heal_steam_lock(apply=False)['notes']:  # read-only: status never repairs
            print('WARN   : %s' % line)
        print('cache  : %s' % ('build ' + state['cachedBuild'] if state['cacheReady']
                                else 'empty (run: luna steam cache with Steam closed)'))
        pending = read_steam_pending()
        if pending:
            print('queued : %s (requested %s; run: luna steam update --now, or luna steam cancel)'
                  % (pending.get('action', '?'),
                     time.strftime('%Y-%m-%d %H:%M', time.localtime(int(pending.get('at') or 0)))))
        return EXIT_OK
    if action == 'heal':
        result = heal_steam_lock()
        if not result['pinned']:
            print('heal  : nothing to heal; no Steam build is pinned (luna steam pin / luna steam lock)')
            return EXIT_OK
        print_heal(result)
        if not result['fixed'] and not result['notes']:
            print('heal  : update block and read-only state are intact')
        return EXIT_OK
    if action == 'history':
        return cmd_history(options)
    if action == 'pin':
        build = options.build or steam_client_build()
        if not build:
            print('cannot determine the client build; pass --build N explicitly', file=sys.stderr)
            return 2
        pin = new_steam_pin(build)
        luna_tools_dir().mkdir(parents=True, exist_ok=True)
        write_json_file(steam_pin_path(), pin)
        ensure_steam_cfg_block()
        print('pinned Steam client %s; updates blocked via steam.cfg' % build)
        return EXIT_OK
    if action == 'lock':
        def confirm():
            if not sys.stdin.isatty():
                return False
            answer = input('Steam is running and will be killed (kill -9). Continue? [y/N] ')
            return answer.strip().lower() in ('y', 'yes')
        code, message = _lock_steam_client(getattr(options, 'force', False), confirm)
        print(message, file=sys.stdout if code == 0 else sys.stderr)
        if getattr(options, 'relaunch', False):
            # Detached-job mode (in-Steam UI): report, then bring Steam back even on failure.
            _notify('Luna: Steam updates blocked' if code == 0 else 'Luna: could not block Steam updates',
                    message[:200])
            _launch_steam_detached()
        return code
    if action == 'unlock':
        if getattr(options, 'relaunch', False):
            # Close Steam first so the next start runs the bootstrapper and self-updates.
            if not _close_steam_gracefully():
                print('Steam did not close in time; nothing was changed', file=sys.stderr)
                _notify('Luna: Steam update not started', 'Steam did not close; try again.')
                return 1
            code = _unlock_steam_client(False)
            if code == EXIT_OK:
                _notify('Luna: Steam unblocked', 'Steam is restarting and will update to the latest client.')
                _launch_steam_detached()
            else:
                _notify('Luna: could not unblock Steam', 'Run: luna steam unlock in a terminal.')
            return code
        return _unlock_steam_client(bool(getattr(options, 'now', False)))
    if action in ('cache', 'unpin'):
        if action == 'unpin':
            remove_steam_pin()
            remove_steam_cfg_block()
            print('unpinned: updates are allowed again')
            return EXIT_OK
        if steam_running():
            print('REFUSING to cache: Steam is running. Close it completely (Steam -> Exit) first.')
            return EXIT_REFUSED
        build = options.build or steam_client_build()
        if not build:
            print('cannot determine the client build; pass --build N explicitly', file=sys.stderr)
            return 2
        ok, message = _cache_client_packages(build)
        print(message, file=sys.stdout if ok else sys.stderr)
        return EXIT_OK if ok else 1
    if action == 'update':
        if getattr(options, 'now', False):
            if steam_running():
                print('REFUSING: Steam is running; --now applies immediately and needs it closed.',
                      file=sys.stderr)
                return EXIT_REFUSED
            ok, message = _apply_steam_update()
            print(message, file=sys.stderr if not ok else sys.stdout)
            return EXIT_OK if ok else 1
        existing = read_steam_pending()
        if existing:
            print('a Steam task is already queued (%s); run: luna steam cancel first'
                  % existing.get('action', '?'), file=sys.stderr)
            return 1
        write_json_file(steam_pending_path(), {'action': 'update', 'at': int(time.time())})
        print('Steam update queued: it applies the next time Steam is closed by '
              '`luna steam update --now`')
        return EXIT_OK
    if action == 'cancel':
        try:
            steam_pending_path().unlink()
            print('queued Steam task cancelled')
        except OSError:
            print('nothing queued')
        return EXIT_OK
    if action == 'recover':
        if steam_running():
            print('REFUSING to recover: Steam is running. '
                  'Close it completely (Steam -> Exit) first.')
            return EXIT_REFUSED
        want = str(options.build or '')
        pin = read_steam_pin()
        if not want:
            want = str(pin.get('clientBuild') or '')
        if not want:
            print('nothing pinned; run: luna steam pin [--build N]', file=sys.stderr)
            return 2
        ok, message = _recover_steam_client(want)
        if not ok:
            print(message, file=sys.stderr)
            return 1
        print(message)
        print('launch Steam and verify, then run: luna steam pin')
        return EXIT_OK
    print('unknown steam action: %s (status|pin|unpin|cache|recover|update|cancel|lock|unlock|'
          'heal|history)' % action, file=sys.stderr)
    return 2
def _cfg_block_present(paths, block):
    """Does every file hold all of the block's key lines, with none contradicted?"""
    want = {line.strip().lower() for line in block.splitlines() if line.strip()}
    want_keys = {line.split('=', 1)[0] for line in want}
    for path in paths:
        try:
            lines = path.read_text().splitlines()
        except OSError:
            return False
        have = {line.strip().lower() for line in lines if _STEAM_CFG_KEYS.match(line)}
        if not want <= have:
            return False
        if any(line.split('=', 1)[0] in want_keys and line not in want for line in have):
            return False
    return True
def heal_steam_lock(apply=True):
    """Restore the update block a third-party installer may have removed.

    Applies when a Steam build is pinned (or the hard lock is recorded):
    re-writes steam.cfg (+ Steam.cfg under the hard lock) and puts package/
    back to read-only. Only cfg + chmod, so it is safe while Steam runs.
    Launcher drift is reported, never re-pinned silently (`luna steam pin`
    is the only thing that does that). Returns {'pinned', 'fixed', 'notes'}.
    """
    result = {'pinned': False, 'fixed': [], 'notes': []}
    pin = read_steam_pin()
    if not pin or not (pin.get('clientBuild') or pin.get('hardLock')):
        return result
    if apply:
        if not steam_pin_path().is_file():  # restore the primary from the copy
            with contextlib.suppress(OSError):
                write_json_file(steam_pin_path(), pin)
                result['fixed'].append('steam-pin.json was missing; restored from %s' % steam_pin_copy_path())
        sync_steam_pin_copy()
    if not steam_home().is_dir():
        return result
    result['pinned'] = True
    hard = steam_hard_lock_active()
    paths = steam_cfg_paths() if hard else [steam_cfg_path()]
    block = STEAM_HARD_CFG_BLOCK if hard else STEAM_CFG_BLOCK
    names = ' + '.join(path.name for path in paths)
    if not _cfg_block_present(paths, block):
        if apply:
            ensure_steam_cfg_block()
            result['fixed'].append('update block was missing or changed; re-wrote %s' % names)
        else:
            result['notes'].append('update block missing or changed in %s (heal would re-write it)' % names)
    package = steam_home() / 'package'
    if hard and package.is_dir() and package.stat().st_mode & 0o222:
        if apply:
            _steam_package_set_readonly(package, True)
            result['fixed'].append('package/ was writable; made it read-only again')
        else:
            result['notes'].append('package/ is writable (heal would make it read-only)')
    now = steam_launcher_hashes()
    drift = sorted(name for name, digest in (pin.get('launcher') or {}).items() if now.get(name, '') != digest)
    if drift:
        result['notes'].append('the Steam launcher changed since the pin (%s); NOT re-pinned. '
                               'Verify it, then run: luna steam pin' % ', '.join(drift))
    build = str(pin.get('clientBuild') or '')
    if build and (cached_client_build() != build or not (steam_cache_dir() / 'package').is_dir()):
        result['notes'].append('no known-good cache for build %s; run: luna steam cache (Steam closed)' % build)
    if result['fixed']:
        try:
            luna_tools_dir().mkdir(parents=True, exist_ok=True)
            with open(luna_tools_dir() / 'steam-heal.log', 'a') as log:
                for line in result['fixed']:
                    log.write('%s %s\n' % (time.strftime('%Y-%m-%d %H:%M:%S'), line))
        except OSError:
            pass
    return result
def print_heal(result, prefix='heal  '):
    for line in result['fixed']:
        print('%s: FIXED: %s' % (prefix, line))
    for line in result['notes']:
        print('%s: WARN: %s' % (prefix, line))
# Known-good ubuntu12 client (the manifest "version" field; ubuntu12_32/steam and
# steamclient.so were built 2026-10-22). Bump these two lines when a newer
# rollback client has been validated (see README "Bumping the known-good build").
KNOWN_GOOD_UBUNTU12_BUILD = '1792618285'
KNOWN_GOOD_UBUNTU12_DATE = 'Oct 22 2026'
# Valve deleted the ubuntu12 manifests from SteamTracking HEAD on 2026-11-12, so the exact
# manifest is pinned by commit + sha256. To bump: pick a commit from `luna steam history`,
# download its file, set the three values (version must equal KNOWN_GOOD_UBUNTU12_BUILD).
KNOWN_GOOD_MANIFEST_COMMIT = '4acc42276f213dd41516da7863064fffb8711f6d'
KNOWN_GOOD_MANIFEST_SHA256 = '5e474d18586e39cac7650382c25c7b4ca1ec2bed785f4eaa36f4ca6d3c9b5d60'
KNOWN_GOOD_MANIFEST_URL = ('https://raw.githubusercontent.com/SteamTracking/SteamTracking/%s/'
                           'ClientManifest/steam_client_ubuntu12' % KNOWN_GOOD_MANIFEST_COMMIT)
STEAM_CDN = 'https://client-fastly.steamstatic.com/client/'
STEAMTRACKING_HISTORY_URL = ('https://api.github.com/repos/SteamTracking/SteamTracking/commits')
LIBCRYPTO_SHA256 = 'c1a4d22c176c8869b3f91083e5c9ff7921da791294397c7db2814281fc99467f'
OS_RELEASE_PATH = '/etc/os-release'
def known_good_line():
    """(ok, text): is the installed ubuntu12 manifest the recorded known-good build?"""
    try:
        text = (steam_home() / 'package' / STEAM_MANIFEST_NAME).read_text(encoding='utf-8', errors='replace')
        found = [build for build in re.findall(r'"version"\s+"(\d+)"', text) if build != '0']
        build = found[-1] if found else ''
    except OSError:
        build = ''
    if build == KNOWN_GOOD_UBUNTU12_BUILD:
        return True, ('Steam client: known-good ubuntu12 build %s (%s)'
                      % (KNOWN_GOOD_UBUNTU12_BUILD, KNOWN_GOOD_UBUNTU12_DATE))
    return False, ('WARN: Steam client: manifest version %s, known-good is ubuntu12 build %s (%s); '
                   'Valve may have republished it, or run: luna steam lock'
                   % (build or 'unreadable', KNOWN_GOOD_UBUNTU12_BUILD, KNOWN_GOOD_UBUNTU12_DATE))
def luna_state_dir():
    """Machine-local Luna state: $LUNA_HOME/state (default ~/.local/share/Luna/state)."""
    return luna_home() / 'state'
def cmd_doctor(options):
    """Environment diagnostics: what Luna needs and what it found."""
    problems = 0
    print('luna       : %s' % luna_home())
    print('repository : %s' % ROOT)
    for tool in ('git', 'make', 'cc', 'node'):
        path = shutil.which(tool)
        print('%-10s : %s' % (tool, path or 'not found (optional)'))
    steam_dir = _find_steam_dir()
    print('steam      : %s' % (steam_dir or 'not found'))
    if steam_dir:
        debugging = steam_dir / '.cef-enable-remote-debugging'
        print('cef debug  : %s (%s)' % ('enabled' if debugging.is_file() else 'not enabled',
                                        debugging))
        state = steam_state()
        print('client     : %s%s, updates %s'
              % (state['build'] or '?',
                 (', pinned %s' % state['pinned']) if state['pinned'] else ', not pinned',
                 'blocked' if state['updatesBlocked'] else 'allowed'))
    else:
        problems += 1
    print('host       : %s' % ('present' if host_binary().is_file() else 'not built'))
    print('unit       : %s (%s)' % (host_unit_path(), unit_state(HOST_UNIT)))
    print('add-ons    : %s' % (', '.join('%s %s' % (name, addon_version(name)) for name in ADDONS)))
    if not installed_addons():
        print('note       : nothing is installed yet: run luna install')
    if not MANIFEST_PATH.is_file():
        problems += 1
        print('FAIL       : %s is missing' % MANIFEST_PATH)
    print('\n%s' % ('OK: no blocking problem found.' if not problems
                     else '%d blocking problem(s) found.' % problems))
    return EXIT_OK if not problems else 1
def cmd_install(options):
    targets = selected_addons(options)
    reasons = refuse_reasons(for_install=True)
    if reasons:
        print('REFUSING to install:')
        for reason in reasons:
            print('  - %s' % reason)
        return EXIT_REFUSED
    rows = plan(targets)
    to_write = [row for row in rows if row[4] in ('new', 'differs')]
    print('plan for %s:' % ', '.join(targets))
    for addon, label, source, dest, state in rows:
        print('  %-9s %-22s %s' % (addon, label, state))
    if options.dry_run:
        if not getattr(options, 'no_steam_machine', False):
            code = steam_machine_action('install', dry_run=True,
                                        migrate=getattr(options, 'migrate_steam_machine', False))
            if code:
                return code
        if getattr(options, 'lock_steam_client', False) or getattr(options, 'steam_build', ''):
            print('steam     : would pin and hard-lock the Steam client build')
        install_luna_host(dry_run=True)
        print('\nDRY RUN: %d file(s) would change, nothing was written.' % len(to_write))
        return EXIT_OK
    differing = [row for row in to_write if row[4] == 'differs']
    if differing and not options.force:
        print('\nREFUSING to overwrite %d file(s) that differ from the pinned payloads:' % len(differing))
        for addon, label, source, dest, state in differing:
            print('  %s/%s (installed %s)' % (addon, label, dest))
        print('Re-run with --force if you really want to replace them.')
        return EXIT_NEEDS_FORCE

    # The Steam client is only touched when asked: a plain install never moves it.
    if getattr(options, 'lock_steam_client', False) or getattr(options, 'steam_build', ''):
        steam_build = getattr(options, 'steam_build', '') or ''
        if steam_build:
            if steam_build != STEAM_COMPAT_BUILD:
                print('REFUSING: --steam-build supports only the verified historical build %s'
                      % STEAM_COMPAT_BUILD, file=sys.stderr)
                return EXIT_REFUSED
            ok, message = ensure_compatible_steam()
            print('steam     : %s' % message, file=sys.stdout if ok else sys.stderr)
            if not ok:
                return 1
        elif steam_hard_lock_active() and steam_state().get('binariesMatch') is not False:
            print('steam     : ubuntu12 hard lock already active; keeping it (build %s)'
                  % (read_steam_pin().get('clientBuild') or '?'))
            print_heal(heal_steam_lock(), 'steam     ')
        else:
            code, message = _lock_steam_client(False, lambda: False)
            print('steam     : %s' % message, file=sys.stdout if code == 0 else sys.stderr)
            if code != 0:
                return 1
    # Shortcuts run before any add-on byte changes: a helper failure must not
    # report a successful install of the payloads as a failure (or the other way
    # round), and the run stays repeatable.
    if not getattr(options, 'no_steam_machine', False):
        code = steam_machine_action('install', migrate=getattr(options, 'migrate_steam_machine', False))
        if code:
            print('FAILED: SteamOS Mode shortcuts could not be updated; '
                  'no add-on files were changed by this run.', file=sys.stderr)
            return code
    if not to_write:
        write_install_snapshot()
        write_tooling()
        install_luna_host()
        if read_steam_pin():
            ensure_steam_cfg_block()
        print('\nAlready installed and identical to the pinned payloads. Nothing to do.')
        clear_install_marker()
        return EXIT_OK

    undo_root = archive_previous(differing, 'undo')
    if undo_root:
        print('undo      : previous copies of %d differing file(s) saved to %s'
              % (len(differing), undo_root))
    apply = Apply()
    write_install_marker(targets, force=bool(getattr(options, 'force', False)))
    try:
        apply.mkdir(addons_dir())
        for addon, label, source, dest, state in rows:
            if state in ('new', 'differs'):
                apply.write(source, dest)
    except BaseException as error:  # noqa: BLE001 - Ctrl-C/SIGTERM must roll back too
        failures = apply.rollback()
        if not failures:
            # The tree is consistent again, so the marker would be a lie.
            clear_install_marker()
        print('FAILED: %s' % error, file=sys.stderr)
        if failures:
            print('%d change(s) could not be undone; `luna status` now reports an '
                  'interrupted install.' % failures, file=sys.stderr)
        else:
            print('Every add-on change made by this run was rolled back.', file=sys.stderr)
        if isinstance(error, Exception):
            return 1
        raise

    write_install_snapshot()
    write_tooling()
    install_luna_host()
    if read_steam_pin():
        # A pin means updates must stay blocked, so re-apply the block right
        # away (Steam is closed here).
        ensure_steam_cfg_block()
        print('steam.cfg : update block re-applied (a Steam build is pinned)')
    print('\ninstalled: %s' % ', '.join('%s %s' % (name, addon_version(name)) for name in targets))
    print('add-ons  : %s' % addons_dir())
    print('\nRestart Steam (Steam -> Exit, then launch it again) to load the add-ons.')
    clear_install_marker()
    return EXIT_OK
def cmd_uninstall(options):
    targets = selected_addons(options)
    for name in targets:
        shutil.rmtree(addons_dir() / name, ignore_errors=True)
        print('removed %s' % name)
    snapshot = addons_dir() / 'luna-manifest.json'
    if snapshot.is_file():
        snapshot.unlink()
    if not installed_addons():
        # Last one out: stop and remove the units, so nothing keeps restarting
        # a host with no add-ons left to serve.
        try:
            unit_dir, service, timer = unit_paths()
            subprocess.run(['systemctl', '--user', 'disable', '--now', timer.name],
                           capture_output=True)
            subprocess.run(['systemctl', '--user', 'disable', '--now', HOST_UNIT],
                           capture_output=True)
            for path in (timer, service, host_unit_path()):
                try:
                    if path.exists():
                        path.unlink()
                except OSError:
                    pass
            subprocess.run(['systemctl', '--user', 'daemon-reload'], capture_output=True)
            print('units    : luna-host and the update timer removed')
        except Exception:  # noqa: BLE001 - uninstall must succeed even if systemd is absent
            pass
    print('Local playtime and presence data were left untouched.')
    if steam_machine_action('uninstall'):
        print('Some SteamOS Mode shortcuts could not be removed; custom edits were preserved.',
              file=sys.stderr)
    return EXIT_OK
def cmd_verify(options):
    manifest = load_manifest()
    problems = []
    checked = 0
    expected = {}
    for name in ADDONS:
        entry = manifest.get('addons', {}).get(name)
        if not entry:
            problems.append('manifest has no entry for %s' % name)
            continue
        expected_paths = set()
        for rel, meta in entry.get('files', {}).items():
            path = payload_path(name, meta['source_path'])
            expected_paths.add(path)
            if not path.is_file():
                problems.append('missing payload %s/%s' % (name, rel))
                continue
            if sha256(path) != meta['sha256']:
                problems.append('payload %s/%s does not match the manifest' % (name, rel))
            else:
                checked += 1
        expected[name] = expected_paths
    for rel, meta in manifest.get('shared', {}).items():
        path = ROOT / rel
        if not path.is_file():
            problems.append('missing shared file %s' % rel)
            continue
        if sha256(path) != meta['sha256']:
            problems.append('shared file %s does not match the manifest' % rel)
        else:
            checked += 1
    # A payload directory must contain exactly what the manifest lists, otherwise
    # a removed or renamed file could survive in the checkout unnoticed.
    for name, expected_paths in expected.items():
        directory = ROOT / 'addons' / name
        for path in sorted(directory.rglob('*')):
            if path.is_file() and path not in expected_paths:
                problems.append('unexpected file in the payload: %s' % path.relative_to(ROOT))
    print('manifest   : %d file(s) verified, generated %s' % (checked, manifest.get('generated', '?')))
    for name in ADDONS:
        entry = manifest.get('addons', {}).get(name, {})
        print('  %-9s %s' % (name, entry.get('plugin_version', '?')))
    if problems:
        print('\nPROBLEMS:')
        for problem in problems:
            print('  - %s' % problem)
        return 1
    print('\nOK: the payloads match the manifest.')
    return EXIT_OK
def steam_machine_action(action, dry_run=False, migrate=False):
    script = ROOT / 'scripts/steam-machine.py'
    if not script.is_file():
        script = luna_tools_dir() / 'steam-machine.py'
    if not script.is_file():
        if action == 'uninstall':
            return EXIT_OK
        print('Steam Machine helper missing; reinstall Luna from a complete bundle.', file=sys.stderr)
        return 1
    command = [sys.executable, str(script), action]
    if dry_run:
        command.append('--dry-run')
    if migrate:
        command.append('--migrate-legacy')
    return subprocess.run(command).returncode
def cmd_launchers(options):
    return steam_machine_action('install', options.dry_run, options.migrate_legacy)
STEAM_LOCKED_ACTIONS = ('lock', 'unlock', 'recover', 'update', 'cache')
def format_history(commits):
    """Lines for a SteamTracking commits API payload (pure; the network part is separate)."""
    lines = []
    for item in commits if isinstance(commits, list) else []:
        sha = str(item.get('sha') or '')
        commit = item.get('commit') or {}
        message = str(commit.get('message') or '').splitlines()[0] if commit.get('message') else ''
        when = str((commit.get('author') or {}).get('date') or '')[:10]
        marks = []
        if sha == KNOWN_GOOD_MANIFEST_COMMIT:
            marks.append('KNOWN-GOOD (pinned)')
        if message.lower().startswith('delete'):
            marks.append('manifest deleted')
        lines.append('%s  %s  %s%s' % (sha[:12], when, message, ('   <- ' + ', '.join(marks)) if marks else ''))
    return lines


def cmd_history(options):
    try:
        data = json.loads(_http_get(STEAMTRACKING_HISTORY_URL, limit=4 * 1024 * 1024))
    except urllib.error.HTTPError as error:
        if error.code in (403, 429):
            print('history: GitHub rate limit reached (HTTP %d); try again later.' % error.code, file=sys.stderr)
        else:
            print('history: GitHub answered HTTP %d' % error.code, file=sys.stderr)
        return 1
    except (OSError, urllib.error.URLError, ValueError) as error:
        print('history: cannot reach GitHub (%s); the pinned known-good commit is %s'
              % (error, KNOWN_GOOD_MANIFEST_COMMIT), file=sys.stderr)
        return 1
    print('SteamTracking ClientManifest/steam_client_ubuntu12 (newest first):')
    for line in format_history(data):
        print('  ' + line)
    return EXIT_OK


def cmd_steam_guard(options):
    """Steam lock/unlock/recover/update/cache take the writer lock, so a queued
    update job cannot start in the middle of them."""
    if getattr(options, 'steam_action', 'status') in STEAM_LOCKED_ACTIONS:
        return run_locked(cmd_steam, options)
    return cmd_steam(options)
# One lock for every command that writes: timer, menu, shell.
cmd_install_locked = locked(cmd_install)
cmd_uninstall_locked = locked(cmd_uninstall)
cmd_launchers_locked = locked(cmd_launchers)
cmd_backup_locked = locked(cmd_backup)
cmd_restore_locked = locked(cmd_restore)
def build_parser():
    parser = argparse.ArgumentParser(prog='luna', description=__doc__,
                                     epilog=EXIT_EPILOG,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest='command')
    for name, handler in (('install', cmd_install_locked), ('uninstall', cmd_uninstall_locked),
                          ('status', cmd_status), ('verify', cmd_verify),
                          ('doctor', cmd_doctor), ('launchers', cmd_launchers_locked),
                          ('steam', cmd_steam_guard), ('update', cmd_update),
                          ('release', cmd_release), ('backup', cmd_backup_locked),
                          ('restore', cmd_restore_locked), ('timer', cmd_timer),
                          ('check', cmd_check)):
        child = sub.add_parser(name)
        child.set_defaults(handler=handler)
        child.add_argument('--only', action='append', default=[],
                           help='restrict to one add-on (repeatable): %s' % ', '.join(ADDONS))
        if name == 'install':
            child.add_argument('--strict', action='store_true',
                               help='fail when the installed payloads differ')
            child.add_argument('--force', action='store_true',
                               help='overwrite payloads that differ')
            child.add_argument('--dry-run', action='store_true', help='print the plan and stop')
            child.add_argument('--lock-steam-client', action='store_true',
                               help='also pin and hard-lock the Steam client build')
            child.add_argument('--steam-build', metavar='BUILD',
                               help='roll back to a specific (verified) client build')
            child.add_argument('--no-steam-machine', action='store_true',
                               help='do not touch SteamOS Mode shortcuts')
            child.add_argument('--migrate-steam-machine', action='store_true',
                               help='rewrite shortcuts that point at an old install')
        if name == 'status':
            child.add_argument('--strict', action='store_true',
                               help='report a modified payload as corrupt')
        if name == 'steam':
            child.add_argument('steam_action', nargs='?', default='status',
                               choices=['status', 'pin', 'unpin', 'cache', 'recover',
                                        'update', 'cancel', 'lock', 'unlock', 'heal', 'history'],
                               help='what to do (default: status)')
            child.add_argument('--force', action='store_true',
                               help='with lock: kill a running Steam without asking')
            child.add_argument('--relaunch', action='store_true',
                               help='with lock/unlock: notify the result and reopen Steam detached')
            child.add_argument('--build', help='client build for pin/cache/recover (default: detected/pinned)')
            child.add_argument('--now', action='store_true',
                               help='with update: apply right away instead of queueing '
                                    '(Steam must be closed); with unlock: launch Steam so it self-updates')
        if name == 'check':
            child.add_argument('--force', action='store_true', help='ignore the 6h cache')
        if name == 'timer':
            child.add_argument('action', choices=['on', 'off', 'status'],
                                help='enable, disable or report the unattended-update timer')
        if name == 'release':
            child.add_argument('--out', help='output directory (default: dist/)')
            child.add_argument('--publish', action='store_true',
                               help='create or refresh a GitHub release with the bundle (needs gh)')
        if name == 'update':
            child.add_argument('--bundle', help='install from a local bundle tarball')
            child.add_argument('--url', help='install from a bundle URL (a .sha256 beside it is verified)')
            child.add_argument('--latest', action='store_true',
                               help='download the newest release asset (needs gh)')
            child.add_argument('--dry-run', action='store_true', help='print the plan and stop')
        if name == 'backup':
            child.add_argument('--out', help='output directory (default: system temp dir)')
        if name == 'restore':
            child.add_argument('archive', help='backup archive to restore')
            child.add_argument('--force', action='store_true',
                               help='overwrite files newer than the archive')
        if name == 'launchers':
            child.add_argument('--dry-run', action='store_true', help='show launcher changes without writing')
            child.add_argument('--migrate-legacy', action='store_true',
                               help='also rewrite shortcuts that point at an old install')
    return parser


def unit_state(unit):
    """active/inactive/unknown for a user unit, without starting anything."""
    result = subprocess.run(['systemctl', '--user', 'is-active', unit],
                            capture_output=True, text=True)
    return result.stdout.strip() or 'unknown'


def main(argv=None):
    parser = build_parser()
    options = parser.parse_args(argv)
    if not getattr(options, 'handler', None):
        parser.print_help()
        return EXIT_OK
    if getattr(options, 'command', '') == 'install' \
            and threading.current_thread() is threading.main_thread():
        def _stop(signum, _frame):
            raise SystemExit(128 + signum)  # so `finally` blocks (Steam lock, rollback) run
        old = {sig: signal.signal(sig, _stop) for sig in (signal.SIGTERM, signal.SIGHUP)}
        try:
            return options.handler(options)
        finally:
            for sig, handler in old.items():
                signal.signal(sig, handler)
    return options.handler(options)


if __name__ == '__main__':
    sys.exit(main())

def steam_launcher_hashes():
    """Hashes of the Steam files the pin records, so drift is visible."""
    root = _find_steam_dir()
    hashes = {}
    if not root:
        return hashes
    for rel in ('steam.sh', 'ubuntu12_32/steam', 'linux64/steamwebhelper'):
        path = root / rel
        try:
            hashes[rel] = sha256(path) if path.is_file() else ''
        except OSError:
            hashes[rel] = ''
    return hashes
