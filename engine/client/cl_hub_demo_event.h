// SPDX-License-Identifier: 0BSD
//
// Per-demo event extraction. Triggered by the `demo_events_scan` console
// command. Piggybacks on the engine's existing fast-parse seek path:
// rewinds the demo to the start, runs it forward at no-render speed while
// a recording flag is set, and observes per-player state transitions
// (STAT_HEALTH falling through 0 = death, STAT_ITEMS bit changes = pickup/
// span, svc_updatefrags deltas = NQ frag event) via hooks invoked from
// cl_parse.c. Restores the user's prior demtime when done.
//
// Format split:
//   cl_hub_demo_event - this file: orchestrator + shared state + QW-protocol
//                       KTX stufftext hooks (//ktx took/drop/bp).
//   cl_hub_mvd_event  - MVD binary-message hooks (mvdhidden_dmgdone,
//                       mvdhidden_demoinfo) and the standalone MVD stats
//                       file scanner.
//   cl_hub_dem_event  - NQ .dem-specific hooks (svc_updatefrags delta -> frag
//                       event with -1 sentinels for the unknown side).

#ifndef CL_HUB_DEMO_EVENT_H
#define CL_HUB_DEMO_EVENT_H

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
	// A player died. Sources, in decreasing completeness:
	//   - STAT_HEALTH > 0 -> <= 0 (MVD all-players, NQ POV only):
	//     origin set from playerstate, victim_items from cached
	//     STAT_ITEMS, killer attribution from mvdhidden_dmgdone (MVD)
	//     or empty.
	//   - svc_print obit parsed by fragstats: killer + weapon (wid in
	//     frag_type) from the obit text. origin (0,0,0) when no
	//     STAT_HEALTH transition was observed for the same victim
	//     (NQ non-POV), or filled in by the in-place promotion when
	//     STAT_HEALTH fires later (POV deaths / MVD).
	//   - svc_updatefrags negative delta (NQ-only): suicide. Killer =
	//     victim = self. No origin/items. Used when fragstats didn't
	//     match a suicide obit pattern.
	//   - svc_updatefrags positive delta (NQ-only): scorer-only kill.
	//     killer_user_id set, victim_user_id = -1. No origin.
	// Consumers can branch on victim_user_id == killer_user_id for
	// suicides; killer_user_id == -1 for "killer unknown"; origin ==
	// (0,0,0) for "no positional data".
	HDE_KIND_DEATH           = 0,
	HDE_KIND_ITEM_PICKUP     = 1, // ground/spawn pickup (see `items` field)
	HDE_KIND_BACKPACK_PICKUP = 2, // a weapon backpack was picked up
	HDE_KIND_FLAG_TOUCH      = 3, // CTF: player grabbed the flag.
	                              // victim_user_id = the grabber.
	HDE_KIND_FLAG_CAPTURE    = 4, // CTF: player capped the flag.
	                              // victim_user_id = the capper.
	HDE_KIND_FLAG_DROP       = 5, // CTF: player dropped the flag
	                              // (death / fumble). victim_user_id =
	                              // the dropper.
} hub_demo_event_kind_t;

// UTF-8 expansion of MAX_SCOREBOARDNAME (64 raw bytes) - each byte may
// expand to up to 2 UTF-8 bytes for the Latin-1 codepoint mapping.
#define HUB_DEMO_EVENT_NAME_BYTES 256

