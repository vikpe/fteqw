// SPDX-License-Identifier: 0BSD
//
// Hub addon: client-side custom code that integrates with the FTEQW
// engine through well-defined hook points. Keeping it isolated makes
// it straightforward to sync with upstream sources.

#ifndef CL_HUB_H
#define CL_HUB_H

// Match clock state. Updated by the hooks below.
//   hub_match_in_progress     true while the match is ticking.
//   hub_match_elapsed_ms      ms elapsed since match start, -1 if unknown.
extern qboolean hub_match_in_progress;
extern double   hub_match_elapsed_ms;

// Registers hub console commands. Called from CL_Init.
void Hub_Init(void);

// QTV transition capture (cl_hub_vidweb.c): the backbuffer now, or deferred to the
// end of the current frame, before the gamma pass.
void Hub_CaptureBackbuffer(const char *texname);
void Hub_RequestTransitionCapture(void);
void Hub_RunPendingTransitionCapture(void);

// Hook entry points called from the engine.
void Hub_CheckServerInfo(void);        // end of CL_CheckServerInfo
void Hub_HostFrame(double frametime);  // each Host_Frame tick
void Hub_OnServerTimeStat(int slot);   // MVD/QTV STAT_TIME stored for `slot`
void Hub_ClearServerTimeStat(void);    // CL_ClearState

// Best-effort fetch of the matching `.loc` file from cl_download_mapsrc
// at world-BSP precache time. `bsp_filename` is the BSP path the engine
// is about to load (e.g. "maps/dm6.bsp"); a non-matching shape (wrong
// folder / extension / empty cvar / file already in FS) is a silent
// no-op. Reloads locs on arrival if the map has already loaded.
// Called from cl_parse.c's Model_CheckDownloads.
void Hub_RequestMapLoc(const char *bsp_filename);

// True for maps the map source serves as packaged/<map>.bsp.gz (lit and loc
// appended). `map_name` is the bare name, e.g. "dm4".
qboolean Hub_MapIsPackaged(const char *map_name);

#endif
