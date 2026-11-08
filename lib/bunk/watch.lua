-- bunk watcher. Run by Rex, from the line `bunk install` adds to init.lua:
--   rex --autostart=false do watch.lua --all state_dir=DIR [period=SECONDS]
-- It exits when the server stops; the next server start runs a new one.

local dir = debug.getinfo(1, "S").source:gsub("^@", ""):match("^(.*)/[^/]*$")
package.path = dir .. "/?.lua;" .. package.path
local core = require("core")

local T = "com.superlogical.terminal"
local args = rex.args or {}
local HOME = os.getenv("HOME") or ""
local STATE = args.state_dir or ((os.getenv("XDG_STATE_HOME") or (HOME .. "/.local/state")) .. "/bunk")
local PANES = STATE .. "/panes"
local CLAUDE_DIR = os.getenv("CLAUDE_CONFIG_DIR") or (HOME .. "/.claude")
local CODEX_HOME = os.getenv("CODEX_HOME") or (HOME .. "/.codex")
local PERIOD = tonumber(args.period or os.getenv("BUNK_PERIOD")) or 3
-- seconds of uptime before records of absent panes are collected
local GC_AFTER = tonumber(args.gc_after or os.getenv("BUNK_GC_AFTER")) or 30

local function now() return os.time() end
local function trim(s) return (s or ""):gsub("^%s+", ""):gsub("%s+$", "") end

