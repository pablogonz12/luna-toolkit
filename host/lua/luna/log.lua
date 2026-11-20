-- Timestamped stderr logging for luna-host itself.
local M = { quiet = false }

local function emit(level, msg)
  if M.quiet then return end
  io.stderr:write(string.format("[%s] [luna-host] %s %s\n", os.date("!%H:%M:%S"), level, tostring(msg)))
end

function M.info(msg) emit("INFO", msg) end
function M.warn(msg) emit("WARN", msg) end
function M.error(msg) emit("ERROR", msg) end

return M
