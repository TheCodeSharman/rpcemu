#!/usr/bin/env python3
"""
RPCEmu MCP server — drive a RISC OS machine running under RPCEmu from an
MCP client (Claude Code, Claude Desktop, the API's MCP connector, ...).

Phase 1 tools (this file):
  - riscos_run         run a RISC OS CLI command, stream output, return exit code
  - riscos_write_file  write a file into the machine's HostFS drive (host-side)
  - riscos_read_file   read a file from the HostFS drive
  - riscos_list        list a directory on the HostFS drive
  - riscos_screenshot  grab the emulator screen as a PNG (via VNC)
  - riscos_send_text   type text at the keyboard (via VNC)
  - riscos_send_key    press a single key by X keysym (via VNC)
  - riscos_click       left-click at a pixel coordinate (via VNC)

It talks to interfaces RPCEmu already exposes:
  - HostCmd socket  (guest CLI + output + return code)   -> riscos_run
  - HostFS directory (host filesystem)                    -> file tools
  - VNC server       (framebuffer + input)                -> screen/input tools

Configuration (environment variables):
  RPCEMU_HOSTCMD_SOCKET  AF_UNIX path (or host:port for TCP) of the HostCmd socket.
  RPCEMU_HOSTFS_DIR      Host directory that backs the machine's HostFS drive.
                         (Guest sees it as HostFS::HostFS.$)
  RPCEMU_VNC_HOST        VNC host (default 127.0.0.1).
  RPCEMU_VNC_PORT        VNC port (default 5900).

Run:  python rpcemu_mcp.py         (stdio transport, for Claude Code / Desktop)
"""

from __future__ import annotations

import os
import socket
import struct
import time
import zlib
from pathlib import Path
from typing import Optional

from mcp.server.fastmcp import FastMCP, Image

# --------------------------------------------------------------------------
# Configuration
# --------------------------------------------------------------------------

HOSTCMD_SOCKET = os.environ.get("RPCEMU_HOSTCMD_SOCKET", "")
HOSTFS_DIR = os.environ.get("RPCEMU_HOSTFS_DIR", "")
VNC_HOST = os.environ.get("RPCEMU_VNC_HOST", "127.0.0.1")
VNC_PORT = int(os.environ.get("RPCEMU_VNC_PORT", "5900"))
DEBUG_SOCKET = os.environ.get("RPCEMU_DEBUG_SOCKET", "")

mcp = FastMCP("rpcemu")


# --------------------------------------------------------------------------
# HostCmd client (persistent, auto-reconnecting)
#
# Wire protocol (client -> server): one command line terminated by '\n'.
# server -> client frames: [type:1][len:u32 BE][payload]
#   'O' output chunk, 'D' done (payload = 4-byte BE return code), 'X' notice.
# One command at a time; wait for 'D' before sending the next. The connection
# is kept open so the RISC OS session (current dir, system variables) persists
# across calls.
# --------------------------------------------------------------------------


class HostCmdError(RuntimeError):
    pass


