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
 *     score_overlay.qc's score box style
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
 *     (codepoint | 0x80). Truncated/space-padded to 5 inner chars.
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
#define PI_MARGIN_PX           8
#define PI_BOTTOM_EXTRA_PX     128  // additional clearance above the bottom edge
#define PI_FONT_PX         10
#define PI_ROW_GAP_PX      2
#define PI_TEAM_GAP_PX     6   // extra space above each team header (except the first)

// Column widths at scale = 1. Rendered text right-aligns within its column,
// then the row right-aligns to the viewport edge.
#define PI_NAME_W_PX     128
#define PI_LOCATION_W_PX  56
#define PI_HEALTH_W_PX    24
#define PI_ARMOR_W_PX     24
#define PI_WEAPON_W_PX    24
#define PI_FRAGS_CHARS     3   // most matches are won in 2-3 digit ranges

#define PI_POWERUP_GAP_PX  2

// Team header frag-box. Fixed at 6 char-widths wide with the score centered
// horizontally; vertical padding is half a char on each side. Split top/bottom
// colors with rounded outer corners (mirrors score_overlay's score-box style).
#define PI_TEAM_BOX_CHARS         6
#define PI_TEAM_BOX_RADIUS_PX     1

// Layout cache produced by PI_LayoutFor and consumed by the draw functions.
typedef struct {
    float  scale;
    float  margin;
    float  bottom_extra;
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
    float  powerup_gap;
} pi_layout_t;

// Forward declarations so the file reads top-down.
void(vector main_size, __out pi_layout_t L)                                    PI_LayoutFor;
void()                                                                         PI_SortPlayersByName;
void()                                                                         PI_SortTeamsByName;
string(string raw)                                                             PI_FormatLocation;
void(pi_layout_t L, vector right_top, float match_active, participant_t p)     PI_DrawPlayerRow;
void(pi_layout_t L, vector right_top, participant_t t)                         PI_DrawTeamHeader;

// ----- entry points ---------------------------------------------------------

