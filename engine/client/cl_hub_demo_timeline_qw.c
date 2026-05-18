// SPDX-License-Identifier: 0BSD
//
// QuakeWorld-family demo scanner. Walks records reading time + cmd +
// length, scans bodies for serverinfo data when needed, otherwise
// skips them.
//   .qwd: float time + byte cmd + body
//   .mvd: byte msec + byte cmd + body   (msec is a delta)
//
// Staged scan:
//   [initial]  demtime <= 10 ms : look in each body for `\timelimit\`
//              and `\status\` (delivered in the fullserverinfo blob
//              via svc_stufftext). Captures hub_demo_timelimit_ms and
//              whether status was "Countdown".
//   [wait]     demtime > 10 ms AND status was "Countdown" : keep
//              scanning bodies for the status change. When status
//              leaves "Countdown" the current demtime is captured as
//              hub_demo_countdown_ms.
//   [skip]     after the above resolves : header-only walk to EOF for
//              the final demtime (hub_demo_total_ms).

#include "quakedef.h"
#include "cl_hub_demo_timeline.h"
#include "cl_hub_demo_timeline_internal.h"

#define QW_DEM_CMD      0
#define QW_DEM_READ     1
#define QW_DEM_SET      2
#define QW_DEM_MULTIPLE 3
#define QW_DEM_SINGLE   4
#define QW_DEM_STATS    5
#define QW_DEM_ALL      6

#define QW_SVC_SERVERINFO 52

// Find `\timelimit\<digits>` anywhere in the body. The initial
// fullserverinfo blob contains this as a backslash-delimited pair.
static void qw_scan_for_timelimit(const unsigned char *buf, int len)
{
	static const char needle[] = "\\timelimit\\";
	int               nlen = (int)sizeof(needle) - 1;

	if (hub_demo_timelimit_ms > 0) return;
	if (len < nlen + 1) return;

	for (int i = 0; i + nlen < len; i++)
	{
		if (memcmp(&buf[i], needle, nlen) != 0) continue;
		int j = i + nlen;
		int tl = 0;
		while (j < len && buf[j] >= '0' && buf[j] <= '9')
		{
			tl = tl * 10 + (buf[j] - '0');
			j++;
		}
		if (tl > 0)
			hub_demo_timelimit_ms = tl * 60 * 1000;
		return;
	}
}

// Find `\status\<value>\` in the body (fullserverinfo blob delivered
// via svc_stufftext) OR svc_serverinfo byte 52 + "status\0value\0"
// (per-key update). Either source overwrites status_out. Returns true
// on hit.
static qboolean qw_scan_for_status(const unsigned char *buf, int len,
                                   char *status_out, int status_max)
{
	static const char needle[] = "\\status\\";
	int               nlen = (int)sizeof(needle) - 1;
	qboolean          hit = false;

	if (status_max <= 1) return false;

	// Pattern A: fullserverinfo `\status\<value>` - the value ends at
	// the next backslash (further key), at the closing `"` of the
	// `fullserverinfo "..."` stufftext, or at a newline / null.
	for (int i = 0; i + nlen < len; i++)
	{
		if (memcmp(&buf[i], needle, nlen) != 0) continue;
		int j = i + nlen;
		int k = 0;
		while (j < len && k + 1 < status_max)
		{
			unsigned char c = buf[j];
			if (c == '\\' || c == '"' || c == '\n' || c == '\r' || c == 0)
				break;
			status_out[k++] = c;
			j++;
		}
		status_out[k] = 0;
		hit = true;
		break;
	}

	// Pattern B: svc_serverinfo (byte 52) + "status\0" + "<value>\0".
	for (int i = 0; i + 1 < len; i++)
	{
		if (buf[i] != QW_SVC_SERVERINFO) continue;
		int kstart = i + 1;
		int kend;
		for (kend = kstart; kend < len && buf[kend]; kend++) {}
		if (kend >= len) break;
		if (strcmp((const char *)&buf[kstart], "status") != 0)
		{
			i = kend;
			continue;
		}
		int vstart = kend + 1;
		int vend;
		for (vend = vstart; vend < len && buf[vend]; vend++) {}
		if (vend >= len) break;
		int k = 0;
		for (int j = vstart; j < vend && k + 1 < status_max; j++)
			status_out[k++] = buf[j];
		status_out[k] = 0;
		hit = true;
		break;
	}

	return hit;
}

