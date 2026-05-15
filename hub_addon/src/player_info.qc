// SPDX-License-Identifier: 0BSD

/*
 * Per-player info overlay - one row per active player, optionally
 * grouped under team headers. Default position: bottom-right corner,
 * 8px margin.
 *
 * Player row columns, left -> right:
 *   powerups | name | location | armor | health | weapon | frags
 *
 * Team header rows:
 *   - team name on the left (plain text, vertically centered)
 *   - summed frags inside a rounded color-split box on the right
 *     (top half = top_color, bottom half = bottom_color), mirroring
 *     overlay.qc's score box style
 *
 * Visibility:
 *   - Hidden in coop (deathmatch == 0).
 *   - Names + frags always visible (last-known values survive standby).
 *   - Live stats (location, health, armor, best weapon) only while the
 *     match is active; same gate as minimap_players.qc.
 *
 * Grouping:
 *   - Teamplay with no empty team strings: team header per team,
 *     members listed under it.
 *   - Otherwise: flat player list, no headers.
 *   - Within each group, players are sorted by name ascending
 *     (markup-stripped for stability). Teams are sorted the same way.
 *   - Location names are wrapped in the Quake charset bracket glyphs
 *     (chars 16/17), with the inner text rendered as brown ASCII
 *     (codepoint | 0x80). Inner field is fixed PI_LOC_NAME_SIZE chars
 *     wide, right-aligned with leading spaces ("ra" -> "[   ra]").
 *   - Armor is omitted at 0; otherwise tinted by armor type
 *     (GA green, YA yellow, RA red).
 *   - Health follows the hud_health convention: red at the low
 *     threshold (<= 25), white otherwise.
 */

// Layout reference height in pixels. All sizes scale with main_size.y / this.
#define PI_REF_HEIGHT 720

// Scale clamps.
#define PI_SCALE_MIN 0.6
#define PI_SCALE_MAX 2.0

// Pixel sizes at scale = 1.
#define PI_FONT_PX         10
#define PI_ROW_GAP_PX      4
#define PI_TEAM_GAP_PX     4   // extra space above each team header (except the first)

// Web app overlays a demo time slider along the bottom of the FTE viewport
// during demo playback; reserve extra vertical margin so the widget clears it.
#define DEMO_TIMESLIDER_HEIGHT_PX 32

// User cvars (registered automatically via autocvar_ prefix).
// playerinfo 0/1                   - master enable
// playerinfo_margin "X Y"          - margin in design pixels (scaled with viewport)
// playerinfo_scale                 - user scale multiplier (applied on top of the
//                                    viewport-driven scale, after clamping)
// playerinfo_font                  - font name; empty = engine default (gl_font)
// playerinfo_frame_color "R G B A" - frame color + alpha, RGB 0-255, A 0-1
//                                    Alpha == 0 disables the frame.
// playerinfo_frame_padding "X Y"   - inner padding around the content, design px
var float  autocvar_playerinfo               = 1;
var vector autocvar_playerinfo_margin        = '16 48 0';
var float  autocvar_playerinfo_scale         = 1;
var string autocvar_playerinfo_font          = "";
var string autocvar_playerinfo_frame_color   = "0 0 0 0";
var vector autocvar_playerinfo_frame_padding = '8 8 0';

// Cached font slot. Reloaded only when the cvar value changes.
string PI_LoadedFontName;
float  PI_LoadedFontSlot;

// Column widths at scale = 1. Rendered text right-aligns within its column,
// then the row right-aligns to the viewport edge.
#define PI_LOCATION_W_PX  56
#define PI_HEALTH_W_PX    24
#define PI_ARMOR_W_PX     24
#define PI_WEAPON_W_PX    24
#define PI_FRAGS_CHARS     3   // most matches are won in 2-3 digit ranges
#define PI_LOC_NAME_SIZE   5   // inner chars between the location brackets
#define PI_PLAYER_NAME_MAX 10  // visible-char cap on player names (markup-stripped)

// Team header frag-box. Fixed at 6 char-widths wide with the score centered
// horizontally; vertical padding is half a char on each side. Split top/bottom
// colors with rounded outer corners (mirrors overlay's score-box style).
#define PI_TEAM_BOX_CHARS         6
#define PI_TEAM_BOX_RADIUS_PX     1

