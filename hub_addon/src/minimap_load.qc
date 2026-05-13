// SPDX-License-Identifier: 0BSD

/*
 * Minimap load pipeline:
 *   - Auto-derive camera/projection from the worldmodel AABB
 *   - Narrow to the convex hull of locs/<mapname>.loc when available
 *   - Parse maps/<mapname>.cull for overrides and cull volumes
 *   - Lazy pickup-ceiling scan for per-region auto-cull volumes
 *
 * Cull file format:
 *   # comments allowed; blank lines ignored
 *   center X Y Z           # camera XY and reference Z (override auto)
 *   ortho HALF_SIZE        # half-extent in QU per side (override auto)
 *   height OFFSET          # camera Z added to center.z (override auto)
 *   # any line with 6 numbers: mins.x mins.y mins.z  maxs.x maxs.y maxs.z
 *   -512 -384 192    512 384 99999
 */

// Forward declarations (top-down ordering).
void()             MinimapAutoBounds;
float()            MinimapNarrowToLocFile;
float(string line) MinimapParseLine;

float() MinimapLoad =
{
    MinimapResetState();
    minimap_loaded     = 0;
    minimap_loaded_for = mapname;

    if (mapname == "") {
        return 0;
    }

    MinimapAutoBounds();
    MinimapNarrowToLocFile();

    string cull_path = sprintf("maps/%s.cull", mapname);
    filestream fh = fopen(cull_path, FILE_READ);
    if (fh < 0) {
        debug("minimap: no cull file '%s'", cull_path);
        return 0;
    }

    string line;
    while ((line = fgets(fh))) {
        MinimapParseLine(line);
    }
    fclose(fh);

    minimap_loaded = 1;
    debug("minimap: %d volumes loaded from %s", (float)minimap_num_volumes, cull_path);
    return 1;
};

// Scan baseline/networked entities once per map. For each pickup, trace
// straight up to find the local ceiling and add a cull volume covering an
// XY region around the pickup above that ceiling. This gives per-region
// auto-cull, which handles multi-level maps where a single global ceiling
// height would leak (lower roofs ignored) or over-cull (upper floors cut off).
//
// Returns 1 if at least one pickup was found, 0 to retry next frame
// (entities probably not yet populated).
float() MinimapScanPickupCeiling =
{
    float region_pad     = 256;   // half-width of the cull column around each pickup, in QU
    float ceiling_margin = 8;     // QU above the detected ceiling to start culling
    float min_items      = 10;    // skip auto-cull entirely if the map has fewer than this many pickups
    int   added       = 0;
    int   pad_outdoor = 0;

    // First pass: count pickups. Stops us adding partial cull volumes on
    // tiny / training / non-DM maps whose pickup geometry isn't a useful
    // signal for "where the play floor is".
    int found = 0;
    float ent_count = getentity(0, GE_MAXENTS);
    for (float i = 1; i < ent_count; i++) {
        float active = getentity(i, GE_ACTIVE);
        if (!active) continue;
        float model_index = getentity(i, GE_MODELINDEX);
        if (model_index == 0) continue;
        string model_name = modelnameforindex(model_index);
        if (MinimapIsPickupModel(model_name)) found++;
    }
    if (!found) {
        // Entities probably not yet networked - retry next frame.
        return 0;
    }
    if (found < min_items) {
        // Map has too few pickups to derive a sensible ceiling. Mark known
        // so we don't keep rescanning every frame.
        minimap_auto_pickup_known = 1;
        debug("minimap: only %d pickups (< %d required), skipping auto-cull",
              (float)found, min_items);
        return 1;
    }

    // Second pass: actually trace and add cull volumes.
    for (float j = 1; j < ent_count && minimap_num_volumes < MINIMAP_MAX_CULL_VOLUMES; j++) {
        float active = getentity(j, GE_ACTIVE);
        if (!active) continue;
        float model_index = getentity(j, GE_MODELINDEX);
        if (model_index == 0) continue;
        string model_name = modelnameforindex(model_index);
        if (!MinimapIsPickupModel(model_name)) continue;

        vector org = getentity(j, GE_ORIGIN);

        // Brushmodel pickups (maps/b_*.bsp) have their origin below the
        // visible floor - tracing straight up from origin would hit the
        // floor surface itself, not the ceiling. Start above the entity's
        // bounding-box top (or a safe player-head offset if absmax is
        // missing) so the trace only sees what is genuinely above.
        vector absmax = getentity(j, GE_ABSMAX);
        float start_z = (absmax.z > org.z + 1) ? absmax.z + 1 : org.z + 56;
        traceline([org.x, org.y, start_z],
                  [org.x, org.y, start_z + 100000],
                  MOVE_NORMAL | MOVE_NOMONSTERS, world);
        if (trace_fraction == 1) {
            // Open sky above (no roof) - no auto-cull needed for this pickup.
            pad_outdoor++;
            continue;
        }
        float ceiling_z = trace_endpos.z;
        // If the trace hit the BSP outer hull (near world_top_z), treat as
        // outdoor too - we don't want to cull the skybox itself.
        if (ceiling_z >= minimap_world_top_z - 32) {
            pad_outdoor++;
            continue;
        }

        minimap_volumes[minimap_num_volumes].mins =
            [org.x - region_pad, org.y - region_pad, ceiling_z + ceiling_margin];
        minimap_volumes[minimap_num_volumes].maxs =
            [org.x + region_pad, org.y + region_pad,  99999];
        minimap_num_volumes++;
        added++;

        // Keep the legacy summary value (used by the world_top_z safety in
        // MinimapPlayerOccluded) - max ceiling seen so far.
        if (ceiling_z > minimap_auto_pickup_max_z) {
            minimap_auto_pickup_max_z = ceiling_z;
        }
    }
    minimap_auto_pickup_known = 1;
    debug("minimap: scanned %d pickups (%d added cull volumes, %d outdoor)",
          (float)found, (float)added, (float)pad_outdoor);
    return 1;
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

        // Legacy single-extent value retained for .cull file overrides and
        // the loc-file narrowing helper; the actual viewport-aspect-aware
        // scale is now computed in MinimapRender.
        float ext = max(minimap_world_dx, minimap_world_dy);
        minimap_ortho = ext * 0.5 + 64;

        // probe highest geometry directly above the center; fall back to maxs.z
        vector top    = [minimap_center.x, minimap_center.y, tmp.maxs.z - 1];
        vector bottom = [minimap_center.x, minimap_center.y, tmp.mins.z + 1];
        traceline(top, bottom, MOVE_NORMAL | MOVE_NOMONSTERS, tmp);
        float highest_z = trace_fraction < 1 ? trace_endpos.z : tmp.maxs.z;

        minimap_height = (highest_z - minimap_center.z) + 512;

        debug("minimap: auto bounds %v..%v, top %g, height %g",
              tmp.mins, tmp.maxs, highest_z, minimap_height);
    }

    remove(tmp);
};

