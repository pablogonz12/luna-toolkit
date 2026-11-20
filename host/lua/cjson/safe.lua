-- cjson.safe: like cjson but returns nil, err instead of raising.
local base = require("cjson")
local M = {}
for k, v in pairs(base) do M[k] = v end
function M.encode(v)
  local ok, r = pcall(base.encode, v)
  if ok then return r end
  return nil, (tostring(r):gsub("^.-:%d+: ", ""))
end
function M.decode(s)
  local ok, r = pcall(base.decode, s)
  if ok then return r end
  return nil, (tostring(r):gsub("^.-:%d+: ", ""))
end
return M
