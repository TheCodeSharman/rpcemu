#!/usr/bin/env bash
#
# Rebuild the integration branch from scratch:
#
#     integration  =  upstream  +  one squashed commit per feature branch
#
# `upstream` is a PRISTINE RPCEmu mirror. Feature branches sit DIRECTLY on it, so
# a feature's mailable-upstream patch is exactly `git diff upstream feature/X` —
# nothing to subtract. The build infrastructure is not in this history at all: it
# lives on the orphan `lab` branch (this script included), outside the source it
# builds, with the source checked out as a nested worktree at tree/. That is why
# `base` is gone. See docs/reorg-plan.md.
#
# Run it from the LAB, against tree/:
#
#     git -C tree checkout integration && tools/reintegrate.sh
#
# The integration branch is DERIVED — the sources of truth are `upstream` and the
# `feature/*` branches.  This regenerates its history, so the result is
# force-pushed:
#
#     git push --force-with-lease origin integration
#
# Re-run whenever a feature branch changes, or after an upstream import.
# To add / remove / reorder a feature, edit the FEATURES list below.
#
# INVARIANT: feature branches must be INDEPENDENT — each touches disjoint
# code, so squash-merging them in any order never conflicts. This is what
# makes integration reproducible on any clone (CI, a fresh checkout, another
# machine) with no hidden state.
#
# Therefore this script disables git rerere for the merges and FAILS HARD on
# the first conflict. A conflict means two features overlap; the fix is to
# rework them (e.g. fold the overlapping features into one branch), NOT to
# resolve-and-record — a machine-local rerere resolution would let a broken
# integration pass here yet fail for everyone else.
set -euo pipefail

BASE=upstream
INTEGRATION=integration

# "branch:squash commit message".  Order matters only when features conflict.
FEATURES=(
  "feature/vram-honesty:VRAM honesty: authentic VRAM sizes + 8 MB OS-patch option"
  "feature/fullscreen-mouse-map:Full-screen mousehack: map host pointer instead of warping (Wayland-safe)"
  "feature/ide-fix:IDE fix: LBA-addressing/data-loss fix + real CHS & LBA disc-size reporting"
  "feature/etherrpcem-podule-fix:EtherRPCEm: fix networking at every RAM size except 256MB"
  "feature/etherrpcem-errorptr-fix:EtherRPCEm: fix the bogus error pointer returned by every SWI"
  "feature/iptunnel-persistent-tap:IPTunnelling: attach to a pre-created persistent TAP (unprivileged)"
  "feature/spork-nat-broadcast-relay:NAT broadcast relay: in-process Access+/ShareFS/Freeway over SLiRP"
  "feature/spork-hostcmd:HostCmd: drive the RISC OS command line from the host (+ rpcemu-run, MCP-ready)"
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
  # rerere disabled per-command: never let a recorded local resolution mask a
  # conflict here. A conflict is a hard error (see INVARIANT above).
  if ! git -c rerere.enabled=false merge --squash "${branch}"; then
    {
      echo
      echo "error: CONFLICT squash-merging '${branch}' into '${INTEGRATION}'."
      echo "Feature branches must be independent, but this one overlaps an"
      echo "earlier feature in:"
      git diff --name-only --diff-filter=U | sed 's/^/    /'
      echo
      echo "Rework so the branches touch disjoint code (e.g. fold the"
      echo "overlapping features into a single branch), then re-run. Aborting"
      echo "without resolving — no rerere, by design."
    } >&2
    git reset --hard "$BASE" >/dev/null 2>&1
    exit 1
  fi
  git commit -m "${msg}"
done

echo
echo "Rebuilt '${INTEGRATION}' = ${BASE} + ${#FEATURES[@]} squashed feature(s)."
echo
echo "!! The RISC OS module binaries in netroms/ are NOT rebuilt by this script,"
echo "!! and this rebuild has just DISCARDED any previous rebuild of them (it"
echo "!! resets to ${BASE}). They are build artifacts: feature branches carry only"
echo "!! the sources, because a binary cannot be composed by merging -- two"
echo "!! branches shipping one would conflict, and neither's would hold the"
echo "!! other's fix. So they live on '${INTEGRATION}' only, and are now STALE."
echo "!!"
echo "!! If any riscos-progs/ source changed, rebuild before publishing (needs a"
echo "!! guest booted to the desktop with the ROOL DDE -- see docs/dde-build.md):"
echo "!!"
echo "!!     (cd ../installs/riscos-530 && ./run) &     # from the lab: installs/..."
echo "!!     make riscos-modules                       # run in the LAB"
echo "!!     git -C tree commit netroms -m 'netroms: rebuild EtherRPCEm'"
echo
echo "Review, then publish with:"
echo "    git push --force-with-lease origin ${INTEGRATION}"
