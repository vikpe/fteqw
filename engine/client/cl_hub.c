// SPDX-License-Identifier: 0BSD

#include "quakedef.h"
#include "cl_hub.h"

// Engine helper (zqtp.c) that returns one of: "disconnected",
// "connecting", "normal", "countdown", "standby".
extern char *Macro_Match_Status(void);

int      hub_seconds_left       = -1;
int      hub_overtime_duration  = 0;
qboolean hub_match_in_progress  = false;
double   hub_match_elapsed      = -1;
double   hub_countdown_duration = 10;

static char hub_prev_status[MAX_INFO_KEY] = "";

// Parse "<N> min[s]/sec[s]/hour[s] left" from cl.serverinfo "status",
// returning remaining match seconds or -1 if the string isn't in that
// form (e.g. it reads "Standby" or "Countdown").
static int hub_parse_status_remaining(void)
{
	char *status = InfoBuf_ValueForKey(&cl.serverinfo, "status");
	int value = (int)strtol(status, &status, 10);
	if (!strcmp(status, " min left") || !strcmp(status, " mins left"))
		return value * 60;
	if (!strcmp(status, " sec left") || !strcmp(status, " secs left"))
		return value;
	if (!strcmp(status, " hour left") || !strcmp(status, " hours left"))
		return value * 60 * 60;
	return -1;
}

void Hub_ResetMatchState(void)
{
	hub_seconds_left       = -1;
	hub_overtime_duration  = 0;
	hub_match_in_progress  = false;
	hub_match_elapsed      = -1;
	hub_countdown_duration = 10;
	hub_prev_status[0]     = 0;
}

int Hub_GetDemoElapsed(void)
{
	extern float demtime;
	if (cls.demoplayback == DPB_NONE)
		return -1;
	if (cls.demoseeking == DEMOSEEK_TIME)
		return (int)floor(cls.demoseektime);
	if (demtime < 0)
		return 0;
	return (int)floor(demtime);
}

int Hub_GetMatchElapsed(void)
{
	if (cls.state != ca_active)
		return -1;
	if (cls.demoplayback == DPB_NONE)
		return -1;
	if (hub_match_elapsed < 0)
		return -1;
	return (int)floor(hub_match_elapsed);
}

void Hub_CheckServerInfo(void)
{
	// Track "X min left" to detect overtime announcements. ktx-style
	// mods announce OT by jumping the status remaining back up (e.g.
	// "1 min left" -> "5 min left"); any increase over the previously
	// observed value is OT, accumulated into hub_overtime_duration.
	int remaining = hub_parse_status_remaining();
	if (remaining >= 0)
	{
		if (hub_seconds_left >= 0 && remaining > hub_seconds_left)
			hub_overtime_duration += remaining - hub_seconds_left;
		hub_seconds_left = remaining;
	}

	const char *status = Macro_Match_Status();
	if (strcmp(status, hub_prev_status) == 0)
		return;

	if (!strcmp(status, "countdown"))
	{
		// New match starting - clear accumulators so the next OT
		// detection cycle starts fresh. Reset the countdown anchor to
		// the assumed default; Hub_HostFrame extends it if the actual
		// countdown runs longer.
		hub_match_elapsed      = -1;
		hub_match_in_progress  = false;
		hub_seconds_left       = -1;
		hub_overtime_duration     = 0;
		hub_countdown_duration = 10;
	}
	else if (!strcmp(status, "standby"))
	{
		hub_match_in_progress = false;
	}
	else if (!strcmp(status, "normal"))
	{
		hub_match_in_progress = true;
		if (!strcmp(hub_prev_status, "countdown"))
		{
			hub_match_elapsed = 0;
		}
		else if (hub_match_elapsed < 0 && !cls.lastdemoname[0])
		{
			// Live join mid-match: derive elapsed from the "X min left"
			// status string. Demos rely on demtime + hub_countdown_duration
			// (see Hub_HostFrame); the pull-down anchor handles them.
			float timelimit = atof(InfoBuf_ValueForKey(&cl.serverinfo, "timelimit"));
			float total     = 60 * timelimit + hub_overtime_duration;
			if (remaining >= 0 && total > 0)
				hub_match_elapsed = total - remaining;
		}
	}

	Q_strncpyz(hub_prev_status, status, sizeof(hub_prev_status));
}

void Hub_HostFrame(double frametime)
{
	// Live (non-demo) match clock: tick by real-time frame delta. Demos
	// derive the clock from demtime below so the value is exact across
	// pause / seek / variable playback speed.
	if (!cls.lastdemoname[0])
	{
		if (hub_match_in_progress && hub_match_elapsed >= 0)
			hub_match_elapsed += frametime;
	}

	if (cls.lastdemoname[0])
	{
		extern float demtime;
		if (demtime < 0)
			return;

		// Track the demtime offset where the match begins. While in
		// COUNTDOWN, extend the anchor up to current demtime if the
		// countdown runs longer than the default 10s. Once INPROGRESS,
		// pull the anchor down if demtime is earlier than the anchor
		// (shorter countdown, or demo joined mid-match with no prior
		// status-derived seed).
		if (cl.matchstate == MATCH_COUNTDOWN && demtime > hub_countdown_duration)
			hub_countdown_duration = demtime;
		else if (cl.matchstate == MATCH_INPROGRESS && demtime < hub_countdown_duration)
			hub_countdown_duration = demtime;

		// Demo match clock: demtime is authoritative, derive from the
		// anchor. STANDBY/COUNTDOWN don't update so the clock freezes
		// during intermission and stays -1 during countdown.
		if (cl.matchstate == MATCH_INPROGRESS)
			hub_match_elapsed = demtime - hub_countdown_duration;
	}
}
