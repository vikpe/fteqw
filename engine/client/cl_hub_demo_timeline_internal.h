// SPDX-License-Identifier: 0BSD
//
// Internal handoff between Hub_DemoTimeline_Scan (the dispatcher) and
// the per-protocol scanners.

#ifndef CL_HUB_DEMO_TIMELINE_INTERNAL_H
#define CL_HUB_DEMO_TIMELINE_INTERNAL_H

// QuakeWorld-family scanner. Handles .qwd (is_mvd=false) and .mvd
// (is_mvd=true) - their per-record framing differs only in the
// time field encoding; bodies and cmd-byte semantics are identical.
void Hub_DemoTimeline_ScanQw(vfsfile_t *f, qboolean is_mvd);

// NetQuake scanner (.dem). Different framing, no QW serverinfo.
void Hub_DemoTimeline_ScanNq(vfsfile_t *f);

#endif