// Layout cache produced by PI_LayoutFor and consumed by the draw functions.
typedef struct {
    float  scale;
    vector font_size;
    float  row_height;          // player row height (= font_size.y)
    float  team_box_width;      // fixed: 6 * font_size.x (centered text)
    float  team_box_height;     // font_size.y + team_box_padding_y*2 (== 2 * font_size.y)
    float  team_box_padding_y;  // half a char-height per side
    float  team_box_radius;
    float  row_gap;
    float  team_gap;
    float  col_gap;
    float  name_w;
    float  location_w;
    float  health_w;
    float  armor_w;
    float  weapon_w;
    float  frags_w;
} pi_layout_t;

// Forward declarations so the file reads top-down.
void(vector view_size, __out pi_layout_t L)                                    PI_LayoutFor;
void()                                                                         PI_SortPlayersByName;
void()                                                                         PI_SortTeamsByName;
string(string raw)                                                             PI_FormatLocation;
void(pi_layout_t L, vector right_top, float match_active, participant_t p)     PI_DrawPlayerRow;
void(pi_layout_t L, vector right_top, participant_t t)                         PI_DrawTeamHeader;
float()                                                                        PI_FontSlot;

// ----- entry points ---------------------------------------------------------

void(vector view_min, vector view_size) PlayerInfoDraw =
{
    if (!autocvar_playerinfo) {
        return;
    }
    // No player view (e.g. minimap_mode FULL): nothing to anchor to.
    if (view_size.x <= 0 || view_size.y <= 0) {
        return;
    }
    if (serverkeyfloat("deathmatch") <= 0) {
        return;
    }

    Participants_Gather();
    if (Participants_PlayerCount == 0) {
        return;
    }

    pi_layout_t L;
    PI_LayoutFor(view_size, L);

    // Teamplay groups when teamplay is on AND every team has a non-empty
    // name. Otherwise fall back to a flat player list.
    float teamplay_on = serverkeyfloat("teamplay") > 0;
    float has_groups = teamplay_on;
    if (has_groups) {
        for (int j = 0; j < Participants_TeamCount; j++) {
            if (Participants_Teams[j].name == "") {
                has_groups = 0;
                break;
            }
        }
    }

    PI_SortPlayersByName();
    if (has_groups) {
        PI_SortTeamsByName();
    }

    // Compute total height so we can bottom-anchor. Team header rows are
    // taller than player rows (they carry the frag-box).
    float total_height;
    if (has_groups) {
        total_height = Participants_TeamCount * (L.team_box_height + L.row_gap)
                     + Participants_PlayerCount * (L.row_height + L.row_gap)
                     - L.row_gap;
        if (Participants_TeamCount > 1) {
            total_height += (Participants_TeamCount - 1) * L.team_gap;
        }
    } else {
        total_height = Participants_PlayerCount * (L.row_height + L.row_gap) - L.row_gap;
    }

    // Bottom-right of the player-view rect. Margin in design pixels,
    // scaled with the rest of the layout. The widget renders once per
    // frame regardless of splitscreen seat count. During demo playback
    // the web app paints a time slider along the bottom, so we add
    // DEMO_TIMESLIDER_HEIGHT_PX to the bottom margin to clear it.
    float margin_x = autocvar_playerinfo_margin.x * L.scale;
    float margin_y = autocvar_playerinfo_margin.y * L.scale;
    if (isdemo()) {
        margin_y += DEMO_TIMESLIDER_HEIGHT_PX * L.scale;
    }
    float right_x  = view_min.x + view_size.x - margin_x;
    float top_y    = view_min.y + view_size.y - margin_y - total_height;

    // Background frame. Alpha == 0 disables the frame entirely (also the
    // width pre-scan, so we don't pay for it when nothing renders).
    // Width tracks the widest actual row content excluding powerups
    // (powerups extend leftward outside the frame). Player rows use
    // name_w + columns; team headers use team_name + box. Frame fits the
    // larger of the two so all in-column content sits inside.
    {
        float  n_col       = tokenize(autocvar_playerinfo_frame_color);
        float  frame_r     = (n_col >= 1) ? stof(argv(0)) : 0;
        float  frame_g     = (n_col >= 2) ? stof(argv(1)) : 0;
        float  frame_b     = (n_col >= 3) ? stof(argv(2)) : 0;
        float  frame_alpha = (n_col >= 4) ? stof(argv(3)) : 0;

        if (frame_alpha > 0) {
            float max_name_w = 0;
            for (int i = 0; i < Participants_PlayerCount; i++) {
                string trunc = MinimapColoredPrefix(Participants_Players[i].name, PI_PLAYER_NAME_MAX);
                float  w     = stringwidth(trunc, 1, L.font_size);
                if (w > L.name_w) w = L.name_w;
                if (w > max_name_w) max_name_w = w;
            }
            // A player can carry at most 3 powerups at once (Q/P/R). Each
            // glyph is one char-width, no margin between them; col_gap
            // separates the rightmost glyph from the name.
            float powerups_w = 3 * stringwidth("Q", 0, L.font_size) + L.col_gap;
            float frame_content_w = powerups_w
                                  + max_name_w
                                  + L.col_gap + L.location_w
                                  + L.col_gap + L.armor_w
                                  + L.col_gap + L.health_w
                                  + L.col_gap + L.weapon_w
                                  + L.col_gap + L.frags_w;
            if (has_groups) {
                for (int g = 0; g < Participants_TeamCount; g++) {
                    float tnw = stringwidth(Participants_Teams[g].name, 1, L.font_size);
                    float team_row_w = tnw + L.col_gap + L.team_box_width;
                    if (team_row_w > frame_content_w) frame_content_w = team_row_w;
                }
            }

            float  pad_x = autocvar_playerinfo_frame_padding.x * L.scale;
            float  pad_y = autocvar_playerinfo_frame_padding.y * L.scale;
            vector frame_pos  = [right_x - frame_content_w - pad_x, top_y - pad_y, 0];
            vector frame_size = [frame_content_w + pad_x * 2,
                                 total_height + pad_y * 2, 0];
            vector frame_rgb  = [frame_r, frame_g, frame_b] / 255;
            drawfill(frame_pos, frame_size, frame_rgb, frame_alpha);
        }
    }

    // Live-stats gate: match running ("min left" in status) OR countdown.
    // Hidden during pre-match standby and on local listen server.
    string status = serverkey("status");
    float  match_active = (strstrofs(status, "min left", 0) >= 0
                           || !strcasecmp(status, "countdown"))
                          && !isserver();

    // Switch to the user-selected font for the widget's text rendering,
    // restore the previous setting before returning so other QC overlays
    // aren't affected.
    float prev_font = drawfont;
    drawfont = PI_FontSlot();

    vector cursor = [right_x, top_y, 0];
    if (has_groups) {
        for (int g = 0; g < Participants_TeamCount; g++) {
            if (g > 0) cursor.y += L.team_gap;
            PI_DrawTeamHeader(L, cursor, Participants_Teams[g]);
            cursor.y += L.team_box_height + L.row_gap;
            for (int i = 0; i < Participants_PlayerCount; i++) {
                if (Participants_Players[i].team != Participants_Teams[g].name) continue;
                PI_DrawPlayerRow(L, cursor, match_active, Participants_Players[i]);
                cursor.y += L.row_height + L.row_gap;
            }
        }
    } else {
        for (int i = 0; i < Participants_PlayerCount; i++) {
            PI_DrawPlayerRow(L, cursor, match_active, Participants_Players[i]);
            cursor.y += L.row_height + L.row_gap;
        }
    }

    drawfont = prev_font;
};

