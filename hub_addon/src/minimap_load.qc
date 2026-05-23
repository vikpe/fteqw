// SPDX-License-Identifier: 0BSD

/*
 * Minimap load pipeline:
 *   - Seed bounds from the worldmodel AABB
 *   - Grid-traceline narrowing: at each cell, do a top-down trace for the
 *     ceiling and a follow-up trace beneath it for the floor; keep the
 *     cell only if there's a real air gap (a room) under the topmost
 *     surface. Sky/clip-tagged hits are also rejected via content bits.
 *     Bbox = AABB of kept cells; camera Z = topmost kept ceiling.
 *   - Parse maps/<mapname>.cull for cull volumes (optional)
 *   - Re-derive the camera height from the cull volumes' highest floor Z
 *     when a .cull file is loaded
 *
 * Cull file format:
 *   # comments allowed; blank lines ignored
 *   # each volume is one line with 6 numbers:
 *   #   mins.x mins.y mins.z  maxs.x maxs.y maxs.z
 *   -512 -384 192    512 384 99999
 */

// Forward declarations (top-down ordering).
void()             MinimapAutoBounds;
float()            MinimapNarrowByTraceline;
float()            MinimapExpandByPickups;
float(string line) MinimapParseLine;
void()             MinimapDeriveBoundsFromVolumes;

float() MinimapLoad =
{
    MinimapResetState();
    minimap_loaded     = 0;
    minimap_loaded_for = mapname;

    if (mapname == "") {
        return 0;
    }

    MinimapAutoBounds();
    MinimapNarrowByTraceline();
    MinimapExpandByPickups();

    string cull_path = sprintf("maps/%s.cull", mapname);
    filestream fh = fopen(cull_path, FILE_READ);
    if (fh < 0) {
        println("[minimap] no cull file '%s'", cull_path);
        // No .cull file - still build the plan grid so the heatmap
        // has a playable-shape mask to clamp against, even on
        // unconfigured maps.
        MinimapBuildPlanCells();
        return 0;
    }

    string line;
    while ((line = fgets(fh))) {
        MinimapParseLine(line);
    }
    fclose(fh);

    minimap_loaded = 1;
    MinimapDeriveBoundsFromVolumes();
    MinimapBuildPlanCells();
    println("[minimap] loaded custom cull file %s (%d volumes)",
            cull_path, (float)minimap_num_volumes);
    return 1;
};

// Derive the camera height from the highest cull-volume floor Z. Volume.mins.z
// is "everything above this Z gets culled", i.e. approximates the room's
// ceiling; the highest such value tells us how high the camera must sit to
// float above the tallest covered room.
//
// XY bounds are intentionally NOT derived here - cull volumes are sized for
// culling (often extending beyond the playable area to safely cover walls
// and hallways), so using them for bounds produces oversized AABBs with
// black slack on the side of the loosest volume. XY bounds come from the
// BSP AABB (auto-bounds) optionally narrowed by the .loc file.
void() MinimapDeriveBoundsFromVolumes =
{
    if (minimap_num_volumes <= 0) return;

    float max_floor_z = -99999;
    for (int i = 0; i < minimap_num_volumes; i++) {
        float mnz = minimap_volumes[i].mins.z;
        if (mnz > max_floor_z) max_floor_z = mnz;
    }

    if (max_floor_z > -99999) {
        minimap_height = max_floor_z - minimap_center.z;
    }
    debug("minimap: derived height %g from %d volumes",
          minimap_height, (float)minimap_num_volumes);
};

// Derive center/ortho/height from the worldmodel AABB.
// setmodel() on a temp entity with the BSP path fills .mins/.maxs from the
// brushmodel (per csplat.qc:976-977).
void() MinimapAutoBounds =
{
    entity tmp = spawn();
    string bsp_path = sprintf("maps/%s.bsp", mapname);
    setmodel(tmp, bsp_path);

    if (tmp.maxs.x > tmp.mins.x) {
        minimap_center.x = (tmp.mins.x + tmp.maxs.x) * 0.5;
        minimap_center.y = (tmp.mins.y + tmp.maxs.y) * 0.5;
        minimap_center.z = tmp.mins.z;
        minimap_world_top_z = tmp.maxs.z;
        minimap_world_dx = tmp.maxs.x - tmp.mins.x;
        minimap_world_dy = tmp.maxs.y - tmp.mins.y;

        // Single-extent fallback used by narrowing helpers to decide whether
        // their result is actually tighter than the BSP-derived bounds.
        float ext = max(minimap_world_dx, minimap_world_dy);
        minimap_ortho = ext * 0.5;

        // Camera Z = BSP top. Guarantees the orthographic camera sits above
        // every brush in the map regardless of where minimap_center.xy lands
        // (a traceline at center can hit a low interior ceiling and place
        // the camera under taller roofs elsewhere).
        minimap_height = tmp.maxs.z - minimap_center.z;

        debug("minimap: auto bounds %v..%v, height %g",
              tmp.mins, tmp.maxs, minimap_height);
    }

    remove(tmp);
};

