#!/usr/bin/env bash
#
# Rebuild the integration branch from scratch:
#
#     integration  =  upstream  +  one squashed commit per feature branch
#
# The integration branch is DERIVED — the sources of truth are the `upstream`
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

BASE=upstream
INTEGRATION=integration

# "branch:squash commit message".  Order matters only when features conflict.
FEATURES=(
  "feature/vram-honesty:VRAM honesty: authentic VRAM sizes + 8 MB OS-patch option"
  # Add once tested / accepted:
  # "feature/fullscreen-mouse-map:Full-screen mousehack: map host pointer instead of warping"
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
