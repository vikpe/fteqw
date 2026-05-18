// SPDX-License-Identifier: 0BSD

/*
 * Shared participant gathering. Single source of truth for "who is in
 * the match" across all hub_addon consumers.
 *
 * Participants_Gather() fills two file-scope buffers in one pass:
 *   Participants_Players[] - active non-spectator players from
 *                            getplayerkeyvalue, in engine slot order.
 *   Participants_Teams[]   - those players folded by team string,
 *                            with scores summed. Empty team strings
 *                            are a valid key - players with team == ""
 *                            group together under name = "".
 *
 * No partition/display rules are applied here. Empty-team handling,
 * 2-side caps, and similar policies live in each consumer (so they
 * can differ between overlay's head-to-head, player_info's full
 * listing, etc.).
 */

#define PARTICIPANT_MAX 32

// Names/teams default to the original unicode (raw quake bytes - color
// codes and special chars preserved). The _ascii companions are the
// strdecolorize'd ASCII versions; use those for sort keys and comparisons.
typedef struct {
    float  slot;          // 0-based engine player index (getplayerstat / getentity(slot+1, ...))
    string name;
    string name_ascii;
    float  score;
    vector top_color;
    vector bottom_color;
    string team;
    string team_ascii;
} participant_t;

var participant_t Participants_Players[PARTICIPANT_MAX];
float Participants_PlayerCount;

var participant_t Participants_Teams[PARTICIPANT_MAX];
float Participants_TeamCount;

// True when the match should be displayed as teamplay.
// QW: mirrors the "teamplay" serverkey.
// NQ: no teamplay serverkey exists, so we infer it from the bottom-color
//     partition - exactly 2 distinct pants colors among active players is
//     treated as teamplay (same convention the .dem parser uses for
//     "NonM" mode detection).
float Participants_IsTeamplay;

// True for any NetQuake-family protocol (vanilla NQ, Fitz666, DarkPlaces
// NQ). Stateless - safe to call without a prior Participants_Gather().
float() Participants_IsNetquake =
{
    string protocol = serverkey("protocol");
    return (strstrofs(protocol, "NetQuake", 0) == 0) || protocol == "Fitz666";
};

void() Participants_Gather =
{
    // NetQuake has no *spectator userinfo flag; spectators are signalled
    // by frags == -99 instead. NetQuake also has no team userinfo string -
    // teammates are identified by sharing the same pants (bottom) color,
    // so derive `team` from "bottomcolor" there.
    float is_netquake = Participants_IsNetquake();

    // Pass 1: active non-spectator players.
    Participants_PlayerCount = 0;
    for (int i = 0; i < maxclients && Participants_PlayerCount < PARTICIPANT_MAX; i++) {
        string name = getplayerkeyvalue(i, "name");
        if (name == "") continue;
        if (stof(getplayerkeyvalue(i, "*spectator")) > 0) continue;
        float frags = stof(getplayerkeyvalue(i, "frags"));
        if (is_netquake && frags == -99) continue;
        // NQ has no team userinfo string; team identity is the
        // pants-color palette slot. Read the engine-canonical name via
        // the "bottomcolor_name" getplayerkeyvalue key wired in
        // pr_csqc.c -> Hub_NQColorName, so this stays in sync with the
        // C-side hub_participants used by the web bindings.
        string team = is_netquake
                    ? getplayerkeyvalue(i, "bottomcolor_name")
                    : getplayerkeyvalue(i, "team");
        Participants_Players[Participants_PlayerCount].slot         = i;
        Participants_Players[Participants_PlayerCount].name         = name;
        Participants_Players[Participants_PlayerCount].name_ascii   = strdecolorize(name);
        Participants_Players[Participants_PlayerCount].score        = frags;
        Participants_Players[Participants_PlayerCount].top_color    = stov(getplayerkeyvalue(i, "topcolor_rgb"));
        Participants_Players[Participants_PlayerCount].bottom_color = stov(getplayerkeyvalue(i, "bottomcolor_rgb"));
        Participants_Players[Participants_PlayerCount].team         = team;
        Participants_Players[Participants_PlayerCount].team_ascii   = strdecolorize(team);
        Participants_PlayerCount++;
    }

    // Pass 2: fold by team string. Score summed across members; other
    // fields (colors, slot, name) come from the first member encountered.
    Participants_TeamCount = 0;
    for (int i = 0; i < Participants_PlayerCount; i++) {
        float existing = -1;
        for (int j = 0; j < Participants_TeamCount; j++) {
            if (Participants_Teams[j].name == Participants_Players[i].team) {
                existing = j;
                break;
            }
        }
        if (existing < 0) {
            if (Participants_TeamCount >= PARTICIPANT_MAX) break;
            Participants_Teams[Participants_TeamCount]            = Participants_Players[i];
            Participants_Teams[Participants_TeamCount].name       = Participants_Players[i].team;
            Participants_Teams[Participants_TeamCount].name_ascii = Participants_Players[i].team_ascii;
            Participants_TeamCount++;
        } else {
            Participants_Teams[existing].score += Participants_Players[i].score;
        }
    }

    // NQ teamplay detection: exactly 2 distinct pants-color teams AND
    // more than 2 players. A duel between two players with mismatched
    // pants colors trivially produces 2 "teams" of 1 player each, but
    // it's not a team game. The C-side hub_participants.c applies the
    // same player-count gate (see should_build_teams).
    Participants_IsTeamplay = is_netquake
                            ? (Participants_TeamCount == 2 && Participants_PlayerCount > 2)
                            : (serverkeyfloat("teamplay") > 0);
};
