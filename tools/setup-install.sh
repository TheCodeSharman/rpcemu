#!/usr/bin/env bash
#
# Recreate a local RISC OS install for RPCEmu from scratch — bundle-free.
#
# Produces  installs/<NAME>/  (installs/ is gitignored) containing:
#   hostfs/                       the universal !Boot tree, built fresh by the
#                                 RiscPc repo's riscos-boot-build (build.py).
#                                 Long names are native on HostFS, so the plain
#                                 (non-RaFS) !Packages build is used by default —
#                                 it boots on RISC OS 3.7 / 4.02 / 5.x alike.
#   roms/ROM<ver>                 a ROM from the RiscPc repo's roms/ (symlinked)
#   cmos.ram                      a known-good HostFS-boot RiscPC CMOS template
#                                 (tools/cmos/riscpc-hostfs.ram)
#   rpc.cfg                       generated here from MODEL / MEM / NETWORK
#   poduleroms/hostfs,ffa + hostfsfiler,ffa + SyncClock,ffa (+ hostcmd,ffa when
#                                 the spork-hostcmd feature is merged)
#                                 from the source tree's riscos-progs/, so RISC OS gets
#                                 the HostFS drive (+ its icon-bar filer)
#   netroms/EtherRPCEm,ffa        the emulated NIC driver, so networking has a
#                                 card to bind to
#   hd4.hdf                       a blank FileCore disc (for real IDE/SD or
#                                 E-format testing; unused by a HostFS boot)
#   run                           launcher: cd here + exec the emulator
#
# This replaces the old marutan RISC OS 3.71 Easy-Start bundle (Google Drive):
# build.py is now the authoritative, auditable source of the !Boot tree.
#
# Usage:   tools/setup-install.sh [NAME]          (or: make setup-install)
# Example: NAME=riscos-370 tools/setup-install.sh
#          NAME=riscos-530 MODEL=RPCSA MEM=256 ROM=".../RiscOS_5.30.rom" tools/setup-install.sh
#          # multi-boot (3-way ROM swap on one shared disc) — generates ./swap-rom:
#          NAME=riscos-multi \
#            EXTRA_ROMS="ROM402=.../RiscOS_4.02.rom ROM530=.../RiscOS_5.30_IOMD.rom" \
#            tools/setup-install.sh
# Needs:   the sibling RiscPc repo (for build.py + roms/) and its downloads
#          already fetched (build.py sha256-verifies them); nix for build deps.
#
set -euo pipefail

# --- paths -------------------------------------------------------------------
REPO="$(cd "$(dirname "$0")/.." && pwd)"                 # the lab (build infra)
TREE="${RPCEMU_TREE:-$REPO/tree}"                        # the nested source worktree
[ -d "$TREE/riscos-progs" ] || { echo "error: no source tree at $TREE -- run tools/bootstrap.sh" >&2; exit 1; }
BUILDER="$REPO/tools/riscos-boot-build"                  # in-repo !Boot builder
# ROMs are large binaries kept out of this repo. Point ROM= at one directly, or
# set RISCPC_REPO to a sibling RiscPc checkout to pick up its roms/ by default.
RISCPC_REPO="${RISCPC_REPO:-$REPO/../RiscPc}"

# --- config (env-overridable) ------------------------------------------------
NAME="${1:-${NAME:-riscos-370}}"
# ROM: any ROM file. Default is the 3.70 dump from a sibling RiscPc checkout.
ROM="${ROM:-$RISCPC_REPO/roms/4. Local Dump/RiscOS_3.70.rom}"
ROM_LABEL="${ROM_LABEL:-ROM370}"                         # name for the roms/ entry
# EXTRA_ROMS: space-separated LABEL=path entries for a multi-boot install. Each
# is symlinked into roms/ as an INACTIVE ".LABEL" (RPCEmu ignores dotted files);
# the generated swap-rom script activates one at a time. e.g.
#   EXTRA_ROMS="ROM402=/path/RiscOS_4.02.rom ROM530=/path/RiscOS_5.30_IOMD.rom"
EXTRA_ROMS="${EXTRA_ROMS:-}"
MODEL="${MODEL:-RPC710}"                                 # RPCEmu machine model
MEM="${MEM:-32}"                                         # RAM (MiB)
VRAM="${VRAM:-2}"                                        # VRAM (MiB)
# macOS has no TUN/TAP, so network-macosx.c stubs the bridging and IP
# tunnelling backends out; NAT (slirp) is the only one that works there.
if [ "$(uname -s)" = "Darwin" ]; then
	NETWORK="${NETWORK:-nat}"
