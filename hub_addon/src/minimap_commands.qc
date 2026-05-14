// SPDX-License-Identifier: 0BSD

/*
 * Minimap console command handlers and cvar description registration.
 * Dispatched from commands.qc:CSQC_ConsoleCommand.
 */

// Forward declarations (top-down ordering).
void(string name, string desc) MinimapDescribeCvar;

void() MinimapRegisterDescriptions =
{
    MinimapDescribeCvar("minimap_mode",
        "Minimap display mode. 0=off, 1=picture-in-picture (top right), 2=split screen (right half), 3=full screen.");
    MinimapDescribeCvar("minimap_player_radius",
        "Radius of the player marker ring on the minimap, in screen pixels.");
    MinimapDescribeCvar("minimap_player_alpha",
        "Alpha applied to a player model that the minimap camera can't see directly (drawn through walls/roofs via a doppelganger pass). Visible players use the engine's normal rendering. Default 0.8.");
    MinimapDescribeCvar("minimap_player_teamcolor",
        "Ring/triangle color for same-team players. '0 0 0' = default green.");
    MinimapDescribeCvar("minimap_player_enemycolor",
        "Ring/triangle color for opposing-team players. '0 0 0' = default red.");
    MinimapDescribeCvar("minimap_player_selfcolor",
        "Ring/triangle color for the local player.");
    MinimapDescribeCvar("minimap_player_name_length",
        "Fixed number of characters to show in each player label. Default 4. Set to 0 for auto (shortest prefix unique among all current players).");
    MinimapDescribeCvar("minimap_player_name_size",
        "Font size in pixels for the player name label above each marker. Default 6.");
};

float() MinimapCmdReload =
{
    CullEditResetState();
    MinimapLoad();
    println("Minimap reloaded:");
    println("  volumes  %d", minimap_num_volumes);
    println("  center   %v", minimap_center);
    println("  ortho    %g", minimap_ortho);
    println("  height   %g", minimap_height);
    return 1;
};

float() MinimapCmdStatus =
{
    string cull_path = sprintf("maps/%s.cull", mapname);
    string cull_status = minimap_loaded ? sprintf("loaded from %s", cull_path)
                                        : sprintf("not found (%s)", cull_path);
    println("Minimap status:");
    println("  mode             %g  (0=off 1=pip 2=split 3=full)", autocvar_minimap_mode);
    println("  map              %s", mapname);
    println("  cull file        %s", cull_status);
    println("  volumes          %d", minimap_num_volumes);
    println("  center           %v", minimap_center);
    println("  world_dx         %g", minimap_world_dx);
    println("  world_dy         %g", minimap_world_dy);
    println("  bbox mins        %g %g", minimap_center.x - minimap_world_dx * 0.5,
                                        minimap_center.y - minimap_world_dy * 0.5);
    println("  bbox maxs        %g %g", minimap_center.x + minimap_world_dx * 0.5,
                                        minimap_center.y + minimap_world_dy * 0.5);
    println("  ortho            %g", minimap_ortho);
    println("  height           %g", minimap_height);
    for (int i = 0; i < minimap_num_volumes; i++) {
        println("  [%d] mins=%v maxs=%v", i, minimap_volumes[i].mins, minimap_volumes[i].maxs);
    }

    // Pickup probe: pure diagnostic listing of the floor-anchor entities
    // visible to the client. Useful for sizing manual .cull volumes;
    // skipped once a .cull file is loaded since at that point the user
    // is presumably done designing.
    if (minimap_loaded) {
        return 1;
    }

    println("Pickup probe:");
    int total      = 0;
    int active     = 0;
    int with_model = 0;
    int pickups    = 0;
    float ent_count = getentity(0, GE_MAXENTS);
    for (float j = 1; j < ent_count; j++) {
        total++;
        float is_active = getentity(j, GE_ACTIVE);
        if (!is_active) continue;
        active++;
        float model_index = getentity(j, GE_MODELINDEX);
        if (model_index == 0) continue;
        with_model++;
        string model_name = modelnameforindex(model_index);
        if (MinimapIsFloorAnchor(model_name)) {
            vector org = getentity(j, GE_ORIGIN);
            pickups++;
            println("  [%d] %s at %v", (int)j, model_name, org);
        }
    }
    println("  scanned=%d active=%d with-model=%d pickups=%d",
            total, active, with_model, pickups);
    return 1;
};

