# `meta` — the re-integration recipe

This is an **orphan branch**. It shares no history with `upstream`, `base`, or
the feature branches, and nothing builds from it. It holds one thing: the
recipe that rebuilds `integration`.

    integration  =  base  +  one squashed commit per feature branch

## Why it is a branch of its own

`FEATURES` (in `tools/reintegrate.sh`) changes whenever a feature is added,
removed or reordered — which is often. Everything else about the model wants
the opposite: feature branches sit on `base`, so **`base` moving forces a
restack of every feature branch**, and a force-push of each one.

When the list lived on `base`, adding a feature meant editing `base`, which
meant restacking ~13 branches and rewriting the commits of every open PR — for
a two-line list change that touches no code. Keeping the recipe here decouples
them: editing `FEATURES` is one commit on `meta`, and no feature branch moves.

`base` is now only for genuine dev/build infra, and should move rarely.

## Using it

There is nothing to check out — run it straight from the branch, from a normal
checkout of the repo:

```sh
git show meta:tools/reintegrate.sh | bash
```

It rebuilds `integration` from `base` + `FEATURES`, then:

```sh
make rebuild                                   # REQUIRED after a reintegrate
git push --force-with-lease origin integration
```

To add / remove / reorder a feature, edit `FEATURES` here and commit. Order
matters only where one branch is stacked on another (see the note in the list).

`integration` is **derived** — rebuilt, never hand-edited, always force-pushed.
The sources of truth are `base` and the `feature/*` branches.

See `CLAUDE.md` on `base` for the full branch model.