else
	NETWORK="${NETWORK:-iptunnellingtap}"            # RPCEmu network_type
fi
TUNIF="${TUNIF:-rpctap0}"                                # tunnel interface
TUNIP="${TUNIP:-172.31.0.1}"                             # tunnel host IP
CMOS_SRC="${CMOS_SRC:-$REPO/tools/cmos/riscpc-hostfs.ram}"
# Pass PACKAGES_IN_RAFS=1 only when the target is a real 10-char E-format
# FileCore card (RISC OS 3.7 SD); HostFS never needs it.
PACKAGES_IN_RAFS="${PACKAGES_IN_RAFS:-0}"
# build.py enables the boot patches (RO4 support + multi-rom-safe) by default.
# Pass NO_BOOT_PATCHES=1 to turn both off for a vanilla ROOL boot -- e.g. a clean
# baseline to test networking.
NO_BOOT_PATCHES="${NO_BOOT_PATCHES:-0}"
# Symlink hostfs/Xfer -> this shared HostFS bridge if it exists (test convenience).
SHARED_XFER="${SHARED_XFER:-$REPO/installs/shared-xfer}"
# Blank FileCore disc size. Keep < 2^31 bytes (2048M) to dodge the FileCore
# >2 GB buffer bug on real CF/SD hardware; 2000M is comfortably under.
DISC_SIZE="${DISC_SIZE:-2000M}"

INSTALL="$REPO/installs/$NAME"

# --- guard -------------------------------------------------------------------
if [ -e "$INSTALL" ]; then
	echo "error: $INSTALL already exists — 'rm -rf' it first to rebuild" >&2
	exit 1
fi
[ -f "$BUILDER/build.py" ] || { echo "error: build.py not found at $BUILDER (set RISCPC_REPO)" >&2; exit 1; }
[ -f "$ROM" ]             || { echo "error: ROM not found: $ROM (set ROM)" >&2; exit 1; }
[ -f "$CMOS_SRC" ]        || { echo "error: CMOS template not found: $CMOS_SRC (set CMOS_SRC)" >&2; exit 1; }
echo ">> repo:       $REPO"
echo ">> riscpc:     $RISCPC_REPO"
echo ">> install:    $INSTALL"
echo ">> rom:        $ROM  (as roms/$ROM_LABEL)"
echo ">> model/mem:  $MODEL / ${MEM}M   network: $NETWORK"

# --- 1. build the universal !Boot tree (the hostfs) --------------------------
BUILD_ARGS=()
[ "$PACKAGES_IN_RAFS" = "1" ] && BUILD_ARGS+=(--packages-in-rafs)
[ "$NO_BOOT_PATCHES" = "1" ] && BUILD_ARGS+=(--no-risc-os-4-support --no-multi-rom-safe)
echo ">> building !Boot tree via build.py ${BUILD_ARGS[*]:-(plain !Packages)} ..."
python3 "$BUILDER/build.py" "${BUILD_ARGS[@]}"

# --- 2. assemble the install -------------------------------------------------
echo ">> assembling install ..."
mkdir -p "$INSTALL/hostfs"
cp -a "$BUILDER/build/disc/." "$INSTALL/hostfs/"
# Xfer bridge (optional test convenience)
if [ -d "$SHARED_XFER" ]; then
	ln -s "$SHARED_XFER" "$INSTALL/hostfs/Xfer"
fi

