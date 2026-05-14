// SPDX-License-Identifier: 0BSD

/*
 * Minimap player overlay: name normalization, label prefix logic,
 * per-player marker (disc + ring + arrowhead), health/armor bars,
 * weapon labels, and the doppelganger pass that draws occluded players
 * through walls.
 */

// Forward declarations (top-down ordering).
float(vector cam_origin, vector player_origin) MinimapPlayerOccluded;
vector(float pnum)                             MinimapPlayerColor;
void()                                         MinimapBuildPlayerLabels;
string(float pi)                               MinimapShortestUniquePrefix;
string(string colored, float n_visible)        MinimapColoredPrefix;
string(string raw)                             MinimapNormalizeName;

// ----- entry points (called from minimap.qc:MinimapRender) ------------------

// 2D player overlay drawn over the minimap scene after renderscene.
void(vector cam_origin) MinimapDrawPlayers =
{
    // Hard-coded fallbacks ensure markers render even when cvars are left at
    // 0 (e.g. from a stale config).
    float radius      = autocvar_minimap_player_radius         > 0 ? autocvar_minimap_player_radius         : 7;
    float alpha_occ   = autocvar_minimap_player_alpha > 0 ? autocvar_minimap_player_alpha : 0.5;
    // Name labels use a cvar-controlled font size; weapon labels are fixed
    // at the same reduced size. Both default to 6 (25% smaller than 8).
    float name_font_size = autocvar_minimap_player_name_size > 0
                           ? autocvar_minimap_player_name_size : 6;
    vector label_size  = [name_font_size, name_font_size, 0];
    vector weapon_size = '6 6 0';

    // Hide HUD-style indicators (health/armor/powerups/weapons) while the
    // match isn't ongoing. The server's status string only contains "min left"
    // once the round is actually running (standby/countdown have other text).
    float match_active = strstrofs(serverkey("status"), "min left", 0) >= 0;

    MinimapBuildPlayerLabels();

    // Highlight the player the main view is tracking when there is one.
    // Skipped in FULL mode since there is no main view to correlate with.
    float highlight_enabled = autocvar_minimap_mode != MINIMAP_FULL;
    vector highlight_color  = '0 1 1';  // #00ffff

    float player_model_index = getmodelindex("progs/player.mdl");
    float is_demo            = isdemo();

    for (int i = 1; i <= maxclients; i++) {
        float player_index = i - 1;
        // Slot must have a name (so it's connected).
        string player_name = getplayerkeyvalue(player_index, "name");
        if (player_name == "") {
            continue;
        }
        // Spectators have userinfo but no playable entity.
        if (stof(getplayerkeyvalue(player_index, "*spectator")) > 0) {
            continue;
        }
        // Mirrors bindings.cpp:getPlayers: on demo playback, post-match
        // ghost slots can linger with no frags and zeroed colors. Drop them.
        if (is_demo
            && stof(getplayerkeyvalue(player_index, "frags"))       < 1
            && stof(getplayerkeyvalue(player_index, "topcolor"))    == 0
            && stof(getplayerkeyvalue(player_index, "bottomcolor")) == 0) {
            continue;
        }
        // Require an active player entity. Without this, slots whose entity
        // hasn't synced (typical for QTV during gaps) get phantom markers
        // even though the renderer has no model to draw.
        float active = getentity(i, GE_ACTIVE);
        if (!active) {
            continue;
        }
        float model_index = getentity(i, GE_MODELINDEX);
        if (model_index != player_model_index) {
            continue;
        }
        vector origin = getentity(i, GE_ORIGIN);
        // Origin at world zero usually means the entity slot exists but the
        // server hasn't placed it yet (mid-respawn, mid-pickup, sync gap).
        // Skip - the renderer won't draw the model there either.
        if (origin == '0 0 0') {
            continue;
        }
        vector angles = getentity(i, GE_ANGLES);

        // 2D overlay is drawn after renderscene without depth test, so the
        // marker is always visible. Mirrors main.qc:301's xray occlusion
        // test: trace from the minimap camera straight at the player. If
        // the hit point falls inside a cull volume, the geometry there is
        // hidden in the render, so we advance past the volume and retry.
        vector head = [origin.x, origin.y, origin.z + 24];
        vector trace_from = cam_origin;
        float steps = 8;
        while (steps > 0) {
            steps--;
            traceline(trace_from, head, MOVE_NORMAL | MOVE_NOMONSTERS, world);
            if (trace_fraction == 1) {
                break;  // unobstructed line of sight
            }
            float vol = MinimapPointInCullVolume(trace_endpos);
            if (vol < 0) {
                break;  // genuine occlusion
            }
            // Hit geometry inside a cull volume. Resume just under it.
            trace_from = [trace_endpos.x, trace_endpos.y, minimap_volumes[vol].mins.z - 1];
            if (trace_from.z <= head.z) {
                break;  // descended past the target, treat as visible
            }
        }

        vector screen = project(origin);
        vector color  = MinimapPlayerColor(player_index);

        // One ring per player: tracked POV gets a cyan, thicker outline
        // with a fuller alpha halo at the center. Everyone else gets a
        // regular team-colored ring.
        float  is_tracked   = highlight_enabled && i == player_localentnum;
        float  ring_radius  = radius;
        float  disc_radius  = ring_radius;
        vector ring_color   = is_tracked ? highlight_color : color;
        float  ring_thick   = is_tracked ? 1.5 : 1;

        // Tracked: fuller alpha at center (gradient still fades out to the
        // ring edge) so the disc reads as more "filled in" without growing
        // past the outline.
        float disc_center_alpha = is_tracked ? 1 : 0.5;
        MinimapDrawDisc(screen, disc_radius, ring_color, disc_center_alpha, 0);
        MinimapDrawRing(screen, ring_radius, ring_color, 1, ring_thick);

        // Active powerups (server sets EF_BLUE for Quad, EF_RED for Pent;
        // both may be set). Icons are drawn later, to the left of the bars.
        // Suppressed entirely outside of an ongoing match.
        float effects = getentity(i, GE_EFFECTS);
        float has_quad = match_active && ((int)effects & EF_BLUE);
        float has_pent = match_active && ((int)effects & EF_RED);

        // Look direction arrowhead sitting on the ring's edge. With camera
        // looking straight down (pitch 90, yaw 0), AngleVectors gives
        // right=(0,-1,0) and up=(1,0,0), so world +X projects to screen up
        // and world +Y to screen left. World yaw maps to screen direction
        //   dx = -sin(yaw), dy = -cos(yaw)   (screen Y points down).
        float world_yaw = angles.y * M_PI / 180.0;
        float dx = -sin(world_yaw);
        float dy = -cos(world_yaw);
        float tri_size  = ring_radius * 0.4 + 1;
        float half_base = tri_size * 0.5;
        float base_dist = ring_radius;
        vector tip = [screen.x + dx * (base_dist + tri_size),
                      screen.y + dy * (base_dist + tri_size), 0];
        vector base1 = [screen.x + dx * base_dist - dy * half_base,
                        screen.y + dy * base_dist + dx * half_base, 0];
        vector base2 = [screen.x + dx * base_dist + dy * half_base,
                        screen.y + dy * base_dist - dx * half_base, 0];
        R_BeginPolygon("minimap_fill_v3", 0, 1);
        R_PolygonVertex(tip,   '0 0 0', ring_color, 1);
        R_PolygonVertex(base1, '0 0 0', ring_color, 1);
        R_PolygonVertex(base2, '0 0 0', ring_color, 1);
        R_EndPolygon();

        // Label is either a fixed-length visible-char prefix (when
        // minimap_player_name_length > 0) or the shortest prefix unique to
        // this player. Both forms keep any ^X markup in front of each kept
        // char so drawstring can recolor them.
        string label;
        if (autocvar_minimap_player_name_length > 0) {
            label = MinimapColoredPrefix(minimap_label_name[player_index], autocvar_minimap_player_name_length);
        } else {
            label = MinimapShortestUniquePrefix(player_index);
        }
        // Name label centered on the player marker; powerup icons sit to its
        // left as a prefix (do not shift the name).
        float icon_count = (has_quad ? 1 : 0) + (has_pent ? 1 : 0);
        float icon_h = label_size.y;
        float icon_w = icon_h;
        float icon_gap = icon_count > 0 ? 2 : 0;
        // usecolours=1 makes stringwidth ignore markup so layout matches what
        // drawstring actually paints.
        float label_width = (label != "") ? stringwidth(label, 1, label_size) : 0;
        float top    = screen.y - radius - label_size.y - 2;
        float name_x = screen.x - label_width * 0.5;
        float icon_x = name_x - (icon_w * icon_count + icon_gap);
        if (has_quad) {
            drawpic([icon_x, top, 0], "sb_quad",
                    [icon_w, icon_h, 0], '1 1 1', 1, 0);
            icon_x += icon_w;
        }
        if (has_pent) {
            drawpic([icon_x, top, 0], "sb_invuln",
                    [icon_w, icon_h, 0], '1 1 1', 1, 0);
        }
        if (label != "") {
            // Pass white so drawstring uses the charset's native colors:
            // plain ASCII = white, qchars in bronze, ^X markup applied
            // per-character. Tinting via the rgb arg would override every
            // unmarked char with the team color.
            drawstring([name_x, top, 0], label, label_size, '1 1 1', 1, 0);
        }
        float text_y = screen.y + radius + 2;

        // Health bar, armor bar, owned-weapon labels - mirroring autoid.
        // getplayerstat works for any player in MVD playback. Hidden during
        // standby/countdown (match not actually started yet).
        float health = getplayerstat(player_index, STAT_HEALTH, EV_FLOAT);
        if (match_active && health > 0) {
            float bar_w   = 17;
            float bar_h   = 1;
            float bar_gap = 1;
            float bar_left    = screen.x - bar_w * 0.5;
            float bar_top     = text_y;
            float bar_group_h = bar_h * 2 + bar_gap;

            // Health bar - two-tone, matching the autoid table in view.c:1823.
            // r = floor(hp/100); LEFT segment (width = bar_w*frac) draws the
            // brighter colours[r+1], RIGHT (1-frac) draws the dimmer colours[r].
            vector hp_pos = [bar_left, text_y, 0];
            float health_idx  = floor(health / 100);
            float health_frac = health / 100 - health_idx;
            if (health_idx > 3) { health_idx = 3; health_frac = 1; }
            if (health_idx < 0) { health_idx = 0; health_frac = 0; }
            vector health_dim  = MinimapHealthColorAt(health_idx);
            vector health_full = MinimapHealthColorAt(health_idx + 1);
            drawfill(hp_pos, [bar_w, bar_h], '0 0 0', 0.6);
            drawfill(hp_pos, [bar_w * health_frac, bar_h], health_full, 1);
            drawfill([bar_left + bar_w * health_frac, text_y, 0],
                     [bar_w * (1 - health_frac), bar_h], health_dim, 1);
            text_y += bar_h + bar_gap;

            // Read items once - used for both armor type and weapon labels.
            // STAT_ITEMS is queried as EV_INTEGER (csplat.qc:1841) since
            // runes/items2 are packed into the upper bits.
            int items = getplayerstat(player_index, STAT_ITEMS, EV_INTEGER);

            // Armor bar - two-tone, matching the autoid table in view.c:1831.
            // RA/YA/GA each have a dim/full color pair; remaining armor
            // draws full, depleted draws dim.
            float armor = getplayerstat(player_index, STAT_ARMOR, EV_FLOAT);
            float armor_max = 0;
            vector armor_dim  = '0 0 0';
            vector armor_full = '0 0 0';
            if (items & MM_IT_ARMOR3) {
                armor_max  = 200;
                armor_dim  = minimap_armor_colors[4];
                armor_full = minimap_armor_colors[5];
            } else if (items & MM_IT_ARMOR2) {
                armor_max  = 150;
                armor_dim  = minimap_armor_colors[2];
                armor_full = minimap_armor_colors[3];
            } else if (items & MM_IT_ARMOR1) {
                armor_max  = 100;
                armor_dim  = minimap_armor_colors[0];
                armor_full = minimap_armor_colors[1];
            }
            if (armor_max > 0 && armor > 0) {
                vector armor_pos = [bar_left, text_y, 0];
                float armor_frac = armor / armor_max;
                if (armor_frac > 1) armor_frac = 1;
                drawfill(armor_pos, [bar_w, bar_h], '0 0 0', 0.6);
                drawfill(armor_pos, [bar_w * armor_frac, bar_h], armor_full, 1);
                drawfill([bar_left + bar_w * armor_frac, text_y, 0],
                         [bar_w * (1 - armor_frac), bar_h], armor_dim, 1);
            }

            // Best-weapon indicator to the right of the bar stack, vertically
            // centered on the bar group. Priority: RLG (both) > RL > LG > GL.
            // For the combo, R uses the RL color and LG uses the LG color,
            // drawn as two adjacent strings.
            float has_rl = items & MM_IT_ROCKET_LAUNCHER;
            float has_lg = items & MM_IT_LIGHTNING;
            float has_gl = items & MM_IT_GRENADE_LAUNCHER;
            float weapon_x = bar_left + bar_w + 3;
            float weapon_y = bar_top + bar_group_h * 0.5 - weapon_size.y * 0.5;
            if (has_rl && has_lg) {
                drawstring([weapon_x, weapon_y, 0], "R", weapon_size,
                           MinimapWeaponColor(MM_IT_ROCKET_LAUNCHER), 1, 0);
                drawstring([weapon_x + stringwidth("R", 0, weapon_size), weapon_y, 0], "LG", weapon_size,
                           MinimapWeaponColor(MM_IT_LIGHTNING), 1, 0);
            } else if (has_rl) {
                drawstring([weapon_x, weapon_y, 0], "RL", weapon_size,
                           MinimapWeaponColor(MM_IT_ROCKET_LAUNCHER), 1, 0);
            } else if (has_lg) {
                drawstring([weapon_x, weapon_y, 0], "LG", weapon_size,
                           MinimapWeaponColor(MM_IT_LIGHTNING), 1, 0);
            } else if (has_gl) {
                drawstring([weapon_x, weapon_y, 0], "GL", weapon_size,
                           MinimapWeaponColor(MM_IT_GRENADE_LAUNCHER), 1, 0);
            }
        }
    }
};

