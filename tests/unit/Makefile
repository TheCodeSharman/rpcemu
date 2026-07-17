# Criterion IDE behaviour tests. See README.md, and `make test-unit` at the
# repo top level.
#
#   make            compile + run the suite
#   make ARGS=...   pass arguments through to the test binary (Criterion flags,
#                   e.g. ARGS=--verbose or ARGS='--filter ide/soft*')
#
# The tests drive src/ide.c through its public register interface only, so
# ide.c is compiled + linked as a separate translation unit (NOT #included).
# Run from an integration checkout so ../../src/ide.c carries the fix. Needs
# the project devenv (gcc + criterion).

ROOT   := $(abspath $(CURDIR)/../..)
CFLAGS := -std=gnu17 -I$(ROOT)/src
ARGS   ?=

.PHONY: check
check:
	@out=$$(mktemp -d)/test_ide; \
	gcc $(CFLAGS) test_ide.c "$(ROOT)/src/ide.c" -lcriterion -o "$$out" && \
	"$$out" $(ARGS)

.DEFAULT_GOAL := check