local function read(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

local function write_atomic(path, s)
  local tmp = path .. ".tmp"
  local f = io.open(tmp, "w")
  if not f then return false end
  f:write(s)
  f:close()
  return os.rename(tmp, path)
end

local function log(...)
  local f = io.open(STATE .. "/bunk.log", "a")
  if not f then return end
  f:write(os.date("!%Y-%m-%dT%H:%M:%SZ "), table.concat({ ... }, " "), "\n")
  f:close()
end

local function decode(s)
  if not s or s == "" then return nil end
  local ok, v = pcall(rex.json.decode, s)
  if ok then return v end
  return nil
end

-- Register a handler before any session call: until one exists, session
-- calls fail with "stream is not attached".
local pending = {}
local flush_scheduled = false
local step, flush
rex.on("terminal.process_changed", function(ctx)
  if not ctx.block_id then return end
  pending[ctx.block_id] = ctx.session_id
  if not flush_scheduled then
    flush_scheduled = true
    rex.after(0.3, function() flush() end)
  end
end)

rex.exec({ "mkdir", "-p", PANES })
rex.exec({ "chmod", "700", STATE })
do -- keep the log under 1 MB
  local f = io.open(STATE .. "/bunk.log", "r")
  if f then
    local size = f:seek("end")
    f:close()
    if size and size > 1024 * 1024 then os.rename(STATE .. "/bunk.log", STATE .. "/bunk.log.1") end
  end
end

-- Newest watcher wins: a config reload or `bunk start` starts another one,
-- and the older one stops at its next event or tick. Uninstall overwrites
-- the token too. The new watcher takes no step until the one it replaces
-- has exited, so two watchers never act at once: one could otherwise
-- overwrite a record the other just saved, or write "resuming" and stop
-- before typing (verify/restore, finding F3).
local TOKEN_FILE = STATE .. "/watcher.token"
local PID_FILE = STATE .. "/watcher.pid"
local token = trim(rex.exec({ "uuidgen" }).stdout)
if token == "" then token = tostring(os.time()) .. tostring(os.clock()) .. tostring({}) end
local my_pid = tonumber(trim(rex.exec({ "sh", "-c", "echo $PPID" }).stdout))

local function is_watcher(pid)
  if not pid or pid == my_pid then return false end
  local r = rex.exec({ "ps", "-ww", "-o", "args=", "-p", tostring(pid) })
  return r and r.ok and r.stdout:find("watch.lua", 1, true) ~= nil
end

-- The pid file names the latest watcher, waiting or running. Each watcher
-- waits for the one named before it, which waited for its own predecessor.
local predecessor = tonumber(trim(read(PID_FILE)))
write_atomic(PID_FILE, tostring(my_pid or "") .. "\n")
write_atomic(TOKEN_FILE, token .. "\n")
log("start", core.VERSION, token)
do
  local waited = 0
  while is_watcher(predecessor) and waited < 15 do
    rex.sleep(0.2)
    waited = waited + 0.2
  end
  if is_watcher(predecessor) then
    log("stop", predecessor, "(previous watcher still running after 15s; killing it)")
    rex.exec({ "kill", tostring(predecessor) })
    rex.sleep(1)
  end
end
if trim(read(TOKEN_FILE)) ~= token then
  log("stop", token, "(replaced while waiting for the previous watcher)")
  rex.stop(0)
  return
end
local started = now()

-- rex.stop may unwind by raising, and pcall would swallow that, so callers
-- check the flag and stop again outside their pcall.
local stopping = false
local function guard()
  if stopping then return false end
  if trim(read(TOKEN_FILE)) ~= token then
    stopping = true
    log("stop", token, "(newer watcher or uninstall)")
    rex.stop(0)
  end
  return not stopping
end

local function record_path(block_id)
  local name = (block_id or ""):gsub(":", "_")
  if not name:match("^[%w_.-]+$") then return nil end
  return PANES .. "/" .. name .. ".json"
end

local function load(block_id)
  local p = record_path(block_id)
  return p and decode(read(p))
end

local function save(block_id, rec)
  local p = record_path(block_id)
  if p then write_atomic(p, rex.json.encode(rec) .. "\n") end
end

local function remove(block_id)
  local p = record_path(block_id)
  if p then os.remove(p) end
end

-- Pids and chat ids used since the last complete pass. The caches below are
-- trimmed to these after each one, so they don't grow with every process.
local touched = {}

local start_cache = {}
local function lstart(pid, fresh)
  pid = tonumber(pid)
  if not pid then return nil end
  touched[pid] = true
  if not fresh and start_cache[pid] then return start_cache[pid] end
  local r = rex.exec({ "ps", "-o", "lstart=", "-p", tostring(pid) }, { env = { LC_ALL = "C" } })
  local s = r and r.ok and trim(r.stdout) or nil
  if s == "" then s = nil end
  start_cache[pid] = s
  return s
end

-- Problems stay listed in status for an hour after they were last seen.
local problems = {}
local function problem(block_id, code, detail)
  local key = code .. " " .. (block_id or "")
  if not problems[key] then log("problem", code, block_id or "", detail or "") end
  problems[key] = { code = code, block_id = block_id, detail = detail, last_seen = os.time() }
end

-- Has this Claude chat got a transcript yet? Look in the folder's project
-- directory, and search all projects (at most every 10s per chat) only when
-- that directory doesn't exist. Found transcripts are remembered.
local transcript_seen, transcript_searched = {}, {}
local function has_transcript(chat)
  touched[chat.id] = true
  if transcript_seen[chat.id] then return true end
  local projects = CLAUDE_DIR .. "/projects"
  if chat.cwd then
    local d = projects .. "/" .. core.claude_slug(chat.cwd)
    if read(d .. "/" .. chat.id .. ".jsonl") then
      transcript_seen[chat.id] = true
      return true
    end
    if rex.exec({ "test", "-d", d }).ok then return false end
  end
  if now() - (transcript_searched[chat.id] or 0) < 10 then return false end
  transcript_searched[chat.id] = now()
  local r = rex.exec({ "find", projects, "-maxdepth", "2", "-name", chat.id .. ".jsonl", "-print", "-quit" })
  if r and r.ok and trim(r.stdout) ~= "" then
    transcript_seen[chat.id] = true
    return true
  end
  return false
end

local agent_first_seen = {}
local function find_chat(kind, pid, block_id)
  if kind == "claude" then
    touched[pid] = true
    local path = CLAUDE_DIR .. "/sessions/" .. pid .. ".json"
    local text = read(path)
    local chat, why = core.claude_chat(decode(text), pid)
    if chat then
      -- A chat with no messages can't be resumed, so it isn't saved yet.
      return has_transcript(chat) and chat or nil
    end
    -- Claude writes no file while it asks whether to trust a folder, so a
    -- missing file is only a problem after a while. A file bunk can't read
    -- is one sooner.
    agent_first_seen[pid] = agent_first_seen[pid] or now()
    if now() - agent_first_seen[pid] > (text and 10 or 120) then
      problem(block_id, "claude.sessions", (text and why or "missing") .. ": " .. path)
    end
    return nil
  end
  local r = rex.exec({ "lsof", "-a", "-p", tostring(pid), "-Fn" })
  local chat, why = core.codex_chat_from_lsof(r and r.stdout, CODEX_HOME)
  if why then problem(block_id, "codex.rollout", why) end
  if chat then return chat end
  r = rex.exec({ "ps", "-ww", "-o", "args=", "-p", tostring(pid) })
  return core.codex_chat_from_args(r and r.stdout)
end

local function observe(session_id, block_id)
  local p = rex.block.call(T, "process", { session_id = session_id, block_id = block_id })
  if type(p) ~= "table" or type(p.child) ~= "table" or not p.child.pid then return { ok = false } end
  local child_start = lstart(p.child.pid)
  if not child_start then return { ok = false } end
  local fg = p.foreground
  local o = {
    ok = true, session_id = session_id, block_id = block_id,
    inc = tostring(p.child.pid) .. "@" .. child_start,
    kind = core.classify(fg),
  }
  if not o.kind then return { ok = false } end
  o.fg_cwd = fg.cwd
  o.fg_pid = fg.pid
  -- The pane's own shell sits directly under the terminal's child (login on
  -- macOS), so its ancestor list holds at most that one process.
  o.at_prompt = o.kind == "shell" and #(p.ancestors or {}) <= 1
  o.shell_cwd = fg.cwd
  o.shell_pid = core.pane_shell(p)
  if o.kind == "claude" or o.kind == "codex" then
    o.agent = { pid = fg.pid, start = lstart(fg.pid) }
    o.chat = find_chat(o.kind, fg.pid, block_id)
  end
  return o
end

-- An agent that is a child of the pane's shell without being in front:
-- Ctrl-Z'd, running an editor, or back in front since observe(). Without
-- this, a resumed chat bunk hadn't yet seen in front would be forgotten as
-- "resume did not start" while it ran (verify/restore, finding F2).
local function pane_agent(o, rec)
  if not o.shell_pid then return end
  local r = rex.exec({ "ps", "-A", "-ww", "-o", "pid=", "-o", "ppid=", "-o", "args=" })
  local a = core.child_agent(r and r.ok and r.stdout, o.shell_pid, rec.agent_pid)
  if not a then return end
  o.kind, o.at_prompt = a.kind, false
  o.agent = { pid = a.pid, start = lstart(a.pid) }
  o.chat = find_chat(a.kind, a.pid, o.block_id)
end

-- Just before typing, look again: is the pane's own shell, the one observe()
-- saw, still in front at its prompt? Rex's write has no condition, so this
-- leaves only the time of one call for the user to start something else
-- (verify/restore, finding F1).
local function still_at_prompt(o)
  local p = rex.block.call(T, "process", { session_id = o.session_id, block_id = o.block_id })
  if type(p) ~= "table" or type(p.child) ~= "table" or type(p.foreground) ~= "table" then return false end
  return tostring(p.child.pid) .. "@" .. (lstart(p.child.pid) or "") == o.inc
    and p.foreground.pid == o.fg_pid
    and core.classify(p.foreground) == "shell"
    and #(p.ancestors or {}) <= 1
end

local exit_seen = {}

function step(session_id, block_id)
  local o = observe(session_id, block_id)
  if not o.ok then return false end
  local rec = load(block_id)
  if rec and o.kind ~= "claude" and o.kind ~= "codex" then pane_agent(o, rec) end
  if rec and rec.agent_pid then
    o.agent_alive = rec.agent_start ~= nil and lstart(rec.agent_pid, true) == rec.agent_start
  end
  o.exit_seen = exit_seen[block_id]
  local marked = false
  -- One token check for the whole list: a watcher that stops between
  -- writing "resuming" and typing would leave that resume untyped.
  local actions = core.decide(rec, o, now())
  if #actions > 0 and not guard() then return false end
  for _, a in ipairs(actions) do
    local what = a[1]
    if what == "write" then
      save(block_id, a[2])
      if not rec or rec.chat_id ~= a[2].chat_id or rec.state ~= a[2].state then
        log("save", block_id, a[2].agent, a[2].chat_id, a[2].state)
      end
    elseif what == "delete" then
      remove(block_id)
      log("forget", block_id, rec and rec.chat_id or "", a[2])
    elseif what == "type" then
      if still_at_prompt(o) then
        rex.block.call(T, "write", { session_id = session_id, block_id = block_id, data = a[2] })
        log("resume", block_id, rec.agent, rec.chat_id)
      else
        save(block_id, rec) -- as it was, so a later pass types it
        log("resume", block_id, rec.agent, rec.chat_id, "(deferred: the prompt is busy)")
      end
    elseif what == "mark_exit" then
      marked = true
      exit_seen[block_id] = exit_seen[block_id] or now()
    elseif what == "problem" then
      problem(block_id, a[2], a[3])
    end
  end
  if not marked then exit_seen[block_id] = nil end
  return true
end

function flush()
  flush_scheduled = false
  local batch = pending
  pending = {}
  if guard() then
    for block_id, session_id in pairs(batch) do pcall(step, session_id, block_id) end
  end
  if stopping then rex.stop(0) end
end

local missing = {}

local function saved_blocks()
  local out = {}
  local r = rex.exec({ "ls", PANES })
  for name in ((r and r.stdout) or ""):gmatch("[^\n]+") do
    if name:match("%.json$") then
      local rec = decode(read(PANES .. "/" .. name))
      if rec and rec.block_id then out[#out + 1] = rec end
    end
  end
  return out
end

local function write_status(complete, panes)
  local list = {}
  for key, p in pairs(problems) do
    if now() - p.last_seen > 3600 then problems[key] = nil else list[#list + 1] = p end
  end
  write_atomic(STATE .. "/status.json", rex.json.encode({
    version = core.VERSION, token = token, started_at = started, last_pass = now(),
    period = PERIOD, complete = complete, panes = panes, problems = list,
  }) .. "\n")
end

local function full_pass()
  if not guard() then return end
  local complete, seen, panes = true, {}, 0
  local list = rex.call("session.list")
  if type(list) ~= "table" then
    complete = false
  else
    for _, s in ipairs(list.sessions or {}) do
      local bl = rex.session.list_blocks({ session_id = s.session_id })
      if type(bl) ~= "table" then
        complete = false
      else
        for _, b in ipairs(bl.blocks or {}) do
          seen[b.block_id] = true
          panes = panes + 1
          local ok, done = pcall(step, s.session_id, b.block_id)
          if not ok then
            complete = false
            log("error", b.block_id, tostring(done))
          end
        end
      end
    end
  end
  -- Forget records for panes that are gone. Wait until Rex has had time to
  -- restore sessions, and need two complete passes in a row.
  if complete and now() - started >= GC_AFTER then
    for _, rec in ipairs(saved_blocks()) do
      if seen[rec.block_id] then
        missing[rec.block_id] = nil
      else
        missing[rec.block_id] = (missing[rec.block_id] or 0) + 1
        if missing[rec.block_id] >= 2 then
          remove(rec.block_id)
          missing[rec.block_id] = nil
          log("forget", rec.block_id, rec.chat_id or "", "pane is gone")
        end
      end
    end
  end
  if complete then
    for _, t in ipairs({ start_cache, agent_first_seen, transcript_seen, transcript_searched }) do
      for k in pairs(t) do if not touched[k] then t[k] = nil end end
    end
    for k in pairs(exit_seen) do if not seen[k] then exit_seen[k] = nil end end
    touched = {}
  end
  write_status(complete, panes)
end

local function tick()
  local ok, err = pcall(full_pass)
  if not ok then log("error", "pass", tostring(err)) end
  if stopping then rex.stop(0) end
end
rex.after(0.5, tick)
rex.every(PERIOD, tick)