void(vector main_size, float vwidth) PlayerInfoDraw =
{
    if (serverkeyfloat("deathmatch") <= 0) {
        return;
    }

    Participants_GatherPlayers();
    if (Participants_PlayerCount == 0) {
        return;
    }

    pi_layout_t L;
    PI_LayoutFor(main_size, L);

    // Teamplay groups when at least one team is non-empty.
    float teamplay_on = serverkeyfloat("teamplay") > 0;
    float has_groups = 0;
    if (teamplay_on) {
        Participants_GatherTeams();
        has_groups = 1;
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

    float right_x = vwidth      - L.margin;
    float top_y   = main_size.y - L.margin - L.bottom_extra - total_height;

    // Live-stats gate: match running ("min left" in status) OR countdown.
    // Hidden during pre-match standby and on local listen server.
    string status = serverkey("status");
    float  match_active = (strstrofs(status, "min left", 0) >= 0
                           || !strcasecmp(status, "countdown"))
                          && !isserver();

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
        string        key_cmp = strdecolorize(key.name);
        int j = i - 1;
        while (j >= 0) {
            if (strcmp(strdecolorize(Participants_Players[j].name), key_cmp) <= 0) break;
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
        string        key_cmp = strdecolorize(key.name);
        int j = i - 1;
        while (j >= 0) {
            if (strcmp(strdecolorize(Participants_Teams[j].name), key_cmp) <= 0) break;
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
    // Extra gap between armor and health so the "/" delimiter has a
    // half-char margin on each side (total = 2 char-widths).
    float health_armor_gap = L.col_gap * 2;
    float armor_right    = health_right   - L.health_w   - health_armor_gap;
    float location_right = armor_right    - L.armor_w    - L.col_gap;
    // Extra char-width between location and name so the bracketed location
    // string has visual breathing room from the name text.
    float name_right     = location_right - L.location_w - L.col_gap * 2;

    // Name width computed up front so the powerup block can sit next to it.
    float nw = stringwidth(p.name, 1, font);
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
                string loc_bracketed = PI_FormatLocation(loc);
                float lw = stringwidth(loc_bracketed, 0, font);
                float loc_left = location_right - L.location_w;
                // White tint = preserve the charset's native colors (yellow
                // brackets, brown ASCII inside).
                drawstring([loc_left + (L.location_w - lw) * 0.5, y, 0], loc_bracketed, font, '1 1 1', 1, 0);
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
                drawstring([armor_right + (health_armor_gap - slash_w) * 0.5, y, 0], "/", font, '0.6 0.6 0.6', 1, 0);
            }

            // Health: hud_health rule - red at the low threshold (<= 25),
            // white otherwise. Right-aligned in the health column. Capped
            // at 999 so the value fits 3 digits.
            float  h_display = (health > 999) ? 999 : health;
            string h_s       = sprintf("%d", h_display);
            float  h_w     = stringwidth(h_s, 0, font);
            vector h_color = (health <= 25) ? '1 0.3 0.3' : '1 1 1';
            drawstring([health_right - h_w, y, 0], h_s, font, h_color, 1, 0);

            // Powerup icons (sb_* wad pics). Positioned to the left of the
            // rendered name with 1 char-gap. Drawn rightmost first so the
            // most important icon sits closest to the name.
            float icon_size = L.row_height;
            float icon_x    = name_x - L.col_gap - icon_size;
            if (items & MM_IT_QUAD) {
                drawpic([icon_x, y, 0], "sb_quad", [icon_size, icon_size, 0], '1 1 1', 1, 0);
                icon_x -= icon_size + L.powerup_gap;
            }
            if (items & MM_IT_INVULNERABILITY) {
                drawpic([icon_x, y, 0], "sb_invuln", [icon_size, icon_size, 0], '1 1 1', 1, 0);
                icon_x -= icon_size + L.powerup_gap;
            }
            if (items & MM_IT_INVISIBILITY) {
                drawpic([icon_x, y, 0], "sb_invis", [icon_size, icon_size, 0], '1 1 1', 1, 0);
                icon_x -= icon_size + L.powerup_gap;
            }
            if (items & MM_IT_SUIT) {
                drawpic([icon_x, y, 0], "sb_suit", [icon_size, icon_size, 0], '1 1 1', 1, 0);
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
    // and quake chars render natively). nw / name_x computed up front.
    drawstring([name_x, y, 0], p.name, font, '1 1 1', 1, 0);
};

// Team header row: team name on the left (plain text, vertically
// centered against the frag-box), summed frags inside a rounded
// color-split box on the right (top half = top_color, bottom half =
// bottom_color). Mirrors the score-box style in score_overlay.qc.
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

// Charset-styled location: Quake bracket glyphs (chars 16/17, the yellow
// rounded brackets) wrap a 5-wide field of brown ASCII (codepoint | 0x80).
// Source truncated to 5 chars, or centered with spaces when shorter (extra
// space goes to the right when the slack is odd).
string(string raw) PI_FormatLocation =
{
    int len       = strlen(raw);
    int trunc_len = (len > 5) ? 5 : len;
    int total_pad = 5 - trunc_len;
    int left_pad  = total_pad / 2;
    int right_pad = total_pad - left_pad;

    string out = chr2str(16);
    for (int k = 0; k < left_pad; k++)  out = strcat(out, " ");
    for (int k = 0; k < trunc_len; k++) {
        out = strcat(out, chr2str((int)str2chr(raw, k) | 128));
    }
    for (int k = 0; k < right_pad; k++) out = strcat(out, " ");
    return strcat(out, chr2str(17));
};

// ----- layout ---------------------------------------------------------------

void(vector main_size, __out pi_layout_t L) PI_LayoutFor =
{
    float scale = main_size.y / PI_REF_HEIGHT;
    if (scale < PI_SCALE_MIN) scale = PI_SCALE_MIN;
    if (scale > PI_SCALE_MAX) scale = PI_SCALE_MAX;
    L.scale = scale;

    L.margin       = ceil(PI_MARGIN_PX * scale);
    L.bottom_extra = ceil(PI_BOTTOM_EXTRA_PX * scale);
    float fpx   = floor(PI_FONT_PX * scale);
    L.font_size = [fpx, fpx, 0];
    L.row_height = fpx;
    L.row_gap   = ceil(PI_ROW_GAP_PX * scale);
    L.team_gap  = ceil(PI_TEAM_GAP_PX * scale);
    L.col_gap   = stringwidth("0", 0, L.font_size);  // one char-width between columns

    L.name_w      = ceil(PI_NAME_W_PX      * scale);
    L.location_w  = ceil(PI_LOCATION_W_PX  * scale);
    L.health_w    = ceil(PI_HEALTH_W_PX    * scale);
    L.armor_w     = ceil(PI_ARMOR_W_PX     * scale);
    L.weapon_w    = ceil(PI_WEAPON_W_PX * scale);
    L.frags_w     = PI_FRAGS_CHARS * stringwidth("0", 0, L.font_size);
    L.powerup_gap = ceil(PI_POWERUP_GAP_PX * scale);

    L.team_box_padding_y = ceil(fpx * 0.5);
    L.team_box_radius    = ceil(PI_TEAM_BOX_RADIUS_PX * scale);
    L.team_box_width     = PI_TEAM_BOX_CHARS * stringwidth("0", 0, L.font_size);
    L.team_box_height    = fpx + L.team_box_padding_y * 2;
};
