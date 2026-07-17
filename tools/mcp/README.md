# RPCEmu MCP server

An [MCP](https://modelcontextprotocol.io) server that lets an MCP client
(Claude Code, Claude Desktop, the API's MCP connector, …) drive a RISC OS
machine running under RPCEmu — run commands, edit/build/read files, and see and
click the screen. It turns the emulator into an agent-drivable RISC OS
development target ("edit on the host, build on the guest, read the result").

It is a thin adapter over interfaces RPCEmu exposes:

| Interface | Used for |
| --- | --- |
| **HostCmd** socket (see [../../docs/hostcmd.md](../../docs/hostcmd.md)) | running guest CLI commands, capturing output + return code |
| **HostFS** directory (host filesystem) | reading/writing/listing files on the machine's HostFS drive |
| **VNC** server | screen capture and keyboard/mouse input |
| **DebugCmd** socket (*not yet available in this fork* — pending `feature/spork-debugcmd-inspect`) | inspecting and controlling the emulated ARM CPU (registers, memory, disassembly, breakpoints, watchpoints, single-step) |

## Tools

| Tool | What it does |
| --- | --- |
| `riscos_run(command, timeout_s=30)` | Run a RISC OS CLI command; returns `{return_code, output, notices}`. The RISC OS session (current dir, system variables) persists across calls. |
| `riscos_write_file(path, content, filetype="fff")` | Write a text file onto the HostFS drive (`,xxx` filetype suffix). |
| `riscos_read_file(path)` | Read a file from the HostFS drive. |
| `riscos_list(path=".")` | List a HostFS directory. |
| `riscos_screenshot()` | Capture the screen as a PNG (so the model can *see* the display). |
| `riscos_send_text(text)` | Type a string + Return at the keyboard. |
| `riscos_send_key(keysym)` | Press one key by X11 keysym (Return=0xFF0D, Escape=0xFF1B, …). |
| `riscos_click(x, y)` | Left-click at a screen pixel coordinate. |

### Debugger tools (control the *emulated CPU*, not a RISC OS debugger)

> **Not yet available in this fork.** The `riscos_debug_*` tools need the
> **DebugCmd** socket, which this fork has not harvested yet (it's the pending
> `feature/spork-debugcmd-inspect` branch). Until then `RPCEMU_DEBUG_SOCKET` has
> nothing to connect to and these tools just return an error; the other tools
> work regardless.

| Tool | What it does |
| --- | --- |
| `riscos_debug_registers()` | Read the ARM registers (r0–r15, pc, cpsr, mode, decoded flags). |
| `riscos_debug_status()` | Paused state + reason, halt/last PC, watchpoint hit, breakpoint & watchpoint lists. |
| `riscos_debug_read_memory(address, length=64, physical=False)` | Side-effect-free memory read (virtual by default; hex `data`). |
| `riscos_debug_disassemble(address, count=16, physical=False)` | Disassemble ARM instructions (side-effect-free). |
| `riscos_debug_pause()` / `riscos_debug_resume()` / `riscos_debug_step(count=1)` | Halt / resume / single-step the CPU. |
| `riscos_debug_breakpoint(action, address="")` | `add`/`del`/`clear` PC breakpoints (max 64; a hit pauses the CPU). |
| `riscos_debug_watchpoint(action, address, size, access, log_only)` | `add`/`del`/`clear` data watchpoints (max 32). |
| `riscos_debug_trace(max_events=64)` | Drain the exception/SWI/log-watchpoint trace ring. |

Memory reads and disassembly are **side-effect-free** (they never trigger
watchpoints or inject aborts) and take **virtual** addresses by default, matching
the CPU registers — pass `physical=True` for raw physical addresses. Pausing the
CPU (directly, or via a breakpoint/watchpoint hit) freezes the whole machine
(guest OS, HostCmd, screen) until you resume.

## Requirements

- The MCP Python SDK: `pip install -r requirements.txt` (installs `mcp[cli]`).
- A running RPCEmu machine with **HostCmd enabled** (on by default) and, for the
  screen/input tools, the **VNC server enabled** (`vnc_enabled=1` in the
  machine's `.cfg`). Headless mode already requires VNC, so a `--headless`
  machine works out of the box.

## Configuration (environment variables)

| Variable | Meaning |
| --- | --- |
| `RPCEMU_HOSTCMD_SOCKET` | The machine's HostCmd socket: an AF_UNIX path (e.g. `<data-dir>/hostcmd.sock`) or `host:port` for TCP. |
| `RPCEMU_HOSTFS_DIR` | Host directory backing the machine's HostFS drive (the guest sees it as `HostFS::HostFS.$`). Usually `<data-dir>/machines/<name>/hostfs`. |
| `RPCEMU_VNC_HOST` | VNC host (default `127.0.0.1`). |
| `RPCEMU_VNC_PORT` | VNC port (default `5900`; matches the machine's `vnc_port`). |
| `RPCEMU_DEBUG_SOCKET` | The machine's DebugCmd socket (AF_UNIX path e.g. `<data-dir>/rpcemu-debug.sock`, or `host:port` for TCP). Needed only for the `riscos_debug_*` tools — *not yet available in this fork* (pending `feature/spork-debugcmd-inspect`), so leave it unset for now. |

## Wiring into Claude Code

Copy `mcp.json.example` to `.mcp.json` in your project (or merge it into an
existing one) and fill in the paths for your machine. Claude Code discovers
project-scoped servers from `.mcp.json`. Alternatively:

```bash
claude mcp add rpcemu -- python3 /path/to/tools/mcp/rpcemu_mcp.py
# then set the RPCEMU_* env vars in your shell or the .mcp.json "env" block
```

The script path depends on how RPCEmu was installed: `tools/mcp/rpcemu_mcp.py` in
a source or `.tar.gz` release tree, or `/usr/share/rpcemu/mcp/rpcemu_mcp.py` from
the `.deb`.

Run standalone (stdio transport) for testing:

```bash
RPCEMU_HOSTCMD_SOCKET=/path/hostcmd.sock \
RPCEMU_HOSTFS_DIR=/path/machines/Default/hostfs \
RPCEMU_VNC_PORT=5900 \
python3 rpcemu_mcp.py
```

## Limitations & tips

- **No stdin.** `riscos_run` forwards whole command lines and captures output;
  it has no keyboard input. A command that prompts (bare `BASIC`, editors, Y/N
  confirmations) will hang until `timeout_s`. Use non-interactive forms
  (`BASIC -quit <file>`, batch flags).
- **Memory-hungry commands need the desktop.** `cc`, `BASIC`, and other programs
  that need an application slot only get one once the **desktop is running**
  (HostCmd then runs them in a TaskWindow child). Before the desktop is up they
  run in a restricted context and can hang — which will wedge the HostCmd
  channel until the machine is reset. Start the desktop first (e.g.
  `riscos_send_text("Desktop")`), then use `riscos_run` for builds. Return-code
  capture on the desktop path relies on `Wimp$ScrapDir` being set (it is under a
  normal `!Boot`).
- **VNC input is paced.** Keystrokes are sent slowly on purpose; the emulator
  drops keys sent faster than ~10/s.
