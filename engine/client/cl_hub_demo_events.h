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
	HDE_KIND_DEATH           = 0, // STAT_HEALTH transitioned from > 0 to <= 0
	HDE_KIND_PICKUP          = 1, // ground/spawn pickup (see `items` field)
	HDE_KIND_WEAPON_DROP     = 2, // player dropped a weapon backpack on death
	HDE_KIND_BACKPACK_PICKUP = 3, // a weapon backpack was picked up
} hub_demo_event_kind_t;

// UTF-8 expansion of MAX_SCOREBOARDNAME (64 raw bytes) - each byte may
// expand to up to 2 UTF-8 bytes for the Latin-1 codepoint mapping.
#define HUB_DEMO_EVENT_NAME_BYTES 256

typedef struct {
	int                   time_ms;     // demtime in ms
	hub_demo_event_kind_t kind;
	int                   victim_user_id;
	                                   // For HDE_KIND_DEATH: the victim.
	                                   // For HDE_KIND_PICKUP: the picker
	                                   // (field is shared - rename was
	                                   // chosen to match the more common
	                                   // death-event usage). Stable
	                                   // server-assigned userid; look up
	                                   // the display name via hub_demo_players.
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
	                                   // Unused for non-death events.
	unsigned int          items;       // For HDE_KIND_PICKUP: the engine IT_*
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
	                                   // name caller-side.
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
	int          frag_count;  // Kills the holder made while this span
	                          // was open. Attribution: when a death is
	                          // emitted with a killer, the killer's
	                          // currently-open spans for every weapon
	                          // bit set in their STAT_ITEMS at death
	                          // time get +1. Powerup spans count too;
	                          // self-frags don't.
	int          rl_kills;    // Of frag_count, kills where the killer
	                          // held RL but not LG at the moment of
	                          // the kill. Mutually exclusive with
	                          // lg_kills / rlg_kills.
	int          lg_kills;    // Killer held LG but not RL.
	int          rlg_kills;   // Killer held both RL and LG.
	                          // frag_count - rl_kills - lg_kills -
	                          // rlg_kills = "other" kills (axe, SG,
	                          // GL, etc.; not tracked).
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

void Hub_DemoEvents_Init(void);
void Hub_DemoEvents_Reset(void);

// Trigger a fast-parse scan of the current demo. No-op if the same demo
// has already been scanned. Returns hub_demo_event_count on success or
// when cached, -1 if not playing a demo / not seekable / not MVD.
// Blocks the caller for up to ~1s.
int Hub_DemoEvents_Scan(void);

// Lightweight variant: walks the demo file directly (no playback state
// machine, no CL_GetDemoMessage) and only parses mvdhidden_demoinfo
// frames so hub_ktxstats_json can be populated without the full event
// scan's ~1s cost. Early-exits once the final ktxstats chunk is
// observed. Returns 0 on success (or when cached / no stats present),
// -1 if the demo isn't scannable. No-op when the full events scan has
// already captured stats for this demo.
int Hub_DemoStats_Scan(void);

// Set by Hub_DemoEvents_Scan while it pumps the fast-parse loop. The
// CL_SetStatNumeric hook checks this before recording, so normal
// playback and user-initiated demo_jump don't pollute the array.
qboolean Hub_DemoEvents_IsRecording(void);

// Called from CL_SetStatNumeric in the MVD branch on every stat write,
// with the player's previous and new ivalue for that stat. No-op when
// not recording.
void Hub_DemoEvents_OnStatUpdate(int slot, unsigned int stat,
                                 int old_ivalue, int new_ivalue);

// Called from CL_ParseKtxItemTimer in the "//ktx took" branch (i.e.
// Cmd_Argc() >= 3, where Argv(2) is the player slot). `model` is the
// resolved model name from cl.model_name[ent->modelindex]; `skin` is
// `ent->skinnum`; `origin` is the item's baseline origin. No-op when
// not recording. Only emits events for kinds we care about (currently
// armor); other models are dropped.
void Hub_DemoEvents_OnKtxTook(int player_slot, const char *model, int skin,
                              const float *origin);

// Called from the //ktx drop parser in cl_parse.c. Splits the multi-bit
// `items` bitmask (e.g. IT_ROCKET_LAUNCHER | IT_LIGHTNING) into one
// HDE_KIND_WEAPON_DROP event per tracked bit (RL, LG only - other
// dropped weapons are ignored). victim_user_id on the emitted event is
// the dropper. origin is the backpack baseline position. `entnum` is
// the backpack entity number - stored so a later //ktx bp message can
// look up the bitmask and emit BACKPACK_PICKUP events. No-op when
// not recording or outside the match.
void Hub_DemoEvents_OnKtxDrop(int player_slot, unsigned int items,
                              const float *origin, unsigned int entnum);

// Called from the //ktx bp parser in cl_parse.c. Looks up the items
// bitmask previously stored by OnKtxDrop for `entnum` and emits one
// HDE_KIND_BACKPACK_PICKUP event per RL / LG bit it contained.
// Also primes a short suppression window so the corresponding
// STAT_ITEMS gain in update_item_spans does NOT also emit a
// duplicate HDE_KIND_PICKUP. No-op when not recording or outside
// the match.
void Hub_DemoEvents_OnKtxBackpackPickup(int player_slot, unsigned int entnum);

// Called from the mvdhidden_dmgdone parser in cl_parse.c. Stores the
// (attacker, time) pair per-victim so the next STAT_HEALTH -> 0
// transition can attribute the kill. attacker_slot may equal targ_slot
// for self damage; either may be -1 / out of range (caller passes 1-based
// entnums minus 1, world damage = no dmgdone so this isn't called).
// No-op when not recording.
void Hub_DemoEvents_OnDamage(int attacker_slot, int targ_slot,
                             unsigned int dmg_type);

// Called from CLEZ_ParseHiddenDemoMessage's mvdhidden_demoinfo branch.
// Reads the message body itself - either appends `payload_len` bytes
// to the captured ktxstats buffer (when scanning) or skips them (any
// other time). `is_more` is the 'more' field from the wire: nonzero
// means another mvdhidden_demoinfo will follow with the next chunk
// of the same payload, zero means this completes the JSON and
// hub_ktxstats_json becomes available.
void Hub_DemoEvents_OnDemoInfo(int payload_len, unsigned int is_more);

#ifdef __cplusplus
}
#endif

#endif