void Hub_DemoTimeline_ScanQw(vfsfile_t *f, qboolean is_mvd)
{
	const double INITIAL_WINDOW_SECS  = 0.1;
	const double COUNTDOWN_WAIT_SECS  = 30.0;

	float    demtime            = 0;
	char     status[64]         = "";
	qboolean seen_status        = false;
	qboolean in_countdown       = false;
	qboolean countdown_resolved = false;
	// Multi-POV detection (MVD only). OR every player slot that
	// appears as a routing target in dem_single (slot = cmd >> 3),
	// dem_stats (same), or dem_multiple (bitmask of slots, except
	// the mvdhidden sentinel mask==0). After the loop, popcount > 1
	// means the demo carries data for >1 player - i.e. a real
	// multi-POV MVD, not a QWD->MVD wrap. cmd >> 3 fits in 5 bits
	// so 32 is enough.
	uint32_t pov_slots_seen = 0;
	// dem_multiple records with seqmask == 0 carry mvdhidden_* extension
	// payloads (cl_demo.c routes them through CLEZ_ParseHiddenDemoMessage):
	// ktxstats JSON, mvdhidden_dmgdone attribution, paused durations, etc.
	// Only server-side MVD recorders (mvdsv / ktx) emit these; a QWD->MVD
	// wrap can't synthesise them since the source QWD doesn't carry the
	// data. Their presence is a definitive "real MVD" signal even when
	// pov_slots_seen happens to be sparse.
	qboolean mvd_has_hidden = false;

	for (;;)
	{
		// Per-record time field.
		if (is_mvd)
		{
			unsigned char msec;
			if (VFS_READ(f, &msec, 1) != 1) break;
			demtime += msec / 1000.0f;
		}
		else
		{
			float t;
			if (VFS_READ(f, &t, sizeof(t)) != (int)sizeof(t)) break;
			demtime = LittleFloat(t);
		}

		unsigned char cmd;
		if (VFS_READ(f, &cmd, 1) != 1) break;

		int body_len = 0;
		switch (cmd & 7)
		{
		case QW_DEM_CMD:
			if (is_mvd) goto done;
			if (VFS_SEEK(f, VFS_TELL(f) + (int)sizeof(q1usercmd_t) + 12) < 0)
				goto done;
			continue;

		case QW_DEM_SET:
			if (VFS_SEEK(f, VFS_TELL(f) + 8) < 0) goto done;
			continue;

		case QW_DEM_MULTIPLE:
		{
			int seqmask, len;
			if (VFS_READ(f, &seqmask, sizeof(seqmask)) != (int)sizeof(seqmask)) goto done;
			if (VFS_READ(f, &len, sizeof(len)) != (int)sizeof(len)) goto done;
			body_len = LittleLong(len);
			if (is_mvd)
			{
				uint32_t mask = (uint32_t)LittleLong(seqmask);
				if (mask) pov_slots_seen |= mask;
				else      mvd_has_hidden = true;
			}
			break;
		}

		case QW_DEM_READ:
		case QW_DEM_ALL:
		{
			int len;
			if (VFS_READ(f, &len, sizeof(len)) != (int)sizeof(len)) goto done;
			body_len = LittleLong(len);
			break;
		}

		case QW_DEM_SINGLE:
		case QW_DEM_STATS:
		{
			int len;
			if (VFS_READ(f, &len, sizeof(len)) != (int)sizeof(len)) goto done;
			body_len = LittleLong(len);
			if (is_mvd)
				pov_slots_seen |= 1u << ((cmd >> 3) & 31);
			break;
		}

		default:
			goto done;
		}

		if (body_len < 0 || body_len > 1024 * 1024) goto done;

		// Initial-window cutoff: once demtime crosses 10 ms, if we
		// never saw a status it'll never come from this scan, so mark
		// resolved and drop straight to the header-only walk.
		if (!seen_status && demtime > INITIAL_WINDOW_SECS)
			countdown_resolved = true;

		// Countdown-wait cutoff: if we entered countdown but no
		// transition shows up within 30 s of demtime, give up on
		// exact detection (the transition likely isn't in this demo,
		// e.g. converted from QWD with the status update stripped).
		if (in_countdown && !countdown_resolved && demtime > COUNTDOWN_WAIT_SECS)
			countdown_resolved = true;

		// Decide whether this body needs inspection.
		qboolean inspect = false;
		if (hub_demo_timelimit_ms == 0) inspect = true;
		if (!seen_status)               inspect = true;
		if (in_countdown && !countdown_resolved) inspect = true;

		if (!inspect)
		{
			if (VFS_SEEK(f, VFS_TELL(f) + body_len) < 0) goto done;
			continue;
		}

		unsigned char buf[2048];
		int want = body_len < (int)sizeof(buf) ? body_len : (int)sizeof(buf);
		if (VFS_READ(f, buf, want) != want) goto done;

		qw_scan_for_timelimit(buf, want);

		if (qw_scan_for_status(buf, want, status, sizeof(status)))
		{
			if (!seen_status)
			{
				seen_status = true;
				if (!stricmp(status, "Countdown"))
					in_countdown = true;
				else
					countdown_resolved = true;
			}
			else if (in_countdown && stricmp(status, "Countdown"))
			{
				hub_demo_countdown_ms = (int)floor(demtime * 1000);
				countdown_resolved    = true;
			}
		}

		if (want < body_len && VFS_SEEK(f, VFS_TELL(f) + (body_len - want)) < 0)
			goto done;
	}

done:
	hub_demo_total_ms = (int)floor(demtime * 1000);

	if (is_mvd)
	{
		// Resolution priority:
		//   1. mvd_has_hidden  -> real MVD recording. Leave -1.
		//   2. popcount > 1    -> per-slot routing for several clients
		//                         (e.g. an older real MVD without hidden
		//                         messages). Leave -1.
		//   3. popcount == 1   -> QWD->MVD wrap whose wrapper put the
		//                         recording client's data in dem_single.
		//                         Take that bit as the slot.
		//   4. popcount == 0   -> QWD->MVD wrap whose wrapper sent
		//                         everything as dem_all. The scan can't
		//                         pinpoint the slot, so use the
		//                         POV_SLOT_FROM_PLAYERVIEW sentinel and
		//                         let Hub_GetDemoPovUserId fall back to
		//                         playerview[0].playernum at query time.
		// Slot 31 (0x80000000) is treated as the top of the QW slot
		// range in protocol (MAX_CLIENTS == 32), but vanishingly rare
		// in practice - real servers run with maxclients well below 32,
		// so a real player in slot 31 is the exception. QWD->MVD wrap
		// tools have been observed using bit 31 in dem_multiple seqmasks
		// as a "from the recording client" sentinel rather than a real
		// routing target. Strip it before counting so wraps that use
		// this convention don't get flagged as multi-POV; the masked
		// vs unmasked values are both reported in the debug line so
		// genuine slot-31 demos can be spotted.
		uint32_t slot_mask = pov_slots_seen & ~0x80000000u;
		int  bits           = 0;
		int  first_bit_slot = 0;
		for (int b = 0; b < 31; b++) {
			if (slot_mask & (1u << b)) {
				if (bits == 0) first_bit_slot = b;
				bits++;
			}
		}
		const char *reason;
		if (mvd_has_hidden || bits > 1)
		{
			hub_demo_pov_slot = -1;
			reason = mvd_has_hidden
			       ? "multi-POV (mvdhidden_* messages present)"
			       : "multi-POV (per-slot routing for >1 client)";
		}
		else if (bits == 1)
		{
			hub_demo_pov_slot = first_bit_slot;
			reason = "single-POV (one dem_single/dem_multiple slot)";
		}
		else
		{
			hub_demo_pov_slot = HUB_DEMO_POV_SLOT_FROM_PLAYERVIEW;
			reason = "single-POV (no per-slot routing, no mvdhidden; "
			         "slot deferred to playerview)";
		}
		Con_Printf("[demo-timeline] mvd pov-detect: pov_slots_seen=0x%08x "
		           "(after masking off bit 31 = 0x%08x) bits=%d "
		           "mvd_has_hidden=%d -> hub_demo_pov_slot=%d  // %s\n",
		           (unsigned int)pov_slots_seen, (unsigned int)slot_mask,
		           bits, mvd_has_hidden ? 1 : 0,
		           hub_demo_pov_slot, reason);
	}

	if (status[0])
		Con_Printf("[demo-timeline] initial status=\"%s\"%s\n",
		           status,
		           in_countdown && !hub_demo_countdown_ms ? " (no transition observed)" : "");
	else
		Con_Printf("[demo-timeline] no status observed in first %.0fms of demtime\n",
		           INITIAL_WINDOW_SECS * 1000);
}
