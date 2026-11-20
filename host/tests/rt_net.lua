local H = dofile((arg[0]:match("^(.*)/[^/]*$") or ".") .. "/rtlib.lua")
local core, socket, http, fs = require("luna_core"), require("socket"), require("http"), require("fs")
local root = string.format("/tmp/luna-rt-net-%d", core.getpid())
fs.create_directories(root)
fs.write(root .. "/hello.txt", "hello world\nline2\n")
local f = io.popen("python3 -I -c 'import socket;s=socket.socket();s.bind((\"127.0.0.1\",0));print(s.getsockname()[1])'")
local port = tonumber(f:read("l")); f:close()
H.ok(port, "free port")
local pidf = root .. "/pid"
os.execute(string.format("python3 -I -m http.server %d --bind 127.0.0.1 -d %s >/dev/null 2>&1 & echo $! > %s", port, root, pidf))
local up
for _ = 1, 50 do
  local fd = core.tcp_connect(port, 0.2)
  if fd then core.close(fd); up = true; break end
  core.sleep(0.1)
end
local function stop()
  local pid = fs.read(pidf)
  if pid then os.execute("kill " .. pid:gsub("%s", "")) end
  fs.remove_all(root)
end
local ok, err = pcall(function()
  H.ok(up, "server up")
  -- raw socket
  local s = socket.tcp()
  s:settimeout(3)
  H.ok(s:connect("127.0.0.1", port), "connect")
  H.ok(s:getfd() >= 0, "fd")
  H.eq(s:send("GET /hello.txt HTTP/1.0\r\nHost: x\r\n\r\n"), 36, "send")
  local r = socket.select({ s }, nil, 3)
  H.eq(r[1], s, "select readable")
  local line = s:receive("*l")
  H.ok(line:match("^HTTP/1%.%d 200"), "status line")
  local rest = s:receive("*a")
  H.ok(rest:find("hello world\nline2\n", 1, true), "body via *a")
  s:close()
  -- timeout path
  local s2 = socket.tcp(); s2:settimeout(3)
  s2:connect("127.0.0.1", port)
  s2:settimeout(0.2)
  local d, e = s2:receive(1)
  H.eq(d, nil, "no data"); H.eq(e, "timeout", "timeout err")
  local t0 = socket.gettime()
  local rr, _, serr = socket.select({ s2 }, nil, 0.2)
  H.eq(#rr, 0, "select empty"); H.eq(serr, "timeout", "select timeout")
  H.ok(socket.gettime() - t0 >= 0.15, "select waited")
  s2:close()
  -- connection refused
  local s3 = socket.tcp()
  local okc, cerr = s3:connect("127.0.0.1", 1)
  H.eq(okc, nil, "refused"); H.ok(cerr, "refused err")
  -- http via curl
  local res = assert(http.get("http://127.0.0.1:" .. port .. "/hello.txt", { headers = { ["User-Agent"] = "t/1" } }))
  H.eq(res.status, 200, "http status"); H.eq(res.body, "hello world\nline2\n", "http body")
  H.eq(res.headers["content-length"], "18", "http header")
  H.eq(http.get("http://127.0.0.1:" .. port .. "/missing").status, 404, "404")
  local hd = assert(http.head("http://127.0.0.1:" .. port .. "/hello.txt"))
  H.eq(hd.status, 200, "head"); H.eq(hd.body, "", "head body")
  H.eq(http.post("http://127.0.0.1:" .. port .. "/", "a=b'c", {}).status, 501, "post")
  local nr, nerr = http.get("http://127.0.0.1:1/", { timeout = 2 })
  H.eq(nr, nil, "http refused"); H.ok(nerr, "http refused err")
  local h = http.start("http://127.0.0.1:" .. port .. "/hello.txt")
  local res2
  for _ = 1, 100 do
    res2 = http.poll(h)
    if res2 then break end
    core.sleep(0.05)
  end
  H.ok(res2 and res2.status == 200, "async poll")
  -- unix socket client against a python echo server
  local sock = root .. "/u.sock"
  local upid = root .. "/upid"
  fs.write(root .. "/echo.py", "import socket,sys,os\ns=socket.socket(socket.AF_UNIX)\ns.bind(sys.argv[1])\ns.listen(1)\nc,_=s.accept()\nc.sendall(b'hi')\nwhile True:\n d=c.recv(100)\n if not d: break\n c.sendall(d.upper())\n")
  os.execute(string.format("python3 -I %s %s >/dev/null 2>&1 & echo $! > %s", root .. "/echo.py", sock, upid))
  local ready
  for _ = 1, 50 do
    local fd = core.unix_connect(sock, 0.2)
    if fd then ready = fd; break end
    core.sleep(0.1)
  end
  H.ok(ready, "unix server up")
  local u = socket.unix(); u.fd = ready; u:settimeout(3)
  H.eq(u:receive(2), "hi", "unix greeting")
  H.eq(u:send("abc"), 3, "unix send")
  local ur = socket.select({ u }, nil, 3)
  H.eq(ur[1], u, "unix select")
  H.eq(u:receive(3), "ABC", "unix echo")
  u:settimeout(0.2)
  local ud, ue = u:receive(1)
  H.eq(ud, nil, "unix no data"); H.eq(ue, "timeout", "unix timeout")
  u:close()
  local u2 = socket.unix()
  local okn, nerr2 = u2:connect(root .. "/nope.sock")
  H.eq(okn, nil, "unix missing"); H.ok(nerr2, "unix missing err")
  pcall(function() os.execute("kill " .. fs.read(upid):gsub("%s", "")) end)
end)
stop()
if not ok then error(err, 0) end
H.done("rt_net")
