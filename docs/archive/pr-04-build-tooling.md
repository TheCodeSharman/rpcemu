# PR #4 — Build tooling: universal !Boot builder + setup-install.sh + CMOS template

> **Archived.** This branch **dissolved into `lab`** during the 2026-07-17 reorg;
> it was never an upstream delta. Its content is now `tools/{dde,cmos,riscos-boot-build,setup-install.sh}`, `docs/dde-build.md`, and the `Makefile`/`CLAUDE.md` edits it had been carrying.
>
> | | |
> | --- | --- |
> | branch | `feature/build-tooling` (deleted; preserved as tag `archive/20260717/feature-build-tooling`) |
> | PR | <https://github.com/TheCodeSharman/rpcemu/pull/4> (closed, not merged) |
> | opened | 2026-07-13 |
> | closed | 2026-07-17 |
>
> Kept because the PR description is where this project records the *why* and the
> journey — and that rationale explains code that now lives here, on `lab`, while
> the PR itself lives only on GitHub. See `docs/reorg-plan.md`.

---

## What this patch does

Adds the **install/build tooling** used to turn official RISC OS sources into
ready-to-run emulator installs. It is deliberately kept on a feature branch **off
`base`** (not in the infra layer) so it isn't dragged onto every other branch.

### Contents
- **`tools/riscos-boot-build/`** — a **bundle-free universal `!Boot` builder**
  (`build.py`). It downloads and **sha256-verifies** official RISC OS sources
  (`sources.json`), then assembles a HostFS disc tree that boots on **RISC OS
  3.7 / 4.02 / 5.x**. Boot-compat patches are on by default. Helpers:
  `roextract.py` (archive → HostFS `,xxx`-typed extraction) and `rozip.py`.
  Vendored, redistributable packages (`PackMan`, `PkgDisc`, `URLFetch`,
  `UnplugSwap`) are checked in so assembly works offline.
- **`tools/setup-install.sh`** — assembles `installs/<name>/` from a built disc
  tree + a ROM + a CMOS template: HostFS boot, with the HostFS `poduleroms`
  (`hostfs,ffa` + `hostfsfiler,ffa` + `SyncClock,ffa`).
- **`tools/cmos/riscpc-hostfs.ram`** — a known-good HostFS-boot RiscPC CMOS
  template (256 bytes).

### Nature of the diff
Pure tooling + vendored data — **no emulator source changes**. Not intended for
upstream submission (it's our project infra); it lives as a feature branch purely
so `integration` can pick it up via `reintegrate.sh`.

### Cleanup noted (self-review)
This branch currently carries an accidentally-committed
`tools/riscos-boot-build/__pycache__/roextract.cpython-313.pyc`. It should be
removed and `__pycache__/` gitignored in a follow-up.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