// Spawns throwaway QC entities mirroring each occluded player, added with
// EF_NODEPTHTEST + alpha so they show through walls/roofs in the minimap
// renderscene pass.
void(vector cam_origin) MinimapSpawnOccludedDoppelgangers =
{
    float player_model_index = getmodelindex("progs/player.mdl");
    minimap_doppel_count = 0;
    for (int i = 1; i <= maxclients; i++) {
        if (minimap_doppel_count >= MINIMAP_MAX_PLAYERS) break;
        float active = getentity(i, GE_ACTIVE);
        if (!active) continue;
        float model_index = getentity(i, GE_MODELINDEX);
        if (model_index != player_model_index) continue;
        vector origin = getentity(i, GE_ORIGIN);
        if (origin == '0 0 0') continue;
        if (!MinimapPlayerOccluded(cam_origin, origin)) continue;

        float occ_alpha = autocvar_minimap_player_alpha > 0
                          ? autocvar_minimap_player_alpha : 0.8;

        entity doppel = spawn();
        setmodelindex(doppel, player_model_index);
        setorigin(doppel, origin);
        doppel.angles  = getentity(i, GE_ANGLES);
        doppel.frame   = getentity(i, GE_FRAME);
        doppel.skin    = getentity(i, GE_SKIN);
        doppel.alpha   = occ_alpha;
        doppel.effects = EF_NODEPTHTEST;
        addentity(doppel);

        minimap_doppel_ents[minimap_doppel_count] = doppel;
        minimap_doppel_count++;
    }
};

