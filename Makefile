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
#   make run        build + run the interpreter; defaults to native Wayland
#                   with an automatic X11/XWayland fallback. Force a platform
#                   with e.g. `make run QPA=xcb`.
#
# This wrapper lives on the upstream branch (git-conversion infra); it is not
# part of upstream RPCEmu and stays out of feature-vs-upstream diffs.

QT5DIR := src/qt5
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

.PHONY: all interpreter recompiler rebuild clean run setup-install \
        test test-unit test-e2e

all: interpreter

interpreter:
	cd $(QT5DIR) && qmake -o Makefile QMAKE_CFLAGS+=$(CSTD) $(PRO) && $(MAKE) -j$(JOBS)

recompiler:
	cd $(QT5DIR) && qmake -o Makefile CONFIG+=dynarec QMAKE_CFLAGS+=$(CSTD) $(PRO) && $(MAKE) -j$(JOBS)

rebuild:
	$(MAKE) clean
	$(MAKE) interpreter

clean:
	-cd $(QT5DIR) && [ -f Makefile ] && $(MAKE) distclean
	$(RM) rpcemu-interpreter rpcemu-recompiler

run: interpreter
	QT_QPA_PLATFORM="$(QPA)" ./rpcemu-interpreter

# Download + assemble a local RISC OS install under installs/$(NAME)/ (gitignored):
# ROM + HostFS tree + CMOS from the marutan 3.71 bundle, the HostFS poduleroms,
# a blank FileCore disc, and a `run` launcher. Then: ./installs/$(NAME)/run
setup-install:
	tools/setup-install.sh $(NAME)

# Test suites. Each lives on its own feature branch, so it is only present once
# merged (e.g. on the integration branch); a target skips cleanly if absent.
# Delegate to the suite's own Makefile. Pass args with e.g. ARGS=--verbose.
test: test-unit test-e2e

test-unit:
	@if [ -d tests/unit ]; then $(MAKE) --no-print-directory -C tests/unit; \
	else echo "skip test-unit: tests/unit not present (needs feature/ide-tests)"; fi

test-e2e:
	@if [ -d tests/e2e ]; then $(MAKE) --no-print-directory -C tests/e2e; \
	else echo "skip test-e2e: tests/e2e not present (needs feature/e2e-tests)"; fi
