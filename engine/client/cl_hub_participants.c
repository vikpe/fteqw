// SPDX-License-Identifier: 0BSD

#include "quakedef.h"
#include "cl_hub_participants.h"
#include "sbar.h"

// Forward declarations so the file reads top-down.
static void gather_players(hub_participants_t *out);
static int  should_build_teams(const hub_participants_t *p);
static void compute_team_groups(hub_participants_t *p);
static void encode_conchar_to_unicode(conchar_t *src, char *out, int outsize);
static int  hub_is_netquake_demo(void);
static int  compare_player_by_name_ascii(const void *a, const void *b);
static int  compare_team_by_team_ascii(const void *a, const void *b);

// ----- entry point ----------------------------------------------------------

void Hub_BuildParticipants(hub_participants_t *out)
{
	out->player_count = 0;
	out->team_count   = 0;
	if (cls.state == ca_disconnected)
		return;

	gather_players(out);
	if (should_build_teams(out))
		compute_team_groups(out);
}

// ----- gather + grouping ----------------------------------------------------

// Walks cl.players, applies the spectator + dem-playback-ghost filter,
// decodes name/team into the output, and sorts by name_ascii.
static void gather_players(hub_participants_t *out)
{
	int is_netquake_demo = hub_is_netquake_demo();
	int i;
	out->player_count = 0;
	for (i = 0; i < cl.allocated_client_slots && out->player_count < HUB_PARTICIPANT_MAX; i++) {
		player_info_t *p = &cl.players[i];
		if (!p->name[0] || p->spectator)
			continue;
		if (is_netquake_demo && p->frags < 1 && p->rbottomcolor == 0 && p->rtopcolor == 0)
			continue;

		hub_participant_player_t *e = &out->players[out->player_count];
		e->userid = p->userid;
		e->frags  = p->frags;
		// Bots conventionally appear with userid 0 (cl_cam.c relies on
		// the same heuristic).
		e->is_bot = (p->userid == 0) ? 1 : 0;

		Q_strncpyz(e->name_bytestr, p->name, sizeof(e->name_bytestr));
		Q_strncpyz(e->team_bytestr, p->team, sizeof(e->team_bytestr));
		Hub_QuakeStringToUnicode(p->name, e->name_unicode, sizeof(e->name_unicode));
		Hub_QuakeStringToAscii(p->name, e->name_ascii, sizeof(e->name_ascii));

		int top = p->rtopcolor;
		int bot = p->rbottomcolor;
		if (top < 0) top = 0;
		if (top > 16) top = 16;
		if (bot < 0) bot = 0;
		if (bot > 16) bot = 16;
		e->top_color    = top;
		e->bottom_color = bot;

		// Resolve the player's shirt/pants palette slot to an RGB triplet
		// (same path as csqc's getplayerkeyvalue "topcolor_rgb"). Used by
		// downstream UI to draw colored swatches without reaching into the
		// engine palette themselves.
		unsigned int idx_top = Sbar_ColorForMap((unsigned int)top);
		unsigned int idx_bot = Sbar_ColorForMap((unsigned int)bot);
		if (idx_top < 256) {
			e->top_rgb[0] = host_basepal[idx_top*3+0];
			e->top_rgb[1] = host_basepal[idx_top*3+1];
			e->top_rgb[2] = host_basepal[idx_top*3+2];
		}
		if (idx_bot < 256) {
			e->bottom_rgb[0] = host_basepal[idx_bot*3+0];
			e->bottom_rgb[1] = host_basepal[idx_bot*3+1];
			e->bottom_rgb[2] = host_basepal[idx_bot*3+2];
		}

		out->player_count++;
	}
	qsort(out->players, out->player_count, sizeof(out->players[0]), compare_player_by_name_ascii);
}

// 2-team detection: >2 active players AND exactly 2 distinct teams.
// NetQuake demos key on bottom_color (the team userinfo field isn't
// broadcast); other protocols key on the raw team string.
static int should_build_teams(const hub_participants_t *p)
{
	int i;
	if (p->player_count <= 2)
		return 0;
	if (hub_is_netquake_demo()) {
		int seen[17] = {0};
		int distinct_count = 0;
		for (i = 0; i < p->player_count; i++) {
			int bot = p->players[i].bottom_color;
			if (bot < 0 || bot > 16)
				continue;
			if (!seen[bot]) {
				seen[bot] = 1;
				distinct_count++;
			}
		}
		return distinct_count == 2;
	} else {
		int distinct_count = 0;
		int j;
		for (i = 0; i < p->player_count; i++) {
			int is_first = 1;
			for (j = 0; j < i; j++) {
				if (!strcmp(p->players[i].team_bytestr, p->players[j].team_bytestr)) {
					is_first = 0;
					break;
				}
			}
			if (is_first) {
				distinct_count++;
				if (distinct_count > 2)
					return 0;
			}
		}
		return distinct_count == 2;
	}
}

