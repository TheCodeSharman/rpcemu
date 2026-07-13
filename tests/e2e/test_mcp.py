"""MCP server end-to-end: the tools an agent uses to drive the guest.

Offline tests exercise the host-side logic (tool registration, HostFS file tools,
guards); the live tests drive a booted guest through riscos_run and prove the full
host<->guest file loop.
"""

import asyncio
import shutil

import pytest


# ------------------------------------------------------------- offline tier ---

def test_all_tools_register(load_mcp, tmp_path):
    m = load_mcp(RPCEMU_HOSTFS_DIR=tmp_path, RPCEMU_HOSTCMD_SOCKET="")
    tools = asyncio.run(m.mcp.list_tools())
    names = {t.name for t in tools}
    assert "riscos_run" in names
    assert {"riscos_read_file", "riscos_write_file", "riscos_list"} <= names
    assert len(tools) == 18


def test_file_tools_roundtrip_offline(load_mcp, tmp_path):
    m = load_mcp(RPCEMU_HOSTFS_DIR=tmp_path, RPCEMU_HOSTCMD_SOCKET="")
    written = m.riscos_write_file("work/hello", 'PRINT "hi"\n', "ffb")
    assert written.endswith("work/hello,ffb")           # ,xxx filetype suffix
    assert m.riscos_read_file("work/hello") == 'PRINT "hi"\n'
    assert "hello,ffb" in m.riscos_list("work")


def test_path_escape_guard(load_mcp, tmp_path):
    m = load_mcp(RPCEMU_HOSTFS_DIR=tmp_path, RPCEMU_HOSTCMD_SOCKET="")
    with pytest.raises(m.HostCmdError):
        m.riscos_write_file("../escape", "x")


def test_run_without_socket_errors_gracefully(load_mcp, tmp_path):
    m = load_mcp(RPCEMU_HOSTFS_DIR=tmp_path, RPCEMU_HOSTCMD_SOCKET="")
    with pytest.raises(m.HostCmdError):
        m.riscos_run("Cat")


# ---------------------------------------------------------------- live tier ---

@pytest.mark.emulator
def test_riscos_run_on_guest(mcp):
    r = mcp.riscos_run("Cat HostFS::HostFS.$")
    assert r["return_code"] == 0
    assert "HostFS::HostFS.$" in r["output"]


@pytest.mark.emulator
def test_host_guest_file_loop(mcp, guest):
    """MCP writes a file host-side; the GUEST reads it via riscos_run; MCP reads
    it back and lists it. Exercises the whole HostFS<->HostCmd bridge."""
    m = mcp
    try:
        m.riscos_write_file("E2ETest/msg", "hello-from-mcp\n", "fff")

        r = m.riscos_run("Type HostFS::HostFS.$.E2ETest.msg")
        assert r["return_code"] == 0
        assert "hello-from-mcp" in r["output"]          # guest sees the host write

        assert m.riscos_read_file("E2ETest/msg") == "hello-from-mcp\n"
        assert any("msg" in entry for entry in m.riscos_list("E2ETest"))
    finally:
        shutil.rmtree(guest.hostfs / "E2ETest", ignore_errors=True)
