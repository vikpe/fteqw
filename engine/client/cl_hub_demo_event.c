// SPDX-License-Identifier: 0BSD
//
// Stub: see cl_hub_demo_event.h. Original ~1400 line implementation
// lives in git history; replacement design is in
// .claude/notes/demo_event_redesign.md.

#include "quakedef.h"
#include "cl_hub_demo_event.h"

void Hub_DemoEvent_Init(void)            {}
qboolean Hub_DemoEvent_IsRecording(void) { return false; }
qboolean Hub_DemoEvent_InMatchTime(void) { return false; }
int      Hub_DemoEvent_TimeMs(void)      { return 0; }

void Hub_DemoEvent_RegisterPlayer(int slot)
{
	(void)slot;
}

void Hub_DemoEvent_OnStatUpdate(int slot, unsigned int stat,
                                int old_ivalue, int new_ivalue)
{
	(void)slot;
	(void)stat;
	(void)old_ivalue;
	(void)new_ivalue;
}

void Hub_DemoEvent_OnPlayerinfo(int slot)
{
	(void)slot;
}

void Hub_DemoEvent_OnFragStatsKill(int killer_slot, int victim_slot, int wid,
                                   const char *obit_text)
{
	(void)killer_slot;
	(void)victim_slot;
	(void)wid;
	(void)obit_text;
}

void Hub_DemoEvent_OnFragStatsFlag(int player_slot,
                                   hub_demo_event_kind_t kind)
{
	(void)player_slot;
	(void)kind;
}

void Hub_DemoEvent_OnFragStatsRune(int player_slot, unsigned int rune_bit)
{
	(void)player_slot;
	(void)rune_bit;
}

void Hub_DemoEvent_OnKtxDrop(int player_slot, unsigned int items,
                             const float *origin, unsigned int entnum)
{
	(void)player_slot;
	(void)items;
	(void)origin;
	(void)entnum;
}

void Hub_DemoEvent_OnKtxBackpackPickup(int player_slot, unsigned int entnum)
{
	(void)player_slot;
	(void)entnum;
}