// Removes the doppelganger entities spawned above. Called right after
// renderscene so they don't linger into the next pass.
void() MinimapRemoveDoppelgangers =
{
    for (int i = 0; i < minimap_doppel_count; i++) {
        if (minimap_doppel_ents[i]) {
            remove(minimap_doppel_ents[i]);
            minimap_doppel_ents[i] = nil;
        }
    }
    minimap_doppel_count = 0;
};

// ----- helpers --------------------------------------------------------------

// Returns 1 if the line from cam_origin to the player's head is blocked by
// world geometry that isn't part of a minimap cull volume. Mirrors the
// xray-style traceline pattern, with extra walking through cull volumes
// since the minimap camera looks down through roofs that are intentionally
// hidden in the render.
float(vector cam_origin, vector player_origin) MinimapPlayerOccluded =
{
    vector head = [player_origin.x, player_origin.y, player_origin.z + 24];
    // Start just inside the BSP. cam_origin sits above the outer hull, and
    // tracing from outside into BSP space hits the hull's top first, which
    // would falsely flag every player as occluded.
    vector trace_from = [cam_origin.x, cam_origin.y, minimap_world_top_z - 1];
    if (trace_from.z <= head.z) {
        return 0;
    }
    float steps = 8;
    while (steps > 0) {
        steps--;
        traceline(trace_from, head, MOVE_NORMAL | MOVE_NOMONSTERS, world);
        if (trace_fraction == 1) {
            return 0;
        }
        float vol = MinimapPointInCullVolume(trace_endpos);
        if (vol < 0) {
            return 1;
        }
        trace_from = [trace_endpos.x, trace_endpos.y, minimap_volumes[vol].mins.z - 1];
        if (trace_from.z <= head.z) {
            return 0;
        }
    }
    return 0;
};

