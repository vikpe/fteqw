// SPDX-License-Identifier: 0BSD

#include "quakedef.h"
#include "cl_hub.h"
#include "cl_hub_demo.h"
#include "cl_hub_demo_timeline.h"

// Engine helper (zqtp.c) that returns one of: "disconnected",
// "connecting", "normal", "countdown", "standby".
extern char *Macro_Match_Status(void);

int      hub_remaining_ms         = -1;
int      hub_overtime_ms = 0;
qboolean hub_match_in_progress    = false;
double   hub_match_elapsed_ms     = -1;

static char hub_prev_status[MAX_INFO_KEY] = "";

// Match elapsed from the server clock pair (STAT_TIME - STAT_MATCHSTARTTIME),
// stamped with the realtime it arrived. -1 when no pair has been seen.
static double hub_server_stat_elapsed_ms = -1;
static double hub_server_stat_realtime;

// Last positive cl_demospeed, restored when demo_toggle_pause resumes.
static float hub_last_positive_demo_speed = 1;

static void Hub_DemoTogglePause_f(void);

void Hub_Init(void)
{
	Cmd_AddCommandD("demo_toggle_pause", Hub_DemoTogglePause_f,
	                "Pauses demo playback, or resumes it at the last non-zero speed. No-op for QTV / live.");
}

// Parse "<N> min[s]/sec[s]/hour[s] left" from cl.serverinfo "status",
// returning remaining match milliseconds or -1 if the string isn't in
// that form (e.g. it reads "Standby" or "Countdown").
static int hub_parse_status_remaining_ms(void)
{
	char *status = InfoBuf_ValueForKey(&cl.serverinfo, "status");
	int value = (int)strtol(status, &status, 10);
	if (!strcmp(status, " min left") || !strcmp(status, " mins left"))
		return value * 60 * 1000;
	if (!strcmp(status, " sec left") || !strcmp(status, " secs left"))
		return value * 1000;
	if (!strcmp(status, " hour left") || !strcmp(status, " hours left"))
		return value * 60 * 60 * 1000;
	return -1;
}

void Hub_ResetMatchState(void)
{
	hub_remaining_ms         = -1;
	hub_overtime_ms = 0;
	hub_match_in_progress    = false;
	hub_match_elapsed_ms     = -1;
	hub_prev_status[0]       = 0;
}

// Called when STAT_TIME lands for `slot`; STAT_MATCHSTARTTIME precedes it in
// the same block, so the pair is read together. A later STAT_MATCHSTARTTIME
// alone (respawn) must not restamp a stale STAT_TIME.
void Hub_OnServerTimeStat(int slot)
{
	int server_time_ms = cl.players[slot].stats[STAT_TIME];
	int match_start_ms = cl.players[slot].stats[STAT_MATCHSTARTTIME];
	if (server_time_ms <= 0 || match_start_ms <= 0 || server_time_ms < match_start_ms)
	{
		hub_server_stat_elapsed_ms = -1;
		return;
	}
	hub_server_stat_elapsed_ms = server_time_ms - match_start_ms;
	hub_server_stat_realtime   = realtime;
}

void Hub_ClearServerTimeStat(void)
{
	hub_server_stat_elapsed_ms = -1;
}

// QTV mid-match join. A proxy may put its own uptime in STAT_TIME, so the pair
// is trusted only inside the minute the current "X min left" reading opened.
static void Hub_AnchorQtvFromServerStats(void)
{
	if (hub_server_stat_elapsed_ms < 0)
		return;
	int remaining_ms = hub_parse_status_remaining_ms();
	int total_ms     = (int)(atof(InfoBuf_ValueForKey(&cl.serverinfo, "timelimit")) * 60 * 1000) + hub_overtime_ms;
	if (remaining_ms < 0 || total_ms <= 0 || remaining_ms > total_ms)
		return;
	const double slack_ms    = 1000;
	double window_start_ms   = total_ms - remaining_ms;
	double elapsed_ms        = hub_server_stat_elapsed_ms + (realtime - hub_server_stat_realtime) * 1000.0;
	qboolean is_in_window    = elapsed_ms >= window_start_ms - slack_ms
	                        && elapsed_ms <  window_start_ms + 60 * 1000 + slack_ms;
	if (!is_in_window)
		return;
	hub_match_elapsed_ms  = elapsed_ms;
	hub_match_in_progress = true;
}

