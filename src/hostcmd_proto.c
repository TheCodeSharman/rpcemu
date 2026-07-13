/*
  RPCEmu - An Acorn system emulator

  HostCmd wire protocol codec — see hostcmd_proto.h for the format. Kept in its
  own translation unit so both the emulator (hostcmd.c) and the standalone host
  client (tools/rpcemu_run.c) link one shared implementation.

  This program is free software; you can redistribute it and/or modify it under
  the terms of the GNU General Public License as published by the Free Software
  Foundation; either version 2 of the License, or (at your option) any later
  version.
 */

#include <string.h>

#include "socket-compat.h"	/* htonl / ntohl */
#include "hostcmd_proto.h"

void
hc_frame_header_encode(const hc_frame_header *h, uint8_t buf[HC_FRAME_HDR_LEN])
{
	uint32_t be = htonl(h->len);

	buf[0] = h->type;
	memcpy(&buf[1], &be, 4);
}

void
hc_frame_header_decode(const uint8_t buf[HC_FRAME_HDR_LEN], hc_frame_header *h)
{
	uint32_t be;

	h->type = buf[0];
	memcpy(&be, &buf[1], 4);
	h->len = ntohl(be);
}

void
hc_put_u32(uint8_t p[4], uint32_t v)
{
	uint32_t be = htonl(v);

	memcpy(p, &be, 4);
}

uint32_t
hc_get_u32(const uint8_t p[4])
{
	uint32_t be;

	memcpy(&be, p, 4);
	return ntohl(be);
}
