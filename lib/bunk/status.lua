-- bunk status: rex --autostart=false do status.lua state_dir=DIR config=FILE
-- Prints the watcher's health, saved chats, and problems. Exits 1 when
-- anything needs attention.

local dir = debug.getinfo(1, "S").source:gsub("^@", ""):match("^(.*)/[^/]*$")
package.path = dir .. "/?.lua;" .. package.path
local core = require("core")

local args = rex.args or {}
local STATE = args.state_dir
local HOME = os.getenv("HOME") or ""

local function read(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

local function decode(s)
  if not s or s == "" then return nil end
  local ok, v = pcall(rex.json.decode, s)
  return ok and v or nil
end

local function short(p)
  if type(p) ~= "string" then return "?" end
  if p:sub(1, #HOME + 1) == HOME .. "/" then return "~" .. p:sub(#HOME + 1) end
  return p
end

local bad = {}
local function say(...) print(table.concat({ ... }, "")) end

local st = decode(read(STATE .. "/status.json"))
local token = (read(STATE .. "/watcher.token") or ""):gsub("%s+", "")
if not st then
  say("watcher   not running (no status yet in ", short(STATE), ")")
  bad[#bad + 1] = "start the watcher: bunk start"
elseif token ~= st.token then
  say("watcher   stopped (token changed: ", token == "uninstalled" and "uninstalled" or "a newer watcher has not written status yet", ")")
  bad[#bad + 1] = "watcher not running"
else
  local age = os.time() - (st.last_pass or 0)
  local limit = 3 * (st.period or 3) + 5
  say("watcher   ", age <= limit and "running" or "STALE", ", v", st.version or "?",
    ", last pass ", age, "s ago", st.complete == false and " (incomplete)" or "")
  if age > limit then bad[#bad + 1] = "watcher has not run a pass in " .. age .. "s: bunk start" end
  if st.version ~= core.VERSION then
    bad[#bad + 1] = "watcher is v" .. tostring(st.version) .. ", bunk is v" .. core.VERSION .. ": bunk start"
  end
end

local cfg = args.config
local text = cfg and read(cfg) or ""
if text:find("-- bunk:managed", 1, true) then
  say("init.lua  set up (", short(cfg), ")")
else
  say("init.lua  NOT set up (", short(cfg), ")")
  bad[#bad + 1] = "run: bunk install"
end

local r = rex.exec({ "ls", STATE .. "/panes" })
local any = false
for name in ((r and r.stdout) or ""):gmatch("[^\n]+") do
  if name:match("%.json$") then
    local rec = decode(read(STATE .. "/panes/" .. name))
    if rec then
      if not any then say("chats") end
      any = true
      say("  ", (rec.block_id or "?"):sub(-8), "  ", rec.agent or "?", "  ",
        (rec.chat_id or "?"):sub(1, 8), "  ", rec.state or "?", "  ", short(rec.cwd))
    end
  end
end
if not any then say("chats     none saved") end

for _, p in ipairs((st and st.problems) or {}) do
  bad[#bad + 1] = p.code .. " in " .. (p.block_id or "?"):sub(-8) .. ": " .. (p.detail or "")
end

if #bad > 0 then
  say("problems")
  for _, b in ipairs(bad) do say("  ", b) end
  say("log       ", short(STATE .. "/bunk.log"))
  rex.stop(1)
end
