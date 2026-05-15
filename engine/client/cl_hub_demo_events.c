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

hub_demo_event_t *hub_demo_events       = NULL;
int               hub_demo_event_count  = 0;

static int      events_capacity      = 0;
static qboolean is_recording         = false;
static qboolean has_seen_health[MAX_CLIENTS];
static char     last_scanned_demo[MAX_OSPATH] = "";

void Hub_DemoEvents_Reset(void)
{
	hub_demo_event_count = 0;
	for (int i = 0; i < MAX_CLIENTS; i++)
		has_seen_health[i] = false;
}

qboolean Hub_DemoEvents_IsRecording(void)
{
	return is_recording;
}

static void events_push(hub_demo_event_kind_t kind, int victim_slot)
{
	if (hub_demo_event_count >= events_capacity)
	{
		int new_cap = events_capacity ? events_capacity * 2 : 256;
		hub_demo_events = BZ_Realloc(hub_demo_events,
		                             sizeof(hub_demo_event_t) * new_cap);
		events_capacity = new_cap;
	}
	hub_demo_event_t *ev = &hub_demo_events[hub_demo_event_count++];
	ev->time_ms = (int)floor(demtime * 1000);
	ev->kind    = kind;
	if (victim_slot >= 0 && victim_slot < MAX_CLIENTS)
	{
		ev->victim_userid = cl.players[victim_slot].userid;
		Hub_QuakeStringToUtf8(cl.players[victim_slot].name,
		                      ev->victim, sizeof(ev->victim));
		// Most recently received origin for this slot. Filled by
		// svc_playerinfo in the same packet as the death stat (or the
		// immediately prior packet) - within ~50ms of the death.
		float *src = cl.inframes[cl.parsecount & UPDATE_MASK]
		                .playerstate[victim_slot].origin;
		ev->origin[0] = src[0];
		ev->origin[1] = src[1];
		ev->origin[2] = src[2];
	}
	else
	{
		ev->victim_userid = 0;
		ev->victim[0]     = 0;
		ev->origin[0]     = ev->origin[1] = ev->origin[2] = 0;
	}
}

void Hub_DemoEvents_OnStatUpdate(int slot, unsigned int stat,
                                 int old_ivalue, int new_ivalue)
{
	if (!is_recording) return;
	if (slot < 0 || slot >= MAX_CLIENTS) return;
	if (stat != STAT_HEALTH) return;

	// First health value seen for this slot is just the initial spawn
	// snapshot, not a death even if it happens to be 0.
	if (!has_seen_health[slot])
	{
		has_seen_health[slot] = true;
		return;
	}

	// Only count deaths during the actual match. cl.matchstate is
	// updated during fast-parse via CL_CheckServerInfo (cl_main.c:3270).
	// hub_match_in_progress isn't usable here: it goes through
	// Macro_Match_Status which requires cls.state >= ca_active, and
	// that only flips inside Host_Frame (CL_MakeActive,
	// cl_main.c:7355-7358) - never inside our pump loop. MATCH_DONTKNOW
	// is treated as in-match per the client.h:1032 convention.
	qboolean in_match = (cl.matchstate == MATCH_INPROGRESS ||
	                     cl.matchstate == MATCH_DONTKNOW);
	if (!in_match) return;

	if (old_ivalue > 0 && new_ivalue <= 0)
		events_push(HDE_KIND_DEATH, slot);
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
		Con_Printf("  %6d ms  death  victim=%-16s pos=%.0f %.0f %.0f\n",
		           ev->time_ms, ev->victim,
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
