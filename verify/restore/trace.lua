-- Turn a TLC error trace into one line per step: the action, then only the
-- variables that step changed. Run: luajit trace.lua < tlc-output
-- Watcher bookkeeping that only restates the action name is left out.
local SKIP = { wObs = true, wPc = true, wGuarded = true, wMarked = true }
local states, cur, var = {}, nil, nil
for line in io.lines() do
  local n, act = line:match("^State (%d+): <(%S+)")
  if n then
    cur = { act = act, vars = {}, order = {} }
    states[#states + 1] = cur
    var = nil
  elseif cur then
    local name, val = line:match("^/\\ (%S+) = (.*)$")
    if name then
      var = name
      cur.vars[name] = val
      cur.order[#cur.order + 1] = name
    elseif var and line:match("^%s+%S") then
      cur.vars[var] = cur.vars[var] .. " " .. line:gsub("^%s+", "")
    elseif line == "" then
      var = nil
    end
  end
  local inv = line:match("^Error: Invariant (%S+) is violated")
  if inv then io.write("violated: ", inv, "\n") end
end
for i, s in ipairs(states) do
  local prev = states[i - 1]
  local diff = {}
  for _, k in ipairs(s.order) do
    if not SKIP[k] and (not prev or prev.vars[k] ~= s.vars[k]) then
      if prev or k == "rec" then diff[#diff + 1] = k .. "=" .. s.vars[k] end
    end
  end
  io.write(("%2d %-14s %s\n"):format(i, s.act, table.concat(diff, "  ")))
end
