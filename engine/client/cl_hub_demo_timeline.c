// SPDX-License-Identifier: 0BSD

#include "quakedef.h"
#include "cl_hub_demo_timeline.h"
#include "cl_hub_demo_timeline_internal.h"

int hub_demo_timelimit_ms    = 0;
int hub_demo_countdown_ms    = 0;
int hub_demo_total_ms        = 0;
int hub_demo_start_offset_ms = 0;
int hub_demo_match_end_ms    = 0;
int hub_demo_pov_slot        = -1;

// Cache key for skip-when-already-scanned. cls.lastdemoname is the
// authoritative identity (URLs for streamed demos, on-disk paths
// otherwise). Cleared by Hub_DemoTimeline_Reset.
static char hub_demo_last_scanned_name[MAX_OSPATH] = "";

void Hub_DemoTimeline_Reset(void)
{
	hub_demo_timelimit_ms         = 0;
	hub_demo_countdown_ms         = 0;
	hub_demo_total_ms             = 0;
	hub_demo_start_offset_ms      = 0;
	hub_demo_match_end_ms         = 0;
	hub_demo_pov_slot             = -1;
	hub_demo_last_scanned_name[0] = 0;
}

void Hub_DemoTimeline_Scan(vfsfile_t *file, int demotype)
{
	const char *demotype_name = "?";
	qofs_t      saved_pos;
	double      t_start;

	// CL_PlayDemoStream calls us on every (re)open. Skip the file
	// walk when the same demo has already been scanned - the events
	// scanner re-opens the file for fast-parse and a third time on
	// restore, which would otherwise pay ~170ms twice for no new
	// information.
	if (*cls.lastdemoname && *hub_demo_last_scanned_name &&
	    !strcmp(cls.lastdemoname, hub_demo_last_scanned_name) &&
	    hub_demo_total_ms > 0)
	{
		Con_DPrintf("[demo-timeline] cached for %s\n", cls.lastdemoname);
		return;
	}

	Hub_DemoTimeline_Reset();

	if (!file) { Con_Printf("[demo-timeline] no file\n"); return; }
	if (file->seekstyle == SS_UNSEEKABLE) { Con_Printf("[demo-timeline] unseekable, skipping\n"); return; }
	if (VFS_GETLEN(file) <= 0) { Con_Printf("[demo-timeline] empty file (download pending), skipping\n"); return; }

	switch (demotype)
	{
	case DPB_QUAKEWORLD: demotype_name = "qwd"; break;
	case DPB_MVD:        demotype_name = "mvd"; break;
	case DPB_NETQUAKE:   demotype_name = "nq";  break;
	default:             Con_Printf("[demo-timeline] unsupported demotype %d\n", demotype); return;
	}

	saved_pos = VFS_TELL(file);
	if (VFS_SEEK(file, 0) < 0) { Con_Printf("[demo-timeline] seek to 0 failed\n"); return; }

	t_start = Sys_DoubleTime();

	switch (demotype)
	{
	case DPB_QUAKEWORLD: Hub_DemoTimeline_ScanQw(file, false); break;
	case DPB_MVD:        Hub_DemoTimeline_ScanQw(file, true);  break;
	case DPB_NETQUAKE:   Hub_DemoTimeline_ScanNq(file);        break;
	}

	double scan_ms = (Sys_DoubleTime() - t_start) * 1000;

	VFS_SEEK(file, saved_pos);

	Q_strncpyz(hub_demo_last_scanned_name, cls.lastdemoname,
	           sizeof(hub_demo_last_scanned_name));

	Con_Printf("[demo-timeline] %s: timelimit=%dms countdown=%dms total=%dms start_offset=%dms match_end=%dms pov_slot=%d (scanned in %.1fms)\n",
	           demotype_name,
	           hub_demo_timelimit_ms,
	           hub_demo_countdown_ms,
	           hub_demo_total_ms,
	           hub_demo_start_offset_ms,
	           hub_demo_match_end_ms,
	           hub_demo_pov_slot,
	           scan_ms);
}
