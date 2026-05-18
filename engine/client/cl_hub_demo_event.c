// SPDX-License-Identifier: 0BSD

#include "quakedef.h"
#include "cl_hub_demo_event.h"
#include "cl_hub_demo_event_internal.h"
#include "cl_hub_demo_timeline.h"
#include "cl_hub.h"
#include "cl_hub_participants.h"

extern float demtime;
extern void  Hub_ResetMatchState(void);
void         CL_PlayDemoStream(vfsfile_t *file, char *filename,
                               qboolean issyspath, int demotype,
                               float bufferdelay, unsigned int eztv_ext);
void         CL_PlayDemo(char *demoname, qboolean usesystempath);
qboolean     CL_GetDemoMessage(void);
void         CL_ReadPacket(void);

hub_demo_event_t  *hub_demo_events       = NULL;
int                hub_demo_event_count  = 0;
hub_demo_player_t *hub_demo_players      = NULL;
int                hub_demo_player_count = 0;
hub_demo_span_t   *hub_demo_spans        = NULL;
int                hub_demo_span_count   = 0;
char              *hub_ktxstats_json     = NULL;

// Growable byte accumulator for the ktxstats JSON. The wire format
// chunks the payload across one or more mvdhidden_demoinfo messages
// (is_more = nonzero on every chunk except the last). We append into
// ktxstats_buf and only publish it to hub_ktxstats_json when the
// final chunk arrives (is_more == 0). Lives here (not in mvd_event.c)
// because Hub_DemoEvent_Reset clears it and the standalone MVD stats
// scanner uses the same accumulator helpers.
static char  *ktxstats_buf      = NULL;
static int    ktxstats_buf_len  = 0;
static int    ktxstats_buf_cap  = 0;
static double ktxstats_t_start  = 0; // Sys_DoubleTime when first chunk
                                      // landed in the accumulator;
                                      // diffed against completion for
                                      // a debug print of grab time.

static int      events_capacity      = 0;
static int      players_capacity     = 0;
static int      spans_capacity       = 0;
static qboolean is_recording         = false;
static qboolean has_seen_health[MAX_CLIENTS];
static char     last_scanned_demo[MAX_OSPATH] = "";

// Tracked STAT_ITEMS bits we emit hold-spans for. Mixes weapons (RL/LG)
// and powerups (quad/pent/ring); the span struct itself is generic so
// the only thing that distinguishes them on the wire is the items bit.
// Parallel arrays indexed in lockstep with tracked_item_bits[].
#define HUB_TRACKED_ITEM_COUNT 5
static const unsigned int tracked_item_bits[HUB_TRACKED_ITEM_COUNT] = {
	IT_ROCKET_LAUNCHER,
	IT_LIGHTNING,
	IT_QUAD,
	IT_INVULNERABILITY,
	IT_INVISIBILITY,
};
static int open_span_start_ms[MAX_CLIENTS][HUB_TRACKED_ITEM_COUNT];

// Frag counts (total + RL/LG/RLG breakdown) live on hub_demo_span_t and
// are filled by finalize_spans() at end of scan via a post-hoc pass
// over the death events. No per-open-span running counter - the death
// event already carries time_ms + killer_user_id + killer_items, so
// every kill that lands inside a span's [start, end] window with the
// span's weapon bit set in killer_items counts toward that span. This
// avoids the ordering bug where the attacker's span could close (e.g.
// they died moments after firing) before the victim's STAT_HEALTH
// transition fired, losing the attribution.

// Most recently closed span per (slot, item index). Recorded when
// update_item_spans pushes a closure so that a //ktx drop arriving
// shortly after can patch was_dropped on the matching weapon span.
// -1 = no span has closed for this slot+item since the last patch
// (or scan start). Cleared after a successful patch so a second drop
// in the same window can't double-flag. Powerup entries are populated
// but never patched (no //ktx drop emits powerup bits).
static int last_closed_span_index[MAX_CLIENTS][HUB_TRACKED_ITEM_COUNT];
static int last_closed_span_time_ms[MAX_CLIENTS][HUB_TRACKED_ITEM_COUNT];

// Drop must arrive within this much time after the span close to be
// considered the matching drop. //ktx drop fires one packet after the
// STAT_ITEMS=0 dem_stat that closed the span, ~50-100ms typical.
#define HUB_DROP_PATCH_WINDOW_MS 1000

// Maps backpack entity numbers to the contents captured at //ktx drop
// time (items bitmask + dropper userid), so the matching //ktx bp
// (pickup) message can recover both which weapons the backpack
// carried and who dropped it. Server entnums for short-lived
// backpacks stay in the low thousands; 2048 covers a comfortable
// margin for any reasonable match. Out-of-range entnums fall through
// to "unknown backpack" (no event emitted).
#define HUB_BACKPACK_INDEX_SIZE 2048
typedef struct {
	unsigned int items;
	int          dropper_user_id;
} hub_backpack_entry_t;
static hub_backpack_entry_t backpack_by_entnum[HUB_BACKPACK_INDEX_SIZE];

// Per-(slot, weapon index) timestamp after which the STAT_ITEMS gain
// path is allowed to emit a HDE_KIND_ITEM_PICKUP event again. Set by
// Hub_DemoEvent_OnKtxBackpackPickup so the subsequent dem_stat
// (which gains the same weapon bit) doesn't double-emit as a ground
// pickup. Window covers the typical 1-2 packet latency between the
// stuffcmd and the stat update.
static int suppress_pickup_until_ms[MAX_CLIENTS][HUB_TRACKED_ITEM_COUNT];
#define HUB_PICKUP_SUPPRESS_WINDOW_MS 300

// Most recent attacker per victim, recorded by Hub_MvdEvent_OnDamage and
// consumed by events_push to attribute the next STAT_HEALTH -> 0
// transition. -1 = unattributed (no damage seen for this victim within
// the window or attacker dropped).
static int          last_dmg_attacker[MAX_CLIENTS];
static int          last_dmg_time_ms[MAX_CLIENTS];
static unsigned int last_dmg_type[MAX_CLIENTS]; // mvdhidden_dmgdone
                                                 // typeandflags (splash
                                                 // bit stripped), copied
                                                 // into emitted death
                                                 // event's frag_type.

// Latest STAT_ITEMS per player, mirrored from the OnStatUpdate hook so
// death events can record what the victim and fragger were holding at
// the moment of the kill (weapons, powerups, armor type). Updated on
// every STAT_ITEMS write the demo emits.
static unsigned int cached_items[MAX_CLIENTS];

// Latest STAT_ARMOR per player. A positive delta with no IT_ARMOR* bit
// transition this frame is a same-type armor re-pickup (e.g. RA on top
// of RA after taking damage) - the only signal available since the
// armor bit is unchanged. Updated on every STAT_ARMOR write.
static int cached_armor[MAX_CLIENTS];

// Drop attribution if the death lags more than this far behind the last
// damage event for the victim. KTX dmgdone fires immediately on damage
// resolution; the STAT_HEALTH transition follows in the same or next
// dem_stats batch (50-100ms typical). 1s is a generous safety margin
// that still rejects stale damage from an earlier round / encounter.
#define HUB_DMG_ATTRIBUTION_WINDOW_MS 1000