// NQ demos drive demtime from cl.gametime, which is absolute level time -
// it carries hub_demo_start_offset_ms of bias when recording began
// mid-level. QW/MVD already zero demtime at demo start, so for those the
// start_offset is 0 and the subtraction is a no-op.
static double Hub_GetDemoTimeRelativeMs(double t_seconds)
{
	double ms = t_seconds * 1000.0 - (double)hub_demo_start_offset_ms;
	return ms < 0 ? 0 : ms;
}

int Hub_GetDemoElapsedMs(void)
{
	extern float demtime;
	if (cls.demoplayback == DPB_NONE)
		return -1;
	if (cls.demoseeking == DEMOSEEK_TIME)
		return (int)floor(Hub_GetDemoTimeRelativeMs(cls.demoseektime));
	if (demtime < 0)
		return 0;
	return (int)floor(Hub_GetDemoTimeRelativeMs(demtime));
}

int Hub_GetMatchElapsedMs(void)
{
	if (cls.state != ca_active)
		return -1;
	if (cls.demoplayback == DPB_NONE)
		return -1;
	if (hub_match_elapsed_ms < 0)
		return -1;
	return (int)floor(hub_match_elapsed_ms);
}

void Hub_CheckServerInfo(void)
{
	// We only track the match clock for demo / qtv playback. Live
	// servers (joined directly) use the engine's own gameclock path.
	// Reset state on the transition out so stale values don't bleed
	// into a subsequent demo / qtv session.
	if (cls.demoplayback == DPB_NONE)
	{
		if (hub_match_elapsed_ms >= 0 || hub_match_in_progress)
			Hub_ResetMatchState();
		return;
	}

	// Track "X min left" to detect overtime announcements. ktx-style
	// mods announce OT by jumping the status remaining back up (e.g.
	// "1 min left" -> "5 min left"); any increase over the previously
	// observed value is OT, accumulated into hub_overtime_ms.
	int remaining_ms = hub_parse_status_remaining_ms();
	if (remaining_ms >= 0)
	{
		if (hub_remaining_ms >= 0 && remaining_ms > hub_remaining_ms)
			hub_overtime_ms += remaining_ms - hub_remaining_ms;
		else if (hub_remaining_ms >= 0 && remaining_ms < hub_remaining_ms
		         && hub_match_elapsed_ms < 0 && !cls.lastdemoname[0])
		{
			// QTV joined mid-match without a usable server clock pair:
			// the first minute decrement is an exact anchor.
			float timelimit = atof(InfoBuf_ValueForKey(&cl.serverinfo, "timelimit"));
			int   total_ms  = (int)(timelimit * 60 * 1000) + hub_overtime_ms;
			if (total_ms > 0)
			{
				hub_match_elapsed_ms  = total_ms - remaining_ms;
				hub_match_in_progress = true;
			}
		}
		hub_remaining_ms = remaining_ms;
	}

	const char *status = Macro_Match_Status();
	if (strcmp(status, hub_prev_status) == 0)
		return;

	if (!strcmp(status, "countdown"))
	{
		// New match starting - clear accumulators so the next OT
		// detection cycle starts fresh.
		hub_match_elapsed_ms     = -1;
		hub_match_in_progress    = false;
		hub_remaining_ms         = -1;
		hub_overtime_ms = 0;
	}
	else if (!strcmp(status, "standby"))
	{
		hub_match_in_progress = false;
		// Demo: capture the match clock at the moment of the match-end
		// transition. Fires inside fast-parse seek loops too (where
		// Hub_HostFrame doesn't get to see the intermediate frames),
		// so jumping past intermission still freezes the clock at the
		// correct end-of-match value instead of the pre-seek one.
		if (cls.lastdemoname[0] && !strcmp(hub_prev_status, "normal"))
		{
			extern float demtime;
			double captured_ms = Hub_GetDemoTimeRelativeMs(demtime) - hub_demo_countdown_ms;
			double max_ms      = hub_demo_timelimit_ms + hub_overtime_ms;
			captured_ms = floor(captured_ms / 1000.0 + 0.5) * 1000.0;
			hub_match_elapsed_ms = (captured_ms > max_ms) ? max_ms : captured_ms;
		}
	}
	else if (!strcmp(status, "normal"))
	{
		hub_match_in_progress = true;
		if (!strcmp(hub_prev_status, "countdown"))
			hub_match_elapsed_ms = 0;
	}

	Q_strncpyz(hub_prev_status, status, sizeof(hub_prev_status));
}

