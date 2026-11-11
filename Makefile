.PHONY: test lint unit worktree e2e

# luacheck breaks under Lua 5.5, so it's installed for LuaJIT (see README).
LUACHECK ?= $(shell command -v luacheck || echo $(HOME)/.luarocks/bin/luacheck)

test: lint unit worktree e2e

# Every tracked file with a sh or bash shebang, including extensionless ones.
# The names go NUL-separated straight to shellcheck, never through the shell's
# parser, so a file named `x;cmd;#` stays a file name. The lane file has no
# shebang, so it is named here.
lint:
	git ls-files -z | xargs -0 grep -l --null -E '^#!/bin/(ba)?sh' | xargs -0 shellcheck
	shellcheck -s sh bin/worktree.lane
	$(LUACHECK) -q lib test verify

unit:
	luajit test/unit.lua

worktree:
	bash test/worktree.sh

e2e:
	bash test/e2e.sh
