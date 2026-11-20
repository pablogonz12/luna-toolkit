-- Minimal loopback HTTP/1.1 GET (DevTools /json). Plain TCP, 127.0.0.1 only.
local socket = require("socket")
local M = {}

local function read_head(sock)
  local lines = {}
  while true do
    local line, err = sock:receive("*l")
    if not line then return nil, err end
    line = line:gsub("\r$", "")
    if line == "" then break end
    lines[#lines + 1] = line
    if #lines > 200 then return nil, "too many headers" end
  end
  return lines
end

-- Returns body,status or nil,err.
function M.get(port, path, timeout, max_body)
  max_body = max_body or 8 * 1024 * 1024
  local sock = socket.tcp()
  sock:settimeout(timeout or 2)
  local ok, err = sock:connect("127.0.0.1", port)
  if not ok then sock:close(); return nil, "connect: " .. tostring(err) end
  local req = "GET " .. path .. " HTTP/1.1\r\nHost: 127.0.0.1:" .. port ..
    "\r\nConnection: close\r\nAccept: application/json\r\n\r\n"
  local sent, serr = sock:send(req)
  if not sent then sock:close(); return nil, "send: " .. tostring(serr) end
  local lines, herr = read_head(sock)
  if not lines then sock:close(); return nil, "read: " .. tostring(herr) end
  local status = tonumber(lines[1]:match("^HTTP/1%.[01]%s+(%d+)"))
  local clen, chunked
  for i = 2, #lines do
    local k, v = lines[i]:match("^([%w%-]+):%s*(.-)%s*$")
    if k then
      k = k:lower()
      if k == "content-length" then clen = tonumber(v)
      elseif k == "transfer-encoding" and v:lower():find("chunked", 1, true) then chunked = true end
    end
  end
  local body
  if chunked then
    local parts, total = {}, 0
    while true do
      local szline = sock:receive("*l")
      local n = szline and tonumber(szline:match("^%s*(%x+)"), 16)
      if not n then sock:close(); return nil, "bad chunk" end
      if n == 0 then break end
      total = total + n
      if total > max_body then sock:close(); return nil, "body too large" end
      local chunk = sock:receive(n)
      if not chunk then sock:close(); return nil, "short chunk" end
      parts[#parts + 1] = chunk
      sock:receive("*l")
    end
    body = table.concat(parts)
  elseif clen then
    if clen > max_body then sock:close(); return nil, "body too large" end
    body = clen == 0 and "" or sock:receive(clen)
    if not body then sock:close(); return nil, "short body" end
  else
    body = sock:receive("*a") or ""
  end
  sock:close()
  return body, status
end

return M
