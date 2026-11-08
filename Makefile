.PHONY: test lint unit worktree e2e

# Every tracked file with a sh or bash shebang, including extensionless ones.
SH_FILES = $(shell git ls-files -z | xargs -0 grep -lE '^\#!/bin/(ba)?sh')
# luacheck breaks under Lua 5.5, so it's installed for LuaJIT (see README).
LUACHECK ?= $(shell command -v luacheck || echo $(HOME)/.luarocks/bin/luacheck)

test: lint unit worktree e2e

lint:
	shellcheck $(SH_FILES)
	$(LUACHECK) -q lib test verify

unit:
	luajit test/unit.lua

worktree:
	bash test/worktree.sh

e2e:
	bash test/e2e.sh
