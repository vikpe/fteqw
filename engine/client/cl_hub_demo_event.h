// SPDX-License-Identifier: 0BSD
//
// Stub: the original event-extraction subsystem has been stripped
// pending a from-scratch rewrite per
// .claude/notes/demo_event_redesign.md. Public hook signatures
// remain so call sites in fragstats.c, cl_parse.c, cl_ents.c,
// cl_main.c, cl_demo.c, cl_hub_ktxstats.c keep compiling; every
// hook is a no-op until the new pipeline lands.
//
// Only `HDE_KIND_FLAG_TOUCH / _CAPTURE / _DROP` are still referenced
// outside this module (by fragstats.c). The original enum included
// HDE_KIND_DEATH / _ITEM_PICKUP / _BACKPACK_PICKUP and a wider event
// struct; those are gone with the implementation and will return
// (in different shape) when the rewrite lands.

#ifndef CL_HUB_DEMO_EVENT_H
#define CL_HUB_DEMO_EVENT_H

#include "quakedef.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
	HDE_KIND_FLAG_TOUCH   = 3,
	HDE_KIND_FLAG_CAPTURE = 4,
	HDE_KIND_FLAG_DROP    = 5,
} hub_demo_event_kind_t;

void     Hub_DemoEvent_Init(void);
qboolean Hub_DemoEvent_IsRecording(void);
qboolean Hub_DemoEvent_InMatchTime(void);
int      Hub_DemoEvent_TimeMs(void);

void Hub_DemoEvent_RegisterPlayer(int slot);
void Hub_DemoEvent_OnStatUpdate(int slot, unsigned int stat,
                                int old_ivalue, int new_ivalue);
void Hub_DemoEvent_OnPlayerinfo(int slot);
void Hub_DemoEvent_OnFragStatsKill(int killer_slot, int victim_slot, int wid,
                                   const char *obit_text);
void Hub_DemoEvent_OnFragStatsFlag(int player_slot,
                                   hub_demo_event_kind_t kind);
void Hub_DemoEvent_OnFragStatsRune(int player_slot, unsigned int rune_bit);
void Hub_DemoEvent_OnKtxDrop(int player_slot, unsigned int items,
                             const float *origin, unsigned int entnum);
void Hub_DemoEvent_OnKtxBackpackPickup(int player_slot, unsigned int entnum);

#ifdef __cplusplus
}
#endif

#endif
