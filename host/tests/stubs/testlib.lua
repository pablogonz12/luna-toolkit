-- Shared helpers for cdp_*.lua tests.
local M = {}
local here = debug.getinfo(1, "S").source:match("^@(.*)/stubs/testlib%.lua$") or "."
M.tests_dir = here
function M.setup()
  local stubs = here .. "/stubs/?.lua;"
  local real = here .. "/../lua/?.lua;" .. here .. "/../lua/?/init.lua;"
  if os.getenv("LUNA_TEST_REAL") then package.path = real .. stubs .. package.path
  else package.path = stubs .. real .. package.path end
  require("luna.log").quiet = true
end
local passed, failed = 0, 0
function M.test(name, fn)
  local ok, err = xpcall(fn, debug.traceback)
  if ok then passed = passed + 1 else failed = failed + 1; io.stderr:write("FAIL " .. name .. ": " .. tostring(err) .. "\n") end
end
function M.eq(a, b, msg)
  if a ~= b then error((msg or "eq") .. ": expected " .. tostring(b) .. ", got " .. tostring(a), 2) end
end
function M.ok(v, msg) if not v then error(msg or "assertion failed", 2) end end
function M.finish(name)
  print(string.format("%s: %d passed, %d failed", name, passed, failed))
  os.exit(failed == 0 and 0 or 1)
end
function M.tmpdir()
  local p = io.popen("mktemp -d"); local d = p:read("*l"); p:close(); return d
end
function M.write(path, text)
  os.execute("mkdir -p '" .. path:match("^(.*)/[^/]*$") .. "'")
  local f = assert(io.open(path, "wb")); f:write(text); f:close()
end
return M
