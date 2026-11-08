-- Unit tests for lib/momento-rex/core.lua. Run: luajit test/unit.lua
local root = arg[0]:match("^(.*)/test/[^/]*$") or "."
package.path = root .. "/lib/momento-rex/?.lua;" .. package.path
local core = require("core")

local pass, fail = 0, 0
local function check(name, cond, detail)
  if cond then pass = pass + 1 else fail = fail + 1; print("FAIL " .. name .. (detail and (": " .. tostring(detail)) or "")) end
end
local function acts(list)
  local t = {}
  for _, a in ipairs(list) do t[#t + 1] = a[1] end
  return table.concat(t, ",")
end

local ID = "94681d99-5e6c-4737-b1e6-d26e53da1ad8"
local ID2 = "7bc34ce9-9740-412b-a465-2fc460220181"

-- classify: match argv0/paths, never the name (Claude puts its version there)
check("claude by argv0", core.classify({ name = "2.1.319", argv0 = "claude", path = "/x/versions/2.1.319" }) == "claude")
check("codex by abs argv0", core.classify({ name = "codex", argv0 = "/Users/a/.local/bin/codex" }) == "codex")
check("login shell", core.classify({ name = "zsh", argv0 = "-zsh", path = "/bin/zsh" }) == "shell")
check("other", core.classify({ name = "vim", argv0 = "vim", path = "/usr/bin/vim" }) == "other")
check("nil fg", core.classify(nil) == nil)
check("claude-ish is not claude", core.classify({ argv0 = "claude-monitor", path = "/x/claude-monitor" }) == "other")

-- resume_line
local rec = { agent = "claude", chat_id = ID, cwd = "/Users/a/src" }
check("same cwd: no cd", core.resume_line(rec, "/Users/a/src") == "\21claude --resume " .. ID .. "\r")
check("other cwd: cd", core.resume_line(rec, "/tmp") == "\21cd -- '/Users/a/src' && claude --resume " .. ID .. "\r")
check("codex", core.resume_line({ agent = "codex", chat_id = ID, cwd = "/a" }, "/a") == "\21codex resume " .. ID .. "\r")
check("quote", core.resume_line({ agent = "claude", chat_id = ID, cwd = "/a'b $(x) ;y" }, "/") ==
  "\21cd -- '/a'\\''b $(x) ;y' && claude --resume " .. ID .. "\r")
for _, cwd in ipairs({ "/a\nrm -rf ~", "/a\rb", "/a\27[2J", "relative", "", "/a\0b" }) do
  check("reject cwd " .. ("%q"):format(cwd), core.resume_line({ agent = "claude", chat_id = ID, cwd = cwd }, "/") == nil)
end
for _, id in ipairs({ "$(id)", ID .. "x", ID .. "; rm", "x" .. ID, "not-a-uuid", "" }) do
  check("reject id " .. id, core.resume_line({ agent = "claude", chat_id = id, cwd = "/a" }, "/a") == nil)
end
check("reject agent", core.resume_line({ agent = "sh", chat_id = ID, cwd = "/a" }, "/a") == nil)

-- quoting round-trips through /bin/sh for random bytes
math.randomseed(42)
local ok_rt = true
for _ = 1, 200 do
  local t = { "/" }
  for _ = 1, math.random(1, 12) do t[#t + 1] = string.char(math.random(32, 126)) end
  local s = table.concat(t)
  local h = io.popen("/bin/sh -c 'printf %s " .. core.quote(s):gsub("'", "'\\''") .. "'")
  local out = h:read("*a"); h:close()
  if out ~= s then ok_rt = false; print("  quote mismatch: " .. s .. " -> " .. out) break end
end
check("quote round-trips through sh", ok_rt)

-- pane_shell: the shell under login (macOS), or the child when it is the shell
local login = { pid = 10, name = "login", path = "/usr/bin/login" }
check("shell at prompt", core.pane_shell({ child = login, foreground = { pid = 11, argv0 = "-zsh" }, ancestors = { login } }) == 11)
check("vim under shell", core.pane_shell({ child = login, foreground = { pid = 12, argv0 = "vim" },
  ancestors = { { pid = 11 }, login } }) == 11)
check("editor under claude", core.pane_shell({ child = login, foreground = { pid = 13, argv0 = "vim" },
  ancestors = { { pid = 12 }, { pid = 11 }, login } }) == 11)
check("child is the shell", core.pane_shell({ child = { pid = 20, path = "/bin/bash" }, foreground = { pid = 21 } }) == 20)
check("no ancestors: unknown", core.pane_shell({ child = login, foreground = { pid = 12, argv0 = "vim" } }) == nil)

-- child_agent: agents among the shell's children, from ps
local PS = "  1     0 /sbin/launchd\n 30    11 vim notes\n 31    11 claude --resume x\n 32    11 codex resume y\n 33    99 claude\n"
check("child agent", (core.child_agent(PS, 11) or {}).pid == 31)
check("child agent prefers the recorded pid", (core.child_agent(PS, 11, 32) or {}).kind == "codex")
check("other shells' agents don't count", core.child_agent(" 33    99 claude\n", 11) == nil)
check("no ps output", core.child_agent(nil, 11) == nil)

-- parsers
check("claude file ok", (core.claude_chat({ pid = 5, sessionId = ID, kind = "interactive", cwd = "/a" }, 5) or {}).id == ID)
check("claude pid mismatch", core.claude_chat({ pid = 6, sessionId = ID, kind = "interactive" }, 5) == nil)
check("claude not interactive", core.claude_chat({ pid = 5, sessionId = ID, kind = "print" }, 5) == nil)
check("claude renamed key", core.claude_chat({ pid = 5, session_id = ID }, 5) == nil)
local H = "/Users/a/.codex"
local lsof = "p1\nfcwd\nn/Users/a/src\nn" .. H .. "/state_5.sqlite\nn" .. H ..
  "/sessions/2026/11/08/rollout-2026-11-08T08-23-35-" .. ID .. ".jsonl\nn" .. H ..
  "/sessions/2026/11/08/rollout-2026-11-08T09-00-00-" .. ID2 .. ".jsonl\n"
check("codex newest rollout", (core.codex_chat_from_lsof(lsof, H) or {}).id == ID2)
check("codex nothing open", core.codex_chat_from_lsof("p1\nn/tmp/x\n", H) == nil)
local c, why = core.codex_chat_from_lsof("n" .. H .. "/sessions/2026/11/08/thread-" .. ID .. ".jsonl\n", H)
check("codex renamed file is a problem", c == nil and why ~= nil)
check("codex resume argv", (core.codex_chat_from_args("/x/codex --profile macos resume " .. ID) or {}).id == ID)
check("codex argv junk", core.codex_chat_from_args("codex resume $(id)") == nil)

-- decide
local INC, INC2 = "100@Sun Nov  8 08:00:00 2026", "200@Sun Nov  8 09:00:00 2026"
local function obs(t)
  local o = { ok = true, inc = INC, session_id = "s", block_id = "b" }
  for k, v in pairs(t) do o[k] = v end
  return o
end
local live = { v = 1, agent = "claude", chat_id = ID, cwd = "/a", inc = INC, agent_pid = 7, agent_start = "t7",
  session_id = "s", block_id = "b", state = "live" }

local a = core.decide(nil, obs({ kind = "claude", agent = { pid = 7, start = "t7" }, chat = { id = ID, cwd = "/a" } }), 0)
check("save new chat", acts(a) == "write" and a[1][2].chat_id == ID and a[1][2].inc == INC)
check("no rewrite when unchanged", acts(core.decide(live,
  obs({ kind = "claude", agent = { pid = 7, start = "t7" }, chat = { id = ID, cwd = "/a" } }), 0)) == "")
a = core.decide(live, obs({ kind = "claude", agent = { pid = 7, start = "t7" }, chat = { id = ID2, cwd = "/a" } }), 0)
check("/clear updates id", acts(a) == "write" and a[1][2].chat_id == ID2)
check("codex before first message saves nothing",
  acts(core.decide(nil, obs({ kind = "codex", agent = { pid = 8, start = "t8" } }), 0)) == "")
local lc = { agent = "codex", chat_id = ID, cwd = "/a", inc = INC, agent_pid = 8, agent_start = "t8", state = "live" }
check("codex /new keeps last id", acts(core.decide(lc, obs({ kind = "codex", agent = { pid = 8, start = "t8" }, fg_cwd = "/a" }), 0)) ~= "delete")

check("ctrl-z keeps", acts(core.decide(live, obs({ kind = "shell", at_prompt = true, agent_alive = true }), 0)) == "")
check("vim inside claude keeps", acts(core.decide(live, obs({ kind = "other", agent_alive = true }), 0)) == "")
check("exit marks first", acts(core.decide(live, obs({ kind = "shell", at_prompt = true, agent_alive = false }), 10)) == "mark_exit")
check("exit not yet confirmed", acts(core.decide(live, obs({ kind = "shell", at_prompt = true, exit_seen = 9 }), 10)) == "mark_exit")
check("exit confirmed deletes", acts(core.decide(live, obs({ kind = "shell", at_prompt = true, exit_seen = 7 }), 10)) == "delete")

a = core.decide(live, obs({ inc = INC2, kind = "shell", at_prompt = true, shell_cwd = "/a" }), 50)
check("restored pane resumes", acts(a) == "write,type" and a[1][2].state == "resuming" and a[1][2].inc == INC2
  and a[2][2] == "\21claude --resume " .. ID .. "\r")
check("restored pane, nested shell waits", acts(core.decide(live, obs({ inc = INC2, kind = "shell", at_prompt = false }), 50)) == "")
check("restored pane, vim waits", acts(core.decide(live, obs({ inc = INC2, kind = "other" }), 50)) == "")
check("restored pane, user started claude", acts(core.decide(live,
  obs({ inc = INC2, kind = "claude", agent = { pid = 9, start = "t9" }, chat = { id = ID2 } }), 50)) == "write")
local bad = {}
for k, v in pairs(live) do bad[k] = v end
bad.cwd = "/a\nrm -rf ~"
check("unsafe record refused", acts(core.decide(bad, obs({ inc = INC2, kind = "shell", at_prompt = true, shell_cwd = "/" }), 50)) == "problem,delete")

local resuming = {}
for k, v in pairs(live) do resuming[k] = v end
resuming.inc, resuming.state, resuming.resumed_at = INC2, "resuming", 50
check("resuming: typed only once", acts(core.decide(resuming, obs({ inc = INC2, kind = "shell", at_prompt = true }), 52)) == "")
check("resuming: agent came up", acts(core.decide(resuming,
  obs({ inc = INC2, kind = "claude", agent = { pid = 9, start = "t9" }, chat = { id = ID } }), 53)) == "write")
check("resuming: never started, marks", acts(core.decide(resuming, obs({ inc = INC2, kind = "shell", at_prompt = true }), 70)) == "mark_exit")
local d = core.decide(resuming, obs({ inc = INC2, kind = "shell", at_prompt = true, exit_seen = 66 }), 70)
check("resuming: never started, deletes", acts(d) == "delete" and d[1][2] == "resume did not start")
check("process call failed: nothing", acts(core.decide(live, { ok = false }, 0)) == "")
check("no record, shell: nothing", acts(core.decide(nil, obs({ kind = "shell", at_prompt = true }), 0)) == "")

print(("%d passed, %d failed"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
