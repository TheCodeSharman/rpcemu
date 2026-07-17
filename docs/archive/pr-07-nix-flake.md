# PR #7 — Nix flake: udp-broadcast-relay-redux, freeway-net helper, rpcemu-freeway module

> **Archived.** This branch **dissolved into `lab`** during the 2026-07-17 reorg;
> it was never an upstream delta. Its content is now `flake.nix`, `flake.lock`, `nix/`, `tools/freeway-net.sh`.
>
> | | |
> | --- | --- |
> | branch | `feature/nix-flake` (deleted; preserved as tag `archive/20260717/feature-nix-flake`) |
> | PR | <https://github.com/TheCodeSharman/rpcemu/pull/7> (closed, not merged) |
> | opened | 2026-07-13 |
> | closed | 2026-07-17 |
>
> Kept because the PR description is where this project records the *why* and the
> journey — and that rationale explains code that now lives here, on `lab`, while
> the PR itself lives only on GitHub. See `docs/reorg-plan.md`.

---

## What this patch does

**Nix packaging + host tooling** for the Freeway/ShareFS bridging that lets an
emulated RISC OS talk to the real RISC PC (and other Acorn Access hosts) on the
LAN. Companion to **`feature/iptunnel-persistent-tap`**.

### Contents
- **`flake.nix` / `flake.lock`** — the flake entry points.
- **`nix/udp-broadcast-relay-redux.nix`** — packages the relay that forwards the
  Acorn Access **UDP discovery broadcasts** across the tap ↔ LAN boundary (they
  don't cross an L3 hop otherwise).
- **`nix/rpcemu-freeway.nix`** — a NixOS module that wires up the persistent tap,
  the broadcast relay, and **proxy-ARP scoped to the LAN subnet** (so the emulated
  machine appears on the physical network without leaking ARP for the whole world).
- **`tools/freeway-net.sh`** — an imperative helper that sets the same thing up
  outside NixOS.

### Nature of the diff
Packaging + shell/Nix only — **no emulator source changes**. Project infra, not an
upstream submission.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
