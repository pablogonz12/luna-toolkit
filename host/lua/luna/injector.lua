-- Target discovery, channel selection and (re)injection over CDP.
local socket = require("socket")
local json = require("json")
local cdp = require("luna.cdp")
local httpget = require("luna.httpget")
local peer = require("luna.peer")
local polyfill = require("luna.polyfill")
local rpc = require("luna.rpc")
local wsframe = require("luna.wsframe")
local log = require("luna.log")

local M = {}
M.DISCOVER_INTERVAL = 0.3      -- until attached
M.REDISCOVER_INTERVAL = 2.0    -- after attach: new windows, restarts
M.VERIFY_TTL = 5.0
M.REINJECT_DELAY = 0.15
M.RECHECK_INTERVAL = 4.0     -- self-heal: re-verify injection on every attached target

local WEB_ORIGINS = {
  ["https://store.steampowered.com"] = true,
  ["https://steamcommunity.com"] = true,
}

function M.origin(url)
  local scheme, host, port = tostring(url or ""):match("^(%a[%w+.-]*)://([^/%?#:@]+):?(%d*)")
  if not scheme then return nil end
  host = host:lower()
  scheme = scheme:lower()
  if port ~= "" and not ((scheme == "https" and port == "443") or (scheme == "http" and port == "80")) then
    return scheme .. "://" .. host .. ":" .. port
  end
  return scheme .. "://" .. host
end

-- "agent" (SharedJSContext), "web" (store/community origin), "menu" (title Steam), or nil.
-- SharedJSContext is checked first so it can never receive web-view scripts;
-- origin is matched before the title and never by title.
function M.classify(t)
  if type(t) ~= "table" then return nil end
  if t.type ~= nil and t.type ~= "page" then return nil end
  if t.title == "SharedJSContext" then return "agent" end
  if WEB_ORIGINS[M.origin(t.url) or ""] then return "web" end
  if t.title == "Steam" then return "menu" end
  return nil
end

-- Read-only listing: returns array of {title,url,type,ws,channel} or nil,err.
function M.list_targets(port, get)
  local body, status = (get or httpget.get)(port, "/json", 2)
  if not body then return nil, status end
  if status ~= 200 then return nil, "http " .. tostring(status) end
  local ok, list = pcall(json.decode, body)
  if not ok or type(list) ~= "table" then return nil, "bad /json" end
  local out = {}
  for _, t in ipairs(list) do
    if type(t) == "table" then
      out[#out + 1] = { title = t.title, url = t.url, type = t.type,
        ws = t.webSocketDebuggerUrl, channel = M.classify(t) }
    end
  end
  return out
end

local Injector = {}
Injector.__index = Injector

-- opts: port()->port,source ; registry ; assets (plugins state.assets) ; plugins (state, optional) ;
--       verify(port)->ok,info ; open(url,port)->session ; get(port,path,timeout)
function M.new(opts)
  return setmetatable({
    opts = opts, sessions = {}, backoff = {}, attached = false, ever_attached = false,
    next_discover = 0, verified_port = nil, verified_at = 0, last_warn = {}, last_port = nil,
    frontend_seen = {},
  }, Injector)
end

function Injector:_warn(key, msg, now)
  if (self.last_warn[key] or -1e9) + 30 < now then
    self.last_warn[key] = now
    log.warn(msg)
  end
end

function Injector:_close_all(reason)
  for ws, s in pairs(self.sessions) do
    self.sessions[ws] = nil
    s:close(reason)
  end
  self.attached = false
end

