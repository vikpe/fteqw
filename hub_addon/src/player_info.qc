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

// Pixel sizes at scale = 1. Base font matches ezhud's 8x8 conchar so a
// numeric scale value renders the same height in both: an ezhud element
// at hud_*_scale 2 and a playerinfo at playerinfo_scale 2 both produce
// 16px-tall text. No viewport auto-scaling - readability across
// viewports is the user's job via playerinfo_scale.
#define PI_FONT_PX         8
#define PI_TEAM_GAP_PX     3   // extra space above each team header (except the first)

// Web app overlays a demo time slider along the bottom of the FTE viewport
// during demo playback; reserve extra vertical margin so the widget clears
// it. Value = slider rendered height (28px) + BASE_BOTTOM_MARGIN_PX in
// DemoTimeSlider.tsx (4px, mb-1 / 1 tailwind unit). Keep in sync if
// either changes.
#define DEMO_TIMESLIDER_HEIGHT_PX 36

// User cvars (registered automatically via autocvar_ prefix).
// playerinfo 0/1                   - master enable
// playerinfo_margin "X Y"          - margin in design pixels at scale = 1
// playerinfo_scale                 - scale multiplier on every dimension.
//                                    Matches ezhud's hud_*_scale convention:
//                                    1 = 8px text, 2 = 16px, etc.
// playerinfo_font                  - font name; empty = engine default (gl_font)
// playerinfo_player_padding "X Y"  - per-row padding (inflates row hit zone +
//                                    highlight box; replaces the inter-row gap)
// playerinfo_track_color "R G B A" - tracked-player row highlight (R G B A floats
//                                    0..1). The seat owning the clicked row tracks
//                                    that player; this highlights which row matches.
// playerinfo_frame_color "R G B A" - frame color + alpha, RGB 0-255, A 0-1
//                                    Alpha == 0 disables the frame.
// playerinfo_frame_padding "X Y"   - inner padding around the content, design px
var float  autocvar_playerinfo                = 1;
var vector autocvar_playerinfo_margin         = '16 16 0';
var float  autocvar_playerinfo_scale          = 1;
var string autocvar_playerinfo_font           = "";
var vector autocvar_playerinfo_player_padding = '0 1 0';
var string autocvar_playerinfo_track_color    = "0 0 0 0.5";
var string autocvar_playerinfo_frame_color    = "0 0 0 0";
var vector autocvar_playerinfo_frame_padding  = '8 8 0';

// Cached font slot. Reloaded only when the cvar value changes.
string PI_LoadedFontName;
float  PI_LoadedFontSlot;

// Column widths at scale = 1. Rendered text right-aligns within its column,
// then the row right-aligns to the viewport edge.
#define PI_LOCATION_W_PX  45
#define PI_HEALTH_W_PX    19
#define PI_ARMOR_W_PX     19
#define PI_WEAPON_W_PX    19
#define PI_FRAGS_CHARS     3   // most matches are won in 2-3 digit ranges
#define PI_LOC_NAME_SIZE   5   // inner chars between the location brackets
#define PI_PLAYER_NAME_MAX 10  // visible-char cap on player names (markup-stripped)

// Team header frag-box. Geometry mirrors ezhud's hud_score_bar2 defaults
// so the standalone score bar and the team-grouped player info line up
// visually: frag_padding 4 4 (inner space around the score text), 3-digit
// minimum content width (so 1- and 2-digit scores share the same box
// size as 3-digit ones), 1px rounded corners. Top/bottom halves carry
// the team's shirt/pants colors.
#define PI_TEAM_BOX_FRAG_PAD_X    4
#define PI_TEAM_BOX_FRAG_PAD_Y    4
#define PI_TEAM_BOX_MIN_CHARS     3
#define PI_TEAM_BOX_RADIUS_PX     1

// Layout cache produced by PI_LayoutFor and consumed by the draw functions.
typedef struct {
    float  scale;
    vector font_size;
    float  row_height;          // player row outer height (= font_size.y + 2*player_pad.y)
    float  team_box_min_w;      // floor for the team frag-box width (min-chars * char_w + pad_x*2)
    float  team_box_height;     // font_size.y + team_box_pad_y*2
    float  team_box_pad_x;      // ezhud hud_score_bar2 frag_padding.x * scale
    float  team_box_pad_y;      // ezhud hud_score_bar2 frag_padding.y * scale
    float  team_box_radius;
    vector player_pad;          // per-row inner padding (x = horizontal, y = vertical)
    float  team_gap;
    float  col_gap;
    float  name_w;
    float  location_w;
    float  health_w;
    float  armor_w;
    float  weapon_w;
    float  frags_w;
} pi_layout_t;

