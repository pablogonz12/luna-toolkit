-- Page-side bridge: window.Millennium.callServerMethod -> binding __lunaSend,
-- answered through window.__lunaResolve. The per-connection token lives in a
-- closure (never a window property) and is replaced on re-injection.
local json = require("json")
local wsframe = require("luna.wsframe")

local M = {}
M.BINDING = "__lunaSend"
M.MAX_REQUEST = 4 * 1024 * 1024

function M.new_token() return wsframe.hex(wsframe.random_bytes(16)) end

local TEMPLATE = [[
(function () {
  var w = window;
  var key = %TOKEN%;
  var pending = w.__lunaPending;
  if (!pending || typeof pending !== 'object') {
    pending = Object.create(null);
    Object.defineProperty(w, '__lunaPending', { value: pending, configurable: true, writable: true });
  }
  var seq = typeof w.__lunaSeq === 'number' ? w.__lunaSeq : 0;
  var resolveFn = function (id, resultJson) {
    var p = pending[id];
    if (!p) return false;
    delete pending[id];
    p(resultJson);
    return true;
  };
  var call = function (plugin, fn, args) {
    return new Promise(function (resolve, reject) {
      var send = w.%BINDING%;
      if (typeof send !== 'function') { reject(new Error('luna bridge unavailable')); return; }
      var id = String(++seq);
      w.__lunaSeq = seq;
      pending[id] = resolve;
      var body;
      try {
        body = JSON.stringify({ id: id, fn: String(fn), args: args === undefined ? {} : args, k: key });
      } catch (e) { delete pending[id]; reject(e); return; }
      try { send(body); } catch (e) { delete pending[id]; reject(e); }
    });
  };
  Object.defineProperty(w, '__lunaResolve', { value: resolveFn, configurable: true, writable: true });
  var m = w.Millennium;
  if (!m || (typeof m !== 'object' && typeof m !== 'function')) {
    m = {};
    Object.defineProperty(w, 'Millennium', { value: m, configurable: true, writable: true });
  }
  Object.defineProperty(m, 'callServerMethod', { value: call, configurable: true, writable: true });
  w.__lunaInstalled = true;
})();
]]

local function js_string(s)
  return json.encode(s)
end

-- Builds the full polyfill (token included) for one connection. Safe to run repeatedly.
function M.build(token)
  assert(type(token) == "string" and #token >= 16, "polyfill: token too short")
  assert(token:match("^[%w]+$"), "polyfill: token must be alphanumeric")
  return (TEMPLATE:gsub("%%(%u+)%%", function(name)
    if name == "TOKEN" then return js_string(token) end
    if name == "BINDING" then return M.BINDING end
  end))
end

-- Constant-time-ish string compare.
local function equal(a, b)
  if type(a) ~= "string" or type(b) ~= "string" or #a ~= #b then return false end
  local diff = 0
  for i = 1, #a do diff = diff | (a:byte(i) ~ b:byte(i)) end
  return diff == 0
end
M.equal = equal

-- Returns {id=string, fn=string, args=table|nil} or nil (silently dropped).
function M.parse_request(payload, token)
  if type(payload) ~= "string" or #payload > M.MAX_REQUEST then return nil end
  if type(token) ~= "string" or token == "" then return nil end
  local ok, req = pcall(json.decode, payload)
  if not ok or type(req) ~= "table" then return nil end
  if not equal(req.k, token) then return nil end
  if type(req.fn) ~= "string" or req.fn == "" then return nil end
  local id = req.id
  if type(id) == "number" then id = string.format("%d", id) end
  if type(id) ~= "string" or id == "" or #id > 64 then return nil end
  local args = req.args
  if args ~= nil and type(args) ~= "table" then args = nil end
  return { id = id, fn = req.fn, args = args }
end

return M
