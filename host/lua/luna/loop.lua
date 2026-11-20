-- Main cooperative loop: select over CDP sockets, Steam liveness, plugin ticks.
local socket = require("socket")
local log = require("luna.log")

local M = {}
M.LIVENESS_INTERVAL = 3
M.TICK_INTERVAL = 5
M.GRACE = 20

local function steam_alive()
  local proc = require("proc")
  local ok, a = pcall(proc.is_alive, "steam")
  if ok and a then return true end
  local ok2, b = pcall(proc.is_alive, "steamwebhelper")
  return ok2 and b or false
end

-- opts: injector, plugins (state), alive() override, grace, now(), max_iterations (tests),
-- exit_when_gone (tests only). The host service must outlive Steam restarts: by default it
-- never exits, it just idles (discovery keeps polling every 0.3-2 s) until Steam returns.
-- Returns exit code (0 only with exit_when_gone, once Steam has gone away).
function M.run(opts)
  local inj = opts.injector
  local plugins = opts.plugins and require("luna.plugins")
  local now_fn = opts.now or socket.gettime
  local alive = opts.alive or steam_alive
  local grace = opts.grace or M.GRACE
  local seen, gone_since = false, nil
  local next_live, next_tick = 0, now_fn() + M.TICK_INTERVAL
  local iter = 0
  while true do
    iter = iter + 1
    if opts.max_iterations and iter > opts.max_iterations then return nil end
    local now = now_fn()
    local rs, ws = inj:sockets(), inj:write_sockets()
    local timeout = inj:poll_timeout(now)
    if #rs == 0 and #ws == 0 then
      socket.sleep(timeout)
    else
      local r, w = socket.select(rs, ws, timeout)
      inj:service(r, w)
    end
    now = now_fn()
    if now >= next_live then
      next_live = now + M.LIVENESS_INTERVAL
      if alive() then
        seen, gone_since = true, nil
      elseif seen then
        gone_since = gone_since or now
        if opts.exit_when_gone and now - gone_since >= grace then
          log.info("Steam is gone; exiting")
          inj:shutdown()
          if plugins then plugins.unload(opts.plugins) end
          return 0
        end
      end
    end
    local ok, err = pcall(inj.tick, inj, now)
    if not ok then log.error("tick: " .. tostring(err)) end
    if plugins and now >= next_tick then
      next_tick = now + M.TICK_INTERVAL
      plugins.tick(opts.plugins, now, inj)
    end
  end
end

return M
