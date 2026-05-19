// SPDX-License-Identifier: 0BSD
//
// Parser for the ktxstats JSON payload embedded in KTX MVD demos.
// KTX writes the end-of-match scoreboard JSON across one or more
// mvdhidden_demoinfo (0x0003) frames; this module reassembles the
// chunks into a single string accessible via hub_ktxstats_json.
//
// Two entry points:
//   - Hub_KtxStats_OnDemoInfo : called from cl_parse.c on every
//     mvdhidden_demoinfo body during normal demo playback. Reads
//     directly from MSG_*; accumulates chunks and publishes the
//     final string when the trailing 'more' flag clears.
//   - Hub_KtxStats_Scan       : standalone fast-path file walker.
//     Seeks past every non-hidden frame, parses only
//     mvdhidden_demoinfo bodies. Lets a caller obtain the JSON
//     without running the full playback state machine.
//
// Independent of the per-event extraction subsystem - the JSON is
// the end-of-match scoreboard, not the per-event stream.

#ifndef CL_HUB_KTXSTATS_H
#define CL_HUB_KTXSTATS_H

#ifdef __cplusplus
extern "C" {
#endif

// Final reassembled JSON, or NULL until a complete payload has
// landed. Owned by this module; do not free.
extern char *hub_ktxstats_json;

// Reset the accumulator length and free hub_ktxstats_json so a
// freshly-loaded demo without stats reports correctly. Called from
// Hub_KtxStats_Scan before its file walk; safe to call any time.
void Hub_KtxStats_Reset(void);

// Called from cl_parse.c's mvdhidden_demoinfo branch
// (CLEZ_ParseHiddenDemoMessage). Reads `payload_len` bytes directly
// from the in-progress demo message and either appends them to the
// accumulator (when capturing) or skips them so the parser stays
// aligned. `is_more` nonzero means another chunk follows; zero
// finalises the JSON and publishes hub_ktxstats_json. Capture is
// gated externally (currently by the event subsystem's recording
// flag) so normal playback does not accumulate.
void Hub_KtxStats_OnDemoInfo(int payload_len, unsigned int is_more);

// Standalone scanner: walks the current MVD demo file directly,
// seeking past anything that isn't a hidden-message frame, and
// parses only mvdhidden_demoinfo bodies. Returns 0 on success or
// when the result is cached, -1 if the demo isn't scannable (not
// playing a demo, not MVD, not seekable, no demo file). Early-
// exits the moment the final ktxstats chunk lands.
int Hub_KtxStats_Scan(void);

#ifdef __cplusplus
}
#endif

#endif
