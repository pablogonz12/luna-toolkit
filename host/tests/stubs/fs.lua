local M = {}
function M.list(dir)
  local out = {}
  local p = io.popen("ls -1p '" .. dir .. "' 2>/dev/null")
  for l in p:lines() do out[#out + 1] = { name = (l:gsub("/$", "")), is_directory = l:sub(-1) == "/" } end
  p:close()
  return out
end
return M
