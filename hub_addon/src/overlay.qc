// SPDX-License-Identifier: 0BSD

/*
 * Overlay drawn across the top of the screen. Bundles the
 * top-of-screen widgets that share a layout/scale:
 *   - 2-side score boxes (1v1 or 2-team partition)
 *   - match clock
 *
 * Visibility:
 *   - Hidden entirely in coop (deathmatch == 0).
 *   - Score boxes shown whenever a 2-side partition is available:
 *     exactly 2 active non-spectator players, OR exactly 2 distinct
 *     teams across them. Stays visible during standby so the final
 *     score from the previous match remains on screen.
 *   - Match clock shown only outside standby.
 *
 * Score row layout (left to right): name1 | score1 | score2 | name2
 *   - 4px gap between every item
 *   - scores sit on a vertically-split rectangle (top half = top_color,
 *     bottom half = bottom_color) belonging to that participant
 *   - name1 ends at score1 (right-aligned to score1)
 *   - name2 begins after score2 (left-aligned to score2)
 *   - names are drawn verbatim, no char filtering
 */

// Layout reference height in pixels. All sizes scale with main_size.y / this.
#define OVERLAY_REF_HEIGHT 720

// Scale clamps - tiny windows stay legible, huge ones don't get cartoonish.
#define OVERLAY_SCALE_MIN 0.6
#define OVERLAY_SCALE_MAX 2.0

// Pixel sizes at scale = 1. Constants are named after the overlay_layout_t
// field they populate (see OVERLAY_LayoutFor).
#define OVERLAY_MARGIN_PX                16
#define OVERLAY_VERTICAL_GAP_PX          4
#define OVERLAY_SCORE_FONT_PX            12
#define OVERLAY_SCORE_PADDING_X_PX       6
#define OVERLAY_SCORE_PADDING_Y_PX       4
#define OVERLAY_SCORE_HORIZONTAL_GAP_PX  4
#define OVERLAY_SCORE_CORNER_RADIUS_PX   1
#define OVERLAY_CLOCK_FONT_PX            12

// Score-box + name layout, scaled to the current viewport.
typedef struct {
    vector font_size;      // character cell (w, h) for drawstring/stringwidth
    vector padding;        // inner padding inside each score box (x=horizontal, y=vertical)
    float  horizontal_gap; // horizontal gap: name<->box and between the two boxes
    float  box_height;     // full score-box height (font_size.y + padding.y*2); drawn as two halves
    float  corner_radius;  // outer corner rounding on top/bottom halves
} overlay_score_layout_t;

// Top-level layout: base scale + per-subsystem metrics. Produced by
// OVERLAY_LayoutFor and consumed by the draw functions.
typedef struct {
    float             scale;
    float             margin;           // top/bottom outer margin around the whole overlay
    float             vertical_gap;     // vertical space between the score-box row and the clock
    overlay_score_layout_t score;
    vector            clock_font_size;  // character cell (w, h) for the "MM:SS" text
} overlay_layout_t;

// Forward declarations so the file reads top-down (entry points first).
void(vector main_size, __out overlay_layout_t L)                                              OVERLAY_LayoutFor;
float(overlay_layout_t L, vector anchor)                                                      OVERLAY_DrawParticipants;
void(overlay_layout_t L, vector anchor)                                                       OVERLAY_DrawClock;
void(overlay_layout_t L, vector anchor, float side, participant_t p)                          OVERLAY_DrawParticipantSide;

// ----- entry points ---------------------------------------------------------

void(vector main_size, float vwidth) OverlayDraw =
{
    // Coop hides everything.
    if (serverkeyfloat("deathmatch") <= 0) {
        return;
    }

    // Highest z-index UI - centered on the full screen, drawn over player
    // view / minimap / powcam.
    overlay_layout_t L;
    OVERLAY_LayoutFor(main_size, L);
    vector anchor = [vwidth * 0.5, L.margin, 0];

    // Participants: visible during standby too (so the final score of the
    // previous match stays on screen between rounds).
    float has_participants = OVERLAY_DrawParticipants(L, anchor);

    // Clock: hidden during pre-match / between-match standby is handled
    // inside OVERLAY_DrawClock. When no participants were drawn, the clock
    // takes their slot at the top.
    vector clock_anchor = anchor;
    if (has_participants) {
        clock_anchor.y += L.score.box_height + L.vertical_gap;
    }
    OVERLAY_DrawClock(L, clock_anchor);
};

// Reserved vertical footprint (top margin + box + clock + bottom margin)
// the score overlay occupies inside the player viewport. Callers placing
// other UI near the top of the viewport (e.g. powcam) can shift down by
// this amount so they don't overlap.
float(vector main_size) OverlayReservedHeight =
{
    overlay_layout_t L;
    OVERLAY_LayoutFor(main_size, L);
    float clock_height = L.clock_font_size.y + L.vertical_gap;
    return L.margin + L.score.box_height + clock_height;
};

// ----- participants ---------------------------------------------------------

