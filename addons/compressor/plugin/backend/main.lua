-- SLS Compressor backend extension for Luna.
-- Runs within the existing Luna process; no extra network listener. Wraps the
-- btrfs-game-compressor CLI: a read-only status scan, plus long passes that keep
-- running detached while this RPC surface only watches their pid and a bounded
-- tail of their log. The safe knobs (ZSTD compression, deduplication, exclusions,
-- a size ceiling) live here and are mirrored into the tool's own config files, so
-- the TUI and every pass agree. Beta asset optimization is off by default and
-- never runs unattended from a batch.
local json = require('json')
local fs = require('fs')
local M = {}
local HOME = os.getenv('HOME') or ''
local DIR = HOME .. '/.local/share/Luna/data/compressor'
local STATUS = DIR .. '/status.json'
local STATUS_TMP = DIR .. '/status.tmp'
local STATUS_AT = DIR .. '/status.at'
local ATTEMPT_AT = DIR .. '/attempt.at'
local JOB_FILE = DIR .. '/job.json'
local JOB_DONE = DIR .. '/job.done'
local JOB_LOG = DIR .. '/last.log'
local SETTINGS = DIR .. '/settings.json'
-- One-game-at-a-time queue: the backend writes a list and a driver script, the
-- driver runs `--compact` per game and appends state, and the UI reads both.
local QUEUE_LIST = DIR .. '/queue.list'
local QUEUE_STATE = DIR .. '/queue.state'
local QUEUE_LOG = DIR .. '/run.log'
local DRIVER = DIR .. '/run-queue.sh'
-- The tool's own configuration, one file per knob (see its --help FILES).
local TOOL_DIR = HOME .. '/.config/btrfs-game-compressor'
-- The tool's own ledgers, read-only, powering the Stats tab: one line per game
-- with its measured sizes, and one measurement per dedupe pass per directory.
-- Both carry a '#' version header, and rows that do not match the expected
-- shape are skipped, so a future format degrades to missing numbers instead of
-- a broken page.
local TOOL_STATE_DIR = HOME .. '/.local/state/btrfs-game-compressor'
local TOOL_STATE_FILE = TOOL_STATE_DIR .. '/compressed_games.db'
local TOOL_DEDUPE_HISTORY = TOOL_STATE_DIR .. '/dedupe_physical_history.db'

