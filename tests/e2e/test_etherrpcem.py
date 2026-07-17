"""Regression tests for the EtherRPCEm driver across RAM sizes.

RISC OS 5.30 used to data-abort during boot on every RAM size except 256MB,
because the driver passed its expansion card's base address to Podule_ReadInfo
and left a callback queued when the resulting error killed it. See
feature/etherrpcem-podule-fix.

These tests boot a real guest at several RAM sizes and drive the driver through
its **public interface** -- the SWI chunk it publishes (EtherRPCEm_DCIVersion,
EtherRPCEm_Inquire) -- rather than reaching into its internals. That keeps them
honest about what a client of the driver actually observes, and means they say
nothing about how initialise() is arranged internally.

Why these live here and not in tests/unit: the fix is in guest ARM code
(riscos-progs/EtherRPCEm), built by Norcroft *inside* the emulator. Unlike
src/ide.c there is no host-linkable translation unit for Criterion to drive, and
the bug is only expressible against a booted RISC OS with a real Podule manager.
The RAM size is the whole point of the test, so each size gets its own boot.

On an unfixed driver the 32MB cases fail: the abort stops the boot, so the guest
never opens its HostCmd socket and the module never becomes resident. The 256MB
cases pass either way -- they are the control, proving the fix does not regress
the one size that always worked.

Needs an install whose netroms/ holds the driver under test, plus hostcmd,ffa in
poduleroms/ and a display to boot into::

    RPCEMU_TEST_INSTALL=installs/riscos-530 pytest tests/e2e/test_etherrpcem.py
"""

from __future__ import annotations

import os
import re
import subprocess
import time
from contextlib import contextmanager
from pathlib import Path

import pytest

from conftest import RPCEMU_RUN, Guest, _wait_for_socket

REPO = Path(__file__).resolve().parents[2]

# 256MB is the only size that ever worked, so it is the control. 32MB is the
# size the bug was reported against. 8MB is the far end of the range.
RAM_SIZES = [8, 32, 256]

BOOT_TIMEOUT = float(os.environ.get("RPCEMU_BOOT_TIMEOUT", "180"))

# The driver's published SWI chunk (cmhg: swi-chunk-base-number 0x58CC0).
SWI_DCIVERSION = 0x58CC0
SWI_INQUIRE = 0x58CC1

DCI_VERSION = 403  # DCI 4.03, what the driver reports

# INQ_MULTICAST|INQ_PROMISCUOUS|INQ_RXERRORS|INQ_HWADDRVALID|INQ_SOFTHWADDR|INQ_HASSTATS
INQUIRE_FLAGS = 0x173

ERR_EINVAL = 0x20E16  # DCI4 error base | EINVAL, what the SWIs reject bad flags with


def _install_dir() -> Path:
    install = os.environ.get("RPCEMU_TEST_INSTALL")
    if not install:
        pytest.skip("no install — set RPCEMU_TEST_INSTALL=installs/riscos-530")
    return Path(install).resolve()