// Most recent fragstats-derived FRAG emit per slot, separately for the
// kill side (slot is killer) and death side (slot is victim). Consulted
// by cl_hub_dem_event.c via Hub_DemoEventInternal_IsFragSuppressed so
// the svc_updatefrags delta hook doesn't double-emit a coarser frag
// event for the same kill fragstats already covered. svc_print arrives
// before svc_updatefrags in the normal packet order so this works as a
// short look-back gate. 0 = never emitted (start-of-scan sentinel; the
// scan begins at demtime 0 so a stale 0 can't match a real demtime).
#define HUB_FRAG_SUPPRESS_WINDOW_MS 1000
static int fragstats_kill_emit_ms[MAX_CLIENTS];
static int fragstats_death_emit_ms[MAX_CLIENTS];

// Per-slot index of the most recent fragstats-emitted FRAG event that
// touched this slot (as killer or victim). Lets the STAT_HEALTH death
// hook locate the fragstats event for a given victim slot in O(1) and
// promote it in place to DEATH (preserving fragstats' killer/weapon
// attribution, adding origin + items from the death moment) instead of
// emitting a duplicate. -1 = no recent fragstats event for that slot.
static int fragstats_last_event_index[MAX_CLIENTS];

// Pending one-sided fragstats event awaiting completion by the next
// svc_updatefrags delta on a teammate. Set by Hub_DemoEvent_OnFragStatsKill
// when the obit-text matched a one-component pattern (e.g.
// X_TEAMKILLS_UNKNOWN / X_TEAMKILLED_UNKNOWN) so only one side is known.
// Consumed by Hub_DemoEventInternal_MergePendingFragEvent which patches
// the missing user-id in place rather than emitting a separate frag-delta
// event. pending_event_index = -1 means "nothing pending".
static int pending_event_index  = -1;
static int pending_known_slot = -1;
static int pending_known_role = 0;  // 1 = killer known (missing victim);
                                     // 0 = victim known (missing killer)
static int pending_time_ms    = 0;

int Hub_DemoEvent_TimeMs(void)
{
	// NQ demos put absolute server/level time on the wire (svc_time)
	// rather than the demo-relative msec deltas MVD uses, so demtime
	// can be anywhere from a few seconds to thousands of seconds at
	// the demo's first frame. Subtract the timeline-scanned start
	// offset to get demo-relative ms. 0 for MVD/QWD.
	return (int)floor(demtime * 1000) - hub_demo_start_offset_ms;
}

// True once demtime has crossed the timeline-scanned countdown, i.e.
// match-time >= 00:00. Replaces the older cl.matchstate gate so that
// spawn-on-item pickups at match-time 0 are captured on maps where a
// player starts on an item (the matchstate transition can lag the
// first STAT_ITEMS frame). hub_demo_countdown_ms == 0 (no observed
// countdown) admits everything from demo start - safe since the
// scan stops at intermission anyway.
qboolean Hub_DemoEvent_InMatchTime(void)
{
	return Hub_DemoEvent_TimeMs() >= hub_demo_countdown_ms;
}

static void Hub_DemoEvent_Reset(void)
{
	hub_demo_event_count  = 0;
	hub_demo_player_count = 0;
	hub_demo_span_count   = 0;
	if (hub_ktxstats_json)
	{
		Z_Free(hub_ktxstats_json);
		hub_ktxstats_json = NULL;
	}
	ktxstats_buf_len = 0;
	for (int i = 0; i < MAX_CLIENTS; i++)
	{
		has_seen_health[i]         = false;
		last_dmg_attacker[i]       = -1;
		last_dmg_time_ms[i]        = 0;
		last_dmg_type[i]           = 0;
		cached_items[i]            = 0;
		cached_armor[i]            = 0;
		fragstats_kill_emit_ms[i]    = 0;
		fragstats_death_emit_ms[i]   = 0;
		fragstats_last_event_index[i]  = -1;
		// Clear the entnum-keyed backpack cache and the per-slot
		// suppression window the next gain transition checks.
		for (int w = 0; w < HUB_TRACKED_ITEM_COUNT; w++)
		{
			open_span_start_ms[i][w]         = -1;
			last_closed_span_index[i][w]     = -1;
			last_closed_span_time_ms[i][w]   = 0;
			suppress_pickup_until_ms[i][w]   = 0;
		}
	}
	pending_event_index  = -1;
	pending_known_slot = -1;
	pending_known_role = 0;
	pending_time_ms    = 0;
	for (int e = 0; e < HUB_BACKPACK_INDEX_SIZE; e++)
	{
		backpack_by_entnum[e].items           = 0;
		backpack_by_entnum[e].dropper_user_id = 0;
	}
}

static void events_push(hub_demo_event_kind_t kind, int player_slot,
                        unsigned int items, const float *origin);

// Frag counts are zeroed here; finalize_spans() fills them after the
// scan loop by walking the death events array.
static void spans_push(int user_id, unsigned int weapon_bit,
                       int start_ms, int end_ms)
{
	if (hub_demo_span_count >= spans_capacity)
	{
		int new_cap = spans_capacity ? spans_capacity * 2 : 128;
		hub_demo_spans = BZ_Realloc(hub_demo_spans,
		                            sizeof(hub_demo_span_t) * new_cap);
		spans_capacity = new_cap;
	}
	hub_demo_span_t *sp = &hub_demo_spans[hub_demo_span_count++];
	sp->start_ms    = start_ms;
	sp->end_ms      = end_ms;
	sp->user_id     = user_id;
	sp->items       = weapon_bit;
	sp->was_dropped = false;
	sp->frag_count  = 0;
}

