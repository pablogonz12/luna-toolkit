#!/usr/bin/env bash
# Run the Lua backend suites in a disposable HOME with the real payloads.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v lua5.4 >/dev/null 2>&1; then lua=lua5.4
elif command -v lua >/dev/null 2>&1; then lua=lua
else echo 'Lua runtime unavailable; install lua' >&2; exit 1
fi
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/home" "$tmp/presence"
(cd "$root" && SLS_TEST_HOME="$tmp/presence" HOME="$tmp/presence" SLS_KIND=presence \
  "$lua" tests/presence/backend-smoke.lua)
env HOME="$tmp/home" LUNA_TEST_HOME="$tmp/home" LUNA_REPO="$root" \
  LUNA_HOME="$tmp/home/.local/share/Luna" "$lua" "$root/tests/hltb-smoke.lua"
for suite in compressor sgdb graphics; do
  env HOME="$tmp/home" LUNA_TEST_HOME="$tmp/home" LUNA_REPO="$root" \
    SLS_GRAPHICS_SYSFS="$tmp/home/sys" SLS_GRAPHICS_OS_RELEASE="$tmp/home/os-release" \
    SLS_GRAPHICS_SYSTEM_LAYER_DIRS="$tmp/home/no-system-layers" \
    SLS_GRAPHICS_OPTISCALER_APP="$tmp/home/opt/optiscaler-client" \
    "$lua" "$root/tests/$suite-smoke.lua"
done
