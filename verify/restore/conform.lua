-- Runs the real core.decide on every input in the model's Decide table and
-- compares. Run: luajit conform.lua REPO_ROOT < table   (check does this)
-- Each table line: rec | observation | now | agent_alive | exit_seen | actions
local root = assert(arg[1], "usage: luajit conform.lua REPO_ROOT < table")
package.path = root .. "/lib/momento-rex/?.lua;" .. package.path
local core = require("core")

local UUID = { "94681d99-5e6c-4737-b1e6-d26e53da1ad8", "7bc34ce9-9740-412b-a465-2fc460220181" }
local CHAT = { [UUID[1]] = "1", [UUID[2]] = "2" }
local CWD = "/w"

local function split(s, sep)
  local t = {}
  for part in (s .. sep):gmatch("(.-)" .. sep:gsub("%p", "%%%0")) do t[#t + 1] = part end
  return t
end

-- Model record -> the JSON record watch.lua saves.
local function to_rec(f)
  if f[1] == "none" then return nil end
  return {
    v = 1, agent = "claude", chat_id = UUID[tonumber(f[2])], cwd = CWD,
    inc = "inc" .. f[3], agent_pid = tonumber(f[4]), agent_start = "start" .. f[4],
    session_id = "S", block_id = "B", state = f[1],
    resumed_at = f[1] == "resuming" and tonumber(f[5]) or nil,
  }
end

-- Model observation -> watch.lua's `o`.
local function to_obs(f, alive, es)
  local kind = ({ agent = "claude", shell = "shell", other = "other" })[f[1]]
  local pid, chat = tonumber(f[4]), tonumber(f[5])
  return {
    ok = true, session_id = "S", block_id = "B", inc = "inc" .. f[3], kind = kind,
    at_prompt = f[2] == "TRUE", shell_cwd = CWD, fg_cwd = CWD,
    agent = kind == "claude" and { pid = pid, start = "start" .. pid } or nil,
    chat = chat ~= 0 and { id = UUID[chat], cwd = CWD } or nil,
    agent_alive = alive, exit_seen = es,
  }
end

-- Real actions -> the model's action string.
local function rec_str(r)
  return table.concat({ r.state, CHAT[r.chat_id] or "?", (r.inc or ""):match("^inc(%d+)$") or "?",
    tostring(r.agent_pid), tostring(r.resumed_at or 0) }, ",")
end
local function acts_str(list, rec)
  local out = {}
  for _, a in ipairs(list) do
    if a[1] == "write" then
      out[#out + 1] = "write:" .. rec_str(a[2]) .. ";"
    elseif a[1] == "type" then
      local want = core.resume_line(rec, CWD)
      if a[2] ~= want then out[#out + 1] = "type-bytes-differ;" end
      out[#out + 1] = "type:" .. (CHAT[a[2]:match("resume (%S+)\r$") or ""] or "?") .. ";"
    elseif a[1] == "mark_exit" then
      out[#out + 1] = "mark;"
    else
      out[#out + 1] = a[1] .. ";"
    end
  end
  return table.concat(out)
end

local rows, bad = 0, 0
for line in io.lines() do
  local body = line:match('^"row (.*)"$')
  if body then
    rows = rows + 1
    local p = split(body, "|")
    local rec = to_rec(split(p[1], ","))
    local alive, es = p[4] == "TRUE", tonumber(p[5])
    local o = to_obs(split(p[2], ","), alive, es ~= 0 and es or nil)
    local got = acts_str(core.decide(rec, o, tonumber(p[3])), rec)
    if got ~= p[6] then
      bad = bad + 1
      if bad <= 10 then
        print(("differs: rec=%s obs=%s now=%s alive=%s exit_seen=%s\n  model: %s\n  code:  %s")
          :format(p[1], p[2], p[3], p[4], p[5], p[6] == "" and "(nothing)" or p[6], got == "" and "(nothing)" or got))
      end
    end
  end
end
if rows == 0 then print("no table rows read") os.exit(2) end
if bad > 0 then print(("core.decide differs from the model on %d of %d inputs"):format(bad, rows)) os.exit(1) end
print(("core.decide matches the model on all %d inputs"):format(rows))