// Per-seat per-row hit rect. PlayerInfoBeginFrame clears the table once
// per CSQC_UpdateView; each seat's PlayerInfoDraw appends. Click dispatch
// (PlayerInfoInputEvent) walks the populated list to find seat + slot under
// the cursor and emits "trackN <userid>". The table survives across the
// inter-frame window where input events fire (between UpdateView calls),
// so the time global advancing between the two doesn't matter.
#define PI_MAX_HITS (PARTICIPANT_MAX * 4)   // 32 players * 4 seats
typedef struct {
    vector pos;
    vector size;
    float  slot;    // 0-based engine player slot
    float  seat;    // 0-based splitscreen seat
} pi_hit_t;
var pi_hit_t pi_hits[PI_MAX_HITS];
float pi_hit_count;

// Forward declarations so the file reads top-down.
void(vector view_size, __out pi_layout_t L)                                                                PI_LayoutFor;
void()                                                                                                     PI_SortPlayersByName;
void()                                                                                                     PI_SortTeamsByName;
string(string raw)                                                                                         PI_FormatLocation;
float(pi_layout_t L, float score)                                                                          PI_TeamBoxWidth;
void(pi_layout_t L, vector right_top, float content_width, float seat, float tracked_slot, float match_active, float is_single_pov, participant_t player) PI_DrawPlayerRow;
void(pi_layout_t L, vector right_top, participant_t team)                                                                              PI_DrawTeamHeader;
float()                                                                                                    PI_FontSlot;

// ----- entry points ---------------------------------------------------------

// Called once per CSQC_UpdateView frame, before the per-seat loop. Clears
// the hit table so each seat's PlayerInfoDraw can append fresh rows.
void() PlayerInfoBeginFrame =
{
    pi_hit_count = 0;
};

