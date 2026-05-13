// SPDX-License-Identifier: 0BSD
//
// One-shot demo file scanner. Walks a recorded demo at load time to
// extract metadata for seek-bar UI (match start, total duration, etc.)
// without driving the engine playback pipeline.

#ifndef CL_HUB_DEMO_TIMELINE_H
#define CL_HUB_DEMO_TIMELINE_H

// Snapshot from the last completed scan. Zero if no scan has run.
extern int hub_demo_timelimit_ms;  // serverinfo "timelimit" minutes -> ms
extern int hub_demo_countdown_ms;    // 0 if no pre-match countdown observed
extern int hub_demo_total_ms;        // demtime at the demo's last record

void Hub_DemoTimeline_Reset(void);

// Scan an already-open demo file. Uses the engine's demotype value
// (DPB_QUAKEWORLD / DPB_MVD / DPB_NETQUAKE) to pick the scanner;
// QTV / unseekable streams are no-ops. Seeks the file back to its
// position-before-scan when done so the caller's read pointer is
// untouched. Always logs a one-line summary to the console.
void Hub_DemoTimeline_Scan(vfsfile_t *file, int demotype);

#endif
