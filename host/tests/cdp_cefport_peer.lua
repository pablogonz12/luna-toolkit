local dir = (arg and arg[0] or ""):match("^(.*)/[^/]*$") or "."
package.path = dir .. "/stubs/?.lua;" .. package.path
local T = require("testlib"); T.setup()

local cefport = require("luna.cefport")
local peer = require("luna.peer")

local function fakeproc(root, pid, comm, start)
  -- field 22 = starttime; comm contains spaces and a paren on purpose
  local f = {}
  for i = 1, 18 do f[i] = "0" end
  T.write(root .. "/" .. pid .. "/stat", pid .. " (" .. comm .. ") S " .. table.concat(f, " ") .. " " .. start .. " 1 2\n")
  T.write(root .. "/" .. pid .. "/comm", comm .. "\n")
end

T.test("cefport.parse", function()
  T.eq(cefport.parse("3615\n").port, 3615)
  local r = cefport.parse("3615\nowner 2541220 6467525\n")
  T.eq(r.owner_pid, 2541220); T.eq(r.owner_start, 6467525)
  T.ok(not cefport.parse("80\n"), "below range")
  T.ok(not cefport.parse("70000"), "above range")
  T.ok(not cefport.parse("abc")); T.ok(not cefport.parse("")); T.ok(not cefport.parse("12 34"))
end)

T.test("cefport.starttime handles odd comm", function()
  local root = T.tmpdir()
  fakeproc(root, 100, "we ird) name", 555)
  T.eq(cefport.starttime(100, root), 555)
  T.eq(cefport.starttime(101, root), nil)
end)

T.test("cefport.read: luna, stale owner, legacy, default", function()
  local root, home = T.tmpdir(), T.tmpdir()
  local lh = home .. "/lunahome"
  fakeproc(root, 4242, "steamwebhelper", 9001)
  local o = { luna_home = lh, home = home, proc_root = root }
  local p, src = cefport.read(o)
  T.eq(p, 8080); T.eq(src, "default")

  T.write(home .. "/.local/share/Luna/cef_port", "3615\n")
  p, src = cefport.read(o); T.eq(p, 3615); T.eq(src, "legacy")

  T.write(lh .. "/cef_port", "4000\nowner 4242 9001\n")
  p, src = cefport.read(o); T.eq(p, 4000); T.eq(src, "luna")

  T.write(lh .. "/cef_port", "4000\nowner 4242 9999\n")   -- recycled pid
  p, src, notes = cefport.read(o); T.eq(p, 3615); T.eq(src, "legacy")
  T.ok(notes[1]:find("stale owner"))

  T.write(lh .. "/cef_port", "4000\nowner 31337 1\n")      -- dead owner
  T.eq(select(2, cefport.read(o)), "legacy")

  T.write(lh .. "/cef_port", "99\n")                       -- out of range
  T.eq(select(2, cefport.read(o)), "legacy")
  T.write(home .. "/.local/share/Luna/cef_port", "garbage")
  p, src = cefport.read(o); T.eq(p, 8080); T.eq(src, "default")
end)

local TCP_HDR = "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n"
local function tcp_line(addr, port, st, uid, inode)
  return string.format("   0: %s:%04X 00000000:0000 %s 00000000:00000000 00:00000000 00000000  %d        0 %d 1 0000000000000000 100 0 0 10 0\n",
    addr, port, st, uid, inode)
end

local function net(root, tcp4, tcp6)
  T.write(root .. "/net/tcp", TCP_HDR .. (tcp4 or ""))
  T.write(root .. "/net/tcp6", TCP_HDR .. (tcp6 or ""))
  T.write(root .. "/self/status", "Name:\tlua\nUid:\t1000\t1000\t1000\t1000\n")
end

T.test("peer.verify accepts steamwebhelper on loopback", function()
  local root = T.tmpdir()
  net(root, tcp_line("0100007F", 3615, "0A", 1000, 777))
  fakeproc(root, 321, "steamwebhelper", 1)
  local ok, info = peer.verify(3615, { proc_root = root, find_pids = function(i) T.eq(i, "777"); return { "321" } end })
  T.ok(ok, tostring(info)); T.eq(info.comm, "steamwebhelper"); T.eq(info.pid, 321)
end)

T.test("peer.verify rejects foreign process / wrong uid / none / invisible", function()
  local root = T.tmpdir()
  fakeproc(root, 50, "python3", 1); fakeproc(root, 321, "steamwebhelper", 1)
  net(root, tcp_line("0100007F", 3615, "0A", 1000, 777))
  local ok, why = peer.verify(3615, { proc_root = root, find_pids = function() return { "50" } end })
  T.ok(not ok and why:find("python3"), tostring(why))
  -- shared socket: every holder must be steam
  ok = peer.verify(3615, { proc_root = root, find_pids = function() return { "321", "50" } end })
  T.ok(not ok)
  ok, why = peer.verify(3615, { proc_root = root, find_pids = function() return {} end })
  T.ok(not ok and why:find("not visible"))
  ok = peer.verify(9999, { proc_root = root, find_pids = function() return { "321" } end })
  T.ok(not ok, "nothing listens")
  net(root, tcp_line("0100007F", 3615, "0A", 0, 777))
  ok, why = peer.verify(3615, { proc_root = root, find_pids = function() return { "321" } end })
  T.ok(not ok and why:find("uid"), tostring(why))
  -- ESTABLISHED (01) is not a listener
  net(root, tcp_line("0100007F", 3615, "01", 1000, 777))
  T.ok(not peer.verify(3615, { proc_root = root, find_pids = function() return { "321" } end }))
end)

T.test("peer: loopback-specific listener wins over wildcard; tcp6 forms", function()
  local root = T.tmpdir()
  fakeproc(root, 50, "evil", 1); fakeproc(root, 321, "steamwebhelper", 1)
  net(root, tcp_line("00000000", 3615, "0A", 1000, 1) .. tcp_line("0100007F", 3615, "0A", 1000, 2))
  local ok = peer.verify(3615, { proc_root = root, find_pids = function(i) return { i == "2" and "321" or "50" } end })
  T.ok(ok, "specific loopback listener is what 127.0.0.1 reaches")
  -- wildcard-only (v4) listener owned by evil -> rejected
  net(root, tcp_line("00000000", 3615, "0A", 1000, 1))
  T.ok(not peer.verify(3615, { proc_root = root, find_pids = function() return { "50" } end }))
  -- tcp6 loopback and v4-mapped
  net(root, "", tcp_line("00000000000000000000000001000000", 3615, "0A", 1000, 3))
  T.ok(peer.verify(3615, { proc_root = root, find_pids = function() return { "321" } end }))
  net(root, "", tcp_line("0000000000000000FFFF00000100007F", 3615, "0A", 1000, 3))
  T.ok(peer.verify(3615, { proc_root = root, find_pids = function() return { "321" } end }))
  -- a non-loopback address is ignored
  net(root, tcp_line("0100A8C0", 3615, "0A", 1000, 3))
  T.ok(not peer.verify(3615, { proc_root = root, find_pids = function() return { "321" } end }))
end)

T.finish("cdp_cefport_peer")
