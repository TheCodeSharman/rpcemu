# Plan — take the infra off `base`, branch features straight off `upstream`

Status: **proposed**, not started. Written 2026-07-17.

## The problem, in one line

**The build infrastructure lives on a branch of the thing it builds.**

Everything below follows from that. `base` = `upstream` + our infra, and every
`feature/*` sits on `base`, so `base` is a strict ancestor of all of them — which
means **`base` can never move** without restacking ~14 branches and force-pushing
every open PR.

`meta` already exists because of this: `FEATURES` changed often, so it was
evicted to an orphan branch to stop it moving `base`. That worked. This plan is
the same move, applied to *all* the infra rather than one list.

## What it actually costs us (observed, not theoretical)

- **Infra edits get smuggled onto a feature branch.** `feature/build-tooling` now
  owns edits to `CLAUDE.md` and the top-level `Makefile` — neither of which is
  "build tooling". They went there *only* because `base` may not move. The branch
  now lies about what it is.
- **A build needed three branches at once.** Fixing `s/errors` needed the driver
  source (`base`), the DDE tooling (`feature/build-tooling`) and HostCmd
  (`feature/spork-hostcmd`) in one tree — so `wip/fix-verify` exists purely to
  merge them. Every driver fix will need that throwaway again.
- **Artifacts have nowhere to live.** `netroms/*.ffa` can't sit on a feature
  branch (a binary can't be composed by merging — two branches shipping one
  conflict, and neither's contains the other's fix), so it lives on `integration`,
  which `reintegrate.sh` resets away every run. This has already shipped a stale
  module: both EtherRPCEm fixes were source-only and the binary RPCEmu loaded had
  both bugs.
- **`meta` has no `.envrc`.** Working there silently loses `direnv`, and with it
  `git-branchless`, whose hook then fails and aborts git's ref updates. That
  turned a clean reintegrate into a fake "conflict" and reset `integration` to
  `base`. The infra can't configure the environment of a branch that excludes it.
- **`git diff base feature/X`** is the mailable patch, so `base` must be
  *subtracted* to talk to upstream. It works, but it is a subtraction that only
  exists because the infra is in the ancestry at all.

## The shape

Invert the nesting. The infra becomes the **outer** tree; a checkout of the
source is **nested inside it**:

```
rpcemu-lab/                 <- the harness. Always present, whatever branch src/ is on.
  CLAUDE.md                    infra docs
  Makefile                     wrapper: builds src/qt5, riscos-modules, tests
  devenv.nix  .envrc           the toolchain (direnv reaches DOWN into src/ too)
  tools/                       dde/, setup-install.sh, riscos-boot-build/, mcp/, reintegrate.sh
  tests/                       unit/ + e2e/
  installs/                    gitignored, as now
  src/                         <- GITIGNORED nested worktree of the source repo
      (upstream | feature/X | integration)
```

The key property: **the harness does not sit on a branch of the source**, so
switching `src/` between `upstream`, a feature, or `integration` never changes
the tooling, and editing the tooling never touches a feature branch.

Then in the source repo:

```
upstream          pristine RPCEmu mirror (unchanged)
feature/*         branch DIRECTLY off upstream
integration       upstream + merged features
```

`base` and `meta` are retired. `git diff upstream feature/X` **is** the mailable
patch, with nothing to subtract.

### Two ways to host the harness

1. **Orphan `lab` branch in the same repo** + a nested `git worktree`
   (recommended). `lab` is `meta` grown up: same trick, more content. One clone,
   one remote, PRs stay where they are. `src/` is a worktree of the same repo,
   gitignored by `lab`.
2. **A separate `rpcemu-lab` repo**, with the source repo cloned inside it.
   Cleaner conceptually; costs a second repo and remote to keep in step.

Prefer (1) — it is a strictly smaller change and `meta` already proves the
orphan-branch pattern works here. Not a submodule either way: submodules pin a
SHA, and this workflow switches `src/` between branches constantly.

## What this fixes for free

- **direnv reaches down.** `.envrc` at the harness root applies to `src/` too,
  because direnv searches parents — so the "meta has no env" and "agent shells
  load RiscPc's devenv" traps both disappear.
- **No more `wip/*` throwaways.** The tooling is always present; only `src/`
  changes.
- **Artifacts stop being a branch problem.** `make riscos-modules` builds from
  whatever `src/` holds, straight into `installs/<name>/netroms/`. Nothing needs
  committing, so nothing can go stale. Commit a rebuilt binary only as a
  deliberate act when mailing upstream.
- **~14 features collapse to ~8.** Several "features" are not upstream deltas at
  all and dissolve into the harness (see below), which is most of the juggling.

