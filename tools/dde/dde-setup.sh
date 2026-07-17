#!/usr/bin/env bash
# Install the ROOL DDE (Acorn C/C++) into an RPCEmu install's HostFS drive, so
# RISC OS modules/apps can be built *inside* the emulated machine and driven
# from the host (see docs/dde-build.md).
#
#   tools/dde/dde-setup.sh <dde-zip> <install-dir> [dde-dir-name]
#
# e.g. tools/dde/dde-setup.sh ~/dde/DDE31d.zip installs/riscos-530
#
# The DDE is commercial software from RISC OS Open; supply your own copy. This
# script only unpacks a zip you already have.
set -euo pipefail

ZIP=${1:?usage: dde-setup.sh <dde-zip> <install-dir> [dde-dir-name]}
INSTALL=${2:?usage: dde-setup.sh <dde-zip> <install-dir> [dde-dir-name]}
DDEDIR=${3:-DDE31}

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
ROEXTRACT="$REPO/tools/riscos-boot-build/roextract.py"

[ -f "$ZIP" ]                || { echo "error: no such zip: $ZIP" >&2; exit 1; }
[ -d "$INSTALL/hostfs" ]     || { echo "error: not an install (no hostfs/): $INSTALL" >&2; exit 1; }
[ -f "$ROEXTRACT" ]          || { echo "error: roextract.py not found: $ROEXTRACT" >&2; exit 1; }

DEST="$INSTALL/hostfs/$DDEDIR"

# RISC OS zips keep the filetype in an Acorn extra-field, not the filename, so a
# plain unzip loses every type and nothing is runnable. roextract.py recovers it
# and writes HostFS ,xxx names.
#
# The DDE zip's top-level directory is the RISC OS dir "AcornC/C++", which maps
# to "AcornC.C++/" in the zip (RISC OS '.' <-> host '/'). Strip it so the tree
# lands directly at <hostfs>.<dde-dir-name>.
STRIP=$(python3 - "$ZIP" <<'EOF'
import sys, zipfile
names = zipfile.ZipFile(sys.argv[1]).namelist()
tops = {n.split('/')[0] for n in names if '/' in n}
print(f"{tops.pop()}/" if len(tops) == 1 else "")
EOF
)

echo "installing DDE"
echo "  zip     : $ZIP"
echo "  strip   : ${STRIP:-<none>}"
echo "  dest    : $DEST"
rm -rf "$DEST"
mkdir -p "$DEST"
python3 "$ROEXTRACT" "$ZIP" "$DEST" "$STRIP"

# The DDE also ships its support modules as a !System tree (Developer/!System),
# which on RISC OS you would !SysMerge into the machine. We do not, because for
# an install built by tools/setup-install.sh it is verifiably a no-op:
#   - every module it carries is already present at an equal-or-newer version
#     (e.g. DDEUtils 1.75 == 1.75), so nothing is added or replaced;
#   - its !System plumbing (!Run, !Boot, SysPaths, !Help) is byte-identical to
#     ROOL's, since both come from ROOL.
# If you build on a machine whose !System *does* lack DDEUtils, merge it --  but
# restrict it to Modules/, e.g.
#   PYTHONPATH=tools/riscos-boot-build python3 -c "\
#     from pathlib import Path; from build import merge_system; \
#     merge_system(Path('<dde>/Developer/!System/310/Modules'), \
#                  Path('<install>/hostfs/!Boot/Resources/!System/310/Modules'), \
#                  {}, {}, '', '')"
# Note merge_system() is NOT a general !SysMerge: real !SysMerge merges modules
# by version and leaves the !System plumbing alone, whereas merge_system()'s
# fallback for files with no comparable version deliberately prefers the source
# (right for the boot builder, where PlingSystem is the authoritative !System;
# wrong for merging a DDE in). Restricting to Modules/ sidesteps that.

# Sanity-check we got a *modern* DDE: the 1998 Acorn C/C++ (Norcroft 5.09) is
# C89 and cannot build sources that use <stdint.h> or C99 'inline'.
if [ ! -d "$DEST/!SetPaths/Lib32" ]; then
	echo >&2
	echo "warning: no !SetPaths/Lib32 -- this does not look like a modern (32-bit) DDE." >&2
	echo "         RISC OS 5 is 32-bit only; a 26-bit DDE's stubs will not do." >&2
fi
if [ ! -f "$DEST/Export/APCS-32/Lib/CLib/h/stdint,fff" ]; then
	echo "warning: no APCS-32 CLib h.stdint -- DDE too old for C99 sources." >&2
fi

cat <<EOF

installed. Next:
  1. Boot the machine:   (cd $INSTALL && ./run)     # needs poduleroms/hostcmd,ffa
  2. Build a project:    tools/dde/dde-amu.sh $INSTALL <project-dir-on-hostfs>

See docs/dde-build.md for the details and the known gotchas.
EOF
