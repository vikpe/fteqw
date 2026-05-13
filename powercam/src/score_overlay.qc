// SPDX-License-Identifier: 0BSD

/*
 * Score overlay drawn centered at the top of the player camera view.
 *
 * Shown only when:
 *   - deathmatch != 0 (skip coop)
 *   - exactly 2 active non-spectator players, OR
 *   - exactly 2 distinct teams across the active non-spectator players
 *
 * Layout (left to right): name1 | score1 | score2 | name2
 *   - 4px gap between every item
 *   - scores sit on a vertically-split rectangle (top half = topcolor,
 *     bottom half = bottomcolor) belonging to that participant
 *   - name1 ends at score1 (right-aligned to score1)
 *   - name2 begins after score2 (left-aligned to score2)
 *   - names are drawn verbatim, no char filtering
 */

#define SO_MAX_PARTICIPANTS 32

// Layout reference height in pixels. All sizes scale with main_size.y / this.
#define SO_REF_HEIGHT 720

// Scale clamps - tiny windows stay legible, huge ones don't get cartoonish.
#define SO_SCALE_MIN 0.6
#define SO_SCALE_MAX 2.0

// Pixel sizes at scale = 1.
#define SO_FONT_PX        12
#define SO_PAD_X_PX       6
#define SO_PAD_Y_PX       4
#define SO_GAP_PX         4
#define SO_MARGIN_PX      16
#define SO_CORNER_PX      1
#define SO_CLOCK_FONT_PX  12
#define SO_CLOCK_GAP_PX   4
#define SO_CLOCK_DESC_PX  2

// Filled rounded rect via R_BeginPolygon (one convex poly, triangle-fan
// tessellated by the engine). `corners` is a bitmask of which corners to
// round: 1=TL, 2=TR, 4=BR, 8=BL.
#define SO_RR_TL 1
#define SO_RR_TR 2
#define SO_RR_BR 4
#define SO_RR_BL 8
#define SO_RR_TOP    (SO_RR_TL | SO_RR_TR)
#define SO_RR_BOTTOM (SO_RR_BR | SO_RR_BL)

// Layout metrics scaled to the current viewport. Reused by both the
// reserved-height calculation and the draw pass.
typedef struct {
    float scale;
    float font_size;
    vector font;
    float pad_x;
    float pad_y;
    float gap;
    float margin;
    float box_height;
    float corner_radius;
    vector clock_font;
    float clock_gap;
} so_layout_t;

void(vector main_size, __out so_layout_t L) SO_LayoutFor =
{
    float scale = main_size.y / SO_REF_HEIGHT;
    if (scale < SO_SCALE_MIN) scale = SO_SCALE_MIN;
    if (scale > SO_SCALE_MAX) scale = SO_SCALE_MAX;
    float font_size = floor(SO_FONT_PX * scale);
    float pad_y     = ceil(SO_PAD_Y_PX * scale);
    L.scale         = scale;
    L.font_size     = font_size;
    L.font          = [font_size, font_size, 0];
    L.pad_x         = ceil(SO_PAD_X_PX * scale);
    L.pad_y         = pad_y;
    L.gap           = ceil(SO_GAP_PX * scale);
    L.margin        = ceil(SO_MARGIN_PX * scale);
    L.box_height    = font_size + pad_y * 2;
    L.corner_radius = ceil(SO_CORNER_PX * scale);
    float clock_fs  = floor(SO_CLOCK_FONT_PX * scale);
    L.clock_font    = [clock_fs, clock_fs, 0];
    L.clock_gap     = ceil(SO_CLOCK_GAP_PX * scale);
};