-- Where the CLI may live, in preference order: the env override is the test
-- seam, then an installed copy, then a source checkout (bgc-native has to sit
-- beside the script, which a checkout keeps). Kept dense: a nil first entry
-- would stop ipairs dead.
local CANDIDATES = {}
local function candidate(path)
  if type(path) == 'string' and path ~= '' then CANDIDATES[#CANDIDATES + 1] = path end
end
candidate(os.getenv('SLS_COMPRESSOR_BIN'))
candidate(HOME .. '/.local/bin/btrfs-game-compressor')
candidate('/usr/local/bin/btrfs-game-compressor')
candidate('/usr/bin/btrfs-game-compressor')
candidate(HOME .. '/Documents/Scripts/btrfs-game-compressor/btrfs-game-compressor')

-- Fixed, no-argument operations. `run` is composed from the saved settings at
-- call time; `preview` stays read-only; `assets` is the alpha inventory.
local ACTIONS = {
  scan = { args = '--status --json', scan = true },
  preview = { args = '--dry-run --pending' },
  -- Remeasures the installed games and refreshes the tool's own saved-size
  -- ledger; it never recompresses anything. This is what fills the Stats tab.
  recheck = { args = '--recheck' },
  run = { args = '--run' },
  assets = { args = '--assets-all' },
}

-- The alpha resolution profile set, exactly as the tool names it. `native`
-- (no asset changes) is represented by the feature toggle being off.
local PROFILES = {
  ['ultra-performance'] = 1, performance = 1, balanced = 1,
  quality = 1, ['ultra-quality'] = 1, lossless = 1,
}

-- How the per-game queue is ordered. Smallest first is the default: a first
-- run then shows completed games almost immediately.
local RUN_ORDERS = { smallest = 1, largest = 1, library = 1 }

local function shq(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function read_text(path)
  local f = io.open(path, 'rb')
  if not f then return nil end
  local data = f:read('*a'); f:close()
  return data
end

local function dirname(path)
  return tostring(path):match('^(.*)/[^/]+$') or '.'
end

-- Writes through a temp file so a reader never sees a half-written report.
local function write_text(path, text)
  fs.create_directories(dirname(path))
  local tmp = path .. '.tmp'
  local f = io.open(tmp, 'wb')
  if not f then return false end
  local written = f:write(text)
  local closed = f:close()
  if not written or not closed then os.remove(tmp); return false end
  if not os.rename(tmp, path) then os.remove(tmp); return false end
  return true
end

local function strip_ansi(text)
  return (tostring(text):gsub('\27%[[0-9;?]*[%a]', ''))
end

-- Up to `lines` log lines from the end of a file, so a multi-megabyte pass
-- cannot flood one RPC response. Progress lines are redrawn with carriage
-- returns; the terminal shows the last rewrite, so only that is kept.
local function tail(path, lines, limit)
  local f = io.open(path, 'rb')
  if not f then return '' end
  local size = f:seek('end') or 0
  local start = size - (limit or 65536)
  if start < 0 then start = 0 end
  f:seek('set', start)
  local data = f:read('*a') or ''
  f:close()
  local out = {}
  for raw in data:gmatch('[^\n]+') do
    local line = strip_ansi(raw)
    -- A carriage return rewinds to column 0, so everything before the last
    -- rewrite on the line is invisible to a terminal; keep the last non-empty
    -- segment (a line ending in '\r' still shows the text before it).
    local segments = {}
    for segment in (line .. '\r'):gmatch('([^\r]*)\r') do segments[#segments + 1] = segment end
    line = ''
    for index = #segments, 1, -1 do
      if segments[index] ~= '' then line = segments[index]; break end
    end
    out[#out + 1] = line
  end
  while #out > lines do table.remove(out, 1) end
  return table.concat(out, '\n')
end

local function find_tool()
  for _, path in ipairs(CANDIDATES) do
    if type(path) == 'string' and path ~= '' and fs.exists(path) then return path end
  end
  return nil
end

-- A pid is ours while /proc still shows the wrapper or the queue driver.
-- Anything else (a recycled pid, a vanished process) counts as finished.
local function alive(pid)
  if type(pid) ~= 'number' or pid < 2 then return false end
  local f = io.open('/proc/' .. math.floor(pid) .. '/cmdline', 'rb')
  if not f then return false end
  local data = f:read('*a'); f:close()
  if type(data) ~= 'string' then return false end
  return data:find('btrfs-game-compressor', 1, true) ~= nil
    or data:find('run-queue.sh', 1, true) ~= nil
end

-- The process group of a live pid, so a cancel can reach the stage children
-- without ever signalling Steam. The comm field may contain spaces, hence the
-- parse after the last ')'.
local function process_group(pid)
  local raw = read_text('/proc/' .. math.floor(pid) .. '/stat')
  local rest = raw and raw:match('%)%s*(.+)$')
  if not rest then return nil end
  local fields = {}
  for field in rest:gmatch('%S+') do fields[#fields + 1] = field end
  return tonumber(fields[3]) -- state, ppid, pgrp
end

-- ---------------------------------------------------------------------------
-- Settings: the source of truth is our own file; the tool's config files are a
-- mirror written on every save so its TUI and a manual CLI run see the same
-- policy. Nothing here is ever free-form: game names are one line each.

local function valid_game_name(value)
  return type(value) == 'string' and #value > 0 and #value <= 255
    and value:find('[\r\n/]') == nil and value ~= '.' and value ~= '..'
end

local function normalize_languages(raw)
  local seen, list = {}, {}
  for token in tostring(raw or ''):gmatch('[^,%s]+') do
    local code = token:lower()
    if code:match('^[a-z0-9%-]+$') and not seen[code] then
      seen[code] = true
      list[#list + 1] = code
    end
  end
  table.sort(list)
  return table.concat(list, ',')
end

local function default_settings()
  return {
    version = 1,
    compress = true,
    dedupe = true,
    eco = false,
    assets = false,
    assetProfile = 'balanced',
    keepLanguages = '',
    maxSizeGb = 0,
    runOrder = 'smallest',
    excluded = {},
  }
end

local function read_settings()
  local data = default_settings()
  local raw = read_text(SETTINGS)
  if not raw then return data end
  local ok, value = pcall(json.decode, raw)
  if not ok or type(value) ~= 'table' then return data end
  if type(value.compress) == 'boolean' then data.compress = value.compress end
  if type(value.dedupe) == 'boolean' then data.dedupe = value.dedupe end
  if type(value.eco) == 'boolean' then data.eco = value.eco end
  if type(value.assets) == 'boolean' then data.assets = value.assets end
  if PROFILES[value.assetProfile] then data.assetProfile = value.assetProfile end
  if RUN_ORDERS[value.runOrder] then data.runOrder = value.runOrder end
  data.keepLanguages = normalize_languages(value.keepLanguages)
  local size = tonumber(value.maxSizeGb)
  if size and size >= 0 and size <= 100000 then
    data.maxSizeGb = math.floor(size * 1000 + 0.5) / 1000
  end
  for _, name in ipairs(type(value.excluded) == 'table' and value.excluded or {}) do
    if valid_game_name(name) and #data.excluded < 4096 then
      data.excluded[#data.excluded + 1] = name
    end
  end
  return data
end

-- Mirror the knobs the tool owns. Assets off pins visual_target to native, so
-- no pass and no TUI action can change game assets while the toggle is off.
local function save_settings(data)
  if not write_text(SETTINGS, json.encode(data)) then return false end
  fs.create_directories(TOOL_DIR)
  write_text(TOOL_DIR .. '/throttle.conf', data.eco and '1\n' or '0\n')
  write_text(TOOL_DIR .. '/visual_target', (data.assets and data.assetProfile or 'native') .. '\n')
  write_text(TOOL_DIR .. '/max_size_mib', tostring(math.floor(data.maxSizeGb * 1024 + 0.5)) .. '\n')
  write_text(TOOL_DIR .. '/keep_languages', data.keepLanguages .. '\n')
  write_text(TOOL_DIR .. '/exclude_games',
    (#data.excluded > 0 and table.concat(data.excluded, '\n') .. '\n' or ''))
  return true
end

-- What the current settings would actually do, straight from the last scan.
local function build_plan(status, settings)
  local plan = { total = 0, pending = 0, compacted = 0, running = 0,
    excluded = 0, overSize = 0, compress = 0, dedupe = 0, blocked = 0 }
  local blocked = {}
  for _, name in ipairs(settings.excluded) do blocked[name] = true end
  local ceiling = tonumber(settings.maxSizeGb) or 0
  local ceiling_bytes = ceiling > 0 and math.floor(ceiling * 1024 * 1024 * 1024) or 0
  for _, game in ipairs((status and status.games) or {}) do
    plan.total = plan.total + 1
    local state = tostring(game.status or '')
    local size = tonumber(game.size_bytes) or 0
    if state == 'COMPACTED' then
      plan.compacted = plan.compacted + 1
    elseif state == 'RUNNING' then
      plan.running = plan.running + 1
    else
      plan.pending = plan.pending + 1
      local excluded = blocked[game.name] == true
      local over = ceiling_bytes > 0 and size >= ceiling_bytes
      if excluded then plan.excluded = plan.excluded + 1 end
      if over then plan.overSize = plan.overSize + 1 end
      if excluded or over then
        plan.blocked = plan.blocked + 1
      elseif state == 'UNCOMPRESSED' or state == 'UPDATED' then
        plan.compress = plan.compress + 1
      elseif state == 'COMPRESSED' then
        plan.dedupe = plan.dedupe + 1
      elseif state == 'LOW YIELD' and game.dedupe_pending == true then
        plan.dedupe = plan.dedupe + 1
      end
    end
  end
  return plan
end

-- ---------------------------------------------------------------------------
-- The one-game-at-a-time queue. The list is written game by game so the UI can
-- show a state and a bar per game, and the driver is a small detached shell
-- script so the pass continues even when Steam or Luna goes away.

-- The queue mirrors the plan: compression targets first, then games whose
-- dedupe pass is outstanding. Running and compacted games are never queued, and
-- the user's filters (exclusions, size ceiling) already applied.
local function build_queue(status, settings)
  local blocked = {}
  for _, name in ipairs(settings.excluded) do blocked[name] = true end
  local ceiling = tonumber(settings.maxSizeGb) or 0
  local ceiling_bytes = ceiling > 0 and math.floor(ceiling * 1024 * 1024 * 1024) or 0
  local queue = {}
  for _, game in ipairs((status and status.games) or {}) do
    local state = tostring(game.status or '')
    local size = tonumber(game.size_bytes) or 0
    local path = tostring(game.path or '')
    local name = tostring(game.name or '')
    local excluded = blocked[name] == true
    local over = ceiling_bytes > 0 and size >= ceiling_bytes
    if not excluded and not over and path ~= '' and name ~= '' then
      local compress = settings.compress and (state == 'UNCOMPRESSED' or state == 'UPDATED')
      local dedupe = settings.dedupe and (state == 'COMPRESSED'
        or (state == 'LOW YIELD' and game.dedupe_pending == true))
      if compress or dedupe then
        queue[#queue + 1] = { name = name, path = path, size = size }
      end
    end
  end
  if settings.runOrder == 'largest' then
    table.sort(queue, function(a, b) return a.size > b.size end)
  elseif settings.runOrder == 'smallest' then
    table.sort(queue, function(a, b) return a.size < b.size end)
  end
  return queue
end

-- ---------------------------------------------------------------- statistics
--
-- The Stats tab reads the compressor's own ledgers instead of re-measuring:
-- nothing here runs the tool, and a missing ledger is simply an empty report.

local MIB = 1048576

-- The tool escapes '%', '|' and control characters in its keys.
local function decode_field(value)
  return (tostring(value):gsub('%%(%x%x)', function(hex)
    local code = tonumber(hex, 16)
    if code == 0x25 then return '%' end
    if code == 0x7C then return '|' end
    if code == 0x09 then return '\t' end
    if code == 0x0A then return '\n' end
    if code == 0x0D then return '\r' end
    return '%' .. hex
  end))
end

local function pipe_fields(line)
  local fields = {}
  for field in (tostring(line) .. '|'):gmatch('([^|]*)|') do fields[#fields + 1] = field end
  return fields
end

-- compressed_games.db, state v2: path|name|stamp|original|on-disk|saved-label|
-- saved MiB|original MiB|on-disk MiB. Only rows the tool has measured (a
-- non-zero original MiB) carry numbers; the rest are records without a size.
function M.parse_state_db(text)
  local records, measured = 0, {}
  for line in tostring(text or ''):gmatch('[^\n]+') do
    if line:sub(1, 1) ~= '#' then
      local fields = pipe_fields(line)
      if #fields >= 9 and fields[1] ~= '' then
        records = records + 1
        local original = tonumber(fields[8]) or 0
        local disk = tonumber(fields[9]) or 0
        if original > 0 then
          measured[#measured + 1] = {
            name = decode_field(fields[2]),
            path = decode_field(fields[1]),
            at = tonumber(fields[3]) or 0,
            original_bytes = original * MIB,
            disk_bytes = disk * MIB,
            saved_bytes = math.max(0, (original - disk) * MIB),
          }
        end
      end
    end
  end
  return { records = records, measured = measured }
end

-- dedupe_physical_history.db: stamp|path|before|...|after|...|saved. The latest
-- measurement per directory wins; earlier passes for the same directory would
-- otherwise count the same reclaimed bytes twice.
function M.parse_dedupe_history(text)
  local by_path, passes, newest = {}, 0, 0
  for line in tostring(text or ''):gmatch('[^\n]+') do
    if line:sub(1, 1) ~= '#' then
      local fields = pipe_fields(line)
      if #fields >= 9 and fields[2] ~= '' then
        passes = passes + 1
        local at = tonumber(fields[1]) or 0
        local current = by_path[fields[2]]
        if not current or at >= current.at then
          by_path[fields[2]] = {
            path = decode_field(fields[2]),
            at = at,
            before_bytes = tonumber(fields[3]) or 0,
            after_bytes = tonumber(fields[7]) or 0,
            saved_bytes = tonumber(fields[9]) or 0,
          }
        end
        if at > newest then newest = at end
      end
    end
  end
  local entries, saved_total = {}, 0
  for _, entry in pairs(by_path) do
    entries[#entries + 1] = entry
    saved_total = saved_total + entry.saved_bytes
  end
  table.sort(entries, function(a, b) return a.saved_bytes > b.saved_bytes end)
  return { passes = passes, directories = #entries, saved_bytes = saved_total,
    newest = newest, entries = entries }
end

local function top_list(list, count)
  local out = {}
  for index = 1, math.min(#list, count) do out[#out + 1] = list[index] end
  return out
end

-- Everything the Stats tab shows, in one read-only pass over small files.
local function build_stats(status, queue)
  local state = M.parse_state_db(read_text(TOOL_STATE_FILE))
  local dedupe = M.parse_dedupe_history(read_text(TOOL_DEDUPE_HISTORY))
  local measured = state.measured
  table.sort(measured, function(a, b) return a.saved_bytes > b.saved_bytes end)
  local original, disk, saved = 0, 0, 0
  for _, entry in ipairs(measured) do
    original = original + entry.original_bytes
    disk = disk + entry.disk_bytes
    saved = saved + entry.saved_bytes
  end
  -- Luna's own passes: the queue driver records the ZSTD bytes each game
  -- reclaimed, which works even when the tool kept no MiB ledger.
  local luna_saved, luna_games = 0, {}
  for _, entry in ipairs((queue and queue.games) or {}) do
    if (entry.saved or 0) > 0 then
      luna_saved = luna_saved + entry.saved
      luna_games[#luna_games + 1] = { name = entry.name, saved_bytes = entry.saved }
    end
  end
  table.sort(luna_games, function(a, b) return a.saved_bytes > b.saved_bytes end)
  -- Library totals come from the last scan: exact sizes per installed game.
  local library_bytes, library_games = 0, 0
  for _, game in ipairs((status and status.games) or {}) do
    local size = tonumber(game.size_bytes) or 0
    if size > 0 then
      library_bytes = library_bytes + size
      library_games = library_games + 1
    end
  end
  return {
    compression = { records = state.records, measured = #measured,
      original_bytes = original, disk_bytes = disk, saved_bytes = saved,
      games = json.array(top_list(measured, 10)) },
    dedupe = { passes = dedupe.passes, directories = dedupe.directories,
      saved_bytes = dedupe.saved_bytes, newest = dedupe.newest,
      entries = json.array(top_list(dedupe.entries, 10)) },
    luna = { measured = #luna_games, saved_bytes = luna_saved,
      games = json.array(top_list(luna_games, 10)) },
    library = { games = library_games, bytes = library_bytes },
  }
end

-- The driver runs one `--compact` per game and appends QUEUE\t<event> lines to
-- the state file; the log holds the tool's own output, including its
-- COMPACT| and PROGRESS| lines.
local function write_driver(tool)
  local template = [[#!/bin/bash
# SLS Luna compressor queue driver: one game at a time, so the panel can show a
# state and a bar per game. Written by the backend; do not edit by hand.
set -u
DIR=@DIR@
TOOL=@TOOL@
LIST=@LIST@
LOG=@LOG@
STATE=@STATE@
: > "$LOG"
: > "$STATE"
total=0
while IFS=$'\t' read -r name path size; do
    [ -n "$path" ] || continue
    total=$((total+1))
done < "$LIST"
i=0
while IFS=$'\t' read -r name path size; do
    [ -n "$path" ] || continue
    i=$((i+1))
    printf 'start\t%s\t%s\t%s\t%s\t%s\n' "$i" "$total" "$size" "$name" "$path" >> "$STATE"
    BGC_PROGRESS=1 BGC_PROGRESS_TOTAL="$size" "$TOOL" --compact "$path" --verbose >> "$LOG" 2>&1
    rc=$?
    saved=0
    if [ "$rc" -eq 0 ]; then
        saved=$(grep -a '^COMPACT|done' "$LOG" | tail -n 1 | awk -F'|' '{print $(NF-1)}')
        [ -n "$saved" ] || saved=0
    fi
    printf 'done\t%s\t%s\t%s\t%s\n' "$i" "$total" "$rc" "$saved" >> "$STATE"
    if [ "$rc" -eq 130 ] || [ "$rc" -eq 143 ]; then
        break
    fi
done < "$LIST"
printf 'finish\t%s\t%s\n' "$i" "$total" >> "$STATE"
]]
  local script = template:gsub('@(%u+)@', {
    DIR = shq(DIR), TOOL = shq(tool), LIST = shq(QUEUE_LIST),
    LOG = shq(QUEUE_LOG), STATE = shq(QUEUE_STATE),
  })
  if not write_text(DRIVER, script) then return false end
  os.execute('chmod +x ' .. shq(DRIVER))
  return true
end

local function read_tail_bytes(path, bytes)
  local f = io.open(path, 'rb')
  if not f then return '' end
  local size = f:seek('end') or 0
  local start = size - (bytes or 262144)
  if start < 0 then start = 0 end
  f:seek('set', start)
  local data = f:read('*a') or ''
  f:close()
  return data
end

local function split_tabs(line)
  local out = {}
  for field in (line .. '\t'):gmatch('([^\t]*)\t') do out[#out + 1] = field end
  return out
end

-- Everything the panel needs about the queue: per-game states from the driver,
-- and the current phase and byte counts from the tool's own progress lines.
local function read_queue(limit)
  local raw = read_text(QUEUE_LIST)
  if not raw then return nil end
  local games, byIndex = {}, {}
  local index = 0
  for line in raw:gmatch('[^\n]+') do
    local fields = split_tabs(line)
    if fields[2] and fields[2] ~= '' then
      index = index + 1
      local entry = {
        index = index, name = fields[1] or '', path = fields[2],
        size = tonumber(fields[3]) or 0, status = 'pending', saved = 0,
      }
      games[#games + 1] = entry
      byIndex[index] = entry
    end
  end
  local queue = { total = index, index = 0, current = nil, done = 0, failed = 0,
    skipped = 0, saved = 0, finished = false, phase = '', doneBytes = 0,
    totalBytes = 0, scannedBytes = 0, games = games }
  local state = read_text(QUEUE_STATE)
  if state then
    for line in state:gmatch('[^\n]+') do
      local fields = split_tabs(line)
      local kind = fields[1] or ''
      if kind == 'start' then
        queue.index = tonumber(fields[2]) or 0
        queue.total = tonumber(fields[3]) or queue.total
        queue.current = {
          name = fields[5] or '', path = fields[6] or '',
          size = tonumber(fields[4]) or 0,
        }
        local entry = byIndex[queue.index]
        if entry then entry.status = 'running' end
      elseif kind == 'done' then
        local idx = tonumber(fields[2]) or 0
        local rc = tonumber(fields[4]) or 0
        local saved = tonumber(fields[5]) or 0
        local entry = byIndex[idx]
        if entry then
          entry.status = rc == 0 and 'done' or (rc == 3 and 'skipped' or 'failed')
          entry.saved = saved
        end
        if rc == 0 then queue.done = queue.done + 1
        elseif rc == 3 then queue.skipped = queue.skipped + 1
        else queue.failed = queue.failed + 1 end
        queue.saved = queue.saved + saved
      elseif kind == 'finish' then
        queue.finished = true
        queue.current = nil
      end
    end
  end
  local log = read_tail_bytes(QUEUE_LOG, limit or 262144)
  for line in log:gmatch('[^\n]+') do
    local done_bytes, total_bytes = line:match('^PROGRESS|compress|(%d+)|(%d+)$')
    if done_bytes then
      queue.phase = 'compress'
      queue.doneBytes = tonumber(done_bytes) or 0
      queue.totalBytes = tonumber(total_bytes) or 0
    else
      local hashed = line:match('^PROGRESS|dedupe|(%d+)|%d+$')
      if hashed then
        queue.phase = 'dedupe'
        queue.scannedBytes = tonumber(hashed) or 0
      elseif line:sub(1, 14) == 'COMPACT|phase|' then
        queue.phase = line:sub(15)
        if queue.phase == 'compress' then queue.doneBytes = 0 end
      end
    end
  end
  if queue.current then
    queue.current.phase = queue.phase
    queue.current.doneBytes = queue.doneBytes
    queue.current.totalBytes = queue.totalBytes
    queue.current.scannedBytes = queue.scannedBytes
  end
  -- A short "next up" list so even the light poll can show what follows.
  queue.next = {}
  for _, entry in ipairs(games) do
    if entry.status == 'pending' and #queue.next < 5 then
      queue.next[#queue.next + 1] = { name = entry.name, size = entry.size }
    end
  end
  return queue
end

-- ---------------------------------------------------------------------------
-- Pending-job bookkeeping.

local function read_job()
  local raw = read_text(JOB_FILE)
  if not raw then return nil end
  local ok, value = pcall(json.decode, raw)
  if not ok or type(value) ~= 'table' then return nil end
  local pid = tonumber(value.pid)
  local action = type(value.action) == 'string' and value.action or ''
  if not pid or pid < 2 or pid ~= math.floor(pid) or not ACTIONS[action] then return nil end
  return { action = action, pid = pid, startedAt = tonumber(value.startedAt) or 0 }
end

-- Launches detached so a pass survives Steam and Luna both going away. The
-- command's own shell records $$ in a pid file before exec, which stays correct
-- even in the rare case where setsid has to fork, and it leads its own process
-- group so a cancel can take the whole pass down.
local function spawn_detached(command, action, scan)
  fs.create_directories(DIR)
  os.remove(JOB_DONE)
  write_text(JOB_LOG, '')
  if scan then os.remove(STATUS_TMP) end
  local pidfile = DIR .. '/job.pid'
  os.remove(pidfile)
  local redirect = scan
    and ('> ' .. shq(STATUS_TMP) .. ' 2>> ' .. shq(JOB_LOG))
    or ('> ' .. shq(JOB_LOG) .. ' 2>&1')
  local inner = string.format('echo $$ > %s; exec nohup %s %s < /dev/null',
    shq(pidfile), command, redirect)
  local outer = string.format('setsid sh -c %s < /dev/null > /dev/null 2>&1 &', shq(inner))
  os.execute(outer)
  local pid
  for _ = 1, 20 do
    local raw = read_text(pidfile)
    pid = raw and tonumber(raw:match('(%d+)'))
    if pid then break end
    os.execute('sleep 0.05')
  end
  os.remove(pidfile)
  if not pid then return nil end
  write_text(JOB_FILE, json.encode({ action = action, pid = pid, startedAt = os.time() }))
  if scan then write_text(ATTEMPT_AT, tostring(os.time())) end
  return pid
end

local function spawn(tool, action, args)
  local spec = ACTIONS[action]
  return spawn_detached(shq(tool) .. ' ' .. (args or spec.args), action, spec.scan == true)
end

-- A finished scan only counts once its whole JSON landed; a scan that was
-- cancelled or crashed leaves nothing to adopt.
local function adopt_status()
  if not fs.exists(STATUS_TMP) then return end
  local raw = read_text(STATUS_TMP)
  os.remove(STATUS_TMP)
  if type(raw) ~= 'string' then return end
  local trimmed = raw:gsub('%s+$', '')
  if #trimmed < 16 or trimmed:sub(1, 1) ~= '{' or trimmed:sub(-1) ~= '}' then return end
  if write_text(STATUS, trimmed) then write_text(STATUS_AT, tostring(os.time())) end
end

local function job_state()
  local job = read_job()
  if not job then return nil end
  local running = alive(job.pid)
  local finishedAt = tonumber(read_text(JOB_DONE) or '') or 0
  if not running and finishedAt == 0 then
    finishedAt = os.time()
    write_text(JOB_DONE, tostring(finishedAt))
    if job.action == 'scan' then adopt_status() end
  end
  if running then finishedAt = 0 end
  return {
    action = job.action, pid = job.pid, running = running,
    startedAt = job.startedAt, finishedAt = finishedAt,
    elapsed = running and (os.time() - job.startedAt) or 0,
    log = tail(JOB_LOG, 40, 65536),
  }
end

-- The wire shape for settings: `excluded` must be a real JSON array, or an
-- empty list arrives as {} and a full one as {"1":..,"2":..}.
local function encode_settings(data)
  return {
    version = data.version,
    compress = data.compress,
    dedupe = data.dedupe,
    eco = data.eco,
    assets = data.assets,
    assetProfile = data.assetProfile,
    keepLanguages = data.keepLanguages,
    maxSizeGb = data.maxSizeGb,
    runOrder = data.runOrder,
    excluded = json.array(data.excluded),
  }
end

local function response(o) return json.encode(o) end

function M.register(registry)
  local settings = read_settings()

  local function scan_state()
    local status = nil
    local raw = read_text(STATUS)
    if raw then
      local ok, value = pcall(json.decode, raw)
      if ok and type(value) == 'table' then status = value end
    end
    return status
  end

  registry.SlsCompressorGet = function(raw)
    local tool = find_tool()
    -- Settings can change on disk (a hand edit, another surface), so the file
    -- is the source of truth on every read.
    settings = read_settings()
    -- Polling clients can ask for the light shape: the plan and the job, with
    -- the per-game list left out so a one-second poll stays tiny.
    local light = false
    if type(raw) == 'string' and #raw <= 200 then
      local ok, obj = pcall(json.decode, raw)
      if ok and type(obj) == 'table' and obj.light == true then light = true end
    end
    -- job_state() first: observing a finished scan adopts its report, which is
    -- what this same response must already include.
    local job = job_state()
    local status = scan_state()
    local statusAt = tonumber(read_text(STATUS_AT) or '') or 0
    -- The first open starts the read-only scan itself; a recent failed attempt
    -- is not retried in a loop, and a running job is always left alone.
    local autoStarted = false
    if tool and not (job and job.running) and status == nil then
      local attempt = tonumber(read_text(ATTEMPT_AT) or '') or 0
      if os.time() - attempt > 600 then
        local pid = spawn(tool, 'scan', ACTIONS.scan.args)
        if pid then
          autoStarted = true
          job = job_state()
        end
      end
    end
    local plan = build_plan(status, settings)
    local queue = read_queue(light and 262144 or 524288)
    if queue then
      queue.active = job ~= nil and job.running and job.action == 'run' and not queue.finished
      queue.next = json.array(queue.next or {})
      if light then
        queue.games = nil
      else
        queue.games = json.array(queue.games)
      end
    end
    local wire_status = status
    if light and status then
      wire_status = { version = status.version, summary = status.summary }
    end
    -- The Stats tab is part of the full shape only; polling clients never pay
    -- for it.
    local stats = nil
    if not light then stats = build_stats(status, queue) end
    return response({
      success = true,
      tool = {
        found = tool ~= nil,
        path = tool or '',
        version = status and tostring(status.version or '') or '',
      },
      status = wire_status,
      statusAt = statusAt,
      settings = encode_settings(settings),
      plan = plan,
      queue = queue,
      stats = stats,
      job = job,
      autoStarted = autoStarted,
    })
  end

  registry.SlsCompressorPutSettings = function(raw)
    if type(raw) ~= 'string' or #raw > 200000 then
      return response({success = false, error = 'Invalid payload'})
    end
    local ok, obj = pcall(json.decode, raw)
    if not ok or type(obj) ~= 'table' then
      return response({success = false, error = 'Invalid settings'})
    end
    local next_settings = default_settings()
    for _, key in ipairs({'compress', 'dedupe', 'eco', 'assets'}) do
      if type(obj[key]) == 'boolean' then next_settings[key] = obj[key] end
    end
    if PROFILES[obj.assetProfile] then next_settings.assetProfile = obj.assetProfile end
    if RUN_ORDERS[obj.runOrder] then next_settings.runOrder = obj.runOrder end
    next_settings.keepLanguages = normalize_languages(obj.keepLanguages)
    local size = tonumber(obj.maxSizeGb)
    if size and size >= 0 and size <= 100000 then
      next_settings.maxSizeGb = math.floor(size * 1000 + 0.5) / 1000
    end
    local seen = {}
    for _, name in ipairs(type(obj.excluded) == 'table' and obj.excluded or {}) do
      if valid_game_name(name) and not seen[name] and #next_settings.excluded < 4096 then
        seen[name] = true
        next_settings.excluded[#next_settings.excluded + 1] = name
      end
    end
    table.sort(next_settings.excluded)
    if not save_settings(next_settings) then
      return response({success = false, error = 'Could not save settings'})
    end
    settings = next_settings
    return response({success = true, settings = encode_settings(settings)})
  end

  registry.SlsCompressorRun = function(raw)
    if type(raw) ~= 'string' or #raw > 1000 then
      return response({success = false, error = 'Invalid payload'})
    end
    local ok, obj = pcall(json.decode, raw)
    local action = ok and type(obj) == 'table' and tostring(obj.action or '') or ''
    if not ACTIONS[action] then
      return response({success = false, error = 'Unknown action'})
    end
    local job = job_state()
    if job and job.running then
      return response({success = false, error = 'A job is already running'})
    end
    local tool = find_tool()
    if not tool then
      return response({success = false, error = 'btrfs-game-compressor was not found'})
    end
    if action ~= 'run' then
      local pid = spawn(tool, action, ACTIONS[action].args)
      if not pid then
        return response({success = false, error = 'Could not start the tool'})
      end
      return response({
        success = true,
        job = {action = action, pid = pid, running = true, startedAt = os.time(),
          args = ACTIONS[action].args},
      })
    end
    -- A run is game by game: the backend writes the queue and a detached driver
    -- runs one `--compact` per game, so the panel gets a state and a bar per
    -- game and the pass survives the UI closing.
    if not settings.compress then
      if not settings.dedupe then
        return response({success = false, error = 'Nothing is enabled: turn on compression or deduplication first'})
      end
      -- Dedupe-only has no per-game command; the tool's library pass is the
      -- maintenance path and the queue does not apply.
      local pid = spawn(tool, 'run', '--dedupe')
      if not pid then
        return response({success = false, error = 'Could not start the tool'})
      end
      return response({
        success = true,
        job = {action = 'run', pid = pid, running = true, startedAt = os.time(), args = '--dedupe'},
      })
    end
    local status = scan_state()
    if not status then
      return response({success = false, error = 'Scan the library first so the queue can be built'})
    end
    local queue = build_queue(status, settings)
    if #queue == 0 then
      return response({success = false, error = 'Nothing to do with the current settings'})
    end
    local lines = {}
    for _, game in ipairs(queue) do
      lines[#lines + 1] = game.name .. '\t' .. game.path .. '\t' .. tostring(game.size)
    end
    if not write_text(QUEUE_LIST, table.concat(lines, '\n') .. '\n') then
      return response({success = false, error = 'Could not write the queue'})
    end
    if not write_driver(tool) then
      return response({success = false, error = 'Could not write the queue driver'})
    end
    local pid = spawn_detached(shq(DRIVER), 'run', false)
    if not pid then
      return response({success = false, error = 'Could not start the queue'})
    end
    return response({
      success = true,
      job = {action = 'run', pid = pid, running = true, startedAt = os.time(),
        args = 'queue', queue = #queue},
    })
  end

  -- Best effort, and deliberately terminal: a compaction is checkpointed and
  -- resumable, so a stopped pass loses at most the current game's progress.
  -- Uses /bin/kill explicitly: dash's builtin kill rejects the `--` separator
  -- (CI failure: "Illegal number: -"), while procps kill handles group and
  -- single-PID signalling portably. The outcome is verified, not assumed.
  registry.SlsCompressorCancel = function()
    local job = job_state()
    if not job or not job.running then
      return response({success = false, error = 'No job is running'})
    end
    local pid = math.floor(job.pid)
    local group = process_group(pid)
    local command
    if group and group == pid then
      command = '/bin/kill -TERM -' .. pid
    else
      command = '/bin/kill -TERM ' .. pid
    end
    local ok = os.execute(command)
    -- os.execute returns true/0 on success depending on the Lua version;
    -- anything else means the signal was not delivered.
    local delivered = ok == true or ok == 0
    if not delivered then
      return response({success = false, code = 'signal',
        error = 'Could not signal the running pass (pid ' .. pid .. ')'})
    end
    return response({success = true, cancelled = true, pid = pid})
  end
end

M.tail = tail
M.normalize_languages = normalize_languages
M.binary_candidates = CANDIDATES
return M