// Diff old/new STAT_ITEMS for the tracked weapon bits and open/close
// spans accordingly. Multi-bit transitions (backpack pickup, death)
// split into one span per weapon. Spans for unknown userids (slot has
// no userid yet) are dropped at open-time.
static void update_item_spans(int slot, unsigned int old_mask,
                                unsigned int new_mask)
{
	unsigned int tracked_mask = 0;
	for (int w = 0; w < HUB_TRACKED_ITEM_COUNT; w++)
		tracked_mask |= tracked_item_bits[w];

	unsigned int diff = (old_mask ^ new_mask) & tracked_mask;
	if (!diff) return;

	int t = Hub_DemoEvent_TimeMs();
	for (int w = 0; w < HUB_TRACKED_ITEM_COUNT; w++)
	{
		unsigned int bit = tracked_item_bits[w];
		if (!(diff & bit)) continue;

		if (new_mask & bit)
		{
			// Gain: open a span if not already open. (A pre-existing
			// open span means we missed a loss - keep the earlier
			// start so the span covers the whole hold.) Weapon
			// pickups also emit a HDE_KIND_ITEM_PICKUP event so the
			// event log shows "X took RL". Powerup pickups
			// (quad/pent/ring) emit here too; the server only sets
			// these bits on a fresh grant so the 0->1 transition is
			// the full signal across all formats.
			if (open_span_start_ms[slot][w] < 0)
			{
				open_span_start_ms[slot][w]  = t;
				// Skip the ground-pickup emit when the matching
				// backpack-pickup hook just fired - otherwise the
				// event log would show both "took RL" and "took
				// RL from pack" for the same player frame.
				if ((bit == IT_ROCKET_LAUNCHER ||
				     bit == IT_LIGHTNING) &&
				    t > suppress_pickup_until_ms[slot][w])
					events_push(HDE_KIND_ITEM_PICKUP, slot, bit, NULL);

				// Powerup pickups (quad/pent/ring): the server only
				// grants these when the player doesn't already have
				// the bit set, so the 0->1 transition is the complete
				// signal across all formats. Same-powerup re-pickup
				// while still active isn't possible (server blocks).
				if (bit == IT_QUAD ||
				    bit == IT_INVULNERABILITY ||
				    bit == IT_INVISIBILITY)
					events_push(HDE_KIND_ITEM_PICKUP, slot, bit, NULL);
			}
		}
		else
		{
			// Loss: close span. -1 = no open span (e.g. transition
			// observed before the slot ever had the bit during scan).
			int start = open_span_start_ms[slot][w];
			open_span_start_ms[slot][w] = -1;
			if (start < 0) continue;
			int uid = cl.players[slot].userid;
			if (uid <= 0) continue;
			spans_push(uid, bit, start, t);
			Hub_DemoEvent_RegisterPlayer(slot);
			// Remember this span so a //ktx drop arriving in the next
			// few packets can patch was_dropped on it.
			last_closed_span_index[slot][w]   = hub_demo_span_count - 1;
			last_closed_span_time_ms[slot][w] = t;
		}
	}
}

// Close any still-open weapon spans at end-of-scan demtime. Called
// after the pump loop completes so the final scanned_demtime is stable.
// Two passes: close any spans still open at end of scan, then walk the
// death events array once and tally frags into every span whose
// [start_ms, end_ms] window contains the event AND whose user_id matches
// the killer. The span existing IS the proof that the player held the
// item during that window. Self-frags carry killer_user_id == 0 and
// skip naturally.
static void finalize_spans(void)
{
	int t = Hub_DemoEvent_TimeMs();
	for (int slot = 0; slot < MAX_CLIENTS; slot++)
	{
		int uid = cl.players[slot].userid;
		for (int w = 0; w < HUB_TRACKED_ITEM_COUNT; w++)
		{
			int start = open_span_start_ms[slot][w];
			if (start < 0) continue;
			open_span_start_ms[slot][w] = -1;
			if (uid <= 0) continue;
			spans_push(uid, tracked_item_bits[w], start, t);
		}
	}

	for (int i = 0; i < hub_demo_span_count; i++)
	{
		hub_demo_span_t *sp = &hub_demo_spans[i];
		for (int j = 0; j < hub_demo_event_count; j++)
		{
			hub_demo_event_t *ev = &hub_demo_events[j];
			if (ev->kind != HDE_KIND_DEATH)        continue;
			if (ev->killer_user_id != sp->user_id) continue;
			if (ev->time_ms < sp->start_ms)        continue;
			if (ev->time_ms > sp->end_ms)          continue;
			sp->frag_count++;
		}
	}
}

// Append the player slot's userid + name to hub_demo_players if not yet
// seen, or fill in a previously-seen entry whose name was empty at first
// sight (player joined late, name arrived in a later packet). First
// non-empty name wins - matches the prior in-event "captured at the
// moment of the event" semantic without storing per-event.
void Hub_DemoEvent_RegisterPlayer(int slot)
{
	if (slot < 0 || slot >= MAX_CLIENTS) return;
	int uid = cl.players[slot].userid;
	if (uid <= 0) return;

	int index = -1;
	for (int i = 0; i < hub_demo_player_count; i++)
	{
		if (hub_demo_players[i].userid == uid)
		{
			index = i;
			break;
		}
	}
	if (index < 0)
	{
		if (hub_demo_player_count >= players_capacity)
		{
			int new_cap = players_capacity ? players_capacity * 2 : 32;
			hub_demo_players = BZ_Realloc(hub_demo_players,
			                              sizeof(hub_demo_player_t) * new_cap);
			players_capacity = new_cap;
		}
		index = hub_demo_player_count++;
		hub_demo_players[index].userid    = uid;
		hub_demo_players[index].name[0]   = 0;
		hub_demo_players[index].team[0]   = 0;
		hub_demo_players[index].is_active = false;
	}
	if (hub_demo_players[index].name[0] == 0 && cl.players[slot].name[0])
	{
		Hub_QuakeStringToUnicode(cl.players[slot].name,
		                      hub_demo_players[index].name,
		                      sizeof(hub_demo_players[index].name));
	}
}

// Walks cl.players[] at end of scan and resolves each registered userid to
// its current live team string + active flag. Phantom userids (someone
// briefly hit by an attribution event but no longer holding the slot, or
// never on the live roster) get is_active=false so consumers can hide them.
// Also registers any active player still in cl.players who hasn't yet been
// added to the roster - covers cases like NQ POV players whose name didn't
// happen to match any obit print (single-word names that prefix nothing,
// or kills emitted before fragstats matched a pattern). The roster should
// reflect "who was in the match" regardless of whether the event log
// references them.
static void finalize_players(void)
{
	for (int i = 0; i < hub_demo_player_count; i++)
	{
		hub_demo_players[i].team[0]   = 0;
		hub_demo_players[i].is_active = false;
	}
	for (int slot = 0; slot < MAX_CLIENTS; slot++)
	{
		int uid = cl.players[slot].userid;
		if (uid <= 0) continue;
		if (cl.players[slot].spectator) continue;
		if (!cl.players[slot].name[0]) continue;

		// Idempotent - adds the slot only if its userid isn't
		// already in hub_demo_players.
		Hub_DemoEvent_RegisterPlayer(slot);

		for (int i = 0; i < hub_demo_player_count; i++)
		{
			if (hub_demo_players[i].userid != uid) continue;
			Hub_QuakeStringToUnicode(cl.players[slot].team,
			                      hub_demo_players[i].team,
			                      sizeof(hub_demo_players[i].team));
			hub_demo_players[i].is_active = true;
			break;
		}
	}
}

qboolean Hub_DemoEvent_IsRecording(void)
{
	return is_recording;
}

