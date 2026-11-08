-- momento-rex core: pure decisions and parsers. No rex, io, or os calls, so it runs
-- under plain luajit in test/unit.lua as well as inside `rex do`.

local M = {}

M.VERSION = "0.1.0"
M.RESUME_GRACE = 15 -- seconds a typed resume gets to bring its agent up
M.EXIT_CONFIRM = 2  -- seconds an exit must stay true before the record goes

local UUID = "^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$"

function M.is_uuid(s)
  return type(s) == "string" and s:match(UUID) ~= nil
end

local SHELLS = { zsh = true, bash = true, fish = true, sh = true, dash = true, ksh = true }
local AGENTS = { claude = true, codex = true }

local function basename(p)
  if type(p) ~= "string" or p == "" then return nil end
  local b = p:gsub("/+$", ""):match("([^/]+)$")
  if not b then return nil end
  return (b:gsub("^%-", "")) -- login shells show up as "-zsh"
end

-- "claude", "codex", "shell", or "other" for a foreground process table from
-- the terminal's `process` call. Claude reports its version in `name`, so
-- only argv0 and the paths count.
function M.classify(fg)
  if type(fg) ~= "table" then return nil end
  for _, f in ipairs({ fg.argv0, fg.invoked_path, fg.path }) do
    local b = basename(f)
    if b and AGENTS[b] then return b end
  end
  local b = basename(fg.argv0) or basename(fg.path)
  if b and SHELLS[b] then return "shell" end
  return "other"
end

