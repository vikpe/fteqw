// SPDX-License-Identifier: 0BSD
//
// Demo-state queries shared by the web bindings, the engine's serverkey
// hook (so CSQC sees the same answers), and any HUD widget that needs
// to adapt to single-POV vs multi-POV playback.

#ifndef CL_HUB_DEMO_H
#define CL_HUB_DEMO_H

#ifdef __cplusplus
extern "C" {
#endif

// Resolves the userid of the recording client for the active demo.
// Returns -1 outside of demo playback, when the demo is multi-POV
// (real MVD with no single recording client), or when the slot's
// userid isn't resolvable yet (early prespawn etc.).
//
// Slot source differs by format:
//   - QWD / NQ : cl.playerview[0].playernum (engine locks the POV
//     to the recording client).
//   - MVD : hub_demo_pov_slot from the timeline scan - the one
//     slot that ever appeared in dem_single / dem_stats /
//     dem_multiple records. -1 for real multi-POV files;
//     playerview[0].playernum follows the spectator camera in MVD
//     playback, not the recording POV.
int Hub_GetDemoPovUserId(void);

// True when the active demo effectively follows a single recording
// POV (QWD, NQ .dem, or an MVD that the timeline scan recognised as
// single-slot). False for real multi-POV MVDs and outside of demo
// playback. Used to gate UI elements that only make sense when the
// viewer can choose which player to spectate.
int Hub_IsSinglePovDemo(void);

// True when the active connection / demo is running a CTF or rune mod
// (detected by the presence of "rune/" entries in the sound precache,
// which all CTF/rune mods register for the rune pickup voiceovers).
// Works on legacy demos where serverinfo "mode" or "*gamedir" is
// absent. Used to gate HUD widgets that overlap with mode-specific
// STAT_ITEMS bit usage - e.g. KTX repurposes IT_SIGIL1..4 as a
// 5-minute-block timelimit indicator in non-CTF deathmatch, so the
// sigil/rune HUD slots should only render when the connection is
// actually a CTF/rune game.
int Hub_IsCtfMode(void);

#ifdef __cplusplus
}
#endif

#endif
