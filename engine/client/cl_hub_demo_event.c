// SPDX-License-Identifier: 0BSD
//
// Hub demo-event subsystem — observe-then-reconcile pipeline.
// Public surface and rationale: cl_hub_demo_event.h.
//
// Phase 1: hooks called during a no-render demo replay append raw,
// single-frame observations into per-kind buffers. No cross-buffer
// references, no emit-while-uncertain rewriting.
//
// Phase 2: after the replay terminates, reconciliation walks the
// buffers and produces the consumer-facing event array.

#include "quakedef.h"
#include "cl_hub_demo_event.h"
#include "cl_hub_demo_timeline.h"
#include "cl_hub_participants.h"

extern float demtime;
extern void  Hub_ResetMatchState(void);
void         CL_PlayDemoStream(vfsfile_t *file, char *filename,
                               qboolean issyspath, int demotype,
                               float bufferdelay, unsigned int eztv_ext);
void         CL_PlayDemo(char *demoname, qboolean usesystempath);
qboolean     CL_GetDemoMessage(void);
void         CL_ReadPacket(void);

// ---- Public output -------------------------------------------------------

hub_demo_event_t  *hub_demo_events       = NULL;
int                hub_demo_event_count  = 0;
hub_demo_player_t *hub_demo_players      = NULL;
int                hub_demo_player_count = 0;
hub_demo_span_t   *hub_demo_spans        = NULL;
int                hub_demo_span_count   = 0;

static int events_capacity  = 0;
static int players_capacity = 0;
static int spans_capacity   = 0;

// ---- Scan state ----------------------------------------------------------

static qboolean is_recording = false;
static char     last_scanned_demo[MAX_OSPATH] = "";

// ---- Phase-1 raw buffers -------------------------------------------------

// All time values are demo-relative ms (Hub_DemoEvent_TimeMs()).
//
// Each buffer is append-only during the scan. Cross-buffer references
// (matching a death message to a STAT_HEALTH transition, pairing drops
// with backpack pickups) happen ONLY in phase 2.

typedef struct {
	int           time_ms;
	char          death_message[HUB_DEMO_OBIT_BYTES];
	qboolean      is_capture;                       // CTF flag-capture obit;
	                                                // reconcile emits as MOD_EVENT.

	int           killer_slot;                      // -1 = unknown; used at
	                                                // end-of-frame to snapshot
	                                                // killer_origin from cl.inframes
	int           killer_user_id;                   // -1 = unknown
	unsigned int  killer_items_snapshot;            // cached_items[killer_slot] at emit
	unsigned int  killer_weapon_id;                // IT_* bit derived from
	                                                // fragstats wid (= the weapon
	                                                // that did the damage, not
	                                                // STAT_ACTIVEWEAPON which lags
	                                                // the obit by 0-N frames)
	float         killer_origin_snapshot[3];        // captured at end-of-frame
	qboolean      is_killer_origin_valid;

	int           victim_user_id;                   // -1 = unknown
} raw_death_message_t;

typedef struct {
	int          time_ms;
	int          victim_slot;
	int          victim_user_id;
	unsigned int victim_items_cached;
	unsigned int victim_active_weapon_cached; // STAT_ACTIVEWEAPON at the
	                                          // moment of death — single
	                                          // IT_* bit identifying the
	                                          // selected weapon (= the
	                                          // weapon the victim drops).
	float        origin[3];                  // snapshotted at end-of-frame
	qboolean     is_consumed;                // set during phase 2 when matched
	qboolean     is_origin_pending;
} raw_death_t;

typedef struct {
	int          time_ms;
	int          user_id;
	unsigned int items;
	float        origin[3];
	int          backpack_user_id;           // resolved in phase 2; 0 if ground
} raw_took_t;

typedef struct {
	int          time_ms;
	unsigned int entnum;
	int          dropper_user_id;
	unsigned int items;
} raw_drop_t;

typedef struct {
	int          time_ms;
	unsigned int entnum;
	int          user_id;
} raw_backpack_pickup_t;

typedef struct {
	int      time_ms;
	int      attacker_user_id;
	int      target_user_id;
	int      damage;
	int      death_type_id;     // KTX dmgdone typeandflags with the splash
	                            // bit stripped — death category
	                            // (lava/drown/telefrag/...).
	qboolean is_splash_damage;  // KTX dmgdone splash flag; only set for
	                            // explosives.
	qboolean is_team_damage;
} raw_damage_t;

// Tracked STAT_ITEMS bits for hold-spans (weapons + powerups). Phase 1
// emits a TOOK on the gain edge and a loss row on the clear edge; phase
// 2 zips them per (user_id, bit) into hub_demo_spans entries.
static const unsigned int span_track_bits[] = {
	IT_ROCKET_LAUNCHER, IT_LIGHTNING,
	IT_QUAD, IT_INVULNERABILITY, IT_INVISIBILITY,
};
#define SPAN_TRACK_BIT_COUNT (sizeof(span_track_bits)/sizeof(span_track_bits[0]))

// Item-bit loss observation. Emitted when a tracked bit was set in the
// previous STAT_ITEMS snapshot and clears in the new one. Phase 2 pairs
// these with raw_tooks of the same bit and user_id to close hold spans
// — required for powerups that wear off mid-life with no death.
typedef struct {
	int          time_ms;
	int          user_id;
	unsigned int items;
} raw_items_loss_t;

// Raw svc_print line. Every obit-channel print is appended here for
// debug attachment to deaths that fragstats didn't classify.
typedef struct {
	int  time_ms;
	char text[HUB_DEMO_OBIT_BYTES];
} raw_print_t;

#define HDE_MAX_DEATH_MESSAGES   2048
#define HDE_MAX_DEATHS           2048
#define HDE_MAX_TOOKS            8192
#define HDE_MAX_ITEMS_LOSSES     8192
#define HDE_MAX_DROPS            2048
#define HDE_MAX_BACKPACK_PICKUPS 2048
#define HDE_MAX_DAMAGES         16384
#define HDE_MAX_PRINTS           4096

