-- millennium: shim for the plugin host API.
local M = {}
local js, css = {}, {}

function M.steam_path()
  local home = os.getenv("HOME") or ""
  local p = home .. "/.steam/steam"
  local real = require("luna_core").readlink(p)
  return real and (real:sub(1, 1) == "/" and real or home .. "/.steam/" .. real) or p
end
function M.version()
  local v = os.getenv("LUNA_VERSION")
  return (v and v ~= "") and v or "luna-dev"
end
function M.ready() return true end
function M.add_browser_js(path) js[#js + 1] = path end
function M.add_browser_css(path) css[#css + 1] = path end
function M.queued_js() return js end
function M.queued_css() return css end
return M
