# Architecture

Three layers, one process:

```
Steam (CEF)  ──CDP/WebSocket──►  luna-host (C)  ──►  Lua add-on (backend/main.lua)
     ▲                                │
     └──────── injected JS ───────────┘  (panel/agent JS over callServerMethod)
```

- `host/src/main.c`, `host/src/luna_core.c` — the process: one Lua state, the
  vendored Lua 5.4.7, module registration, the CDP client and the RPC loop.
- `host/lua/` — the Lua side of the host: `luna/cdp.lua` (attach, evaluate),
  `luna/wsframe.lua` (WebSocket framing), `luna/cefport.lua` (find the port),
  `luna/plugins.lua` (discover and register add-ons), `luna/polyfill.lua` (the
  page-side shim), plus `json`, `fs`, `proc`, `http`, `logger`, `privfs`.
- `addons/<name>/plugin/backend/main.lua` — `register(registry)` puts RPC
  handlers into one table; `plugin/public/*.js` is the UI injected into Steam.
  `plugin/plugin.json` carries the name, version and description.
- `scripts/luna.py` — everything the user runs: install, verify, status,
  doctor, Steam client pin/lock/rollback, releases, backups, the timer.

State lives under `$LUNA_HOME`: `addons/` (what the host loads), `lua/` (host
tree), `bin/luna-host`, `state/` (tooling copy, pins, locks) and `data/`
(add-on data). The systemd user unit `luna-host.service` keeps the process
alive; it is the only thing that runs all the time.

## Contracts

- An add-on never opens a socket. Everything travels through the registry.
- The host never writes into Steam's tree except for `.cef-enable-remote-debugging`.
- `luna steam` only ever touches Valve-owned files (`steam.cfg`, `package/`,
  the client binaries it pinned) and always keeps a backup.
- `luna verify` pins every shipped file in `vendor/MANIFEST.json`; releases and
  bundles are checked against the same pins.
