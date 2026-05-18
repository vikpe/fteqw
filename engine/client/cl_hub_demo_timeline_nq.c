// SPDX-License-Identifier: 0BSD
//
// NetQuake demo (.dem) scanner. Format:
//   header line: `<cdtrack>\n`
//   records:     int msglength + 12 bytes viewangles + msglength body
// NQ has no serverinfo / countdown concept. svc_time carries the
// absolute server/level time (NOT demo-relative like MVD msec deltas),
// so to report a useful duration we capture both the first and last
// svc_time and compute (last - first). The first value is also exported
// as hub_demo_start_offset_ms so the event scanner can subtract it to
// get demo-relative event timestamps.
//
// NQ also has no serverinfo "timelimit" key, so we recover timelimit +
// countdown anchor by sniffing svc_print payloads for the
// "N minute(s) remaining" announcement most NQ deathmatch mods emit at
// match start AND periodically as the clock counts down. The first
// observation isn't reliable - if the demo was recorded mid-match the
// initial banner is gone and the first hit is a smaller mid-match
// warning. We instead track the largest N seen across the whole demo
// and anchor (timelimit, countdown) to that print, which is the
// match-start announcement when present (and the best available proxy
// otherwise).
//
// Match end is captured separately by sniffing for the "The match is
// over" svc_print most NQ deathmatch mods emit when the timer expires;
// stored in hub_demo_match_end_ms (demo-relative). Lets the bindings
// distinguish overtime from intermission without relying on the QW-side
// "post-match minus multiple-of-60s overtime" heuristic.

#include "quakedef.h"
#include "cl_hub_demo_timeline.h"
#include "cl_hub_demo_timeline_internal.h"

#define NQ_SVC_TIME 7
#define NQ_BODY_CAP (64 * 1024) // matches MAX_NQMSGLEN

// Substring-scan the packet body for "N minute(s) remaining" and return
// the largest N found, or 0 if none. The bare substring lookup is
// mod-portable (different NQ DM mods phrase the header differently but
// the suffix is conventional). Accepts both plain ("9 minutes remaining")
// and bracketed ("[9] minutes remaining") formats - some NQ mods wrap
// the digits in square brackets for emphasis. Bounded to 1..999 to
// reject false positives from arbitrary digits adjacent to the keyword
// in non-print payloads.
static int nq_find_minutes_remaining(const unsigned char *body, int len)
{
	static const char K_PLURAL[]   = " minutes remaining";
	static const char K_SINGULAR[] = " minute remaining";
	int klen_p = (int)sizeof(K_PLURAL)   - 1;
	int klen_s = (int)sizeof(K_SINGULAR) - 1;
	int best = 0;

	for (int i = 0; i + klen_s <= len; i++)
	{
		if      (i + klen_p <= len && memcmp(body + i, K_PLURAL,   klen_p) == 0) ;
		else if (i + klen_s <= len && memcmp(body + i, K_SINGULAR, klen_s) == 0) ;
		else continue;

		// Backtrack to read the leading number, optionally wrapped in
		// square brackets.
		int j         = i - 1;
		int has_close = (j >= 0 && body[j] == ']');
		if (has_close) j--;
		int num = 0;
		int mul = 1;
		while (j >= 0 && body[j] >= '0' && body[j] <= '9')
		{
			num += (body[j] - '0') * mul;
			mul *= 10;
			j--;
		}
		if (mul == 1)                                       continue;  // no digits before the keyword
		if (has_close && (j < 0 || body[j] != '['))         continue;  // close without matching open
		if (num <= 0 || num > 999)                          continue;  // not a plausible match length
		if (num > best)                                     best = num;
	}
	return best;
}

// Substring match for the "The match is over" print. First hit wins
// (matches the timelimit-scan policy), so a server that re-prints the
// banner during intermission doesn't shift the match-end anchor later.
static qboolean nq_find_match_over(const unsigned char *body, int len)
{
	static const char K[] = "The match is over";
	int klen = (int)sizeof(K) - 1;
	if (len < klen) return false;
	for (int i = 0; i + klen <= len; i++)
		if (memcmp(body + i, K, klen) == 0) return true;
	return false;
}

void Hub_DemoTimeline_ScanNq(vfsfile_t *f)
{
	float          first_time     = 0;
	float          last_time      = 0;
	qboolean       has_first_time = false;
	qboolean       has_match_end  = false;
	int            best_minutes   = 0;
	char           c              = 0;
	unsigned char *body           = NULL;

	// Skip CD-track header line.
	while (VFS_READ(f, &c, 1) == 1 && c != '\n')
		;
	if (c != '\n')
		goto done;

	body = Z_Malloc(NQ_BODY_CAP);

	for (;;)
	{
		int msglength;
		if (VFS_READ(f, &msglength, sizeof(msglength)) != (int)sizeof(msglength))
			break;
		msglength = LittleLong(msglength);
		if (msglength == -1) // explicit EOF marker (Q2-style; tolerated here)
			break;
		if (msglength < 0 || msglength > NQ_BODY_CAP)
			break;

		// Skip viewangles (3 floats).
		if (VFS_SEEK(f, VFS_TELL(f) + 12) < 0)
			break;

		if (msglength == 0)
			continue;
		if (VFS_READ(f, body, msglength) != msglength)
			break;

		// svc_time is conventionally the first message in a packet.
		// Peek the leading byte; if it's svc_time, the next 4 bytes
		// are the float timestamp.
		if (body[0] == NQ_SVC_TIME && msglength >= 5)
		{
			float t;
			memcpy(&t, body + 1, 4);
			last_time = LittleFloat(t);
			if (!has_first_time)
			{
				first_time     = last_time;
				has_first_time = true;
			}
		}

		// Search the body for the timelimit print. The largest N wins
		// (the match-start banner carries the timelimit; mid-match
		// warnings count down with smaller N). Anchoring countdown to
		// the *first packet that carries the new max* lines up with
		// the match-start announcement when the demo captures it, and
		// degrades gracefully to "earliest available announcement" for
		// mid-match recordings.
		if (has_first_time)
		{
			int mins = nq_find_minutes_remaining(body, msglength);
			if (mins > best_minutes)
			{
				best_minutes          = mins;
				hub_demo_timelimit_ms = mins * 60 * 1000;
				hub_demo_countdown_ms =
				    (int)floor((last_time - first_time) * 1000);
			}
		}

		// Match-end print. Captured demo-relative (subtract first_time
		// so the value lines up with countdown_ms and total_ms).
		if (!has_match_end && has_first_time &&
		    nq_find_match_over(body, msglength))
		{
			hub_demo_match_end_ms =
			    (int)floor((last_time - first_time) * 1000);
			has_match_end = true;
		}
	}

done:
	if (body) Z_Free(body);
	hub_demo_start_offset_ms = (int)floor(first_time * 1000);
	hub_demo_total_ms        = (int)floor((last_time - first_time) * 1000);
}
