// SPDX-License-Identifier: 0BSD

#include "quakedef.h"
#include "cl_hub_demo_events.h"
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
// final chunk arrives (is_more == 0).
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
// Separate cache key for the lightweight stats scan. A full events scan
// also writes here (since it captures stats too); a prior stats-only
// scan only writes here, leaving last_scanned_demo empty so a later
// full scan still runs.
static char     last_scanned_demo_stats[MAX_OSPATH] = "";

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
// are filled by count_span_frags() at end of scan via a post-hoc pass
// over the death events. No per-open-span running counter - the death
// event already carries time_ms + killer_user_id + killer_items, so
// every kill that lands inside a span's [start, end] window with the
// span's weapon bit set in killer_items counts toward that span. This
// avoids the ordering bug where the attacker's span could close (e.g.
// they died moments after firing) before the victim's STAT_HEALTH
// transition fired, losing the attribution.

// Most recently closed span per (slot, item idx). Recorded when
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

// Per-(slot, weapon idx) timestamp after which the STAT_ITEMS gain
// path is allowed to emit a HDE_KIND_PICKUP event again. Set by
// Hub_DemoEvents_OnKtxBackpackPickup so the subsequent dem_stat
// (which gains the same weapon bit) doesn't double-emit as a ground
// pickup. Window covers the typical 1-2 packet latency between the
// stuffcmd and the stat update.
static int suppress_pickup_until_ms[MAX_CLIENTS][HUB_TRACKED_ITEM_COUNT];
#define HUB_PICKUP_SUPPRESS_WINDOW_MS 300

// Most recent attacker per victim, recorded by Hub_DemoEvents_OnDamage and
// consumed by Hub_DemoEvents_OnStatUpdate to attribute the next
// STAT_HEALTH -> 0 transition. -1 = unattributed (no damage seen for this
// victim within the window or attacker dropped).
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

// Drop attribution if the death lags more than this far behind the last
// damage event for the victim. KTX dmgdone fires immediately on damage
// resolution; the STAT_HEALTH transition follows in the same or next
// dem_stats batch (50-100ms typical). 1s is a generous safety margin
// that still rejects stale damage from an earlier round / encounter.
#define HUB_DMG_ATTRIBUTION_WINDOW_MS 1000

// True once demtime has crossed the timeline-scanned countdown, i.e.
// match-time >= 00:00. Replaces the older cl.matchstate gate so that
// spawn-on-item pickups at match-time 0 are captured on maps where a
// player starts on an item (the matchstate transition can lag the
// first STAT_ITEMS frame). hub_demo_countdown_ms == 0 (no observed
// countdown) admits everything from demo start - safe since the
// scan stops at intermission anyway.
static qboolean in_match_time(void)
{
	return (int)floor(demtime * 1000) >= hub_demo_countdown_ms;
}

void Hub_DemoEvents_Reset(void)
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
		has_seen_health[i]   = false;
		last_dmg_attacker[i] = -1;
		last_dmg_time_ms[i]  = 0;
		last_dmg_type[i]     = 0;
		cached_items[i]      = 0;
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
	for (int e = 0; e < HUB_BACKPACK_INDEX_SIZE; e++)
	{
		backpack_by_entnum[e].items           = 0;
		backpack_by_entnum[e].dropper_user_id = 0;
	}
}

static void register_player(int slot);
static void events_push(hub_demo_event_kind_t kind, int player_slot,
                        unsigned int items, const float *origin);

