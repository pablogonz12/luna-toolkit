local M = { alive = {} }
function M.is_alive(comm) return M.alive[comm] == true end
return M
