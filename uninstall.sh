#!/usr/bin/env bash
# Remove Luna: the user unit, the host binary and its tree, the add-ons and the
# `luna` command. Playtime/presence data under ~/.local/share/Luna/data is kept
# unless --purge is given.
set -euo pipefail

LUNA_HOME="${LUNA_HOME:-$HOME/.local/share/Luna}"
UNIT_DIR="$HOME/.config/systemd/user"
PURGE=0
[ "${1:-}" = "--purge" ] && PURGE=1

if pgrep -x steam >/dev/null 2>&1; then
  echo "uninstall.sh: exit Steam completely before removing Luna" >&2
  exit 1
fi

systemctl --user disable --now luna-host.service 2>/dev/null || true
rm -f "$UNIT_DIR/luna-host.service" "$UNIT_DIR/luna-autoupdate.service" "$UNIT_DIR/luna-autoupdate.timer"
systemctl --user daemon-reload 2>/dev/null || true

rm -f "$HOME/.local/bin/luna"
if [ "$PURGE" = 1 ]; then
  rm -rf "$LUNA_HOME"
  echo "Luna removed, including its data."
else
  rm -rf "$LUNA_HOME/bin" "$LUNA_HOME/lua" "$LUNA_HOME/addons" "$LUNA_HOME/state" "$LUNA_HOME/scripts"
  echo "Luna removed. Your playtime and presence data is still in $LUNA_HOME/data."
  echo "Remove that too with: $0 --purge"
fi
echo "Steam's own files were not touched."
