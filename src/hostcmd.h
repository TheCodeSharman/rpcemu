/*
  RPCEmu - An Acorn system emulator

  HostCmd - expose the guest RISC OS command line to the host.

  The host connects to a local socket and submits command lines; a RISC OS
  gateway module (riscos-progs/HostCmd) polls the emulator for those commands
  via the ArcEm HostCmd SWI, runs each through OS_CLI capturing its output,
  and hands the output back over the same SWI to be streamed to the host.

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 2 of the License, or
  (at your option) any later version.
 */

#ifndef HOSTCMD_H
#define HOSTCMD_H

#include "hostfs.h"	/* ARMul_State + ARMul_LoadByte/StoreByte shims */

#ifdef __cplusplus
extern "C" {
#endif

/* SWI handler, dispatched on R9. Runs on the emulator thread (from opSWI). */
void hostcmd(ARMul_State *state);

/* Lifecycle - all invoked on the emulator thread, alongside the HostFS
   siblings in rpcemu.c, so no locking is required. */
void hostcmd_init(void);	/**< Create + bind + listen if enabled; else no-op. */
void hostcmd_reset(void);	/**< Abort any in-flight command on machine reset. */
void hostcmd_close(void);	/**< Tear down listener/client and unlink the socket. */
void hostcmd_poll(void);	/**< Non-blocking accept/recv/send; call each tick. */

#ifdef __cplusplus
}
#endif

#endif /* HOSTCMD_H */