class HostCmd:
    def __init__(self, spec: str):
        self.spec = spec
        self.sock: Optional[socket.socket] = None

    def _connect(self) -> None:
        if not self.spec:
            raise HostCmdError(
                "RPCEMU_HOSTCMD_SOCKET is not set — cannot reach the machine's "
                "HostCmd socket."
            )
        if ":" in self.spec and not self.spec.startswith("/"):
            host, _, port = self.spec.rpartition(":")
            s = socket.create_connection((host or "127.0.0.1", int(port)), timeout=5)
        else:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.settimeout(5)
            s.connect(self.spec)
        self.sock = s
        # Drain the connect banner ('X' notice), best effort.
        try:
            self._read_frame(deadline=time.monotonic() + 2)
        except (HostCmdError, socket.timeout):
            pass

    def _ensure(self) -> None:
        if self.sock is None:
            self._connect()

    def _drop(self) -> None:
        if self.sock is not None:
            try:
                self.sock.close()
            finally:
                self.sock = None

    def _recv_exact(self, n: int, deadline: float) -> bytes:
        assert self.sock is not None
        buf = b""
        while len(buf) < n:
            self.sock.settimeout(max(0.05, deadline - time.monotonic()))
            chunk = self.sock.recv(n - len(buf))
            if not chunk:
                raise HostCmdError("HostCmd connection closed by the emulator")
            buf += chunk
        return buf

    def _read_frame(self, deadline: float):
        hdr = self._recv_exact(5, deadline)
        typ = chr(hdr[0])
        (length,) = struct.unpack(">I", hdr[1:5])
        payload = self._recv_exact(length, deadline) if length else b""
        return typ, payload

    def run(self, command: str, timeout_s: float) -> dict:
        command = command.rstrip("\r\n")
        # Try once; on a stale/broken connection, reconnect and retry once.
        for attempt in range(2):
            try:
                self._ensure()
                assert self.sock is not None
                self.sock.settimeout(5)
                self.sock.sendall((command + "\n").encode("latin-1", "replace"))
                deadline = time.monotonic() + timeout_s
                out = bytearray()
                notices = []
                while True:
                    typ, payload = self._read_frame(deadline)
                    if typ == "O":
                        out += payload
                    elif typ == "X":
                        note = payload.decode("latin-1").strip()
                        notices.append(note)
                        if "busy" in note.lower():
                            # A previous command is still in flight in the guest
                            # (often a hung memory-hungry/interactive command). No
                            # 'D' frame will follow this one — don't wait it out.
                            raise HostCmdError(
                                "the guest is busy with a previous command that "
                                "has not finished (it may be hung — e.g. an "
                                "interactive or memory-starved command). Reset the "
                                "machine or wait for it to complete."
                            )
                    elif typ == "D":
                        rc = struct.unpack(">i", payload)[0] if len(payload) == 4 else None
                        text = out.decode("latin-1")
                        return {
                            "return_code": rc,
                            "output": text,
                            "notices": notices,
                        }
                    else:
                        # Unknown frame; ignore.
                        pass
            except (HostCmdError, socket.timeout, OSError) as e:
                self._drop()
                if attempt == 0 and isinstance(e, (HostCmdError, OSError)):
                    continue  # reconnect and retry once
                if isinstance(e, socket.timeout):
                    raise HostCmdError(
                        f"Timed out after {timeout_s}s waiting for '{command}' to "
                        "finish. Interactive commands (bare BASIC, editors, Y/N "
                        "prompts) have no stdin and will hang — use non-interactive "
                        "invocations."
                    )
                raise
        raise HostCmdError("unreachable")


_hostcmd = HostCmd(HOSTCMD_SOCKET)


# --------------------------------------------------------------------------
# DebugCmd client (persistent, auto-reconnecting)
#
# Newline-delimited: send "<verb> [args]\n", read exactly one JSON object line.
# Runs against RPCEmu's host-side debugger, so it can inspect and control the
# emulated CPU directly.
# --------------------------------------------------------------------------


class DebugCmd:
    def __init__(self, spec: str):
        self.spec = spec
        self.sock: Optional[socket.socket] = None
        self.buf = b""

    def _connect(self) -> None:
        if not self.spec:
            raise HostCmdError(
                "RPCEMU_DEBUG_SOCKET is not set — the debugger socket is "
                "unavailable (is debug_enabled=1 for this machine?)."
            )
        if ":" in self.spec and not self.spec.startswith("/"):
            host, _, port = self.spec.rpartition(":")
            self.sock = socket.create_connection((host or "127.0.0.1", int(port)), timeout=5)
        else:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.settimeout(5)
            s.connect(self.spec)
            self.sock = s
        self.buf = b""

    def _drop(self) -> None:
        if self.sock is not None:
            try:
                self.sock.close()
            finally:
                self.sock = None
        self.buf = b""

    def cmd(self, line: str) -> dict:
        for attempt in range(2):
            try:
                if self.sock is None:
                    self._connect()
                assert self.sock is not None
                self.sock.settimeout(5)
                self.sock.sendall((line + "\n").encode("latin-1", "replace"))
                deadline = time.monotonic() + 5
                while b"\n" not in self.buf:
                    self.sock.settimeout(max(0.05, deadline - time.monotonic()))
                    chunk = self.sock.recv(65536)
                    if not chunk:
                        raise HostCmdError("debugger connection closed")
                    self.buf += chunk
                ln, _, self.buf = self.buf.partition(b"\n")
                import json

                return json.loads(ln.decode("latin-1"))
            except (HostCmdError, socket.timeout, OSError) as e:
                self._drop()
                if attempt == 0 and not isinstance(e, socket.timeout):
                    continue
                raise HostCmdError(f"debugger command {line!r} failed: {e}")
        raise HostCmdError("unreachable")


