# PR #9 — MCP server: drive a RISC OS guest from an MCP client (riscos_run + HostFS file tools)

> **Archived.** This branch **dissolved into `lab`** during the 2026-07-17 reorg;
> it was never an upstream delta. Its content is now `tools/mcp/`.
>
> | | |
> | --- | --- |
> | branch | `feature/spork-mcp-server` (deleted; preserved as tag `archive/20260717/feature-spork-mcp-server`) |
> | PR | <https://github.com/TheCodeSharman/rpcemu/pull/9> (closed, not merged) |
> | opened | 2026-07-13 |
> | closed | 2026-07-17 |
>
> Kept because the PR description is where this project records the *why* and the
> journey — and that rationale explains code that now lives here, on `lab`, while
> the PR itself lives only on GitHub. See `docs/reorg-plan.md`.

---

## What this patch does

Harvests the standalone **Python MCP server** from `andrewtimmins/rpcemu-extended`
("Spork Edition") so an MCP client (Claude Code, Claude Desktop, the API's MCP
connector) can **drive a RISC OS machine running under RPCEmu** — run guest CLI
commands and read/write/list files on the HostFS drive.

### Contents (pure Python + docs — no C, no build changes)
- **`tools/mcp/rpcemu_mcp.py`** — vendored **verbatim**; port-agnostic (reads only
  env vars), registers all **18 tools**.
- **`tools/mcp/{README.md, requirements.txt, mcp.json.example}`**.
- **`docs/hostcmd.md`** — the HostCmd protocol/quick-start, **adapted to this
  fork's `make`/qmake build** (Spork's `./build.sh --podules` → `make` +
  `make -C src/tools`; dropped the non-existent `rpcemu-shell`).

### What works today
On top of **`feature/spork-hostcmd`**:
- **`riscos_run`** — run a guest command over the HostCmd socket.
- **`riscos_read_file` / `write_file` / `list`** — **pure host-side** on the HostFS
  directory; they need no emulator socket at all.

### Inert until later branches (documented in the README / env-var table)
- **`riscos_debug_*`** (10 tools) — need the **DebugCmd** socket, pending
  `feature/spork-debugcmd-inspect`. `docs/debugcmd.md` is deferred to that branch.
- **VNC** screen/input tools (4) — pending a VNC server port.

### Reproducible runtime — note on the diff
The `mcp` Python dependency is provided from Nix on **`base`'s `devenv.nix`**
(`python3.withPackages [ mcp ]`), *not* on this branch — chosen over pip because
pydantic-core wheels are unreliable on NixOS. Keeping it on `base` leaves this
branch's `git diff base` **pure Python + docs** (still mailable). The tool's own
`requirements.txt` remains the portable, upstream-facing pip story.

### Verified
18 tools register; the host-side file tools work (correct `,ffb` filetype
suffixing, read/list); the path-escape guard holds; `riscos_run` errors gracefully
with no socket; `integration` builds clean.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
