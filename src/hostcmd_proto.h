/*
  RPCEmu - An Acorn system emulator

  HostCmd wire protocol — the single definition shared by the emulator-side
  server (hostcmd.c) and the host-side client (tools/rpcemu_run.c).

  The client sends one '\n'-terminated command line per request. The server
  streams back length-prefixed frames:

      [type:1][length:u32 big-endian][payload:length]

  Lengths and the 'D' return code are big-endian, i.e. network byte order, so
  the codec (hostcmd_proto.c) uses htonl()/ntohl() rather than hand-rolled shifts.

  This program is free software; you can redistribute it and/or modify it under
  the terms of the GNU General Public License as published by the Free Software
  Foundation; either version 2 of the License, or (at your option) any later
  version.
 */

#ifndef HOSTCMD_PROTO_H
#define HOSTCMD_PROTO_H

#include <stdint.h>

/* Server -> client frame types. */
#define HC_FRAME_OUTPUT	'O'	/* output chunk (streamed live)            */
#define HC_FRAME_DONE	'D'	/* command finished; payload = u32 BE rc   */
#define HC_FRAME_NOTICE	'X'	/* advisory text (banner, "busy", "reset") */

#define HC_FRAME_HDR_LEN 5	/* type(1) + length(4) */

/* First frame the server sends on connect (an HC_FRAME_NOTICE payload). */
#define HC_PROTO_BANNER	"RPCEmu HostCmd v1\n"

/*
 * A frame header — the fixed part of every frame. Only the header is modelled
 * as a data structure: the payload is never materialised whole. Both sides
 * stream it (the emulator copies it straight out of guest memory into its ring;
 * the client streams it to stdout in chunks), so a payload pointer here would
 * fight that and force large output to be buffered.
 */
typedef struct {
	uint8_t  type;	/* one of HC_FRAME_*     */
	uint32_t len;	/* payload length, bytes */
} hc_frame_header;

/* Serialise/parse a frame header (length in network / big-endian order). */
void hc_frame_header_encode(const hc_frame_header *h, uint8_t buf[HC_FRAME_HDR_LEN]);
void hc_frame_header_decode(const uint8_t buf[HC_FRAME_HDR_LEN], hc_frame_header *h);

/* Big-endian u32 codec for the 'D' return-code payload (a value, not a header). */
void     hc_put_u32(uint8_t p[4], uint32_t v);
uint32_t hc_get_u32(const uint8_t p[4]);

#endif /* HOSTCMD_PROTO_H */