// Gather players, fold into participants (1-2 teams or 1-2 players),
// sort, and draw. Returns 1 if anything was drawn, 0 if bailed (no
// participants, or too many for a 2-side display). A single participant
// is drawn on the left; two are drawn left/right. `anchor` is the
// centered top of the overlay row (x = horizontal center, y = top edge).
float(overlay_layout_t L, vector anchor) OVERLAY_DrawParticipants =
{
    Participants_Gather();
    if (Participants_PlayerCount == 0) {
        return 0;
    }

    // Teamplay: use the gathered team grouping when 1 or 2 distinct
    // non-empty teams exist; otherwise fall through to the per-player case.
    participant_t participants[2];
    float participant_count = 0;
    if (serverkeyfloat("teamplay") > 0) {
        float has_empty_team = 0;
        for (int j = 0; j < Participants_TeamCount; j++) {
            if (Participants_Teams[j].name == "") {
                has_empty_team = 1;
                break;
            }
        }
        if (!has_empty_team && (Participants_TeamCount == 1 || Participants_TeamCount == 2)) {
            participants[0] = Participants_Teams[0];
            if (Participants_TeamCount == 2) participants[1] = Participants_Teams[1];
            participant_count = Participants_TeamCount;
        }
    }

    if (participant_count == 0) {
        if (Participants_PlayerCount > 2) {
            return 0;
        }
        participants[0] = Participants_Players[0];
        if (Participants_PlayerCount == 2) participants[1] = Participants_Players[1];
        participant_count = Participants_PlayerCount;
    }

    // Two-sided: stable left/right placement by ASCII-byte order of the
    // name_ascii field, ascending.
    if (participant_count == 2 &&
        strcmp(participants[0].name_ascii, participants[1].name_ascii) > 0) {
        participant_t swap = participants[0];
        participants[0] = participants[1];
        participants[1] = swap;
    }

    OVERLAY_DrawParticipantSide(L, anchor, -1, participants[0]);
    if (participant_count == 2) {
        OVERLAY_DrawParticipantSide(L, anchor, +1, participants[1]);
    }
    return 1;
};

// Draws one participant's score box + score text + outward name. `side` is
// -1 for left of anchor.x, +1 for right.
void(overlay_layout_t L, vector anchor, float side, participant_t p) OVERLAY_DrawParticipantSide =
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

    HubDrawRoundedRect(box_top_pos,    half_size, L.score.corner_radius, RR_TOP,    p.top_color, 1);
    HubDrawRoundedRect(box_bottom_pos, half_size, L.score.corner_radius, RR_BOTTOM, p.bottom_color, 1);
    drawstring(score_pos, score_s, font, '1 1 1', 1, 0);
    drawstring(name_pos,  p.name,  font, '1 1 1', 1, 0);
};

// ----- clock ----------------------------------------------------------------

// Match elapsed clock. Positioned just below the score boxes when
// participants were drawn; otherwise sits in the score row's slot at
// `anchor.y`. getmatchelapsed returns -1 during
// standby/QTV-before-first-time-print; we skip drawing in that case so
// the slot doesn't read "-1:59" (floor(-1/1000)=-1 -> mm=-1, ss=59).
// Countdown is shown as a literal "Countdown" label, independent of the
// elapsed clock.
void(overlay_layout_t L, vector anchor) OVERLAY_DrawClock =
{
    string status = serverkey("status");

    string text;
    vector color;
    if (!strcasecmp(status, "countdown")) {
        text  = "Countdown";
        color = '1 1 1';
    } else {
        // No valid clock yet: pre-match standby, or QTV joined mid-match
        // before the first "X min left" status update lets Hub_CheckServerInfo
        // derive elapsed. Skip entirely; intermission has elapsed_ms frozen
        // at the match-end value, so the clock keeps showing post-match.
        float elapsed_ms = getmatchelapsed();
        if (elapsed_ms < 0)
            return;
        float elapsed = floor(elapsed_ms / 1000);
        float minutes = floor(elapsed / 60);
        float seconds = elapsed - minutes * 60;
        text  = sprintf("%02d:%02d", minutes, seconds);
        color = '1 1 0.2';
    }
    float  width = stringwidth(text, 0, L.clock_font_size);
    vector pos   = [anchor.x - width * 0.5, anchor.y, 0];
    drawstring(pos, text, L.clock_font_size, color, 1, 0);
};

// ----- layout ---------------------------------------------------------------

void(vector main_size, __out overlay_layout_t L) OVERLAY_LayoutFor =
{
    float scale = main_size.y / OVERLAY_REF_HEIGHT;
    if (scale < OVERLAY_SCALE_MIN) scale = OVERLAY_SCALE_MIN;
    if (scale > OVERLAY_SCALE_MAX) scale = OVERLAY_SCALE_MAX;
    L.scale = scale;

    L.margin = ceil(OVERLAY_MARGIN_PX * scale);

    float score_font_px = floor(OVERLAY_SCORE_FONT_PX * scale);
    L.score.font_size      = [score_font_px, score_font_px, 0];
    L.score.padding        = [ceil(OVERLAY_SCORE_PADDING_X_PX * scale), ceil(OVERLAY_SCORE_PADDING_Y_PX * scale), 0];
    L.score.horizontal_gap = ceil(OVERLAY_SCORE_HORIZONTAL_GAP_PX * scale);
    L.score.box_height     = score_font_px + L.score.padding.y * 2;
    L.score.corner_radius  = ceil(OVERLAY_SCORE_CORNER_RADIUS_PX * scale);

    float clock_font_px    = floor(OVERLAY_CLOCK_FONT_PX * scale);
    L.clock_font_size = [clock_font_px, clock_font_px, 0];
    L.vertical_gap    = ceil(OVERLAY_VERTICAL_GAP_PX * scale);
};