// Frag counts are zeroed here; count_span_frags() fills them after the
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
	sp->rl_kills    = 0;
	sp->lg_kills    = 0;
	sp->rlg_kills   = 0;
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

	int t = (int)floor(demtime * 1000);
	for (int w = 0; w < HUB_TRACKED_ITEM_COUNT; w++)
	{
		unsigned int bit = tracked_item_bits[w];
		if (!(diff & bit)) continue;

		if (new_mask & bit)
		{
			// Gain: open a span if not already open. (A pre-existing
			// open span means we missed a loss - keep the earlier
			// start so the span covers the whole hold.) Weapon
			// pickups also emit a HDE_KIND_PICKUP event so the
			// event log shows "X took RL". Powerups already get
			// pickup events from OnKtxTook, so gate to RL / LG to
			// avoid double-emitting.
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
					events_push(HDE_KIND_PICKUP, slot, bit, NULL);
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
			register_player(slot);
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
// weapon during that window, so we don't also check killer_items against
// the span's bit. RL/LG/RLG breakdown comes from the killer_items
// snapshot the event captured at kill time. Self-frags carry
// killer_user_id == 0 and skip naturally.
static void finalize_spans(void)
{
	int t = (int)floor(demtime * 1000);
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
			qboolean has_rl = (ev->killer_items & IT_ROCKET_LAUNCHER) != 0;
			qboolean has_lg = (ev->killer_items & IT_LIGHTNING)       != 0;
			if      (has_rl && has_lg) sp->rlg_kills++;
			else if (has_rl)           sp->rl_kills++;
			else if (has_lg)           sp->lg_kills++;
		}
	}
}

// Append the player slot's userid + name to hub_demo_players if not yet
// seen, or fill in a previously-seen entry whose name was empty at first
// sight (player joined late, name arrived in a later packet). First
// non-empty name wins - matches the prior in-event "captured at the
// moment of the event" semantic without storing per-event.
static void register_player(int slot)
{
	if (slot < 0 || slot >= MAX_CLIENTS) return;
	int uid = cl.players[slot].userid;
	if (uid <= 0) return;

	int idx = -1;
	for (int i = 0; i < hub_demo_player_count; i++)
	{
		if (hub_demo_players[i].userid == uid)
		{
			idx = i;
			break;
		}
	}
	if (idx < 0)
	{
		if (hub_demo_player_count >= players_capacity)
		{
			int new_cap = players_capacity ? players_capacity * 2 : 32;
			hub_demo_players = BZ_Realloc(hub_demo_players,
			                              sizeof(hub_demo_player_t) * new_cap);
			players_capacity = new_cap;
		}
		idx = hub_demo_player_count++;
		hub_demo_players[idx].userid    = uid;
		hub_demo_players[idx].name[0]   = 0;
		hub_demo_players[idx].team[0]   = 0;
		hub_demo_players[idx].is_active = false;
	}
	if (hub_demo_players[idx].name[0] == 0 && cl.players[slot].name[0])
	{
		Hub_QuakeStringToUnicode(cl.players[slot].name,
		                      hub_demo_players[idx].name,
		                      sizeof(hub_demo_players[idx].name));
	}
}

// Walks cl.players[] at end of scan and resolves each registered userid to
// its current live team string + active flag. Phantom userids (someone
// briefly hit by an attribution event but no longer holding the slot, or
// never on the live roster) get is_active=false so consumers can hide them.
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

