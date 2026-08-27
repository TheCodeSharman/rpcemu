# macOS port — handover

Written 2026-08-27, updated 2026-08-28. Everything below was done on
`thecodesharman-macbookair` (Darwin 24.5, arm64).

## How this started

A question about BBC BASIC style in `RiscPc/tools/video-source/ModeServ.bas`:
is `MODE "X320 Y256 C256 F50"` enough to make the parser redundant? Settling
that needs a RISC OS 3.70 guest, which needs RPCEmu, which did not build on
macOS. **Answered on 2026-08-28: yes** — see the last section.

## Repo state (all pushed unless noted)

| Repo / branch | Commit | What |
|---|---|---|
| `rpcemu` `feature/macos` | `129a3f7` | the port, `RPCEMU_NETWORKING`, modifier keys |
| `rpcemu` `feature/vidc-shutdown-join` | `cc58488` | video-thread shutdown fix |
| `rpcemu` `lab` | `2d7e2ea` | devenv, Makefile, setup-install, sources.json, FEATURES |
| `nix-config` `main` | `5dea769` | `trusted-users` via `environment.etc` |

**Not pushed:** `integration` is rebuilt locally (`ef78dab`, reintegrated
2026-08-28 to pick up the modifier-key fix) but not force-pushed. Their workflow
is `git -C tree push --force-with-lease origin integration`; left undone
deliberately because it rewrites a shared branch.

`RiscPc` `feature/modeserv-mode-string` (`d3bff54`) carries the ModeServ change
the MODE question produced. Not pushed.

`test/macos-vidcfix` is a local scratch branch. Don't push it.

## What is actually verified

- RISC OS 3.70 boots to a full desktop, 800×600, HostFS mounted, `!Boot` tree
  present, ~135 MIPS. Screenshot recipe below.
- Three consecutive boot → clean-Exit cycles, exit code 0, no crash reports.
- NAT survives a soak that previously killed it in ~20 s.
- HostCmd responds (`rpcemu-run -- Cat HostFS::HostFS.$` lists the tree), and
  drives BASIC end to end — see the resolved issue 1 below.
- **Modifier keys reach the guest** (2026-08-28). Shift, Ctrl, Alt and Caps Lock
  all arrive; confirmed by holding Shift through a boot.

## What is NOT verified

- **Networking actually working in the guest.** Only "no longer crashes". No
  DHCP lease or ping has been observed from inside RISC OS.
- Anything on Linux. Every lab change is platform-conditional but none of it
  has been re-run on the Linux box.

## Open issues

1. **Window opens off-screen** — observed at `x=1435` and `x=-795` on a
   1440-wide display. Cosmetic but annoying; nothing looked at it yet.
2. **`reintegrate.sh` misreports a missing local branch as a disjointness
   conflict.** Cost an hour. It says "rework so the branches touch disjoint
   code" when the real cause can be that the branch isn't checked out locally.
3. **`PlingSystem.zip` / `BonusBinDev.zip` pins will expire again** — ROOL
   publishes no versioned variant. `sources.json` records what to check.

## Resolved since

**HostCmd wedging on `BASIC -load` (was issue 1).** The redirection was a red
herring. When the desktop is up, HostCmd runs the command in a TaskWindow child
(`hostcmd.s`, `tw_prefix`), and a BASIC that reaches the `>` prompt sits there
forever because nothing sends it TaskWindow input — no Morio, so the gateway
never reports the command finished. The fix is to make BASIC incapable of
reaching a prompt: **`BASIC -quit <file>`** runs the program and exits, needs no
stdin at all, and returns cleanly even on an untrapped error. `-quit` and
`-load` both accept a *text* file and tokenise it, so the test can stay
plain text.

Two more things that cost time, worth knowing before writing another guest test:

- **Don't redirect BASIC's output to a file across a mode change.** `{ > file }`
  catches the VDU sequences the mode change emits and the result lines come out
  interleaved and out of order. Accumulate results in an array and write them
  with `OPENOUT`/`BPUT#` at the end — file I/O is immune, and the host can read
  the file straight out of `hostfs/` afterwards.