static raw_death_message_t   raw_death_messages[HDE_MAX_DEATH_MESSAGES];
static int                   raw_death_message_count;
static raw_death_t           raw_deaths[HDE_MAX_DEATHS];
static int                   raw_death_count;
static raw_took_t            raw_tooks[HDE_MAX_TOOKS];
static int                   raw_took_count;
static raw_items_loss_t      raw_items_losses[HDE_MAX_ITEMS_LOSSES];
static int                   raw_items_loss_count;
static raw_drop_t            raw_drops[HDE_MAX_DROPS];
static int                   raw_drop_count;
static raw_backpack_pickup_t raw_bp_pickups[HDE_MAX_BACKPACK_PICKUPS];
static int                   raw_bp_pickup_count;
static raw_damage_t          raw_damages[HDE_MAX_DAMAGES];
static int                   raw_damage_count;
static raw_print_t           raw_prints[HDE_MAX_PRINTS];
static int                   raw_print_count;

// First-seen STAT_HEALTH per slot is the initial spawn snapshot, not
// a death even if it happens to be 0.
static qboolean      has_seen_health[MAX_CLIENTS];
// STAT_ITEMS shadow updated unconditionally so phase 1 can fill
// victim_items at the moment of death without re-walking the demo.
static unsigned int  cached_items[MAX_CLIENTS];
// STAT_ACTIVEWEAPON shadow. Single IT_* bit identifying the currently
// selected weapon. Snapshotted onto raw_death_t at death so the
// consumer can render "victim dropped X" without guessing from the
// full items bitmask.
static unsigned int  cached_active_weapon[MAX_CLIENTS];

// Phase-1 participants set. Seeded by RegisterPlayer and by any hook
// touching a slot. Finalized in phase 2 from cl.players[].
static int  participants_slots[MAX_CLIENTS];
static int  participants_count;

// ---- Time gates ----------------------------------------------------------

int Hub_DemoEvent_TimeMs(void)
{
	return (int)floor(demtime * 1000) - hub_demo_start_offset_ms;
}

qboolean Hub_DemoEvent_IsRecording(void)
{
	return is_recording;
}

qboolean Hub_DemoEvent_InMatchTime(void)
{
	int t = Hub_DemoEvent_TimeMs();
	if (t < hub_demo_countdown_ms) return false;
	if (hub_demo_match_end_ms > 0 && t > hub_demo_match_end_ms) return false;
	return true;
}

// ---- Phase-1 helpers -----------------------------------------------------

static void participants_add(int slot)
{
	if (slot < 0 || slot >= MAX_CLIENTS) return;
	for (int i = 0; i < participants_count; i++)
		if (participants_slots[i] == slot) return;
	if (participants_count < MAX_CLIENTS)
		participants_slots[participants_count++] = slot;
}

static int slot_to_user_id(int slot)
{
	if (slot < 0 || slot >= MAX_CLIENTS) return -1;
	int user_id = cl.players[slot].userid;
	return user_id > 0 ? user_id : -1;
}

static void copy_player_origin(int slot, float *out)
{
	if (slot < 0 || slot >= MAX_CLIENTS) { VectorClear(out); return; }
	float *source = cl.inframes[cl.parsecount & UPDATE_MASK]
	                   .playerstate[slot].origin;
	out[0] = source[0]; out[1] = source[1]; out[2] = source[2];
}

// ---- Phase-1 hooks -------------------------------------------------------

void Hub_DemoEvent_OnStatUpdate(int slot, unsigned int stat,
                                int old_ivalue, int new_ivalue)
{
	if (!is_recording) return;
	if (slot < 0 || slot >= MAX_CLIENTS) return;

	if (stat == STAT_ACTIVEWEAPON)
	{
		// Tracked outside InMatchTime so the first death after warmup
		// has a valid snapshot. Single IT_* bit.
		cached_active_weapon[slot] = (unsigned int)new_ivalue;
		return;
	}

	if (stat == STAT_ITEMS)
	{
		// Track STAT_ITEMS shadow even outside match time so the first
		// real death after warmup reports a valid bitmask. Gain edges
		// emit TOOKs and loss edges emit items_losses only inside the
		// match window.
		unsigned int old_items = (unsigned int)old_ivalue;
		unsigned int new_items = (unsigned int)new_ivalue;
		unsigned int gained    = new_items & ~old_items;
		unsigned int lost      = old_items & ~new_items;
		cached_items[slot] = new_items;

		if (!Hub_DemoEvent_InMatchTime()) return;

		// Emit one TOOK per single bit gained. The redesign keeps the
		// per-bit shape so consumer weapon-span tracking can run
		// uniformly across ground, backpack, and rune sources.
		static const unsigned int track_bits[] = {
			IT_SHOTGUN, IT_SUPER_SHOTGUN, IT_NAILGUN, IT_SUPER_NAILGUN,
			IT_GRENADE_LAUNCHER, IT_ROCKET_LAUNCHER, IT_LIGHTNING,
			IT_ARMOR1, IT_ARMOR2, IT_ARMOR3,
			IT_SUPERHEALTH, IT_QUAD, IT_INVULNERABILITY, IT_INVISIBILITY,
			IT_KEY1, IT_KEY2,
			IT_SIGIL1, IT_SIGIL2, IT_SIGIL3, IT_SIGIL4,
		};
		int t = Hub_DemoEvent_TimeMs();
		int user_id = slot_to_user_id(slot);
		if (gained)
		{
			for (size_t w = 0; w < sizeof(track_bits)/sizeof(track_bits[0]); w++)
			{
				unsigned int bit = track_bits[w];
				if (!(gained & bit)) continue;
				if (raw_took_count >= HDE_MAX_TOOKS) break;
				raw_took_t *r = &raw_tooks[raw_took_count++];
				r->time_ms          = t;
				r->user_id          = user_id;
				r->items            = bit;
				r->backpack_user_id = 0;
				copy_player_origin(slot, r->origin);
			}
		}

		// Loss observation for span tracking. Restricted to span_track_bits
		// — phase 2 only pairs losses against these bits, so other
		// transitions (armor, mega, runes, keys) are intentionally dropped.
		if (lost)
		{
			for (size_t w = 0; w < SPAN_TRACK_BIT_COUNT; w++)
			{
				unsigned int bit = span_track_bits[w];
				if (!(lost & bit)) continue;
				if (raw_items_loss_count >= HDE_MAX_ITEMS_LOSSES) break;
				raw_items_loss_t *r = &raw_items_losses[raw_items_loss_count++];
				r->time_ms = t;
				r->user_id = user_id;
				r->items   = bit;
			}
		}

		if (gained || lost) participants_add(slot);
		return;
	}

	if (stat != STAT_HEALTH) return;

	if (!has_seen_health[slot])
	{
		has_seen_health[slot] = true;
		return;
	}
	if (!Hub_DemoEvent_InMatchTime()) return;
	if (!(old_ivalue > 0 && new_ivalue <= 0)) return;
	if (raw_death_count >= HDE_MAX_DEATHS) return;

	raw_death_t *r = &raw_deaths[raw_death_count++];
	r->time_ms                     = Hub_DemoEvent_TimeMs();
	r->victim_slot                 = slot;
	r->victim_user_id              = slot_to_user_id(slot);
	r->victim_items_cached         = cached_items[slot];
	r->victim_active_weapon_cached = cached_active_weapon[slot];
	VectorClear(r->origin);
	r->is_origin_pending           = true;
	r->is_consumed                 = false;
	participants_add(slot);
}

