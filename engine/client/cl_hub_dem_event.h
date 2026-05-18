// SPDX-License-Identifier: 0BSD
//
// NetQuake .dem-specific demo event hooks. The .dem wire format lacks the
// MVD-only damage-attribution stream (mvdhidden_dmgdone), so the only
// reliable kill signal is the svc_updatefrags delta. We emit a
// HDE_KIND_FRAG event with one side filled in and the other set to -1
// ("unknown") per the design rule - no positional / timing guesses for
// the missing side.

#ifndef CL_HUB_DEM_EVENT_H
#define CL_HUB_DEM_EVENT_H

#ifdef __cplusplus
extern "C" {
#endif

// Called from the NQ svc_updatefrags handler in cl_parse.c. `slot` is the
// player whose frag count changed; old_frags / new_frags are the prior
// and new server-broadcast frag values. Positive delta -> emit HDE_KIND_FRAG
// with killer_user_id = this slot's userid and victim_user_id = -1.
// Negative delta -> emit with victim_user_id = this slot's userid and
// killer_user_id = -1 (typically a suicide / lost frag). Zero delta is
// a no-op. No-op when not recording or outside the match.
void Hub_DemEvent_OnFragUpdate(int slot, int old_frags, int new_frags);

#ifdef __cplusplus
}
#endif

#endif
