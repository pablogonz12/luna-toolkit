local H = {}
local n = 0
function H.eq(a, b, msg)
  n = n + 1
  if a ~= b then error(string.format("FAIL %s: expected %s got %s", msg or "?", tostring(b), tostring(a)), 2) end
end
function H.ok(v, msg)
  n = n + 1
  if not v then error("FAIL " .. (msg or "?"), 2) end
end
function H.throws(f, msg)
  n = n + 1
  if pcall(f) then error("FAIL expected error: " .. (msg or "?"), 2) end
end
function H.done(name) print(string.format("%s: %d assertions ok", name, n)) end
return H