function Injector:session_list()
  local list = {}
  for _, s in pairs(self.sessions) do list[#list + 1] = s end
  return list
end

function Injector:sockets()
  local r = {}
  for _, s in pairs(self.sessions) do if not s.closed then r[#r + 1] = s.sock end end
  return r
end

function Injector:write_sockets()
  local w = {}
  for _, s in pairs(self.sessions) do if s:wants_write() then w[#w + 1] = s.sock end end
  return w
end

function Injector:poll_timeout(now)
  now = now or socket.gettime()
  local t = math.max(0.01, math.min(1.0, self.next_discover - now))
  for _, s in pairs(self.sessions) do
    if s.data.dirty_at then t = math.min(t, math.max(0.01, s.data.dirty_at - now)) end
    if s:wants_write() then t = math.min(t, 0.05) end
  end
  return t
end

-- Pump sessions whose sockets were reported readable/writable by select.
function Injector:service(readable, writable)
  local rset, wset = {}, {}
  for _, s in ipairs(readable or {}) do rset[s] = true end
  for _, s in ipairs(writable or {}) do wset[s] = true end
  for _, s in pairs(self.sessions) do
    if rset[s.sock] then s:pump() end
    if wset[s.sock] then s:flush() end
  end
  for ws, s in pairs(self.sessions) do
    if s.closed then self.sessions[ws] = nil end
  end
end

---------------------------------------------------------------- injection
local function css_script(id, text)
  return "(function(){var id=" .. rpc.js_literal(id) .. ";" ..
    "var o=document.querySelectorAll('style[data-luna-css]');" ..
    "for(var i=0;i<o.length;i++){if(o[i].getAttribute('data-luna-css')===id)o[i].remove();}" ..
    "var s=document.createElement('style');s.setAttribute('data-luna-css',id);" ..
    "s.textContent=" .. rpc.js_literal(text) ..
    ";(document.head||document.documentElement).appendChild(s);})()"
end

local function marker_script(key)
  return "(window.__lunaDone=window.__lunaDone||{})[" .. rpc.js_literal(key) .. "]=1"
end

local function log_eval(what)
  return function(res, err)
    if err then
      log.warn("cdp " .. what .. " failed: " .. (type(err) == "table" and tostring(err.message) or tostring(err)))
    elseif type(res) == "table" and res.exceptionDetails then
      local d = res.exceptionDetails
      local msg = d.exception and d.exception.description or d.text
      log.warn("script " .. what .. " threw: " .. tostring(msg):sub(1, 200))
    end
  end
end

function Injector:_inject(sess)
  local d = sess.data
  d.dirty_at = nil
  if d.busy then d.dirty_at = (self.now or socket.gettime()) + M.REINJECT_DELAY; return end
  d.busy = true
  if not d.enabled then
    d.enabled = true
    sess:send("Page.enable", {}, log_eval("Page.enable"))
    sess:send("Runtime.enable", {}, log_eval("Runtime.enable"))
  end
  sess:send("Runtime.addBinding", { name = polyfill.BINDING }, log_eval("addBinding"))
  sess:evaluate(polyfill.build(d.token), log_eval("polyfill"))
  sess:evaluate("Object.keys(window.__lunaDone||{})", function(res, err)
    d.busy = false
    if err or type(res) ~= "table" or not res.result then
      if not sess.closed then d.dirty_at = (self.now or socket.gettime()) + 1.0 end
      return
    end
    local done = {}
    for _, k in ipairs(res.result.value or {}) do done[k] = true end
    local assets = self.opts.assets and self.opts.assets[d.channel]
    if assets then
      local function run(kind, fmt)
        for _, a in ipairs(assets[kind]) do
          local key = d.epoch .. ":" .. a.id
          if not done[key] then
            sess:evaluate(fmt(a), log_eval(a.id))
            sess:evaluate(marker_script(key), nil)
          end
        end
      end
      run("css", function(a) return css_script(a.id, a.text) end)
      run("js", function(a) return a.text end)
    end
    if not d.announced then
      d.announced = true
      log.info("injected into " .. d.channel .. " target " .. tostring(d.title or d.url))
      if self.opts.plugins then
        local ok, plugins = pcall(require, "luna.plugins")
        if ok then plugins.frontend_loaded(self.opts.plugins, d.channel) end
      end
    end
  end)
end

function Injector:_attach(ws, target, channel, port, now)
  local open = self.opts.open or cdp.open
  local sess, err = open(ws, port)
  if not sess then
    local b = self.backoff[ws] or { delay = 0.5 }
    b.next = now + b.delay
    b.delay = math.min(b.delay * 2, 10)
    self.backoff[ws] = b
    self:_warn("open:" .. ws, "cannot attach " .. tostring(target.title) .. ": " .. tostring(err), now)
    return
  end
  self.backoff[ws] = nil
  local token = polyfill.new_token()
  sess.data = { channel = channel, token = token, epoch = wsframe.sha1_hex(token):sub(1, 10),
    title = target.title, url = target.url, ws = ws, dirty_at = now, recheck_at = now + M.RECHECK_INTERVAL }
  local function dirty()
    if not sess.data.dirty_at then sess.data.dirty_at = (self.now or socket.gettime()) + M.REINJECT_DELAY end
  end
  sess:on("Page.frameNavigated", function(p) if not (p.frame and p.frame.parentId) then dirty() end end)
  sess:on("Page.loadEventFired", dirty)
  sess:on("Page.domContentEventFired", dirty)
  sess:on("Runtime.executionContextsCleared", dirty)
  sess:on("Runtime.executionContextCreated", function(p)
    local aux = p.context and p.context.auxData
    if aux and aux.isDefault then dirty() end
  end)
  sess:on("Runtime.bindingCalled", function(p)
    if p.name == polyfill.BINDING then
      rpc.handle(sess, { registry = self.opts.registry, token = sess.data.token }, p.payload, p.executionContextId)
    end
  end)
  for _, ev in ipairs({ "Inspector.detached", "Inspector.targetCrashed" }) do
    sess:on(ev, function() sess:close(ev) end)
  end
  sess:on("close", function(reason)
    if self.sessions[ws] == sess then self.sessions[ws] = nil end
    log.info("detached from " .. tostring(target.title or ws) .. " (" .. tostring(reason) .. ")")
  end)
  self.sessions[ws] = sess
  self.attached = true
  self.ever_attached = true
  log.info("attached to " .. channel .. " target " .. tostring(target.title or target.url))
end

---------------------------------------------------------------- discovery
function Injector:_verify(port, now)
  if self.verified_port == port and now - self.verified_at < M.VERIFY_TTL then return true end
  local verify = self.opts.verify or peer.verify
  local ok, info = verify(port)
  if ok then
    self.verified_port, self.verified_at = port, now
    return true
  end
  self.verified_port = nil
  return false, info
end

function Injector:discover(now)
  local port, source = self.opts.port()
  if self.last_port and self.last_port ~= port then
    log.info("cef port changed " .. tostring(self.last_port) .. " -> " .. tostring(port))
    self:_close_all("port changed")
  end
  self.last_port = port
  local ok, why = self:_verify(port, now)
  if not ok then
    if next(self.sessions) then self:_close_all("peer verification failed") end
    self:_warn("peer", "port " .. port .. " (" .. tostring(source) .. ") not trusted: " .. tostring(why), now)
    return
  end
  local targets, err = M.list_targets(port, self.opts.get)
  if not targets then
    if next(self.sessions) then self:_close_all("cdp unreachable") end
    self:_warn("json", "GET /json failed: " .. tostring(err), now)
    return
  end
  local seen = {}
  for _, t in ipairs(targets) do
    local ws = t.ws
    if t.channel and type(ws) == "string" and not seen[ws] then
      seen[ws] = true
      local sess = self.sessions[ws]
      if sess then
        if sess.data.channel ~= t.channel then
          sess.data.channel = t.channel
          sess.data.dirty_at = now
        end
        sess.data.title, sess.data.url = t.title, t.url
      else
        local b = self.backoff[ws]
        if not b or b.next <= now then self:_attach(ws, t, t.channel, port, now) end
      end
    end
  end
  for ws, s in pairs(self.sessions) do
    if not seen[ws] then self.sessions[ws] = nil; s:close("target gone") end
  end
  for ws in pairs(self.backoff) do if not seen[ws] then self.backoff[ws] = nil end end
  self.attached = next(self.sessions) ~= nil
end

function Injector:tick(now)
  now = now or socket.gettime()
  self.now = now
  if now >= self.next_discover then
    local ok, err = pcall(self.discover, self, now)
    if not ok then log.error("discover: " .. tostring(err)) end
    self.next_discover = now + (self.attached and M.REDISCOVER_INTERVAL or M.DISCOVER_INTERVAL)
  end
  for ws, s in pairs(self.sessions) do
    if s.closed then
      self.sessions[ws] = nil
    else
      s:tick(now)
      local d = s.data
      -- Missed navigation/context events must not leave a target un-injected: recheck
      -- periodically (the inject is idempotent, markers prevent double-running assets).
      if not d.dirty_at and not d.busy and now >= (d.recheck_at or 0) then
        d.recheck_at = now + M.RECHECK_INTERVAL
        if d.announced then d.dirty_at = now end
      end
      if d.dirty_at and d.dirty_at <= now and not s.closed then
        local ok, err = pcall(self._inject, self, s)
        if not ok then log.error("inject: " .. tostring(err)) end
      end
    end
  end
  self.attached = next(self.sessions) ~= nil
end

function Injector:shutdown() self:_close_all("shutdown") end

return M