# ROM (symlinked so a re-dump upstream is picked up; RPCEmu joins roms/* < 2/4/6/8MiB)
mkdir -p "$INSTALL/roms"
ln -s "$ROM" "$INSTALL/roms/$ROM_LABEL"
cat > "$INSTALL/roms/roms.txt" <<'ROMS'
This directory needs to contain the RISC OS ROMs.  All files that don't
start with a "." or have the extension "txt" will be joined together in
alphabetical order to make up the ROM that RPCEmu uses.  The total
length of the ROM files must be 2, 4, 6, or 8MiB long.
ROMS

# Extra ROMs for a multi-boot install: symlinked INACTIVE (dotted) alongside the
# active primary; swap-rom (below) toggles which one RPCEmu loads.
if [ -n "$EXTRA_ROMS" ]; then
	for entry in $EXTRA_ROMS; do
		label="${entry%%=*}"; path="${entry#*=}"
		[ -f "$path" ] || { echo "error: EXTRA_ROMS file not found: $path" >&2; exit 1; }
		ln -s "$path" "$INSTALL/roms/.$label"
		echo ">> extra rom:  $path  (as roms/.$label, inactive)"
	done

	# swap-rom: switch the active ROM on this shared-disc multi-boot install.
	cat > "$INSTALL/swap-rom" <<'SWAP'
#!/usr/bin/env bash
# Switch the active RISC OS ROM on this shared-disc multi-boot install.
#
#   swap-rom            cycle to the next ROM (3.70 -> 4.02 -> 5.30 -> 3.70)
#   swap-rom 5.30       switch directly to a ROM (accepts 5.30, 530, or 5)
#   swap-rom -l         list available ROMs, marking the active one
#
# ROMs live in ./roms as ROMxxx (active) or .ROMxxx (inactive); RPCEmu loads
# only the single non-dotted one.
set -euo pipefail
R="$(cd "$(dirname "$0")" && pwd)/roms"

# Discover all ROMxxx (dotted or not) as bare codes, e.g. 370 402 530
mapfile -t codes < <(cd "$R" && ls -1 .ROM??? ROM??? 2>/dev/null | sed 's/^\.//; s/^ROM//' | sort -u)
[ "${#codes[@]}" -gt 0 ] || { echo "error: no ROMxxx files in $R" >&2; exit 1; }

# Current active = the one without a leading dot
cur=""; for c in "${codes[@]}"; do [ -e "$R/ROM$c" ] && cur="$c"; done

if [ "${1:-}" = "-l" ] || [ "${1:-}" = "--list" ]; then
	for c in "${codes[@]}"; do
		[ "$c" = "$cur" ] && echo "* $c (active)" || echo "  $c"
	done
	exit 0
fi

