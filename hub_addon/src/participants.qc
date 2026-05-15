// SPDX-License-Identifier: 0BSD

/*
 * Shared participant gathering.
 *
 * Active players are pulled from getplayerkeyvalue; team grouping is
 * built on top. Two file-scope buffers expose the result so multiple
 * consumers in the same frame can read without re-gathering.
 *
 * Partition/display policy stays in each caller (e.g. score_overlay's
 * "empty team disqualifies the head-to-head partition" rule). Empty
 * team strings are treated as a valid team key here - players with
 * team == "" group together under name = "".
 */

#define PARTICIPANT_MAX 32

typedef struct {
    float  slot;          // 0-based engine player index (getplayerstat / getentity(slot+1, ...))
    string name;
    float  score;
    vector top_color;
    vector bottom_color;
    string team;
} participant_t;

// Active non-spectator players, in the order returned by the engine.
var participant_t Participants_Players[PARTICIPANT_MAX];
float Participants_PlayerCount;

// Players folded by team string. Score is summed across members; other
// fields come from the first member encountered. .team mirrors .name.
var participant_t Participants_Teams[PARTICIPANT_MAX];
float Participants_TeamCount;

// Forward declarations so the file reads top-down.
void() Participants_GatherPlayers;
void() Participants_GatherTeams;

void() Participants_GatherPlayers =
{
    Participants_PlayerCount = 0;
    for (int i = 0; i < maxclients && Participants_PlayerCount < PARTICIPANT_MAX; i++) {
        string name = getplayerkeyvalue(i, "name");
        if (name == "") continue;
        if (stof(getplayerkeyvalue(i, "*spectator")) > 0) continue;
        Participants_Players[Participants_PlayerCount].slot         = i;
        Participants_Players[Participants_PlayerCount].name         = name;
        Participants_Players[Participants_PlayerCount].score        = stof(getplayerkeyvalue(i, "frags"));
        Participants_Players[Participants_PlayerCount].top_color    = stov(getplayerkeyvalue(i, "topcolor_rgb"));
        Participants_Players[Participants_PlayerCount].bottom_color = stov(getplayerkeyvalue(i, "bottomcolor_rgb"));
        Participants_Players[Participants_PlayerCount].team         = getplayerkeyvalue(i, "team");
        Participants_PlayerCount++;
    }
};

// Folds Participants_Players[] by team string. Call Participants_GatherPlayers
// first. Safe to call when player count is 0 (produces zero teams).
void() Participants_GatherTeams =
{
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
            Participants_Teams[Participants_TeamCount]      = Participants_Players[i];
            Participants_Teams[Participants_TeamCount].name = Participants_Players[i].team;
            Participants_TeamCount++;
        } else {
            Participants_Teams[existing].score += Participants_Players[i].score;
        }
    }
};