// ----- sort -----------------------------------------------------------------

// Insertion sort, ASCII order on the markup-stripped names ascending.
// N is small (<= PARTICIPANT_MAX = 32) so the O(N^2) cost is negligible.
// Both loops split the condition because fteqcc evaluates both sides of
// && before the boundcheck fires (negative index would trip on
// Participants_*[-1] otherwise).
void() PI_SortPlayersByName =
{
    for (int i = 1; i < Participants_PlayerCount; i++) {
        participant_t key = Participants_Players[i];
        int j = i - 1;
        while (j >= 0) {
            if (strcmp(Participants_Players[j].name_ascii, key.name_ascii) <= 0) break;
            Participants_Players[j + 1] = Participants_Players[j];
            j--;
        }
        Participants_Players[j + 1] = key;
    }
};

void() PI_SortTeamsByName =
{
    for (int i = 1; i < Participants_TeamCount; i++) {
        participant_t key = Participants_Teams[i];
        int j = i - 1;
        while (j >= 0) {
            if (strcmp(Participants_Teams[j].name_ascii, key.name_ascii) <= 0) break;
            Participants_Teams[j + 1] = Participants_Teams[j];
            j--;
        }
        Participants_Teams[j + 1] = key;
    }
};

// ----- row + header rendering -----------------------------------------------

