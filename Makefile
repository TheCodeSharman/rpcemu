# Convenience wrapper around the qmake build in src/qt5/.
#
#   make            build the interpreter (default target)
#   make rebuild    clean build from scratch — use after switching branches
#                   (switching updates the source but never the binary)
#   make recompiler build the dynarec target (unstable; prefer interpreter)
#   make clean      remove build artefacts
#   make test       run all test suites present (unit + e2e; skips any absent)
#   make test-unit  Criterion IDE behaviour tests (tests/unit)
#   make test-e2e   pytest agent-drive end-to-end suite (tests/e2e)
#   make riscos-modules
#                   rebuild the RISC OS modules in riscos-progs/ into netroms/,
#                   using the ROOL DDE inside a BOOTED guest (see below)
#
# EVERYTHING here builds whatever tree/ is checked out at -- `make` on a feature
# branch yields an emulator with only that feature. The targets announce the
# branch for that reason. For the fully integrated build:
#     git -C tree checkout integration && make
#   make run        build + run the interpreter; defaults to native Wayland
#                   with an automatic X11/XWayland fallback. Force a platform
#                   with e.g. `make run QPA=xcb`.
#
# This wrapper lives on the upstream branch (git-conversion infra); it is not
# part of upstream RPCEmu and stays out of feature-vs-upstream diffs.

# The nested source worktree (upstream | feature/* | integration), created by
# tools/bootstrap.sh. The lab drives it from outside; it is not on any branch of
# the source, which is the whole point. See docs/reorg-plan.md.
TREE   := tree
QT5DIR := $(TREE)/src/qt5

