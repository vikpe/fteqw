// SPDX-License-Identifier: 0BSD

/*
 * Minimap console command handlers and cvar description registration.
 * Dispatched from commands.qc:CSQC_ConsoleCommand.
 */

float() MinimapCmdReload =
{
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
    println("Minimap status:");
    println("  mode             %g  (0=off 1=pip 2=split 3=full)", autocvar_qdw_minimap_mode);
    println("  map              %s", mapname);
    println("  loaded           %g", minimap_loaded);
    println("  volumes          %d", minimap_num_volumes);
    println("  center           %v", minimap_center);
    println("  ortho            %g", minimap_ortho);
    println("  height           %g", minimap_height);
    println("  auto-cull known  %g", minimap_auto_pickup_known);
    println("  auto-cull max_z  %g", minimap_auto_pickup_max_z);
    for (int i = 0; i < minimap_num_volumes; i++) {
        println("  [%d] mins=%v maxs=%v", i, minimap_volumes[i].mins, minimap_volumes[i].maxs);
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
        if (MinimapIsPickupModel(model_name)) {
            vector org = getentity(j, GE_ORIGIN);
            pickups++;
            println("  [%d] %s at %v", (int)j, model_name, org);
        }
    }
    println("  scanned=%d active=%d with-model=%d pickups=%d",
            total, active, with_model, pickups);
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

void() MinimapRegisterDescriptions =
{
    MinimapDescribeCvar("qdw_minimap_mode",
        "Minimap display mode. 0=off, 1=picture-in-picture (top right), 2=split screen (right half), 3=full screen.");
    MinimapDescribeCvar("qdw_minimap_ortho",
        "Orthographic half-extent in Quake units per side. 0 = use value from .cull file or auto-derived from worldmodel bounds.");
    MinimapDescribeCvar("qdw_minimap_height_offset",
        "Camera Z offset above the reference center. 0 = use value from .cull file or auto-derived (highest geometry at center + 512 margin).");
    MinimapDescribeCvar("qdw_minimap_center_override",
        "Camera XY position and reference Z, as a vector. '0 0 0' = use value from .cull file or worldmodel midpoint.");
    MinimapDescribeCvar("qdw_minimap_player_radius",
        "Radius of the player marker ring on the minimap, in screen pixels.");
    MinimapDescribeCvar("qdw_minimap_player_alpha_occluded",
        "Alpha applied to a player model that the minimap camera can't see directly (drawn through walls/roofs via a doppelganger pass). Visible players use the engine's normal rendering. Default 0.8.");
    MinimapDescribeCvar("qdw_minimap_player_color_team",
        "Ring/triangle color for same-team players. '0 0 0' = default green.");
    MinimapDescribeCvar("qdw_minimap_player_color_enemy",
        "Ring/triangle color for opposing-team players. '0 0 0' = default red.");
    MinimapDescribeCvar("qdw_minimap_player_color_self",
        "Ring/triangle color for the local player.");
    MinimapDescribeCvar("qdw_minimap_player_label_name_length",
        "Fixed number of characters to show in each player label. Default 4. Set to 0 for auto (shortest prefix unique among all current players).");
    MinimapDescribeCvar("qdw_minimap_player_label_font_size",
        "Font size in pixels for the player name label above each marker. Default 6.");
};

float() MinimapCmdHelp =
{
    println("Minimap commands:");
    println("  reload   - reparse maps/<mapname>.cull and recompute auto bounds");
    println("  status   - print current mode, map, volume count, and view params");
    println("  help     - show this command list");
    println("Cvars:");
    println("  qdw_minimap_mode             0=off 1=pip 2=split 3=full");
    println("  qdw_minimap_ortho            half-extent in QU; 0 = use file value");
    println("  qdw_minimap_height_offset    camera Z above center; 0 = use file value");
    println("  qdw_minimap_center_override  vector; '0 0 0' = use file value");
    return 1;
};
