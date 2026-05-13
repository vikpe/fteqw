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

// Filled rounded rect via R_BeginPolygon (one convex poly, triangle-fan
// tessellated by the engine). `corners` is a bitmask of which corners to
// round: 1=TL, 2=TR, 4=BR, 8=BL.
#define SO_RR_TL 1
#define SO_RR_TR 2
#define SO_RR_BR 4
#define SO_RR_BL 8
#define SO_RR_TOP    (SO_RR_TL | SO_RR_TR)
#define SO_RR_BOTTOM (SO_RR_BR | SO_RR_BL)
#define SO_RR_ALL    (SO_RR_TL | SO_RR_TR | SO_RR_BR | SO_RR_BL)

void(vector pos, vector size, float radius, float corners, vector color, float alpha) SO_DrawRoundedRect =
{
    if (radius < 1 || corners == 0) {
        drawfill(pos, [size.x, size.y, 0], color, alpha);
        return;
    }
    if (radius > size.x * 0.5) radius = size.x * 0.5;
    if (radius > size.y * 0.5) radius = size.y * 0.5;

    float N = 5;  // segments per rounded corner
    float px = pos.x, py = pos.y;
    float w = size.x, h = size.y;
    float cx, cy, a, i;

    R_BeginPolygon("minimap_fill_v3", 0, 1);

    // Walk perimeter clockwise: TL -> TR -> BR -> BL. Each rounded corner
    // emits N+1 arc points; each square corner emits a single vertex.
    // Angles are in screen space (y-down); arc ranges chosen so consecutive
    // corners connect smoothly without overlap.
    if (corners & SO_RR_TL) {
        cx = px + radius; cy = py + radius;
        for (i = 0; i <= N; i++) {
            a = M_PI + (i / N) * (M_PI / 2);
            R_PolygonVertex([cx + cos(a) * radius, cy + sin(a) * radius, 0],
                            '0 0 0', color, alpha);
        }
    } else {
        R_PolygonVertex([px, py, 0], '0 0 0', color, alpha);
    }

    if (corners & SO_RR_TR) {
        cx = px + w - radius; cy = py + radius;
        for (i = 0; i <= N; i++) {
            a = 3 * M_PI / 2 + (i / N) * (M_PI / 2);
            R_PolygonVertex([cx + cos(a) * radius, cy + sin(a) * radius, 0],
                            '0 0 0', color, alpha);
        }
    } else {
        R_PolygonVertex([px + w, py, 0], '0 0 0', color, alpha);
    }

    if (corners & SO_RR_BR) {
        cx = px + w - radius; cy = py + h - radius;
        for (i = 0; i <= N; i++) {
            a = (i / N) * (M_PI / 2);
            R_PolygonVertex([cx + cos(a) * radius, cy + sin(a) * radius, 0],
                            '0 0 0', color, alpha);
        }
    } else {
        R_PolygonVertex([px + w, py + h, 0], '0 0 0', color, alpha);
    }

    if (corners & SO_RR_BL) {
        cx = px + radius; cy = py + h - radius;
        for (i = 0; i <= N; i++) {
            a = M_PI / 2 + (i / N) * (M_PI / 2);
            R_PolygonVertex([cx + cos(a) * radius, cy + sin(a) * radius, 0],
                            '0 0 0', color, alpha);
        }
    } else {
        R_PolygonVertex([px, py + h, 0], '0 0 0', color, alpha);
    }

    R_EndPolygon();
};