typedef struct {
	int                   time_ms;     // demtime in ms
	hub_demo_event_kind_t kind;
	int                   victim_user_id;
	                                   // For HDE_KIND_DEATH: the victim.
	                                   // For HDE_KIND_ITEM_PICKUP: the picker
	                                   // (field is shared - rename was
	                                   // chosen to match the more common
	                                   // death-event usage). Stable
	                                   // server-assigned userid; look up
	                                   // the display name via hub_demo_players.
	                                   // For HDE_KIND_FRAG: -1 when only
	                                   // the killer side is known
	                                   // (positive frag delta on NQ).
	int                   killer_user_id;
	                                   // For HDE_KIND_DEATH: userid of the
	                                   // player whose mvdhidden_dmgdone
	                                   // last hit the victim within the
	                                   // attribution window before
	                                   // STAT_HEALTH->0. Equals
	                                   // victim_user_id for self damage
	                                   // (rocket jump / explosion suicide).
	                                   // 0 = no attribution (world damage,
	                                   // lava/void, attacker dropped, etc.).
	                                   // For HDE_KIND_FRAG: -1 when only
	                                   // the victim side is known
	                                   // (negative frag delta on NQ).
	                                   // Unused for non-death/frag events.
	unsigned int          items;       // For HDE_KIND_ITEM_PICKUP: the engine IT_*
	                                   // bit picked up (e.g. IT_ARMOR3, IT_QUAD,
	                                   // IT_INVULNERABILITY, IT_INVISIBILITY).
	                                   // Same constants as STAT_ITEMS bits so
	                                   // consumers can mask directly. 0 for
	                                   // non-pickup events.
	unsigned int          victim_items;
	                                   // For HDE_KIND_DEATH: the victim's
	                                   // full STAT_ITEMS bitmask at the
	                                   // moment of death (cached from the
	                                   // most recent STAT_ITEMS update).
	                                   // Mask with IT_ROCKET_LAUNCHER etc.
	                                   // for "what did they have". 0 for
	                                   // non-death events.
	unsigned int          killer_items;
	                                   // For HDE_KIND_DEATH with attributed
	                                   // killer: the killer's STAT_ITEMS
	                                   // at the moment of death. 0 when
	                                   // killer_user_id == 0 (unattributed).
	unsigned int          frag_type;   // For HDE_KIND_DEATH with an
	                                   // attributed killer: the raw
	                                   // mvdhidden_dmgdone type field
	                                   // (KTX/server-defined dtype enum;
	                                   // splash flag stripped). 0 when
	                                   // killer_user_id == 0 or for
	                                   // non-death events. Consumers
	                                   // map known values (e.g.
	                                   // telefrag) to verbs.
	float                 origin[3];   // event position (player's
	                                   // playerstate.origin for deaths,
	                                   // item baseline.origin for KTX
	                                   // pickups). Resolve to a .loc area
	                                   // name caller-side. {0,0,0} for
	                                   // HDE_KIND_FRAG (no positional
	                                   // data on svc_updatefrags).
} hub_demo_event_t;

// One entry per distinct userid referenced by any event in the current
// scan. `name` is the first non-empty name seen for that userid during
// the scan; if a player joined mid-scan their entry tracks the name from
// their first observable event onward. `team` + `is_active` are
// finalized at end of scan from cl.players[] - is_active==true means
// the userid is still in the live, non-spectator scoreboard, so
// consumers can drop phantom entries (slots that briefly damaged
// someone but aren't actually playing). Consumers should look up
// event.victim_user_id / killer_user_id in this table to render a
// display name and to filter to the real match roster.
typedef struct {
	int      userid;
	char     name[HUB_DEMO_EVENT_NAME_BYTES];
	char     team[HUB_DEMO_EVENT_NAME_BYTES]; // UTF-8 team string; "" if no team / FFA
	qboolean is_active;                       // present in cl.players, non-spectator, at end of scan
} hub_demo_player_t;

// Closed time interval during which `user_id` held the weapon identified
// by the IT_* bit in `items`. Built engine-side from STAT_ITEMS
// transitions during the scan: a gain opens a span, a loss (including
// the STAT_ITEMS=0 write on death) closes and emits it. Open spans at
// end of scan get closed at the last observed demtime. items always
// carries exactly one bit; multi-weapon pickups (backpack) split into
// one span per weapon. Currently emitted for IT_ROCKET_LAUNCHER and
// IT_LIGHTNING only. No match-window gate - web filters using
// FteDemoInfo.countdown_ms.
typedef struct {
	int          start_ms;
	int          end_ms;
	int          user_id;
	unsigned int items;
	qboolean     was_dropped; // true if a //ktx drop for this weapon fired
	                          // shortly after the span closed (i.e. the
	                          // player died with the weapon and the
	                          // backpack landed). false if the span ended
	                          // any other way (intermission / scan end).
	int          frag_count;  // Kills the holder made during this span.
	                          // For every HDE_KIND_DEATH event whose
	                          // killer_user_id matches user_id and whose
	                          // time_ms falls in [start_ms, end_ms],
	                          // bump frag_count by 1. No weapon filter -
	                          // the span existing is the proof the holder
	                          // had the item, and self-frags (killer_user_id
	                          // == 0) skip naturally. A single death can
	                          // tally on multiple of a player's open spans
	                          // (e.g. RL + Quad held together both count
	                          // it); that's the intended semantic.
} hub_demo_span_t;

// Last-completed scan results. Empty until demo_events_scan is run.
extern hub_demo_event_t  *hub_demo_events;
extern int                hub_demo_event_count;
extern hub_demo_player_t *hub_demo_players;
extern int                hub_demo_player_count;
extern hub_demo_span_t   *hub_demo_spans;
extern int                hub_demo_span_count;

// JSON string captured from an mvdhidden_demoinfo (0x0003) message
// during the scan - the embedded ktxstats blob KTX writes at match
// end on some MVD demos. NULL until a complete ktxstats payload is
// observed. Owned by the events module; do not free.
extern char *hub_ktxstats_json;

