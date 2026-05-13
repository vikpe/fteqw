// SPDX-License-Identifier: 0BSD
//
// NetQuake demo (.dem) scanner. Format:
//   header line: `<cdtrack>\n`
//   records:     int msglength + 12 bytes viewangles + msglength body
// NQ has no serverinfo / countdown concept, so we only capture the
// total demo duration by tracking the last svc_time value seen.

#include "quakedef.h"
#include "cl_hub_demo_timeline.h"
#include "cl_hub_demo_timeline_internal.h"

#define NQ_SVC_TIME 7

void Hub_DemoTimeline_ScanNq(vfsfile_t *f)
{
	float last_time = 0;
	char  c = 0;

	// Skip CD-track header line.
	while (VFS_READ(f, &c, 1) == 1 && c != '\n')
		;
	if (c != '\n')
		goto done;

	for (;;)
	{
		int msglength;
		if (VFS_READ(f, &msglength, sizeof(msglength)) != (int)sizeof(msglength))
			break;
		msglength = LittleLong(msglength);
		if (msglength == -1) // explicit EOF marker (Q2-style; tolerated here)
			break;
		if (msglength < 0 || msglength > 1024 * 1024)
			break;

		// Skip viewangles (3 floats).
		if (VFS_SEEK(f, VFS_TELL(f) + 12) < 0)
			break;

		// Server packets typically start with svc_time. Peek the first
		// byte; if it's svc_time, capture the timestamp. Otherwise just
		// skip the body.
		if (msglength >= 1)
		{
			unsigned char first;
			if (VFS_READ(f, &first, 1) != 1)
				break;
			msglength -= 1;

			if (first == NQ_SVC_TIME && msglength >= 4)
			{
				float t;
				if (VFS_READ(f, &t, sizeof(t)) != (int)sizeof(t))
					break;
				last_time = LittleFloat(t);
				msglength -= 4;
			}
		}

		if (msglength > 0 && VFS_SEEK(f, VFS_TELL(f) + msglength) < 0)
			break;
	}

done:
	hub_demo_total_ms = (int)floor(last_time * 1000);
}
