-- Base64 (RFC 4648 standard alphabet, padded), pure Lua 5.4.
local M = {}
local A = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local enc, dec = {}, {}
for i = 1, 64 do local c = A:sub(i, i); enc[i - 1] = c; dec[c:byte()] = i - 1 end

function M.encode(s)
  s = tostring(s)
  local out, n = {}, #s
  for i = 1, n - 2, 3 do
    local a, b, c = s:byte(i, i + 2)
    local v = (a << 16) | (b << 8) | c
    out[#out + 1] = enc[v >> 18] .. enc[(v >> 12) & 63] .. enc[(v >> 6) & 63] .. enc[v & 63]
  end
  local r = n % 3
  if r == 1 then
    local v = s:byte(n) << 16
    out[#out + 1] = enc[v >> 18] .. enc[(v >> 12) & 63] .. "=="
  elseif r == 2 then
    local a, b = s:byte(n - 1, n)
    local v = (a << 16) | (b << 8)
    out[#out + 1] = enc[v >> 18] .. enc[(v >> 12) & 63] .. enc[(v >> 6) & 63] .. "="
  end
  return table.concat(out)
end

-- Returns decoded string, or nil, err on malformed input. Whitespace ignored; padding optional.
function M.decode(s)
  s = tostring(s):gsub("%s", ""):gsub("=+$", "")
  local out, acc, bits = {}, 0, 0
  for i = 1, #s do
    local v = dec[s:byte(i)]
    if not v then return nil, "invalid base64 character" end
    acc = ((acc << 6) | v) & 0xffffff; bits = bits + 6
    if bits >= 8 then bits = bits - 8; out[#out + 1] = string.char((acc >> bits) & 255) end
  end
  if #s % 4 == 1 then return nil, "invalid base64 length" end
  return table.concat(out)
end
M.b64encode, M.b64decode = M.encode, M.decode
return M
