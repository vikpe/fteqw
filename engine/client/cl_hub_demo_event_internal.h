// SPDX-License-Identifier: 0BSD
//
// Internal API exposed by cl_hub_demo_event.c to its sibling format-
// specific files (cl_hub_mvd_event.c, cl_hub_dem_event.c). Do not
// include from anywhere else - cl_hub_demo_event.h is the public
// surface for engine call sites.

#ifndef CL_HUB_DEMO_EVENT_INTERNAL_H
#define CL_HUB_DEMO_EVENT_INTERNAL_H

#ifdef __cplusplus
extern "C" {
#endif

// Record last-attacker per victim for the next STAT_HEALTH -> 0
// transition to consume. Both slots are 0-based; out-of-range and
// not-recording are filtered here so callers can stay thin. dmg_type
// is the mvdhidden_dmgdone typeandflags field with the splash bit
// already stripped.
void Hub_DemoEventInternal_StashDamage(int attacker_slot, int targ_slot,
                                       unsigned int dmg_type);

// Append `len` bytes from `bytes` to the in-progress ktxstats buffer.
// On the final chunk (is_more == 0), publishes the accumulated buffer
// to hub_ktxstats_json (Z_Malloc'd copy) and prints a one-line
// completion notice tagged with `log_tag` (e.g. "demo-events",
// "demo-stats"). Callers from the playback path use this directly;
// the standalone file scanner does too. On the first chunk (buffer
// empty) the start time is captured for the completion-time print.
void Hub_DemoEventInternal_AppendKtxStats(const void *bytes, int len,
                                          unsigned int is_more,
                                          const char *log_tag);

// Reset the ktxstats accumulator length (so a fresh scan doesn't see
// leftover bytes) and free hub_ktxstats_json if set. Called from
// Hub_MvdEvent_StatsScan before its file walk so the standalone scan
// reports correctly on a demo that has no stats.
void Hub_DemoEventInternal_ResetKtxStatsBuf(void);

// Returns true if Hub_DemoEvent_OnFragStatsKill recently fired for
// `slot` in the matching role (kill-side / death-side), within the
// suppression window. Consumed by cl_hub_dem_event.c so a
// svc_updatefrags delta doesn't double-emit a frag event when
// fragstats already caught the kill via svc_print parsing.
qboolean Hub_DemoEventInternal_IsFragSuppressed(int slot, qboolean as_killer);

// If a recent fragstats hook emitted a partial frag event (one of
// killer/victim is -1 because the obit text didn't carry both sides -
// e.g. "X gets a frag for the other team" carries only the killer, "X
// was telefragged by his teammate" carries only the victim), try to
// fill in the missing side from this svc_updatefrags delta. Returns
// true on merge (caller should skip emitting a duplicate frag event),
// false otherwise. NQ-only: only the dem_event frag-delta path calls
// this, and the same-team check keys on the player's palette
// bottom-color (the NQ team identity).
qboolean Hub_DemoEventInternal_MergePendingFragEvent(int slot, int delta);

// Emit one HDE_KIND_DEATH event with the given known userid on the
// scoring or losing side and -1 on the unknown side. Called from
// cl_hub_dem_event.c. No-op when not recording or outside match time.
// killer_uid > 0 + victim_uid == -1: positive frag delta (NQ, scorer
//   known but victim not knowable from the delta alone).
// killer_uid == victim_uid > 0: self-kill (suicide / world damage in
//   id1 NQ, where only the dying player's frag count decrements).
void Hub_DemoEventInternal_PushFragEvent(int killer_uid, int victim_uid);

#ifdef __cplusplus
}
#endif

#endif