// Drawn once per splitscreen seat. `seat` is the 0-based splitscreen seat
// index (cl.playerview slot); used as the row's seat tag for click dispatch
// and to read this seat's tracked player via player_localentnum (the caller
// must setviewprop(VF_ACTIVESEAT, seat) before invoking us).
void(float seat, vector view_min, vector view_size) PlayerInfoDraw =
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

    // Tracked player slot for this seat. player_localentnum is 1-based and
    // reflects the active seat's viewed entity; -1 means free-fly / no track.
    float tracked_slot = -1;
    if (player_localentnum >= 1 && player_localentnum <= maxclients) {
        tracked_slot = player_localentnum - 1;
    }

    // Teamplay groups when teamplay is on AND every team has a non-empty
    // name. Otherwise fall back to a flat player list. Participants_Gather
    // resolved the protocol-specific teamplay detection (QW serverkey vs
    // NQ "exactly 2 pants colors") into Participants_IsTeamplay.
    float has_groups = Participants_IsTeamplay;
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
    // taller than player rows (they carry the frag-box). Player rows
    // include vertical padding in row_height; no inter-row gap.
    float total_height;
    if (has_groups) {
        total_height = Participants_TeamCount * L.team_box_height
                     + Participants_PlayerCount * L.row_height;
        if (Participants_TeamCount > 1) {
            total_height += (Participants_TeamCount - 1) * L.team_gap;
        }
    } else {
        total_height = Participants_PlayerCount * L.row_height;
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
    float anchor_right = view_min.x + view_size.x - margin_x;
    float anchor_top   = view_min.y + view_size.y - margin_y - total_height;

    // Single-POV demos (QWD, NQ .dem, single-slot MVD wraps) only carry
    // STAT_ITEMS / STAT_HEALTH / STAT_ARMOR and origin updates for the
    // one recording client. Trying to draw the live-stats block (location,
    // armor, health, weapon) for any other player would print zeroed /
    // stale values, so collapse the row to name + frags in that case.
    // Engine-resolved by Hub_IsSinglePovDemo, exposed via pr_clcmd.c's
    // serverkey switch.
    float is_single_pov = serverkeyfloat("demo_is_single_pov") > 0;

    // Row content width: widest of (player row content) and (team header
    // content). Powerups extend leftward outside the column block but
    // are included so the hit rect / highlight wraps them too. Used by the
    // background frame, the tracked-row highlight, and the per-row hit rect.
    float max_name_width = 0;
    for (int i = 0; i < Participants_PlayerCount; i++) {
        string truncated_name  = MinimapColoredPrefix(Participants_Players[i].name, PI_PLAYER_NAME_MAX);
        float  truncated_width = stringwidth(truncated_name, 1, L.font_size);
        if (truncated_width > L.name_w) truncated_width = L.name_w;
        if (truncated_width > max_name_width) max_name_width = truncated_width;
    }
    float content_width;
    if (is_single_pov) {
        // Slim row: name | frags. No powerups, location, armor, health
        // or weapon column - we don't have the stats to populate them.
        content_width = max_name_width + L.col_gap + L.frags_w;
    } else {
        // A player can carry at most 3 powerups at once (Q/P/R). Each
        // glyph is one char-width, no margin between them; col_gap
        // separates the rightmost glyph from the name.
        float powerups_width = 3 * stringwidth("Q", 0, L.font_size) + L.col_gap;
        content_width = powerups_width
                      + max_name_width
                      + L.col_gap * 3   + L.location_w
                      + L.col_gap       + L.armor_w
                      + L.col_gap * 1.5 + L.health_w
                      + L.col_gap       + L.weapon_w
                      + L.col_gap       + L.frags_w;
    }
    if (has_groups) {
        for (int g = 0; g < Participants_TeamCount; g++) {
            float team_name_width = stringwidth(Participants_Teams[g].name, 1, L.font_size);
            float team_box_width  = PI_TeamBoxWidth(L, Participants_Teams[g].score);
            float team_row_width  = team_name_width + L.col_gap + team_box_width;
            if (team_row_width > content_width) content_width = team_row_width;
        }
    }

    // Background frame. Alpha == 0 disables the frame entirely.
    {
        float  frame_argc  = tokenize(autocvar_playerinfo_frame_color);
        float  frame_red   = (frame_argc >= 1) ? stof(argv(0)) : 0;
        float  frame_green = (frame_argc >= 2) ? stof(argv(1)) : 0;
        float  frame_blue  = (frame_argc >= 3) ? stof(argv(2)) : 0;
        float  frame_alpha = (frame_argc >= 4) ? stof(argv(3)) : 0;

        if (frame_alpha > 0) {
            float  frame_pad_x = autocvar_playerinfo_frame_padding.x * L.scale;
            float  frame_pad_y = autocvar_playerinfo_frame_padding.y * L.scale;
            vector frame_pos   = [anchor_right - content_width - frame_pad_x, anchor_top - frame_pad_y, 0];
            vector frame_size  = [content_width + frame_pad_x * 2,
                                  total_height + frame_pad_y * 2, 0];
            vector frame_rgb   = [frame_red, frame_green, frame_blue] / 255;
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

    vector cursor = [anchor_right, anchor_top, 0];
    if (has_groups) {
        for (int g = 0; g < Participants_TeamCount; g++) {
            if (g > 0) cursor.y += L.team_gap;
            PI_DrawTeamHeader(L, cursor, Participants_Teams[g]);
            cursor.y += L.team_box_height;
            for (int i = 0; i < Participants_PlayerCount; i++) {
                if (Participants_Players[i].team != Participants_Teams[g].name) continue;
                PI_DrawPlayerRow(L, cursor, content_width, seat, tracked_slot, match_active, is_single_pov, Participants_Players[i]);
                cursor.y += L.row_height;
            }
        }
    } else {
        for (int i = 0; i < Participants_PlayerCount; i++) {
            PI_DrawPlayerRow(L, cursor, content_width, seat, tracked_slot, match_active, is_single_pov, Participants_Players[i]);
            cursor.y += L.row_height;
        }
    }

    drawfont = prev_font;
};

// Click dispatch. Walks the per-frame hit table for a row under the cursor,
// emits "track_userid <userid>" for the clicked player, and locks autotrack
// to user-mode so it doesn't reclaim the camera. Routed from main.qc's
// CSQC_InputEvent chain. Returns 1 (consume) on hit, 0 (passthrough) on miss.
float(float evtype, float scanx, float chary, float devid) PlayerInfoInputEvent =
{
    if (!autocvar_playerinfo) return 0;
    if (evtype != IE_KEYDOWN || scanx != K_MOUSE1) return 0;

    // Single-POV demos (QWD, NQ .dem, single-slot MVD wraps) lock the
    // view to the recording client; there's nothing meaningful to track.
    // Silently consume the click so downstream input handlers don't
    // react either. Engine-resolved by Hub_IsSinglePovDemo, exposed via
    // pr_clcmd.c's serverkey switch.
    if (serverkeyfloat("demo_is_single_pov") > 0) return 1;

    vector cursor_pos = getmousepos();
    for (int i = 0; i < pi_hit_count; i++) {
        if (cursor_pos.x < pi_hits[i].pos.x || cursor_pos.x >= pi_hits[i].pos.x + pi_hits[i].size.x) continue;
        if (cursor_pos.y < pi_hits[i].pos.y || cursor_pos.y >= pi_hits[i].pos.y + pi_hits[i].size.y) continue;
        // "userid" is special-cased in the engine's getplayerkey lookup
        // (engine/client/pr_csqc.c:4508). "*userid" would fall through to
        // the infobuf and return empty.
        string userid = getplayerkeyvalue(pi_hits[i].slot, "userid");
        if (userid == "") return 1;
        // track_userid (cl_cam.c:Cam_TrackUserid_f) takes a numeric
        // userid only - no nick fallback, no "#sortidx" branch - so a
        // player with a digit-shaped nick can't be misresolved. It also
        // flips autotrackmode to TM_USER on every explicit pick, so
        // manual control survives until the user issues `autotrack`
        // again.
        localcmd(sprintf("track_userid %s\n", userid));
        return 1;
    }
    return 0;
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
// right_top.x is the row's right edge (widget right margin); right_top.y is
// its top edge. The row outer block extends content_w + 2*player_pad.x
// horizontally and L.row_height vertically; content draws inset by player_pad.
// Stats are skipped when match_active is 0. Tracked-row highlight + the hit
// rect for click dispatch both span the full outer block.
void(pi_layout_t L, vector right_top, float content_width, float seat, float tracked_slot, float match_active, float is_single_pov, participant_t player) PI_DrawPlayerRow =
{
    vector font = L.font_size;

    // Outer block (highlight + hit zone). Content right-aligns to
    // right_top.x - player_pad.x; content vertically offset by player_pad.y.
    float  outer_width    = content_width + L.player_pad.x * 2;
    vector outer_pos      = [right_top.x - outer_width, right_top.y, 0];
    vector outer_size     = [outer_width, L.row_height, 0];
    float  content_right_x = right_top.x - L.player_pad.x;
    float  content_y      = right_top.y + L.player_pad.y;

    // Tracked-player highlight (drawn under the row content). Parse track_color
    // each call - cheap, lets users tweak live; partial input falls back to
    // opaque black.
    if (player.slot == tracked_slot) {
        float  track_argc  = tokenize(autocvar_playerinfo_track_color);
        float  track_red   = (track_argc >= 1) ? stof(argv(0)) : 0;
        float  track_green = (track_argc >= 2) ? stof(argv(1)) : 0;
        float  track_blue  = (track_argc >= 3) ? stof(argv(2)) : 0;
        float  track_alpha = (track_argc >= 4) ? stof(argv(3)) : 1;
        drawfill(outer_pos, outer_size, [track_red, track_green, track_blue], track_alpha);
    }

    // Record click target. Drop frames silently if the table is full -
    // PI_MAX_HITS is sized for MAX_CLIENTS * MV_VIEWS, which already covers
    // the max simultaneously-visible rows.
    if (pi_hit_count < PI_MAX_HITS) {
        pi_hits[pi_hit_count].pos  = outer_pos;
        pi_hits[pi_hit_count].size = outer_size;
        pi_hits[pi_hit_count].slot = player.slot;
        pi_hits[pi_hit_count].seat = seat;
        pi_hit_count++;
    }

    // Walk right -> left, each column anchored to its right edge.
    // Full layout: [powerups] | name | location | armor | health | weapon | frags.
    // Single-POV layout (no per-non-POV-player stats): name | frags only.
    float frags_right    = content_right_x;
    float name_right;
    float weapon_right   = 0;
    float health_right   = 0;
    float armor_right    = 0;
    float location_right = 0;
    if (is_single_pov) {
        name_right = frags_right - L.frags_w - L.col_gap;
    } else {
        weapon_right   = frags_right    - L.frags_w    - L.col_gap;
        health_right   = weapon_right   - L.weapon_w   - L.col_gap;
        // armor | slash | 0.5 col_gap | health: slash sits flush
        // against armor's right edge (no margin), then a half col_gap
        // before the health column. The slash itself is one char wide,
        // so total armor-to-health distance is 1.5 * col_gap.
        armor_right    = health_right   - L.health_w   - L.col_gap * 1.5;
        location_right = armor_right    - L.armor_w    - L.col_gap;
        // Two extra char-widths between location and name on top of the
        // regular col_gap, so the bracketed location string has clear
        // breathing room from the name text.
        name_right     = location_right - L.location_w - L.col_gap * 3;
    }

    // Name truncated to PI_PLAYER_NAME_MAX visible chars (markup preserved).
    // Width computed up front so the powerup block can sit next to it.
    string player_name       = MinimapColoredPrefix(player.name, PI_PLAYER_NAME_MAX);
    float  player_name_width = stringwidth(player_name, 1, font);
    if (player_name_width > L.name_w) player_name_width = L.name_w;
    float  name_x            = name_right - player_name_width;

    // Frags (always shown).
    string frags_text       = ftos(player.score);
    float  frags_text_width = stringwidth(frags_text, 0, font);
    drawstring([frags_right - frags_text_width, content_y, 0], frags_text, font, '1 1 1', 1, 0);

    // Live stats: location, health/armor, best weapon. Single-POV demos
    // only have these for the recording client, so the whole block is
    // skipped (matches the collapsed name-only column layout above).
    if (match_active && !is_single_pov) {
        vector origin = getentity(player.slot + 1, GE_ORIGIN);
        if (origin != '0 0 0') {
            string location_name = getlocationname(origin);
            if (location_name != "") {
                // Three pieces: open-bracket | content | close-bracket, with
                // a half-char gap between each bracket and the content so the
                // brackets aren't crammed against the text.
                string location_inner       = PI_FormatLocation(location_name);
                float  location_inner_width = stringwidth(location_inner, 0, font);
                float  bracket_width        = stringwidth(chr2str(16), 0, font);
                float  half_char_width      = font.x * 0.5;
                float  location_total_width = bracket_width + half_char_width + location_inner_width + half_char_width + bracket_width;
                float  location_open_x      = location_right - location_total_width;
                float  location_content_x   = location_open_x + bracket_width + half_char_width;
                float  location_close_x     = location_content_x + location_inner_width + half_char_width;
                drawstring([location_open_x,    content_y, 0], chr2str(16),    font, '1 1 1', 1, 0);
                drawstring([location_content_x, content_y, 0], location_inner, font, '1 1 1', 1, 0);
                drawstring([location_close_x,   content_y, 0], chr2str(17),    font, '1 1 1', 1, 0);
            }
        }

        // Dead-player gate: an active player entity with the player model.
        // Mirrors minimap_players.qc - matches gib/corpse/disconnect states
        // that STAT_HEALTH alone wouldn't catch.
        float health             = getplayerstat(player.slot, STAT_HEALTH, EV_FLOAT);
        float entity_active      = getentity(player.slot + 1, GE_ACTIVE);
        float entity_model_index = getentity(player.slot + 1, GE_MODELINDEX);
        float player_model_index = getmodelindex("progs/player.mdl");
        if (entity_active && entity_model_index == player_model_index && health > 0) {
            int    items = getplayerstat(player.slot, STAT_ITEMS, EV_INTEGER);
            float  armor = getplayerstat(player.slot, STAT_ARMOR, EV_FLOAT);

            // Armor: own column, omitted at 0. Tinted by armor type
            // (GA green, YA yellow, RA red).
            if (armor > 0) {
                string armor_value = sprintf("%d", armor);
                float  armor_width = stringwidth(armor_value, 0, font);
                vector armor_color = '1 1 1';
                if      (items & MM_IT_ARMOR3) armor_color = '1 0.3 0.3';
                else if (items & MM_IT_ARMOR2) armor_color = '1 1 0.3';
                else if (items & MM_IT_ARMOR1) armor_color = '0.3 1 0.3';
                drawstring([armor_right - armor_width, content_y, 0],
                           armor_value, font, armor_color, 1, 0);
                // Slash flush in the col_gap between armor and health,
                // no extra margin on either side.
                drawstring([armor_right, content_y, 0],
                           "/", font, '0.6 0.6 0.6', 0.75, 0);
            }

            // Health: hud_health rule - red at the low threshold (<= 25),
            // white otherwise. Right-aligned in the health column. Capped
            // at 999 so the value fits 3 digits.
            float  health_display    = (health > 999) ? 999 : health;
            string health_text       = sprintf("%d", health_display);
            float  health_text_width = stringwidth(health_text, 0, font);
            vector health_color      = (health <= 25) ? '1 0.3 0.3' : '1 1 1';
            drawstring([health_right - health_text_width, content_y, 0], health_text, font, health_color, 1, 0);

            // Powerup glyphs: single colored chars, no inter-char margin.
            // Q = quad (blue), P = pent (red), R = ring (yellow). Drawn
            // rightmost first so the highest-priority one sits closest
            // to the name.
            float char_width = stringwidth("Q", 0, font);
            float powerup_x  = name_x - L.col_gap - char_width;
            if (items & MM_IT_QUAD) {
                drawstring([powerup_x, content_y, 0], "Q", font, '0.38 0.65 0.98', 1, 0);
                powerup_x -= char_width;
            }
            if (items & MM_IT_INVULNERABILITY) {
                drawstring([powerup_x, content_y, 0], "P", font, '1 0 0', 1, 0);
                powerup_x -= char_width;
            }
            if (items & MM_IT_INVISIBILITY) {
                drawstring([powerup_x, content_y, 0], "R", font, '1 1 0', 1, 0);
            }

            // Best weapon: RLG (both) > RL > LG > GL. Mirrors the minimap's
            // weapon labels - RLG splits into "R" (RL color) + "LG" (LG color)
            // drawn as two adjacent strings. Left-aligned in the column so
            // RL/LG/GL/RLG all start at the same x.
            float has_rl      = items & MM_IT_ROCKET_LAUNCHER;
            float has_lg      = items & MM_IT_LIGHTNING;
            float has_gl      = items & MM_IT_GRENADE_LAUNCHER;
            float weapon_left = weapon_right - L.weapon_w;
            if (has_rl && has_lg) {
                float r_letter_width = stringwidth("R", 0, font);
                drawstring([weapon_left,                  content_y, 0], "R",  font, MinimapWeaponColor(MM_IT_ROCKET_LAUNCHER), 1, 0);
                drawstring([weapon_left + r_letter_width, content_y, 0], "LG", font, MinimapWeaponColor(MM_IT_LIGHTNING),       1, 0);
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
                    drawstring([weapon_left, content_y, 0], single_label, font, single_color, 1, 0);
                }
            }
        }
    }

    // Name (right-aligned within its column; drawn verbatim so color codes
    // and quake chars render natively). Computed up front along with
    // player_name_width / name_x.
    drawstring([name_x, content_y, 0], player_name, font, '1 1 1', 1, 0);
};

// Team header row: team name on the left (plain text, vertically
// centered against the frag-box), summed frags inside a rounded
// color-split box on the right (top half = top_color, bottom half =
// bottom_color). Mirrors the score-box style in overlay.qc.
void(pi_layout_t L, vector right_top, participant_t team) PI_DrawTeamHeader =
{
    vector font        = L.font_size;
    float  box_height  = L.team_box_height;
    float  half_height = box_height * 0.5;
    float  box_width   = PI_TeamBoxWidth(L, team.score);
    float  box_x       = right_top.x - box_width;
    vector half_size   = [box_width, half_height, 0];

    HubDrawRoundedRect([box_x, right_top.y, 0],               half_size, L.team_box_radius, RR_TOP,    team.top_color,    1);
    HubDrawRoundedRect([box_x, right_top.y + half_height, 0], half_size, L.team_box_radius, RR_BOTTOM, team.bottom_color, 1);

    // Score text centered horizontally + vertically inside the box.
    string score_text  = ftos(team.score);
    float  score_width = stringwidth(score_text, 0, font);
    float  score_x     = box_x + (box_width - score_width) * 0.5;
    float  score_y     = right_top.y + L.team_box_pad_y;
    drawstring([score_x, score_y, 0], score_text, font, '1 1 1', 1, 0);

    // Team name placed to the left of the box, vertically centered
    // against the box height.
    float name_width = stringwidth(team.name, 1, font);
    float name_x     = box_x - L.col_gap - name_width;
    float name_y     = right_top.y + (box_height - font.y) * 0.5;
    drawstring([name_x, name_y, 0], team.name, font, '1 1 1', 1, 0);
};

// Box width sized like ezhud's hud_score_bar2 frag swatches: max of
// (score text width + frag_padding.x * 2) and the 3-digit minimum.
float(pi_layout_t L, float score) PI_TeamBoxWidth =
{
    float score_w   = stringwidth(ftos(score), 0, L.font_size);
    float content_w = score_w + L.team_box_pad_x * 2;
    return content_w > L.team_box_min_w ? content_w : L.team_box_min_w;
};

// ----- location format ------------------------------------------------------

// Inner content for the bracketed location: a fixed PI_LOC_NAME_SIZE field
// of brown ASCII (codepoint | 0x80), right-aligned with leading spaces.
// "ra" -> "   ra". Brackets and the half-char inner margins are added by
// the row draw code so they can sit at non-char-aligned x positions.
string(string raw) PI_FormatLocation =
{
    int raw_length        = strlen(raw);
    int truncated_length  = (raw_length > PI_LOC_NAME_SIZE) ? PI_LOC_NAME_SIZE : raw_length;
    int left_padding      = PI_LOC_NAME_SIZE - truncated_length;

    string result = "";
    for (int k = 0; k < left_padding; k++) result = strcat(result, " ");
    for (int k = 0; k < truncated_length; k++) {
        result = strcat(result, chr2str((int)str2chr(raw, k) | 128));
    }
    return result;
};

// ----- layout ---------------------------------------------------------------

void(vector view_size, __out pi_layout_t L) PI_LayoutFor =
{
    // Raw user scale, matching ezhud's hud_*_scale convention. The
    // viewport dimension intentionally isn't an input - sizing should
    // be predictable from the cvar alone, identical to every ezhud
    // element. Defaults to 1 when unset or negative.
    float scale = autocvar_playerinfo_scale;
    if (scale <= 0) scale = 1;
    L.scale = scale;

    float font_px = floor(PI_FONT_PX * scale);
    L.font_size = [font_px, font_px, 0];
    // player_pad cvar is in design pixels; scale to match the rest of the
    // layout. row_height already includes the vertical padding so the loop
    // can stride row_height per row without a separate gap term.
    L.player_pad = [ceil(autocvar_playerinfo_player_padding.x * scale),
                    ceil(autocvar_playerinfo_player_padding.y * scale), 0];
    L.row_height = font_px + L.player_pad.y * 2;
    L.team_gap  = ceil(PI_TEAM_GAP_PX * scale);
    L.col_gap   = stringwidth("0", 0, L.font_size);  // one char-width between columns

    L.name_w      = PI_PLAYER_NAME_MAX * stringwidth("0", 0, L.font_size);
    L.location_w  = ceil(PI_LOCATION_W_PX  * scale);
    L.health_w    = ceil(PI_HEALTH_W_PX    * scale);
    L.armor_w     = ceil(PI_ARMOR_W_PX     * scale);
    L.weapon_w    = ceil(PI_WEAPON_W_PX * scale);
    L.frags_w     = PI_FRAGS_CHARS * stringwidth("0", 0, L.font_size);

    L.team_box_pad_x  = ceil(PI_TEAM_BOX_FRAG_PAD_X * scale);
    L.team_box_pad_y  = ceil(PI_TEAM_BOX_FRAG_PAD_Y * scale);
    L.team_box_radius = ceil(PI_TEAM_BOX_RADIUS_PX  * scale);
    L.team_box_height = font_px + L.team_box_pad_y * 2;
    L.team_box_min_w  = PI_TEAM_BOX_MIN_CHARS * stringwidth("0", 0, L.font_size)
                      + L.team_box_pad_x * 2;
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