## Reclassify while we're here

| Branch | Becomes |
| --- | --- |
| `feature/build-tooling` | **harness** (it *is* the infra) |
| `feature/e2e-tests`, `feature/ide-tests` | **harness** (`tests/`) |
| `feature/nix-flake` | **harness** |
| `feature/spork-mcp-server` | **harness** (`tools/mcp/`) — host-side, never upstream |
| `feature/vram-honesty`, `feature/fullscreen-mouse-map`, `feature/ide-fix`, `feature/etherrpcem-podule-fix`, `feature/etherrpcem-errorptr-fix`, `feature/iptunnel-persistent-tap`, `feature/spork-nat-broadcast-relay`, `feature/spork-hostcmd` | stay **features** off `upstream` (real `src/` + `riscos-progs/` deltas) |

`feature/spork-hostcmd` needs a look: it is `src/` + `poduleroms/` (upstream-ish)
but exists to serve the harness. Keep it a feature; the harness depends on
`integration` having it, which it already documents.

## Migration

Do it in this order; each step is verifiable and the old refs are kept until the
end.

0. **Freeze.** Land in-flight work first. *(Done — PR #17 is in `integration`
   `e5dbd3f`, `netroms/` rebuilt.)* Tag the current world: `archive/base`,
   `archive/integration`, `archive/meta`, and `archive/feature-*`. Nothing is
   deleted until step 6.
1. **Create `lab`** as an orphan branch from today's `meta`, and move the infra
   onto it — `CLAUDE.md`, `Makefile`, `devenv.nix`, `.envrc`, `tools/`, `tests/`,
   `docs/`, `.gitignore` (the harness's own). Take each file from `base` *or* the
   branch that currently smuggles it (`Makefile` and `CLAUDE.md` from
   `feature/build-tooling`, which has the newest). Add `/src/` to `lab`'s
   `.gitignore`.
2. **Bootstrap script** on `lab` (`tools/bootstrap.sh`): create the nested
   worktree at `src/`, defaulting to `integration`. Verify: `make` builds the
   emulator, `make riscos-modules` rebuilds EtherRPCEm to `83d6da72`, `make test`
   passes.
3. **Rebase the true features onto `upstream`**, one at a time:
   `git rebase --onto upstream base feature/X`. Expect this to be clean — features
   touch `src/`/`riscos-progs/`, the infra doesn't. Verify each with
   `git diff upstream feature/X` = only that feature's delta, and build it in the
   harness.
4. **Retire the dissolved branches** (`build-tooling`, `e2e-tests`, `ide-tests`,
   `nix-flake`, `mcp-server`): close their PRs with a pointer to `lab`. Their
   content is not lost — it moved.
5. **Rewrite `reintegrate.sh`** for `integration = upstream + features` (drop
   `BASE`, drop the dissolved entries). Keep the independence invariant and the
   fail-hard-on-conflict rule; both earned their keep. Rebuild `integration`,
   re-run the e2e suite, rebuild `netroms/`.
6. **Re-point the open PRs.** For each surviving feature, change the PR base from
   `base` to `upstream` and force-push the rebased branch. GitHub keeps the PR and
   its comments; the diff shrinks to the honest delta. Then delete `base`/`meta`
   (the `archive/*` tags remain).

## Risks, honestly

- **Step 6 is the loud one.** ~8 PRs get force-pushed and re-based. They survive,
  but reviewers see a rewritten diff. Cheapest now; it only gets worse — this is
  the argument for doing it soon rather than well-timed.
- **`.gitignore` is genuinely ambiguous.** Some of it (`rpcemu-interpreter`,
  `installs/`) is the harness's; some describes upstream's own build droppings and
  arguably belongs in `src/`. Split it deliberately; don't let it drift back onto
  a feature.
- **A worktree nested inside its own repo's worktree** is supported but slightly
  unusual. `/src/` must be gitignored on `lab`, and `git-branchless` should be
  checked against it early (step 2), not at the end.
- **`git rerere` and the branchless event log** carry resolutions/history keyed to
  the old SHAs. Expect to re-record; don't trust a rerere hit during the rebase.
- **`feature/spork-hostcmd` and `feature/etherrpcem-tests`** are stacked/coupled
  today (tests reuse `conftest.py`). Once tests move to the harness, that stacking
  disappears — check it does rather than assuming.

## Not doing

- **Not** turning `src/` into a submodule (pinned SHA fights branch-switching).
- **Not** merging `upstream` into `lab`, ever. `lab` stays orphan; that is the
  whole point.
- **Not** committing built modules on feature branches. That was never the
  problem's cause and reintroduces the artifact conflict.
