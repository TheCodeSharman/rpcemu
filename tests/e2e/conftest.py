"""Shared fixtures for the RPCEmu agent-drive end-to-end suite.

The suite has two tiers:

  * OFFLINE  — no emulator; exercises the MCP server's host-side logic and the
               rpcemu-run client's argument handling. Always runs.
  * LIVE     — needs a booted, HostCmd-capable RISC OS guest. Marked
               ``@pytest.mark.emulator``; skipped automatically when no guest is
               available, so ``pytest -m "not emulator"`` gives a fast, headless run.

Providing a guest for the LIVE tests — two ways:

  * ATTACH to an already-running emulator (does not disturb it)::

        RPCEMU_HOSTCMD_SOCKET=/path/to/install/hostcmd.sock
        RPCEMU_HOSTFS_DIR=/path/to/install/hostfs

  * BOOT one for the whole session from an install (needs a display; the install
    must have ``hostcmd,ffa`` in its ``poduleroms/``)::

        RPCEMU_TEST_INSTALL=/path/to/installs/<name>

Path overrides (default to the repo's built artifacts):
  RPCEMU_RUN   — the rpcemu-run client binary (default src/tools/rpcemu-run)
  RPCEMU_MCP   — the MCP server module      (default tools/mcp/rpcemu_mcp.py)
  RPCEMU       — the emulator binary, boot mode only (default ./rpcemu-interpreter)
"""

from __future__ import annotations

import importlib.util
import os
import stat
import subprocess
import time
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[2]


def _path_env(var: str, default: str) -> Path:
    return Path(os.environ.get(var) or str(REPO / default))


RPCEMU_RUN = _path_env("RPCEMU_RUN", "src/tools/rpcemu-run")
MCP_MODULE = _path_env("RPCEMU_MCP", "tools/mcp/rpcemu_mcp.py")
BOOT_TIMEOUT = float(os.environ.get("RPCEMU_BOOT_TIMEOUT", "90"))


def _is_socket(p: Path) -> bool:
    try:
        return stat.S_ISSOCK(p.stat().st_mode)
    except OSError:
        return False


def _wait_for_socket(p: Path, timeout: float) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if _is_socket(p):
            return True
        time.sleep(0.5)
    return False


class Guest:
    """A handle on a HostCmd-capable machine: its socket, HostFS dir, and a
    convenience ``run()`` that drives a guest command through rpcemu-run."""

    def __init__(self, socket_path: str, hostfs_dir: str):
        self.socket = socket_path
        self.hostfs = Path(hostfs_dir)

    def run(self, command: str, timeout: float = 30.0):
        """Run one guest command; return (return_code, output). Output is the
        VDU stream (rpcemu-run sends it to stdout); notices go to stderr."""
        r = subprocess.run(
            [str(RPCEMU_RUN), "--socket", self.socket, "--", command],
            capture_output=True, text=True, timeout=timeout,
        )
        return r.returncode, r.stdout


@pytest.fixture(scope="session")
def guest():
    """Yield a Guest, attaching to or booting an emulator; skip if none available."""
    sock = os.environ.get("RPCEMU_HOSTCMD_SOCKET")
    hostfs = os.environ.get("RPCEMU_HOSTFS_DIR")

    if sock:  # ---- attach mode ----
        if not hostfs:
            pytest.skip("RPCEMU_HOSTCMD_SOCKET is set but RPCEMU_HOSTFS_DIR is not")
        if not _is_socket(Path(sock)):
            pytest.skip(f"HostCmd socket not present: {sock}")
        yield Guest(sock, hostfs)
        return

    install = os.environ.get("RPCEMU_TEST_INSTALL")
    if not install:  # ---- neither: skip the live tier ----
        pytest.skip(
            "no guest — set RPCEMU_HOSTCMD_SOCKET (attach) or RPCEMU_TEST_INSTALL (boot)"
        )

    # ---- boot mode ----
    install_dir = Path(install).resolve()
    run_script = install_dir / "run"
    sockpath = install_dir / "hostcmd.sock"
    if not run_script.exists():
        pytest.skip(f"no run script in install: {run_script}")
    if not RPCEMU_RUN.exists():
        pytest.skip(f"rpcemu-run not built at {RPCEMU_RUN} (build the integration tree first)")

    try:
        sockpath.unlink()
    except FileNotFoundError:
        pass

    env = dict(os.environ)
    env.setdefault("RPCEMU", str(REPO / "rpcemu-interpreter"))
    proc = subprocess.Popen(
        [str(run_script)], cwd=str(install_dir), env=env,
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    try:
        if not _wait_for_socket(sockpath, BOOT_TIMEOUT):
            pytest.fail(f"emulator did not open {sockpath} within {BOOT_TIMEOUT}s")
        yield Guest(str(sockpath), str(install_dir / "hostfs"))
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()
        try:
            sockpath.unlink()
        except FileNotFoundError:
            pass


@pytest.fixture
def load_mcp():
    """Return a loader that imports a FRESH copy of the MCP server with the given
    environment applied first (the module reads its config from env at import)."""
    counter = {"n": 0}

    def _load(**env):
        for key, value in env.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = str(value)
        counter["n"] += 1
        spec = importlib.util.spec_from_file_location(
            f"rpcemu_mcp_undertest_{counter['n']}", MCP_MODULE
        )
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod

    if not MCP_MODULE.exists():
        pytest.skip(f"MCP server not found at {MCP_MODULE} (need the integration tree)")
    return _load


@pytest.fixture
def rpcemu_run_bin():
    """Path to the rpcemu-run client binary (skip if not built)."""
    if not RPCEMU_RUN.exists():
        pytest.skip(f"rpcemu-run not built at {RPCEMU_RUN}")
    return RPCEMU_RUN


@pytest.fixture
def mcp(guest, load_mcp):
    """The MCP server module bound to the live guest, with its persistent HostCmd
    connection closed on teardown. HostCmd serves ONE client at a time, so each
    live test must release its connection before the next opens one."""
    mod = load_mcp(RPCEMU_HOSTCMD_SOCKET=guest.socket, RPCEMU_HOSTFS_DIR=guest.hostfs)
    yield mod
    try:
        mod._hostcmd._drop()   # close the socket so the next test can connect
    except Exception:
        pass
