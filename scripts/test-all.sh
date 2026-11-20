#!/usr/bin/env bash
# One entry point for every suite, so a local run matches the pipeline:
# the shell/UI tests, the Lua backend suites, the host tests and the static checks.
# Lua is required; node is required for the UI tests.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

# Tests run real install code paths; never pop desktop notifications.
export LUNA_NO_NOTIFY=1

echo '== node: check + tests =='
for file in addons/*/plugin/public/*.js; do node --check "$file"; done
node --test tests/*.test.cjs tests/presence/*.test.cjs

echo '== lua: syntax + backend suites =='
if command -v lua5.4 >/dev/null 2>&1; then lua=lua5.4
elif command -v lua >/dev/null 2>&1; then lua=lua
else echo 'Lua runtime unavailable; install lua' >&2; exit 1
fi
luac -p tests/presence/backend-smoke.lua tests/compressor-smoke.lua \
  tests/sgdb-smoke.lua tests/graphics-smoke.lua tests/hltb-smoke.lua addons/*/plugin/backend/main.lua
bash scripts/test-backend.sh

echo '== host: native luna-host tests (rt_* + cdp_*) =='
if [[ ! -x host/bin/luna-host ]]; then
  echo 'building host/bin/luna-host...'
  make -C host all >/dev/null
fi
make -C host test

echo '== python: installer tests + compile + verify =='
python3 -m py_compile scripts/luna.py scripts/steam-machine.py scripts/make-manifest.py tests/*.py
python3 -m unittest discover -s tests -p 'test_*.py'
python3 scripts/luna.py verify >/dev/null

echo '== shell syntax =='
bash -n scripts/*.sh

echo
echo 'all suites passed.'
