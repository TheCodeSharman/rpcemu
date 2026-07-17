#!/usr/bin/env bash
# Run `amu` on a project inside a *running* RPCEmu machine, with the ROOL DDE's
# paths set up, and report the result on the host. See docs/dde-build.md.
#
#   tools/dde/dde-amu.sh <install-dir> <project> [dde-dir-name] [amu-args...]
#
# <project> is the project's path under the machine's HostFS root, using RISC OS
# separators, e.g. "Build.EtherRPCEm".
#
# Requires: the machine booted with poduleroms/hostcmd,ffa (HostCmd socket), and
# src/tools/rpcemu-run built (`make -C src/tools`). Both come from the hostcmd
# feature; on `integration` they are present.
set -euo pipefail

INSTALL=${1:?usage: dde-amu.sh <install-dir> <project> [dde-dir-name] [amu-args...]}
PROJECT=${2:?usage: dde-amu.sh <install-dir> <project> [dde-dir-name] [amu-args...]}
DDEDIR=${3:-DDE31}
shift 3 || shift $#

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
RUN="$REPO/src/tools/rpcemu-run"
SOCK="$INSTALL/hostcmd.sock"

[ -x "$RUN" ]  || { echo "error: $RUN missing -- run: make -C src/tools" >&2; exit 1; }
[ -S "$SOCK" ] || { echo "error: no HostCmd socket at $SOCK (is the machine booted?)" >&2; exit 1; }

ro() { "$RUN" --socket "$SOCK" -- "$@"; }

D="HostFS::HostFS.\$.$DDEDIR"
P="HostFS::HostFS.\$.$PROJECT"

# What the DDE's own !SetPaths.SetPaths does, reduced to what a command-line
# build needs: the 32-bit tools on Run$Path, and the APCS-32 exports on C$Path.
# (We do not run SetPaths itself: it is an Obey file that also wants the Filer,
# and its RMEnsure/RomPatch dance is only needed on RISC OS 4.)
ro Set C\$Path "$D.Export.APCS-32.Lib.CLib.,$D.Export.APCS-32.Lib.tboxlibs.,$D.Export.APCS-32.Lib.,$D.Export.APCS-32.C.,$P." >/dev/null
ro SetMacro Run\$Path ,%.,"$D.!SetPaths.Lib32." >/dev/null

# Gotcha: some project Makefiles link against `C:o.stubsg`, which exists in
# neither the DDE nor ROOL's shared Makefiles -- ModuleLibs prescribes
# `CLIB = CLIB:o.stubs` for modules. Provide o.stubs under that name, inside the
# project (which is on C$Path), rather than patching the Makefile or the DDE.
STUBS="$INSTALL/hostfs/$(echo "$PROJECT" | tr '.' '/')/o/stubsg,ffd"
if [ ! -f "$STUBS" ] && [ -d "$(dirname "$STUBS")" ]; then
	SRC="$INSTALL/hostfs/$DDEDIR/Export/APCS-32/Lib/CLib/o/stubs,ffd"
	[ -f "$SRC" ] && { cp "$SRC" "$STUBS"; echo "note: provided o.stubsg (= APCS-32 o.stubs) for this project"; }
fi

# Run amu via an Obey file rather than as a bare command, so that WimpSlot and
# amu land in the *same* OS_CLI. Each rpcemu-run command is its own OS_CLI, so a
# WimpSlot issued as a separate command is gone again before amu starts -- amu
# then inherits whatever slot the desktop left, which fits amu plus cmhg/objasm/
# Link but not amu plus cc (~420K), and cc dies with "No writable memory at this
# address". The DDE's own !AMU asks for the same 1024k (Apps/DDE/!AMU/Desc).
SLOT=${DDE_WIMPSLOT:-1024k}
OBEY="$INSTALL/hostfs/ddeamu,feb"
{
	echo "WimpSlot -min $SLOT"
	echo "Dir $P"
	echo "amu $*"
} > "$OBEY"

echo "=== amu $* in $P (WimpSlot $SLOT) ==="
ro Obey "HostFS::HostFS.\$.ddeamu"
