# PR #14 — IDE tests: black-box behaviour tests via the register interface

> **Archived.** This branch **dissolved into `lab`** during the 2026-07-17 reorg;
> it was never an upstream delta. Its content is now `tests/unit/`.
>
> | | |
> | --- | --- |
> | branch | `feature/ide-tests` (deleted; preserved as tag `archive/20260717/feature-ide-tests`) |
> | PR | <https://github.com/TheCodeSharman/rpcemu/pull/14> (closed, not merged) |
> | opened | 2026-07-14 |
> | closed | 2026-07-17 |
>
> Kept because the PR description is where this project records the *why* and the
> journey — and that rationale explains code that now lives here, on `lab`, while
> the PR itself lives only on GitHub. See `docs/reorg-plan.md`.

---

## What

Behaviour (black-box) regression tests for the IDE fixes (#13), driven **only through the device's public register interface** (`ide.h`: `writeide`/`readide`/`writeidew`/`readidew`/`callbackide`/`resetide`) — the same registers RISC OS pokes. `src/ide.c` is compiled and linked as a **separate translation unit** (not `#include`d), so the tests reach none of its `static` internals: they assert observable behaviour (status/error registers, data read back, the backing disc file), not implementation, and survive refactoring of `ide.c`.

A small harness creates a temp `hd4.hdf`, attaches it via the module's own `resetide()`, and drives ATA IDENTIFY / READ / WRITE / soft-reset by poking registers.

## No `#ifdef` gating — uniform red→green

Because everything goes through the register interface (present in both the unfixed and fixed `ide.c`), the whole suite compiles and runs against either:

- Against the fix: **5/5 pass**.
- Against a plain `base` `ide.c`: **all 5 red** — IDENTIFY reports the ~32 GB placeholder / no LBA; an LBA access on a boot-block image lands on the wrong sector; an out-of-bounds read silently zero-fills instead of IDNF-ing; the soft reset posts `0` instead of `0x01`; and an unimplemented command **crashes** the process (`fatal()` → `abort()`).

The tests:

| test | behaviour asserted |
|---|---|
| `identify_reports_real_geometry_and_28bit_lba` | real cylinder count + 28-bit LBA capacity, LBA-supported bit set, LBA48 **not** advertised |
| `lba_access_hits_the_correct_sector_on_a_boot_block_image` | LBA read *and* write on a skip512 image hit file sector N+1 (the corruption bug), verified against the backing file |
| `access_past_end_of_disc_is_rejected_with_idnf` | OOB read/write → IDNF, not zero-fill/extend |
| `unimplemented_command_aborts_instead_of_crashing` | NOP + unknown opcode → ABRT, no crash |
| `soft_reset_reports_diagnostic_passed` | SRST posts error `0x01` (so RISC OS 5 detects the drive) |

## Run

```bash
make -C tests/unit        # or, from the repo top level:  make test-unit
make -C tests/unit ARGS=--verbose
```

Self-contained (the devenv provides gcc + Criterion). Supersedes the earlier white-box suite that `#include`d `ide.c` to reach `static` functions.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
