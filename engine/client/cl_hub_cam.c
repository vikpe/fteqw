// SPDX-License-Identifier: 0BSD
//
// Hub-side camera helpers. Keeps the project's FTE-fork camera
// extensions out of upstream cl_cam.c. cl_cam.c only calls into here
// via the three Hub_* hooks declared in cl_hub_cam.h, plus
// Hub_Cam_Init from cl_main.c's CL_Init for command registration.

#include "quakedef.h"
#include "cl_hub_cam.h"
#include "cl_hub_demo.h"
#include "cl_hub_demo_timeline.h"

static void Hub_TrackUserid_f(void);

void Hub_Cam_Init(void)
{
	Cmd_AddCommand("track_userid", Hub_TrackUserid_f);
}

int Hub_ResolveCamLockSlot(int requested_slot)
{
	// Only fires when the timeline scan resolved a concrete slot
	// (hub_demo_pov_slot >= 0); the FROM_PLAYERVIEW sentinel (-2) is
	// treated as "engine already picked the slot" and left alone.
	if (cls.demoplayback == DPB_MVD
	    && hub_demo_pov_slot >= 0
	    && requested_slot != hub_demo_pov_slot)
		return hub_demo_pov_slot;
	return requested_slot;
}

void Hub_OnExplicitTrack(void)
{
	// Cam_AutoTrack_Update is idempotent (just assigns the file-local
	// autotrackmode enum), so we call it unconditionally rather than
	// reading the static state from cl_cam.c.
	Cam_AutoTrack_Update("user");
}

void Hub_TrackPlayerByUserid(int seat, char *plrarg)
{
	playerview_t *playerview = &cl.playerview[seat];
	int           slot;
	int           userid;
	char         *end_ptr;

	if (seat >= MAX_SPLITS)
		return;
	if (cls.state <= ca_connected) {
		Con_Printf("Not connected.\n");
		return;
	}
	if (!playerview->spectator) {
		Con_Printf("Not spectating.\n");
		return;
	}

	// Match the regular track command: any explicit pick takes the
	// camera off any auto-tracking mode.
	Hub_OnExplicitTrack();

	if (!Q_strcasecmp(plrarg, "off")) {
		Cam_Unlock(playerview);
		return;
	}

	userid = strtoul(plrarg, &end_ptr, 10);
	if (*end_ptr || userid <= 0) {
		Con_Printf("track_userid: expected numeric userid, got '%s'\n",
		           plrarg);
		return;
	}

	// Single-POV demo override: only the recording client has stats /
	// origin / item data in the file, so trying to track any other
	// player produces an empty camera. Force the lock onto the POV's
	// userid no matter what the caller asked for. Multi-POV MVDs fall
	// through with the original userid since every slot is valid
	// there.
	{
		int pov_userid = Hub_GetDemoPovUserId();
		if (Hub_IsSinglePovDemo() && pov_userid > 0 && userid != pov_userid)
			userid = pov_userid;
	}

	for (slot = 0; slot < cl.allocated_client_slots; slot++) {
		player_info_t *player = &cl.players[slot];
		if (player->name[0] && !player->spectator && player->userid == userid)
			break;
	}
	if (slot == cl.allocated_client_slots) {
		Con_Printf("Couldn't find userid %i\n", userid);
		return;
	}
	Cam_Lock(playerview, slot);
}

// track_userid <userid> [...]. Single-arg form (the only one the CSQC
// player_info click dispatch ever emits) resolves the seat from the
// targetted-split prefix, so "pN+1 track_userid <uid>" tracks in
// seat N.
static void Hub_TrackUserid_f(void)
{
	int arg_count = Cmd_Argc();

	if (arg_count < 2) {
		Con_Printf("Usage: %s userid|off [userid ...]\n", Cmd_Argv(0));
		return;
	}

	if (arg_count == 2) {
		Hub_TrackPlayerByUserid(CL_TargettedSplit(false), Cmd_Argv(1));
		return;
	}

	int seat_count = arg_count - 1;
	if (seat_count > MAX_SPLITS)
		seat_count = MAX_SPLITS;
	for (int seat = 0; seat < seat_count; seat++)
		Hub_TrackPlayerByUserid(seat, Cmd_Argv(seat + 1));
}