// TP_NewMap looks for the .loc once per map; when this GET lands after the
// map has loaded, nothing would pick it up. Reload once it's on disk.
static void Hub_MapLocDownloaded(struct dl_download *dl)
{
	extern cvar_t host_mapname;
	char loc_base[MAX_QPATH];
	if (dl->status != DL_FINISHED) return;	// missing .loc is fine
	// DL_Close only closes the file after notifying; close it now so the FS can read it
	if (dl->file) VFS_CLOSE(dl->file);
	dl->file = NULL;
	FS_FlushFSHashWritten(dl->localname);
	// arrived before the map loaded (TP_NewMap will find it) or for a previous map
	COM_FileBase(dl->localname, loc_base, sizeof(loc_base));
	if (strcmp(loc_base, host_mapname.string)) return;
	TP_ReloadCurrentLocs();
}

// Best-effort GET of the matching .loc from cl_download_mapsrc when the
// world BSP is being precached. The standard CL_CheckOrEnqueDownloadFile
// path can't be used here because sv.state is set on +map (listen
// server) and short-circuits with "no downloading if we're the one
// we'd be downloading from"; HTTP_CL_Get sidesteps that, same pattern
// SV_Map_DownloadStart (sv_ccmds.c) uses for its own BSP fetch.
//
// Silent on every failure path (no UI feedback, no fallback) - a
// missing .loc is fine, location names just stay empty. On success
// Hub_MapLocDownloaded reloads locs if the map already loaded.
// CL_CheckDLFile skips the GET when the .loc is already in the FS
// (id1 paks loaded at boot, prior-session cache, custom map pk3 that
// happens to be registered before this hook fires).
void Hub_RequestMapLoc(const char *bsp_filename)
{
	extern cvar_t cl_download_mapsrc;
	char loc_base[MAX_QPATH];
	char loc_path[MAX_QPATH];
	size_t len;
	if (!bsp_filename || !*cl_download_mapsrc.string) return;
	if (strncmp(bsp_filename, "maps/", 5)) return;
	len = strlen(bsp_filename);
	if (len < 4 || strcmp(bsp_filename + len - 4, ".bsp")) return;
	COM_FileBase(bsp_filename, loc_base, sizeof(loc_base));
	Q_snprintfz(loc_path, sizeof(loc_path), "locs/%s.loc", loc_base);
	if (CL_CheckDLFile(loc_path)) return;
	HTTP_CL_Get(va("%s%s.loc", cl_download_mapsrc.string, loc_base),
	            loc_path, Hub_MapLocDownloaded);
}