// Narrow XY bounds by sampling BSP geometry directly. For each cell of a
// grid laid over the current AABB, trace down to find a ceiling; if the
// ceiling is a sky/clip surface (rejected via content bits) or there's no
// open room beneath it (a follow-up trace finds no floor within
// min_room_height), the cell is skipped. The AABB of the remaining cells
// is the playable bbox, and the topmost kept ceiling becomes the camera Z.
//
// Works without .loc files or a populated entity table, and copes with
// maps whose outer shell is plain solid brushes (no sky/clip tag) - those
// cells reject because they have no air gap beneath the top surface.
//
// Resolution is fixed at 48 cells on the dominant axis with the
// perpendicular axis scaled to preserve aspect, so half-cell error is
// ~world_extent/96 (typically <50 QU).
// Returns 1 if bounds were narrowed.
#define MINIMAP_PROBE_COLS 48
float() MinimapNarrowByTraceline =
{
    if (minimap_world_dx <= 0 || minimap_world_dy <= 0) {
        return 0;
    }

    float cols = MINIMAP_PROBE_COLS;
    float rows = floor(cols * minimap_world_dx / minimap_world_dy);
    if (rows < 4)   rows = 4;
    if (rows > 128) rows = 128;

    float bsp_min_x = minimap_center.x - minimap_world_dx * 0.5;
    float bsp_min_y = minimap_center.y - minimap_world_dy * 0.5;
    float top_z    = minimap_world_top_z + 1;
    float bottom_z = minimap_center.z - 1;
    float cell_dx  = minimap_world_dx / rows;
    float cell_dy  = minimap_world_dy / cols;

    // A "playable" cell is one where there's an open room below the topmost
    // solid - ceiling + air + floor. Cells over the outer wall mass (which
    // on maps like dm2 isn't sky/clip-tagged so content bits don't filter
    // it) are solid from top to bottom and have no air gap, so they fail
    // this check.
    //
    // Sky and player/monster-clip brushes are also rejected up front via
    // content bits, since trace_endpos there isn't a real ceiling.
    float reject_bits = CONTENTBIT_SKY | CONTENTBIT_PLAYERCLIP | CONTENTBIT_MONSTERCLIP;
    float min_room_height = 32;
    float min_x =  99999, min_y =  99999;
    float max_x = -99999, max_y = -99999;
    float max_hit_z = -99999;
    float hits = 0;
    for (float row = 0; row < rows; row++) {
        float wx = bsp_min_x + (row + 0.5) * cell_dx;
        for (float col = 0; col < cols; col++) {
            float wy = bsp_min_y + (col + 0.5) * cell_dy;
            traceline([wx, wy, top_z], [wx, wy, bottom_z],
                      MOVE_NORMAL | MOVE_NOMONSTERS, world);
            if (trace_fraction >= 1) continue;
            if (trace_endcontents & reject_bits) continue;
            float roof_z = trace_endpos.z;
            // Probe for a floor below the ceiling. If there's no room
            // beneath the topmost solid (we're standing on the outer wall),
            // the trace bottoms out at bottom_z with no further hit.
            traceline([wx, wy, roof_z - 1], [wx, wy, bottom_z],
                      MOVE_NORMAL | MOVE_NOMONSTERS, world);
            if (trace_fraction >= 1) continue;
            if (trace_endcontents & reject_bits) continue;
            if (roof_z - trace_endpos.z < min_room_height) continue;
            if (wx < min_x) min_x = wx;
            if (wy < min_y) min_y = wy;
            if (wx > max_x) max_x = wx;
            if (wy > max_y) max_y = wy;
            if (roof_z > max_hit_z) max_hit_z = roof_z;
            hits++;
        }
    }

    if (hits == 0 || max_x <= min_x) {
        return 0;
    }

    // Expand the hit AABB by half a cell on each side so the cell centers
    // map back to a bbox that fully contains the sampled cells.
    min_x -= cell_dx * 0.5;
    max_x += cell_dx * 0.5;
    min_y -= cell_dy * 0.5;
    max_y += cell_dy * 0.5;

    float new_extent = max(max_x - min_x, max_y - min_y);
    float new_ortho  = new_extent * 0.5;
    if (new_ortho >= minimap_ortho) {
        return 0;
    }

    minimap_center.x = (min_x + max_x) * 0.5;
    minimap_center.y = (min_y + max_y) * 0.5;
    minimap_ortho    = new_ortho;
    minimap_world_dx = max_x - min_x;
    minimap_world_dy = max_y - min_y;

    // Camera Z = topmost surface inside the narrowed playable area, not the
    // BSP maxs.z (which is usually a sky shell brush far above gameplay).
    // Placing the camera at sky height pushes the floor outside the
    // orthographic far clip and the whole minimap renders black.
    if (max_hit_z > -99999) {
        minimap_height = max_hit_z - minimap_center.z;
    }
    debug("minimap: traceline probe narrowed bounds (%g hits / %g cells), center %v, ortho %g, height %g",
          hits, cols * rows, minimap_center, minimap_ortho, minimap_height);
    return 1;
};