// origin: caller-supplied event position (e.g. item baseline for pickups,
// or NULL to use the player's current playerstate origin for deaths).
// items: engine IT_* bit for pickups (0 for non-pickup events).
static void events_push(hub_demo_event_kind_t kind, int player_slot,
                        unsigned int items, const float *origin)
{
	if (hub_demo_event_count >= events_capacity)
	{
		int new_cap = events_capacity ? events_capacity * 2 : 256;
		hub_demo_events = BZ_Realloc(hub_demo_events,
		                             sizeof(hub_demo_event_t) * new_cap);
		events_capacity = new_cap;
	}
	hub_demo_event_t *ev = &hub_demo_events[hub_demo_event_count++];
	ev->time_ms        = Hub_DemoEvent_TimeMs();
	ev->kind           = kind;
	ev->items          = items;
	ev->killer_user_id = 0;
	ev->victim_items   = 0;
	ev->killer_items   = 0;
	ev->frag_type      = 0;
	if (player_slot >= 0 && player_slot < MAX_CLIENTS)
	{
		ev->victim_user_id = cl.players[player_slot].userid;
		Hub_DemoEvent_RegisterPlayer(player_slot);

		// Death attribution: consume the most recent damage record for
		// this victim if it's still within the window. Cleared after
		// consumption so a second death without a fresh dmgdone (rare:
		// double-kill via lava etc.) doesn't reuse stale attribution.
		if (kind == HDE_KIND_DEATH)
		{
			ev->victim_items = cached_items[player_slot];
			int atk = last_dmg_attacker[player_slot];
			int dt  = ev->time_ms - last_dmg_time_ms[player_slot];
			// Self-frags (atk == player_slot) leave killer_user_id at 0
			// so post-hoc span attribution skips them naturally.
			if (atk >= 0 && atk < MAX_CLIENTS && atk != player_slot &&
			    dt >= 0 && dt <= HUB_DMG_ATTRIBUTION_WINDOW_MS)
			{
				ev->killer_user_id = cl.players[atk].userid;
				ev->killer_items   = cached_items[atk];
				ev->frag_type      = last_dmg_type[player_slot];
				Hub_DemoEvent_RegisterPlayer(atk);
			}
			last_dmg_attacker[player_slot] = -1;
		}
	}
	else
	{
		ev->victim_user_id = 0;
	}
	if (origin)
	{
		ev->origin[0] = origin[0];
		ev->origin[1] = origin[1];
		ev->origin[2] = origin[2];
	}
	else if (player_slot >= 0 && player_slot < MAX_CLIENTS)
	{
		// Most recently received origin for this slot. Filled by
		// svc_playerinfo in the same packet as the stat update (or the
		// immediately prior packet) - within ~50ms of the event.
		float *src = cl.inframes[cl.parsecount & UPDATE_MASK]
		                .playerstate[player_slot].origin;
		ev->origin[0] = src[0];
		ev->origin[1] = src[1];
		ev->origin[2] = src[2];
	}
	else
	{
		ev->origin[0] = ev->origin[1] = ev->origin[2] = 0;
	}
}

void Hub_DemoEvent_OnStatUpdate(int slot, unsigned int stat,
                                int old_ivalue, int new_ivalue)
{
	if (!is_recording) return;
	if (slot < 0 || slot >= MAX_CLIENTS) return;

	// Cache STAT_ITEMS for both players involved in a frag. Cache is
	// kept even outside the match (warmup picks-ups still update the
	// bitmask) so the first real death after warmup reports an accurate
	// items state.
	if (stat == STAT_ITEMS)
	{
		// Skip span tracking outside the match. KTX warmup hands players
		// the full arsenal, so an ungated first STAT_ITEMS write would
		// open RL/LG spans at t=0 for everyone; the subsequent respawn
		// at match start (axe+SG only) would then close them with the
		// wrong start time. cached_items still updates unconditionally
		// so death attribution has a fresh bitmask for the first kill.
		if (Hub_DemoEvent_InMatchTime())
		{
			update_item_spans(slot, (unsigned int)old_ivalue,
			                    (unsigned int)new_ivalue);

			// Armor type-change / first pickup: 0->1 transition on
			// any IT_ARMOR* bit. Same-type re-pickup (the bit was
			// already set) is handled via STAT_ARMOR positive delta
			// further down.
			unsigned int gained = ((unsigned int)new_ivalue) &
			                      ~((unsigned int)old_ivalue);
			if (gained & IT_ARMOR1)
				events_push(HDE_KIND_ITEM_PICKUP, slot, IT_ARMOR1, NULL);
			if (gained & IT_ARMOR2)
				events_push(HDE_KIND_ITEM_PICKUP, slot, IT_ARMOR2, NULL);
			if (gained & IT_ARMOR3)
				events_push(HDE_KIND_ITEM_PICKUP, slot, IT_ARMOR3, NULL);

			// Mega health pickup: IT_SUPERHEALTH 0->1 transition.
			// Server only sets the bit on a fresh pickup (it stays
			// set during the rotten timer and clears when HP ticks
			// back below 100), so the bit transition is the full
			// signal for the initial pickup. MH re-pickup while the
			// rotten timer is still running is detected via
			// STAT_HEALTH below.
			if (gained & IT_SUPERHEALTH)
				events_push(HDE_KIND_ITEM_PICKUP, slot, IT_SUPERHEALTH, NULL);
		}
		cached_items[slot] = (unsigned int)new_ivalue;
		return;
	}

	if (stat == STAT_ARMOR)
	{
		// Same-type armor re-pickup detection. Armor never recovers
		// without a pickup (no regen in QW), so any positive delta is
		// a touch. The IT_ARMOR* bit transition path above already
		// fires when the armor *type* changes (or it's the player's
		// first armor since spawn), so here we only emit when the
		// currently-held armor type's bit is still set and the new
		// value stays within that tier's cap - the bit-transition
		// path will have handled type changes (which push the value
		// above the prior tier's cap).
		int delta = new_ivalue - cached_armor[slot];
		cached_armor[slot] = new_ivalue;
		if (delta <= 0)                       return;
		if (!Hub_DemoEvent_InMatchTime())     return;
		unsigned int items = cached_items[slot];
		unsigned int bit;
		int          cap;
		if      (items & IT_ARMOR3) { bit = IT_ARMOR3; cap = 200; }
		else if (items & IT_ARMOR2) { bit = IT_ARMOR2; cap = 150; }
		else if (items & IT_ARMOR1) { bit = IT_ARMOR1; cap = 100; }
		else                                  return; // type-change handled by bit-transition path
		if (new_ivalue > cap)                 return; // upgrade, bit-transition path will emit
		events_push(HDE_KIND_ITEM_PICKUP, slot, bit, NULL);
		return;
	}

	if (stat != STAT_HEALTH) return;

	// First health value seen for this slot is just the initial spawn
	// snapshot, not a death even if it happens to be 0.
	if (!has_seen_health[slot])
	{
		has_seen_health[slot] = true;
		return;
	}

	if (!Hub_DemoEvent_InMatchTime()) return;

	if (old_ivalue > 0 && new_ivalue <= 0)
	{
		// If fragstats already emitted a DEATH event for this victim
		// (svc_print obit fires before svc_updatestat STAT_HEALTH=0
		// in the typical packet order), enrich it in place with the
		// origin + items the STAT_HEALTH transition gives us, and
		// optionally refine killer info from MVD damage attribution.
		// Avoids two events for the same kill. Falls through to a
		// fresh emit when fragstats hadn't matched.
		if (Hub_DemoEventInternal_IsFragSuppressed(slot, false))
		{
			int event_index = fragstats_last_event_index[slot];
			if (event_index >= 0 && event_index < hub_demo_event_count)
			{
				hub_demo_event_t *ev = &hub_demo_events[event_index];
				ev->victim_items = cached_items[slot];
				float *src = cl.inframes[cl.parsecount & UPDATE_MASK]
				                .playerstate[slot].origin;
				ev->origin[0] = src[0];
				ev->origin[1] = src[1];
				ev->origin[2] = src[2];
				// If MVD damage attribution is available, use it to
				// refine killer info: the fragstats event already
				// has killer/victim from the obit, but
				// mvdhidden_dmgdone carries killer_items and a more
				// specific frag_type / dtype. NQ has no dmgdone so
				// this branch silently no-ops there.
				int atk = last_dmg_attacker[slot];
				int dt  = Hub_DemoEvent_TimeMs() - last_dmg_time_ms[slot];
				if (atk >= 0 && atk < MAX_CLIENTS && atk != slot &&
				    dt >= 0 && dt <= HUB_DMG_ATTRIBUTION_WINDOW_MS)
				{
					ev->killer_user_id = cl.players[atk].userid;
					ev->killer_items   = cached_items[atk];
					ev->frag_type      = last_dmg_type[slot];
					last_dmg_attacker[slot] = -1;
				}
				fragstats_last_event_index[slot] = -1;
				goto health_done;
			}
		}
		events_push(HDE_KIND_DEATH, slot, 0, NULL);
	}
health_done:

	// Mega health re-pickup: IT_SUPERHEALTH already set (a prior MH's
	// rotten timer is still running) and STAT_HEALTH jumps upward
	// past 100. HP can only exceed 100 via MH - small medkits cap at
	// 100 - so a positive delta ending above 100 with the bit still
	// set means another MH was taken at a separate spawn before the
	// first one wore off. Initial pickup (bit 0->1) is handled in the
	// STAT_ITEMS path above. STAT_HEALTH arrives before STAT_ITEMS in
	// the per-frame broadcast order (lower stat index), so cached
	// IT_SUPERHEALTH here reflects the state *before* this frame's
	// STAT_ITEMS update; for the initial pickup it's still 0 and we
	// correctly skip.
	if ((cached_items[slot] & IT_SUPERHEALTH) &&
	    new_ivalue > old_ivalue && new_ivalue > 100)
		events_push(HDE_KIND_ITEM_PICKUP, slot, IT_SUPERHEALTH, NULL);
}

