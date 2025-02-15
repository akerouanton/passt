// SPDX-License-Identifier: GPL-2.0-or-later

/* PASST - Plug A Simple Socket Transport
 *  for qemu/UNIX domain socket mode
 *
 * PASTA - Pack A Subtle Tap Abstraction
 *  for network namespace/tap device mode
 *
 * arp.c - ARP implementation
 *
 * Copyright (c) 2020-2021 Red Hat GmbH
 * Author: Stefano Brivio <sbrivio@redhat.com>
 */

#include <arpa/inet.h>
#include <limits.h>
#include <net/if.h>
#include <net/if_arp.h>
#include <netinet/if_ether.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <unistd.h>
#include <string.h>

#include "util.h"
#include "log.h"
#include "arp.h"
#include "dhcp.h"
#include "passt.h"
#include "tap.h"

/**
 * arp() - Check if this is a supported ARP message, reply as needed
 * @c:		Execution context
 * @p:		Packet pool, single packet with Ethernet buffer
 *
 * Return: 1 if handled, -1 on failure
 */
int arp(const struct ctx *c, const struct pool *p)
{
	unsigned char swap[4];
	struct ethhdr *eh;
	struct arphdr *ah;
	struct arpmsg *am;
	size_t l2len;

	eh = packet_get(p, 0, 0,			 sizeof(*eh), NULL);
	ah = packet_get(p, 0, sizeof(*eh),		 sizeof(*ah), NULL);
	am = packet_get(p, 0, sizeof(*eh) + sizeof(*ah), sizeof(*am), NULL);

	if (!eh || !ah || !am)
		return -1;

	if (ah->ar_hrd != htons(ARPHRD_ETHER)	||
	    ah->ar_pro != htons(ETH_P_IP)	||
	    ah->ar_hln != ETH_ALEN		||
	    ah->ar_pln != 4			||
	    ah->ar_op  != htons(ARPOP_REQUEST))
		return 1;

	/* Discard announcements, but not 0.0.0.0 "probes" */
	if (memcmp(am->sip, &in4addr_any, sizeof(am->sip)) &&
	    !memcmp(am->sip, am->tip, sizeof(am->sip)))
		return 1;

	/* Don't resolve the guest's assigned address, either. */
	if (!memcmp(am->tip, &c->ip4.addr, sizeof(am->tip)))
		return 1;

	ah->ar_op = htons(ARPOP_REPLY);
	memcpy(am->tha,		am->sha,	sizeof(am->tha));
	memcpy(am->sha,		c->our_tap_mac,	sizeof(am->sha));

	memcpy(swap,		am->tip,	sizeof(am->tip));
	memcpy(am->tip,		am->sip,	sizeof(am->tip));
	memcpy(am->sip,		swap,		sizeof(am->sip));

	l2len = sizeof(*eh) + sizeof(*ah) + sizeof(*am);
	memcpy(eh->h_dest,	eh->h_source,	sizeof(eh->h_dest));
	memcpy(eh->h_source,	c->our_tap_mac,	sizeof(eh->h_source));

	tap_send_single(c, eh, l2len);

	return 1;
}
