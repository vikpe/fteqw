// SPDX-License-Identifier: 0BSD

// Track the next / previous participant (name order, wrapping), shared by the
// track_next / track_prev commands and the swipe gesture.

// Tracks the participant `delta` steps from the tracked one. Starts at the
// first / last participant when nothing is tracked.
void(float delta) TrackParticipantByDelta =
{
    // Single-POV demos lock the view to the recording client.
    if (serverkeyfloat("demo_is_single_pov") > 0) return;

    Participants_Gather();
    float player_count = Participants_PlayerCount;
    if (player_count < 1) return;

    float tracked_slot = -1;
    if (player_localentnum >= 1 && player_localentnum <= maxclients) {
        tracked_slot = player_localentnum - 1;
    }

    float current_index = -1;
    for (float i = 0; i < player_count; i++) {
        if (Participants_Players[i].slot == tracked_slot) {
            current_index = i;
            break;
        }
    }

    float next_index;
    if (current_index < 0) {
        next_index = delta > 0 ? 0 : player_count - 1;
    } else {
        next_index = current_index + delta;
        if (next_index < 0) next_index += player_count;
        if (next_index >= player_count) next_index -= player_count;
    }

    string userid = getplayerkeyvalue(Participants_Players[next_index].slot, "userid");
    if (userid == "") return;
    localcmd(sprintf("track_userid %s\n", userid));
};
