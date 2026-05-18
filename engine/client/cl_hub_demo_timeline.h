// SPDX-License-Identifier: 0BSD
//
// One-shot demo file scanner. Walks a recorded demo at load time to
// extract metadata for seek-bar UI (match start, total duration, etc.)
// without driving the engine playback pipeline.

#ifndef CL_HUB_DEMO_TIMELINE_H
#define CL_HUB_DEMO_TIMELINE_H

// Snapshot from the last completed scan. Zero if no scan has run.
extern int hub_demo_timelimit_ms;    // serverinfo "timelimit" minutes -> ms
extern int hub_demo_countdown_ms;    // 0 if no pre-match countdown observed
extern int hub_demo_total_ms;        // demo duration in ms (last svc_time -
                                     //   start_offset_ms, so absolute server
                                     //   time on the wire doesn't leak in)
extern int hub_demo_start_offset_ms; // absolute svc_time at demo start.
                                     // NQ demos carry absolute level time
                                     // (not zero-based like MVD/QWD), so the
                                     // event scanner subtracts this from
                                     // demtime to get demo-relative ms.
                                     // 0 for MVD/QWD (already zero-based).
// Sentinel for hub_demo_pov_slot: the scan classified the demo as
// effectively single-POV (no mvdhidden messages, no per-slot routing
// for more than one client) but couldn't pin down a specific slot from
// the file contents. Hub_GetDemoPovUserId falls back to
// cl.playerview[0].playernum when it sees this value.
#define HUB_DEMO_POV_SLOT_FROM_PLAYERVIEW (-2)

extern int hub_demo_pov_slot;        // recording POV's player slot when
                                     // the demo is effectively single-POV
                                     // (only one slot seen in dem_single /
                                     // dem_stats / dem_multiple records).
                                     // -1 when the demo is multi-POV (a
                                     // real MVD), and the binding layer
                                     // uses that as the multi-POV signal.
                                     // Always -1 for QWD/NQ scans here -
                                     // those formats are single-POV by
                                     // definition, and the binding layer
                                     // takes the slot from
                                     // playerview[0].playernum instead.
extern int hub_demo_match_end_ms;    // observed match-end timestamp in
                                     // demo-relative ms, or 0 if not seen.
                                     // NQ only: captured from the
                                     // "The match is over" svc_print most
                                     // NQ deathmatch mods emit when the
                                     // timer expires. Lets bindings split
                                     // post-match into overtime + the
                                     // intermission tail with cleaner
                                     // boundaries than the timelimit-based
                                     // math used for QW/MVD.

void Hub_DemoTimeline_Reset(void);

// Scan an already-open demo file. Uses the engine's demotype value
// (DPB_QUAKEWORLD / DPB_MVD / DPB_NETQUAKE) to pick the scanner;
// QTV / unseekable streams are no-ops. Seeks the file back to its
// position-before-scan when done so the caller's read pointer is
// untouched. Always logs a one-line summary to the console.
void Hub_DemoTimeline_Scan(vfsfile_t *file, int demotype);

#endif
