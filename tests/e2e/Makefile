# Agent-drive end-to-end suite (pytest) in a self-contained Nix shell, so it
# needs nothing pre-installed. See README.md, and `make test-e2e` at the repo
# top level.
#
#   make                            everything (live tests skip without a guest)
#   make ARGS='-m "not emulator"'   OFFLINE only -- fast, no emulator/display
#   make ARGS='-m emulator'         LIVE only
#
# Point it at a guest via the environment (passed straight through to pytest):
#   # attach to a running emulator (does not disturb it):
#   RPCEMU_HOSTCMD_SOCKET=$PWD/installs/<name>/hostcmd.sock \
#   RPCEMU_HOSTFS_DIR=$PWD/installs/<name>/hostfs   make -C tests/e2e
#   # or boot one for the session (needs a display; hostcmd,ffa in poduleroms/):
#   RPCEMU_TEST_INSTALL=$PWD/installs/<name>        make -C tests/e2e
#
# The live tier needs the INTEGRATION tree (HostCmd client src/tools/rpcemu-run
# + MCP server tools/mcp/) and a built rpcemu-interpreter: make rebuild && make -C src/tools

ARGS ?=

.PHONY: check
check:
	@nix-shell -p 'python3.withPackages(ps: [ps.pytest ps.mcp])' \
	  --run 'pytest "$(CURDIR)" $(ARGS)'

.DEFAULT_GOAL := check
