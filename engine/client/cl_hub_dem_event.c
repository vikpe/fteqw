// SPDX-License-Identifier: 0BSD

#include "quakedef.h"
#include "cl_hub_demo_event.h"
#include "cl_hub_demo_event_internal.h"
#include "cl_hub_dem_event.h"

void Hub_DemEvent_OnFragUpdate(int slot, int old_frags, int new_frags)
{
	if (!Hub_DemoEvent_IsRecording()) return;
	if (slot < 0 || slot >= MAX_CLIENTS) return;
	if (!Hub_DemoEvent_InMatchTime()) return;

	int delta = new_frags - old_frags;
	if (delta == 0) return;

	// Ignore the initial spawn snapshot (frags=0 -> first real value).
	// svc_updatefrags fires once per join with the current scoreboard
	// state; treating that as a frag would attribute phantom kills at
	// match start to anyone who joined with a non-zero count from the
	// previous map.
	if (old_frags == 0 && new_frags > 0 && Hub_DemoEvent_TimeMs() <= 0)
		return;

	// Spectator sentinel values (-99 / -999) aren't real frag deltas;
	// they're the spec-on/off signal. CLNQ_CheckPlayerIsSpectator
	// reads the same values upstream.
	if (new_frags == -99 || new_frags == -999) return;
	if (old_frags == -99 || old_frags == -999) return;

	Hub_DemoEvent_RegisterPlayer(slot);

	int uid = cl.players[slot].userid;
	if (uid <= 0) return;

	// Merge into a pending one-sided fragstats event if this delta
	// corresponds to the missing teammate side (e.g. obit text
	// "X gets a frag for the other team" carried only the killer;
	// the teamkilled player's frag-- arrives here as the victim).
	// On merge: the pending event's victim_user_id (or killer_user_id)
	// is patched in place and no new frag event is emitted.
	if (Hub_DemoEventInternal_MergePendingFragEvent(slot, delta)) return;

	if (delta > 0)
	{
		// Scorer known, victim unknown (NQ has no per-frag attribution
		// stream). Skip when fragstats already emitted a rich
		// killer+victim+weapon event for this slot from svc_print
		// parsing - the obituary text arrives just before the frag
		// count update, so the suppression window catches the dupe.
		if (Hub_DemoEventInternal_IsFragSuppressed(slot, true)) return;
		for (int i = 0; i < delta; i++)
			Hub_DemoEventInternal_PushFragEvent(uid, -1);
	}
	else
	{
		// Negative frag delta. In id1 NQ frag scoring, only the player
		// themselves can lose a frag (rocket-to-self, fall, lava,
		// drown, kill command). Treating the delta as a suicide
		// (killer == victim == self) covers self-frag variants we
		// don't have an obit pattern for - the alternative would be
		// emitting killer=-1 and rendering "? fragged X" for what is
		// always a self-kill on this protocol. Fragstats hits that
		// matched a specific suicide pattern (e.g. "becomes bored
		// with life") already fired their own event and the
		// suppression check above skips this path.
		if (Hub_DemoEventInternal_IsFragSuppressed(slot, false)) return;
		int loss = -delta;
		for (int i = 0; i < loss; i++)
			Hub_DemoEventInternal_PushFragEvent(uid, uid);
	}
}