-- The pid of the pane's own shell, from the terminal's `process` result: the
-- child itself when it is a shell, or else the process directly under the
-- child (login on macOS). nil when Rex left the ancestor list out.
function M.pane_shell(p)
  if type(p) ~= "table" or type(p.child) ~= "table" then return nil end
  if M.classify(p.child) == "shell" then return p.child.pid end
  local fg, anc = p.foreground, p.ancestors or {}
  if type(fg) ~= "table" or fg.pid == p.child.pid or #anc == 0 then return nil end
  if #anc == 1 then return fg.pid end -- the list ends with the child
  return type(anc[#anc - 1]) == "table" and anc[#anc - 1].pid or nil
end

-- An agent among the children of shell_pid in `ps -A -o pid= -o ppid= -o args=`
-- output, as {pid, kind}. The one with prefer_pid wins; otherwise the first.
function M.child_agent(text, shell_pid, prefer_pid)
  shell_pid, prefer_pid = tonumber(shell_pid), tonumber(prefer_pid)
  local found
  for line in (text or ""):gmatch("[^\n]+") do
    local pid, ppid, args = line:match("^%s*(%d+)%s+(%d+)%s+(.*)$")
    if pid and tonumber(ppid) == shell_pid then
      local kind = M.classify({ argv0 = args:match("^(%S+)") })
      if kind == "claude" or kind == "codex" then
        local a = { pid = tonumber(pid), kind = kind }
        if a.pid == prefer_pid then return a end
        found = found or a
      end
    end
  end
  return found
end

function M.valid_cwd(s)
  if type(s) ~= "string" or s:sub(1, 1) ~= "/" or #s > 1024 then return false end
  return not s:find("[%z\1-\31\127]")
end

function M.quote(s)
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

-- The exact bytes to type into a restored shell, or nil and a reason.
-- Built from a validated record at the moment of typing; never stored.
function M.resume_line(rec, shell_cwd)
  if type(rec) ~= "table" or not AGENTS[rec.agent] then return nil, "unknown agent" end
  if not M.is_uuid(rec.chat_id) then return nil, "chat id is not a UUID" end
  if not M.valid_cwd(rec.cwd) then return nil, "folder is not a plain absolute path" end
  local cmd = rec.agent == "claude" and ("claude --resume " .. rec.chat_id)
    or ("codex resume " .. rec.chat_id)
  if rec.cwd ~= shell_cwd then cmd = "cd -- " .. M.quote(rec.cwd) .. " && " .. cmd end
  if cmd:find("[%z\1-\31\127]") then return nil, "control character in command" end
  -- Ctrl-U first clears anything already on the prompt line.
  return "\21" .. cmd .. "\r"
end

-- Claude's ~/.claude/sessions/<pid>.json, already decoded.
function M.claude_chat(t, pid)
  if type(t) ~= "table" then return nil, "unreadable" end
  if tonumber(t.pid) ~= tonumber(pid) then return nil, "pid does not match" end
  if t.kind ~= nil and t.kind ~= "interactive" then return nil, "not interactive" end
  if not M.is_uuid(t.sessionId) then return nil, "sessionId missing or not a UUID" end
  return { id = t.sessionId, cwd = M.valid_cwd(t.cwd) and t.cwd or nil }
end

-- `lsof -Fn` output for a Codex process. Returns {id = ...} for the newest
-- open rollout, nil when none is open, and a problem string when a .jsonl
-- under sessions/ is open but isn't named the way momento-rex expects.
function M.codex_chat_from_lsof(text, codex_home)
  local prefix = codex_home .. "/sessions/"
  local best, bestname, odd
  for line in (text or ""):gmatch("[^\n]+") do
    local path = line:match("^n(.+)$")
    if path and path:sub(1, #prefix) == prefix and path:match("%.jsonl$") then
      local name = path:match("([^/]+)$")
      local id = name:match("^rollout%-.+%-(%x+%-%x+%-%x+%-%x+%-%x+)%.jsonl$")
      if id and M.is_uuid(id) then
        if not bestname or name > bestname then best, bestname = id, name end
      else
        odd = path
      end
    end
  end
  if best then return { id = best } end
  if odd then return nil, "open Codex file has an unexpected name: " .. odd end
  return nil
end

-- `ps -o args=` for a Codex process: `codex resume <id>` before its first message.
function M.codex_chat_from_args(args)
  local id = (args or ""):match("%sresume%s+(%S+)")
  if M.is_uuid(id) then return { id = id } end
  return nil
end

local FIELDS = { "agent", "chat_id", "cwd", "inc", "agent_pid", "agent_start", "session_id", "state" }

local function same(a, b)
  if not a or not b then return false end
  for _, k in ipairs(FIELDS) do
    if a[k] ~= b[k] then return false end
  end
  return true
end

local function copy(t)
  local c = {}
  for k, v in pairs(t) do c[k] = v end
  return c
end

-- decide(rec, o, now) -> list of actions. `rec` is the pane's saved record or
-- nil. `o` is a fresh observation of the pane:
--   ok          the process call worked
--   inc         "<child pid>@<child start>": changes when Rex gives the pane a new shell
--   kind        classify(foreground)
--   at_prompt   the foreground is the pane's own shell (not a nested one)
--   shell_cwd   the shell's cwd when at_prompt
--   agent       {pid, start} of the foreground agent
--   chat        {id, cwd} found for that agent, or nil
--   agent_alive the record's agent pid still runs with the same start time
--   exit_seen   when this pane first looked exited (watcher memory), or nil
-- Actions: {"write", rec}, {"delete", why}, {"type", bytes}, {"mark_exit"},
-- {"problem", code, detail}.
function M.decide(rec, o, now)
  if not o or not o.ok then return {} end

  if o.kind == "claude" or o.kind == "codex" then
    local id = o.chat and o.chat.id
    -- Keep what we knew if the lookup comes up empty for the same process
    -- (Codex after /new, before the first message).
    if not id and rec and rec.agent == o.kind and rec.agent_pid == o.agent.pid then id = rec.chat_id end
    if not id then return {} end
    local want = {
      v = 1, agent = o.kind, chat_id = id,
      cwd = (o.chat and o.chat.cwd) or (M.valid_cwd(o.fg_cwd) and o.fg_cwd) or (rec and rec.cwd),
      inc = o.inc, agent_pid = o.agent.pid, agent_start = o.agent.start,
      session_id = o.session_id, block_id = o.block_id, state = "live",
    }
    if same(rec, want) then return {} end
    return { { "write", want } }
  end

  if not rec then return {} end

  if rec.inc ~= o.inc then
    -- A new shell: Rex restored this pane. Only type into the pane's own
    -- shell prompt, never into vim or a nested shell.
    if not o.at_prompt then return {} end
    local line, why = M.resume_line(rec, o.shell_cwd)
    if not line then
      return { { "problem", "resume.unsafe", why }, { "delete", "unsafe record: " .. why } }
    end
    local r2 = copy(rec)
    r2.inc, r2.state, r2.resumed_at = o.inc, "resuming", now
    return { { "write", r2 }, { "type", line } } -- written first: one attempt per shell
  end

  if rec.state == "resuming" and now - (rec.resumed_at or 0) < M.RESUME_GRACE then return {} end
  if o.agent_alive then return {} end -- Ctrl-Z, or the agent is running something like vim
  if o.exit_seen and now - o.exit_seen >= M.EXIT_CONFIRM then
    return { { "delete", rec.state == "resuming" and "resume did not start" or "agent exited" } }
  end
  return { { "mark_exit" } }
end

return M
