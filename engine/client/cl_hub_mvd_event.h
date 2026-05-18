// SPDX-License-Identifier: 0BSD
//
// MVD-specific demo event hooks. These fire from cl_parse.c when parsing
// MVD binary hidden messages (mvdhidden_dmgdone, mvdhidden_demoinfo) that
// don't exist on QWD or NQ wires. Bodies forward into cl_hub_demo_event
// helpers for actual state mutation.

#ifndef CL_HUB_MVD_EVENT_H
#define CL_HUB_MVD_EVENT_H

#ifdef __cplusplus
extern "C" {
#endif

// Called from the mvdhidden_dmgdone parser in cl_parse.c. Stores the
// (attacker, time) pair per-victim so the next STAT_HEALTH -> 0
// transition can attribute the kill. attacker_slot may equal targ_slot
// for self damage; either may be -1 / out of range (caller passes 1-based
// entnums minus 1, world damage = no dmgdone so this isn't called).
// No-op when not recording.
void Hub_MvdEvent_OnDamage(int attacker_slot, int targ_slot,
                           unsigned int dmg_type);

// Called from CLEZ_ParseHiddenDemoMessage's mvdhidden_demoinfo branch.
// Reads the message body itself - either appends `payload_len` bytes
// to the captured ktxstats buffer (when scanning) or skips them (any
// other time). `is_more` is the 'more' field from the wire: nonzero
// means another mvdhidden_demoinfo will follow with the next chunk
// of the same payload, zero means this completes the JSON and
// hub_ktxstats_json becomes available.
void Hub_MvdEvent_OnDemoInfo(int payload_len, unsigned int is_more);

// Lightweight standalone scanner: walks the demo file directly (no
// playback state machine, no CL_GetDemoMessage) and only parses
// mvdhidden_demoinfo frames so hub_ktxstats_json can be populated
// without the full event scan's ~1s cost. Early-exits once the final
// ktxstats chunk is observed. Returns 0 on success (or when cached /
// no stats present), -1 if the demo isn't scannable. No-op when the
// full events scan has already captured stats for this demo. MVD-only:
// reads the MVD frame layout and mvdhidden_* messages which don't
// exist on other demo formats.
int Hub_MvdEvent_StatsScan(void);

#ifdef __cplusplus
}
#endif

#endif
