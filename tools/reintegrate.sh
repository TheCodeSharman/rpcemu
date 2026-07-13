#!/usr/bin/env bash
#
# Rebuild the integration branch from scratch:
#
#     integration  =  base  +  one squashed commit per feature branch
#
# `upstream` is a PRISTINE RPCEmu mirror; `base` = upstream + our dev/build infra
# (.gitignore, Makefile, devenv, CLAUDE.md, this script). Feature branches sit on
# `base`, so a feature's mailable-upstream patch is `git diff base feature/X`.
#
# The integration branch is DERIVED — the sources of truth are the `base`
# branch and the `feature/*` branches.  This regenerates its history, so the
# result is force-pushed:
#
#     git push --force-with-lease origin integration
#
# Re-run whenever a feature branch changes, or after an upstream import.
# To add / remove / reorder a feature, edit the FEATURES list below.
#
# git rerere is enabled in this repo, so if two features ever conflict you
# only resolve it once; subsequent rebuilds replay the resolution.
set -euo pipefail

BASE=base
INTEGRATION=integration

# "branch:squash commit message".  Order matters only when features conflict.
FEATURES=(
  "feature/build-tooling:Build tooling: setup-install.sh + riscos-boot-build + CMOS template"
  "feature/vram-honesty:VRAM honesty: authentic VRAM sizes + 8 MB OS-patch option"
  "feature/fullscreen-mouse-map:Full-screen mousehack: map host pointer instead of warping (Wayland-safe)"
  "feature/ide-real-geometry:IDE: report disc geometry from image size, not a fixed 32 GB"
  "feature/spork-ide-lba-dataloss:IDE: LBA/data-loss fix (skip512 decouple + IDNF bounds + RO5 capacity)"
  "feature/iptunnel-persistent-tap:IPTunnelling: attach to a pre-created persistent TAP (unprivileged)"
  "feature/nix-flake:Nix flake: udp-broadcast-relay-redux, freeway-net helper, rpcemu-freeway module"
  "feature/spork-nat-broadcast-relay:NAT broadcast relay: in-process Access+/ShareFS/Freeway over SLiRP"
  "feature/spork-hostcmd:HostCmd: drive the RISC OS command line from the host (+ rpcemu-run, MCP-ready)"
  "feature/spork-mcp-server:MCP server: drive a RISC OS guest from an MCP client (riscos_run + HostFS file tools)"
  "feature/e2e-tests:E2E tests: pytest suite exercising the HostCmd + MCP agent-drive stack"
)

# Refuse to run with a dirty (tracked) working tree.
if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "error: working tree has uncommitted changes — commit or stash first" >&2
  exit 1
fi

git checkout -B "$INTEGRATION" "$BASE"

for entry in "${FEATURES[@]}"; do
  branch="${entry%%:*}"
  msg="${entry#*:}"
  echo ">> squash-merging ${branch}"
  git merge --squash "${branch}"
  git commit -m "${msg}"
done

echo
echo "Rebuilt '${INTEGRATION}' = ${BASE} + ${#FEATURES[@]} squashed feature(s)."
echo "Review, then publish with:"
echo "    git push --force-with-lease origin ${INTEGRATION}"
