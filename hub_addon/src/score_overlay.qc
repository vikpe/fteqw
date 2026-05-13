// SPDX-License-Identifier: 0BSD

/*
 * Score overlay drawn centered at the top of the screen.
 *
 * Visibility:
 *   - Hidden entirely in coop (deathmatch == 0).
 *   - Participants (name+score boxes) shown whenever a 2-side partition
 *     is available: exactly 2 active non-spectator players, OR exactly
 *     2 distinct teams across them. Stays visible during standby so the
 *     final score from the previous match remains on screen.
 *   - Match clock shown only outside standby.
 *
 * Layout (left to right): name1 | score1 | score2 | name2
 *   - 4px gap between every item
 *   - scores sit on a vertically-split rectangle (top half = top_color,
 *     bottom half = bottom_color) belonging to that participant
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

// Pixel sizes at scale = 1. Constants are named after the so_layout_t
// field they populate (see SO_LayoutFor).
#define SO_MARGIN_PX                16
#define SO_VERTICAL_GAP_PX          4
#define SO_SCORE_FONT_PX            12
#define SO_SCORE_PADDING_X_PX       6
#define SO_SCORE_PADDING_Y_PX       4
#define SO_SCORE_HORIZONTAL_GAP_PX  4
#define SO_SCORE_CORNER_RADIUS_PX   1
#define SO_CLOCK_FONT_PX            12

// Filled rounded rect via R_BeginPolygon (one convex poly, triangle-fan
// tessellated by the engine). `corners` is a bitmask of which corners to
// round: 1=TL, 2=TR, 4=BR, 8=BL.
#define SO_RR_TL 1
#define SO_RR_TR 2
#define SO_RR_BR 4
#define SO_RR_BL 8
#define SO_RR_TOP    (SO_RR_TL | SO_RR_TR)
#define SO_RR_BOTTOM (SO_RR_BR | SO_RR_BL)

// One scoreboard entry. The same shape works for raw players, aggregated
// teams, and the final 2 participants - .team is only meaningful for the
// raw-player pass.
typedef struct {
    string name;
    float  score;
    vector top_color;
    vector bottom_color;
    string team;
} so_participant_t;

// Score-box + name layout, scaled to the current viewport.
typedef struct {
    vector font_size;      // character cell (w, h) for drawstring/stringwidth
    vector padding;        // inner padding inside each score box (x=horizontal, y=vertical)
    float  horizontal_gap; // horizontal gap: name<->box and between the two boxes
    float  box_height;     // full score-box height (font_size.y + padding.y*2); drawn as two halves
    float  corner_radius;  // outer corner rounding on top/bottom halves
} so_score_layout_t;

// Top-level layout: base scale + per-subsystem metrics. Produced by
// SO_LayoutFor and consumed by the draw functions.
typedef struct {
    float             scale;
    float             margin;           // top/bottom outer margin around the whole overlay
    float             vertical_gap;     // vertical space between the score-box row and the clock
    so_score_layout_t score;
    vector            clock_font_size;  // character cell (w, h) for the "MM:SS" text
} so_layout_t;

// Forward declarations so the file reads top-down (entry points first).
void(vector main_size, __out so_layout_t L)                                              SO_LayoutFor;
float(so_layout_t L, vector anchor)                                                      SO_DrawParticipants;
void(so_layout_t L, vector anchor, float has_participants)                               SO_DrawClock;
void(so_layout_t L, vector anchor, float side, so_participant_t p)                       SO_DrawParticipantSide;
void(vector pos, vector size, float radius, float corners, vector color, float alpha)    SO_DrawRoundedRect;

// ----- entry points ---------------------------------------------------------

void(vector main_size, float vwidth) ScoreOverlayDraw =
{
    // Coop hides everything.
    if (serverkeyfloat("deathmatch") <= 0) {
        return;
    }

    // Highest z-index UI - centered on the full screen, drawn over player
    // view / minimap / powcam.
    so_layout_t L;
    SO_LayoutFor(main_size, L);
    vector anchor = [vwidth * 0.5, L.margin, 0];

    // Participants: visible during standby too (so the final score of the
    // previous match stays on screen between rounds).
    float has_participants = SO_DrawParticipants(L, anchor);

    // Clock: hidden during pre-match / between-match standby. When no
    // participants were drawn, the clock takes their slot at the top.
    if (strcasecmp(serverkey("status"), "standby")) {
        SO_DrawClock(L, anchor, has_participants);
    }
};

// Reserved vertical footprint (top margin + box + clock + bottom margin)
// the score overlay occupies inside the player viewport. Callers placing
// other UI near the top of the viewport (e.g. powcam) can shift down by
// this amount so they don't overlap.
float(vector main_size) ScoreOverlayReservedHeight =
{
    so_layout_t L;
    SO_LayoutFor(main_size, L);
    float clock_height = L.clock_font_size.y + L.vertical_gap;
    return L.margin + L.score.box_height + clock_height + L.margin;
};

// ----- participants ---------------------------------------------------------

// Gather players, fold into participants (1-2 teams or 1-2 players),
// sort, and draw. Returns 1 if anything was drawn, 0 if bailed (no
// participants, or too many for a 2-side display). A single participant
// is drawn on the left; two are drawn left/right. `anchor` is the
// centered top of the overlay row (x = horizontal center, y = top edge).
float(so_layout_t L, vector anchor) SO_DrawParticipants =
{
    // Collect active non-spectator players into one struct array.
    so_participant_t players[SO_MAX_PARTICIPANTS];
    float player_count = 0;
    for (int i = 0; i < maxclients && player_count < SO_MAX_PARTICIPANTS; i++) {
        string name = getplayerkeyvalue(i, "name");
        if (name == "") continue;
        if (stof(getplayerkeyvalue(i, "*spectator")) > 0) continue;
        players[player_count].name     = name;
        players[player_count].score    = stof(getplayerkeyvalue(i, "frags"));
        players[player_count].top_color = stov(getplayerkeyvalue(i, "topcolor_rgb"));
        players[player_count].bottom_color = stov(getplayerkeyvalue(i, "bottomcolor_rgb"));
        players[player_count].team     = getplayerkeyvalue(i, "team");
        player_count++;
    }

    if (player_count == 0) {
        return 0;
    }

    // Teamplay: aggregate into unique teams. Use them when 1 or 2
    // distinct non-empty teams exist; otherwise fall through.
    so_participant_t participants[2];
    float participant_count = 0;
    if (serverkeyfloat("teamplay") > 0) {
        so_participant_t teams[SO_MAX_PARTICIPANTS];
        float team_count = 0;
        for (int i = 0; i < player_count; i++) {
            if (players[i].team == "") {
                // Empty team disqualifies the partition; poison team_count
                // so the check below falls through to the player case.
                team_count = -1;
                break;
            }
            float existing = -1;
            for (int j = 0; j < team_count; j++) {
                if (teams[j].name == players[i].team) {
                    existing = j;
                    break;
                }
            }
            if (existing < 0) {
                if (team_count >= SO_MAX_PARTICIPANTS) break;
                teams[team_count]      = players[i];
                teams[team_count].name = players[i].team;
                team_count++;
            } else {
                teams[existing].score += players[i].score;
            }
        }
        if (team_count == 1 || team_count == 2) {
            participants[0] = teams[0];
            if (team_count == 2) participants[1] = teams[1];
            participant_count = team_count;
        }
    }

    if (participant_count == 0) {
        if (player_count > 2) {
            return 0;
        }
        participants[0] = players[0];
        if (player_count == 2) participants[1] = players[1];
        participant_count = player_count;
    }

    // Two-sided: stable left/right placement by ASCII-byte order of the
    // markup-stripped names, ascending.
    if (participant_count == 2 &&
        strcmp(strdecolorize(participants[0].name), strdecolorize(participants[1].name)) > 0) {
        so_participant_t swap = participants[0];
        participants[0] = participants[1];
        participants[1] = swap;
    }

    SO_DrawParticipantSide(L, anchor, -1, participants[0]);
    if (participant_count == 2) {
        SO_DrawParticipantSide(L, anchor, +1, participants[1]);
    }
    return 1;
};

// Draws one participant's score box + score text + outward name. `side` is
// -1 for left of anchor.x, +1 for right.
void(so_layout_t L, vector anchor, float side, so_participant_t p) SO_DrawParticipantSide =
{
    vector font    = L.score.font_size;
    string score_s = ftos(p.score);
    float  name_w  = stringwidth(p.name, 1, font);
    float  score_w = stringwidth(score_s, 0, font);

    // Score boxes get a minimum inner width of 3 character-widths so 1- and
    // 2-digit scores share the footprint of a 3-digit one.
    float  min_inner  = stringwidth("000", 0, font);
    float  inner_w    = (score_w > min_inner) ? score_w : min_inner;
    vector half_size  = [inner_w + L.score.padding.x * 2, L.score.box_height * 0.5, 0];

    // side=-1: box sits to the left of anchor.x; name extends further left.
    // side=+1: box sits to the right; name extends further right.
    float box_x  = (side < 0) ? (anchor.x - L.score.horizontal_gap * 0.5 - half_size.x) : (anchor.x + L.score.horizontal_gap * 0.5);
    float name_x = (side < 0) ? (box_x - L.score.horizontal_gap - name_w)               : (box_x + half_size.x + L.score.horizontal_gap);

    vector box_top_pos    = [box_x, anchor.y, 0];
    vector box_bottom_pos = [box_x, anchor.y + half_size.y, 0];
    vector score_pos      = [box_x + (half_size.x - score_w) * 0.5, anchor.y + L.score.padding.y, 0];
    vector name_pos       = [name_x, anchor.y + L.score.padding.y, 0];

    SO_DrawRoundedRect(box_top_pos,    half_size, L.score.corner_radius, SO_RR_TOP,    p.top_color, 1);
    SO_DrawRoundedRect(box_bottom_pos, half_size, L.score.corner_radius, SO_RR_BOTTOM, p.bottom_color, 1);
    drawstring(score_pos, score_s, font, '1 1 1', 1, 0);
    drawstring(name_pos,  p.name,  font, '1 1 1', 1, 0);
};

// ----- clock ----------------------------------------------------------------

// Match elapsed clock. Positioned just below the score boxes when
// participants were drawn; otherwise sits in the score row's slot at
// `anchor.y`. getmatchelapsed returns -1 during
// standby/countdown/QTV-before-first-time-print; we skip drawing in
// that case so the slot doesn't read "00:00".
void(so_layout_t L, vector anchor, float has_participants) SO_DrawClock =
{
    float elapsed = getmatchelapsed();
    if (elapsed < 0) return;
    float  minutes = floor(elapsed / 60);
    float  seconds = floor(elapsed - minutes * 60);
    string text    = sprintf("%02d:%02d", minutes, seconds);
    float  width   = stringwidth(text, 0, L.clock_font_size);
    float  y       = has_participants ? (anchor.y + L.score.box_height + L.vertical_gap) : anchor.y;
    vector pos     = [anchor.x - width * 0.5, y, 0];
    drawstring(pos, text, L.clock_font_size, '1 1 0.2', 1, 0);
};

// ----- layout / primitives --------------------------------------------------

void(vector main_size, __out so_layout_t L) SO_LayoutFor =
{
    float scale = main_size.y / SO_REF_HEIGHT;
    if (scale < SO_SCALE_MIN) scale = SO_SCALE_MIN;
    if (scale > SO_SCALE_MAX) scale = SO_SCALE_MAX;
    L.scale = scale;

    L.margin = ceil(SO_MARGIN_PX * scale);

    float score_font_px = floor(SO_SCORE_FONT_PX * scale);
    L.score.font_size      = [score_font_px, score_font_px, 0];
    L.score.padding        = [ceil(SO_SCORE_PADDING_X_PX * scale), ceil(SO_SCORE_PADDING_Y_PX * scale), 0];
    L.score.horizontal_gap = ceil(SO_SCORE_HORIZONTAL_GAP_PX * scale);
    L.score.box_height     = score_font_px + L.score.padding.y * 2;
    L.score.corner_radius  = ceil(SO_SCORE_CORNER_RADIUS_PX * scale);

    float clock_font_px    = floor(SO_CLOCK_FONT_PX * scale);
    L.clock_font_size = [clock_font_px, clock_font_px, 0];
    L.vertical_gap    = ceil(SO_VERTICAL_GAP_PX * scale);
};

void(vector pos, vector size, float radius, float corners, vector color, float alpha) SO_DrawRoundedRect =
{
    if (radius < 1 || corners == 0) {
        drawfill(pos, [size.x, size.y, 0], color, alpha);
        return;
    }
    if (radius > size.x * 0.5) radius = size.x * 0.5;
    if (radius > size.y * 0.5) radius = size.y * 0.5;

    float  segments_per_corner = 5;
    vector center;
    float  angle;

    R_BeginPolygon("minimap_fill_v3", 0, 1);

    // Walk perimeter clockwise: TL -> TR -> BR -> BL. Each rounded corner
    // emits N+1 arc points; each square corner emits a single vertex.
    // Angles are in screen space (y-down); arc ranges chosen so consecutive
    // corners connect smoothly without overlap.
    if (corners & SO_RR_TL) {
        center = [pos.x + radius, pos.y + radius, 0];
        for (int i = 0; i <= segments_per_corner; i++) {
            angle = M_PI + (i / segments_per_corner) * (M_PI / 2);
            R_PolygonVertex([center.x + cos(angle) * radius, center.y + sin(angle) * radius, 0],
                            '0 0 0', color, alpha);
        }
    } else {
        R_PolygonVertex([pos.x, pos.y, 0], '0 0 0', color, alpha);
    }

    if (corners & SO_RR_TR) {
        center = [pos.x + size.x - radius, pos.y + radius, 0];
        for (int i = 0; i <= segments_per_corner; i++) {
            angle = 3 * M_PI / 2 + (i / segments_per_corner) * (M_PI / 2);
            R_PolygonVertex([center.x + cos(angle) * radius, center.y + sin(angle) * radius, 0],
                            '0 0 0', color, alpha);
        }
    } else {
        R_PolygonVertex([pos.x + size.x, pos.y, 0], '0 0 0', color, alpha);
    }

    if (corners & SO_RR_BR) {
        center = [pos.x + size.x - radius, pos.y + size.y - radius, 0];
        for (int i = 0; i <= segments_per_corner; i++) {
            angle = (i / segments_per_corner) * (M_PI / 2);
            R_PolygonVertex([center.x + cos(angle) * radius, center.y + sin(angle) * radius, 0],
                            '0 0 0', color, alpha);
        }
    } else {
        R_PolygonVertex([pos.x + size.x, pos.y + size.y, 0], '0 0 0', color, alpha);
    }

    if (corners & SO_RR_BL) {
        center = [pos.x + radius, pos.y + size.y - radius, 0];
        for (int i = 0; i <= segments_per_corner; i++) {
            angle = M_PI / 2 + (i / segments_per_corner) * (M_PI / 2);
            R_PolygonVertex([center.x + cos(angle) * radius, center.y + sin(angle) * radius, 0],
                            '0 0 0', color, alpha);
        }
    } else {
        R_PolygonVertex([pos.x, pos.y + size.y, 0], '0 0 0', color, alpha);
    }

    R_EndPolygon();
};
