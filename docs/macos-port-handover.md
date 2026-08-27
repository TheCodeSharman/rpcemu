# macOS port — handover

Written 2026-08-27. Everything below was done on `thecodesharman-macbookair`
(Darwin 24.5, arm64).

## How this started

A question about BBC BASIC style in `RiscPc/tools/video-source/ModeServ.bas`:
is `MODE "X320 Y256 C256 F50"` enough to make the parser redundant? Settling
that needs a RISC OS 3.70 guest, which needs RPCEmu, which did not build on
macOS. **The original question is still unanswered** — see the last section.

## Repo state (all pushed unless noted)

| Repo / branch | Commit | What |
|---|---|---|
| `rpcemu` `feature/macos` | `7123d5f` | the port + `RPCEMU_NETWORKING` for Darwin |
| `rpcemu` `feature/vidc-shutdown-join` | `cc58488` | video-thread shutdown fix |
| `rpcemu` `lab` | `2d7e2ea` | devenv, Makefile, setup-install, sources.json, FEATURES |
| `nix-config` `main` | `5dea769` | `trusted-users` via `environment.etc` |

**Not pushed:** `integration` is rebuilt locally (`103dc22`) but not force-pushed.
Their workflow is `git -C tree push --force-with-lease origin integration`; left
undone deliberately because it rewrites a shared branch.

`test/macos-vidcfix` is a local scratch branch. Don't push it.

## What is actually verified

- RISC OS 3.70 boots to a full desktop, 800×600, HostFS mounted, `!Boot` tree
  present, ~135 MIPS. Screenshot recipe below.
- Three consecutive boot → clean-Exit cycles, exit code 0, no crash reports.
- NAT survives a soak that previously killed it in ~20 s.
- HostCmd responds (`rpcemu-run -- Cat HostFS::HostFS.$` lists the tree).

## What is NOT verified

- **Networking actually working in the guest.** Only "no longer crashes". No
  DHCP lease or ping has been observed from inside RISC OS.
- **Modifier keys.** Cloverleaf added a whole `NSEvent.modifierFlags` layer
  (`keyboard_handle_modifier_keys`) because macOS delivers modifiers as a mask,
  not key events. We deliberately took only their *table* and kept upstream's
  stateless `keyboard_map_key`. Whether Qt populates `nativeVirtualKey()` for
  Shift/Ctrl/Alt on macOS is **untested**. If modifiers don't reach RISC OS,
  that's why.
- Anything on Linux. Every lab change is platform-conditional but none of it
  has been re-run on the Linux box.

## Open issues

1. **HostCmd wedges on `BASIC -load`.** Running
   `BASIC -load <file> { < <cmds> }` through `rpcemu-run` left BASIC in
   immediate mode inside the HostCmd callback and the gateway stopped
   responding — subsequent `Echo` timed out; only a restart cleared it. The
   `{ < ... }` redirection is likely mangled by `rpcemu-run` splitting it
   across argv. **Next thing to try** (was in progress when this was written):
   put the whole command in an Obey file and run `Obey <file>` instead —
   `hostfs/runtest,feb` is already written and ready.
2. **Window opens off-screen** — observed at `x=1435` and `x=-795` on a
   1440-wide display. Cosmetic but annoying; nothing looked at it yet.
3. **`reintegrate.sh` misreports a missing local branch as a disjointness
   conflict.** Cost an hour. It says "rework so the branches touch disjoint
   code" when the real cause can be that the branch isn't checked out locally.
4. **`PlingSystem.zip` / `BonusBinDev.zip` pins will expire again** — ROOL
   publishes no versioned variant. `sources.json` records what to check.

## Gotchas worth keeping

**Qt 5.15 `QMacStyle` segfaults on Darwin 24.5.** `drawNSViewInRect` →
`objc_msgSend` → `EXC_BAD_ACCESS`, the moment any dialog with a push button is
painted. The exit-confirmation box is enough. **Always pass `-style Fusion`** —
the generated `installs/*/run` does this on Darwin.