// Grid-traceline the BSP AABB from above and print a top-down ASCII map of
// where geometry exists. Compares the bounds of "hit" cells to the playable
// area derived from pickups, so outlier brushes (sky shell, hidden detail,
// trigger rooms) that inflate the BSP AABB become visible at a glance.
//
// Resolution is fixed at 48 columns; rows scale to preserve world aspect.
// '#' = traceline hit (BSP brush above floor), '.' = empty cell.
float() MinimapCmdProbe =
{
    if (minimap_world_dx <= 0 || minimap_world_dy <= 0) {
        println("[minimap probe] bounds not derived yet (open the minimap once).");
        return 1;
    }

    float cols = 48;
    float rows = floor(cols * minimap_world_dx / minimap_world_dy);
    if (rows < 4)  rows = 4;
    if (rows > 96) rows = 96;

    float bsp_min_x = minimap_center.x - minimap_world_dx * 0.5;
    float bsp_min_y = minimap_center.y - minimap_world_dy * 0.5;
    float top_z    = minimap_world_top_z + 1;
    float bottom_z = minimap_center.z - 1;
    float cell_dx  = minimap_world_dx / rows;
    float cell_dy  = minimap_world_dy / cols;

    float hits = 0;
    float hit_min_x =  99999, hit_min_y =  99999;
    float hit_max_x = -99999, hit_max_y = -99999;

    println("[minimap probe] grid %gx%g over bbox (%g %g)..(%g %g)",
            cols, rows,
            bsp_min_x, bsp_min_y,
            bsp_min_x + minimap_world_dx, bsp_min_y + minimap_world_dy);

    // Row 0 = north (high X) for a screen-aligned top-down view: world +X
    // maps to screen up under the minimap camera angles.
    //   '#' = kept (room found beneath ceiling)
    //   's' = sky-surface hit (rejected)
    //   'p' = player-clip hit (rejected)
    //   'm' = monster-clip hit (rejected)
    //   'W' = solid hit but no air gap beneath (outer wall mass, rejected)
    //   '.' = no hit
    float reject_bits = CONTENTBIT_SKY | CONTENTBIT_PLAYERCLIP | CONTENTBIT_MONSTERCLIP;
    float min_room_height = 32;
    for (float row = 0; row < rows; row++) {
        string line_str = "  ";
        float wx = bsp_min_x + minimap_world_dx - (row + 0.5) * cell_dx;
        for (float col = 0; col < cols; col++) {
            float wy = bsp_min_y + (col + 0.5) * cell_dy;
            traceline([wx, wy, top_z], [wx, wy, bottom_z],
                      MOVE_NORMAL | MOVE_NOMONSTERS, world);
            if (trace_fraction >= 1) {
                line_str = strcat(line_str, ".");
                continue;
            }
            if (trace_endcontents & reject_bits) {
                string mark = "?";
                if (trace_endcontents & CONTENTBIT_SKY)         mark = "s";
                else if (trace_endcontents & CONTENTBIT_PLAYERCLIP) mark = "p";
                else if (trace_endcontents & CONTENTBIT_MONSTERCLIP) mark = "m";
                line_str = strcat(line_str, mark);
                continue;
            }
            float roof_z = trace_endpos.z;
            traceline([wx, wy, roof_z - 1], [wx, wy, bottom_z],
                      MOVE_NORMAL | MOVE_NOMONSTERS, world);
            if (trace_fraction >= 1 ||
                (trace_endcontents & reject_bits) ||
                roof_z - trace_endpos.z < min_room_height) {
                line_str = strcat(line_str, "W");
                continue;
            }
            line_str = strcat(line_str, "#");
            hits++;
            if (wx < hit_min_x) hit_min_x = wx;
            if (wy < hit_min_y) hit_min_y = wy;
            if (wx > hit_max_x) hit_max_x = wx;
            if (wy > hit_max_y) hit_max_y = wy;
        }
        println(line_str);
    }

    println("[minimap probe] hits %g/%g cells (%g%%)",
            hits, cols * rows, hits * 100 / (cols * rows));
    if (hits > 0) {
        println("[minimap probe] hit extent  mins=(%g %g) maxs=(%g %g)",
                hit_min_x, hit_min_y, hit_max_x, hit_max_y);
        println("[minimap probe] hit span    dx=%g dy=%g (vs bbox dx=%g dy=%g)",
                hit_max_x - hit_min_x, hit_max_y - hit_min_y,
                minimap_world_dx, minimap_world_dy);
    }
    return 1;
};

float() MinimapCmdHelp =
{
    println("Minimap commands:");
    println("  reload   - reparse maps/<mapname>.cull and recompute auto bounds");
    println("  status   - print current mode, map, volume count, and view params");
    println("  probe    - grid-traceline the BSP AABB and print a coverage map");
    println("  help     - show this command list");
    println("Cvars:");
    println("  minimap_mode             0=off 1=pip 2=split 3=full");
    return 1;
};

// Adds a description to a cvar without disturbing its current value.
// Reads the current value at call time (rather than via $-expansion at
// command-execution time) so the value can never be lost - even if the
// expansion context somehow lacks the cvar, we already captured its string.
void(string name, string desc) MinimapDescribeCvar =
{
    localcmd(sprintf("set %s \"%s\" // %s\n", name, cvar_string(name), desc));
};
