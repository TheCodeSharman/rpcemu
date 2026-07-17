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
PRO    := rpcemu.pro
JOBS   := $(shell nproc)
# GCC 15 defaults to -std=gnu23 (C23), where bool/true/false are keywords and
# upstream's hand-rolled `typedef int bool` (hostfs.c) no longer compiles. Pin
# the C dialect to the pre-C23 default upstream built with (gcc 11-14 = gnu17)
# so the *unmodified* upstream source builds. C-only; C++/Qt keep gcc15's default.
CSTD   := -std=gnu17
# Qt platform for `make run`: try native Wayland, fall back to X11 if there's
# no Wayland compositor (or qtwayland isn't installed).
QPA    ?= wayland;xcb
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
interpreter:
	cd $(QT5DIR) && qmake -o Makefile QMAKE_CFLAGS+=$(CSTD) $(PRO) && $(MAKE) -j$(JOBS)
	@ln -sfn $(TREE)/rpcemu-interpreter $(CURDIR)/rpcemu-interpreter

recompiler:
	cd $(QT5DIR) && qmake -o Makefile CONFIG+=dynarec QMAKE_CFLAGS+=$(CSTD) $(PRO) && $(MAKE) -j$(JOBS)
	@ln -sfn $(TREE)/rpcemu-recompiler $(CURDIR)/rpcemu-recompiler

rebuild:
	$(MAKE) clean
	$(MAKE) interpreter

clean:
	-cd $(QT5DIR) && [ -f Makefile ] && $(MAKE) distclean
	$(RM) $(TREE)/rpcemu-interpreter $(TREE)/rpcemu-recompiler
	$(RM) $(CURDIR)/rpcemu-interpreter $(CURDIR)/rpcemu-recompiler

# Launch an INSTALL, not the source tree. upstream TRACKS cmos.ram and rpc.cfg,
# so running with the source root as datadir dirties them every time (base used
# to delete them; a branch off upstream cannot, and ignoring a tracked file does
# nothing). An install's datadir is the install directory, so it stays clean.
run: interpreter
	@[ -x installs/$(NAME)/run ] || { \
		echo "error: no install at installs/$(NAME) — make setup-install NAME=$(NAME)"; exit 1; }
	QT_QPA_PLATFORM="$(QPA)" RPCEMU=$(CURDIR)/$(TREE)/rpcemu-interpreter installs/$(NAME)/run

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
	@echo "Rebuilt: $(RISCOS_MODULES). Commit netroms/ in $(TREE)/ on integration."
