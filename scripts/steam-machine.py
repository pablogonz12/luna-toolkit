#!/usr/bin/env python3
"""Luna-owned Steam Machine launchers; no game/account data or shell launch commands."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time


DRM_ROOT = Path('/sys/class/drm')


def paths():
    home = Path.home()
    tools = home / '.local/share/Luna/state'
    data = Path(os.environ.get('XDG_DATA_HOME') or home / '.local/share')
    if not data.is_absolute():
        data = home / '.local/share'
    return tools, data / 'applications', home / '.local/bin/luna-steam-machine'


def digest(content):
    return hashlib.sha256(content).hexdigest()


MARKER = 'X-Luna-SteamOS=true'


def has_marker(content):
    """Luna stamps every launcher it writes. The stamp alone never grants ownership."""
    try:
        text = content.decode('utf-8')
    except UnicodeDecodeError:
        return False
    return any(line.strip() == MARKER for line in text.splitlines())


def read_state():
    try:
        state = json.loads((paths()[0] / 'steam-machine-shortcuts.json').read_text())
        if isinstance(state, dict) and isinstance(state.get('files'), dict):
            return state
    except (OSError, ValueError):
        pass
    return {'files': {}, 'profiles': {}}


def profile(width, height, refresh):
    values = tuple(int(value) for value in (width, height, refresh))
    if not (640 <= values[0] <= 7680 and 480 <= values[1] <= 4320 and 24 <= values[2] <= 360):
        raise ValueError('Unsupported Steam Machine dimensions/refresh: %s' % (values,))
    return dict(zip(('width', 'height', 'refresh'), values))


def discover_profiles():
    """Render targets, not monitor modesetting. Never persist EDID/serial data."""
    found = {(1920, 1080, 60): profile(1920, 1080, 60)}
    try:
        result = subprocess.run(['niri', 'msg', '--json', 'outputs'], capture_output=True,
                                text=True, timeout=5)
        outputs = json.loads(result.stdout) if result.returncode == 0 else {}
        for output in outputs.values() if isinstance(outputs, dict) else []:
            modes = output.get('modes') or []
            if not modes:
                continue
            current = output.get('current_mode')
            mode = (modes[current] if isinstance(current, int) and 0 <= current < len(modes)
                    else max(modes, key=lambda m: (m['width'] * m['height'], m['refresh_rate'])))
            item = profile(mode['width'], mode['height'], round(mode['refresh_rate'] / 1000))
            found[tuple(item.values())] = item
        if len(found) > 1:
            return list(found.values())
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError):
        pass
    for status in sorted(DRM_ROOT.glob('card*-*/status')):
        try:
            if status.read_text().strip() != 'connected':
                continue
            first = (status.parent / 'modes').read_text().splitlines()[0]
            width, height = first.split('x')
            item = profile(width, height, 60)
            found[tuple(item.values())] = item
        except (OSError, ValueError, IndexError):
            continue
    return list(found.values())


def desktop_arg(value):
    # Desktop Entry Exec quoting is not shell quoting. Percent is a field code.
    return '"' + str(value).replace('\\', '\\\\').replace('"', '\\"').replace('`', '\\`').replace('$', '\\$').replace('%', '%%') + '"'


STEAMOS_PREFIX = 'steamos-'
OLD_SCHEME_PREFIXES = ('steam-machine', 'luna-steam-machine')


def entry_name(item):
    return 'steamos-%dx%d-%d.desktop' % (item['width'], item['height'], item['refresh'])


def entry_label(item):
    width, height, refresh = (item[key] for key in ('width', 'height', 'refresh'))
    resolution = {(1920, 1080): '1080p', (2560, 1440): '2K', (2880, 1800): '3K',
                  (3840, 2160): '4K'}.get((width, height), '%dx%d' % (width, height))
    return 'SteamOS (%s %d)' % (resolution, refresh)


def is_old_scheme(name):
    return name.endswith('.desktop') and name.startswith(OLD_SCHEME_PREFIXES)


def mode_key(item):
    return (item['width'], item['height'], item['refresh'])


def desktop_entry(item):
    tools, _, wrapper = paths()
    width, height, refresh = (item[key] for key in ('width', 'height', 'refresh'))
    label = entry_label(item).replace('\n', ' ').replace('\r', ' ')
    command = '%s --width %d --height %d --refresh %d' % (desktop_arg(wrapper), width, height, refresh)
    return ('[Desktop Entry]\nName=%s\nComment=Steam Big Picture; SDL mouse compatibility; render target %dx%d at %d fps\n'
            'Exec=%s\nTryExec=gamescope\nIcon=steam\nTerminal=false\nType=Application\nCategories=Game;\n'
            'X-Luna-SteamOS=true\nActions=FreePointer;\n\n[Desktop Action FreePointer]\n'
            'Name=Launch with free mouse pointer\nExec=%s --mouse-mode free\n'
            % (label, width, height, refresh, command, command)).encode()


def legacy_profile(path):
    """Recognize only simple Gamescope+Steam launchers; never execute their shell."""
    text = path.read_text()
    match = re.search(r'^Exec=(.*)$', text, re.M)
    if not match:
        return None
    outer = shlex.split(match.group(1))
    if len(outer) == 3 and outer[:2] == ['sh', '-c']:
        match = re.search(r'(?:^|;)\s*gamescope\s+(.+)$', outer[2])
        if not match:
            return None
        prefix = outer[2][:match.start()].strip()
        allowed_prefix = r'(?:(?:killall(?: -9)? (?:steam|gamescope) 2>/dev/null|sleep [0-9]+);\s*)*'
        if prefix and not re.fullmatch(allowed_prefix, prefix.rstrip(';') + ';'):
            return None
        arguments = shlex.split(match.group(1))
    elif outer and Path(outer[0]).name == 'gamescope':
        arguments = outer[1:]
    else:
        return None
    if '--' not in arguments:
        return None
    split = arguments.index('--')
    options, child = arguments[:split], arguments[split + 1:]
    if child[:1] == [str(Path.home() / '.local/bin/ccd-launch')]:
        if child[1:4] not in (['--group', 'auto', '--'], ['--group', 'e', '--']):
            return None
        child = child[4:]
    allowed = {'steam'}
    if len(child) != 2 or child[0] not in allowed or child[1] not in ('-bigpicture', '-gamepadui'):
        return None
    values = {}
    flags = {'--rt', '--fullscreen', '-f', '--steam', '-e', '--force-grab-cursor'}
    dimensions = {'-W': 'width', '-H': 'height', '-r': 'refresh', '-w': 'inner_width', '-h': 'inner_height'}
    index = 0
    while index < len(options):
        option = options[index]
        if option in flags:
            index += 1
        elif option in dimensions and index + 1 < len(options):
            values[dimensions[option]] = int(options[index + 1])
            index += 2
        elif option == '-O' and index + 1 < len(options) and re.fullmatch(r'[A-Za-z0-9_.,-]+', options[index + 1]):
            # -O never selected an output in a nested session; retain only the render profile.
            index += 2
        else:
            return None
    if not all(key in values for key in ('width', 'height', 'refresh')):
        return None
    if values.get('inner_width', values['width']) != values['width'] or values.get('inner_height', values['height']) != values['height']:
        return None
    item = profile(values['width'], values['height'], values['refresh'])
    return item


def atomic_write(path, content, mode):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix='.luna-machine-', dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as out:
            out.write(content)
        os.chmod(temporary, mode)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def archive_owned(tools, path):
    """Keep the bytes of a file before it is replaced."""
    folder = tools / 'archive'
    folder.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime('%Y%m%d-%H%M%S')
    target = folder / ('%s.%s' % (path.name, stamp))
    suffix = 0
    while target.exists():
        suffix += 1
        target = folder / ('%s.%s-%d' % (path.name, stamp, suffix))
    atomic_write(target, path.read_bytes(), 0o600)
    print('archived previous copy: %s' % target)
    return target


def base_modes(state):
    modes = {}
    for item in discover_profiles():
        modes[mode_key(item)] = item
    # Previously managed profiles stay covered while their display is gone,
    # whatever shortcut name a previous Luna version used.
    old_profiles = {}
    for name, item in (state.get('profiles') or {}).items():
        try:
            checked = profile(item['width'], item['height'], item['refresh'])
        except (KeyError, TypeError, ValueError):
            continue
        old_profiles[name] = checked
        modes.setdefault(mode_key(checked), checked)
    return modes, old_profiles


def build_desired(modes):
    tools, applications, wrapper = paths()
    installed = tools / 'steam-machine.py'
    wrapper_bytes = ('#!/bin/sh\n# Luna-managed SteamOS Mode entry point.\nexec %s %s run "$@"\n'
                     % (shlex.quote(sys.executable), shlex.quote(str(installed)))).encode()
    desired = {installed: (Path(__file__).read_bytes(), 0o755), wrapper: (wrapper_bytes, 0o755)}
    for item in modes.values():
        desired[applications / entry_name(item)] = (desktop_entry(item), 0o644)
    return desired


def classify(path, content, old, adopt):
    """Decide what to do with a desired file. Never returns 'write' over unrecorded edits.

    'write'  : absent, identical, or untouched since Luna wrote it (silent upgrade)
    'adopt'  : the owner asked for Luna's version explicitly (old bytes get archived)
    'edited' : bytes differ from what Luna last wrote, or Luna has no record
    'foreign': no record and no Luna marker
    """
    if path.is_symlink():
        raise ValueError('Refusing to replace a launcher symlink: %s' % path)
    if not path.exists():
        return 'write'
    current = path.read_bytes()
    if current == content:
        return 'write'
    if str(path) in adopt:
        return 'adopt'
    recorded = old.get('sha256') if old else None
    if recorded and digest(current) == recorded:
        return 'write'
    if not recorded and path.suffix == '.desktop' and not has_marker(current):
        return 'foreign'
    return 'edited'


def kept_line(path, kind, behind):
    if kind == 'foreign':
        return 'kept (not a Luna file): %s' % path
    line = 'kept (edited outside Luna): %s' % path
    if behind:
        line += " - Luna's version has changed since, so this copy is behind"
    return line


def resolve_adopt(adopt, desired):
    chosen = set()
    for raw in adopt or []:
        matches = [path for path in desired if str(path) == str(Path(raw).expanduser()) or path.name == raw]
        if not matches:
            raise ValueError('--adopt %s is not a file Luna manages (see: steam-machine.py status)' % raw)
        chosen.update(str(path) for path in matches)
    return chosen


def install(dry_run=False, migrate_legacy=False, adopt=()):
    tools, applications, wrapper = paths()
    state = read_state()
    installed = tools / 'steam-machine.py'
    modes, old_profiles = base_modes(state)
    adopted = {}
    if migrate_legacy:
        for path in sorted(applications.glob('steam-machine*.desktop')):
            if path.is_symlink():
                continue
            try:
                item = legacy_profile(path)
            except (OSError, ValueError):
                item = None
            if item:
                modes.setdefault(mode_key(item), item)
                if str(path) not in state['files']:
                    adopted[str(path)] = item
            elif str(path) not in state['files']:
                print('preserved custom launcher: %s' % path)
    desired = build_desired(modes)
    adopt_set = resolve_adopt(adopt, desired)
    planned = {}
    archive = set()
    kept = {}
    for path, (content, mode) in desired.items():
        old = state['files'].get(str(path))
        action = classify(path, content, old, adopt_set)
        if action in ('edited', 'foreign'):
            recorded = old.get('sha256') if old else None
            kept[path] = (action, bool(recorded) and recorded != digest(content))
            continue
        if action == 'adopt':
            archive.add(path)
        planned[path] = (content, mode)
    # Adopt-and-rename: recognized legacy launchers move to the SteamOS scheme.
    # First-time adoptions are backed up; previously managed old-scheme files
    # carry their backup reference over. Edited files and symlinks are preserved.
    retire = []
    for name, item in list(old_profiles.items()) + [(p, i) for p, i in adopted.items()]:
        path = Path(name)
        if path.parent == Path('.'):
            # Profile entries are bare shortcut names; resolve them here.
            path = applications / path.name
        if path.parent != applications or not is_old_scheme(path.name):
            continue
        info = state['files'].get(str(path), {})
        if path.is_symlink():
            print('preserved launcher symlink: %s' % path)
            continue
        if path.exists() and info and digest(path.read_bytes()) != info.get('sha256'):
            print('preserved edited launcher: %s' % path)
            continue
        if mode_key(item) not in modes:
            continue
        retire.append((path, item, info))
    if dry_run:
        for path in planned:
            print('would %s: %s' % ('adopt (archive old, then overwrite)' if path in archive else 'manage', path))
        for path, (kind, behind) in kept.items():
            print('would keep: ' + kept_line(path, kind, behind))
        for path, item, _ in retire:
            print('would retire: %s -> %s' % (path, applications / entry_name(item)))
        return 0
    backup_dir = tools / 'steam-machine-backups' / str(time.time_ns())
    previous = {}
    try:
        for path, (content, mode) in planned.items():
            previous[path] = (path.read_bytes(), path.stat().st_mode & 0o777) if path.exists() else None
            old = state['files'].get(str(path), {})
            if not path.exists() or path.read_bytes() != content or path.stat().st_mode & 0o777 != mode:
                if path in archive:
                    archive_owned(tools, path)
                atomic_write(path, content, mode)
            state['files'][str(path)] = dict(old, sha256=digest(content))
        for path, item, info in retire:
            new_path = applications / entry_name(item)
            previous[path] = (path.read_bytes(), path.stat().st_mode & 0o777) if path.exists() else None
            original = info.get('original')
            if not original and path.exists():
                saved = backup_dir / path.name
                atomic_write(saved, path.read_bytes(), 0o600)
                original = str(saved)
            path.unlink(missing_ok=True)
            if str(path) in state['files']:
                del state['files'][str(path)]
            if original:
                current = state['files'].get(str(new_path), {})
                state['files'][str(new_path)] = dict(current, original=original,
                                                     migrated_from=str(path))
            print('retired old shortcut name: %s -> %s' % (path.name, new_path.name))
        # Kept files stay quiet on later runs; they are reported again only when the
        # file or Luna's own version of it changes. `status` always lists them.
        old_kept = state.get('kept') if isinstance(state.get('kept'), dict) else {}
        state['kept'] = {}
        announce = []
        for path, (kind, behind) in kept.items():
            seen = {'seen': digest(path.read_bytes()), 'luna': digest(desired[path][0]), 'kind': kind}
            state['kept'][str(path)] = seen
            if old_kept.get(str(path)) != seen:
                announce.append(kept_line(path, kind, behind))
        state['profiles'] = {entry_name(item): dict(zip(('width', 'height', 'refresh'), key))
                             for key, item in modes.items()}
        atomic_write(tools / 'steam-machine-shortcuts.json', (json.dumps(state, indent=2, sort_keys=True) + '\n').encode(), 0o600)
    except Exception:
        for path, old in reversed(list(previous.items())):
            if old is None:
                path.unlink(missing_ok=True)
            else:
                atomic_write(path, *old)
        raise
    if shutil.which('update-desktop-database'):
        subprocess.run(['update-desktop-database', str(applications)], capture_output=True, timeout=15)
    for line in announce:
        print(line)
    if announce:
        script = Path(__file__).resolve()
        print('  compare with Luna\'s version: python3 %s status --diff' % shlex.quote(str(script)))
        print('  adopt Luna\'s version (archives yours first): python3 %s install --adopt PATH' % shlex.quote(str(script)))
    print('SteamOS Mode shortcuts: %d; SDL mouse compatibility' % len(modes))
    return 0


def status(show_diff=False):
    """Read-only: list files Luna kept because they were edited outside Luna."""
    state = read_state()
    modes, _ = base_modes(state)
    desired = build_desired(modes)
    found = 0
    for path, (content, _) in desired.items():
        kind = classify(path, content, state['files'].get(str(path)), set())
        if kind not in ('edited', 'foreign'):
            continue
        found += 1
        recorded = (state['files'].get(str(path)) or {}).get('sha256')
        print(kept_line(path, kind, bool(recorded) and recorded != digest(content)))
        if show_diff:
            import difflib
            old = path.read_bytes().decode('utf-8', 'replace').splitlines(True)
            new = content.decode('utf-8', 'replace').splitlines(True)
            sys.stdout.writelines(difflib.unified_diff(old, new, str(path), "Luna's version"))
    if not found:
        print('No files kept: everything Luna manages is Luna-written.')
    return 0
    if any(info.get('original') for info in state['files'].values()):
        print('Original launcher backups: %s' % (tools / 'steam-machine-backups'))
    return 0


def uninstall():
    tools, applications, wrapper = paths()
    state = read_state()
    for name, info in list(state['files'].items()):
        path = Path(name)
        if path not in (tools / 'steam-machine.py', wrapper) and path.parent != applications:
            continue
        if path.is_symlink() or (path.exists() and digest(path.read_bytes()) != info.get('sha256')):
            print('preserved edited launcher: %s' % path)
            continue
        if info.get('original'):
            saved = Path(info['original'])
            if not saved.resolve().is_relative_to((tools / 'steam-machine-backups').resolve()):
                raise ValueError('Unsafe original launcher backup path')
            # Adopt-and-rename entries restore the original bytes to the
            # pre-migration path and drop the SteamOS file (when unchanged).
            old_path = Path(info['migrated_from']) if info.get('migrated_from') else path
            atomic_write(old_path, saved.read_bytes(), 0o644)
            if old_path != path and (not path.exists() or digest(path.read_bytes()) == info.get('sha256')):
                path.unlink(missing_ok=True)
        else:
            path.unlink(missing_ok=True)
        del state['files'][name]
    state['profiles'] = {name: item for name, item in (state.get('profiles') or {}).items()
                         if str(applications / name) in state['files']}
    atomic_write(tools / 'steam-machine-shortcuts.json', (json.dumps(state, indent=2, sort_keys=True) + '\n').encode(), 0o600)
    return 0


def launch_command(options):
    item = profile(options.width, options.height, options.refresh)
    steam = shutil.which('steam')
    if not steam:
        raise ValueError('steam was not found in PATH. Install Steam first.')
    gamescope = shutil.which('gamescope')
    if not gamescope:
        raise ValueError('Gamescope is not installed. Install it with your system package manager first.')
    niri = bool(os.environ.get('NIRI_SOCKET')) or 'niri' in os.environ.get('XDG_CURRENT_DESKTOP', '').lower()
    capture = options.mouse_mode == 'captured' or (options.mouse_mode == 'auto' and niri)
    backend = options.backend
    if capture and backend == 'wayland':
        raise ValueError('Use the SDL backend for captured mouse mode; the Wayland backend can freeze pointer motion.')
    command = [gamescope, '--backend', backend, '-W', str(item['width']), '-H', str(item['height']),
               '-w', str(item['width']), '-h', str(item['height']), '-r', str(item['refresh']), '--fullscreen', '--steam', '--mangoapp']
    if capture:
        command.append('--force-grab-cursor')
    # gamescope tells Steam that mangoapp exists, and Steam then drives its visibility
    # (the QAM performance overlay level, hidden by default) and overrides keybinds.
    # Hide that from the client so the overlay follows our config and Shift_R+F12 alone.
    command.append('--')
    hotkey = Path.home() / '.local/bin/mangoapp-hotkey'
    if hotkey.is_file() and os.access(hotkey, os.X_OK):
        # mangoapp samples its own toggle key (0.1-0.5 s apart) and misses most presses.
        # This helper watches the session keyboard and sends mangoapp a toggle message.
        command += ['/bin/sh', '-c', '"$0" & exec "$@"', str(hotkey)]
    command += [shutil.which('env') or '/usr/bin/env', '-u', 'WAYLAND_DISPLAY', '-u', 'MANGOHUD', '-u', 'MANGOHUD_CONFIG',
                '-u', 'STEAM_USE_MANGOAPP', '-u', 'STEAM_MANGOAPP_PRESETS_SUPPORTED',
                '-u', 'STEAM_MANGOAPP_HORIZONTAL_SUPPORTED',
                # MANGOHUD=0: mangoapp already draws the overlay here, so keep the per-game layer
                # (~/.local/share/vulkan/implicit_layer.d/MangoHud-steam.*.json) from adding a second one.
                'MANGOHUD=0',
                'SDL_VIDEODRIVER=x11', 'SDL_VIDEO_DRIVER=x11', 'GDK_BACKEND=x11', 'QT_QPA_PLATFORM=xcb']
    cpu = Path.home() / '.local/bin/ccd-launch'
    if cpu.is_file() and os.access(cpu, os.X_OK):
        # CCD layout: Steam client on CCD1 (group e); games reach CCD0 through steam-ccd-pin.
        command += [str(cpu), '--group', 'e', '--']
    command = command + [str(steam), '-gamepadui']
    if cpu.is_file() and os.access(cpu, os.X_OK):
        # gamescope (the compositor) must stay on all CPUs, whatever slice the launcher itself sits in.
        command = [str(cpu), '--group', 'all', '--'] + command
    return command


def steam_running():
    for proc in Path('/proc').iterdir():
        if not proc.name.isdigit():
            continue
        try:
            if proc.stat().st_uid == os.getuid() and (proc / 'comm').read_text().strip() in {'steam', 'steamwebhelper'}:
                if (proc / 'stat').read_text().split(') ', 1)[1].split()[0] != 'Z':
                    return True
        except (OSError, IndexError):
            continue
    return False


def terminate_steam_stack(timeout=20):
    """End a stale Steam session so a new one can start.

    SIGTERMs the exact Steam stack (client and web helper) and
    waits for it to exit. Game and reaper processes have different names and
    are never targeted, but killing Steam out from under a running game still
    orphans it: save and close games first. Raises if anything is still alive
    after the timeout instead of launching into a half-dead session.
    """
    if shutil.which('pkill') is None:
        raise ValueError('pkill is not available; close Steam completely (Steam -> Exit) first.')
    for name in ('steam', 'steamwebhelper'):
        subprocess.run(['pkill', '-x', name], capture_output=True)
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if not steam_running():
            return
        time.sleep(1)
    raise ValueError('Steam processes did not exit after pkill; '
                     'close Steam completely (Steam -> Exit) first.')


def run(options):
    command = launch_command(options)
    if options.print_command:
        print(shlex.join(command))
        return 0
    runtime = Path(os.environ.get('XDG_RUNTIME_DIR') or Path.home() / '.cache')
    runtime.mkdir(parents=True, exist_ok=True)
    with (runtime / 'luna-steam-machine.lock').open('a+') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise ValueError('A Luna Steam Machine session is already running.')
        terminated = False
        if steam_running():
            # The shortcut owns the session switch: end the stale Steam stack
            # (pkill -x steam and its helpers) instead of refusing to launch.
            print('Luna SteamOS Mode: ending the running Steam session first.', flush=True)
            terminate_steam_stack()
            terminated = True
        # SDL must control the host window; only the child is forced onto the
        # Gamescope Xwayland display. Do not inherit a single-driver Wayland pin.
        env = os.environ.copy()
        env['SDL_VIDEODRIVER'] = 'wayland,x11' if env.get('WAYLAND_DISPLAY') else 'x11'
        env['SDL_VIDEO_DRIVER'] = env['SDL_VIDEODRIVER']
        # gamescope --steam otherwise writes a throwaway config containing only
        # "no_display" and points MANGOHUD_CONFIGFILE at it, so mangoapp starts
        # hidden and our layout and toggle key are ignored. Pin the real config.
        env['MANGOHUD_CONFIGFILE'] = str(Path.home() / '.config/MangoHud/MangoHud.conf')
        # Read that file, but park mangoapp's built-in toggle on an unused key:
        # the mangoapp-hotkey helper owns the toggle (the key is still toggle_hud in the file).
        if os.access(Path.home() / '.local/bin/mangoapp-hotkey', os.X_OK):
            env['MANGOHUD_CONFIG'] = 'read_cfg,toggle_hud=F24'
        log = Path.home() / '.local/state/Luna/steam-machine.log'
        log.parent.mkdir(parents=True, exist_ok=True)
        with log.open('ab') as out:
            out.write(('\nLuna SteamOS Mode: SDL backend, mouse=%s%s\n'
                       % (options.mouse_mode,
                          ', previous Steam session terminated' if terminated else '')).encode())
            out.flush()
            result = subprocess.run(command, env=env, stdout=out, stderr=subprocess.STDOUT)
        if result.returncode:
            raise ValueError('Gamescope exited with code %d. See %s' % (result.returncode, log))
        return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    install_parser = sub.add_parser('install')
    install_parser.add_argument('--dry-run', action='store_true')
    install_parser.add_argument('--migrate-legacy', action='store_true')
    install_parser.add_argument('--adopt', action='append', default=[], metavar='PATH',
                                help="overwrite this kept file with Luna's version (old bytes are archived first)")
    status_parser = sub.add_parser('status')
    status_parser.add_argument('--diff', action='store_true')
    sub.add_parser('uninstall')
    launch = sub.add_parser('run')
    launch.add_argument('--width', type=int, default=1920)
    launch.add_argument('--height', type=int, default=1080)
    launch.add_argument('--refresh', type=int, default=60)
    launch.add_argument('--mouse-mode', choices=('auto', 'captured', 'free'), default='free')
    launch.add_argument('--backend', choices=('sdl', 'wayland'), default='sdl')
    launch.add_argument('--print-command', action='store_true')
    options = parser.parse_args()
    try:
        if options.command == 'install':
            return install(options.dry_run, options.migrate_legacy, options.adopt)
        if options.command == 'status':
            return status(options.diff)
        if options.command == 'uninstall':
            return uninstall()
        return run(options)
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        message = 'Luna Steam Machine: %s' % error
        print(message, file=sys.stderr)
        if options.command == 'run' and not options.print_command and shutil.which('notify-send'):
            try:
                subprocess.run(['notify-send', '--app-name=Luna', 'Steam Machine could not start', str(error)], timeout=10)
            except (OSError, subprocess.SubprocessError):
                pass
        return 1


if __name__ == '__main__':
    sys.exit(main())