@contextmanager
def _booted(install: Path, mem_size: int):
    """Boot the install at mem_size and yield a Guest; restore rpc.cfg after."""
    if not RPCEMU_RUN.exists():
        pytest.skip(f"rpcemu-run not built at {RPCEMU_RUN}")
    if not (install / "netroms" / "EtherRPCEm,ffa").exists():
        pytest.skip(f"no EtherRPCEm in {install}/netroms")

    cfg = install / "rpc.cfg"
    saved = cfg.read_text()
    cfg.write_text(re.sub(r"^mem_size=.*$", f"mem_size={mem_size}", saved, flags=re.M))

    sockpath = install / "hostcmd.sock"
    sockpath.unlink(missing_ok=True)

    env = dict(os.environ)
    env.setdefault("RPCEMU", str(REPO / "rpcemu-interpreter"))
    proc = subprocess.Popen(
        [str(install / "run")], cwd=str(install), env=env,
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    try:
        if not _wait_for_socket(sockpath, BOOT_TIMEOUT):
            pytest.fail(f"{mem_size}MB: no HostCmd socket within {BOOT_TIMEOUT}s")
        guest = Guest(str(sockpath), str(install / "hostfs"))
        # The socket appears early in the boot; wait for the CLI to answer.
        deadline = time.monotonic() + BOOT_TIMEOUT
        while time.monotonic() < deadline:
            try:
                if "pong" in guest.run("Echo pong", timeout=15)[1]:
                    break
            except subprocess.TimeoutExpired:
                pass
            time.sleep(2)
        else:
            pytest.fail(f"{mem_size}MB: guest never reached a usable command line "
                        f"(an unfixed driver aborts the boot here)")
        yield guest
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()
        sockpath.unlink(missing_ok=True)
        cfg.write_text(saved)


@pytest.fixture(scope="module", params=RAM_SIZES, ids=lambda m: f"{m}MB")
def guest_at_ram(request):
    """A booted guest at each RAM size. One boot per size — the size is the test."""
    with _booted(_install_dir(), request.param) as guest:
        yield guest, request.param


def _basic(guest: Guest, body: str) -> str:
    """Run a BASIC fragment in the guest and return what it wrote to $.tout.

    BASIC is the only scripting the guest is guaranteed to have, and writing to
    a HostFS file is the only reliable way back to the host (output redirection
    does not survive HostCmd).
    """
    out = guest.hostfs / "tout"
    for stale in guest.hostfs.glob("tout,*"):
        stale.unlink()
    out.unlink(missing_ok=True)

    prog = (
        'o%=OPENOUT"HostFS::HostFS.$.tout"\n'
        'ON ERROR BPUT#o%,"ERR &"+STR$~ERR:CLOSE#o%:QUIT\n'
        f"{body}\n"
        "CLOSE#o%\n"
        "QUIT\n"
    )
    (guest.hostfs / "tprog,fff").write_text(prog)
    guest.run("BASIC -quit HostFS::HostFS.$.tprog", timeout=60)

    for _ in range(10):
        hits = list(guest.hostfs.glob("tout,*")) + ([out] if out.exists() else [])
        if hits:
            return hits[0].read_text().replace("\r", "\n").strip()
        time.sleep(1)
    pytest.fail("BASIC produced no output file")


@pytest.mark.emulator
def test_module_is_resident(guest_at_ram):
    """The driver survives its own initialisation and stays loaded.

    The original bug made initialise() fail, so RISC OS unloaded the module.
    """
    guest, mem_size = guest_at_ram
    _, out = guest.run("Modules")
    assert "EtherRPCEm" in out, f"{mem_size}MB: EtherRPCEm is not resident:\n{out}"


@pytest.mark.emulator
def test_card_is_present(guest_at_ram):
    """The emulated Ethernet card is enumerated (a precondition for the rest)."""
    guest, mem_size = guest_at_ram
    _, out = guest.run("Podules")
    assert re.search(r"Expansion card\s+\d+:\s*RPCEmu Ethernet", out), \
        f"{mem_size}MB: no RPCEmu Ethernet card:\n{out}"


@pytest.mark.emulator
def test_swi_dciversion(guest_at_ram):
    """EtherRPCEm_DCIVersion reports the DCI version it implements."""
    guest, mem_size = guest_at_ram
    out = _basic(guest, f'SYS &{SWI_DCIVERSION:X},0 TO ,v%\nBPUT#o%,STR$(v%)')
    assert out == str(DCI_VERSION), f"{mem_size}MB: DCIVersion returned {out!r}"


@pytest.mark.emulator
def test_swi_inquire_reports_features(guest_at_ram):
    """EtherRPCEm_Inquire reports the driver's feature bitmap for unit 0."""
    guest, mem_size = guest_at_ram
    out = _basic(guest, f'SYS &{SWI_INQUIRE:X},0,0 TO ,,f%\nBPUT#o%,STR$~(f%)')
    assert out == f"{INQUIRE_FLAGS:X}", f"{mem_size}MB: Inquire returned &{out}"


@pytest.mark.emulator
def test_swi_rejects_bad_flags(guest_at_ram):
    """The SWIs validate their flags word rather than ignoring it.

    Exercises the driver's error path, and proves the SWI is really being
    decoded by the driver and not swallowed by an absent module.
    """
    guest, mem_size = guest_at_ram
    out = _basic(guest, f'SYS &{SWI_DCIVERSION:X},1 TO ,v%\nBPUT#o%,"no error"')
    assert out == f"ERR &{ERR_EINVAL:X}", f"{mem_size}MB: expected EINVAL, got {out!r}"
