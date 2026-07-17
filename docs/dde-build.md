# Building RISC OS software with the DDE, inside RPCEmu

The programs in [`riscos-progs/`](../riscos-progs/) (`EtherRPCEm`, `HostCmd`,
`HostFS`, `SyncClock`, …) are RISC OS modules built with Acorn's toolchain —
`cc` (Norcroft), `objasm`, `cmhg`, `Link`, driven by `amu`. There is no Linux
port of that toolchain, so we build them **inside** an emulated machine and
drive it from the host over the [HostCmd](hostcmd.md) socket:

```
edit on the host  ->  amu on the guest  ->  read the result on the host
```

This gives an ordinary edit/build/test loop against the real Acorn compiler.

## You need a *modern* DDE

Use **ROOL DDE 30 or later** (DDE31d, 2024, is known good). It is commercial
software from [RISC OS Open](https://www.riscosopen.org/); supply your own copy.

**The 1998 Acorn C/C++ that ships in the RPCEmu starter pack will not do.** Its
Norcroft is `5.09`, a C89 compiler:

| Problem | Consequence |
| --- | --- |
| no `<stdint.h>` | any source using `uint32_t` etc. fails to compile |
| no C99 `inline` | `static inline` is a syntax error |
| only 26-bit `o.stubs` | **RISC OS 5 is 32-bit only** — a module linked with these may not load at all |

You can bodge past the first two with a fake `stdint` and `#define inline`, but
not the third, and the result is not comparable to a real build. Don't.

## Which machine to build on

Build on a **RISC OS 5** install (e.g. `installs/riscos-530`). The DDE's
`!SetPaths.SetUp` requires SharedCLibrary **5.34+**; RISC OS 5.30 ships 6.23, so
nothing needs softloading and the `!RomPatch` dance (which exists for RISC OS 4)
is not used. RISC OS 3.7 cannot run DDE31 at all.

The machine needs `poduleroms/hostcmd,ffa` so the HostCmd socket exists.

## Setup (once per install)

```bash
tools/dde/dde-setup.sh ~/path/to/'ROOL DDE31d (2024)(RISC OS Open).zip' installs/riscos-530
```

RISC OS zips store each file's type in an Acorn extra-field rather than the
filename, so a plain `unzip` silently drops every filetype and nothing is
runnable. The script uses [`roextract.py`](../tools/riscos-boot-build/roextract.py)
to recover types and write HostFS `,xxx` names. A correct install has
`DDE31/!SetPaths/Lib32/cc,ff8` (~420 KB, the 32-bit Norcroft).

## Building

Boot the machine, then:

```bash
make -C src/tools                                    # once: builds rpcemu-run
(cd installs/riscos-530 && ./run) &                  # boot; creates hostcmd.sock
tools/dde/dde-amu.sh installs/riscos-530 Build.EtherRPCEm
```

Put the project on the machine's HostFS drive (`installs/<name>/hostfs/Build/…`)
and edit it from the host; `amu` runs on the guest.

`dde-amu.sh` sets only what a command-line build needs — the `Lib32` tools on
`Run$Path`, and the `APCS-32` exports on `C$Path` — mirroring what the DDE's own
`!SetPaths.SetPaths` does. It deliberately does not run `SetPaths` itself: that
is an Obey file that also wants the Filer.

To run a tool by hand:

```bash
src/tools/rpcemu-run --socket installs/riscos-530/hostcmd.sock -- cc
```

## Gotchas

- **`C:o.stubsg` does not exist.** Several project Makefiles (including
  `EtherRPCEm`'s) link against it, but it is in neither the DDE nor ROOL's
  shared `Makefiles`. ROOL's `ModuleLibs` prescribes `CLIB = CLIB:o.stubs` for
  modules. `dde-amu.sh` therefore drops a copy of the APCS-32 `o.stubs` into the
  project's `o/` as `stubsg`, rather than patching the Makefile or the DDE.
  (`stubsg` is plausibly a debug-enabled stubs from the full RISC OS source
  tree's CLib build — the shipped `EtherRPCEm` is ~3 KB larger than ours.)
- **`amu` cannot spawn `cc` over HostCmd — UNRESOLVED.** `amu` runs `cmhg`,
  `objasm`, `bin2c` and `Link` fine, but when it reaches `cc` (by far the
  largest tool, ~420 KB) it dies with:

  ```
  cc -depend !Depend -IC: -throwback -zM -Wp -c -o o.Module c.Module
  AMU: *** No writable memory at this address ***
  ```

  The **identical** `cc` command run directly over HostCmd works. So the tools
  and paths are right; `amu` + `cc` simply do not both fit in the application
  space a HostCmd command gets. Ruled out: it is *not* a missing `DDEUtils`
  (the install's `!System` already has 1.75, and loading it explicitly does not
  help), and `WimpSlot` (plain, `-min/-max`, `-next`) makes no difference.
  The DDE itself runs `amu` via the FrontEnd module inside a **TaskWindow** with
  a `1024k` slot (`Apps/DDE/!AMU/Desc`: `wimpslot 1024k`, `-desktop`), so that is
  the environment it is designed for. But that is *not* the explanation, and it
  is not available to us either: a TaskWindow is still ordinary application
  space at `&8000` — a Wimp task with its own slot, not a different memory model
  — and trying to start one over HostCmd fails outright:

  ```
  TaskWindow "amu" -wimpslot 1024k -quit
  Window Manager is currently in use
  ```

  because HostCmd issues `OS_CLI` from a module while the desktop is running.
  Worth trying next: a machine that boots to the **command line** rather than the
  desktop, which is how you would build from the CLI on real hardware — then
  application space is not some Wimp task's slot.

  **Working recipe until this is solved** — run `cc` yourself, then let `amu`
  do the rest (it then finds `o.Module` up to date and proceeds to `Link`):

  ```bash
  RUN="src/tools/rpcemu-run --socket installs/riscos-530/hostcmd.sock --"
  $RUN Dir HostFS::HostFS.\$.Build.EtherRPCEm
  $RUN cc -depend !Depend -IC: -throwback -zM -Wp -c -o o.Module c.Module
  tools/dde/dde-amu.sh installs/riscos-530 Build.EtherRPCEm
  ```

  This is how the verified `EtherRPCEm` build below was produced.
- **The DDE's `Developer/!System` does not need merging** into a machine built
  by `tools/setup-install.sh`. Verified: every module it carries is already
  present at an equal-or-newer version (`DDEUtils 1.75 == 1.75`), and its
  `!System` plumbing is byte-identical to ROOL's. If you build on a machine
  whose `!System` lacks `DDEUtils`, merge it — but restrict it to `Modules/`.
  Note `build.py`'s `merge_system()` is *not* a general `!SysMerge`: real
  `!SysMerge` merges modules by version and leaves the `!System` plumbing alone,
  whereas `merge_system()` prefers the source for files with no comparable
  version — deliberate for the boot builder (where PlingSystem *is* the
  authoritative `!System`), wrong for merging a DDE in.
- The project Makefiles are **standalone** — they do not include ROOL's shared
  `Makefiles` fragments (`CModule`, `ModuleLibs`, …), even though the DDE ships
  them.
- The module's help string is stamped with the **guest's** clock, so a rebuild
  will not be byte-identical to a build made on another date.

## Worked example: EtherRPCEm

```bash
cp -a riscos-progs/EtherRPCEm installs/riscos-530/hostfs/Build/EtherRPCEm
# cc by hand (see the amu gotcha above), then amu for cmhg/objasm/Link:
RUN="src/tools/rpcemu-run --socket installs/riscos-530/hostcmd.sock --"
$RUN Dir HostFS::HostFS.$.Build.EtherRPCEm
$RUN cc -depend !Depend -IC: -throwback -zM -Wp -c -o o.Module c.Module
tools/dde/dde-amu.sh installs/riscos-530 Build.EtherRPCEm
cp installs/riscos-530/hostfs/Build/EtherRPCEm/EtherRPCEm,ffa netroms/
```

Verified: DDE31d rebuilds `EtherRPCEm 1.05` from unmodified source, and the
result is **behaviourally identical** to the shipped `netroms/EtherRPCEm,ffa` —
including reproducing the RISC OS 5.30 boot data abort at `&FC16AAB8` that only
appears below 256 MB. That equivalence is the point: it makes a change to the
driver a controlled experiment.