_debug = DebugCmd(DEBUG_SOCKET)


# --------------------------------------------------------------------------
# HostFS file helpers (host-side; the guest sees this dir as HostFS::HostFS.$)
#
# RISC OS filetypes are encoded on HostFS as a ",xxx" leaf suffix (xxx = 3 hex
# digits). Paths here use host-style '/' separators relative to the HostFS root.
# --------------------------------------------------------------------------


def _hostfs_root() -> Path:
    if not HOSTFS_DIR:
        raise HostCmdError(
            "RPCEMU_HOSTFS_DIR is not set — cannot access the HostFS drive."
        )
    return Path(HOSTFS_DIR).resolve()


def _safe_join(rel: str) -> Path:
    root = _hostfs_root()
    p = (root / rel.lstrip("/")).resolve()
    if p != root and root not in p.parents:
        raise HostCmdError(f"path escapes the HostFS root: {rel!r}")
    return p


# --------------------------------------------------------------------------
# Minimal VNC/RFB client (screenshot + input). RFB 3.3, security None, Raw.
# --------------------------------------------------------------------------


def _vnc_connect() -> tuple[socket.socket, int, int]:
    s = socket.create_connection((VNC_HOST, VNC_PORT), timeout=10)
    s.settimeout(15)

    def recvn(n: int) -> bytes:
        b = b""
        while len(b) < n:
            c = s.recv(n - len(b))
            if not c:
                raise HostCmdError("VNC connection closed during handshake")
            b += c
        return b

    recvn(12)  # server "RFB 003.00x\n"
    s.sendall(b"RFB 003.003\n")
    (sec,) = struct.unpack(">I", recvn(4))
    if sec == 0:
        (n,) = struct.unpack(">I", recvn(4))
        raise HostCmdError("VNC connection failed: " + recvn(n).decode("latin-1"))
    if sec != 1:
        raise HostCmdError(
            f"VNC server requires authentication (security type {sec}); this tool "
            "only supports passwordless VNC."
        )
    s.sendall(b"\x01")  # ClientInit, shared
    w, h = struct.unpack(">HH", recvn(4))
    recvn(16)  # pixel format
    (nl,) = struct.unpack(">I", recvn(4))
    recvn(nl)  # desktop name
    return s, w, h


def _vnc_screenshot_png() -> bytes:
    s, w, h = _vnc_connect()

    def recvn(n: int) -> bytes:
        b = b""
        while len(b) < n:
            c = s.recv(n - len(b))
            if not c:
                raise HostCmdError("VNC connection closed mid-framebuffer")
            b += c
        return b

    # Force 32bpp true-colour, big-endian, RGB shifts 16/8/0.
    spf = (
        struct.pack(">BBBB", 0, 0, 0, 0)
        + struct.pack(">BBBB", 32, 24, 1, 1)
        + struct.pack(">HHH", 255, 255, 255)
        + struct.pack(">BBB", 16, 8, 0)
        + b"\x00\x00\x00"
    )
    s.sendall(spf)
    s.sendall(struct.pack(">BBH", 2, 0, 1) + struct.pack(">i", 0))  # SetEncodings: Raw
    s.sendall(struct.pack(">BBHHHH", 3, 0, 0, 0, w, h))  # FramebufferUpdateRequest

    mt = recvn(1)[0]
    while mt != 0:  # skip non-FramebufferUpdate messages
        if mt == 1:
            recvn(5)
        elif mt == 3:
            recvn(7)
        mt = recvn(1)[0]
    recvn(1)
    (nrect,) = struct.unpack(">H", recvn(2))
    fb = bytearray(w * h * 4)
    for _ in range(nrect):
        x, y, rw, rh, enc = struct.unpack(">HHHHi", recvn(12))
        if enc != 0:
            raise HostCmdError(f"VNC server used unsupported encoding {enc}")
        data = recvn(rw * rh * 4)
        for row in range(rh):
            src = row * rw * 4
            dst = ((y + row) * w + x) * 4
            fb[dst : dst + rw * 4] = data[src : src + rw * 4]
    s.close()
    return _encode_png(w, h, fb)


