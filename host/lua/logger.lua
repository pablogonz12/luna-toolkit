-- logger: stderr logging.
local M = {}
local function emit(level, msg, ...)
  if msg == M then msg = ... end -- allow logger:info("x")
  io.stderr:write(string.format("[%s] %s\n", level, tostring(msg)))
end
function M.log(...) emit("log", ...) end
function M.info(...) emit("info", ...) end
function M.warn(...) emit("warn", ...) end
function M.error(...) emit("error", ...) end
return M