void Hub_DemoEvent_OnPlayerinfo(int slot)
{
	// Playerinfo origins are written into cl.inframes by the parser
	// before this hook runs; nothing extra to capture here. The
	// snapshot for pending deaths/killers happens at end-of-frame.
	(void)slot;
}

void Hub_DemoEvent_OnFragStatsKill(int killer_slot, int victim_slot,
                                   unsigned int killer_weapon_id,
                                   const char *death_message)
{
	if (!is_recording) return;
	if (!Hub_DemoEvent_InMatchTime()) return;
	if (raw_death_message_count >= HDE_MAX_DEATH_MESSAGES) return;

	int killer_user_id = slot_to_user_id(killer_slot);
	int victim_user_id = slot_to_user_id(victim_slot);
	if (killer_user_id < 0 && victim_user_id < 0) return;

	qboolean killer_slot_valid = (killer_slot >= 0 && killer_slot < MAX_CLIENTS);

	raw_death_message_t *r = &raw_death_messages[raw_death_message_count++];
	r->time_ms               = Hub_DemoEvent_TimeMs();
	r->killer_user_id        = killer_user_id;
	r->victim_user_id        = victim_user_id;
	r->killer_slot           = killer_slot;
	r->is_capture            = false;
	r->death_message[0]      = 0;
	if (death_message) Q_strncpyz(r->death_message, death_message, sizeof(r->death_message));
	VectorClear(r->killer_origin_snapshot);
	r->is_killer_origin_valid = false;
	r->killer_items_snapshot  = killer_slot_valid ? cached_items[killer_slot] : 0;
	r->killer_weapon_id      = killer_weapon_id;

	if (killer_slot >= 0) participants_add(killer_slot);
	if (victim_slot >= 0) participants_add(victim_slot);
}

void Hub_DemoEvent_OnFragStatsFlag(int player_slot,
                                   hub_demo_event_kind_t kind)
{
	// HDE_KIND_FLAG_TOUCH: not emitted. The obit only tells us a
	// flag was touched, not which (IT_KEY1 vs IT_KEY2). STAT_ITEMS
	// remains the sure source for both bit and timing.
	// HDE_KIND_FLAG_DROP: not a consumer event.
	if (kind != HDE_KIND_FLAG_CAPTURE) return;
	if (!is_recording) return;
	if (!Hub_DemoEvent_InMatchTime()) return;
	if (player_slot < 0 || player_slot >= MAX_CLIENTS) return;
	int user_id = slot_to_user_id(player_slot);
	if (user_id < 0) return;
	if (raw_death_message_count >= HDE_MAX_DEATH_MESSAGES) return;

	// Captures become MOD_EVENT(ctf_capture) in phase 2. Record as a
	// death-message with fftype=CAPTURE; the capper's origin is
	// snapshotted directly here (no end-of-frame defer) because the
	// actor is the victim_slot, not the killer_slot.
	raw_death_message_t *r = &raw_death_messages[raw_death_message_count++];
	r->time_ms                       = Hub_DemoEvent_TimeMs();
	r->killer_user_id                = -1;
	r->victim_user_id                = user_id;
	r->killer_slot                   = -1;
	r->is_capture                    = true;
	r->death_message[0]              = 0;
	copy_player_origin(player_slot, r->killer_origin_snapshot);
	r->is_killer_origin_valid        = true;
	r->killer_items_snapshot  = 0;
	r->killer_weapon_id      = 0;
	participants_add(player_slot);
}

void Hub_DemoEvent_OnFragStatsRune(int player_slot, unsigned int rune_bit)
{
	if (!is_recording) return;
	if (!Hub_DemoEvent_InMatchTime()) return;
	if (player_slot < 0 || player_slot >= MAX_CLIENTS) return;
	if (!rune_bit) return;
	int user_id = slot_to_user_id(player_slot);
	if (user_id < 0) return;
	if (raw_took_count >= HDE_MAX_TOOKS) return;

	raw_took_t *r = &raw_tooks[raw_took_count++];
	r->time_ms          = Hub_DemoEvent_TimeMs();
	r->user_id          = user_id;
	r->items            = rune_bit;
	r->backpack_user_id = 0;
	copy_player_origin(player_slot, r->origin);
	participants_add(player_slot);
}

void Hub_DemoEvent_OnKtxDrop(int player_slot, unsigned int items,
                             const float *origin, unsigned int entnum)
{
	(void)origin;  // dropper's playerstate origin isn't consumed by
	               // phase 2; backpacks are paired by entnum.
	if (!is_recording) return;
	if (player_slot < 0 || player_slot >= MAX_CLIENTS) return;
	if (!Hub_DemoEvent_InMatchTime()) return;
	if (raw_drop_count >= HDE_MAX_DROPS) return;

	raw_drop_t *r = &raw_drops[raw_drop_count++];
	r->time_ms         = Hub_DemoEvent_TimeMs();
	r->dropper_user_id = slot_to_user_id(player_slot);
	r->items           = items;
	r->entnum          = entnum;
	participants_add(player_slot);
}