def _encode_png(width: int, height: int, fb: bytes) -> bytes:
    """Encode the VNC framebuffer (4 bytes/pixel, first 3 = R,G,B) as an RGB PNG."""
    raw = bytearray()
    for y in range(height):
        raw.append(0)  # filter: none
        row = y * width * 4
        for x in range(width):
            o = row + x * 4
            raw += bytes((fb[o], fb[o + 1], fb[o + 2]))

    def chunk(typ: bytes, data: bytes) -> bytes:
        c = typ + data
        return struct.pack(">I", len(data)) + c + struct.pack(">I", zlib.crc32(c) & 0xFFFFFFFF)

    sig = b"\x89PNG\r\n\x1a\n"
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    return (
        sig
        + chunk(b"IHDR", ihdr)
        + chunk(b"IDAT", zlib.compress(bytes(raw), 6))
        + chunk(b"IEND", b"")
    )


def _vnc_send_keys(syms: list[int]) -> None:
    s, _, _ = _vnc_connect()
    try:
        for sym in syms:
            # Deliberately unhurried: the emulator samples VNC input at the
            # keyboard-scan rate, and bursts faster than ~10 keys/s get dropped
            # (observed: "Desktop" arriving as "dkop" at 0.05s/key).
            s.sendall(struct.pack(">BBHI", 4, 1, 0, sym))  # KeyEvent down
            time.sleep(0.04)
            s.sendall(struct.pack(">BBHI", 4, 0, 0, sym))  # KeyEvent up
            time.sleep(0.07)
    finally:
        s.close()


def _vnc_click(x: int, y: int) -> None:
    s, _, _ = _vnc_connect()
    try:
        s.sendall(struct.pack(">BBHH", 5, 0, x, y))  # move
        time.sleep(0.05)
        s.sendall(struct.pack(">BBHH", 5, 1, x, y))  # left down
        time.sleep(0.08)
        s.sendall(struct.pack(">BBHH", 5, 0, x, y))  # up
        time.sleep(0.05)
    finally:
        s.close()


# --------------------------------------------------------------------------
# MCP tools
# --------------------------------------------------------------------------


@mcp.tool()
def riscos_run(command: str, timeout_s: float = 30.0) -> dict:
    """Run a RISC OS command-line command inside the emulated machine and return
    its output and return code.

    Use this to drive the guest OS: run star-commands, build tools (cc, objasm,
    link), BASIC programs, etc. Output written to the VDU stream is captured.
    The RISC OS session persists across calls — the current directory and system
    variables set by one command are visible to the next.

    IMPORTANT: this forwards whole command lines and captures output; it has no
    stdin. Commands that prompt for keyboard input (a bare `BASIC`, editors, Y/N
    confirmations) will hang until `timeout_s`. Prefer non-interactive forms
    (e.g. `BASIC -quit <file>`, batch flags). Files on the HostFS drive are
    reachable in the guest as `HostFS::HostFS.$.<name>`.

    Returns: {"return_code": int, "output": str, "notices": [str]}.
    """
    return _hostcmd.run(command, timeout_s)


@mcp.tool()
def riscos_write_file(path: str, content: str, filetype: str = "fff") -> str:
    """Write a text file onto the machine's HostFS drive (host-side write).

    `path` is relative to the HostFS root, using '/' as the separator (e.g.
    "work/hello"). `filetype` is a 3-hex-digit RISC OS filetype appended as a
    ",xxx" suffix on disk (default "fff" = Text; use "ffb" for tokenised BASIC,
    "ffa" for a module, etc.); pass an empty string for no filetype suffix.

    The guest sees the file at HostFS::HostFS.$.<path-with-dots>. Returns the
    host path written.
    """
    p = _safe_join(path)
    if filetype:
        p = p.with_name(p.name + "," + filetype.lower())
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(content, encoding="latin-1")
    return str(p)