void(vector pos, vector size, float radius, float corners, vector color, float alpha) SO_DrawRoundedRect =
{
    if (radius < 1 || corners == 0) {
        drawfill(pos, [size.x, size.y, 0], color, alpha);
        return;
    }
    if (radius > size.x * 0.5) radius = size.x * 0.5;
    if (radius > size.y * 0.5) radius = size.y * 0.5;

    float segments_per_corner = 5;
    float origin_x = pos.x, origin_y = pos.y;
    float width = size.x, height = size.y;
    float center_x, center_y, angle;
    float i;

    R_BeginPolygon("minimap_fill_v3", 0, 1);

    // Walk perimeter clockwise: TL -> TR -> BR -> BL. Each rounded corner
    // emits N+1 arc points; each square corner emits a single vertex.
    // Angles are in screen space (y-down); arc ranges chosen so consecutive
    // corners connect smoothly without overlap.
    if (corners & SO_RR_TL) {
        center_x = origin_x + radius; center_y = origin_y + radius;
        for (i = 0; i <= segments_per_corner; i++) {
            angle = M_PI + (i / segments_per_corner) * (M_PI / 2);
            R_PolygonVertex([center_x + cos(angle) * radius, center_y + sin(angle) * radius, 0],
                            '0 0 0', color, alpha);
        }
    } else {
        R_PolygonVertex([origin_x, origin_y, 0], '0 0 0', color, alpha);
    }

    if (corners & SO_RR_TR) {
        center_x = origin_x + width - radius; center_y = origin_y + radius;
        for (i = 0; i <= segments_per_corner; i++) {
            angle = 3 * M_PI / 2 + (i / segments_per_corner) * (M_PI / 2);
            R_PolygonVertex([center_x + cos(angle) * radius, center_y + sin(angle) * radius, 0],
                            '0 0 0', color, alpha);
        }
    } else {
        R_PolygonVertex([origin_x + width, origin_y, 0], '0 0 0', color, alpha);
    }

    if (corners & SO_RR_BR) {
        center_x = origin_x + width - radius; center_y = origin_y + height - radius;
        for (i = 0; i <= segments_per_corner; i++) {
            angle = (i / segments_per_corner) * (M_PI / 2);
            R_PolygonVertex([center_x + cos(angle) * radius, center_y + sin(angle) * radius, 0],
                            '0 0 0', color, alpha);
        }
    } else {
        R_PolygonVertex([origin_x + width, origin_y + height, 0], '0 0 0', color, alpha);
    }

    if (corners & SO_RR_BL) {
        center_x = origin_x + radius; center_y = origin_y + height - radius;
        for (i = 0; i <= segments_per_corner; i++) {
            angle = M_PI / 2 + (i / segments_per_corner) * (M_PI / 2);
            R_PolygonVertex([center_x + cos(angle) * radius, center_y + sin(angle) * radius, 0],
                            '0 0 0', color, alpha);
        }
    } else {
        R_PolygonVertex([origin_x, origin_y + height, 0], '0 0 0', color, alpha);
    }

    R_EndPolygon();
};

// Reserved vertical footprint (top margin + box + clock + bottom margin)
// the score overlay occupies inside the player viewport. Callers placing
// other UI near the top of the viewport (e.g. powcam) can shift down by
// this amount so they don't overlap.
float(vector main_size) ScoreOverlayReservedHeight =
{
    so_layout_t L;
    SO_LayoutFor(main_size, L);
    float clock_height = L.clock_font.y + L.clock_gap;
    return L.margin + L.box_height + clock_height + L.margin;
};