void Hub_DemoEvent_OnKtxBackpackPickup(int player_slot, unsigned int entnum)
{
	if (!is_recording) return;
	if (player_slot < 0 || player_slot >= MAX_CLIENTS) return;
	if (!Hub_DemoEvent_InMatchTime()) return;
	if (raw_bp_pickup_count >= HDE_MAX_BACKPACK_PICKUPS) return;

	raw_backpack_pickup_t *r = &raw_bp_pickups[raw_bp_pickup_count++];
	r->time_ms = Hub_DemoEvent_TimeMs();
	r->user_id = slot_to_user_id(player_slot);
	r->entnum  = entnum;
	participants_add(player_slot);
}

void Hub_DemoEvent_OnPrint(const char *line)
{
	if (!is_recording) return;
	if (!Hub_DemoEvent_InMatchTime()) return;
	if (!line) return;
	if (raw_print_count >= HDE_MAX_PRINTS) return;

	raw_print_t *r = &raw_prints[raw_print_count++];
	r->time_ms = Hub_DemoEvent_TimeMs();
	Q_strncpyz(r->text, line, sizeof(r->text));
}

void Hub_DemoEvent_OnDamage(int attacker_slot, int target_slot,
                            int damage, int death_type_id,
                            qboolean is_team_damage,
                            qboolean is_splash_damage)
{
	if (!is_recording) return;
	if (!Hub_DemoEvent_InMatchTime()) return;
	if (raw_damage_count >= HDE_MAX_DAMAGES) return;
	int attacker_user_id = slot_to_user_id(attacker_slot);
	int target_user_id   = slot_to_user_id(target_slot);
	if (attacker_user_id < 0 || target_user_id < 0) return;

	raw_damage_t *r = &raw_damages[raw_damage_count++];
	r->time_ms          = Hub_DemoEvent_TimeMs();
	r->attacker_user_id = attacker_user_id;
	r->target_user_id   = target_user_id;
	r->damage           = damage;
	r->death_type_id    = death_type_id;
	r->is_team_damage   = is_team_damage;
	r->is_splash_damage = is_splash_damage;
}

void Hub_DemoEvent_OnFrameEnd(void)
{
	if (!is_recording) return;

	// Snapshot origin for any death whose origin is still pending —
	// the playerinfo for the victim's slot has now landed in
	// cl.inframes[parsecount].playerstate.
	for (int i = 0; i < raw_death_count; i++)
	{
		raw_death_t *d = &raw_deaths[i];
		if (!d->is_origin_pending) continue;
		copy_player_origin(d->victim_slot, d->origin);
		d->is_origin_pending = false;
	}

	// Snapshot killer origin for fresh death_messages emitted this
	// frame whose killer_slot resolves to a real slot. The most
	// recent death_message rows are at the tail; bail once we step
	// past anything older than the current frame.
	int t = Hub_DemoEvent_TimeMs();
	for (int i = raw_death_message_count - 1; i >= 0; i--)
	{
		raw_death_message_t *m = &raw_death_messages[i];
		if (m->is_killer_origin_valid) break;
		if (m->time_ms != t)           break;
		if (m->killer_slot < 0)        continue;
		copy_player_origin(m->killer_slot, m->killer_origin_snapshot);
		m->is_killer_origin_valid = true;
	}
}

// ---- Phase-2 reconciliation ---------------------------------------------

static void events_grow(void)
{
	if (hub_demo_event_count < events_capacity) return;
	int new_capacity = events_capacity ? events_capacity * 2 : 256;
	hub_demo_events = BZ_Realloc(hub_demo_events,
	                             sizeof(hub_demo_event_t) * new_capacity);
	events_capacity = new_capacity;
}

static void spans_grow(void)
{
	if (hub_demo_span_count < spans_capacity) return;
	int new_capacity = spans_capacity ? spans_capacity * 2 : 128;
	hub_demo_spans = BZ_Realloc(hub_demo_spans,
	                            sizeof(hub_demo_span_t) * new_capacity);
	spans_capacity = new_capacity;
}

static void players_grow(void)
{
	if (hub_demo_player_count < players_capacity) return;
	int new_capacity = players_capacity ? players_capacity * 2 : 32;
	hub_demo_players = BZ_Realloc(hub_demo_players,
	                              sizeof(hub_demo_player_t) * new_capacity);
	players_capacity = new_capacity;
}

static int find_or_add_player(int user_id, int slot_hint)
{
	for (int i = 0; i < hub_demo_player_count; i++)
		if (hub_demo_players[i].user_id == user_id) return i;
	players_grow();
	int index = hub_demo_player_count++;
	hub_demo_players[index].user_id   = user_id;
	hub_demo_players[index].name[0]   = 0;
	hub_demo_players[index].team[0]   = 0;
	hub_demo_players[index].is_active = false;
	if (slot_hint >= 0 && slot_hint < MAX_CLIENTS &&
	    cl.players[slot_hint].name[0])
	{
		Hub_QuakeStringToUnicode(cl.players[slot_hint].name,
		                         hub_demo_players[index].name,
		                         sizeof(hub_demo_players[index].name));
	}
	return index;
}

// Tolerance for pairing a death_message (with a known victim) to a
// raw_death of the same victim. Zero: require exact-ms match; anything
// that doesn't line up falls through to the salvage path and surfaces
// honestly as "unknown".
#define HDE_MATCH_WINDOW_MS   0

// Find the nearest unconsumed raw_death within ±window_ms of t.
// victim_user_id > 0: additionally require d->victim_user_id == that.
// victim_user_id <= 0: any victim (used for killer-only obits where
// the obit text didn't name the victim). Returns index, or -1.
static int find_nearest_unconsumed_death(int t, int window_ms,
                                         int victim_user_id)
{
	int best = -1, best_delta_ms = window_ms + 1;
	for (int i = 0; i < raw_death_count; i++)
	{
		raw_death_t *d = &raw_deaths[i];
		if (d->is_consumed) continue;
		if (victim_user_id > 0 && d->victim_user_id != victim_user_id)
			continue;
		int delta_ms = d->time_ms - t;
		if (delta_ms < 0) delta_ms = -delta_ms;
		if (delta_ms > window_ms) continue;
		if (delta_ms < best_delta_ms) { best_delta_ms = delta_ms; best = i; }
	}
	return best;
}

