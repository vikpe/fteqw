// SPDX-License-Identifier: 0BSD
//
// Hub demo-event subsystem. Two-phase observe-then-reconcile pipeline:
// hooks fired from cl_parse.c / cl_ents.c / fragstats.c during a
// no-render replay append into per-kind raw buffers; after the replay,
// a single reconciliation pass merges the buffers into the
// consumer-facing event array (TOOK / DEATH / MOD_EVENT).

#ifndef CL_HUB_DEMO_EVENT_H
#define CL_HUB_DEMO_EVENT_H

#include "quakedef.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
	HDE_KIND_TOOK         = 0,
	HDE_KIND_DEATH        = 1,
	HDE_KIND_MOD_EVENT    = 2,
	// Legacy enum slots: still referenced by fragstats.c so the
	// Stats_Evaluate dispatch can tag the rune/flag cases. Phase 1
	// translates these into the appropriate raw buffer entry.
	HDE_KIND_FLAG_TOUCH   = 3,
	HDE_KIND_FLAG_CAPTURE = 4,
	HDE_KIND_FLAG_DROP    = 5,
} hub_demo_event_kind_t;

typedef enum {
	HDE_MOD_CTF_CAPTURE = 0,
} hub_demo_mod_event_kind_t;

// UTF-8 expansion of MAX_SCOREBOARDNAME (64 raw bytes) - each byte
// may expand to up to 2 UTF-8 bytes for Latin-1 codepoint mapping.
#define HUB_DEMO_EVENT_NAME_BYTES 256
// Obit text storage on death events. Matches fragstats line cap.
#define HUB_DEMO_OBIT_BYTES 256

typedef struct {
	int          time_ms;
	int          user_id;            // the picker
	unsigned int items;              // single IT_* bit
	float        origin[3];
	int          backpack_user_id;   // dropper if from a backpack, else 0
} hub_demo_took_t;

typedef struct {
	int          user_id;
	unsigned int items;              // STAT_ITEMS at this side of the kill
	float        origin[3];
	unsigned int weapon_id;          // fragstats wid; 0 if unattributed
} hub_demo_death_user_t;

typedef struct {
	int                   time_ms;
	char                  message[HUB_DEMO_OBIT_BYTES];
	hub_demo_death_user_t victim;
	hub_demo_death_user_t killer;     // user_id == victim for suicide;
	                                  // user_id == 0 / all zero for unattributed.
} hub_demo_death_t;

typedef struct {
	int                       time_ms;
	int                       user_id;
	hub_demo_mod_event_kind_t mod_kind;
	float                     origin[3];
} hub_demo_mod_event_t;

typedef struct {
	hub_demo_event_kind_t kind;
	union {
		hub_demo_took_t      took;
		hub_demo_death_t     death;
		hub_demo_mod_event_t mod;
	} u;
} hub_demo_event_t;

typedef struct {
	int      user_id;
	char     name[HUB_DEMO_EVENT_NAME_BYTES];
	char     team[HUB_DEMO_EVENT_NAME_BYTES];
	qboolean is_active;
} hub_demo_player_t;

typedef struct {
	int          user_id;
	int          start_ms;
	int          end_ms;
	unsigned int items;
	int          frag_count;
	qboolean     was_dropped;
} hub_demo_span_t;

extern hub_demo_event_t  *hub_demo_events;
extern int                hub_demo_event_count;
extern hub_demo_player_t *hub_demo_players;
extern int                hub_demo_player_count;
extern hub_demo_span_t   *hub_demo_spans;
extern int                hub_demo_span_count;

void     Hub_DemoEvent_Init(void);

// Trigger a fast-parse scan of the current demo. Idempotent per demo
// path. Returns hub_demo_event_count, or -1 when the demo is not
// scannable (no demo, qtv stream, unseekable, non-MVD).
int      Hub_DemoEvent_Scan(void);

qboolean Hub_DemoEvent_IsRecording(void);
qboolean Hub_DemoEvent_InMatchTime(void);
int      Hub_DemoEvent_TimeMs(void);

// Phase-1 hooks. All no-op unless Hub_DemoEvent_IsRecording().
void Hub_DemoEvent_OnStatUpdate(int slot, unsigned int stat,
                                int old_ivalue, int new_ivalue);
void Hub_DemoEvent_OnPlayerinfo(int slot);
void Hub_DemoEvent_OnFragStatsKill(int killer_slot, int victim_slot,
                                   int weapon_id, const char *death_message);
void Hub_DemoEvent_OnFragStatsFlag(int player_slot,
                                   hub_demo_event_kind_t kind);
void Hub_DemoEvent_OnFragStatsRune(int player_slot, unsigned int rune_bit);
void Hub_DemoEvent_OnKtxDrop(int player_slot, unsigned int items,
                             const float *origin, unsigned int entnum);
void Hub_DemoEvent_OnKtxBackpackPickup(int player_slot, unsigned int entnum);

// Damage observation hook (MVD-only, mvdhidden_dmgdone). Used in
// phase-2 reconciliation as a conservative tie-breaker for
// unattributed deaths.
void Hub_DemoEvent_OnDamage(int attacker_slot, int target_slot,
                            int damage, qboolean is_team_damage,
                            qboolean is_splash_damage);

// Raw svc_print line observation. Called from Stats_ParsePrintLine
// for every obit-channel print, regardless of whether fragstats
// matched a pattern. Phase 2 attaches the nearest line to deaths
// whose death_message is otherwise empty — lets the consumer side
// see unmatched obits ("X mows down a teammate" etc.) for debugging.
void Hub_DemoEvent_OnPrint(const char *line);

// Called once per MVD packet after CLQW_ParseServerMessage finishes.
// Walks pending-origin entries and snapshots player origins captured
// for the just-completed frame. No-op outside scan.
void Hub_DemoEvent_OnFrameEnd(void);

#ifdef __cplusplus
}
#endif

#endif