@mcp.tool()
def riscos_read_file(path: str) -> str:
    """Read a text file from the machine's HostFS drive.

    `path` is relative to the HostFS root ('/'-separated). The ",xxx" filetype
    suffix is optional — if "work/hello" isn't found, the first "work/hello,*"
    match is read. Returns the file contents.
    """
    p = _safe_join(path)
    if not p.exists():
        matches = sorted(p.parent.glob(p.name + ",*")) if p.parent.exists() else []
        if matches:
            p = matches[0]
        else:
            raise HostCmdError(f"no such file on the HostFS drive: {path!r}")
    return p.read_text(encoding="latin-1")


@mcp.tool()
def riscos_list(path: str = ".") -> list[str]:
    """List a directory on the machine's HostFS drive.

    `path` is relative to the HostFS root ('/'-separated; "." = root). Directory
    entries are suffixed with '/'. RISC OS filetype suffixes (",xxx") are shown
    as-is. Returns the sorted list of entries.
    """
    p = _safe_join(path)
    if not p.is_dir():
        raise HostCmdError(f"not a directory on the HostFS drive: {path!r}")
    out = []
    for child in sorted(p.iterdir()):
        out.append(child.name + ("/" if child.is_dir() else ""))
    return out


@mcp.tool()
def riscos_screenshot() -> Image:
    """Capture the emulated machine's screen as a PNG image (via VNC).

    Use this to see the current display — the desktop, an application window,
    text-mode output, an error box — so you can verify GUI results or read
    anything that isn't captured by riscos_run's text stream.
    """
    return Image(data=_vnc_screenshot_png(), format="png")


@mcp.tool()
def riscos_send_text(text: str) -> str:
    """Type a string at the emulated keyboard (via VNC), followed by Return.

    Use this to interact with on-screen prompts or the desktop when a command
    can't be driven through riscos_run (e.g. typing into an application, or
    starting the desktop with `Desktop`). Printable ASCII plus Return only.
    """
    syms = [ord(c) for c in text]
    syms.append(0xFF0D)  # Return
    _vnc_send_keys(syms)
    return f"typed {len(text)} chars + Return"


@mcp.tool()
def riscos_send_key(keysym: int) -> str:
    """Press and release a single key by X11 keysym (via VNC).

    Useful for non-printing keys: Return=0xFF0D, Escape=0xFF1B, F12=0xFFC9,
    Tab=0xFF09, Backspace=0xFF08, cursor keys 0xFF51-0xFF54. Printable ASCII
    keysyms equal the character code.
    """
    _vnc_send_keys([keysym])
    return f"pressed keysym 0x{keysym:04x}"


@mcp.tool()
def riscos_click(x: int, y: int) -> str:
    """Left-click at pixel coordinate (x, y) on the emulated screen (via VNC).

    Coordinates are screen pixels from the top-left, matching riscos_screenshot
    output. Use this to dismiss dialog boxes, click iconbar icons, etc.
    """
    _vnc_click(int(x), int(y))
    return f"clicked ({x}, {y})"


def _hexaddr(a: str) -> str:
    a = a.strip().lower()
    if a.startswith("0x"):
        a = a[2:]
    int(a, 16)  # validate
    return a


@mcp.tool()
def riscos_debug_registers() -> dict:
    """Read the emulated ARM CPU registers.

    Returns {r0..r15 (hex), pc, cpsr, mode, flags ("NZCV"), paused}. This is the
    host-side view of the *emulated* CPU (not a RISC OS debugger) — it works
    whether the CPU is running or paused.
    """
    return _debug.cmd("regs")


@mcp.tool()
def riscos_debug_status() -> dict:
    """Read the debugger status: whether the CPU is paused and why, the last/halt
    PC and opcode, any watchpoint hit, and the current breakpoint and watchpoint
    lists. `reason`: 0=none 1=user 2=breakpoint 3=watchpoint 4=step 5=exception
    6=SWI.
    """
    return _debug.cmd("status")


