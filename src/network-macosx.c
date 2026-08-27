/*
  RPCEmu - An Acorn system emulator

  Copyright (C) 2016-2017 Matthew Howkins

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 2 of the License, or
  (at your option) any later version.

  This program is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details.

  You should have received a copy of the GNU General Public License
  along with this program; if not, write to the Free Software
  Foundation, Inc., 675 Mass Ave, Cambridge, MA 02139, USA.
 */

/* macOS host networking.

   macOS has no TUN/TAP device, so the Ethernet-bridging backend that
   network-linux.c provides has no equivalent here. These entry points are
   therefore stubs, and macOS reaches the network through NAT (slirp)
   instead -- see network-nat.c, which is userspace sockets and builds
   unchanged on macOS.

   network.c dispatches on the configured NetworkType, so the NAT path never
   passes through these functions. They exist because network.c is compiled
   unconditionally and references them. */

#include <stdint.h>

#include "rpcemu.h"
#include "network.h"

int
network_plt_init(void)
{
	/* No TUN/TAP on macOS; bridging is unavailable. */
	return 0;
}

void
network_plt_reset(void)
{
	/* No TUN/TAP on macOS; bridging is unavailable. */
}

uint32_t
network_plt_tx(uint32_t errbuf, uint32_t mbufs, uint32_t dest, uint32_t src,
               uint32_t frametype)
{
	NOT_USED(errbuf);
	NOT_USED(mbufs);
	NOT_USED(dest);
	NOT_USED(src);
	NOT_USED(frametype);

	return 0;
}

uint32_t
network_plt_rx(uint32_t errbuf, uint32_t mbuf, uint32_t rxhdr,
               uint32_t *dataavail)
{
	NOT_USED(errbuf);
	NOT_USED(mbuf);
	NOT_USED(rxhdr);
	NOT_USED(dataavail);

	return 0;
}

void
network_plt_setirqstatus(uint32_t address)
{
	NOT_USED(address);
}