// Tolerance for damage→STAT_HEALTH-zero pairing. ~200ms covers the
// typical adjacent-packet jitter between the mvdhidden_dmgdone record
// and the resulting STAT_HEALTH=0 update without admitting chip damage
// from much earlier in the fight (damage_attribute also requires
// exactly ONE attacker with >=100 dmg, which guards against false
// positives on victims with armor/MH).
#define HDE_DMG_WINDOW_MS 200

// Damage-based killer attribution. Returns the attacker user_id when
// EXACTLY ONE attacker accumulated >=100 damage in the [t - window, t]
// window. Multiple candidates or no >=100 candidate => 0. Splash team
// damage is excluded (RL/GL chip on a teammate is incidental); direct
// team damage is admitted (telefrag / axe / shotgun teamkills).
static int damage_attribute(int victim_user_id, int t)
{
	int candidates[MAX_CLIENTS]; int damage_sum[MAX_CLIENTS]; int candidate_count = 0;
	memset(candidates, 0, sizeof(candidates));
	memset(damage_sum,        0, sizeof(damage_sum));
	for (int i = 0; i < raw_damage_count; i++)
	{
		raw_damage_t *r = &raw_damages[i];
		if (r->target_user_id != victim_user_id) continue;
		// Skip team-damage only when it's splash. Direct team damage
		// (telefrag, axe, shotgun) is a real one-shot teamkill that
		// the obit's ff_tkdeath pattern flagged; admitting it lets
		// damage_attribute return the teammate killer. Splash team
		// damage stays excluded — RL/GL chip damage to a teammate is
		// usually incidental and shouldn't get credited as the kill.
		if (r->is_team_damage && r->is_splash_damage) continue;
		int delta_ms = t - r->time_ms;
		if (delta_ms < 0 || delta_ms > HDE_DMG_WINDOW_MS) continue;
		int j;
		for (j = 0; j < candidate_count; j++) if (candidates[j] == r->attacker_user_id) break;
		if (j == candidate_count) { candidates[candidate_count] = r->attacker_user_id; candidate_count++; }
		damage_sum[j] += r->damage;
	}
	int hits = 0, winner = 0;
	for (int j = 0; j < candidate_count; j++)
		if (damage_sum[j] >= 100) { hits++; winner = candidates[j]; }
	return hits == 1 ? winner : 0;
}

// Fallback window for attaching the nearest svc_print line to a death
// whose message field is empty. Wide enough to span the typical packet
// jitter between the obit print and the STAT_HEALTH-zero update, tight
// enough to stay anchored to the right kill.
#define HDE_PRINT_ATTACH_WINDOW_MS 200

static void push_death_event(int time_ms, int victim_user_id, int killer_user_id,
                             unsigned int victim_weapon_id,
                             unsigned int killer_weapon_id,
                             unsigned int victim_items,
                             unsigned int killer_items,
                             const float *origin, const float *killer_origin,
                             const char *death_message)
{
	events_grow();
	hub_demo_event_t *ev = &hub_demo_events[hub_demo_event_count++];
	ev->kind                     = HDE_KIND_DEATH;
	ev->u.death.time_ms          = time_ms;
	ev->u.death.death_type_id    = 0;
	ev->u.death.victim.user_id   = victim_user_id;
	ev->u.death.victim.weapon_id = victim_weapon_id;
	ev->u.death.victim.items     = victim_items;
	ev->u.death.killer.user_id   = killer_user_id;
	ev->u.death.killer.weapon_id = killer_weapon_id;
	ev->u.death.killer.items     = killer_items;

	// death_type_id: KTX death_type_id from the most recent damage hit on this
	// victim within HDE_DMG_WINDOW_MS. mvdhidden_dmgdone is KTX-only so
	// this stays 0 on non-KTX MVDs and on demos with no damage stream.
	if (victim_user_id > 0)
	{
		int best_delta_ms = HDE_DMG_WINDOW_MS + 1;
		for (int i = 0; i < raw_damage_count; i++)
		{
			raw_damage_t *r = &raw_damages[i];
			if (r->target_user_id != victim_user_id) continue;
			int delta_ms = time_ms - r->time_ms;
			if (delta_ms < 0 || delta_ms > HDE_DMG_WINDOW_MS) continue;
			if (delta_ms >= best_delta_ms) continue;
			best_delta_ms             = delta_ms;
			ev->u.death.death_type_id = (unsigned int)r->death_type_id;
		}
	}
	if (origin) { ev->u.death.victim.origin[0]=origin[0]; ev->u.death.victim.origin[1]=origin[1]; ev->u.death.victim.origin[2]=origin[2]; }
	else        VectorClear(ev->u.death.victim.origin);
	if (killer_origin) { ev->u.death.killer.origin[0]=killer_origin[0]; ev->u.death.killer.origin[1]=killer_origin[1]; ev->u.death.killer.origin[2]=killer_origin[2]; }
	else               VectorClear(ev->u.death.killer.origin);
	ev->u.death.message[0] = 0;
	if (death_message) Q_strncpyz(ev->u.death.message, death_message,
	                          sizeof(ev->u.death.message));

	// Killer attribution fallback. For obits that named only the victim
	// (e.g. fragstats ff_tkdeath "X was telefragged by his teammate")
	// the caller passes killer_user_id=0. mvdhidden_dmgdone usually
	// carries the attacker; damage_attribute returns it when exactly
	// one player dealt >=100 dmg within HDE_DMG_WINDOW_MS — exactly
	// the telefrag / one-shot case.
	if (ev->u.death.killer.user_id == 0 && victim_user_id > 0)
	{
		int attributed = damage_attribute(victim_user_id, time_ms);
		if (attributed > 0) ev->u.death.killer.user_id = attributed;
	}

	// Debug: if no message was supplied by the matched obit (or the
	// salvage path), attach the nearest svc_print line within ±200ms.
	// Catches teamkill obits like "X checks his glasses" that fragstats
	// classifies as one-side patterns (the resulting raw_death_message
	// passes the print straight through) AND raw_deaths whose obit was
	// never matched at all.
	if (ev->u.death.message[0] == 0)
	{
		int best_delta_ms = HDE_PRINT_ATTACH_WINDOW_MS + 1;
		const char *nearest = NULL;
		for (int p = 0; p < raw_print_count; p++)
		{
			int delta_ms = time_ms - raw_prints[p].time_ms;
			if (delta_ms < 0) delta_ms = -delta_ms;
			if (delta_ms > HDE_PRINT_ATTACH_WINDOW_MS) continue;
			if (delta_ms >= best_delta_ms) continue;
			best_delta_ms = delta_ms;
			nearest       = raw_prints[p].text;
		}
		if (nearest)
			Q_strncpyz(ev->u.death.message, nearest,
			           sizeof(ev->u.death.message));
	}
}