# What tree/ is currently on. The emulator is built from whatever that is, so a
# build made while tree/ sits on one feature contains ONLY that feature -- and
# the lab-root symlink (which every install's `run` resolves) then points at it.
# Nothing about the binary says which branch produced it, so say it out loud.
TREE_REF := $(shell git -C $(TREE) rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')
TREE_SHA := $(shell git -C $(TREE) rev-parse --short HEAD 2>/dev/null || echo '?')
# Records which commit the objects in tree/src/qt5 were built from, so a build
# after tree/ has moved can clean first instead of silently mixing branches.
STAMP    := $(TREE)/.built-from
PRO    := rpcemu.pro
# qmake's DESTDIR puts the binary at the source-tree root on Linux, but on
# macOS it builds an application bundle and the executable lives inside it.
# Everything downstream (the lab symlink, `make run`, `make clean`) needs the
# real path, not the bundle.
ifeq ($(shell uname -s),Darwin)
INTERP := $(TREE)/rpcemu-interpreter.app/Contents/MacOS/rpcemu-interpreter
RECOMP := $(TREE)/rpcemu-recompiler.app/Contents/MacOS/rpcemu-recompiler
else
INTERP := $(TREE)/rpcemu-interpreter
RECOMP := $(TREE)/rpcemu-recompiler
endif
# nproc is coreutils (Linux); macOS has neither, so fall back to sysctl. An
# empty JOBS would become a bare `make -j`, i.e. unbounded parallelism.
JOBS   := $(shell nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)
# GCC 15 defaults to -std=gnu23 (C23), where bool/true/false are keywords and
# upstream's hand-rolled `typedef int bool` (hostfs.c) no longer compiles. Pin
# the C dialect to the pre-C23 default upstream built with (gcc 11-14 = gnu17)
# so the *unmodified* upstream source builds. C-only; C++/Qt keep gcc15's default.
CSTD   := -std=gnu17
# Qt platform for `make run`: on Linux try native Wayland, falling back to X11
# if there's no Wayland compositor (or qtwayland isn't installed). macOS has a
# single platform plugin, cocoa, compiled into qtbase -- forcing anything else
# there just fails to load.
ifeq ($(shell uname -s),Darwin)
QPA    ?= cocoa
else
QPA    ?= wayland;xcb
endif
# Name of the local RISC OS install to create/launch under installs/<NAME>/.
NAME   ?= riscos-371

# The install used as the RISC OS build machine for `riscos-modules`, and the
# modules to build from riscos-progs/.
DDE_INSTALL    ?= installs/riscos-530
RISCOS_MODULES ?= EtherRPCEm

.PHONY: all interpreter recompiler rebuild clean run setup-install \
        test test-unit test-e2e riscos-modules rpcemu-run

all: interpreter

# qmake writes the binary to the SOURCE-TREE root (rpcemu.pro: DESTDIR = ../..),
# i.e. $(TREE)/rpcemu-interpreter. The installs' `run` scripts resolve
# ../../rpcemu-interpreter, which lands at the LAB root -- so link it there.
#
# The link is made HERE, by the target that produces the binary, and not by
# bootstrap.sh: bootstrap runs BEFORE anything is built (on a fresh clone there
# is no binary to link), so a link made there would either dangle or be missing
# exactly when it is first needed.
# Auto-cleans when tree/ has moved since the last build. An incremental build
# after a branch switch is NOT the branch you are on: qmake's Makefile recompiles
# only what changed mtime, so objects from the previous branch survive and get
# linked in -- a binary that is a mixture of two branches while claiming to be
# one. (Observed: two builds of byte-identical source gave different binaries;
# the clean build is deterministic, so the odd one out was a stale mixture.)
# This is what the old "always make rebuild after switching branches" rule was
# for; better to make it impossible to forget than to write it down.
interpreter:
	@echo ">> building from tree/ @ $(TREE_REF) ($(TREE_SHA))"
	@if [ -f "$(STAMP)" ] && [ "$$(cat '$(STAMP)')" != "$(TREE_SHA)" ]; then \
		echo ">> tree/ moved since the last build ($$(cat '$(STAMP)') -> $(TREE_SHA)) — cleaning first"; \
		$(MAKE) --no-print-directory clean >/dev/null 2>&1 || true; \
	fi
	cd $(QT5DIR) && qmake -o Makefile QMAKE_CFLAGS+=$(CSTD) $(PRO) && $(MAKE) -j$(JOBS)
	@echo "$(TREE_SHA)" > "$(STAMP)"
	@ln -sfn $(INTERP) $(CURDIR)/rpcemu-interpreter
	@echo ">> rpcemu-interpreter is now the $(TREE_REF) build ($(TREE_SHA))"

recompiler:
	@echo ">> building from tree/ @ $(TREE_REF) ($(TREE_SHA))"
	cd $(QT5DIR) && qmake -o Makefile CONFIG+=dynarec QMAKE_CFLAGS+=$(CSTD) $(PRO) && $(MAKE) -j$(JOBS)
	@ln -sfn $(RECOMP) $(CURDIR)/rpcemu-recompiler

rebuild:
	$(MAKE) clean
	$(MAKE) interpreter

clean:
	-cd $(QT5DIR) && [ -f Makefile ] && $(MAKE) distclean
	$(RM) $(INTERP) $(RECOMP)
	$(RM) $(CURDIR)/rpcemu-interpreter $(CURDIR)/rpcemu-recompiler
	$(RM) $(STAMP)

# Launch an INSTALL, not the source tree. upstream TRACKS cmos.ram and rpc.cfg,
# so running with the source root as datadir dirties them every time (base used
# to delete them; a branch off upstream cannot, and ignoring a tracked file does
# nothing). An install's datadir is the install directory, so it stays clean.
run: interpreter
	@[ -x installs/$(NAME)/run ] || { \
		echo "error: no install at installs/$(NAME) — make setup-install NAME=$(NAME)"; exit 1; }
	@echo ">> launching installs/$(NAME) with the $(TREE_REF) build ($(TREE_SHA))"
	QT_QPA_PLATFORM="$(QPA)" RPCEMU=$(CURDIR)/$(INTERP) installs/$(NAME)/run

# Download + assemble a local RISC OS install under installs/$(NAME)/ (gitignored):
# ROM + HostFS tree + CMOS from the marutan 3.71 bundle, the HostFS poduleroms,
# a blank FileCore disc, and a `run` launcher. Then: ./installs/$(NAME)/run
setup-install:
	tools/setup-install.sh $(NAME)

# Test suites. They live HERE, on the lab, so they are always present and these
# targets no longer skip: a suite that quietly does nothing is worse than one
# that fails. (The e2e suite skipping instead of failing when rpcemu-run moved is
# exactly how a green run came to test nothing.) They exercise tree/, so point
# tree/ at the branch under test. Pass args with e.g. ARGS=--verbose.
test: test-unit test-e2e

test-unit:
	@$(MAKE) --no-print-directory -C tests/unit

test-e2e:
	@$(MAKE) --no-print-directory -C tests/e2e

# Rebuild the RISC OS modules in riscos-progs/ (EtherRPCEm, ...) into netroms/.
#
# They need Acorn's toolchain (cc/Norcroft, objasm, cmhg, Link, driven by amu),
# which has no Linux port -- so this drives `amu` on the project's own Makefile
# INSIDE a guest, over the HostCmd socket. See docs/dde-build.md.
#
# Requires $(DDE_INSTALL) to have the ROOL DDE installed (tools/dde/dde-setup.sh)
# and poduleroms/hostcmd,ffa, and to be BOOTED TO THE DESKTOP -- cc has no
# application slot before then. Boot it with: (cd $(DDE_INSTALL) && ./run) &
#
# The results are build artifacts: feature branches carry riscos-progs/ sources
# only (a binary cannot be composed by merging), and reintegrate.sh resets to
# base and so discards the last rebuild. Re-run this and commit netroms/ on
# integration after any reintegrate that touched riscos-progs/.
#
# Each run copies a pristine source tree in, so it is always a clean build.
# The HostCmd client the DDE build and the e2e suite drive the guest through.
# It lives in the source tree (feature/spork-hostcmd), not the lab.
rpcemu-run:
	@$(MAKE) --no-print-directory -C $(TREE)/src/tools

riscos-modules: rpcemu-run
	@[ -d $(TREE)/riscos-progs ] || { echo "error: no source tree at $(TREE)/ — run tools/bootstrap.sh"; exit 1; }
	@[ -S "$(DDE_INSTALL)/hostcmd.sock" ] || { \
		echo "error: no HostCmd socket at $(DDE_INSTALL)/hostcmd.sock"; \
		echo "       the build machine must be booted to the desktop first:"; \
		echo "           (cd $(DDE_INSTALL) && ./run) &"; \
		exit 1; }
	@for m in $(RISCOS_MODULES); do \
		echo "=== building $$m ==="; \
		rm -rf "$(DDE_INSTALL)/hostfs/Build/$$m" || exit 1; \
		mkdir -p "$(DDE_INSTALL)/hostfs/Build" || exit 1; \
		cp -a "$(TREE)/riscos-progs/$$m" "$(DDE_INSTALL)/hostfs/Build/$$m" || exit 1; \
		tools/dde/dde-amu.sh "$(DDE_INSTALL)" "Build.$$m" || exit 1; \
		[ -f "$(DDE_INSTALL)/hostfs/Build/$$m/$$m,ffa" ] || { \
			echo "error: $$m did not build (no $$m,ffa)"; exit 1; }; \
		cp "$(DDE_INSTALL)/hostfs/Build/$$m/$$m,ffa" "$(TREE)/netroms/$$m,ffa" || exit 1; \
		echo "    -> $(TREE)/netroms/$$m,ffa"; \
	done
	@echo "Rebuilt: $(RISCOS_MODULES) from tree/ @ $(TREE_REF). Commit netroms/ in $(TREE)/ on integration."
