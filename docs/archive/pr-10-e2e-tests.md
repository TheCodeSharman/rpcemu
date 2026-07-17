# PR #10 — E2E tests: pytest suite exercising the HostCmd + MCP agent-drive stack

> **Archived.** This branch **dissolved into `lab`** during the 2026-07-17 reorg;
> it was never an upstream delta. Its content is now `tests/e2e/`.
>
> | | |
> | --- | --- |
> | branch | `feature/e2e-tests` (deleted; preserved as tag `archive/20260717/feature-e2e-tests`) |
> | PR | <https://github.com/TheCodeSharman/rpcemu/pull/10> (closed, not merged) |
> | opened | 2026-07-13 |
> | closed | 2026-07-17 |
>
> Kept because the PR description is where this project records the *why* and the
> journey — and that rationale explains code that now lives here, on `lab`, while
> the PR itself lives only on GitHub. See `docs/reorg-plan.md`.

---

^[[0mdirenv: loading ~/Projects/rpcemu/.envrc
Adds an end-to-end pytest suite under `tests/e2e/` that exercises the
agent-drive stack (HostCmd + the MCP server) against a real RISC OS guest.

## What it covers
- **`test_hostcmd.py`** — the HostCmd wire path: connect to the socket, run
  guest `*`-commands via `rpcemu-run`, assert streamed output and return codes.
- **`test_mcp.py`** — the MCP server tools: `riscos_run` plus the HostFS
  file read/write/list tools, host↔guest both directions.

## Two tiers
- **Offline** (default) — runs without a booted emulator; 6 tests.
- **Live** (`@pytest.mark.emulator`) — needs a running guest. Attach to an
  existing instance via `RPCEMU_HOSTCMD_SOCKET` / `RPCEMU_HOSTFS_DIR`, or let
  the suite boot one via `RPCEMU_TEST_INSTALL`.

## Running
Runs from its own Makefile, self-contained (Nix-provisioned pytest + mcp) — `make -C tests/e2e`, or `make test-e2e` at the repo top level. Examples:
- `make -C tests/e2e ARGS='-m "not emulator"'` — offline tier only.
- `make -C tests/e2e` — full suite (attach/boot a guest first).

## Validation
- Offline tier: **6 passed** from a fresh integration checkout.
- Full suite (attached to a booted RISC OS 3.71 guest): **12 passed** in the
  prior session.

## Notes
- This feature only *runs* meaningfully from an `integration` checkout, since
  it needs `src/tools` (rpcemu-run) and `tools/mcp` present together — hence it
  is wired into `tools/reintegrate.sh` (integration = base + 9 features).
- Pure additive: `git diff base feature/e2e-tests` is `tests/e2e/**` only; no
  emulator C source is touched.
