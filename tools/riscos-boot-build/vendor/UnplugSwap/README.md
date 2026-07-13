# UnplugSwap — per-OS module-unplug CMOS mask on a multi-ROM disc

A tiny standalone BBC BASIC utility the multi-ROM switcher calls from `BootRun`
(see `build.py` `patch_bootrun_per_os_bootcfg`). On a ROM swap it **saves the
outgoing OS's 13 module-unplug CMOS bytes** and **restores the incoming OS's**
(clearing them if that OS has never been seen).

## Why per-OS, and why *not* just clear

The CMOS **module-unplug mask is position-keyed** to ROM-module order. `*Unplug
<name>` (used by `!Boot.Resources.!Internet.!Run` and by interactive
`InetSetup`/Configure) sets the bit for that name's slot in the **currently
running ROM**. So the *same* unplug lands on a *different* bit per ROM — e.g.
`InternetA` is `&13` bit 1 on RISC OS 4.02 but `&13` bit 3 on 3.7, so 4.02's bit
would unplug one of 3.7's **core** network modules. A shared mask therefore
breaks networking on a swap.

Clearing the mask on a swap is **not enough**: an OS does not necessarily
re-assert its unplugs by name on every boot. On 3.7 the mask is set by
*interactive* Configure, not by a boot script, so a cleared mask stays lost and
3.7's networking breaks. (Verified empirically: booting 3.7 after a clear gives
"Route: Network is unreachable" until its `&13=&08` is put back.) So each OS
keeps its own mask, restored on a swap.

**Only the 13 unplug bytes are touched** — filesystem/drive/monitor config is
machine state shared across OSes and must not change (a full-CMOS swap clobbers
it → "Disc drive not known"). The RTC clock is outside CMOS 0..239.

## The 13 locations

The Kernel's `UnplugCMOSTable` (`s/ModHand`) — main-ROM `Unplug7..17` — plus
`ExtnUnplug1/2` for extension ROMs: `&D9 &DA &DB &12 &13 &09 &82 &83 &8D &8E &E7
&14 &15`.

## Interface

Reads two system variables set by `BootRun`:
- `Unplug$Save` — file to save the outgoing OS's mask to (unset/"" = skip, e.g.
  the first-ever boot with no prior owner)
- `Unplug$Load` — file to restore this OS's mask from; if the file is absent
  (OS never seen) the mask is cleared (all modules enabled), and the OS
  establishes its own mask via Configure, captured on the next swap-away.

Apply-timing: the mask is read at ROM module-init, *before* `!Boot`, so the
restore lands one boot too late — the switcher prompts a restart, and the next
boot inits from the restored mask.

## Files

- **`Source,fff`** — the readable source (text, no line numbers). Edit this.
- **`UnplugSwap,ffb`** — the tokenised BASIC that `build.py` places at
  `!Boot.Utils.UnplugSwap`. **This is what actually ships.**

## Re-tokenising after editing `Source,fff`

No host-side BASIC tokeniser (`bastotxt` is detokenise-only), so produce `,ffb`
inside RISC OS (e.g. under RPCEmu). In a command window:

```
BASIC
TEXTLOAD "<path>.Source"
SAVE "<path>.UnplugSwap"
QUIT
```

Then copy `UnplugSwap,ffb` back here. Verify with `bastotxt -i UnplugSwap,ffb`.
