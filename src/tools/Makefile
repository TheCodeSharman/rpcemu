# Standalone host-side client for the HostCmd socket (see riscos-progs/HostCmd).
# It does NOT link the emulator core -- it is just a small socket client, so it
# builds on its own without qmake/Qt.
#
#   make -C src/tools        ->  src/tools/rpcemu-run
#
CC ?= cc
CFLAGS ?= -O2 -Wall

# The wire-protocol codec (../hostcmd_proto.c) is a shared module: the emulator
# links it via src/qt5/rpcemu.pro; this standalone client compiles it in directly
# (it does not link the emulator core).
rpcemu-run: rpcemu_run.c ../hostcmd_proto.c ../hostcmd_proto.h ../socket-compat.h
	$(CC) $(CFLAGS) -I.. -o $@ rpcemu_run.c ../hostcmd_proto.c

clean:
	$(RM) rpcemu-run

.PHONY: clean
