# Standalone host-side client for the HostCmd socket (see riscos-progs/HostCmd).
# It does NOT link the emulator core -- it is just a small socket client, so it
# builds on its own without qmake/Qt.
#
#   make -C src/tools        ->  src/tools/rpcemu-run
#
CC ?= cc
CFLAGS ?= -O2 -Wall

rpcemu-run: rpcemu_run.c ../socket-compat.h ../hostcmd_proto.h
	$(CC) $(CFLAGS) -o $@ rpcemu_run.c

clean:
	$(RM) rpcemu-run

.PHONY: clean