static void push_mod_event(int time_ms, int victim_user_id,
                           hub_demo_mod_event_kind_t mod_kind,
                           const float *origin)
{
	events_grow();
	hub_demo_event_t *ev = &hub_demo_events[hub_demo_event_count++];
	ev->kind                  = HDE_KIND_MOD_EVENT;
	ev->u.mod.time_ms         = time_ms;
	ev->u.mod.user_id         = victim_user_id;
	ev->u.mod.mod_kind        = mod_kind;
	if (origin) { ev->u.mod.origin[0]=origin[0]; ev->u.mod.origin[1]=origin[1]; ev->u.mod.origin[2]=origin[2]; }
	else        VectorClear(ev->u.mod.origin);
}

static void push_took_event(const raw_took_t *r)
{
	events_grow();
	hub_demo_event_t *ev = &hub_demo_events[hub_demo_event_count++];
	ev->kind                    = HDE_KIND_TOOK;
	ev->u.took.time_ms          = r->time_ms;
	ev->u.took.user_id          = r->user_id;
	ev->u.took.items            = r->items;
	ev->u.took.backpack_user_id = r->backpack_user_id;
	ev->u.took.origin[0]        = r->origin[0];
	ev->u.took.origin[1]        = r->origin[1];
	ev->u.took.origin[2]        = r->origin[2];
}

static int event_time_ms(const hub_demo_event_t *ev)
{
	switch (ev->kind)
	{
	case HDE_KIND_TOOK:      return ev->u.took.time_ms;
	case HDE_KIND_DEATH:     return ev->u.death.time_ms;
	case HDE_KIND_MOD_EVENT: return ev->u.mod.time_ms;
	default:                 return 0;
	}
}

static int compare_event_time(const void *a, const void *b)
{
	int ta = event_time_ms((const hub_demo_event_t *)a);
	int tb = event_time_ms((const hub_demo_event_t *)b);
	return (ta > tb) - (ta < tb);
}

static void finalize_players(void)
{
	// Seed roster from participants set with phase-1 names.
	for (int i = 0; i < participants_count; i++)
	{
		int slot    = participants_slots[i];
		int user_id = slot_to_user_id(slot);
		if (user_id < 0) continue;
		find_or_add_player(user_id, slot);
	}

	// Reset team / is_active before walking the live roster.
	for (int i = 0; i < hub_demo_player_count; i++)
	{
		hub_demo_players[i].team[0]   = 0;
		hub_demo_players[i].is_active = false;
	}

	for (int slot = 0; slot < MAX_CLIENTS; slot++)
	{
		int user_id = slot_to_user_id(slot);
		if (user_id < 0) continue;
		if (cl.players[slot].spectator) continue;
		if (!cl.players[slot].name[0])  continue;

		int index = find_or_add_player(user_id, slot);
		if (hub_demo_players[index].name[0] == 0)
			Hub_QuakeStringToUnicode(cl.players[slot].name,
			                         hub_demo_players[index].name,
			                         sizeof(hub_demo_players[index].name));
		Hub_QuakeStringToUnicode(cl.players[slot].team,
		                         hub_demo_players[index].team,
		                         sizeof(hub_demo_players[index].team));
		hub_demo_players[index].is_active = true;
	}
}

// Build item-hold spans from raw gain/loss observations. Each span_bit
// is processed independently: gains and losses for the same (user_id,
// bit) are zipped in chronological order. An unmatched trailing gain
// closes at scan_end_ms with was_dropped=false. A loss matched against
// the immediately-prior gain marks was_dropped=true when a //ktx drop
// for that same (user_id, bit) lands within ~1s — captures the death-
// drop case for weapons; powerups (no drop signal) stay false.
#define HDE_DROP_WINDOW_MS 1000

static void finalize_spans(int scan_end_ms)
{
	for (size_t w = 0; w < SPAN_TRACK_BIT_COUNT; w++)
	{
		unsigned int bit = span_track_bits[w];

		// Collect gain times and loss times for this bit, per user_id.
		// raw_tooks and raw_items_losses are already in chronological
		// order within each buffer (append-only during a forward scan),
		// so a per-user_id linear walk preserves order.
		for (int gi = 0; gi < raw_took_count; gi++)
		{
			raw_took_t *gain = &raw_tooks[gi];
			if (gain->items != bit) continue;
			int user_id = gain->user_id;
			if (user_id <= 0) continue;

			// Find the next loss for this user_id+bit at time >= gain->time_ms.
			int end_ms = scan_end_ms;
			qboolean is_closed_by_loss = false;
			for (int li = 0; li < raw_items_loss_count; li++)
			{
				raw_items_loss_t *loss = &raw_items_losses[li];
				if (loss->items != bit) continue;
				if (loss->user_id != user_id) continue;
				if (loss->time_ms < gain->time_ms) continue;
				end_ms = loss->time_ms;
				is_closed_by_loss = true;
				break;
			}

			// Skip subsequent gains that fall inside [gain, end_ms) —
			// they are duplicates from the same hold (rare but possible
			// if a stat retransmits). Implementation: advance gi to the
			// last gain whose time_ms < end_ms, then continue the outer
			// loop from gi+1.
			while (gi + 1 < raw_took_count &&
			       raw_tooks[gi + 1].items == bit &&
			       raw_tooks[gi + 1].user_id == user_id &&
			       raw_tooks[gi + 1].time_ms < end_ms)
				gi++;

			// was_dropped: did a //ktx drop for this (user_id, bit) fire
			// within HDE_DROP_WINDOW_MS after the close?
			qboolean was_dropped = false;
			if (is_closed_by_loss)
			{
				for (int di = 0; di < raw_drop_count; di++)
				{
					raw_drop_t *drop = &raw_drops[di];
					if (drop->dropper_user_id != user_id) continue;
					if (!(drop->items & bit)) continue;
					int delta_ms = drop->time_ms - end_ms;
					if (delta_ms < -HDE_MATCH_WINDOW_MS) continue;
					if (delta_ms >  HDE_DROP_WINDOW_MS)  continue;
					was_dropped = true;
					break;
				}
			}

			spans_grow();
			hub_demo_span_t *sp = &hub_demo_spans[hub_demo_span_count++];
			sp->start_ms    = gain->time_ms;
			sp->end_ms      = end_ms;
			sp->user_id     = user_id;
			sp->items       = bit;
			sp->was_dropped = was_dropped;
			sp->frag_count  = 0;
		}
	}

	// Tally frags per span: every DEATH where killer == span.user_id
	// inside [start_ms, end_ms] counts. Self-frags (killer == 0) skip
	// naturally.
	for (int i = 0; i < hub_demo_span_count; i++)
	{
		hub_demo_span_t *sp = &hub_demo_spans[i];
		for (int j = 0; j < hub_demo_event_count; j++)
		{
			hub_demo_event_t *ev = &hub_demo_events[j];
			if (ev->kind != HDE_KIND_DEATH) continue;
			if (ev->u.death.killer.user_id != sp->user_id) continue;
			if (ev->u.death.time_ms < sp->start_ms)        continue;
			if (ev->u.death.time_ms > sp->end_ms)          continue;
			sp->frag_count++;
		}
	}
}