// Pick a color for a player relative to the tracked POV. While spectating,
// player_localnum points at the spectator slot (no team), so all players
// would read as "enemy". player_localentnum is the entity the engine is
// actually viewing through - the tracked player. Team coloring keys off
// that player's team instead, so teammates of whoever you're tracking
// render as team-colored.
//
// Mirrors the engine's TP_PlayerTeam / cl.teamplay pattern (zqtp.c:328,
// cl_cam.c:446): same-team only counts in teamplay mode. In FFA every
// non-self player is an enemy regardless of userinfo team strings.
vector(float pnum) MinimapPlayerColor =
{
    float pov_pnum = (player_localentnum > 0) ? (player_localentnum - 1) : player_localnum;
    if (pnum == pov_pnum) {
        return autocvar_minimap_player_selfcolor;
    }
    float same_team = 0;
    if (serverkeyfloat("teamplay") > 0) {
        string pov_team = getplayerkeyvalue(pov_pnum, "team");
        string his_team = getplayerkeyvalue(pnum, "team");
        same_team = (pov_team == his_team && pov_team != "");
    }
    vector color = same_team ? autocvar_minimap_player_teamcolor : autocvar_minimap_player_enemycolor;
    if (color == '0 0 0') {
        return same_team ? minimap_default_color_team : minimap_default_color_enemy;
    }
    return color;
};

