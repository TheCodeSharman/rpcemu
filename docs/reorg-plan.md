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

**Decided: (1), the orphan `lab` branch.** It is a strictly smaller change and
`meta` already proves the orphan-branch pattern works here. Not a submodule
either way: submodules pin a SHA, and this workflow switches `src/` between
branches constantly.

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

## Inventory (measured)

The split is cleaner than expected: **every path we added is a new top-level
name**, so nothing we own overlaps anything upstream owns.

| Owner | Paths |
| --- | --- |
| **upstream** | `COPYING` `readme.txt` `src/` `riscos-progs/` `netroms/` `roms/` `cmos.ram` `rpc.cfg` |
| **lab** (infra) | `.envrc` `CLAUDE.md` `Makefile` `devenv.{nix,yaml,lock}` `flake.{nix,lock}` `nix/` `docs/` `tests/` `tools/` + `gitignore-src` (was `base:.gitignore`) |

Provenance for the lab's content — take each from the branch that has the
**newest**, not blindly from `base`:

- `base`: `.envrc`, `devenv.*`, and the originals of `CLAUDE.md` / `Makefile`
- `feature/build-tooling`: `tools/{dde,cmos,riscos-boot-build,setup-install.sh}`,
  `docs/dde-build.md`, **and the current `CLAUDE.md` + `Makefile`** (they were
  smuggled here precisely because `base` may not move — take these)
- `feature/nix-flake`: `flake.*`, `nix/`
- `feature/spork-mcp-server`: `tools/mcp/`, its `docs/`
- `feature/e2e-tests`, `feature/ide-tests`: `tests/`
- `meta`: `tools/reintegrate.sh`, this plan

Simplest route: take the infra from **`integration`**, which already has all of
the above merged and is the newest of everything. Then re-add `meta`'s files.

### Wrinkle: `base` *deletes* `cmos.ram` and `rpc.cfg`

`base` is not purely additive — it **removes** two files upstream ships. They are
auto-generated with sensible defaults when absent, and the emulator *writes* them
at runtime, so tracking them means a dirty tree the moment you run from the repo
root. Deleting them was the fix.

Under the new model a feature branches off `upstream`, so it **keeps** them, and
that fix is gone. Ignoring them cannot help — they are tracked, and `.gitignore`
has no effect on tracked files.

Resolve it in the lab, not by patching upstream: **`make run` must launch an
install** (`installs/<name>/run`, whose datadir is the install), never the source
root. Today's `run` target does `./rpcemu-interpreter` from the repo root, which
is exactly what dirties them — change it as part of moving the Makefile. If they
still get dirtied, `git update-index --skip-worktree` from bootstrap is the
fallback; do not re-add a delete-upstream-files commit.

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

## Decided: `.gitignore` — the source tree commits none at all

**Upstream ships no `.gitignore`.** The entire file was invented by `base`, so
none of it is upstream's to keep. `upstream` and every `feature/*` will therefore
carry **no `.gitignore`**, and the rules move to the lab as a committed
`gitignore-src`. `bootstrap.sh` materialises it into `src/` **two ways**:

```sh
# 1. a GENERATED, untracked .gitignore that lists itself -- so ordinary tools work
{ echo "# GENERATED by bootstrap.sh -- untracked, ignores itself. Do not commit."
  echo ".gitignore"; cat "$LAB/gitignore-src"; } > src/.gitignore
# 2. a backstop that survives `git clean -xdf` (which deletes the above)
git -C src config core.excludesFile "$LAB/gitignore-src"
```

One source of truth (`gitignore-src`), two materialisations. This removes the
ambiguity the earlier draft flagged rather than splitting the file:
`git diff upstream feature/X` loses the ignore noise for good, and there is
nothing left to drift back onto a feature branch.

**A `.gitignore` can ignore itself** — verified. Git reads ignore files from the
**working tree**, not the index, so an untracked `.gitignore` listing `.gitignore`
is fully effective *and* invisible:

```
$ git status --porcelain          # only real source; junk AND .gitignore hidden
?? real-source.c
$ git check-ignore -v .gitignore
.gitignore:2:.gitignore	.gitignore
$ git add -A                      # cannot stage itself -- self-protecting
A  real-source.c
```