if [ $# -ge 1 ]; then
	# Requested version: drop dots, then match a ROM code exactly or by prefix
	# so "5.30", "530" and "5" all select ROM530.
	want="${1//./}"
	target=""
	for c in "${codes[@]}"; do [ "$c" = "$want" ] && target="$c"; done
	if [ -z "$target" ]; then
		for c in "${codes[@]}"; do [[ "$c" == "$want"* ]] && target="$c"; done
	fi
	[ -n "$target" ] || { echo "error: no ROM matches '$1' (have: ${codes[*]})" >&2; exit 1; }
else
	# No arg: cycle to the next ROM in discovered order
	target="${codes[0]}"
	for i in "${!codes[@]}"; do
		[ "${codes[$i]}" = "$cur" ] && target="${codes[$(( (i + 1) % ${#codes[@]} ))]}" && break
	done
fi

if [ "$target" = "$cur" ]; then
	echo ">> active ROM already: $target"
	exit 0
fi

[ -n "$cur" ] && mv "$R/ROM$cur" "$R/.ROM$cur"
mv "$R/.ROM$target" "$R/ROM$target"
echo ">> active ROM is now: $target"
SWAP
	chmod +x "$INSTALL/swap-rom"
	echo ">> wrote swap-rom (multi-boot ROM switcher)"
fi

# HostFS filing system + icon-bar filer (+ clock) as an extension podule ROM.
# Without this RISC OS never presents the HostFS drive.
mkdir -p "$INSTALL/poduleroms"
cp "$TREE/riscos-progs/HostFS/hostfs,ffa" \
   "$TREE/riscos-progs/HostFS/hostfsfiler,ffa" \
   "$INSTALL/poduleroms/"
cp "$TREE/riscos-progs/SyncClock/SyncClock,ffa" "$INSTALL/poduleroms/" 2>/dev/null || true

# HostCmd gateway module — lets the host drive the guest RISC OS command line
# over a socket (used by rpcemu-run and the MCP server). Provided by the
# spork-hostcmd feature, so it is optional here: present once that feature is
# merged (e.g. on the integration branch), a no-op otherwise.
cp "$TREE/riscos-progs/HostCmd/hostcmd,ffa" "$INSTALL/poduleroms/" 2>/dev/null || true

# Emulated NIC driver — network.c loads it from netroms/ at startup to build
# the network podule ROM; without it the guest has no network card.
mkdir -p "$INSTALL/netroms"
cp "$TREE/netroms/EtherRPCEm,ffa" "$INSTALL/netroms/"

# Known-good HostFS-boot RiscPC CMOS (version-neutral; 3.7 can re-Configure it).
cp "$CMOS_SRC" "$INSTALL/cmos.ram"

# Blank FileCore disc (sparse) — for real IDE/SD or E-format testing.
truncate -s "$DISC_SIZE" "$INSTALL/hd4.hdf"

# rpc.cfg
cat > "$INSTALL/rpc.cfg" <<CFG
[General]
bridgename=rpcemu
cdrom_enabled=0
cdrom_iso=
cdrom_type=0
cpu_idle=0
ipaddress=$TUNIP
macaddress=
mem_size=$MEM
model=$MODEL
mouse_following=1
mouse_twobutton=1
network_type=$NETWORK
refresh_rate=60
show_fullscreen_message=0
sound_enabled=1
tunnelinterface=$TUNIF
username=
vram_size=$VRAM

[nat_port_forward_rules]
size=0
CFG

# --- 3. launcher -------------------------------------------------------------
cat > "$INSTALL/run" <<'LAUNCH'
#!/usr/bin/env bash
# Launch RPCEmu with THIS directory as the RISC OS install (datadir="./").
# Needs a working rpcemu-interpreter and its runtime libraries on your shell.
# Override the binary with RPCEMU=/path/to/rpcemu-interpreter.
set -euo pipefail
INSTALL="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$INSTALL/../.." && pwd)"
BIN="${RPCEMU:-$REPO/rpcemu-interpreter}"
if [ ! -x "$BIN" ]; then
	echo "error: RPCEmu binary not found/executable: $BIN" >&2
	echo "       build it (make) or set RPCEMU=/path/to/rpcemu-interpreter" >&2
	exit 1
fi
cd "$INSTALL"
# Qt platform plugin: Linux wants native Wayland with an X11 fallback; macOS
# has only cocoa, and forcing anything else makes Qt abort at startup (which
# macOS then surfaces as a crash reporter dialog rather than an error).
#
# -style Fusion on macOS: Qt 5.15's native QMacStyle draws real AppKit controls
# through private NSView calls and SEGVs on modern macOS (seen on Darwin 24.5:
# QMacStylePrivate::drawNSViewInRect -> objc_msgSend -> EXC_BAD_ACCESS) the
# moment any dialog with a push button is painted -- an RPCEmu error box is
# enough. Fusion is drawn entirely by Qt and does not touch AppKit.
case "$(uname -s)" in
Darwin) exec "$BIN" -style Fusion ;;
*)      exec env QT_QPA_PLATFORM='wayland;xcb' "$BIN" ;;
esac
LAUNCH
chmod +x "$INSTALL/run"

echo ">> done: installs/$NAME"
echo ">> build the emulator if needed (make), then run:  ./installs/$NAME/run"
