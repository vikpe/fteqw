// SPDX-License-Identifier: 0BSD
//
// Optional, explicit per-demo event extraction. Triggered by the
// `demo_events_scan` console command. Piggybacks on the engine's
// existing fast-parse seek path: rewinds the demo to the start, runs
// it forward at no-render speed while a recording flag is set, and
// observes per-player state transitions (currently STAT_HEALTH falling
// through 0 = death) via a hook in CL_SetStatNumeric. Restores the
// user's prior demtime when done.
//
// MVD-only for now: in MVD demos the server broadcasts dem_stats for
// every player slot, so cl.players[i].stats[STAT_HEALTH] is observable
// for everyone. QWD demos only carry the recording player's stats.

#ifndef CL_HUB_DEMO_EVENTS_H
#define CL_HUB_DEMO_EVENTS_H

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
	HDE_KIND_DEATH = 0, // STAT_HEALTH transitioned from > 0 to <= 0
} hub_demo_event_kind_t;

// UTF-8 expansion of MAX_SCOREBOARDNAME (64 raw bytes) - each byte may
// expand to up to 2 UTF-8 bytes for the Latin-1 codepoint mapping.
#define HUB_DEMO_EVENT_NAME_BYTES 256

typedef struct {
	int                   time_ms;     // demtime in ms
	hub_demo_event_kind_t kind;
	int                   victim_userid;
	                                   // cl.players[slot].userid - stable
	                                   // across renames; 0 if unknown
	char                  victim[HUB_DEMO_EVENT_NAME_BYTES];
	                                   // UTF-8-encoded name captured at
	                                   // the moment of the event (raw
	                                   // quake bytes mapped to Latin-1
	                                   // codepoints; ^X color codes
	                                   // stripped). So renames don't
	                                   // retroactively rewrite earlier
	                                   // deaths.
	float                 origin[3];   // victim's playerstate origin at the
	                                   // moment of the event - the most
	                                   // recently received position from
	                                   // svc_playerinfo (within ~50ms of
	                                   // the death). Resolve to a .loc
	                                   // area name caller-side.
} hub_demo_event_t;

// Last-completed scan results. Empty until demo_events_scan is run.
extern hub_demo_event_t *hub_demo_events;
extern int               hub_demo_event_count;

void Hub_DemoEvents_Init(void);
void Hub_DemoEvents_Reset(void);

// Trigger a fast-parse scan of the current demo. No-op if the same demo
// has already been scanned. Returns hub_demo_event_count on success or
// when cached, -1 if not playing a demo / not seekable / not MVD.
// Blocks the caller for up to ~1s.
int Hub_DemoEvents_Scan(void);

// Set by Hub_DemoEvents_Scan while it pumps the fast-parse loop. The
// CL_SetStatNumeric hook checks this before recording, so normal
// playback and user-initiated demo_jump don't pollute the array.
qboolean Hub_DemoEvents_IsRecording(void);

// Called from CL_SetStatNumeric in the MVD branch on every stat write,
// with the player's previous and new ivalue for that stat. No-op when
// not recording.
void Hub_DemoEvents_OnStatUpdate(int slot, unsigned int stat,
                                 int old_ivalue, int new_ivalue);

#ifdef __cplusplus
}
#endif

#endif
