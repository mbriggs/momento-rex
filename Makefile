.PHONY: test unit worktree e2e

test: unit worktree e2e

unit:
	luajit test/unit.lua

worktree:
	bash test/worktree.sh

e2e:
	bash test/e2e.sh
