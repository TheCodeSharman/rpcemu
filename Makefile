# Convenience wrapper around the qmake build in src/qt5/.
#
#   make            build the interpreter (default target)
#   make rebuild    clean build from scratch — use after switching branches
#                   (switching updates the source but never the binary)
#   make recompiler build the dynarec target (unstable; prefer interpreter)
#   make clean      remove build artefacts
#   make run        build + run the interpreter
#                   override the Qt platform, e.g. `make run QPA=wayland`
#
# This wrapper lives on the upstream branch (git-conversion infra); it is not
# part of upstream RPCEmu and stays out of feature-vs-upstream diffs.

QT5DIR := src/qt5
PRO    := rpcemu.pro
JOBS   := $(shell nproc)
QPA    ?= xcb

.PHONY: all interpreter recompiler rebuild clean run

all: interpreter

interpreter:
	cd $(QT5DIR) && qmake -o Makefile $(PRO) && $(MAKE) -j$(JOBS)

recompiler:
	cd $(QT5DIR) && qmake -o Makefile CONFIG+=dynarec $(PRO) && $(MAKE) -j$(JOBS)

rebuild:
	$(MAKE) clean
	$(MAKE) interpreter

clean:
	-cd $(QT5DIR) && [ -f Makefile ] && $(MAKE) distclean
	$(RM) rpcemu-interpreter rpcemu-recompiler

run: interpreter
	QT_QPA_PLATFORM=$(QPA) ./rpcemu-interpreter
