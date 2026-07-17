# Agent-drive end-to-end tests

A pytest suite that exercises the **HostCmd** + **MCP** agent-drive stack against a
real RISC OS guest — and, through it, RPCEmu itself. Because HostCmd lets the host
run arbitrary guest commands, these tests double as a way to **regression-test
emulator behaviour**: a guest command that reports disc geometry covers
`feature/ide-real-geometry`, one that reports VRAM covers `feature/vram-honesty`,
and so on. Adding coverage for a new feature is usually just a few more lines here.

## Tiers

| Tier | Needs | Marker | Run headless? |
| --- | --- | --- | --- |
| **offline** | nothing (temp HostFS dir) | *(none)* | yes |
| **live** | a booted, HostCmd-capable guest | `@pytest.mark.emulator` | no (display for boot mode) |

Live tests **auto-skip** when no guest is available, so `-m "not emulator"` is a
fast, dependency-light run.

## Prerequisites

The suite runs against the **integration tree** (it needs both the HostCmd client
and the MCP server, which only coexist there). Build them first:

```bash
direnv exec ~/Projects/rpcemu make rebuild     # the emulator
direnv exec ~/Projects/rpcemu make -C src/tools # the rpcemu-run client
```

`pytest` + `mcp` are provided on the fly by the Makefile (a Nix shell) —
nothing to install.

## Running

```bash
# offline only — fast, no emulator, no display
make -C tests/e2e ARGS='-m "not emulator"'      # or, top level:  make test-e2e

# full suite, attaching to an already-running emulator (does not disturb it):
RPCEMU_HOSTCMD_SOCKET=$PWD/installs/riscos-371/hostcmd.sock \
RPCEMU_HOSTFS_DIR=$PWD/installs/riscos-371/hostfs \
make -C tests/e2e

# full suite, booting an emulator for the session (needs a display; the install
# must have hostcmd,ffa in its poduleroms/):
RPCEMU_TEST_INSTALL=$PWD/installs/riscos-371 make -C tests/e2e
```

## Configuration (environment)

| Variable | Meaning |
| --- | --- |
| `RPCEMU_HOSTCMD_SOCKET` | Attach to this HostCmd socket (attach mode). |
| `RPCEMU_HOSTFS_DIR` | The guest's HostFS directory (required with attach mode). |
| `RPCEMU_TEST_INSTALL` | Boot this install for the session (boot mode). |
| `RPCEMU_RUN` | rpcemu-run client binary (default `src/tools/rpcemu-run`). |
| `RPCEMU_MCP` | MCP server module (default `tools/mcp/rpcemu_mcp.py`). |
| `RPCEMU` | Emulator binary, boot mode (default `./rpcemu-interpreter`). |
| `RPCEMU_BOOT_TIMEOUT` | Seconds to wait for the socket in boot mode (default 90). |

## What's covered

- **HostCmd** (`test_hostcmd.py`): guest command runs + streamed output + rc 0;
  error command → non-zero rc + captured message; RISC OS session (CSD) persists
  across separate connections; the client's over-long-host guard; `--help`.
- **MCP** (`test_mcp.py`): all 18 tools register; HostFS file tools round-trip
  (with `,xxx` filetype suffixes); path-escape guard; `riscos_run` errors cleanly
  with no socket; and the live **host↔guest file loop** (MCP writes → guest reads
  via `riscos_run` → MCP reads back → lists).

## Adding coverage

To assert on some emulator behaviour, add a `@pytest.mark.emulator` test that runs
a guest command reporting it and asserts on the output, e.g.:

```python
@pytest.mark.emulator
def test_something(guest):
    rc, out = guest.run("SomeStarCommand")
    assert rc == 0
    assert "expected" in out
```