// Renders one player row, columns right-aligned within their column box.
// right_top.x is the right edge of the row; right_top.y is its top edge.
// Stats are skipped when match_active is 0.
void(pi_layout_t L, vector right_top, float match_active, participant_t p) PI_DrawPlayerRow =
{
    vector font = L.font_size;
    float  y    = right_top.y;

    // Walk right -> left, each column anchored to its right edge.
    // Layout: [powerups] | name | location | armor | health | weapon | frags
    // Powerups have no dedicated column; they hug the left edge of the
    // rendered name (see name_x below).
    float frags_right    = right_top.x;
    float weapon_right   = frags_right    - L.frags_w    - L.col_gap;
    float health_right   = weapon_right   - L.weapon_w   - L.col_gap;
    // 2px breathing room on each side of the "/" delimiter between armor
    // and health, on top of the regular col_gap.
    float slash_gap      = L.col_gap + ceil(4 * L.scale);
    float armor_right    = health_right   - L.health_w   - slash_gap;
    float location_right = armor_right    - L.armor_w    - L.col_gap;
    // Extra char-width between location and name so the bracketed location
    // string has visual breathing room from the name text.
    float name_right     = location_right - L.location_w - L.col_gap * 2;

    // Name truncated to PI_PLAYER_NAME_MAX visible chars (markup preserved).
    // Width computed up front so the powerup block can sit next to it.
    string p_name = MinimapColoredPrefix(p.name, PI_PLAYER_NAME_MAX);
    float  nw     = stringwidth(p_name, 1, font);
    if (nw > L.name_w) nw = L.name_w;
    float name_x = name_right - nw;

    // Frags (always shown).
    string frags_s = ftos(p.score);
    float  fw      = stringwidth(frags_s, 0, font);
    drawstring([frags_right - fw, y, 0], frags_s, font, '1 1 1', 1, 0);

    // Live stats: location, health/armor, best weapon.
    if (match_active) {
        vector origin = getentity(p.slot + 1, GE_ORIGIN);
        if (origin != '0 0 0') {
            string loc = getlocationname(origin);
            if (loc != "") {
                // Three pieces: open-bracket | content | close-bracket, with
                // a half-char gap between each bracket and the content so the
                // brackets aren't crammed against the text.
                string content   = PI_FormatLocation(loc);
                float  content_w = stringwidth(content, 0, font);
                float  bracket_w = stringwidth(chr2str(16), 0, font);
                float  half_char = font.x * 0.5;
                float  total_w   = bracket_w + half_char + content_w + half_char + bracket_w;
                float  x_open    = location_right - total_w;
                float  x_content = x_open + bracket_w + half_char;
                float  x_close   = x_content + content_w + half_char;
                drawstring([x_open,    y, 0], chr2str(16), font, '1 1 1', 1, 0);
                drawstring([x_content, y, 0], content,     font, '1 1 1', 1, 0);
                drawstring([x_close,   y, 0], chr2str(17), font, '1 1 1', 1, 0);
            }
        }

        // Dead-player gate: an active player entity with the player model.
        // Mirrors minimap_players.qc - matches gib/corpse/disconnect states
        // that STAT_HEALTH alone wouldn't catch.
        float health     = getplayerstat(p.slot, STAT_HEALTH, EV_FLOAT);
        float ent_active = getentity(p.slot + 1, GE_ACTIVE);
        float ent_model  = getentity(p.slot + 1, GE_MODELINDEX);
        float player_mdl = getmodelindex("progs/player.mdl");
        if (ent_active && ent_model == player_mdl && health > 0) {
            int    items = getplayerstat(p.slot, STAT_ITEMS, EV_INTEGER);
            float  armor = getplayerstat(p.slot, STAT_ARMOR, EV_FLOAT);

            // Armor: own column, omitted at 0. Tinted by armor type
            // (GA green, YA yellow, RA red).
            if (armor > 0) {
                string a_s     = sprintf("%d", armor);
                float  a_w     = stringwidth(a_s, 0, font);
                vector a_color = '1 1 1';
                if      (items & MM_IT_ARMOR3) a_color = '1 0.3 0.3';
                else if (items & MM_IT_ARMOR2) a_color = '1 1 0.3';
                else if (items & MM_IT_ARMOR1) a_color = '0.3 1 0.3';
                drawstring([armor_right - a_w, y, 0], a_s, font, a_color, 1, 0);
                // Slash centered in the 2-char gap between armor and health
                // columns (half-char margin on each side of the slash).
                float slash_w = stringwidth("/", 0, font);
                drawstring([armor_right + (slash_gap - slash_w) * 0.5, y, 0], "/", font, '0.6 0.6 0.6', 1, 0);
            }

            // Health: hud_health rule - red at the low threshold (<= 25),
            // white otherwise. Right-aligned in the health column. Capped
            // at 999 so the value fits 3 digits.
            float  h_display = (health > 999) ? 999 : health;
            string h_s       = sprintf("%d", h_display);
            float  h_w     = stringwidth(h_s, 0, font);
            vector h_color = (health <= 25) ? '1 0.3 0.3' : '1 1 1';
            drawstring([health_right - h_w, y, 0], h_s, font, h_color, 1, 0);

            // Powerup glyphs: single colored chars, no inter-char margin.
            // Q = quad (blue), P = pent (red), R = ring (yellow). Drawn
            // rightmost first so the highest-priority one sits closest
            // to the name.
            float char_w    = stringwidth("Q", 0, font);
            float powerup_x = name_x - L.col_gap - char_w;
            if (items & MM_IT_QUAD) {
                drawstring([powerup_x, y, 0], "Q", font, '0 0 1', 1, 0);
                powerup_x -= char_w;
            }
            if (items & MM_IT_INVULNERABILITY) {
                drawstring([powerup_x, y, 0], "P", font, '1 0 0', 1, 0);
                powerup_x -= char_w;
            }
            if (items & MM_IT_INVISIBILITY) {
                drawstring([powerup_x, y, 0], "R", font, '1 1 0', 1, 0);
            }

            // Best weapon: RLG (both) > RL > LG > GL. Mirrors the minimap's
            // weapon labels - RLG splits into "R" (RL color) + "LG" (LG color)
            // drawn as two adjacent strings. Left-aligned in the column so
            // RL/LG/GL/RLG all start at the same x.
            float has_rl = items & MM_IT_ROCKET_LAUNCHER;
            float has_lg = items & MM_IT_LIGHTNING;
            float has_gl = items & MM_IT_GRENADE_LAUNCHER;
            float weapon_left = weapon_right - L.weapon_w;
            if (has_rl && has_lg) {
                float r_w = stringwidth("R", 0, font);
                drawstring([weapon_left, y, 0],       "R",  font, MinimapWeaponColor(MM_IT_ROCKET_LAUNCHER), 1, 0);
                drawstring([weapon_left + r_w, y, 0], "LG", font, MinimapWeaponColor(MM_IT_LIGHTNING),       1, 0);
            } else {
                string  single_label = "";
                vector  single_color = '1 1 1';
                if (has_rl) {
                    single_label = "RL";
                    single_color = MinimapWeaponColor(MM_IT_ROCKET_LAUNCHER);
                } else if (has_lg) {
                    single_label = "LG";
                    single_color = MinimapWeaponColor(MM_IT_LIGHTNING);
                } else if (has_gl) {
                    single_label = "GL";
                    single_color = MinimapWeaponColor(MM_IT_GRENADE_LAUNCHER);
                }
                if (single_label != "") {
                    drawstring([weapon_left, y, 0], single_label, font, single_color, 1, 0);
                }
            }
        }
    }

    // Name (right-aligned within its column; drawn verbatim so color codes
    // and quake chars render natively). p_name / nw / name_x computed up front.
    drawstring([name_x, y, 0], p_name, font, '1 1 1', 1, 0);
};