// Groups players by team string, sums frags, sorts by team_ascii.
static void compute_team_groups(hub_participants_t *p)
{
	int i, k;
	p->team_count = 0;
	for (i = 0; i < p->player_count; i++) {
		const hub_participant_player_t *player = &p->players[i];
		int existing = -1;
		for (k = 0; k < p->team_count; k++) {
			if (!strcmp(p->teams[k].team_bytestr, player->team_bytestr)) {
				existing = k;
				break;
			}
		}
		if (existing < 0) {
			if (p->team_count >= HUB_PARTICIPANT_MAX)
				break;
			hub_participant_team_t *g = &p->teams[p->team_count];
			g->frag_sum = player->frags;
			g->top_rgb[0]    = player->top_rgb[0];
			g->top_rgb[1]    = player->top_rgb[1];
			g->top_rgb[2]    = player->top_rgb[2];
			g->bottom_rgb[0] = player->bottom_rgb[0];
			g->bottom_rgb[1] = player->bottom_rgb[1];
			g->bottom_rgb[2] = player->bottom_rgb[2];
			Q_strncpyz(g->team_bytestr, player->team_bytestr, sizeof(g->team_bytestr));
			Hub_QuakeStringToUnicode(player->team_bytestr,
			                      g->team_unicode, sizeof(g->team_unicode));
			Hub_QuakeStringToAscii(player->team_bytestr,
			                       g->team_ascii, sizeof(g->team_ascii));
			p->team_count++;
		} else {
			p->teams[existing].frag_sum += player->frags;
		}
	}
	qsort(p->teams, p->team_count, sizeof(p->teams[0]), compare_team_by_team_ascii);
}

// ----- decode / introspection -----------------------------------------------

void Hub_QuakeStringToUnicode(const char *src, char *out, int out_size)
{
	conchar_t buf[HUB_PARTICIPANT_NAME_BYTES];
	COM_ParseFunString(CON_WHITEMASK, src, buf, sizeof(buf), qfalse);
	encode_conchar_to_unicode(buf, out, out_size);
}

void Hub_QuakeStringToAscii(const char *src, char *out, int out_size)
{
	conchar_t buf[HUB_PARTICIPANT_NAME_BYTES];
	COM_ParseFunString(CON_WHITEMASK, src, buf, sizeof(buf), qfalse);
	COM_DeFunString(buf, NULL, out, out_size, qtrue, qfalse);
}

// Walks a conchar buffer, drops hidden/markup chars, and emits each
// codepoint as UTF-8. Quake-specific glyphs (gold brackets/digits,
// dashes, dots from the special-graphics range) are routed through
// COM_DeQuake by packing the byte back into the Quake private-use
// area first; that's the same engine helper SV_MVD and the log writer
// use, so player tags like "[sr]" come out as the real ASCII brackets
// instead of C0/C1 control codepoints that JS renders as "undefined".
static void encode_conchar_to_unicode(conchar_t *src, char *out, int outsize)
{
	if (outsize <= 0)
		return;
	char *p = out;
	int   remaining = outsize - 1;
	unsigned int codeflags, codepoint;
	while (*src && remaining > 0) {
		src = Font_Decode(src, &codeflags, &codepoint);
		if (codeflags & CON_HIDDEN)
			continue;
		// Normalise to the raw Quake byte representation:
		//   - Bare 0..0x7F with the CON_2NDCHARSETTEXT flag becomes
		//     0x80..0xFF (the 2nd-charset slot in the JS lookup).
		//   - PUA-form codepoints (0xE000..0xE0FF) drop the prefix.
		// Keeping the raw byte (rather than running it through
		// COM_DeQuake) preserves the slot that the JS BYTE_COLORS
		// table reads as "gold" for special-graphics chars
		// (0x10..0x1B / 0x90..0x9B) and "brown" for high-bit text,
		// while CHAR_TABLE still maps 0x10/0x90 to '[', 0x11/0x91 to
		// ']', and so on. Real unicode codepoints (>= 0x100, outside
		// the PUA) fall through unchanged.
		if (codepoint < 0x80) {
			if (codeflags & CON_2NDCHARSETTEXT)
				codepoint |= 0x80;
		} else if (codepoint >= 0xe000 && codepoint < 0xe100) {
			codepoint &= 0xff;
		}
		unsigned int wrote = utf8_encode(p, codepoint, remaining);
		if (!wrote)
			break;
		p += wrote;
		remaining -= wrote;
	}
	*p = '\0';
}

static int hub_is_netquake_demo(void)
{
	char *m = Cmd_GetMacroValue("demoplayback");
	return (m && !strcmp(m, "demplayback")) ? 1 : 0;
}

// ----- qsort comparators ----------------------------------------------------

static int compare_player_by_name_ascii(const void *a, const void *b)
{
	const hub_participant_player_t *pa = (const hub_participant_player_t *)a;
	const hub_participant_player_t *pb = (const hub_participant_player_t *)b;
	return strcasecmp(pa->name_ascii, pb->name_ascii);
}

static int compare_team_by_team_ascii(const void *a, const void *b)
{
	const hub_participant_team_t *ta = (const hub_participant_team_t *)a;
	const hub_participant_team_t *tb = (const hub_participant_team_t *)b;
	return strcasecmp(ta->team_ascii, tb->team_ascii);
}
