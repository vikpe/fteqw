// SPDX-License-Identifier: 0BSD
//
// Hub addon: client-side custom code that integrates with the FTEQW
// engine through well-defined hook points. Keeping it isolated makes
// it straightforward to sync with upstream sources.

#ifndef CL_HUB_H
#define CL_HUB_H

// QTV match clock. Updated by the hooks below.
//   hub_match_in_progress  true while the match is ticking.
//   hub_match_elapsed         seconds elapsed since match start, -1 if unknown.
extern qboolean hub_match_in_progress;
extern double   hub_match_elapsed;

// Hook entry points called from the engine.
void Hub_CheckServerInfo(void);        // end of CL_CheckServerInfo
void Hub_HostFrame(double frametime);  // each Host_Frame tick

#endif