- **`ON ERROR LOCAL ... :ENDPROC` is "badly nested"** and kills the run before it
  writes anything. Keep error handlers at the top level.

**Modifier keys (was under "not verified").** Shift, Alt and Caps Lock never
reached the guest; `keyboard_macosx.c` simply had no table entries for them, and
`kVK_Control` being the only modifier present is exactly why Ctrl alone worked.
No `NSEvent.modifierFlags` layer is needed: Qt's cocoa plugin already turns each
change of the mask back into a QKeyEvent in `-[QNSView flagsChanged:]` and passes
`[nsevent keyCode]` through as `nativeVirtualKey`. Caps Lock needed a special
case in `main_window.cpp` because macOS reports it as a *latch*. One Qt limit
survives: `flagsChanged:` derives press-vs-release from a delta on the whole
mask, so the second of two modifiers sharing a mask bit produces no event.

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

## The MODE question, answered

`MODE "X320 Y256 C256 F50"` works on RISC OS 3.70 and the ModeServ parser is
redundant. Measured in the guest, not reasoned about.

The thing that made this look hard: with the guest's stock monitor definition
the small mode was **refused**, and the two call paths refused it in different
words —

| call | AKF60 loaded | AKF50 loaded |
|---|---|---|
| `MODE "X640 Y480 C256 F60"` | ok | ok |
| `MODE "X320 Y256 C256 F50"` | `This screen mode is unsuitable for displaying the desktop` | ok → 320×256 |
| `OS_ScreenMode 0`, selector 320×256 F50 | `Screen mode not available` (&1ED) | ok → 320×256 |
| `OS_ScreenMode 0`, selector 320×256 F-1 | ok → 320×256 | ok → 320×256 |

**It is the monitor definition, every time.** Both paths were reporting the same
"this mode is not in the MDF" failure, the Wimp phrasing it as unsuitable for the
desktop and the kernel as not available. Swapping AKF60 for AKF50 flips which
frame rates exist — F70 works under AKF60 and fails under AKF50, F50 vice versa.
It has nothing to do with single- versus multi-tasking, and nothing to do with
`taskcount`; that whole line of enquiry was chasing the wrong variable.

The install selects the MDF in `hostfs/!Boot/Choices/Boot/PreDesk/Configure/`:
`VRAM,feb` loads AKF50, `NoVRAM,feb` loads AKF60. Note that this lives in the
HostFS tree, **not** in CMOS, so a change to it survives even an unclean kill of
the emulator — and conversely, `*Status MonitorType` reporting `Auto` tells you
nothing about which MDF is actually loaded.

The routing claim in the previous draft stands — the refusal was worded by the
Wimp, so `MODE <string>` really does reach `Wimp_SetMode`. What was wrong was the
conclusion drawn from it: that this makes the string form unable to reach the
small modes the bench cares about. Under AKF50 it reaches 320×256 perfectly
well, and the Wimp raises no objection.

Tests are left in `installs/riscos-371/hostfs/`: `modetst3,fff` (string vs
selector, both mode strings and the `OS_ScreenMode 0` block) and `modetst4,fff`
(frame-rate sweep at 320×256, reporting the error number and message). Each has
a `runtst<N>,feb` Obey wrapper; run one with

    rpcemu-run --socket hostcmd.sock -- Obey HostFS::HostFS.$.runtst3

and read the answer out of `hostfs/mode<N>out` on the host side.

## For ModeServ itself

Two things survive from the original review, independent of all the above:

- The four globals `px%/py%/pd%/pr%` were a hidden return channel out of
  `FNparse`. **Done** — `RiscPc` `feature/modeserv-mode-string` (`d3bff54`)
  deletes `FNparse`, `FNdepth` and all four globals, and hands the command tail
  to `MODE` directly. The wire protocol is unchanged, and `MODES` still
  enumerates via `OS_ScreenMode 2`, which is where an unavailable frame rate is
  properly answered.
- PatLib has global `CX%/CY%/R%` *and* local `cx%/cy%/r%` holding the same
  values, distinguished only by case. That is a latent bug waiting to happen.
  **Not done.**