// Refreshes the per-frame label cache. Called once at the top of
// MinimapDrawPlayers.
void() MinimapBuildPlayerLabels =
{
    float player_model_index = getmodelindex("progs/player.mdl");
    for (int i = 0; i < MINIMAP_MAX_PLAYERS; i++) {
        minimap_label_name [i] = "";
        minimap_label_plain[i] = "";
        if (i >= maxclients) {
            continue;
        }
        float entnum = i + 1;
        float active = getentity(entnum, GE_ACTIVE);
        if (!active) {
            continue;
        }
        float model_index = getentity(entnum, GE_MODELINDEX);
        if (model_index != player_model_index) {
            continue;
        }
        string raw = getplayerkeyvalue(i, "name");
        minimap_label_name [i] = MinimapNormalizeName(raw);
        minimap_label_plain[i] = strdecolorize(minimap_label_name[i]);
    }
};

// Returns the shortest visible-character prefix of player `pi`'s name that no
// other active player's name starts with. Comparison uses the decolored plain
// form so two players named e.g. "^1Foo" and "^2Foo" still need disambiguation,
// but the returned string keeps its color markup for drawstring.
string(float pi) MinimapShortestUniquePrefix =
{
    string mine_plain = minimap_label_plain[pi];
    float my_length = strlen(mine_plain);
    if (my_length == 0) {
        return "";
    }
    for (float n = 1; n <= my_length; n++) {
        string my_prefix = substring(mine_plain, 0, n);
        float unique = 1;
        for (int j = 0; j < MINIMAP_MAX_PLAYERS; j++) {
            if (j == pi) continue;
            string other = minimap_label_plain[j];
            if (other == "") continue;
            if (substring(other, 0, n) == my_prefix) {
                unique = 0;
                break;
            }
        }
        if (unique) {
            return MinimapColoredPrefix(minimap_label_name[pi], n);
        }
    }
    return minimap_label_name[pi];
};

