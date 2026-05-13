// SPDX-License-Identifier: 0BSD

#include "quakedef.h"
#include "cl_hub.h"

// Engine helper (zqtp.c) that returns one of: "disconnected",
// "connecting", "normal", "countdown", "standby".
extern char *Macro_Match_Status(void);

qboolean hub_qtv_match_in_progress = false;
double   hub_qtv_match_time       = -1;

// Recorded demos: demtime offset where the match began. Defaults to 10
// (the standard countdown duration) so a demo that records the full
// pre-match countdown reads 00:00 at the moment the match starts. If
// the matchstate becomes non-COUNTDOWN while demtime is still below the
// anchor, we joined mid-game or in standby and pull the anchor back to
// current demtime. demtime is authoritative for demos, so the "X min[s]
// left" print parser is not consulted here.
double hub_demo_match_started_at = 10;

// Accumulates "N minutes overtime follows" prints (see
// cl_parse.c:CL_ParseOvertimeLine). Shared with the demo path because
// demos can have overtime announcements too; it just isn't used to
// derive demo elapsed time (demtime serves that role for recorded
// demos).
int hub_match_total_overtime;

// Last status seen on the previous Hub_CheckServerInfo. We only act on
// qtv match clock transitions when this changes, so repeated serverinfo
// refreshes carrying the same status are no-ops for that branch. Sized
// to MAX_INFO_KEY so any value reachable through cl.serverinfo fits
// without truncation; Q_strncpyz is bounded regardless.
static char hub_prev_status[MAX_INFO_KEY] = "";

// Parse "<N> min[s]/sec[s]/hour[s] left" from cl.serverinfo "status",
// returning remaining match seconds or -1 if the string isn't in that
// form (e.g. it reads "Standby" or "Countdown").
static float hub_parse_status_remaining(void)
{
	char *s = InfoBuf_ValueForKey(&cl.serverinfo, "status");
	float t = strtod(s, &s);
	if (!strcmp(s, " min left") || !strcmp(s, " mins left"))
		return t * 60;
	if (!strcmp(s, " sec left") || !strcmp(s, " secs left"))
		return t;
	if (!strcmp(s, " hour left") || !strcmp(s, " hours left"))
		return t * 60 * 60;
	return -1;
}

// Clear the cached match clock state. Called from CL_MakeActive and
// from demo seek paths so stale values don't leak across boundaries.
void Hub_ResetMatchState(void)
{
	hub_qtv_match_in_progress = false;
	hub_qtv_match_time       = -1;
	hub_demo_match_started_at = 10;
	hub_match_total_overtime = 0;
	hub_prev_status[0]     = 0;
}

// Whole seconds of demo playback position (demtime). -1 when not
// playing back a demo or stream. While seeking, report the target
// position - the engine restarts the demo for backward seeks and
// demtime briefly reads 0 until the fast-parse catches up, which would
// otherwise yank a progress bar back to the start.
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

// Total demo length in whole seconds, i.e. timelimit + any overtime
// announcements parsed so far. -1 when not playing back a demo or
// stream, or when no timelimit is known.
int Hub_GetDemoDuration(void)
{
	float timelimit;
	if (cls.demoplayback == DPB_NONE)
		return -1;
	timelimit = atof(InfoBuf_ValueForKey(&cl.serverinfo, "timelimit"));
	if (timelimit <= 0)
		return -1;
	return (int)(timelimit * 60) + hub_match_total_overtime;
}

// Whole seconds elapsed since the match started (floored).
//   >= 0  match clock available
//   -1    no match context: disconnected, not yet active, no clock yet.
//
// Two paths:
//   Recorded demo (cls.lastdemoname set): elapsed = demtime - hub_demo_match_started_at.
//     The anchor defaults to 10 (standard countdown) and is pulled to
//     current demtime by Hub_CheckServerInfo if a non-COUNTDOWN status
//     is observed while still inside that window.
//   QTV (live stream, lastdemoname empty): hub_qtv_match_time, maintained by
//     Hub_CheckServerInfo + Hub_HostFrame.
int Hub_GetMatchElapsed(void)
{
	if (cls.state != ca_active)
		return -1;
	if (cls.demoplayback == DPB_NONE)
		return -1;

	if (cls.lastdemoname[0])
	{
		extern float demtime;
		double elapsed;
		if (hub_demo_match_started_at < 0)
			return -1;
		elapsed = demtime - hub_demo_match_started_at;
		if (elapsed < 0)
			return -1;
		return (int)floor(elapsed);
	}

	if (hub_qtv_match_time < 0)
		return -1;
	return (int)floor(hub_qtv_match_time);
}

void Hub_CheckServerInfo(void)
{
	const char *status = Macro_Match_Status();

	// QTV match clock: act on status transitions.
	if (strcmp(status, hub_prev_status) != 0)
	{
		if (!strcmp(status, "countdown"))
		{
			hub_qtv_match_time       = -1;
			hub_qtv_match_in_progress = false;
		}
		else if (!strcmp(status, "standby"))
		{
			hub_qtv_match_in_progress = false;
		}
		else if (!strcmp(status, "normal"))
		{
			hub_qtv_match_in_progress = true;
			if (!strcmp(hub_prev_status, "countdown"))
			{
				hub_qtv_match_time = 0;
			}
			else if (hub_qtv_match_time < 0)
			{
				// Joined mid-match: derive elapsed from the "X min
				// left" status string.
				float remaining = hub_parse_status_remaining();
				float timelimit = atof(InfoBuf_ValueForKey(&cl.serverinfo, "timelimit"));
				float total     = 60 * timelimit + hub_match_total_overtime;
				if (remaining >= 0 && total > 0)
					hub_qtv_match_time = total - remaining;
			}
		}
		Q_strncpyz(hub_prev_status, status, sizeof(hub_prev_status));
	}

	// Recorded demo: anchor pull-down. Fires on every serverinfo
	// refresh (not just transitions) - the comparison is idempotent
	// once the anchor reaches the minimum demtime observed.
	if (cls.lastdemoname[0] && strcmp(status, "countdown") != 0)
	{
		extern float demtime;
		if (demtime >= 0 && demtime < hub_demo_match_started_at)
			hub_demo_match_started_at = demtime;
	}
}

void Hub_HostFrame(double frametime)
{
	if (hub_qtv_match_in_progress && hub_qtv_match_time >= 0)
		hub_qtv_match_time += frametime;
}