// Killer-only obit ("X gets a frag for the other team") has no victim
// name to validate against, so the only pairing signal is temporal
// proximity. Allow a small window even with HDE_MATCH_WINDOW_MS=0 so
// these one-sided matches still attach to the right raw_death.
#define HDE_KILLER_PAIR_WINDOW_MS 100

static void reconcile(int scan_end_ms)
{
	// Walk each death_message: emit captures as MOD_EVENT directly,
	// otherwise try to pair with an unconsumed raw_death (matched or
	// killer-only) and emit one DEATH event. Unmatched death_messages
	// fall through to a salvage push with whatever sides are known.
	for (int i = 0; i < raw_death_message_count; i++)
	{
		raw_death_message_t *m = &raw_death_messages[i];
		if (m->is_capture)
		{
			float *origin = m->is_killer_origin_valid ? m->killer_origin_snapshot
			                                          : NULL;
			push_mod_event(m->time_ms, m->victim_user_id,
			               HDE_MOD_CTF_CAPTURE, origin);
			continue;
		}

		// Two pairing modes for the death_message:
		//   victim known: validate against same-victim raw_death within
		//                 HDE_MATCH_WINDOW_MS (strict).
		//   killer-only:  pair with the closest unconsumed raw_death by
		//                 time alone, within HDE_KILLER_PAIR_WINDOW_MS.
		int death_index = -1;
		if (m->victim_user_id > 0)
		{
			death_index = find_nearest_unconsumed_death(
			                  m->time_ms, HDE_MATCH_WINDOW_MS,
			                  m->victim_user_id);
		}
		else if (m->killer_user_id > 0)
		{
			death_index = find_nearest_unconsumed_death(
			                  m->time_ms, HDE_KILLER_PAIR_WINDOW_MS, 0);
		}
		if (death_index >= 0)
		{
			raw_death_t *d = &raw_deaths[death_index];
			d->is_consumed = true;
			int killer_user_id = m->killer_user_id > 0 ? m->killer_user_id : 0;
			// killer.weapon_id is the IT_* bit fragstats resolved from
			// the obit pattern (ground truth — the weapon that did the
			// damage). victim.weapon_id is a STAT_ACTIVEWEAPON snapshot
			// at death (= the weapon the victim drops).
			push_death_event(d->time_ms, d->victim_user_id, killer_user_id,
			                 d->victim_active_weapon_cached,
			                 killer_user_id != 0 ? m->killer_weapon_id : 0,
			                 d->victim_items_cached,
			                 m->killer_items_snapshot,
			                 d->origin,
			                 m->is_killer_origin_valid ? m->killer_origin_snapshot : NULL,
			                 m->death_message);
		}
		else
		{
			// Salvage unmatched death_message: no raw_death paired, so
			// no STAT_ACTIVEWEAPON snapshot for the victim. Emit with
			// whatever sides are known; victim.weapon_id stays 0.
			int killer_user_id = m->killer_user_id > 0 ? m->killer_user_id : 0;
			int victim         = m->victim_user_id > 0 ? m->victim_user_id : -1;
			push_death_event(m->time_ms, victim, killer_user_id,
			                 0,
			                 killer_user_id != 0 ? m->killer_weapon_id : 0,
			                 0,
			                 m->killer_items_snapshot,
			                 NULL,
			                 m->is_killer_origin_valid ? m->killer_origin_snapshot : NULL,
			                 m->death_message);
		}
	}

	// Salvage raw_deaths that no death_message claimed (no fragstats
	// match at all). damage_attribute backfills the killer when
	// possible; push_death_event auto-attaches the nearest svc_print
	// line so unmatched obits ("X checks his glasses", "X mows down a
	// teammate") still surface for debugging.
	for (int i = 0; i < raw_death_count; i++)
	{
		raw_death_t *d = &raw_deaths[i];
		if (d->is_consumed) continue;
		int killer_user_id = damage_attribute(d->victim_user_id, d->time_ms);

		// killer_weapon_id / killer_items unavailable in the salvage
		// path — we have no death_message snapshot. victim.active_weapon
		// comes from STAT_ACTIVEWEAPON cached at the STAT_HEALTH→0
		// instant.
		push_death_event(d->time_ms, d->victim_user_id, killer_user_id,
		                 d->victim_active_weapon_cached, 0,
		                 d->victim_items_cached, 0,
		                 d->origin, NULL, NULL);
	}

	// Pair drops with backpack_pickups by entnum, annotate the
	// matching took with backpack_user_id.
	for (int i = 0; i < raw_drop_count; i++)
	{
		raw_drop_t *drop = &raw_drops[i];
		for (int j = 0; j < raw_bp_pickup_count; j++)
		{
			raw_backpack_pickup_t *bp = &raw_bp_pickups[j];
			if (bp->entnum != drop->entnum) continue;
			if (bp->time_ms < drop->time_ms) continue;

			// Find the tooks at this picker around bp->time_ms whose
			// item bit is in drop->items, and annotate.
			for (int k = 0; k < raw_took_count; k++)
			{
				raw_took_t *t = &raw_tooks[k];
				if (t->user_id != bp->user_id) continue;
				if (!(t->items & drop->items)) continue;
				int delta_ms = t->time_ms - bp->time_ms;
				if (delta_ms < -HDE_MATCH_WINDOW_MS || delta_ms > HDE_MATCH_WINDOW_MS)
					continue;
				if (t->backpack_user_id == 0)
					t->backpack_user_id = drop->dropper_user_id;
			}
			break;
		}
	}

	// Emit TOOKs.
	for (int i = 0; i < raw_took_count; i++)
		push_took_event(&raw_tooks[i]);

	// Stable chronological order — death/took/mod arrive interleaved.
	if (hub_demo_event_count > 0)
		qsort(hub_demo_events, hub_demo_event_count,
		      sizeof(hub_demo_event_t), compare_event_time);

	finalize_players();
	finalize_spans(scan_end_ms);
}