// Reserved vertical footprint (top margin + box + bottom margin) the score
// overlay occupies inside the player viewport. Callers placing other UI
// near the top of the viewport (e.g. powcam) can shift down by
// this amount so they don't overlap.
float(vector main_size) ScoreOverlayReservedHeight =
{
    float scale  = main_size.y / 720;
    if (scale < 0.6) scale = 0.6;
    if (scale > 2.0) scale = 2.0;
    float fs        = floor(12 * scale);
    float pad_y     = ceil(4 * scale);
    float margin    = ceil(16 * scale);
    float clock_h   = floor(10 * scale) + ceil(2 * scale);
    float box_h     = fs + pad_y * 2;
    return margin + box_h + clock_h + margin;
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
    string  p_name [SO_MAX_PARTICIPANTS];
    float   p_frags[SO_MAX_PARTICIPANTS];
    vector  p_top  [SO_MAX_PARTICIPANTS];
    vector  p_bot  [SO_MAX_PARTICIPANTS];
    string  p_team [SO_MAX_PARTICIPANTS];
    float n = 0;

    int i;
    for (i = 0; i < maxclients && n < SO_MAX_PARTICIPANTS; i++) {
        string nm = getplayerkeyvalue(i, "name");
        if (nm == "") continue;
        if (stof(getplayerkeyvalue(i, "*spectator")) > 0) continue;

        p_name [n] = nm;
        p_frags[n] = stof(getplayerkeyvalue(i, "frags"));
        p_top  [n] = stov(getplayerkeyvalue(i, "topcolor_rgb"));
        p_bot  [n] = stov(getplayerkeyvalue(i, "bottomcolor_rgb"));
        p_team [n] = getplayerkeyvalue(i, "team");
        n++;
    }

    // Collapse to participants: either 2 players or 2 teams.
    string  part_name [2];
    float   part_score[2];
    vector  part_top  [2];
    vector  part_bot  [2];
    float   valid = 0;

    // Try unique teams first.
    string  teams      [SO_MAX_PARTICIPANTS];
    float   team_frags [SO_MAX_PARTICIPANTS];
    vector  team_top   [SO_MAX_PARTICIPANTS];
    vector  team_bot   [SO_MAX_PARTICIPANTS];
    float nt = 0;
    float any_team_empty = 0;

    for (i = 0; i < n; i++) {
        if (p_team[i] == "") {
            any_team_empty = 1;
        }
        float found = -1;
        int j;
        for (j = 0; j < nt; j++) {
            if (teams[j] == p_team[i]) {
                found = j;
                break;
            }
        }
        if (found < 0) {
            if (nt >= SO_MAX_PARTICIPANTS) break;
            teams     [nt] = p_team[i];
            team_frags[nt] = p_frags[i];
            team_top  [nt] = p_top  [i];
            team_bot  [nt] = p_bot  [i];
            nt++;
        } else {
            team_frags[found] += p_frags[i];
        }
    }

    // Use teams only when teamplay is enabled AND there are exactly 2 distinct
    // non-empty teams. Otherwise fall back to the 2-player case.
    float teamplay = serverkeyfloat("teamplay");
    if (teamplay > 0 && nt == 2 && !any_team_empty) {
        part_name [0] = teams     [0];
        part_score[0] = team_frags[0];
        part_top  [0] = team_top  [0];
        part_bot  [0] = team_bot  [0];
        part_name [1] = teams     [1];
        part_score[1] = team_frags[1];
        part_top  [1] = team_top  [1];
        part_bot  [1] = team_bot  [1];
        valid = 1;
    } else if (n == 2) {
        part_name [0] = p_name [0];
        part_score[0] = p_frags[0];
        part_top  [0] = p_top  [0];
        part_bot  [0] = p_bot  [0];
        part_name [1] = p_name [1];
        part_score[1] = p_frags[1];
        part_top  [1] = p_top  [1];
        part_bot  [1] = p_bot  [1];
        valid = 1;
    }

    if (!valid) {
        return;
    }

    // Stable left/right placement: sort the two participants by the
    // ASCII-byte order of their (markup-stripped) names, ascending.
    if (strcmp(strdecolorize(part_name[0]), strdecolorize(part_name[1])) > 0) {
        string  tn = part_name [0]; part_name [0] = part_name [1]; part_name [1] = tn;
        float   ts = part_score[0]; part_score[0] = part_score[1]; part_score[1] = ts;
        vector  tt = part_top  [0]; part_top  [0] = part_top  [1]; part_top  [1] = tt;
        vector  tb = part_bot  [0]; part_bot  [0] = part_bot  [1]; part_bot  [1] = tb;
    }

    // Layout. Everything scales with viewport height (720p as the baseline),
    // clamped to keep the overlay readable on tiny windows and sane on 4K.
    float scale  = main_size.y / 720;
    if (scale < 0.6) scale = 0.6;
    if (scale > 2.0) scale = 2.0;
    float fs     = floor(12 * scale);
    vector font  = [fs, fs, 0];
    float  gap   = ceil(4 * scale);
    float  pad_x = ceil(6 * scale);
    float  pad_y = ceil(4 * scale);

    string s1 = ftos(part_score[0]);
    string s2 = ftos(part_score[1]);

    float n1w = stringwidth(part_name[0], 1, font);
    float n2w = stringwidth(part_name[1], 1, font);
    float s1w = stringwidth(s1, 0, font);
    float s2w = stringwidth(s2, 0, font);

    // Score boxes get a minimum inner width of 3 character-widths so a 1- or
    // 2-digit score has the same footprint as a 3-digit one.
    float min_inner = stringwidth("000", 0, font);
    float i1w = (s1w > min_inner) ? s1w : min_inner;
    float i2w = (s2w > min_inner) ? s2w : min_inner;

    float box_h = font.y + pad_y * 2;
    float b1w   = i1w + pad_x * 2;
    float b2w   = i2w + pad_x * 2;

    // Always centered on the full screen (highest z-index UI element -
    // rendered last on top of player view, minimap, and powcam). Names extend
    // outward and don't shift the score boxes.
    float margin   = ceil(16 * scale);
    float top      = margin;
    float center_x = vwidth * 0.5;
    float box1_x   = center_x - gap * 0.5 - b1w;
    float box2_x   = center_x + gap * 0.5;
    float name1_x  = box1_x - gap - n1w;
    float name2_x  = box2_x + b2w + gap;

    // Name 1 (right-aligned to score 1).
    drawstring([name1_x, top + pad_y, 0], part_name[0], font, '1 1 1', 1, 0);

    // Score boxes: top half = topcolor with TL/TR rounded; bottom half =
    // bottomcolor with BL/BR rounded. Score text horizontally centered.
    float radius = ceil(1 * scale);

    SO_DrawRoundedRect([box1_x, top, 0],
                       [b1w, box_h * 0.5], radius, SO_RR_TOP, part_top[0], 1);
    SO_DrawRoundedRect([box1_x, top + box_h * 0.5, 0],
                       [b1w, box_h * 0.5], radius, SO_RR_BOTTOM, part_bot[0], 1);
    drawstring([box1_x + (b1w - s1w) * 0.5, top + pad_y, 0],
               s1, font, '1 1 1', 1, 0);

    SO_DrawRoundedRect([box2_x, top, 0],
                       [b2w, box_h * 0.5], radius, SO_RR_TOP, part_top[1], 1);
    SO_DrawRoundedRect([box2_x, top + box_h * 0.5, 0],
                       [b2w, box_h * 0.5], radius, SO_RR_BOTTOM, part_bot[1], 1);
    drawstring([box2_x + (b2w - s2w) * 0.5, top + pad_y, 0],
               s2, font, '1 1 1', 1, 0);

    // Name 2 (left-aligned to score 2).
    drawstring([name2_x, top + pad_y, 0], part_name[1], font, '1 1 1', 1, 0);

    // Match elapsed clock, centered just below the score boxes. -1 means
    // no clock yet (standby, countdown, QTV before first time print) - in
    // that case we skip drawing so the slot doesn't read "00:00".
    float elapsed = getmatchelapsed();
    if (elapsed >= 0)
    {
        float  mins  = floor(elapsed / 60);
        float  secs  = floor(elapsed - mins * 60);
        string clock = sprintf("%02d:%02d", mins, secs);
        vector cfont = [floor(12 * scale), floor(12 * scale), 0];
        float  cw    = stringwidth(clock, 0, cfont);
        float  cx    = center_x - cw * 0.5;
        float  cy    = top + box_h + ceil(4 * scale);
        drawstring([cx, cy, 0], clock, cfont, '1 1 0.2', 1, 0);
    }
};
