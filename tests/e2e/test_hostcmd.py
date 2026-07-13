"""HostCmd end-to-end: drive guest RISC OS commands from the host via rpcemu-run."""

import subprocess

import pytest


# ---------------------------------------------------------------- live tier ---

@pytest.mark.emulator
def test_command_runs_and_returns_zero(guest):
    rc, out = guest.run("Echo hello-e2e")
    assert rc == 0
    assert "hello-e2e" in out


@pytest.mark.emulator
def test_cat_streams_hostfs_listing(guest):
    rc, out = guest.run("Cat HostFS::HostFS.$")
    assert rc == 0
    assert "HostFS::HostFS.$" in out  # the directory-listing header


@pytest.mark.emulator
def test_error_command_reports_nonzero_and_message(guest):
    rc, out = guest.run("Type HostFS::HostFS.$.NoSuchFileForE2E")
    assert rc != 0                      # RISC OS Sys$ReturnCode propagated
    assert "not found" in out.lower()   # error text was captured + streamed


@pytest.mark.emulator
def test_session_persists_across_connections(guest):
    """Each rpcemu-run is a separate connection, but the guest RISC OS session
    (current directory) persists — set it in one call, observe it in the next."""
    rc1, _ = guest.run("Dir HostFS::HostFS.$")
    assert rc1 == 0
    rc2, out = guest.run("Cat")            # cat the CSD, no explicit path
    assert rc2 == 0
    assert "CSD" in out and "HostFS" in out


# ------------------------------------------------------------- offline tier ---

def test_connect_tcp_rejects_overlong_host(rpcemu_run_bin):
    """The connect_tcp fix: an over-long host errors instead of silently
    truncating and connecting to the wrong place."""
    host = "h" * 300
    r = subprocess.run(
        [str(rpcemu_run_bin), "--tcp", f"{host}:15590", "--", "Cat"],
        capture_output=True, text=True, timeout=10,
    )
    assert r.returncode != 0
    assert "too long" in (r.stderr + r.stdout).lower()


def test_help_exits_zero(rpcemu_run_bin):
    r = subprocess.run(
        [str(rpcemu_run_bin), "--help"], capture_output=True, text=True, timeout=10
    )
    assert r.returncode == 0
    assert "rpcemu" in (r.stdout + r.stderr).lower()