// ---- Reset ---------------------------------------------------------------

static void hde_reset(void)
{
	hub_demo_event_count  = 0;
	hub_demo_player_count = 0;
	hub_demo_span_count   = 0;

	raw_death_message_count = 0;
	raw_death_count         = 0;
	raw_took_count          = 0;
	raw_items_loss_count    = 0;
	raw_drop_count          = 0;
	raw_bp_pickup_count     = 0;
	raw_damage_count        = 0;
	raw_print_count         = 0;

	participants_count = 0;
	for (int i = 0; i < MAX_CLIENTS; i++)
	{
		has_seen_health[i]        = false;
		cached_items[i]           = 0;
		cached_active_weapon[i]   = 0;
	}
}

// ---- Scan dispatcher -----------------------------------------------------

int Hub_DemoEvent_Scan(void)
{
	if (!cls.demoplayback)
	{
		Con_Printf("not playing a demo\n");
		return -1;
	}
	if (cls.demoplayback != DPB_MVD &&
	    cls.demoplayback != DPB_QUAKEWORLD &&
	    cls.demoplayback != DPB_NETQUAKE)
	{
		Con_Printf("demo_events_scan: MVD / QWD / NQ only\n");
		return -1;
	}
	if (!*cls.lastdemoname)
	{
		Con_Printf("cannot scan qtv streams\n");
		return -1;
	}
	if (!cls.demoinfile || cls.demoinfile->seekstyle == SS_UNSEEKABLE)
	{
		Con_Printf("demo is not seekable\n");
		return -1;
	}

	if (last_scanned_demo[0] && !strcmp(last_scanned_demo, cls.lastdemoname))
	{
		Con_Printf("[demo-events] %d events (cached)\n",
		           hub_demo_event_count);
		return hub_demo_event_count;
	}

	extern cvar_t cl_demospeed;
	float    saved_time           = demtime > 0 ? demtime : 0;
	char     saved_name[MAX_OSPATH];
	char     saved_demospeed[32];
	qboolean saved_was_systempath = cls.lastdemowassystempath;
	int      demotype             = cls.demoplayback;
	Q_strncpyz(saved_name,      cls.lastdemoname,    sizeof(saved_name));
	Q_strncpyz(saved_demospeed, cl_demospeed.string, sizeof(saved_demospeed));

	double t_start = Sys_DoubleTime();

	hde_reset();
	is_recording = true;

	{
		vfsfile_t *df = cls.demoinfile;
		VFS_SEEK(df, 0);
		cls.demoinfile = NULL;
		CL_PlayDemoStream(df, cls.lastdemoname, cls.lastdemowassystempath,
		                  demotype, 0, 0);
	}
	Hub_ResetMatchState();

	cls.demoseektime = 1e9f;
	cls.demoseeking  = DEMOSEEK_INTERMISSION;

	int    iters       = 0;
	int    idle_runs   = 0;
	double t_safety    = t_start + 30.0;
	while (cls.demoplayback != DPB_NONE && cls.demoseeking != DEMOSEEK_NOT)
	{
		float prev_demtime = demtime;
		int   processed    = 0;
		while (CL_GetDemoMessage())
		{
			CL_ReadPacket();
			processed++;
			if (cls.demoplayback == DPB_NONE ||
			    cls.demoseeking  == DEMOSEEK_NOT) break;
		}
		iters++;
		if (processed == 0 && demtime == prev_demtime)
		{
			if (++idle_runs > 1024) break;
		}
		else idle_runs = 0;
		if ((iters & 0xff) == 0 && Sys_DoubleTime() > t_safety) break;
	}

	int scan_end_ms = Hub_DemoEvent_TimeMs();
	is_recording    = false;

	reconcile(scan_end_ms);

	if (cls.demoplayback == DPB_NONE)
	{
		CL_PlayDemo(saved_name, saved_was_systempath);
	}
	else
	{
		vfsfile_t *df = cls.demoinfile;
		VFS_SEEK(df, 0);
		cls.demoinfile = NULL;
		CL_PlayDemoStream(df, saved_name, saved_was_systempath,
		                  demotype, 0, 0);
	}
	Hub_ResetMatchState();
	cls.demoseektime = saved_time;
	cls.demoseeking  = DEMOSEEK_TIME;
	// Restore cl_demospeed: the EOF-pause path sets it to 0 when the
	// scan races to the end of the demo.
	Cvar_Set(&cl_demospeed, saved_demospeed);

	Q_strncpyz(last_scanned_demo, saved_name, sizeof(last_scanned_demo));

	double scan_ms = (Sys_DoubleTime() - t_start) * 1000.0;
	Con_Printf("[demo-events] %d events in %.0f ms (raw: %d deaths, %d msgs, %d tooks/%d losses, %d drops/%d bp, %d damages, %d prints)\n",
	           hub_demo_event_count, scan_ms,
	           raw_death_count, raw_death_message_count,
	           raw_took_count, raw_items_loss_count,
	           raw_drop_count, raw_bp_pickup_count, raw_damage_count,
	           raw_print_count);
	return hub_demo_event_count;
}

static void CL_DemoEventsScan_f(void)
{
	Hub_DemoEvent_Scan();
}

void Hub_DemoEvent_Init(void)
{
	Cmd_AddCommandD("demo_events_scan", CL_DemoEventsScan_f,
	                "Fast-parse the current demo to extract per-player events. MVD only.");
}
