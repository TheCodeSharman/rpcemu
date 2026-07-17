# Archived PR descriptions

Branches that **dissolved into `lab`** in the 2026-07-17 reorg (see
`../reorg-plan.md`). None was an upstream delta: they were build infrastructure
and tests that had been forced onto feature branches because the infra used to
live on `base`, a branch of the very source it built.

The code moved into this branch verbatim. These are the PR descriptions that
explain *why* it exists — preserved here so the rationale sits with the code
rather than only in a closed GitHub PR.

| PR | Branch | What it became |
| --- | --- | --- |
| [#4](pr-04-build-tooling.md) | `feature/build-tooling` | `tools/{dde,cmos,riscos-boot-build,setup-install.sh}`, `docs/dde-build.md`, and the `Makefile`/`CLAUDE.md` edits it had been carrying |
| [#7](pr-07-nix-flake.md) | `feature/nix-flake` | `flake.nix`, `flake.lock`, `nix/`, `tools/freeway-net.sh` |
| [#9](pr-09-spork-mcp-server.md) | `feature/spork-mcp-server` | `tools/mcp/` |
| [#10](pr-10-e2e-tests.md) | `feature/e2e-tests` | `tests/e2e/` |
| [#14](pr-14-ide-tests.md) | `feature/ide-tests` | `tests/unit/` |
| [#16](pr-16-etherrpcem-tests.md) | `feature/etherrpcem-tests` | `tests/e2e/test_etherrpcem.py` |

The commits themselves are preserved as `archive/20260717/feature-*` tags.
