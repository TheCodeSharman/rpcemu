# `lab` — the build infrastructure

This is an **orphan branch**. It shares no history with `upstream` or the feature
branches, and nothing here is upstream's. It is the harness: the Makefile, the
toolchain, the tests, the DDE tooling, the MCP server, and the recipe that
rebuilds `integration`.

## Why it is off to one side

**The infrastructure must not live on a branch of the thing it builds.**

It used to. `base` was `upstream` + our infra, and every `feature/*` sat on it —
so `base` was a strict ancestor of all of them and **could never move** without
restacking every branch and force-pushing every open PR. `meta`, this branch's
ancestor, existed only to hold `FEATURES` out of `base`'s way. That was the right
fix applied to one file; this is the same fix applied to all of it.

What the old shape cost: infra edits got smuggled onto whichever feature branch
would take them (`CLAUDE.md` and the `Makefile` ended up on
`feature/build-tooling`, which is not what that branch is); a one-line driver fix
needed a throwaway merge branch just to see its own build tooling; and built
artifacts had nowhere to live at all.

Inverting it fixes all of that at once:

```
lab/                    <- you are here. Always present, whatever tree/ is on.
  Makefile  tools/  tests/  CLAUDE.md  devenv.nix  .envrc  gitignore-src
  tree/                 <- nested worktree of the source (gitignored)
  installs/             <- local RISC OS installs (gitignored)
  rpcemu-interpreter    -> tree/rpcemu-interpreter
```

Switching `tree/` between `upstream`, a feature and `integration` never changes
the tooling, and editing the tooling never touches a feature branch.

## Start here

```sh
tools/bootstrap.sh              # create tree/ (default: integration) + wire ignores
make                            # build the emulator from tree/src/qt5
make test                       # unit + e2e
./installs/riscos-530/run       # run a machine
```

`bootstrap.sh` is **idempotent** — re-run it any time. It is also the fix for a
fresh clone, a `git clean -xdf` inside `tree/`, or the lab having been moved.

## The branch model

```
upstream      pristine RPCEmu mirror
feature/*     branch DIRECTLY off upstream -- `git diff upstream feature/X`
              IS the mailable patch, with nothing to subtract
integration   upstream + one squashed commit per feature (DERIVED, force-pushed)
lab           this branch
```

Rebuild with `git -C tree checkout integration && tools/reintegrate.sh`, then
`make rebuild`. `integration` is derived — never hand-edited; the sources of
truth are `upstream` and the `feature/*` branches.

**Feature branches must be INDEPENDENT** — each touches disjoint code, so
squash-merging them in any order never conflicts. `reintegrate.sh` disables
`rerere` and fails hard on the first conflict rather than papering over it.

## Two things that bite

- **The source tree commits no `.gitignore`, deliberately** — that is why the
  upstream diffs are clean. The rules live here in `gitignore-src`;
  `bootstrap.sh` installs them into `tree/` as a generated, self-ignoring
  `.gitignore` plus a `core.excludesFile` backstop. Git never applies ignore
  rules across a repository boundary, so this branch's own `.gitignore` cannot
  reach `tree/`. Never commit a `.gitignore` into `tree/`.
- **`netroms/*.ffa` are build artifacts and go stale silently.** They live on
  `integration` only (a binary cannot be composed by merging, so two branches
  shipping one would conflict and neither's would hold the other's fix), and
  `reintegrate.sh` resets to `upstream` and discards them. Rebuild with
  `make riscos-modules` and re-commit after any reintegrate that touched
  `riscos-progs/`. The failure mode is the sources looking fixed while the module
  RPCEmu loads is not — it has already happened once.

Rationale and the migration that got here: [`docs/reorg-plan.md`](docs/reorg-plan.md).
Pre-reorg refs are preserved as `archive/20260717/*` tags; `base` and `meta` are
retired.
