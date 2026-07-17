# PR #16 — tests: EtherRPCEm driver across RAM sizes

> **Archived.** This branch **dissolved into `lab`** during the 2026-07-17 reorg;
> it was never an upstream delta. Its content is now `tests/e2e/test_etherrpcem.py`.
>
> | | |
> | --- | --- |
> | branch | `feature/etherrpcem-tests` (deleted; preserved as tag `archive/20260717/feature-etherrpcem-tests`) |
> | PR | <https://github.com/TheCodeSharman/rpcemu/pull/16> (closed, not merged) |
> | opened | 2026-07-17 |
> | closed | 2026-07-17 |
>
> Kept because the PR description is where this project records the *why* and the
> journey — and that rationale explains code that now lives here, on `lab`, while
> the PR itself lives only on GitHub. See `docs/reorg-plan.md`.

---

E2E regression tests for the EtherRPCEm RAM-size bug fixed in
`feature/etherrpcem-podule-fix` (#15). Stacked on `feature/e2e-tests` rather
than `base` so it can reuse that suite's `conftest.py`.

Boots a real guest at 8/32/256MB and drives the driver through its **public
interface** — the SWI chunk it publishes (`EtherRPCEm_DCIVersion`,
`EtherRPCEm_Inquire`) — rather than reaching into its internals. The RAM size is
the whole point, so each size gets its own boot.

These live here and not in `tests/unit` because the fix is guest ARM code built
by Norcroft *inside* the emulator: unlike `src/ide.c` there is no host-linkable
translation unit for Criterion to drive, and the bug is only expressible against
a booted RISC OS with a real Podule manager. A host unit test could only
exercise a mocked `_swix`, which would have asserted the old, wrong behaviour
just as happily as the new one.

## Validated in both directions

Against `installs/riscos-530`, swapping the driver in `netroms/EtherRPCEm,ffa`:

| | 8MB | 32MB | 256MB |
| --- | --- | --- | --- |
| fixed driver | 5 pass | 5 pass | 5 pass |
| unfixed driver | 5 error | 5 error | 5 pass (control) |

The unfixed errors read *"guest never reached the desktop"* — the tests really
do detect the bug rather than passing vacuously. 256MB is the control, proving
the fix doesn't regress the one size that always worked.

## What validating them changed

The first end-to-end run was 9/15 red, and the driver was never at fault — both
defects were in the test:

1. **A race against the boot.** Readiness was judged by an `Echo pong` reply,
   but HostCmd answers from the **supervisor prompt at ~T+4s** while the desktop
   only arrives **~T+6s** (RPCEmu boots RO 5.30 in about six seconds). Every
   BASIC-driven test fired into that 1–2s window, where there is no application
   slot: BASIC data-aborted in its own startup — `&FC17CF48`, inside the
   **BASIC** module at `FC17C984`, *not* the driver — and wedged the guest. It
   failed at *every* RAM size including the 256MB control, which is what proves
   it was never the podule bug.

   It looked deterministic rather than flaky only because pytest is reliably
   fast enough to always land inside the window; the same commands run by hand
   were a second slower and always passed.

   `Wimp$State` reaching `desktop` is the correct signal and is strictly better
   than a reply: HostCmd answers even on a boot the driver later aborts, so the
   old check could not have detected an unfixed driver at all. Suite runtime
   drops **505s → 21s**, since no test now burns a 60s timeout against a dead
   guest.

2. **An unverified constant.** `ERR_EINVAL` was read off `s/errors` (`0x20E16`)
   but never observed. The driver returns a pointer *past* its own error block,
   so a client reads whatever sits there. Confirmed against the loaded image
   (`OS_Module 18` base `20149874`): block at base+`22D8`, returned pointer
   base+`2644`, word there `E1877003` (an opcode). The unfixed driver does the
   same (block +`2DC4`, pointer +`3164`), so it is **pre-existing**, not a
   regression, and wants its own investigation. The test now asserts only that
   bad flags are rejected — what can honestly be checked here.

The branch also originally swept in `docs/dde-build.md` and `tools/dde/*`, which
are byte-identical duplicates of what `feature/build-tooling` already carries
(commit `69cc451`, still unpushed). Dropped, so this branch is one logical patch
as the branch model requires — otherwise `reintegrate.sh` would squash the same
files onto `base` from two features.

## Running

```
RPCEMU_TEST_INSTALL=installs/riscos-530 pytest tests/e2e/test_etherrpcem.py -v
```

Needs an install whose `netroms/` holds the driver under test, `hostcmd,ffa` in
`poduleroms/`, and a display to boot into.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
