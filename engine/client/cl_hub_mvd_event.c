// SPDX-License-Identifier: 0BSD

#include "quakedef.h"
#include "cl_hub_demo_event.h"
#include "cl_hub_demo_event_internal.h"
#include "cl_hub_mvd_event.h"

// Cache key for the lightweight stats scan. A full events scan writes
// to last_scanned_demo in cl_hub_demo_event.c and also captures stats
// (via Hub_MvdEvent_OnDemoInfo during playback), so the full-scan cache
// shadows this one. A prior stats-only scan writes only here, leaving
// the full-scan cache empty so a later full scan still runs.
static char last_scanned_demo_stats[MAX_OSPATH] = "";

void Hub_MvdEvent_OnDamage(int attacker_slot, int targ_slot,
                           unsigned int dmg_type)
{
	Hub_DemoEventInternal_StashDamage(attacker_slot, targ_slot, dmg_type);
}

void Hub_MvdEvent_OnDemoInfo(int payload_len, unsigned int is_more)
{
	// Outside a scan: just consume the bytes so the parser stays
	// aligned. We don't keep the json across normal playback.
	if (!Hub_DemoEvent_IsRecording() || payload_len <= 0)
	{
		if (payload_len > 0) MSG_ReadSkip(payload_len);
		return;
	}

	// Copy the chunk out of the wire buffer and into the shared
	// accumulator. Final chunk publication happens inside the helper.
	void *tmp = Z_Malloc(payload_len);
	MSG_ReadData(tmp, payload_len);
	Hub_DemoEventInternal_AppendKtxStats(tmp, payload_len, is_more,
	                                     "demo-events");
	Z_Free(tmp);
}

// Standalone stats scanner. Walks the demo file directly, skipping the
// body of every non-hidden frame with VFS_SEEK and only parsing
// mvdhidden_demoinfo blocks within hidden-message frames. Early-exits
// the moment the final ktxstats chunk lands, so demos that emit stats
// near the end still pay the seek cost but demos that emit them
// mid-match return almost immediately.
//
// Frame layout (MVD, post-header):
//   1 byte  msec delta
//   1 byte  cmd (low 3 bits = dem_*)
//   if dem_multiple: 4 bytes  to-mask  (0 = hidden message)
//   for dem_read/single/stats/all/multiple: 4 bytes  body length
//   N bytes body
//   (dem_cmd / dem_set are fixed-size and never hidden.)
//
// Hidden body layout (CLEZ_ParseHiddenDemoMessage):
//   4 bytes  size (-1 sentinel for "end of hidden block")
//   2 bytes  cmd UInt16
//   `size` bytes  payload (for 0x0003 demoinfo: 2 bytes is_more + chunk)
int Hub_MvdEvent_StatsScan(void)
{
	if (!cls.demoplayback)                              return -1;
	if (cls.demoplayback != DPB_MVD)                    return -1;
	if (!*cls.lastdemoname)                             return -1;
	if (!cls.demoinfile)                                return -1;
	if (cls.demoinfile->seekstyle == SS_UNSEEKABLE)     return -1;

	// Cache hit on either path covers stats - a prior full scan already
	// captured ktxstats via the playback hook; a prior stats-only scan
	// is the obvious case.
	if (hub_ktxstats_json && last_scanned_demo_stats[0]
	    && !strcmp(last_scanned_demo_stats, cls.lastdemoname))
		return 0;

	double     t_start    = Sys_DoubleTime();
	vfsfile_t *f          = cls.demoinfile;
	qofs_t     saved_pos  = VFS_TELL(f);
	int        body_cap   = 64 * 1024;
	unsigned char *body   = Z_Malloc(body_cap);
	qboolean   done       = false;

	VFS_SEEK(f, 0);

	// Clear any prior ktxstats from playback so a freshly-loaded demo
	// without stats reports correctly (NULL hub_ktxstats_json).
	Hub_DemoEventInternal_ResetKtxStatsBuf();

	while (!done)
	{
		unsigned char hdr[2];
		if (VFS_READ(f, hdr, 2) != 2) break;
		unsigned char cmd = hdr[1];

		int      body_len  = 0;
		qboolean is_hidden = false;

		switch (cmd & 7)
		{
		case dem_multiple:
		{
			int seqmask, len;
			if (VFS_READ(f, &seqmask, 4) != 4) { done = true; break; }
			if (VFS_READ(f, &len, 4)     != 4) { done = true; break; }
			body_len  = LittleLong(len);
			is_hidden = (LittleLong(seqmask) == 0);
			break;
		}
		case dem_read:
		case dem_single:
		case dem_stats:
		case dem_all:
		{
			int len;
			if (VFS_READ(f, &len, 4) != 4) { done = true; break; }
			body_len = LittleLong(len);
			break;
		}
		case dem_set:
			if (VFS_SEEK(f, VFS_TELL(f) + 8) < 0) done = true;
			continue;
		case dem_cmd:
			// MVDs don't normally contain dem_cmd records; defend
			// against a malformed/non-standard demo by skipping the
			// fixed-size body (q1usercmd_t + 3 angles).
			if (VFS_SEEK(f, VFS_TELL(f) + (int)sizeof(q1usercmd_t) + 12) < 0)
				done = true;
			continue;
		default:
			done = true;
			break;
		}
		if (done) break;

		if (body_len < 0 || body_len > 4 * 1024 * 1024) break;

		if (!is_hidden)
		{
			if (VFS_SEEK(f, VFS_TELL(f) + body_len) < 0) break;
			continue;
		}

		if (body_len > body_cap)
		{
			while (body_cap < body_len) body_cap *= 2;
			body = BZ_Realloc(body, body_cap);
		}
		if (VFS_READ(f, body, body_len) != body_len) break;

		// Walk the hidden-message stream inside the body looking for
		// mvdhidden_demoinfo (cmd 0x0003). Other hidden cmds (dmgdone
		// etc.) are ignored entirely on this fast path.
		int pos = 0;
		while (pos + 6 <= body_len)
		{
			int size; memcpy(&size, body + pos, 4);
			size = LittleLong(size);
			pos += 4;
			if (size == -1) break;  // end-of-hidden-block sentinel
			if (size < 0 || pos + 2 > body_len) { done = true; break; }
			unsigned short cmd_id;
			memcpy(&cmd_id, body + pos, 2);
			cmd_id = LittleShort(cmd_id);
			pos += 2;
			if (pos + size > body_len) { done = true; break; }

			if (cmd_id == 0x0003 /* mvdhidden_demoinfo */ && size >= 2)
			{
				unsigned short is_more;
				memcpy(&is_more, body + pos, 2);
				is_more = LittleShort(is_more);
				int payload_len = size - 2;
				if (payload_len > 0)
				{
					Hub_DemoEventInternal_AppendKtxStats(
					    body + pos + 2, payload_len, is_more,
					    "demo-stats");
					if (!is_more)
					{
						done = true;
						break;
					}
				}
			}
			pos += size;
		}
	}

	VFS_SEEK(f, saved_pos);
	Z_Free(body);

	Q_strncpyz(last_scanned_demo_stats, cls.lastdemoname,
	           sizeof(last_scanned_demo_stats));

	double scan_ms = (Sys_DoubleTime() - t_start) * 1000.0;
	Con_Printf("[demo-stats] scan in %.0f ms (ktxstats: %s)\n",
	           scan_ms, hub_ktxstats_json ? "found" : "not found");
	return 0;
}