// Team header row: team name on the left (plain text, vertically
// centered against the frag-box), summed frags inside a rounded
// color-split box on the right (top half = top_color, bottom half =
// bottom_color). Mirrors the score-box style in overlay.qc.
void(pi_layout_t L, vector right_top, participant_t t) PI_DrawTeamHeader =
{
    vector font   = L.font_size;
    float  box_h  = L.team_box_height;
    float  half_h = box_h * 0.5;
    float  box_w  = L.team_box_width;
    float  box_x  = right_top.x - box_w;
    vector half_size = [box_w, half_h, 0];

    HubDrawRoundedRect([box_x, right_top.y, 0],          half_size, L.team_box_radius, RR_TOP,    t.top_color,    1);
    HubDrawRoundedRect([box_x, right_top.y + half_h, 0], half_size, L.team_box_radius, RR_BOTTOM, t.bottom_color, 1);

    // Score text centered horizontally + vertically in the fixed-width box.
    string score_s = ftos(t.score);
    float  score_w = stringwidth(score_s, 0, font);
    float  score_x = box_x + (box_w - score_w) * 0.5;
    float  score_y = right_top.y + L.team_box_padding_y;
    drawstring([score_x, score_y, 0], score_s, font, '1 1 1', 1, 0);

    // Team name placed to the left of the box, vertically centered
    // against the box height.
    float name_w = stringwidth(t.name, 1, font);
    float name_x = box_x - L.col_gap - name_w;
    float name_y = right_top.y + (box_h - font.y) * 0.5;
    drawstring([name_x, name_y, 0], t.name, font, '1 1 1', 1, 0);
};