**macOS deduplicates crash reports.** `ls -t` on
`~/Library/Logs/DiagnosticReports/*rpcemu*` can hand you a stale one and send
you chasing a fixed bug. Sort by *filename* (they embed the timestamp) and
check the time actually matches the run.

**`lldb --batch ... -- <binary> <args>` fails here** with
`executable doesn't exist: '(empty)'`. Use `/usr/bin/sample <pid>` for hangs and
the `.ips` crash reports for crashes; both worked reliably.

**Screenshotting the emulator**: a full-screen `screencapture` catches whatever
is in front, and `System Events` reported the window position wrongly (`x=-635`
vs Quartz's `x=5`). What works:

```sh
nix-shell -p 'python3.withPackages(ps: [ps.pyobjc-framework-Quartz])' \
  --run "python3 -c \"
from Quartz import CGWindowListCopyWindowInfo, kCGWindowListOptionAll, kCGNullWindowID
for w in CGWindowListCopyWindowInfo(kCGWindowListOptionAll, kCGNullWindowID):
    if 'rpcemu' in str(w.get('kCGWindowOwnerName','')).lower() and w.get('kCGWindowName'):
        print(w.get('kCGWindowNumber'))\""
screencapture -x -o -l <windowid> out.png
```

**Driving the exit-confirm dialog**: the button *is* exposed to accessibility,
just nested — `button "Exit" of group 1 of window 1`. Enumerating only the
window's direct children finds nothing and looks like Qt not exposing titles.

**nixpkgs Qt5 output splitting**: `qmake` is in `qtbase.dev`; the platform
plugin (`libqcocoa.dylib`) is in `qtbase.bin`, *not* the default output; the
`qt_lib_multimedia.pri` that `QT += multimedia` resolves against is in
`qtmultimedia.dev`. All three are needed or you get, respectively, "qmake not
found", `Could not find the Qt platform plugin "cocoa" in ""`, and
`Unknown module(s) in QT: multimedia`.

## Where the MODE question stands

Established from source, not from running anything:

- RISC OS 3.70's ROM BASIC **does** accept `MODE <string>`: `Stmt2` at the
  `RO_3_70` tag prepends `"WimpMode "` and calls `OS_CLI`.
- `*WimpMode` → `Wimp_SetMode`, which at `RO_3_70` only calls `int_setmode`
  when `taskcount > 0`; otherwise it records the mode "for next time".
- A single-tasking program launched **from the desktop** leaves all Wimp tasks
  registered, so `taskcount > 0` and the mode does change. MS's original claim
  that it works was right; my first reading of it was wrong.
- The remaining open question is only the `taskcount == 0` case — `*BASIC` from
  a bare supervisor prompt with the desktop never started.
- RISC OS 3.70's kernel has `ScreenModeReason_Limit = 4`, so there is no
  `OS_ScreenMode 15`; modern BASIC's string path does not exist on this ROM.

`hostfs/modetest,fff` and `hostfs/modein,fff` are already written and contain
the test (reads mode vars, does `MODE "X320 Y256 C256 F50"`, reads them back,
prints `RESULT before= after= err=`). Blocked only on issue 1 above.

## For ModeServ itself

Two things survive from the original review, independent of all the above:

- The four globals `px%/py%/pd%/pr%` are a hidden return channel; BASIC V has
  `RETURN` parameters for exactly this, and they work on `DEF FN` at `RO_3_70`.
  MS's reasoning was the library-isolation one: `LIBRARY "PatLib"` shares one
  global namespace, and PatLib already exports `W% H% UX% UY% CX% CY% ...`.
- PatLib has global `CX%/CY%/R%` *and* local `cx%/cy%/r%` holding the same
  values, distinguished only by case. That is a latent bug waiting to happen.

Neither change has been made.
