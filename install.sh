#!/usr/bin/env bash
# Luna installer: installs luna-host, its Lua tree and the add-ons into
# ~/.local/share/Luna, then enables the user unit.
#
#   curl -fsSL https://raw.githubusercontent.com/<owner>/<repo>/main/install.sh | bash
#   bash install.sh --local .        # install from a checkout
#   bash install.sh --dry-run        # show what would happen
set -euo pipefail

OWNER="${LUNA_OWNER:-pgm1207}"
REPO="${LUNA_REPO:-luna-toolkit}"
LUNA_HOME="${LUNA_HOME:-$HOME/.local/share/Luna}"
UNIT_DIR="$HOME/.config/systemd/user"
UNIT="$UNIT_DIR/luna-host.service"
LOCAL_DIR=""
DRY_RUN=0

usage() {
  cat <<'EOF'
usage: install.sh [--local DIR] [--dry-run] [--help]

  --local DIR   install from a local checkout instead of a release bundle
  --dry-run     print the plan and change nothing
  --help        this text

Environment: LUNA_HOME (default ~/.local/share/Luna), LUNA_OWNER, LUNA_REPO.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --local) LOCAL_DIR="${2:?--local needs a directory}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "install.sh: unknown option $1" >&2; usage >&2; exit 2 ;;
  esac
done

say() { printf '%s\n' "$*"; }
die() { printf 'install.sh: %s\n' "$*" >&2; exit 1; }
run() {
  if [ "$DRY_RUN" = 1 ]; then printf '  would run: %s\n' "$*"; else "$@"; fi
}

for tool in cc make curl tar; do
  command -v "$tool" >/dev/null 2>&1 || die "missing $tool (Arch: sudo pacman -S base-devel curl)"
done

# Steam must be closed: the host writes into the tree the client loads from.
if pgrep -x steam >/dev/null 2>&1 || pgrep -x steamwebhelper >/dev/null 2>&1; then
  die "Steam is running. Exit Steam completely (Steam -> Exit) and run this again."
fi

work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT

if [ -n "$LOCAL_DIR" ]; then
  src="$(cd "$LOCAL_DIR" && pwd)"
  [ -d "$src/host" ] || die "$src does not look like a Luna checkout"
  say "source : local checkout $src"
else
  tag="${LUNA_TAG:-latest}"
  if [ "$tag" = latest ]; then
    base="https://github.com/$OWNER/$REPO/releases/latest/download"
  else
    base="https://github.com/$OWNER/$REPO/releases/download/$tag"
  fi
  asset="luna.tar.gz"
  say "source : $base/$asset"
  curl -fsSL -o "$work/$asset" "$base/$asset" || die "download failed"
  curl -fsSL -o "$work/$asset.sha256" "$base/$asset.sha256" || die "checksum download failed"
  expected="$(cut -d' ' -f1 <"$work/$asset.sha256")"
  actual="$(sha256sum "$work/$asset" | cut -d' ' -f1)"
  [ "$expected" = "$actual" ] || die "sha256 mismatch (expected $expected, got $actual)"
  say "sha256 : verified"
  mkdir -p "$work/src"
  tar -xzf "$work/$asset" -C "$work/src" --strip-components=1
  src="$work/src"
fi

[ -f "$src/host/Makefile" ] || die "no host/Makefile in $src"
say "build  : make -C host"
if [ "$DRY_RUN" = 1 ]; then
  say "  would run: make -C $src/host"
else
  make -C "$src/host" >/dev/null || die "the host did not build (needs cc and make)"
fi

say "install: $LUNA_HOME"
for step in "$LUNA_HOME/bin/luna-host" "$LUNA_HOME/lua" "$LUNA_HOME/addons"; do
  run mkdir -p "$(dirname "$step")"
done
run mkdir -p "$LUNA_HOME/bin" "$LUNA_HOME/state"
if [ "$DRY_RUN" = 0 ]; then
  install -Dm755 "$src/host/bin/luna-host" "$LUNA_HOME/bin/luna-host"
  rm -rf "$LUNA_HOME/lua.new"
  cp -a "$src/host/lua" "$LUNA_HOME/lua.new"
  rm -rf "$LUNA_HOME/lua"
  mv "$LUNA_HOME/lua.new" "$LUNA_HOME/lua"
  for addon in luna sgdb graphics playtime presence compressor; do
    [ -d "$src/addons/$addon/plugin" ] || continue
    rm -rf "$LUNA_HOME/addons/$addon"
    mkdir -p "$LUNA_HOME/addons/$addon"
    cp -a "$src/addons/$addon/plugin/." "$LUNA_HOME/addons/$addon/"
  done
else
  say "  would copy host/lua and the add-ons into $LUNA_HOME"
fi

say "unit   : $UNIT"
if [ "$DRY_RUN" = 0 ]; then
  mkdir -p "$UNIT_DIR"
  cat >"$UNIT" <<EOF
# Managed by Luna: host v1
[Unit]
Description=Luna plugin host (injects Luna's add-ons into Steam)
After=graphical-session.target

[Service]
Type=simple
Environment=LUNA_HOME=$LUNA_HOME
Environment=LUNA_LUA_DIR=$LUNA_HOME/lua
ExecStart=$LUNA_HOME/bin/luna-host
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
EOF
  systemctl --user daemon-reload || true
  systemctl --user enable luna-host.service || true
  say "         enabled; it starts with your next session"
else
  say "  would write the unit and enable it"
fi

say "command: $HOME/.local/bin/luna"
run mkdir -p "$HOME/.local/bin"
if [ "$DRY_RUN" = 0 ]; then
  run cp -a "$src/scripts" "$LUNA_HOME/scripts" 2>/dev/null || {
    rm -rf "$LUNA_HOME/scripts"; cp -a "$src/scripts" "$LUNA_HOME/scripts"; }
  cat >"$HOME/.local/bin/luna" <<'EOF'
#!/bin/sh
# Managed by Luna: runs the tooling copy under $LUNA_HOME/state.
LUNA_HOME="${LUNA_HOME:-$HOME/.local/share/Luna}"
if [ ! -f "$LUNA_HOME/state/luna.py" ]; then
  echo "luna: no tooling copy found; run the installer again" >&2
  exit 1
fi
exec python3 "$LUNA_HOME/state/luna.py" "$@"
EOF
  chmod 755 "$HOME/.local/bin/luna"
  python3 "$src/scripts/luna.py" install --force --no-steam-machine >/dev/null || true
fi

say ""
say "Luna is installed. Start Steam; the panels appear in the library and the top bar."
say "Remove it again with:"
say "  curl -fsSL https://raw.githubusercontent.com/$OWNER/$REPO/main/uninstall.sh | bash"
