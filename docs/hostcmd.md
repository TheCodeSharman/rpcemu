# HostCmd — drive the RISC OS command line from the host

HostCmd exposes the guest's RISC OS command line to the host over a local
socket. Combined with **HostFS** (which already maps a host directory into
RISC OS), it turns RPCEmu into a remote build target: edit source in a host
editor, run the build **inside** RISC OS, and read the output back on the host —
ideal for driving the RISC OS toolchain (`cc`, `objasm`, `link`, `basic`, …)
from a modern IDE or an automation/LLM agent.

```
host tool (rpcemu-run / your IDE / Claude Code)
        │   local AF_UNIX socket
        ▼
   emulator (hostcmd.c)  ── ArcEm SWI 0x56ac5 ──▶  HostCmd gateway module
        ▲                                                │  OS_CLI + WrchV capture
        └──────────────── streamed output ◀─────────────┘
```

## Quick start

1. Build the emulator (interpreter) and the host-side client:
   ```bash
   make                  # builds the interpreter
   make -C src/tools     # builds src/tools/rpcemu-run (a plain socket client;
                         # no qmake/Qt — just libc)
   ```
2. Make the guest gateway module visible to a machine. It ships **prebuilt** at
   `riscos-progs/HostCmd/hostcmd,ffa`; copy it into that machine's
   `poduleroms/` directory so RISC OS auto-loads it at boot (alongside
   `hostfs,ffa`). (`hostcmd,ffa` is a checked-in binary — you only need the ARM
   cross-assembler if you want to rebuild it from `hostcmd.s`.)
3. Start a machine. HostCmd is **on by default**; the emulator creates a socket
   at `<data-dir>/hostcmd.sock`.
4. From the host:
   ```bash
   # one-shot: run a command, print its output, exit with the guest return code
   src/tools/rpcemu-run -- Cat HostFS::HostFS.$

   # compile-on-guest loop
   src/tools/rpcemu-run -- cc -c hello
   ```

`rpcemu-run` exits with the command's RISC OS return code (`Sys$ReturnCode`),
so it drops straight into Makefiles, scripts and agent tool-calls.

## How it works

- The emulator traps a custom **ArcEm SWI** (`0x56ac5`, chunk `0x56ac0 + 5`),
  the same mechanism HostFS and networking use. The handler and the socket are
  serviced on the emulator thread, so no locking is involved.
- A small RISC OS **gateway module** (`riscos-progs/HostCmd`) runs a `~1cs`
  ticker that polls the emulator for a submitted command. When one arrives it is
  run from a **transient callback** (a safe foreground context) with **WrchV**
  claimed, so all VDU output is captured — and still shown on the emulated
  screen. The ticker streams that output back to the host *while the command is
  still running*, then reports the return code once the output has drained.
- Session state persists: sequential commands share RISC OS's current directory
  and system variables, and the session even survives a guest reset.

## Configuration

Per-machine `.cfg` keys (under `[General]`):

| Key | Default | Meaning |
| --- | --- | --- |
| `hostcmd_enabled` | `1` | Enable the HostCmd socket. |
| `hostcmd_socket` | *(empty)* | Empty ⇒ `<data-dir>/hostcmd.sock` (AF_UNIX). A path ⇒ that AF_UNIX path. A bare port number ⇒ TCP on `127.0.0.1:<port>`. |

The host client picks the socket from `--socket PATH`, `--tcp host:port`, or the
default `$RPCEMU_DATADIR/hostcmd.sock`.

## Wire protocol

For anyone integrating without the CLI:

- **Client → server:** one command line terminated by `\n` (RISC OS command
  lines can't contain newlines). e.g. `printf 'Cat\n' | nc -U <data-dir>/hostcmd.sock`.
- **Server → client:** length-prefixed frames `[type:1][len:uint32 BE][payload]`:
  - `O` — output chunk (streamed live).
  - `D` — command done; payload is the 4-byte big-endian return code (the
    command boundary).
  - `X` — advisory text (banner, "busy", "machine reset").

One command runs at a time; a client should wait for the `D` frame before
sending the next line. If a second client connects while one is active it is
rejected with an `X` notice.

## Security

HostCmd lets whoever can open the socket run **arbitrary** commands inside the
guest. The default transport is an **AF_UNIX** socket under the machine's data
directory, so access is limited by filesystem permissions and it is never
exposed on the network. The optional TCP mode binds `127.0.0.1` only; it is
reachable by any local user, so enable it deliberately. To disable HostCmd
entirely, set `hostcmd_enabled=0`.

## Limitations

- **No stdin / mid-command interaction.** The channel forwards whole command
  lines and captures output; a command that prompts for keyboard input
  (editors, `Y/N` confirmations) will hang. Prefer non-interactive tool
  invocations (`-quit`, batch flags).
- **Text output only.** WrchV captures everything written through the VDU
  character stream (`OS_WriteC`, `OS_Write0`, C `printf`, …). Programs that draw
  directly to the screen bypass it.