void Hub_DemoEvent_OnKtxDrop(int player_slot, unsigned int items,
                             const float *origin, unsigned int entnum)
{
	if (!is_recording) return;
	if (player_slot < 0 || player_slot >= MAX_CLIENTS) return;
	if (!Hub_DemoEvent_InMatchTime()) return;

	int t = Hub_DemoEvent_TimeMs();

	// Index the contents by backpack entnum so a later //ktx bp can
	// emit per-weapon BACKPACK_PICKUP events even though that wire
	// message only carries the entnum. Store dropper userid too so
	// the pickup event can identify whose backpack was taken.
	if (entnum < HUB_BACKPACK_INDEX_SIZE)
	{
		backpack_by_entnum[entnum].items = items;
		backpack_by_entnum[entnum].dropper_user_id =
		    cl.players[player_slot].userid;
	}

	// No event emit - "the dropper had this weapon at death" is already
	// implicit in the matching DEATH event's victim_items, and
	// BACKPACK_PICKUP carries the dropper attribution when the loot is
	// picked up. Use the //ktx drop signal purely as a side-effect to
	// (a) flag the weapon-hold span as ending in a death-drop and
	// (b) populate the entnum index for the eventual BACKPACK_PICKUP.
	for (int w = 0; w < HUB_TRACKED_ITEM_COUNT; w++)
	{
		unsigned int bit = tracked_item_bits[w];
		if (!(items & bit)) continue;

		int span_index = last_closed_span_index[player_slot][w];
		int dt       = t - last_closed_span_time_ms[player_slot][w];
		if (span_index >= 0 && span_index < hub_demo_span_count &&
		    dt >= 0 && dt <= HUB_DROP_PATCH_WINDOW_MS)
		{
			hub_demo_spans[span_index].was_dropped = true;
		}
		// Clear so a later unrelated drop in the same window can't
		// re-flag the same span.
		last_closed_span_index[player_slot][w] = -1;
	}
}

void Hub_DemoEvent_OnKtxBackpackPickup(int player_slot, unsigned int entnum)
{
	if (!is_recording) return;
	if (player_slot < 0 || player_slot >= MAX_CLIENTS) return;
	if (!Hub_DemoEvent_InMatchTime()) return;
	if (entnum >= HUB_BACKPACK_INDEX_SIZE) return;

	hub_backpack_entry_t entry = backpack_by_entnum[entnum];
	backpack_by_entnum[entnum].items           = 0;
	backpack_by_entnum[entnum].dropper_user_id = 0;
	if (!entry.items) return;

	int t = Hub_DemoEvent_TimeMs();

	// Emit one BACKPACK_PICKUP per tracked RL / LG bit and prime
	// the suppression window so the subsequent STAT_ITEMS gain
	// transition doesn't also fire a HDE_KIND_ITEM_PICKUP for the same
	// weapon. Origin is taken from the player's playerstate at
	// emit time (NULL = use playerstate.origin). Dropper userid
	// is reused for killer_user_id on the event so consumers can
	// render "X took Y's RL-pack".
	for (int w = 0; w < HUB_TRACKED_ITEM_COUNT; w++)
	{
		unsigned int bit = tracked_item_bits[w];
		if (!(entry.items & bit)) continue;
		if (bit != IT_ROCKET_LAUNCHER && bit != IT_LIGHTNING) continue;
		events_push(HDE_KIND_BACKPACK_PICKUP, player_slot, bit, NULL);
		hub_demo_events[hub_demo_event_count - 1].killer_user_id =
		    entry.dropper_user_id;
		suppress_pickup_until_ms[player_slot][w] =
		    t + HUB_PICKUP_SUPPRESS_WINDOW_MS;
	}
}

// ---- Internal API (cl_hub_demo_event_internal.h) ------------------------

void Hub_DemoEventInternal_StashDamage(int attacker_slot, int targ_slot,
                                       unsigned int dmg_type)
{
	if (!is_recording) return;
	if (targ_slot < 0 || targ_slot >= MAX_CLIENTS) return;
	if (attacker_slot < 0 || attacker_slot >= MAX_CLIENTS) return;
	if (!Hub_DemoEvent_InMatchTime()) return;

	last_dmg_attacker[targ_slot] = attacker_slot;
	last_dmg_time_ms[targ_slot]  = Hub_DemoEvent_TimeMs();
	last_dmg_type[targ_slot]     = dmg_type;
}

void Hub_DemoEventInternal_ResetKtxStatsBuf(void)
{
	if (hub_ktxstats_json) { Z_Free(hub_ktxstats_json); hub_ktxstats_json = NULL; }
	ktxstats_buf_len = 0;
}

