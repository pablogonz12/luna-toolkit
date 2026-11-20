# Changelog

## 0.15.0

First public release.

- `luna-host`: a small Lua 5.4 host (C + vendored Lua, MIT) that attaches to
  Steam's CEF debugging port and loads the add-ons from `$LUNA_HOME/addons`.
- Add-ons: `luna` (menu, Health, Updates, Settings, About), `playtime`,
  `presence`, `compressor`, `sgdb` (artwork) and `graphics`.
- CLI: install, uninstall, status, verify, doctor, launchers, steam, update,
  release, backup, restore, timer, check.
- Steam client pin and rollback: pinned manifest, `steam.cfg` lock and
  `luna steam pin|lock|unlock|history|recover`.
- `install.sh` with `--local` and `--dry-run`.

## 0.14.x

Internal development builds.
