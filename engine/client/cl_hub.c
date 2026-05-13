// SPDX-License-Identifier: 0BSD

#include "quakedef.h"
#include "cl_hub.h"
#include "cl_hub_demo_timeline.h"

// Engine helper (zqtp.c) that returns one of: "disconnected",
// "connecting", "normal", "countdown", "standby".
extern char *Macro_Match_Status(void);

int      hub_remaining_ms         = -1;
int      hub_overtime_ms = 0;
qboolean hub_match_in_progress    = false;
double   hub_match_elapsed_ms     = -1;

static char hub_prev_status[MAX_INFO_KEY] = "";

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

int Hub_GetDemoElapsedMs(void)
{
	extern float demtime;
	if (cls.demoplayback == DPB_NONE)
		return -1;
	if (cls.demoseeking == DEMOSEEK_TIME)
		return (int)floor(cls.demoseektime * 1000);
	if (demtime < 0)
		return 0;
	return (int)floor(demtime * 1000);
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
			double captured_ms = demtime * 1000.0 - hub_demo_countdown_ms;
			double max_ms      = hub_demo_timelimit_ms + hub_overtime_ms;
			captured_ms = floor(captured_ms / 1000.0 + 0.5) * 1000.0;
			hub_match_elapsed_ms = (captured_ms > max_ms) ? max_ms : captured_ms;
		}
	}
	else if (!strcmp(status, "normal"))
	{
		hub_match_in_progress = true;
		if (!strcmp(hub_prev_status, "countdown"))
		{
			hub_match_elapsed_ms = 0;
		}
		else if (hub_match_elapsed_ms < 0 && !cls.lastdemoname[0])
		{
			// QTV joined mid-match: derive elapsed from the "X min
			// left" status string. Demos use the scan-captured
			// countdown anchor instead (see Hub_HostFrame).
			float timelimit = atof(InfoBuf_ValueForKey(&cl.serverinfo, "timelimit"));
			int   total_ms  = (int)(timelimit * 60 * 1000) + hub_overtime_ms;
			if (remaining_ms >= 0 && total_ms > 0)
				hub_match_elapsed_ms = total_ms - remaining_ms;
		}
	}

	Q_strncpyz(hub_prev_status, status, sizeof(hub_prev_status));
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
		if (cl.matchstate == MATCH_INPROGRESS && demtime >= 0)
			hub_match_elapsed_ms = demtime * 1000.0 - hub_demo_countdown_ms;
	}
	else
	{
		// Live (QTV): tick by real-time frame delta when in-progress.
		if (hub_match_in_progress && hub_match_elapsed_ms >= 0)
			hub_match_elapsed_ms += frametime * 1000.0;
	}
}