void Hub_DemoEventInternal_AppendKtxStats(const void *bytes, int len,
                                          unsigned int is_more,
                                          const char *log_tag)
{
	if (len <= 0)
	{
		if (!is_more) ktxstats_buf_len = 0;
		return;
	}

	// First chunk: stamp the start time so we can report grab duration
	// when the final chunk arrives.
	if (ktxstats_buf_len == 0)
		ktxstats_t_start = Sys_DoubleTime();

	// Grow the accumulator by powers of two (+1 for the eventual null
	// terminator) and append the next chunk.
	int needed = ktxstats_buf_len + len + 1;
	if (needed > ktxstats_buf_cap)
	{
		int new_cap = ktxstats_buf_cap ? ktxstats_buf_cap : 4096;
		while (new_cap < needed) new_cap *= 2;
		ktxstats_buf     = BZ_Realloc(ktxstats_buf, new_cap);
		ktxstats_buf_cap = new_cap;
	}
	memcpy(ktxstats_buf + ktxstats_buf_len, bytes, len);
	ktxstats_buf_len += len;

	// Final chunk: publish. Subsequent scans reset the buffer first,
	// so we don't need to clear ktxstats_buf_len here.
	if (!is_more)
	{
		ktxstats_buf[ktxstats_buf_len] = 0;
		if (hub_ktxstats_json) Z_Free(hub_ktxstats_json);
		hub_ktxstats_json = Z_Malloc(ktxstats_buf_len + 1);
		memcpy(hub_ktxstats_json, ktxstats_buf, ktxstats_buf_len + 1);
		double grab_ms = (Sys_DoubleTime() - ktxstats_t_start) * 1000.0;
		Con_Printf("[%s] ktxstats: %d bytes in %.1f ms\n",
		           log_tag, ktxstats_buf_len, grab_ms);
		ktxstats_buf_len = 0;
	}
}

void Hub_DemoEvent_OnFragStatsFlag(int player_slot, hub_demo_event_kind_t kind)
{
	if (!is_recording) return;
	if (!Hub_DemoEvent_InMatchTime()) return;
	if (player_slot < 0 || player_slot >= MAX_CLIENTS) return;
	if (kind != HDE_KIND_FLAG_TOUCH &&
	    kind != HDE_KIND_FLAG_CAPTURE &&
	    kind != HDE_KIND_FLAG_DROP)
		return;
	if (cl.players[player_slot].userid <= 0) return;

	// events_push picks origin from playerstate when called with NULL,
	// which is exactly the actor's position at the print moment - the
	// flag's location for grabs / drops, the capture point for caps.
	events_push(kind, player_slot, 0, NULL);
}

void Hub_DemoEvent_OnFragStatsRune(int player_slot, unsigned int rune_bit)
{
	if (!is_recording) return;
	if (!Hub_DemoEvent_InMatchTime()) return;
	if (player_slot < 0 || player_slot >= MAX_CLIENTS) return;
	if (cl.players[player_slot].userid <= 0) return;
	if (!rune_bit) return;

	events_push(HDE_KIND_ITEM_PICKUP, player_slot, rune_bit, NULL);
}

qboolean Hub_DemoEventInternal_MergePendingFragEvent(int slot, int delta)
{
	if (pending_event_index < 0) return false;
	if (pending_event_index >= hub_demo_event_count)
	{
		pending_event_index = -1;
		return false;
	}
	if (Hub_DemoEvent_TimeMs() - pending_time_ms > HUB_FRAG_SUPPRESS_WINDOW_MS)
	{
		pending_event_index = -1;
		return false;
	}
	if (slot < 0 || slot >= MAX_CLIENTS) return false;
	if (pending_known_slot < 0 || pending_known_slot >= MAX_CLIENTS) return false;
	if (slot == pending_known_slot) return false;

	// NQ team identity = pants color. Same-team check.
	if (cl.players[slot].rbottomcolor != cl.players[pending_known_slot].rbottomcolor)
		return false;

	int new_uid = cl.players[slot].userid;
	if (new_uid <= 0) return false;

	hub_demo_event_t *ev = &hub_demo_events[pending_event_index];
	if (pending_known_role == 1 && delta < 0)
	{
		// Killer known, missing victim. Negative delta on a teammate
		// is the player who lost a frag from being teamkilled.
		ev->victim_user_id = new_uid;
		Hub_DemoEvent_RegisterPlayer(slot);
		pending_event_index = -1;
		return true;
	}
	if (pending_known_role == 0 && delta > 0)
	{
		// Victim known, missing killer. Positive delta on a teammate
		// is the player who scored from the teamkill.
		ev->killer_user_id = new_uid;
		Hub_DemoEvent_RegisterPlayer(slot);
		pending_event_index = -1;
		return true;
	}
	return false;
}

qboolean Hub_DemoEventInternal_IsFragSuppressed(int slot, qboolean as_killer)
{
	if (slot < 0 || slot >= MAX_CLIENTS) return false;
	int t       = Hub_DemoEvent_TimeMs();
	int stamped = as_killer ? fragstats_kill_emit_ms[slot]
	                        : fragstats_death_emit_ms[slot];
	if (stamped <= 0) return false;
	return (t - stamped) <= HUB_FRAG_SUPPRESS_WINDOW_MS;
}