qboolean Hub_DemoEvents_IsRecording(void)
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
	ev->time_ms        = (int)floor(demtime * 1000);
	ev->kind           = kind;
	ev->items          = items;
	ev->killer_user_id = 0;
	ev->victim_items   = 0;
	ev->killer_items   = 0;
	ev->frag_type      = 0;
	if (player_slot >= 0 && player_slot < MAX_CLIENTS)
	{
		ev->victim_user_id = cl.players[player_slot].userid;
		register_player(player_slot);

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
			// so post-hoc span attribution (count_span_frags) skips
			// them naturally.
			if (atk >= 0 && atk < MAX_CLIENTS && atk != player_slot &&
			    dt >= 0 && dt <= HUB_DMG_ATTRIBUTION_WINDOW_MS)
			{
				ev->killer_user_id = cl.players[atk].userid;
				ev->killer_items   = cached_items[atk];
				ev->frag_type      = last_dmg_type[player_slot];
				register_player(atk);
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

void Hub_DemoEvents_OnStatUpdate(int slot, unsigned int stat,
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
		if (in_match_time())
			update_item_spans(slot, (unsigned int)old_ivalue,
			                    (unsigned int)new_ivalue);
		cached_items[slot] = (unsigned int)new_ivalue;
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

	if (!in_match_time()) return;

	if (old_ivalue > 0 && new_ivalue <= 0)
		events_push(HDE_KIND_DEATH, slot, 0, NULL);
}

void Hub_DemoEvents_OnKtxTook(int player_slot, const char *model, int skin,
                              const float *origin)
{
	if (!is_recording) return;
	if (!model) return;
	if (player_slot < 0 || player_slot >= MAX_CLIENTS) return;

	if (!in_match_time()) return;

	// Resolve model + skin to the engine's IT_* bit. The same bits appear
	// in STAT_ITEMS, so a consumer can mask `event.items` against IT_QUAD
	// etc. directly without a separate kind enum.
	unsigned int items;
	if (!strcmp(model, "progs/armor.mdl"))
	{
		switch (skin)
		{
		case 2:  items = IT_ARMOR3; break;
		case 1:  items = IT_ARMOR2; break;
		default: items = IT_ARMOR1; break;
		}
	}
	else if (!strcmp(model, "progs/quaddama.mdl")) items = IT_QUAD;
	else if (!strcmp(model, "progs/invulner.mdl")) items = IT_INVULNERABILITY;
	else if (!strcmp(model, "progs/invisibl.mdl")) items = IT_INVISIBILITY;
	else if (!strcmp(model, "maps/b_bh100.bsp"))   items = IT_SUPERHEALTH;
	else
	{
		return; // model not tracked
	}

	events_push(HDE_KIND_PICKUP, player_slot, items, origin);
}

void Hub_DemoEvents_OnKtxDrop(int player_slot, unsigned int items,
                              const float *origin, unsigned int entnum)
{
	if (!is_recording) return;
	if (player_slot < 0 || player_slot >= MAX_CLIENTS) return;
	if (!in_match_time()) return;

	int t = (int)floor(demtime * 1000);

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

	// Split multi-weapon backpacks into one event per tracked bit so
	// consumers can filter on a single IT_* constant. Each emitted bit
	// also patches the most recently closed span for the dropper if
	// one closed within the attribution window - the drop arrives a
	// packet or two after STAT_ITEMS=0 closes the span on death.
	for (int w = 0; w < HUB_TRACKED_ITEM_COUNT; w++)
	{
		unsigned int bit = tracked_item_bits[w];
		if (!(items & bit)) continue;
		events_push(HDE_KIND_WEAPON_DROP, player_slot, bit, origin);

		int span_idx = last_closed_span_index[player_slot][w];
		int dt       = t - last_closed_span_time_ms[player_slot][w];
		if (span_idx >= 0 && span_idx < hub_demo_span_count &&
		    dt >= 0 && dt <= HUB_DROP_PATCH_WINDOW_MS)
		{
			hub_demo_spans[span_idx].was_dropped = true;
		}
		// Clear so a later unrelated drop in the same window can't
		// re-flag the same span.
		last_closed_span_index[player_slot][w] = -1;
	}
}

void Hub_DemoEvents_OnKtxBackpackPickup(int player_slot, unsigned int entnum)
{
	if (!is_recording) return;
	if (player_slot < 0 || player_slot >= MAX_CLIENTS) return;
	if (!in_match_time()) return;
	if (entnum >= HUB_BACKPACK_INDEX_SIZE) return;

	hub_backpack_entry_t entry = backpack_by_entnum[entnum];
	backpack_by_entnum[entnum].items           = 0;
	backpack_by_entnum[entnum].dropper_user_id = 0;
	if (!entry.items) return;

	int t = (int)floor(demtime * 1000);

	// Emit one BACKPACK_PICKUP per tracked RL / LG bit and prime
	// the suppression window so the subsequent STAT_ITEMS gain
	// transition doesn't also fire a HDE_KIND_PICKUP for the same
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

void Hub_DemoEvents_OnDamage(int attacker_slot, int targ_slot,
                             unsigned int dmg_type)
{
	if (!is_recording) return;
	if (targ_slot < 0 || targ_slot >= MAX_CLIENTS) return;
	if (attacker_slot < 0 || attacker_slot >= MAX_CLIENTS) return;

	if (!in_match_time()) return;

	last_dmg_attacker[targ_slot] = attacker_slot;
	last_dmg_time_ms[targ_slot]  = (int)floor(demtime * 1000);
	last_dmg_type[targ_slot]     = dmg_type;
}

void Hub_DemoEvents_OnDemoInfo(int payload_len, unsigned int is_more)
{
	// Outside a scan: just consume the bytes so the parser stays
	// aligned. We don't keep the json across normal playback.
	if (!is_recording || payload_len <= 0)
	{
		if (payload_len > 0) MSG_ReadSkip(payload_len);
		return;
	}

	// First chunk: stamp the start time so we can report grab duration
	// when the final chunk arrives.
	if (ktxstats_buf_len == 0)
		ktxstats_t_start = Sys_DoubleTime();

	// Grow the accumulator by powers of two (+1 for the eventual null
	// terminator) and append the next chunk.
	int needed = ktxstats_buf_len + payload_len + 1;
	if (needed > ktxstats_buf_cap)
	{
		int new_cap = ktxstats_buf_cap ? ktxstats_buf_cap : 4096;
		while (new_cap < needed) new_cap *= 2;
		ktxstats_buf     = BZ_Realloc(ktxstats_buf, new_cap);
		ktxstats_buf_cap = new_cap;
	}
	MSG_ReadData(ktxstats_buf + ktxstats_buf_len, payload_len);
	ktxstats_buf_len += payload_len;

	// Final chunk: publish. Subsequent scans Reset() the buffer first,
	// so we don't need to clear ktxstats_buf_len here.
	if (!is_more)
	{
		ktxstats_buf[ktxstats_buf_len] = 0;
		if (hub_ktxstats_json) Z_Free(hub_ktxstats_json);
		hub_ktxstats_json = Z_Malloc(ktxstats_buf_len + 1);
		memcpy(hub_ktxstats_json, ktxstats_buf, ktxstats_buf_len + 1);
		double grab_ms = (Sys_DoubleTime() - ktxstats_t_start) * 1000.0;
		Con_Printf("[demo-events] ktxstats: %d bytes in %.1f ms\n",
		           ktxstats_buf_len, grab_ms);
		ktxstats_buf_len = 0;
	}
}

// Rewind the demo, fast-forward to the end with the recording flag set,
// then fast-forward back to the user's prior demtime with the flag
// cleared. Returns event count, or -1 if the demo isn't scannable.
// Idempotent for the same demo file path.
int Hub_DemoEvents_Scan(void)
{
	if (!cls.demoplayback)
	{
		Con_Printf("not playing a demo\n");
		return -1;
	}
	if (cls.demoplayback != DPB_MVD)
	{
		Con_Printf("demo_events_scan currently supports MVD only\n");
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

	Hub_DemoEvents_Reset();
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

	// Pump CL_GetDemoMessage until seek completes (svc_intermission seen
	// or EOF). CL_GetDemoMessage may return 0 during early prespawn while
	// CL_RequestNextDownload progresses asset loading - those calls are
	// productive even though they return 0, so don't break on zero alone.
	// Track no-progress idle iterations to bail safely.
	int    iters     = 0;
	int    idle_runs = 0;
	double t_safety  = t_start + 30.0;
	while (cls.demoplayback != DPB_NONE && cls.demoseeking != DEMOSEEK_NOT)
	{
		float prev_demtime = demtime;
		int   processed    = 0;
		while (CL_GetDemoMessage())
		{
			CL_ReadPacket();
			processed++;
			if (cls.demoplayback == DPB_NONE || cls.demoseeking == DEMOSEEK_NOT)
				break;
		}
		iters++;
		if (processed == 0 && demtime == prev_demtime)
		{
			if (++idle_runs > 1024)
			{
				Con_Printf("[demo-events] no progress, stopping\n");
				break;
			}
		}
		else
		{
			idle_runs = 0;
		}
		if ((iters & 0xff) == 0 && Sys_DoubleTime() > t_safety)
		{
			Con_Printf("[demo-events] safety timeout\n");
			break;
		}
	}

	is_recording = false;
	float scanned_demtime = demtime;

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

	Q_strncpyz(last_scanned_demo,       saved_name, sizeof(last_scanned_demo));
	Q_strncpyz(last_scanned_demo_stats, saved_name, sizeof(last_scanned_demo_stats));

	double scan_ms = (Sys_DoubleTime() - t_start) * 1000.0;
	Con_Printf("[demo-events] %d events in %.0f ms (scanned %.1fs, restoring to %.1fs)\n",
	           hub_demo_event_count, scan_ms, scanned_demtime, saved_time);
	return hub_demo_event_count;
}

// Standalone stats scanner. Walks the demo file directly, skipping the
// body of every non-hidden frame with VFS_SEEK and only parsing
// mvdhidden_demoinfo blocks within hidden-message frames. Early-exits
// the moment the final ktxstats chunk lands, so demos that emit stats
// near the end still pay the seek cost but demos that emit them
// mid-match return almost immediately.
//
// Frame layout (MVD, post-header):
//   1 byte  msec delta
//   1 byte  cmd (low 3 bits = dem_*)
//   if dem_multiple: 4 bytes  to-mask  (0 = hidden message)
//   for dem_read/single/stats/all/multiple: 4 bytes  body length
//   N bytes body
//   (dem_cmd / dem_set are fixed-size and never hidden.)
//
// Hidden body layout (CLEZ_ParseHiddenDemoMessage):
//   4 bytes  size (-1 sentinel for "end of hidden block")
//   2 bytes  cmd UInt16
//   `size` bytes  payload (for 0x0003 demoinfo: 2 bytes is_more + chunk)
int Hub_DemoStats_Scan(void)
{
	if (!cls.demoplayback)                              return -1;
	if (cls.demoplayback != DPB_MVD)                    return -1;
	if (!*cls.lastdemoname)                             return -1;
	if (!cls.demoinfile)                                return -1;
	if (cls.demoinfile->seekstyle == SS_UNSEEKABLE)     return -1;

	// Either cache hits cover stats - a prior full scan already
	// captured ktxstats; a prior stats-only scan is the obvious case.
	if (last_scanned_demo[0]
	    && !strcmp(last_scanned_demo, cls.lastdemoname))
		return 0;
	if (last_scanned_demo_stats[0]
	    && !strcmp(last_scanned_demo_stats, cls.lastdemoname))
		return 0;

	double     t_start    = Sys_DoubleTime();
	vfsfile_t *f          = cls.demoinfile;
	qofs_t     saved_pos  = VFS_TELL(f);
	int        body_cap   = 64 * 1024;
	unsigned char *body   = Z_Malloc(body_cap);
	qboolean   done       = false;

	VFS_SEEK(f, 0);

	// Clear any prior ktxstats from playback so a freshly-loaded demo
	// without stats reports correctly (NULL hub_ktxstats_json).
	if (hub_ktxstats_json) { Z_Free(hub_ktxstats_json); hub_ktxstats_json = NULL; }
	ktxstats_buf_len = 0;

	while (!done)
	{
		unsigned char hdr[2];
		if (VFS_READ(f, hdr, 2) != 2) break;
		unsigned char cmd = hdr[1];

		int      body_len  = 0;
		qboolean is_hidden = false;

		switch (cmd & 7)
		{
		case dem_multiple:
		{
			int seqmask, len;
			if (VFS_READ(f, &seqmask, 4) != 4) { done = true; break; }
			if (VFS_READ(f, &len, 4)     != 4) { done = true; break; }
			body_len  = LittleLong(len);
			is_hidden = (LittleLong(seqmask) == 0);
			break;
		}
		case dem_read:
		case dem_single:
		case dem_stats:
		case dem_all:
		{
			int len;
			if (VFS_READ(f, &len, 4) != 4) { done = true; break; }
			body_len = LittleLong(len);
			break;
		}
		case dem_set:
			if (VFS_SEEK(f, VFS_TELL(f) + 8) < 0) done = true;
			continue;
		case dem_cmd:
			// MVDs don't normally contain dem_cmd records; defend
			// against a malformed/non-standard demo by skipping the
			// fixed-size body (q1usercmd_t + 3 angles).
			if (VFS_SEEK(f, VFS_TELL(f) + (int)sizeof(q1usercmd_t) + 12) < 0)
				done = true;
			continue;
		default:
			done = true;
			break;
		}
		if (done) break;

		if (body_len < 0 || body_len > 4 * 1024 * 1024) break;

		if (!is_hidden)
		{
			if (VFS_SEEK(f, VFS_TELL(f) + body_len) < 0) break;
			continue;
		}

		if (body_len > body_cap)
		{
			while (body_cap < body_len) body_cap *= 2;
			body = BZ_Realloc(body, body_cap);
		}
		if (VFS_READ(f, body, body_len) != body_len) break;

		// Walk the hidden-message stream inside the body looking for
		// mvdhidden_demoinfo (cmd 0x0003). Other hidden cmds (dmgdone
		// etc.) are ignored entirely on this fast path.
		int pos = 0;
		while (pos + 6 <= body_len)
		{
			int size; memcpy(&size, body + pos, 4);
			size = LittleLong(size);
			pos += 4;
			if (size == -1) break;  // end-of-hidden-block sentinel
			if (size < 0 || pos + 2 > body_len) { done = true; break; }
			unsigned short cmd_id;
			memcpy(&cmd_id, body + pos, 2);
			cmd_id = LittleShort(cmd_id);
			pos += 2;
			if (pos + size > body_len) { done = true; break; }

			if (cmd_id == 0x0003 /* mvdhidden_demoinfo */ && size >= 2)
			{
				unsigned short is_more;
				memcpy(&is_more, body + pos, 2);
				is_more = LittleShort(is_more);
				int payload_len = size - 2;
				if (payload_len > 0)
				{
					if (ktxstats_buf_len == 0)
						ktxstats_t_start = Sys_DoubleTime();
					int needed = ktxstats_buf_len + payload_len + 1;
					if (needed > ktxstats_buf_cap)
					{
						int new_cap = ktxstats_buf_cap ? ktxstats_buf_cap : 4096;
						while (new_cap < needed) new_cap *= 2;
						ktxstats_buf     = BZ_Realloc(ktxstats_buf, new_cap);
						ktxstats_buf_cap = new_cap;
					}
					memcpy(ktxstats_buf + ktxstats_buf_len,
					       body + pos + 2, payload_len);
					ktxstats_buf_len += payload_len;

					if (!is_more)
					{
						ktxstats_buf[ktxstats_buf_len] = 0;
						if (hub_ktxstats_json) Z_Free(hub_ktxstats_json);
						hub_ktxstats_json = Z_Malloc(ktxstats_buf_len + 1);
						memcpy(hub_ktxstats_json, ktxstats_buf,
						       ktxstats_buf_len + 1);
						double grab_ms =
						    (Sys_DoubleTime() - ktxstats_t_start) * 1000.0;
						Con_Printf("[demo-stats] ktxstats: %d bytes in %.1f ms\n",
						           ktxstats_buf_len, grab_ms);
						ktxstats_buf_len = 0;
						done = true;
						break;
					}
				}
			}
			pos += size;
		}
	}

	VFS_SEEK(f, saved_pos);
	Z_Free(body);

	Q_strncpyz(last_scanned_demo_stats, cls.lastdemoname,
	           sizeof(last_scanned_demo_stats));

	double scan_ms = (Sys_DoubleTime() - t_start) * 1000.0;
	Con_Printf("[demo-stats] scan in %.0f ms (ktxstats: %s)\n",
	           scan_ms, hub_ktxstats_json ? "found" : "not found");
	return 0;
}

static void CL_DemoEventsScan_f(void)
{
	Hub_DemoEvents_Scan();
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
		const char *kname = (ev->kind == HDE_KIND_DEATH) ? "death" : "pickup";
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
		for (int j = 0; j < hub_demo_player_count; j++)
		{
			if (hub_demo_players[j].userid == ev->victim_user_id)
			{
				pname = hub_demo_players[j].name;
				break;
			}
		}
		Con_Printf("  %6d ms  %-7s%s  userid=%-4d player=%-16s pos=%.0f %.0f %.0f\n",
		           ev->time_ms, kname, iname, ev->victim_user_id, pname,
		           ev->origin[0], ev->origin[1], ev->origin[2]);
	}
}

void Hub_DemoEvents_Init(void)
{
	Cmd_AddCommandD("demo_events_scan", CL_DemoEventsScan_f,
	                "Fast-parse the current demo from start to end to extract per-player events (currently STAT_HEALTH-based deaths in MVD demos). Restores playback position when done.");
	Cmd_AddCommandD("demo_events_dump", CL_DemoEventsDump_f,
	                "Print the first 20 events from the most recent demo_events_scan.");
}
