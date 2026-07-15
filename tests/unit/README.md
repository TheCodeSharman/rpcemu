# IDE unit / regression tests (Criterion)

Behaviour tests for the IDE device (`feature/ide-fix`): the LBA-vs-CHS /
`skip512` addressing bug that corrupted data, the out-of-bounds sector guard,
the IDENTIFY geometry/capacity reporting, the ABRT-not-`fatal()` command
handling, and the soft-reset diagnostic code RISC OS 5 needs to detect the drive.

## Running

```bash
make -C tests/unit        # or, from the repo top level:  make test-unit
make -C tests/unit ARGS=--verbose
```

Requires the project **devenv** (provides `criterion` + `gcc`) — run inside it,
e.g. `direnv exec /path/to/rpcemu make test-unit`, or from an interactive shell
in the repo. Run from an **integration checkout** so `src/ide.c` carries the fix.

## How it works

`test_ide.c` drives the emulated drive **only through its public register
interface** (`ide.h`: `writeide`/`readide`/`writeidew`/`readidew`/`callbackide`/
`resetide`) — the same registers RISC OS pokes — and asserts on what a guest
observes: the status/error registers, the data read back, and the backing disc
file. `src/ide.c` is compiled and linked as a **separate translation unit** (it
is *not* `#include`d), so the tests cannot reach its `static` internals: they
test **behaviour, not implementation**, and survive refactoring of `ide.c`.

A small harness creates a temp `hd4.hdf`, attaches it via the module's own
`resetide()`, and drives ATA IDENTIFY / READ / WRITE / soft-reset by poking
registers. A few hardware globals (`iomd`, `config`, `updateirqs`, `rpclog`,
`error`, `fatal`, `arm_dump`, `rpcemu_get_datadir`) are stubbed.

Because every test goes through the register interface — which exists in both
the unfixed and fixed `ide.c` — the whole suite compiles and runs against
either, with **no `#ifdef` gating**. It is a uniform red→green guard:

- Against the fix: **5/5 pass**.
- Against a plain `base` `ide.c`: **all 5 red** — IDENTIFY reports the 32 GB
  placeholder / no LBA; an LBA access on a boot-block image lands on the wrong
  sector; an out-of-bounds read silently zero-fills instead of IDNF-ing; the
  soft reset posts `0` instead of `0x01`; and an unimplemented command
  **crashes** the process (`fatal()` → `abort()`).
