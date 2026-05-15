// SPDX-License-Identifier: 0BSD
//
// Hub addon: participant model.
//
// Single source of truth for "who is in the match", built from cl.players
// with the spectator + dem-playback-ghost filter, name/team decoded to
// UTF-8 (original) + ASCII (stripped) flavors, and an optional team-fold
// when the 2-team detection rule fires (>2 active players AND exactly
// 2 distinct teams; team key is bottom_color on NetQuake demos, raw team
// string otherwise).
//
// Consumers (currently bindings.cpp's getTitle) call Hub_BuildParticipants
// with a stack-allocated hub_participants_t and read the resulting arrays.

#ifndef CL_HUB_PARTICIPANTS_H
#define CL_HUB_PARTICIPANTS_H

#ifdef __cplusplus
extern "C" {
#endif

#define HUB_PARTICIPANT_MAX        32
#define HUB_PARTICIPANT_NAME_BYTES 256
#define HUB_PARTICIPANT_ASCII_BYTES 64

typedef struct {
	int  userid;
	int  frags;
	int  top_color;     // 0..16
	int  bottom_color;  // 0..16
	char name[HUB_PARTICIPANT_NAME_BYTES];        // original UTF-8 (^X codes + special chars preserved)
	char name_ascii[HUB_PARTICIPANT_ASCII_BYTES]; // ASCII, colors stripped, special chars approximated
	char team[HUB_PARTICIPANT_NAME_BYTES];
	char team_ascii[HUB_PARTICIPANT_ASCII_BYTES];
} hub_participant_player_t;

typedef struct {
	int  frag_sum;
	char team[HUB_PARTICIPANT_NAME_BYTES];
	char team_ascii[HUB_PARTICIPANT_ASCII_BYTES];
} hub_participant_team_t;

typedef struct {
	hub_participant_player_t players[HUB_PARTICIPANT_MAX];
	int                       player_count;
	hub_participant_team_t    teams[HUB_PARTICIPANT_MAX];  // empty unless the 2-team rule fires
	int                       team_count;
} hub_participants_t;

void Hub_BuildParticipants(hub_participants_t *out);

#ifdef __cplusplus
}
#endif

#endif
