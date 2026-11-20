-- http: HTTP(S) client implemented by spawning curl.
local core = require("luna_core")
local M = {}

local DEFAULT_UA = "luna-host/1.0"
local counter = 0

local function q(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function tmpname(tag)
  counter = counter + 1
  local dir = os.getenv("XDG_RUNTIME_DIR")
  if not dir or dir == "" or not core.stat(dir) then dir = "/tmp" end
  return string.format("%s/luna-http-%d-%d-%s", dir, core.getpid(), counter, tag)
end

local function readfile(p)
  local f = io.open(p, "rb")
  if not f then return nil end
  local d = f:read("a")
  f:close()
  return d
end

local function parse_headers(raw)
  local headers = {}
  if not raw then return headers end
  -- use only the last header block (after redirects / 100-continue)
  local last
  for block in (raw:gsub("\r\n", "\n") .. "\n"):gmatch("(.-)\n\n") do
    if block:match("^HTTP/") then last = block end
  end
  if not last then return headers end
  local first = true
  for line in last:gmatch("[^\n]+") do
    if first then first = false
    else
      local k, v = line:match("^([^:]+):%s*(.-)%s*$")
      if k then
        k = k:lower()
        if headers[k] then headers[k] = headers[k] .. ", " .. v else headers[k] = v end
      end
    end
  end
  return headers
end

local function build(opts, files)
  local method = (opts.method or "GET"):upper()
  local a = { "curl", "-sS" }
  local timeout = tonumber(opts.timeout) or 30
  a[#a + 1] = "--max-time " .. string.format("%d", math.max(1, math.ceil(timeout)))
  a[#a + 1] = "--connect-timeout " .. string.format("%d", math.max(1, math.ceil(math.min(timeout, 15))))
  if opts.follow ~= false then a[#a + 1] = "-L --max-redirs 10" end
  if opts.insecure then a[#a + 1] = "-k" end
  if method == "HEAD" then a[#a + 1] = "-I" else a[#a + 1] = "-X " .. q(method) end
  local has_ua = false
  local names = {}
  for k in pairs(opts.headers or {}) do names[#names + 1] = k end
  table.sort(names)
  for _, k in ipairs(names) do
    local v = opts.headers[k]
    if tostring(k):lower() == "user-agent" then has_ua = true end
    if tostring(k):find("[\r\n:]") or tostring(v):find("[\r\n]") then error("invalid header", 0) end
    a[#a + 1] = "-H " .. q(k .. ": " .. tostring(v))
  end
  if not has_ua then a[#a + 1] = "-H " .. q("User-Agent: " .. DEFAULT_UA) end
  local data = opts.data or opts.body
  if data ~= nil and method ~= "HEAD" then
    local f = assert(io.open(files.data, "wb"))
    f:write(tostring(data))
    f:close()
    a[#a + 1] = "--data-binary @" .. q(files.data)
  end
  a[#a + 1] = "-D " .. q(files.hdr)
  a[#a + 1] = "-o " .. (method == "HEAD" and "/dev/null" or q(files.body))
  a[#a + 1] = "-w '%{http_code}'"
  a[#a + 1] = "--"
  a[#a + 1] = q(opts.url)
  return table.concat(a, " ")
end

local function cleanup(files)
  for _, p in pairs(files) do core.remove(p) end
end

local function finish(files, code, err)
  local res
  code = tonumber((code or ""):match("%d+"))
  if not code or code == 0 then
    res = nil
    err = err ~= "" and err or "request failed"
  else
    res = { status = code, headers = parse_headers(readfile(files.hdr)), body = readfile(files.body) or "" }
  end
  cleanup(files)
  if not res then return nil, (err:gsub("%s+$", "")) end
  return res
end

local function newfiles()
  return { data = tmpname("data"), hdr = tmpname("hdr"), body = tmpname("body"), err = tmpname("err"), st = tmpname("st") }
end

function M.request(opts)
  if type(opts) == "string" then opts = { url = opts } end
  assert(type(opts.url) == "string" and opts.url ~= "", "url required")
  local files = newfiles()
  local ok, cmd = pcall(build, opts, files)
  if not ok then cleanup(files); return nil, cmd end
  local p = io.popen(cmd .. " 2>" .. q(files.err), "r")
  if not p then cleanup(files); return nil, "cannot spawn curl" end
  local code = p:read("a")
  p:close()
  return finish(files, code, readfile(files.err))
end

local function with(opts, extra)
  local o = {}
  for k, v in pairs(opts or {}) do o[k] = v end
  for k, v in pairs(extra) do o[k] = v end
  return o
end

function M.get(url, opts) return M.request(with(opts, { url = url, method = "GET" })) end
function M.head(url, opts) return M.request(with(opts, { url = url, method = "HEAD" })) end
function M.post(url, data, opts) return M.request(with(opts, { url = url, method = "POST", data = data })) end

-- Asynchronous: curl runs in the background; poll() checks for completion.
function M.start(url, opts)
  if type(url) == "table" then opts = url; url = opts.url end
  local o = with(opts, { url = url })
  local files = newfiles()
  local ok, cmd = pcall(build, o, files)
  if not ok then cleanup(files); return nil, cmd end
  local sh = string.format("( %s > %s 2>%s; mv %s %s ) >/dev/null 2>&1 &",
    cmd, q(files.st .. ".tmp"), q(files.err), q(files.st .. ".tmp"), q(files.st))
  os.execute(sh)
  return { files = files, done = false }
end

-- returns nil,'pending' while running; response table, or nil,err when finished.
function M.poll(handle)
  if handle.done then return handle.result, handle.err end
  if not core.stat(handle.files.st) then return nil, "pending" end
  local code = readfile(handle.files.st)
  local res, err = finish(handle.files, code, readfile(handle.files.err))
  handle.done, handle.result, handle.err = true, res, err
  return res, err
end

return M
