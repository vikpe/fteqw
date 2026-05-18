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
	int  is_bot;        // 1 if the player looks like a bot (userid == 0)
	int  top_color;     // 0..16 (palette slot)
	int  bottom_color;  // 0..16 (palette slot)
	unsigned char top_rgb[3];     // resolved RGB (0..255) for the top palette slot
	unsigned char bottom_rgb[3];  // resolved RGB (0..255) for the bottom palette slot
	char name_bytestr[HUB_PARTICIPANT_NAME_BYTES];  // raw quake-encoded bytes (^X markup + 2nd-charset bytes preserved); pass to ezhud drawfuncs->StringH for correct rendering
	char name_unicode[HUB_PARTICIPANT_NAME_BYTES];  // UTF-8 (raw bytes mapped into Latin-1 codepoints); use this for non-quake renderers (HTML titles, etc.)
	char name_ascii[HUB_PARTICIPANT_ASCII_BYTES];   // ASCII, colors stripped, special chars approximated
	char team_bytestr[HUB_PARTICIPANT_NAME_BYTES];  // grouping key; the unicode/ascii variants only matter on the per-team rollup and are decoded there
} hub_participant_player_t;

typedef struct {
	int  frag_sum;
	unsigned char top_rgb[3];
	unsigned char bottom_rgb[3];
	char team_bytestr[HUB_PARTICIPANT_NAME_BYTES];
	char team_unicode[HUB_PARTICIPANT_NAME_BYTES];
	char team_ascii[HUB_PARTICIPANT_ASCII_BYTES];
} hub_participant_team_t;

typedef struct {
	hub_participant_player_t players[HUB_PARTICIPANT_MAX];
	int                       player_count;
	hub_participant_team_t    teams[HUB_PARTICIPANT_MAX];  // empty unless the 2-team rule fires
	int                       team_count;
} hub_participants_t;

void Hub_BuildParticipants(hub_participants_t *out);

// True when the current session is a NetQuake-protocol demo. Used by
// HUD widgets that need to substitute NQ-specific signals for QW-only
// serverinfo fields (e.g. cl.teamplay, status string).
int Hub_IsNetquakeDemo(void);

// Palette index (0..13) -> color name string ("red", "blue", ...).
// Returns "" for out-of-range indices. NetQuake demos identify teams by
// the player's bottom-color palette slot rather than a team userinfo
// string; this is the canonical mapping used by both the C-side
// hub_participants builder and the QC participants.qc consumer (via
// the "bottomcolor_name" getplayerkeyvalue key wired in pr_csqc.c).
// Pointer is to static storage; do not free, do not modify.
const char *Hub_NQColorName(int palette_index);

// Convert a raw quake-encoded string (color codes, 2nd-charset bytes)
// into a unicode string serialised as UTF-8. First-charset special
// glyphs (0x00..0x1F) and their 2nd-charset gold duplicates are mapped
// to their ASCII equivalents (16/17 -> '[' / ']' etc.) so clan tags
// like "[sr]" survive into JS-side text rendering. ^X color codes and
// hidden markup are dropped.
void Hub_QuakeStringToUnicode(const char *src, char *out, int out_size);

// Convert a raw quake-encoded string into 7-bit ASCII: color codes
// stripped, special chars approximated. Suitable for sort keys.
void Hub_QuakeStringToAscii(const char *src, char *out, int out_size);

#ifdef __cplusplus
}
#endif

#endif