void Hub_DemoEvent_Init(void);

// Trigger a fast-parse scan of the current demo. No-op if the same demo
// has already been scanned. Returns hub_demo_event_count on success or
// when cached, -1 if not playing a demo / not seekable. Accepts MVD and
// NQ (.dem) playback; QWD is not yet wired. Blocks the caller for up to
// ~1s.
int Hub_DemoEvent_Scan(void);

// Set by Hub_DemoEvent_Scan while it pumps the fast-parse loop. The
// per-format On*Update hooks check this before recording, so normal
// playback and user-initiated demo_jump don't pollute the array.
qboolean Hub_DemoEvent_IsRecording(void);

// True once demtime has crossed the timeline-scanned countdown, i.e.
// match-time >= 00:00. Exported so cl_hub_mvd_event / cl_hub_dem_event
// can gate their hooks on match-time without duplicating the demtime
// comparison.
qboolean Hub_DemoEvent_InMatchTime(void);

// Current demtime in ms, computed once and cached for callers.
int Hub_DemoEvent_TimeMs(void);

// Append `player_slot` to the event-scan player roster if not already
// present. Exported so format-specific hooks (frag events with no
// stat update to follow) can ensure their referenced userids are
// resolvable by consumers.
void Hub_DemoEvent_RegisterPlayer(int slot);

// Called from CL_SetStatNumeric in the MVD branch on every stat write,
// with the player's previous and new ivalue for that stat. Protocol-
// agnostic in shape; only wired from the MVD stat path today. No-op
// when not recording.
void Hub_DemoEvent_OnStatUpdate(int slot, unsigned int stat,
                                int old_ivalue, int new_ivalue);

// Called from Stats_Evaluate (fragstats.c) on every parsed obituary
// line. Slots are 0-based player slots; either may be -1 ("unknown")
// per the design rule - no guessing. `wid` is fragstats' weapon
// index (look up `fragstats.weapontotals[wid].codename` etc.). The
// hook emits a HDE_KIND_FRAG event with the weapon id stashed in
// `frag_type`, and primes a per-slot suppression window so the
// upcoming svc_updatefrags delta on the same slot does NOT also
// emit a coarser frag event for the same kill. No-op when not
// recording or outside match time.
void Hub_DemoEvent_OnFragStatsKill(int killer_slot, int victim_slot, int wid);

// Called from Stats_Evaluate (fragstats.c) when a CTF flag pattern
// matched. `kind` is one of HDE_KIND_FLAG_TOUCH / _CAPTURE / _DROP.
// Emits a single event with victim_user_id set to the acting player's
// userid and origin lifted from the player's current playerstate so
// the location field resolves on the map. No-op when not recording
// or outside match time.
void Hub_DemoEvent_OnFragStatsFlag(int player_slot, hub_demo_event_kind_t kind);

// Called from Stats_Evaluate (fragstats.c) when a rune pattern
// matched. `rune_bit` is IT_SIGIL1 / IT_SIGIL2 / IT_SIGIL3 / IT_SIGIL4
// for Resistance / Strength / Haste / Regeneration respectively.
// Emits HDE_KIND_ITEM_PICKUP with items=rune_bit (same shape as a weapon
// or armor pickup, just a different IT_* bit) and victim_user_id set
// to the picker. No-op when not recording or outside match time.
void Hub_DemoEvent_OnFragStatsRune(int player_slot, unsigned int rune_bit);

// Called from the //ktx drop parser in cl_parse.c. Splits the multi-bit
// `items` bitmask (e.g. IT_ROCKET_LAUNCHER | IT_LIGHTNING) into one
// HDE_KIND_WEAPON_DROP event per tracked bit (RL, LG only - other
// dropped weapons are ignored). victim_user_id on the emitted event is
// the dropper. origin is the backpack baseline position. `entnum` is
// the backpack entity number - stored so a later //ktx bp message can
// look up the bitmask and emit BACKPACK_PICKUP events. No-op when
// not recording or outside the match.
void Hub_DemoEvent_OnKtxDrop(int player_slot, unsigned int items,
                             const float *origin, unsigned int entnum);

// Called from the //ktx bp parser in cl_parse.c. Looks up the items
// bitmask previously stored by OnKtxDrop for `entnum` and emits one
// HDE_KIND_BACKPACK_PICKUP event per RL / LG bit it contained.
// Also primes a short suppression window so the corresponding
// STAT_ITEMS gain in update_item_spans does NOT also emit a
// duplicate HDE_KIND_ITEM_PICKUP. No-op when not recording or outside
// the match.
void Hub_DemoEvent_OnKtxBackpackPickup(int player_slot, unsigned int entnum);

#ifdef __cplusplus
}
#endif

#endif