void Hub_DemoEvent_OnFragStatsKill(int killer_slot, int victim_slot, int wid)
{
	if (!is_recording) return;
	if (!Hub_DemoEvent_InMatchTime()) return;

	int killer_uid = -1;
	int victim_uid = -1;
	if (killer_slot >= 0 && killer_slot < MAX_CLIENTS)
	{
		killer_uid = cl.players[killer_slot].userid;
		Hub_DemoEvent_RegisterPlayer(killer_slot);
	}
	if (victim_slot >= 0 && victim_slot < MAX_CLIENTS)
	{
		victim_uid = cl.players[victim_slot].userid;
		Hub_DemoEvent_RegisterPlayer(victim_slot);
	}
	if (killer_uid <= 0) killer_uid = -1;
	if (victim_uid <= 0) victim_uid = -1;
	if (killer_uid == -1 && victim_uid == -1) return;

	// Bidirectional dedup. The svc_print obit and svc_updatefrags can
	// arrive in either order within a packet (id1's PlayerDeath sets
	// .frags before bprint, so svc_updatefrags often fires first for
	// world-damage deaths; KTX is the other way around). If a recent
	// DEATH event for this victim or this killer+missing-victim is
	// already in the array, merge the fragstats info into it instead
	// of emitting a duplicate.
	int t_now = Hub_DemoEvent_TimeMs();
	for (int i = hub_demo_event_count - 1; i >= 0; i--)
	{
		hub_demo_event_t *ev = &hub_demo_events[i];
		if (t_now - ev->time_ms > HUB_FRAG_SUPPRESS_WINDOW_MS) break;
		if (ev->kind != HDE_KIND_DEATH) continue;

		// Same-victim match (most common: fragstats follows a
		// frag-delta-emitted suicide / partial death for this player).
		// OR killer-side match where the existing event has no victim
		// yet (frag-delta positive-delta partial).
		qboolean same_victim =
		    (victim_uid > 0 && ev->victim_user_id == victim_uid);
		qboolean killer_partial =
		    (killer_uid > 0 && ev->killer_user_id == killer_uid &&
		     ev->victim_user_id == -1);
		if (!same_victim && !killer_partial) continue;

		// Patch in place. fragstats info wins for any slot where we
		// have a real userid (killer / victim / weapon).
		if (killer_uid > 0) ev->killer_user_id = killer_uid;
		if (victim_uid > 0) ev->victim_user_id = victim_uid;
		if (wid > 0)        ev->frag_type      = (unsigned int)wid;
		// Record this index so the STAT_HEALTH death hook can still
		// enrich origin + items via the existing fragstats_last_event_index
		// path.
		if (killer_slot >= 0 && killer_slot < MAX_CLIENTS)
			fragstats_last_event_index[killer_slot] = i;
		if (victim_slot >= 0 && victim_slot < MAX_CLIENTS)
			fragstats_last_event_index[victim_slot] = i;
		goto stamped_suppression;
	}

	Hub_DemoEventInternal_PushFragEvent(killer_uid, victim_uid);

	// Stash the weapon id on the just-pushed event so consumers can
	// resolve it via fragstats.weapontotals[wid].
	if (hub_demo_event_count > 0)
		hub_demo_events[hub_demo_event_count - 1].frag_type =
		    (unsigned int)wid;

	// Record the new event's index against both slots so the later
	// STAT_HEALTH=0 transition for the victim (and any frag-delta on
	// the killer) can patch it in place instead of pushing a duplicate.
	// Without this, multi-POV MVDs - where every player's STAT_HEALTH
	// is observed, not just the recording client's - double-emit every
	// frag whose obit text arrives before the STAT_HEALTH update.
	if (hub_demo_event_count > 0)
	{
		int new_index = hub_demo_event_count - 1;
		if (killer_slot >= 0 && killer_slot < MAX_CLIENTS)
			fragstats_last_event_index[killer_slot] = new_index;
		if (victim_slot >= 0 && victim_slot < MAX_CLIENTS)
			fragstats_last_event_index[victim_slot] = new_index;
	}

	// Mark the event as pending if one side is missing. The next
	// matching svc_updatefrags delta on a teammate of the known side
	// (handled in Hub_DemoEventInternal_MergePendingFragEvent) will
	// fill in the missing user-id in place. Covers obit text like
	// "X gets a frag for the other team" (killer-only) or "X was
	// telefragged by his teammate" (victim-only).
	qboolean is_partial    = (killer_uid <= 0) || (victim_uid <= 0);
	qboolean has_known_slot = (killer_slot >= 0) || (victim_slot >= 0);
	if (is_partial && has_known_slot && hub_demo_event_count > 0)
	{
		pending_event_index  = hub_demo_event_count - 1;
		pending_known_slot = (killer_uid > 0) ? killer_slot : victim_slot;
		pending_known_role = (killer_uid > 0) ? 1 : 0;
		pending_time_ms    = Hub_DemoEvent_TimeMs();
	}
	else
	{
		// Both sides resolved; no further merging needed.
		pending_event_index = -1;
	}

stamped_suppression:
	// Prime suppression windows so an imminent svc_updatefrags delta
	// on the same slot doesn't emit a duplicate event. Stamp BOTH
	// directions for each known slot - some mods (e.g. CRMod) decrement
	// the teamkiller's frags as a penalty, so a killer can have a
	// negative delta we still want suppressed; conversely a victim
	// could in principle have a positive delta. Fragstats already
	// represents the kill so any frag-delta on the same slot within
	// the window is a duplicate by definition.
	{
		int t = Hub_DemoEvent_TimeMs();
		int stamp = t > 0 ? t : 1;
		if (killer_slot >= 0 && killer_slot < MAX_CLIENTS)
		{
			fragstats_kill_emit_ms[killer_slot]  = stamp;
			fragstats_death_emit_ms[killer_slot] = stamp;
		}
		if (victim_slot >= 0 && victim_slot < MAX_CLIENTS)
		{
			fragstats_kill_emit_ms[victim_slot]  = stamp;
			fragstats_death_emit_ms[victim_slot] = stamp;
		}
	}
}

void Hub_DemoEventInternal_PushFragEvent(int killer_uid, int victim_uid)
{
	if (!is_recording) return;
	if (!Hub_DemoEvent_InMatchTime()) return;

	if (hub_demo_event_count >= events_capacity)
	{
		int new_cap = events_capacity ? events_capacity * 2 : 256;
		hub_demo_events = BZ_Realloc(hub_demo_events,
		                             sizeof(hub_demo_event_t) * new_cap);
		events_capacity = new_cap;
	}
	hub_demo_event_t *ev = &hub_demo_events[hub_demo_event_count++];
	ev->time_ms        = Hub_DemoEvent_TimeMs();
	ev->kind           = HDE_KIND_DEATH;
	ev->victim_user_id = victim_uid;
	ev->killer_user_id = killer_uid;
	ev->items          = 0;
	ev->victim_items   = 0;
	ev->killer_items   = 0;
	ev->frag_type      = 0;
	ev->origin[0] = ev->origin[1] = ev->origin[2] = 0;

	// Resolve origin from the playerstate of whichever side is known
	// (prefer victim - "where the death happened"). QW broadcasts
	// svc_playerinfo for every visible player each frame, so even in a
	// single-POV demo non-POV slots have a recent origin here.
	int origin_uid = (victim_uid > 0) ? victim_uid : killer_uid;
	if (origin_uid > 0)
	{
		for (int s = 0; s < MAX_CLIENTS; s++)
		{
			if (cl.players[s].userid != origin_uid) continue;
			float *src = cl.inframes[cl.parsecount & UPDATE_MASK]
			                .playerstate[s].origin;
			ev->origin[0] = src[0];
			ev->origin[1] = src[1];
			ev->origin[2] = src[2];
			break;
		}
	}
}

// ---- Scan dispatcher ----------------------------------------------------

