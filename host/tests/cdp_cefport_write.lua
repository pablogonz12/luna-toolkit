-- luna-host owns its CEF port: discovery from Steam's own command line, and
-- the atomic $LUNA_HOME/cef_port writer. No wrapper, no Luna, no network.
local dir = (arg and arg[0] or ""):match("^(.*)/[^/]*$") or "."
package.path = dir .. "/stubs/?.lua;" .. package.path
local T = require("testlib"); T.setup()

local cefport = require("luna.cefport")

local function fakeproc(root, pid, comm, start, cmdline)
  -- field 22 = starttime; args are NUL separated exactly like /proc/<pid>/cmdline
  local f = {}
  for i = 1, 18 do f[i] = "0" end
  T.write(root .. "/" .. pid .. "/stat", pid .. " (" .. comm .. ") S " .. table.concat(f, " ") .. " " .. start .. " 1 2\n")
  T.write(root .. "/" .. pid .. "/cmdline", cmdline)
end

T.test("port_in_cmdline only accepts the debug flag in range", function()
  T.eq(cefport.port_in_cmdline("/steam\0--remote-debugging-port=3615\0"), 3615)
  T.eq(cefport.port_in_cmdline("--remote-debugging-port=80\0"), nil, "below range")
  T.eq(cefport.port_in_cmdline("--remote-debugging-port=70000\0"), nil, "above range")
  T.eq(cefport.port_in_cmdline("/steam\0--no-remote-debugging-port=3615\0"), nil, "other flag")
  T.eq(cefport.port_in_cmdline(nil), nil)
end)

T.test("from_process prefers steamwebhelper and ignores unrelated processes", function()
  local root = T.tmpdir()
  fakeproc(root, 10, "steam", 500, "/usr/bin/steam\0--remote-debugging-port=3615\0")
  fakeproc(root, 11, "steamwebhelper", 700, "/steam/steamwebhelper\0--remote-debugging-port=4321\0")
  fakeproc(root, 12, "python3", 900, "/usr/bin/python3\0--remote-debugging-port=9999\0")
  local port, pid = cefport.from_process({ proc_root = root })
  T.eq(port, 4321); T.eq(pid, 11)
  os.remove(root .. "/11/cmdline")
  port, pid = cefport.from_process({ proc_root = root })
  T.eq(port, 3615); T.eq(pid, 10, "plain steam client is the fallback")
end)

T.test("discover: process, then file, then default", function()
  local proc, home = T.tmpdir(), T.tmpdir()
  local lh = home .. "/lunahome"
  fakeproc(proc, 20, "steamwebhelper", 4242, "/steam/steamwebhelper\0--remote-debugging-port=3615\0")
  T.write(lh .. "/cef_port", "4000\n")
  local o = { luna_home = lh, home = home, proc_root = proc }
  local port, source, pid = cefport.discover(o)
  T.eq(port, 3615); T.eq(source, "process"); T.eq(pid, 20)
  os.remove(proc .. "/20/cmdline")
  port, source, pid = cefport.discover(o)
  T.eq(port, 4000); T.eq(source, "luna"); T.eq(pid, nil, "no owner from the file alone")
  T.write(lh .. "/cef_port", "garbage\n")
  port, source = cefport.discover(o)
  T.eq(port, 8080); T.eq(source, "default")
end)

T.test("write records the port atomically with a live owner line", function()
  local home, proc = T.tmpdir(), T.tmpdir()
  local lh = home .. "/lunahome"
  T.write(lh .. "/.keep", "")
  fakeproc(proc, 30, "steamwebhelper", 9001, "/steam/steamwebhelper\0--remote-debugging-port=3615\0")
  local ok, err = cefport.write(3615, { luna_home = lh, home = home, pid = 30, start = 9001 })
  T.ok(ok, tostring(err))
  local f = assert(io.open(lh .. "/cef_port", "rb")); local body = f:read("*a"); f:close()
  T.eq(body, "3615\nowner 30 9001\n")
  -- The contract file must read back to the same port...
  local o = { luna_home = lh, home = home, proc_root = proc }
  T.eq((cefport.read(o)), 3615)
  -- ...and stay trusted only while that pid's start time matches.
  T.write(proc .. "/30/stat", "30 (steamwebhelper) S 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 111 1 2\n")
  T.eq((select(2, cefport.read(o))), "default", "recycled pid must not be trusted")
  T.ok(not cefport.write(99, { luna_home = lh, home = home }), "out of range refused")
  T.ok(not cefport.write("abc", { luna_home = lh, home = home }))
end)

T.test("record discovers and writes in one step", function()
  local home, proc = T.tmpdir(), T.tmpdir()
  local lh = home .. "/lunahome"
  T.write(lh .. "/.keep", "")
  fakeproc(proc, 40, "steamwebhelper", 777, "/steam/steamwebhelper\0--remote-debugging-port=4321\0")
  local port, source, wrote = cefport.record({ luna_home = lh, home = home, proc_root = proc })
  T.eq(port, 4321); T.eq(source, "process"); T.eq(wrote, true)
  local f = assert(io.open(lh .. "/cef_port", "rb")); local body = f:read("*a"); f:close()
  T.eq(body, "4321\nowner 40 777\n")
  -- Nothing to discover and nowhere to write: no throw, just a refusal.
  local ro = { luna_home = "/proc/self/cef_port", home = home, proc_root = T.tmpdir() }
  local p2, s2, writable = cefport.record(ro)
  T.eq(p2, 8080); T.eq(s2, "default"); T.eq(writable, false)
end)

T.finish("cdp_cefport_write")