void Hub_HostFrame(double frametime)
{
    // Same scope as Hub_CheckServerInfo: only ticks for demo / qtv.
	if (cls.demoplayback == DPB_NONE)
		return;

	if (cls.lastdemoname[0])
	{
		// Demo: derive the match clock from demtime + the scan-
		// captured countdown anchor (hub_demo_countdown_ms, exact
		// transition demtime observed during the file scan).
		// STANDBY/COUNTDOWN don't update so the clock stays -1
		// pre-match and freezes during intermission.
		extern float demtime;
		if (cls.protocol == CP_NETQUAKE)
		{
			// NQ has no serverinfo "status" string, so cl.matchstate
			// never reaches MATCH_INPROGRESS. Drive the clock from
			// the scan anchors instead: -1 pre-match (clock hidden),
			// elapsed during the match, frozen at match-end during
			// the post-match tail. Skip when the scan produced no
			// countdown anchor (e.g. unseekable / unsupported demo).
			if (demtime < 0 || hub_demo_countdown_ms <= 0)
			{
				hub_match_elapsed_ms = -1;
			}
			else
			{
				double rel_ms = Hub_GetDemoTimeRelativeMs(demtime);
				if (rel_ms < hub_demo_countdown_ms)
					hub_match_elapsed_ms = -1;
				else if (hub_demo_match_end_ms > 0 &&
				         rel_ms >= hub_demo_match_end_ms)
					hub_match_elapsed_ms = hub_demo_match_end_ms - hub_demo_countdown_ms;
				else
					hub_match_elapsed_ms = rel_ms - hub_demo_countdown_ms;
			}
		}
		else if (cl.matchstate == MATCH_INPROGRESS && demtime >= 0)
		{
			hub_match_elapsed_ms = Hub_GetDemoTimeRelativeMs(demtime) - hub_demo_countdown_ms;
		}
	}
	else
	{
		// Live (QTV): tick by real-time frame delta when in-progress.
		if (hub_match_elapsed_ms < 0 && cl.matchstate == MATCH_INPROGRESS)
			Hub_AnchorQtvFromServerStats();
		if (hub_match_in_progress && hub_match_elapsed_ms >= 0)
			hub_match_elapsed_ms += frametime * 1000.0;
	}
}

// Maps whose lit ships separately (legacy + GPL id maps); the map source has them
// as packaged/<map>.bsp.gz with lit and loc appended. Sorted (byte order) for bsearch.
static const char *const hub_packaged_maps[] = {
	"aerowalk",
	"bravado",
	"ctf2m1",
	"ctf2m2",
	"ctf5",
	"ctf8",
	"dm1",
	"dm2",
	"dm3",
	"dm4",
	"dm5",
	"dm6",
	"e1m1",
	"e1m2",
	"e1m3",
	"e1m4",
	"e1m5",
	"e1m6",
	"e1m7",
	"e1m8",
	"e2m1",
	"e2m2",
	"e2m3",
	"e2m4",
	"e2m5",
	"e2m6",
	"e2m7",
	"e3m1",
	"e3m2",
	"e3m3",
	"e3m4",
	"e3m5",
	"e3m6",
	"e3m7",
	"e4m1",
	"e4m2",
	"e4m3",
	"e4m4",
	"e4m5",
	"e4m6",
	"e4m7",
	"e4m8",
	"end",
	"endif",
	"povdmm4",
	"schloss",
	"shifter",
	"start",
	"ztndm3",
};

static int Hub_CompareMapName(const void *key, const void *element)
{
	return strcmp((const char *)key, *(const char *const *)element);
}

qboolean Hub_MapIsPackaged(const char *map_name)
{
	return bsearch(map_name, hub_packaged_maps, countof(hub_packaged_maps),
	               sizeof(hub_packaged_maps[0]), Hub_CompareMapName) != NULL;
}

static void Hub_DemoTogglePause_f(void)
{
	extern cvar_t cl_demospeed;
	if (!Hub_IsSeekableDemo())
		return;
	if (cl_demospeed.value > 0)
	{
		hub_last_positive_demo_speed = cl_demospeed.value;
		Cvar_SetValue(&cl_demospeed, 0);
	}
	else
		Cvar_SetValue(&cl_demospeed, hub_last_positive_demo_speed);
}