void(vector main_min, vector main_size, float vwidth, float vheight) ScoreOverlayDraw =
{
    if (serverkeyfloat("deathmatch") <= 0) {
        return;
    }
    // Hide during pre-match standby (no scores yet). After the match the
    // status may revert to "standby" but matchstart is still set - keep the
    // overlay visible in that case so the final score remains on screen.
    if (!strcasecmp(serverkey("status"), "standby")) {
        return;
    }

    // Collect active non-spectator players.
    string player_names    [SO_MAX_PARTICIPANTS];
    float  player_frags    [SO_MAX_PARTICIPANTS];
    vector player_topcolor [SO_MAX_PARTICIPANTS];
    vector player_botcolor [SO_MAX_PARTICIPANTS];
    string player_team     [SO_MAX_PARTICIPANTS];
    float  player_count    = 0;

    int i;
    for (i = 0; i < maxclients && player_count < SO_MAX_PARTICIPANTS; i++) {
        string name = getplayerkeyvalue(i, "name");
        if (name == "") continue;
        if (stof(getplayerkeyvalue(i, "*spectator")) > 0) continue;

        player_names    [player_count] = name;
        player_frags    [player_count] = stof(getplayerkeyvalue(i, "frags"));
        player_topcolor [player_count] = stov(getplayerkeyvalue(i, "topcolor_rgb"));
        player_botcolor [player_count] = stov(getplayerkeyvalue(i, "bottomcolor_rgb"));
        player_team     [player_count] = getplayerkeyvalue(i, "team");
        player_count++;
    }

    // Collapse to participants: either 2 players or 2 teams.
    string participant_name     [2];
    float  participant_score    [2];
    vector participant_topcolor [2];
    vector participant_botcolor [2];
    float  participants_ok      = 0;

    // Try unique teams first.
    string team_name     [SO_MAX_PARTICIPANTS];
    float  team_frags    [SO_MAX_PARTICIPANTS];
    vector team_topcolor [SO_MAX_PARTICIPANTS];
    vector team_botcolor [SO_MAX_PARTICIPANTS];
    float  team_count        = 0;
    float  any_team_empty    = 0;

    for (i = 0; i < player_count; i++) {
        if (player_team[i] == "") {
            any_team_empty = 1;
        }
        float existing = -1;
        int j;
        for (j = 0; j < team_count; j++) {
            if (team_name[j] == player_team[i]) {
                existing = j;
                break;
            }
        }
        if (existing < 0) {
            if (team_count >= SO_MAX_PARTICIPANTS) break;
            team_name     [team_count] = player_team    [i];
            team_frags    [team_count] = player_frags   [i];
            team_topcolor [team_count] = player_topcolor[i];
            team_botcolor [team_count] = player_botcolor[i];
            team_count++;
        } else {
            team_frags[existing] += player_frags[i];
        }
    }

    // Use teams only when teamplay is enabled AND there are exactly 2 distinct
    // non-empty teams. Otherwise fall back to the 2-player case.
    float teamplay = serverkeyfloat("teamplay");
    if (teamplay > 0 && team_count == 2 && !any_team_empty) {
        participant_name    [0] = team_name    [0];
        participant_score   [0] = team_frags   [0];
        participant_topcolor[0] = team_topcolor[0];
        participant_botcolor[0] = team_botcolor[0];
        participant_name    [1] = team_name    [1];
        participant_score   [1] = team_frags   [1];
        participant_topcolor[1] = team_topcolor[1];
        participant_botcolor[1] = team_botcolor[1];
        participants_ok = 1;
    } else if (player_count == 2) {
        participant_name    [0] = player_names   [0];
        participant_score   [0] = player_frags   [0];
        participant_topcolor[0] = player_topcolor[0];
        participant_botcolor[0] = player_botcolor[0];
        participant_name    [1] = player_names   [1];
        participant_score   [1] = player_frags   [1];
        participant_topcolor[1] = player_topcolor[1];
        participant_botcolor[1] = player_botcolor[1];
        participants_ok = 1;
    }

    if (!participants_ok) {
        return;
    }

    // Stable left/right placement: sort the two participants by the
    // ASCII-byte order of their (markup-stripped) names, ascending.
    if (strcmp(strdecolorize(participant_name[0]), strdecolorize(participant_name[1])) > 0) {
        string swap_name = participant_name[0];
        participant_name[0] = participant_name[1];
        participant_name[1] = swap_name;

        float swap_score = participant_score[0];
        participant_score[0] = participant_score[1];
        participant_score[1] = swap_score;

        vector swap_top = participant_topcolor[0];
        participant_topcolor[0] = participant_topcolor[1];
        participant_topcolor[1] = swap_top;

        vector swap_bot = participant_botcolor[0];
        participant_botcolor[0] = participant_botcolor[1];
        participant_botcolor[1] = swap_bot;
    }

    // Layout. All sizes derived from the viewport via SO_LayoutFor.
    so_layout_t L;
    SO_LayoutFor(main_size, L);
    vector font  = L.font;
    float  gap   = L.gap;
    float  pad_x = L.pad_x;
    float  pad_y = L.pad_y;

    string score1_str = ftos(participant_score[0]);
    string score2_str = ftos(participant_score[1]);

    float name1_width  = stringwidth(participant_name[0], 1, font);
    float name2_width  = stringwidth(participant_name[1], 1, font);
    float score1_width = stringwidth(score1_str, 0, font);
    float score2_width = stringwidth(score2_str, 0, font);

    // Score boxes get a minimum inner width of 3 character-widths so a 1- or
    // 2-digit score has the same footprint as a 3-digit one.
    float min_inner_width = stringwidth("000", 0, font);
    float inner1_width = (score1_width > min_inner_width) ? score1_width : min_inner_width;
    float inner2_width = (score2_width > min_inner_width) ? score2_width : min_inner_width;

    float box_height = L.box_height;
    float box1_width = inner1_width + pad_x * 2;
    float box2_width = inner2_width + pad_x * 2;

    // Always centered on the full screen (highest z-index UI element -
    // rendered last on top of player view, minimap, and powcam). Names extend
    // outward and don't shift the score boxes.
    float top      = L.margin;
    float center_x = vwidth * 0.5;
    float box1_x   = center_x - gap * 0.5 - box1_width;
    float box2_x   = center_x + gap * 0.5;
    float name1_x  = box1_x - gap - name1_width;
    float name2_x  = box2_x + box2_width + gap;

    // Name 1 (right-aligned to score 1).
    drawstring([name1_x, top + pad_y, 0], participant_name[0], font, '1 1 1', 1, 0);

    // Score boxes: top half = topcolor with TL/TR rounded; bottom half =
    // bottomcolor with BL/BR rounded. Score text horizontally centered.
    float radius = L.corner_radius;

    SO_DrawRoundedRect([box1_x, top, 0],
                       [box1_width, box_height * 0.5], radius, SO_RR_TOP, participant_topcolor[0], 1);
    SO_DrawRoundedRect([box1_x, top + box_height * 0.5, 0],
                       [box1_width, box_height * 0.5], radius, SO_RR_BOTTOM, participant_botcolor[0], 1);
    drawstring([box1_x + (box1_width - score1_width) * 0.5, top + pad_y, 0],
               score1_str, font, '1 1 1', 1, 0);

    SO_DrawRoundedRect([box2_x, top, 0],
                       [box2_width, box_height * 0.5], radius, SO_RR_TOP, participant_topcolor[1], 1);
    SO_DrawRoundedRect([box2_x, top + box_height * 0.5, 0],
                       [box2_width, box_height * 0.5], radius, SO_RR_BOTTOM, participant_botcolor[1], 1);
    drawstring([box2_x + (box2_width - score2_width) * 0.5, top + pad_y, 0],
               score2_str, font, '1 1 1', 1, 0);

    // Name 2 (left-aligned to score 2).
    drawstring([name2_x, top + pad_y, 0], participant_name[1], font, '1 1 1', 1, 0);

    // Match elapsed clock, centered just below the score boxes. -1 means
    // no clock yet (standby, countdown, QTV before first time print) - in
    // that case we skip drawing so the slot doesn't read "00:00".
    float elapsed = getmatchelapsed();
    if (elapsed >= 0) {
        float  minutes = floor(elapsed / 60);
        float  seconds = floor(elapsed - minutes * 60);
        string clock       = sprintf("%02d:%02d", minutes, seconds);
        float  clock_width = stringwidth(clock, 0, L.clock_font);
        float  clock_x     = center_x - clock_width * 0.5;
        float  clock_y     = top + box_height + L.clock_gap;
        drawstring([clock_x, clock_y, 0], clock, L.clock_font, '1 1 0.2', 1, 0);
    }
};