// After grid-traceline narrowing, walk client entities for pickups and
// expand the bbox to include any whose XY falls outside. Pickups always
// sit in playable space by definition, so the bbox must contain them -
// the traceline grid misses items that land between probe cells, in
// alcoves with no ceiling within range, or under open-sky areas where
// the ceiling trace hits sky and gets rejected (schloss MH / YA are the
// canonical case).
//
// Models are identified via MinimapIsFloorAnchor (the same allowlist the
// /minimap scan command uses). Spawn points and triggers have no client-
// visible model in vanilla Quake so they can't be enumerated this way;
// items + weapons cover the common case.
//
// Returns 1 if at least one pickup pushed the bbox outward.
float() MinimapExpandByPickups =
{
    if (minimap_world_dx <= 0 || minimap_world_dy <= 0) {
        return 0;
    }

    float min_x = minimap_center.x - minimap_world_dx * 0.5;
    float max_x = minimap_center.x + minimap_world_dx * 0.5;
    float min_y = minimap_center.y - minimap_world_dy * 0.5;
    float max_y = minimap_center.y + minimap_world_dy * 0.5;

    float pickup_count = 0;
    float expanded     = 0;
    float ent_count    = getentity(0, GE_MAXENTS);
    for (float j = 1; j < ent_count; j++) {
        float is_active = getentity(j, GE_ACTIVE);
        if (!is_active) continue;
        float model_index = getentity(j, GE_MODELINDEX);
        if (model_index == 0) continue;
        string model_name = modelnameforindex(model_index);
        if (!MinimapIsFloorAnchor(model_name)) continue;
        pickup_count++;
        vector org = getentity(j, GE_ORIGIN);
        if (org.x < min_x) { min_x = org.x; expanded = 1; }
        if (org.x > max_x) { max_x = org.x; expanded = 1; }
        if (org.y < min_y) { min_y = org.y; expanded = 1; }
        if (org.y > max_y) { max_y = org.y; expanded = 1; }
    }

    if (!expanded) {
        debug("minimap: pickup expansion not needed (%g pickups all inside bbox)",
              pickup_count);
        return 0;
    }

    // Half-pickup-radius padding so item icons don't kiss the viewport edge.
    float pad = 32;
    min_x -= pad; max_x += pad;
    min_y -= pad; max_y += pad;

    minimap_center.x = (min_x + max_x) * 0.5;
    minimap_center.y = (min_y + max_y) * 0.5;
    minimap_world_dx = max_x - min_x;
    minimap_world_dy = max_y - min_y;
    minimap_ortho    = max(minimap_world_dx, minimap_world_dy) * 0.5;

    debug("minimap: expanded bbox to include %g pickups, new dx=%g dy=%g center=%v",
          pickup_count, minimap_world_dx, minimap_world_dy, minimap_center);
    return 1;
};

float(string line) MinimapParseLine =
{
    float num_tokens = tokenize_console(line);
    if (num_tokens <= 0) {
        return 0;
    }

    string head = argv(0);
    if (substring(head, 0, 1) == "#") {
        return 0;
    }

    if (num_tokens >= 6 && minimap_num_volumes < MINIMAP_MAX_CULL_VOLUMES) {
        minimap_volumes[minimap_num_volumes].mins =
            [stof(argv(0)), stof(argv(1)), stof(argv(2))];
        minimap_volumes[minimap_num_volumes].maxs =
            [stof(argv(3)), stof(argv(4)), stof(argv(5))];
        minimap_num_volumes++;
        return 1;
    }

    return 0;
};