That is strictly better than `core.excludesFile` alone: it is a real `.gitignore`,
so VS Code, ripgrep, fd and every editor honour it with no configuration; there is
no absolute path to break when the lab moves; and `git add -A` **cannot**
accidentally commit it. Its one weakness is that `git clean -xdf` deletes it
(being ignored), which is exactly what the `core.excludesFile` backstop covers —
tested: with the file gone, the rules still apply.

**Ignore rules are NOT transitive — verified, not assumed.** A `.gitignore` in
the lab root has *no* effect on `src/`: git never crosses a repository boundary,
and a nested worktree is its own root. Tested — the artifact shows as `?? foo.o`
and `check-ignore` exits 1. Only two mechanisms reach into `src/`, and both were
tested against the real shape (orphan branch + nested worktree, across a branch
switch):

| Mechanism | Rules live in | Verdict |
| --- | --- | --- |
| lab's own `.gitignore` | the lab | **useless for `src/`** — not transitive |
| `$GIT_COMMON_DIR/info/exclude` | an uncommitted copy | works; rules unversioned; invisible to tools |
| `core.excludesFile` → lab file | a committed lab file | works; **use as backstop** |
| **generated self-ignoring `.gitignore`** | generated from the lab file | **use as primary** |

All the working ones survive `src/` switching branches (`core.excludesFile` lands
in the shared repo config, covering every worktree; the generated file is
untracked, so checkout leaves it alone).

Costs, accepted:

- **Neither is committable**, so a clone without `bootstrap.sh` has *no* ignores.
  Bootstrap becoming the mandatory entry point is the mitigation (and arguably the
  point). Make it idempotent and cheap to re-run.
- **`git clean -xdf` in `src/` deletes the generated `.gitignore`.** The
  `core.excludesFile` backstop covers exactly this window; re-running bootstrap
  restores the file. This is why both are used.
- **`core.excludesFile` needs an absolute path**, so moving or renaming the lab
  breaks the backstop (not the primary). Re-running `bootstrap.sh` is the fix; say
  so in its output.
- **An untracked `.gitignore` will collide** if a future RPCEmu import ever ships
  one — `git checkout` refuses to clobber an untracked file. Loud and detectable,
  not silent; handle it at import time.

## Migration

Do it in this order; each step is verifiable and the old refs are kept until the
end.

0. **Freeze.** Land in-flight work first. *(Done — PR #17 is in `integration`
   `e5dbd3f`, `netroms/` rebuilt.)* Tag the current world: `archive/base`,
   `archive/integration`, `archive/meta`, and `archive/feature-*`. Nothing is
   deleted until step 6.
1. **Create `lab`** as an orphan branch from today's `meta`, and move the infra
   onto it — `CLAUDE.md`, `Makefile`, `devenv.nix`, `.envrc`, `tools/`, `tests/`,
   `docs/`. Take each file from `base` *or* the branch that currently smuggles it
   (`Makefile` and `CLAUDE.md` from `feature/build-tooling`, which has the
   newest). `base`'s `.gitignore` becomes the lab's `gitignore-src`; the lab gets
   its own small `.gitignore` containing `/src/` and `/installs/`.
2. **Bootstrap script** on `lab` (`tools/bootstrap.sh`): create the nested
   worktree at `src/` (default `integration`) and wire the ignores:
   `git -C src config core.excludesFile "$LAB/gitignore-src"`. Make it
   idempotent and re-runnable — it is the fix for a moved lab. Verify: `make`
   builds the emulator, `make riscos-modules` rebuilds EtherRPCEm to `83d6da72`,
   `make test` passes, and `git -C src status` is clean with **no** `.gitignore`
   in the tree.
3. **Rebase the true features onto `upstream`**, one at a time:
   `git rebase --onto upstream base feature/X`. Expect this to be clean — features
   touch `src/`/`riscos-progs/`, the infra doesn't. Verify each with
   `git diff upstream feature/X` = only that feature's delta, and build it in the
   harness. Note the rebase *drops* `.gitignore` (and the rest of base's infra)
   from each feature's ancestry rather than moving it — so until step 2's
   `core.excludesFile` is wired, a rebased feature's `git status` will be noisy
   with build artifacts. Wire the ignores first; do not "fix" it by re-adding a
   `.gitignore`.
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
- ~~`.gitignore` is genuinely ambiguous.~~ **Resolved** — upstream ships none, so
  the source tree commits none and the rules move wholesale to the lab. See the
  decision section above.
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
