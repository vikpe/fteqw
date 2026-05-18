// SPDX-License-Identifier: 0BSD
//
// Hub camera helpers. See cl_hub_cam.c.

#ifndef CL_HUB_CAM_H
#define CL_HUB_CAM_H

#ifdef __cplusplus
extern "C" {
#endif

// Called from CL_Init. Registers `track_userid` and any other hub-side
// camera commands so cl_cam.c stays clean of fork-specific dispatch.
void Hub_Cam_Init(void);

// Single-POV MVD wraps (e.g. QWD->MVD with one recording client) carry
// stats / origin only for that one slot. Cam_Lock consults this helper
// so any lock targeting a different slot - autotrack, demo-stuffcmd
// `ptrack`, manual `track <nick>`, csqc helpers - gets retargeted to
// the recording slot at the lowest level. Multi-POV MVDs and non-demo
// playback pass through unchanged.
int Hub_ResolveCamLockSlot(int requested_slot);

// Any explicit user-driven track command should flip the autotrack
// mode to TM_USER so a later automatic picker (killer / hightrack /
// stats) doesn't reclaim the camera on the next stats update. Called
// from Cam_Track_f and the hub command handlers.
void Hub_OnExplicitTrack(void);

// Locks the given seat's spectator camera onto the player carrying the
// requested userid. plrarg is a positive decimal string, or "off" to
// unlock. Numeric only - no nick fallback, no `#sortidx` branch - so
// callers that already know the userid (web client, csqc helpers)
// can't pull the wrong player when a nick happens to look like a
// digit string.
void Hub_TrackPlayerByUserid(int seat, char *plrarg);

#ifdef __cplusplus
}
#endif

#endif
