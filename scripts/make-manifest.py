#!/usr/bin/env python3
"""Write vendor/MANIFEST.json: sha256 of every payload in this tree.

Maintainer tool: run it after changing an add-on, then `luna verify`.
"""
import hashlib
import json
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ADDONS = ('luna', 'sgdb', 'graphics', 'playtime', 'presence', 'compressor')
SHARED = ('install.sh', 'uninstall.sh', 'scripts/steam-machine.py')


def digest(path):
    h = hashlib.sha256()
    with open(path, 'rb') as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()


def main():
    manifest = {'generated': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
                'addons': {}, 'shared': {}}
    for name in ADDONS:
        root = ROOT / 'addons' / name / 'plugin'
        files = {}
        for path in sorted(root.rglob('*')):
            if not path.is_file():
                continue
            rel = str(path.relative_to(root))
            files[rel] = {'source_path': 'plugin/' + rel, 'sha256': digest(path)}
        try:
            version = json.loads((root / 'plugin.json').read_text()).get('version', '?')
        except (OSError, ValueError):
            version = '?'
        manifest['addons'][name] = {'plugin_version': version, 'files': files}
    for rel in SHARED:
        path = ROOT / rel
        if path.is_file():
            manifest['shared'][rel] = {'sha256': digest(path)}
    out = ROOT / 'vendor' / 'MANIFEST.json'
    out.parent.mkdir(exist_ok=True)
    out.write_text(json.dumps(manifest, indent=2, sort_keys=True) + '\n')
    print('wrote %s (%d add-ons)' % (out, len(manifest['addons'])))
    return 0


if __name__ == '__main__':
    sys.exit(main())
