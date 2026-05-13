// SPDX-License-Identifier: 0BSD
//
// Hub addon: client-side custom code that integrates with the FTEQW
// engine through well-defined hook points. Everything in here is
// additive to the upstream engine - keeping it isolated makes it
// straightforward to sync with upstream sources.

#ifndef CL_HUB_H
#define CL_HUB_H

// QTV match clock. Updated by the hooks below.
//   hub_qtv_match_in_progress  true while the match is ticking.
//   hub_qtv_match_time        seconds elapsed since match start, -1 if unknown.
extern qboolean hub_qtv_match_in_progress;
extern double   hub_qtv_match_time;

// Hook entry points called from the engine. Hub_ResetMatchState is
// declared in client.h and is also defined in cl_hub.c.
void Hub_CheckServerInfo(void);        // end of CL_CheckServerInfo
void Hub_HostFrame(double frametime);  // each Host_Frame tick

#endif