// Optionally narrow the minimap projection to the convex hull of points in
// locs/<mapname>.loc. Useful when the BSP outer hull encloses outlier
// brushes that aren't part of the playable area. Two .loc formats are
// supported:
//   - QW classic: "X Y Z name..."         (XYZ in 1/8 quake units, atoi'd)
//   - FTE comma:  "minX,minY,minZ,maxX,maxY,maxZ,name"
// Returns 1 if bounds were narrowed.
float() MinimapNarrowToLocFile =
{
    string loc_path = sprintf("locs/%s.loc", mapname);
    filestream fh = fopen(loc_path, FILE_READ);
    if (fh < 0) {
        return 0;
    }

    float min_x =  99999, min_y =  99999;
    float max_x = -99999, max_y = -99999;
    float count = 0;

    string line;
    while ((line = fgets(fh))) {
        if (line == "") continue;

        if (strstrofs(line, ",", 0) >= 0) {
            // FTE AABB format - six comma-separated coords
            float num_tokens = tokenizebyseparator(line, ",");
            if (num_tokens < 6) continue;
            float a = stof(argv(0)), b = stof(argv(1));
            float c = stof(argv(3)), d = stof(argv(4));
            if (a < min_x) min_x = a;
            if (c < min_x) min_x = c;
            if (a > max_x) max_x = a;
            if (c > max_x) max_x = c;
            if (b < min_y) min_y = b;
            if (d < min_y) min_y = d;
            if (b > max_y) max_y = b;
            if (d > max_y) max_y = d;
            count++;
            continue;
        }

        // QW classic: integer eighths, space-separated
        num_tokens = tokenize_console(line);
        if (num_tokens < 4) continue;
        if (argv(0) == "" || !(stof(argv(0)) != 0 || argv(0) == "0")) continue;
        float x = stof(argv(0)) / 8;
        float y = stof(argv(1)) / 8;
        if (x < min_x) min_x = x;
        if (y < min_y) min_y = y;
        if (x > max_x) max_x = x;
        if (y > max_y) max_y = y;
        count++;
    }
    fclose(fh);

    if (count == 0 || max_x <= min_x) {
        return 0;
    }

    // .loc files only mark named landmarks, not the full playable extent.
    // Inflate generously so corners/walls of the playable area aren't
    // cropped, then only adopt the result if it's actually tighter than
    // the BSP-derived bounds.
    float pad = 256;
    min_x -= pad;  min_y -= pad;
    max_x += pad;  max_y += pad;

    float new_extent = max(max_x - min_x, max_y - min_y);
    float new_ortho  = new_extent * 0.5 + 64;
    if (new_ortho >= minimap_ortho) {
        return 0;
    }

    minimap_center.x = (min_x + max_x) * 0.5;
    minimap_center.y = (min_y + max_y) * 0.5;
    minimap_ortho = new_ortho;
    // Also feed the tighter bounds into the world extents so MinimapRender's
    // scale calc uses them. Otherwise the render keeps padding 15% around the
    // full BSP and you get ugly empty borders on maps that .loc has tightened.
    minimap_world_dx = max_x - min_x;
    minimap_world_dy = max_y - min_y;
    debug("minimap: locs/%s.loc narrowed bounds (%g points), center %v, ortho %g",
          mapname, count, minimap_center, minimap_ortho);
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

    if (head == "center" && num_tokens >= 4) {
        minimap_center = [stof(argv(1)), stof(argv(2)), stof(argv(3))];
        return 1;
    }
    if (head == "ortho" && num_tokens >= 2) {
        minimap_ortho = stof(argv(1));
        return 1;
    }
    if (head == "height" && num_tokens >= 2) {
        minimap_height = stof(argv(1));
        return 1;
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