// Returns the first `n_visible` characters of a colored name, copying any ^X
// markup verbatim alongside the kept chars so drawstring still recolors them.
string(string colored, float n_visible) MinimapColoredPrefix =
{
    string out = "";
    float length = strlen(colored);
    float visible = 0;
    float i;
    for (i = 0; i < length; i++) {
        if (visible >= n_visible) {
            break;
        }
        float c = str2chr(colored, i);
        if (c == '^' && i + 1 < length) {
            float next_c = str2chr(colored, i + 1);
            out = strcat(out, chr2str(c));
            out = strcat(out, chr2str(next_c));
            i++;
            if (next_c == '^') {
                visible++;  // ^^ unescapes to a single visible '^'
            }
            continue;
        }
        out = strcat(out, chr2str(c));
        visible++;
    }
    return out;
};

// Sanitize a player name for display via drawstring: keep printable ASCII,
// QW ^X color codes, and any chars Quake's font can render (high-bit bronze
// bytes when utf8_enable is off; qchar codepoints 0xE000..0xE0FF when on).
// Both ranges are accepted unconditionally - whichever the engine actually
// uses depends on utf8_enable, the other range will simply be empty in
// practice.
string(string raw) MinimapNormalizeName =
{
    string out = "";
    float length = strlen(raw);
    float i;
    for (i = 0; i < length; i++) {
        float c = str2chr(raw, i);
        // ^X is a 2-byte color marker; keep both bytes verbatim (^^ -> literal ^).
        if (c == '^' && i + 1 < length) {
            float next_c = str2chr(raw, i + 1);
            out = strcat(out, chr2str(c));
            out = strcat(out, chr2str(next_c));
            i++;
            continue;
        }
        // Quake's font has renderable glyphs across the full byte range:
        //   16..17    brackets [ ]
        //   18..27    gold numbers 0-9
        //   33..126   standard ASCII
        //   144..145  brackets [ ] (high-bit duplicate)
        //   146..155  gold numbers 0-9 (high-bit duplicate)
        //   161..254  brown ASCII a-z, A-Z, 0-9, punctuation
        // We accept bytes 16..255 (drop only the few leading control-range
        // chars that all render as blank) and the full UTF-8 qchar range
        // 0xE000..0xE0FF used when utf8_enable is on.
        if ((c >= 16 && c <= 255) || (c >= 0xE000 && c <= 0xE0FF)) {
            out = strcat(out, chr2str(c));
        }
    }
    return out;
};
