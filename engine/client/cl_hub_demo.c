// SPDX-License-Identifier: 0BSD

#include "quakedef.h"
#include "cl_hub_demo.h"
#include "cl_hub_demo_timeline.h"

int Hub_GetDemoPovUserId(void)
{
	if (cls.demoplayback == DPB_NONE)
		return -1;

	int slot;
	if (cls.demoplayback == DPB_MVD)
	{
		if (hub_demo_pov_slot >= 0)
			slot = hub_demo_pov_slot;
		else if (hub_demo_pov_slot == HUB_DEMO_POV_SLOT_FROM_PLAYERVIEW)
			slot = (int)cl.playerview[0].playernum;
		else
			return -1;  // real multi-POV MVD
	}
	else
		slot = (int)cl.playerview[0].playernum;

	if (slot < 0 || slot >= MAX_CLIENTS)
		return -1;
	if (cl.players[slot].userid <= 0)
		return -1;
	return cl.players[slot].userid;
}

int Hub_IsSinglePovDemo(void)
{
	if (cls.demoplayback == DPB_NONE)
		return 0;
	if (cls.demoplayback == DPB_MVD)
		return hub_demo_pov_slot != -1;  // explicit slot OR FROM_PLAYERVIEW sentinel
	return 1;  // QWD / NQ are single-POV by definition
}

// Detect a CTF/rune game by scanning the sound precache for any path
// rooted at "rune/" (rune pickup voiceovers - rune/rune1.wav etc).
// Works on legacy demos where serverinfo "mode" or "*gamedir" is absent
// but the mod's sounds are still in the precache list. Cached per
// connection via cl.servercount, which the engine bumps on every
// new server/demo handshake.
int Hub_IsCtfMode(void)
{
	static int cached_servercount = -1;
	static int cached_is_ctf      = 0;

	if (cached_servercount == cl.servercount)
		return cached_is_ctf;

	cached_is_ctf = 0;
	for (int i = 1; i < MAX_PRECACHE_SOUNDS; i++)
	{
		const char *s = cl.sound_name[i];
		if (!s) continue;
		if (!strncmp(s, "rune/", 5))
		{
			cached_is_ctf = 1;
			break;
		}
	}
	cached_servercount = cl.servercount;
	return cached_is_ctf;
}