// Rewind the demo, fast-forward to the end with the recording flag set,
// then fast-forward back to the user's prior demtime with the flag
// cleared. Returns event count, or -1 if the demo isn't scannable.
// Idempotent for the same demo file path. Accepts MVD (full coverage)
// and NQ (.dem - fragstats + frag-delta events); QWD not yet wired.
int Hub_DemoEvent_Scan(void)
{
	if (!cls.demoplayback)
	{
		Con_Printf("not playing a demo\n");
		return -1;
	}
	if (cls.demoplayback != DPB_MVD && cls.demoplayback != DPB_NETQUAKE)
	{
		Con_Printf("demo_events_scan supports MVD and NQ (.dem) only\n");
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
		Con_Printf("[demo-events] %d events (cached, demo already scanned)\n",
		           hub_demo_event_count);
		return hub_demo_event_count;
	}

	float    saved_time           = demtime > 0 ? demtime : 0;
	char     saved_name[MAX_OSPATH];
	qboolean saved_was_systempath = cls.lastdemowassystempath;
	int      demotype             = cls.demoplayback;
	Q_strncpyz(saved_name, cls.lastdemoname, sizeof(saved_name));

	double t_start = Sys_DoubleTime();

	Hub_DemoEvent_Reset();
	is_recording = true;

	{
		vfsfile_t *df = cls.demoinfile;
		VFS_SEEK(df, 0);
		cls.demoinfile = NULL;
		CL_PlayDemoStream(df, cls.lastdemoname, cls.lastdemowassystempath,
		                  demotype, 0, 0);
	}
	Hub_ResetMatchState();

	// MVD has a DEMOSEEK_INTERMISSION fast-warp path in CL_GetDemoMessage
	// that yields packets freely until svc_intermission. NQ doesn't:
	// its CL_GetDemoMessage branch (cl_demo.c:640+) only fast-warps
	// under DEMOSEEK_TIME. Use that mode with a target past the
	// timeline-known last svc_time so the scan terminates cleanly when
	// cl.gametime crosses it - no manual demtime warping or past-total
	// safety net needed (those produced runaway demtime when the
	// engine kept reading past EOF).
	if (demotype == DPB_NETQUAKE && hub_demo_total_ms > 0)
	{
		// Target slightly BEFORE the demo's last svc_time so the
		// transition fires on the final real packet. The engine
		// checks `cl.gametime > demoseektime` (strict >), so
		// landing exactly on the last value misses; landing past
		// it hits EOF first (closing the file) and breaks the
		// restore path for URL-backed demos.
		cls.demoseektime =
		    (hub_demo_start_offset_ms + hub_demo_total_ms - 1000) / 1000.0f;
		cls.demoseeking  = DEMOSEEK_TIME;
	}
	else
	{
		cls.demoseektime = 1e9f;
		cls.demoseeking  = DEMOSEEK_INTERMISSION;
	}

	// Pump CL_GetDemoMessage until seek completes (svc_intermission seen
	// or EOF). CL_GetDemoMessage may return 0 during early prespawn while
	// CL_RequestNextDownload progresses asset loading - those calls are
	// productive even though they return 0, so don't break on zero alone.
	// Track no-progress idle iterations to bail safely.
	int         iters     = 0;
	int         idle_runs = 0;
	int         packets   = 0;
	double      t_safety  = t_start + 30.0;
	const char *exit_reason = "?";
	while (cls.demoplayback != DPB_NONE && cls.demoseeking != DEMOSEEK_NOT)
	{
		float prev_demtime = demtime;
		int   processed    = 0;
		while (CL_GetDemoMessage())
		{
			CL_ReadPacket();
			// NQ DEMOSEEK_TIME reads packets freely without
			// advancing demtime (no CL_ProgressDemoTime in the
			// fast-parse path). Mirror demtime to cl.gametime
			// after each packet so events emitted from svc_print
			// / svc_updatefrags handlers between packets get
			// stamped with the right relative time, and
			// Hub_DemoEvent_InMatchTime() correctly gates them
			// against countdown_ms. Safe with DEMOSEEK_TIME:
			// cl.gametime stops advancing once the demo runs
			// out of svc_time, and the seek target triggers
			// DEMOSEEK_NOT before that.
			if (cls.demoplayback == DPB_NETQUAKE)
				demtime = cl.gametime;
			processed++;
			packets++;
			if (cls.demoplayback == DPB_NONE || cls.demoseeking == DEMOSEEK_NOT)
				break;
		}
		iters++;
		if (processed == 0 && demtime == prev_demtime)
		{
			if (++idle_runs > 1024)
			{
				exit_reason = "no-progress";
				break;
			}
		}
		else
		{
			idle_runs = 0;
		}
		if ((iters & 0xff) == 0 && Sys_DoubleTime() > t_safety)
		{
			exit_reason = "safety-timeout";
			break;
		}
	}
	if (!strcmp(exit_reason, "?"))
	{
		if      (cls.demoplayback == DPB_NONE)        exit_reason = "playback-stopped";
		else if (cls.demoseeking  == DEMOSEEK_NOT)    exit_reason = "seek-target-reached";
	}

	is_recording = false;
	float scanned_demtime = demtime;
	Con_DPrintf("[demo-events] scan loop exit: reason=%s iters=%d packets=%d demtime=%.2f idle_runs=%d\n",
	            exit_reason, iters, packets, demtime, idle_runs);

	finalize_spans();
	finalize_players();

	if (cls.demoplayback == DPB_NONE)
	{
		// EOF closed the demo; re-open from disk.
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

	Q_strncpyz(last_scanned_demo, saved_name, sizeof(last_scanned_demo));

	double scan_ms = (Sys_DoubleTime() - t_start) * 1000.0;
	Con_Printf("[demo-events] %d events in %.0f ms (scanned %.1fs, restoring to %.1fs)\n",
	           hub_demo_event_count, scan_ms, scanned_demtime, saved_time);
	return hub_demo_event_count;
}

static void CL_DemoEventsScan_f(void)
{
	Hub_DemoEvent_Scan();
}

// demo_events_dump: temporary debug aid - prints up to 20 events.
static void CL_DemoEventsDump_f(void)
{
	int n    = hub_demo_event_count;
	int show = n < 20 ? n : 20;

	Con_Printf("[demo-events] %d total, showing first %d:\n", n, show);
	for (int i = 0; i < show; i++)
	{
		hub_demo_event_t *ev = &hub_demo_events[i];
		const char *kname;
		switch (ev->kind)
		{
		case HDE_KIND_DEATH:           kname = "death";  break;
		case HDE_KIND_ITEM_PICKUP:          kname = "pickup"; break;
		case HDE_KIND_BACKPACK_PICKUP: kname = "bp";     break;
		case HDE_KIND_FLAG_TOUCH:      kname = "flag+";  break;
		case HDE_KIND_FLAG_CAPTURE:    kname = "flagc";  break;
		case HDE_KIND_FLAG_DROP:       kname = "flag-";  break;
		default:                       kname = "?";      break;
		}
		const char *iname = "";
		switch (ev->items)
		{
		case IT_ARMOR1:          iname = " ga";   break;
		case IT_ARMOR2:          iname = " ya";   break;
		case IT_ARMOR3:          iname = " ra";   break;
		case IT_QUAD:            iname = " quad"; break;
		case IT_INVULNERABILITY: iname = " pent"; break;
		case IT_INVISIBILITY:    iname = " ring"; break;
		default:                 iname = "";      break;
		}
		const char *pname = "?";
		// Pick whichever side isn't -1 for the row's display name.
		// DEATH events from NQ positive-delta-only kills have
		// victim_user_id == -1 but a known killer.
		int show_uid = ev->victim_user_id;
		if (show_uid < 0)
			show_uid = ev->killer_user_id;
		for (int j = 0; j < hub_demo_player_count; j++)
		{
			if (hub_demo_players[j].userid == show_uid)
			{
				pname = hub_demo_players[j].name;
				break;
			}
		}
		Con_Printf("  %6d ms  %-7s%s  killer=%-4d victim=%-4d player=%-16s pos=%.0f %.0f %.0f\n",
		           ev->time_ms, kname, iname, ev->killer_user_id,
		           ev->victim_user_id, pname,
		           ev->origin[0], ev->origin[1], ev->origin[2]);
	}
}

void Hub_DemoEvent_Init(void)
{
	Cmd_AddCommandD("demo_events_scan", CL_DemoEventsScan_f,
	                "Fast-parse the current demo from start to end to extract per-player events (deaths, pickups, weapon drops, frag deltas). MVD demos yield full coverage; NQ (.dem) demos yield frag events only. Restores playback position when done.");
	Cmd_AddCommandD("demo_events_dump", CL_DemoEventsDump_f,
	                "Print the first 20 events from the most recent demo_events_scan.");
}