@mcp.tool()
def riscos_debug_read_memory(address: str, length: int = 64, physical: bool = False) -> dict:
    """Read emulated memory (side-effect-free — never triggers watchpoints/aborts).

    `address` is hex (e.g. "fc03d870"). By default it is a **virtual** (MMU-
    translated) address, matching the CPU registers/PC; pass physical=True to
    read a raw physical address instead. `length` is capped at 4096. Returns
    {addr, physical, len, data} where data is a hex string (unmapped bytes read
    as 00).
    """
    return _debug.cmd(f"mem {_hexaddr(address)} {int(length)}{' phys' if physical else ''}")


@mcp.tool()
def riscos_debug_disassemble(address: str, count: int = 16, physical: bool = False) -> dict:
    """Disassemble emulated ARM instructions (side-effect-free).

    `address` is hex; virtual by default (use physical=True for a raw physical
    address). `count` is capped at 256. Returns {lines: ["<addr>: <opcode>
    <mnemonic>", ...]}. Disassemble at the `pc` from riscos_debug_registers to
    see what the CPU is about to execute.
    """
    return _debug.cmd(f"dis {_hexaddr(address)} {int(count)}{' phys' if physical else ''}")


@mcp.tool()
def riscos_debug_pause() -> dict:
    """Halt the emulated CPU. The pause is asynchronous — it takes effect at the
    next instruction, so poll riscos_debug_status until paused is true. WARNING:
    a paused CPU freezes the whole machine (guest OS, HostCmd, and the screen all
    stop) until riscos_debug_resume. Use for inspection, then resume.
    """
    return _debug.cmd("pause")


@mcp.tool()
def riscos_debug_resume() -> dict:
    """Resume the emulated CPU after a pause, breakpoint, watchpoint, or step."""
    return _debug.cmd("resume")


@mcp.tool()
def riscos_debug_step(count: int = 1) -> dict:
    """Single-step the emulated CPU `count` instructions, then pause again. The
    CPU must be paused (or about to be). Follow with riscos_debug_registers /
    riscos_debug_disassemble to observe the effect.
    """
    return _debug.cmd(f"step {int(count)}")


@mcp.tool()
def riscos_debug_breakpoint(action: str, address: str = "") -> dict:
    """Manage PC breakpoints (max 64). `action` is "add", "del", or "clear".
    `address` (hex) is required for add/del. When the emulated PC reaches a
    breakpoint the CPU pauses (riscos_debug_status shows reason=2); resume with
    riscos_debug_resume.
    """
    action = action.strip().lower()
    if action == "clear":
        return _debug.cmd("bp clear")
    if action in ("add", "del"):
        if not address:
            raise HostCmdError(f"bp {action} requires an address")
        return _debug.cmd(f"bp {action} {_hexaddr(address)}")
    raise HostCmdError('action must be "add", "del", or "clear"')


@mcp.tool()
def riscos_debug_watchpoint(action: str, address: str = "", size: int = 4,
                            access: str = "w", log_only: bool = False) -> dict:
    """Manage data watchpoints (max 32). `action` is "add", "del", or "clear".
    For add/del: `address` (hex), `size` in bytes, `access` one of "r"/"w"/"rw".
    If log_only=True (add), a matching access emits a trace event instead of
    halting (read with riscos_debug_trace). Otherwise a match pauses the CPU
    (riscos_debug_status shows reason=3).
    """
    action = action.strip().lower()
    if action == "clear":
        return _debug.cmd("wp clear")
    if action in ("add", "del"):
        if not address:
            raise HostCmdError(f"wp {action} requires an address")
        tail = " log" if (log_only and action == "add") else ""
        return _debug.cmd(f"wp {action} {_hexaddr(address)} {int(size)} {access}{tail}")
    raise HostCmdError('action must be "add", "del", or "clear"')


@mcp.tool()
def riscos_debug_trace(max_events: int = 64) -> dict:
    """Drain the debug trace ring — exception, SWI, and log-only-watchpoint events
    captured during execution (up to 128). Returns {dropped, events:[{seq, type
    (0=exception 1=SWI 2=watchpoint), pc, opcode, arg0, arg1, arg2}]}. Tracing of
    exceptions/SWIs must be configured in the machine's debugger for events to
    appear; log-only watchpoints always feed it.
    """
    return _debug.cmd(f"trace {int(max_events)}")


if __name__ == "__main__":
    mcp.run()