// ----- location format ------------------------------------------------------

// Inner content for the bracketed location: a fixed PI_LOC_NAME_SIZE field
// of brown ASCII (codepoint | 0x80), right-aligned with leading spaces.
// "ra" -> "   ra". Brackets and the half-char inner margins are added by
// the row draw code so they can sit at non-char-aligned x positions.
string(string raw) PI_FormatLocation =
{
    int len       = strlen(raw);
    int trunc_len = (len > PI_LOC_NAME_SIZE) ? PI_LOC_NAME_SIZE : len;
    int left_pad  = PI_LOC_NAME_SIZE - trunc_len;

    string out = "";
    for (int k = 0; k < left_pad; k++) out = strcat(out, " ");
    for (int k = 0; k < trunc_len; k++) {
        out = strcat(out, chr2str((int)str2chr(raw, k) | 128));
    }
    return out;
};

// ----- layout ---------------------------------------------------------------

void(vector view_size, __out pi_layout_t L) PI_LayoutFor =
{
    float scale = view_size.y / PI_REF_HEIGHT;
    if (scale < PI_SCALE_MIN) scale = PI_SCALE_MIN;
    if (scale > PI_SCALE_MAX) scale = PI_SCALE_MAX;
    // User multiplier applied after the viewport clamp - explicit user
    // preference overrides the auto-scaling bounds.
    if (autocvar_playerinfo_scale > 0) {
        scale = scale * autocvar_playerinfo_scale;
    }
    L.scale = scale;

    float fpx   = floor(PI_FONT_PX * scale);
    L.font_size = [fpx, fpx, 0];
    L.row_height = fpx;
    L.row_gap   = ceil(PI_ROW_GAP_PX * scale);
    L.team_gap  = ceil(PI_TEAM_GAP_PX * scale);
    L.col_gap   = stringwidth("0", 0, L.font_size);  // one char-width between columns

    L.name_w      = PI_PLAYER_NAME_MAX * stringwidth("0", 0, L.font_size);
    L.location_w  = ceil(PI_LOCATION_W_PX  * scale);
    L.health_w    = ceil(PI_HEALTH_W_PX    * scale);
    L.armor_w     = ceil(PI_ARMOR_W_PX     * scale);
    L.weapon_w    = ceil(PI_WEAPON_W_PX * scale);
    L.frags_w     = PI_FRAGS_CHARS * stringwidth("0", 0, L.font_size);

    L.team_box_padding_y = ceil(fpx * 0.5);
    L.team_box_radius    = ceil(PI_TEAM_BOX_RADIUS_PX * scale);
    L.team_box_width     = PI_TEAM_BOX_CHARS * stringwidth("0", 0, L.font_size);
    L.team_box_height    = fpx + L.team_box_padding_y * 2;
};

// Resolves the active drawfont slot. Empty cvar -> FONT_DEFAULT (engine's
// gl_font). Otherwise (re)loads the named font into a cached slot on first
// use and whenever the cvar value changes.
float() PI_FontSlot =
{
    string name = autocvar_playerinfo_font;
    if (name == "") {
        return FONT_DEFAULT;
    }
    if (name != PI_LoadedFontName) {
        if (PI_LoadedFontSlot > 0) {
            loadfont("", name, "10 12 14 16 18 20", PI_LoadedFontSlot);
        } else {
            PI_LoadedFontSlot = loadfont("", name, "10 12 14 16 18 20", -1);
        }
        PI_LoadedFontName = name;
    }
    return PI_LoadedFontSlot;
};
