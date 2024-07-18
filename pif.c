/* SPDX-License-Identifier: GPL-2.0-or-later
 * Copyright Red Hat
 * Author: David Gibson <david@gibson.dropbear.id.au>
 *
 * Passt/pasta interface types and IDs
 */

#include <stdint.h>
#include <assert.h>
#include <netinet/in.h>

#include "util.h"
#include "pif.h"
#include "siphash.h"
#include "ip.h"
#include "inany.h"
#include "passt.h"

const char *pif_type_str[] = {
	[PIF_NONE]		= "<none>",
	[PIF_HOST]		= "HOST",
	[PIF_TAP]		= "TAP",
	[PIF_SPLICE]		= "SPLICE",
};
static_assert(ARRAY_SIZE(pif_type_str) == PIF_NUM_TYPES,
	      "pif_type_str[] doesn't match enum pif_type");


/** pif_sockaddr() - Construct a socket address suitable for an interface
 * @c:		Execution context
 * @sa:		Pointer to sockaddr to fill in
 * @sl:		Updated to relevant length of initialised @sa
 * @pif:	Interface to create the socket address
 * @addr:	IPv[46] address
 * @port:	Port (host byte order)
 */
void pif_sockaddr(const struct ctx *c, union sockaddr_inany *sa, socklen_t *sl,
		  uint8_t pif, const union inany_addr *addr, in_port_t port)
{
	const struct in_addr *v4 = inany_v4(addr);

	ASSERT(pif_is_socket(pif));

	if (v4) {
		sa->sa_family = AF_INET;
		sa->sa4.sin_addr = *v4;
		sa->sa4.sin_port = htons(port);
		memset(&sa->sa4.sin_zero, 0, sizeof(sa->sa4.sin_zero));
		*sl = sizeof(sa->sa4);
	} else {
		sa->sa_family = AF_INET6;
		sa->sa6.sin6_addr = addr->a6;
		sa->sa6.sin6_port = htons(port);
		if (pif == PIF_HOST && IN6_IS_ADDR_LINKLOCAL(&addr->a6))
			sa->sa6.sin6_scope_id = c->ifi6;
		else
			sa->sa6.sin6_scope_id = 0;
		sa->sa6.sin6_flowinfo = 0;
		*sl = sizeof(sa->sa6);
	}
}
