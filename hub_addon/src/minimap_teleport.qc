// SPDX-License-Identifier: 0BSD

/*
 * Minimap click-to-teleport.
 *
 * Maps a screen-space click inside the minimap viewport back to a world XY,
 * snaps to the nearest floor-anchor pickup, and issues `setpos`.
 *
 * Routed from CSQC_InputEvent in main.qc via MinimapInputEvent.
 *
 * `setpos` is forwarded to the server (cl_main.c:6092) which gates it on
 * SV_MayCheat. On a local listen server with cheats allowed it teleports
 * the player into MOVETYPE_NOCLIP at the given coords; on a remote server
 * without cheats it prints a refusal; in demo/qtv playback there is no
 * server to receive the command and it is silently dropped. The caller
 * doesn't need to know which - the engine handles all three.
 */

// Lift above the floor for both the bbox fit check and the final setpos.
// Quake's player bbox is mins.z = -24 (feet) to maxs.z = +32 (head), so a
// lift of 24 would put the feet exactly on the floor - on a slope, the
// slope keeps rising under the bbox and clips the bottom, making fit
// checks always fail. 40 gives 16 units of headroom under the feet,
// enough to clear a 45 deg slope across the bbox half-width (16 * tan45
// = 16). The player drops the extra 16 units after the teleport - no
// visible difference since they're in noclip anyway.
#define MINIMAP_TELEPORT_Z_LIFT 40

// Forward declarations (top-down ordering).
float(vector cursor)                                                 MinimapTeleport;
float(vector screen,    __out vector world)                          MinimapScreenToWorld;
float(vector click_xy,  __out vector dest_xy, __out float floor_z)   MinimapFindNearestFloor;
float(vector click_xy,  __out float floor_z)                         MinimapTraceFloorAt;
float(vector xy, float floor_z)                                      MinimapCanStandAt;

// ----- entry point (called from main.qc:CSQC_InputEvent) --------------------

// Input router handler. Self-gates on minimap state: minimap off or event
// is not a left-mouse-down -> 0 (passthrough). Inside the minimap rect ->
// 1 (consumed, teleport issued or rejected silently). Outside the rect ->
// 0 (passthrough, e.g. mouse1 inside the main view still triggers +attack).
float(float evtype, float scanx, float chary, float devid) MinimapInputEvent =
{
    if (autocvar_minimap_mode == MINIMAP_OFF) return 0;
    if (evtype != IE_KEYDOWN || scanx != K_MOUSE1) return 0;
    return MinimapTeleport(getmousepos());
};

// Handles a left-click at screen position `cursor`. Returns 1 if the click
// landed inside the minimap viewport (consume - prevents the engine from
// treating it as a +attack), 0 otherwise.
//
// "Parachute drop" semantics: trace straight down from the click XY,
// stepping past cull-volume geometry (the same volumes the minimap uses
// to hide roofs) so we land on the floor visually shown on the minimap.
// If straight-down misses (click in void / off-map / on a wall),
// MinimapFindNearestFloor expands outward in concentric rings to find
// the closest XY that does have floor. No teleport if both fail.
float(vector cursor) MinimapTeleport =
{
    vector click_xy;
    if (!MinimapScreenToWorld(cursor, click_xy)) {
        return 0;
    }
    vector dest_xy;
    float  floor_z;
    if (!MinimapFindNearestFloor(click_xy, dest_xy, floor_z)) {
        return 1;
    }
    localcmd(sprintf("setpos %g %g %g\n",
                     dest_xy.x, dest_xy.y,
                     floor_z + MINIMAP_TELEPORT_Z_LIFT));
    return 1;
};

// ----- helpers --------------------------------------------------------------

// Inverse of MinimapRender's projection, computed from the engine-side
// project() snapshot taken during render. Returns 1 and writes world XY
// into `world` when `screen` lies inside the cached viewport rect; Z is
// left at 0 (callers use the snapped entity's Z instead).
//
// The projection is affine in world XY, so caching project() at three
// reference points fully determines it:
//   screen_at(w) = center_screen + (w.x - cx) * wx_delta + (w.y - cy) * wy_delta
// where center_screen, wx_delta, wy_delta come from MinimapRender. We
// invert the 2x2 ((ax bx) (ay by)) at click time. This avoids hardcoding
// any axis-convention assumption (which renderers handle slightly
// differently) - whatever project() does, the inverse follows.
float(vector screen, __out vector world) MinimapScreenToWorld =
{
    world = '0 0 0';
    if (!minimap_view_valid) {
        return 0;
    }
    vector vmin  = minimap_view_rect.min;
    vector vsize = minimap_view_rect.size;
    if (vsize.x <= 0 || vsize.y <= 0) {
        return 0;
    }
    if (screen.x < vmin.x || screen.x >= vmin.x + vsize.x ||
        screen.y < vmin.y || screen.y >= vmin.y + vsize.y) {
        return 0;
    }
    float ax = minimap_view_wx_delta.x;
    float ay = minimap_view_wx_delta.y;
    float bx = minimap_view_wy_delta.x;
    float by = minimap_view_wy_delta.y;
    float det = ax * by - bx * ay;
    if (det == 0) {
        return 0;  // degenerate - shouldn't happen with a valid view
    }
    float dsx = screen.x - minimap_view_center_screen.x;
    float dsy = screen.y - minimap_view_center_screen.y;
    float dwx = ( by * dsx - bx * dsy) / det;
    float dwy = (-ay * dsx + ax * dsy) / det;
    world.x = minimap_center.x + dwx;
    world.y = minimap_center.y + dwy;
    return 1;
};

// Concentric XY ring search for the closest column that has a real
// floor a player can stand on. Tries the click XY first - the cheap
// fast path. On miss, samples expanding rings (smaller radius first)
// and returns the first hit; every sample on ring r sits exactly r
// units from the click, so first-hit IS closest. Rings share uniform
// arc spacing so the pattern reads as a polar grid.
//
// Outward-shift retry: when a ring sample finds floor but the player
// center wouldn't fit there (e.g. the sample sits near the inside of
// a wall, and the click is on the wrong side of that wall), shift the
// sample one player-width further from the click and re-test. The
// wall is typically between the click and the floor, so backing off
// puts us clear.
//
// Radii cap at the largest entry in minimap_find_radii.
#define MINIMAP_FIND_SHIFT 32
float(vector click_xy, __out vector dest_xy, __out float floor_z) MinimapFindNearestFloor =
{
    minimap_debug_click_valid = 1;
    minimap_debug_click_xy    = click_xy;
    int n_slot = MINIMAP_FIND_RING_COUNT * MINIMAP_FIND_MAX_DIRS;
    for (int i = 0; i < n_slot; i++) {
        minimap_debug_sample_state[i] = MINIMAP_SAMPLE_UNTESTED;
    }

    if (MinimapTraceFloorAt(click_xy, floor_z) &&
        MinimapCanStandAt(click_xy, floor_z)) {
        dest_xy = click_xy;
        return 1;
    }
    float two_pi = M_PI * 2;
    for (int r = 0; r < MINIMAP_FIND_RING_COUNT; r++) {
        int n_dir = (int)minimap_find_dirs[r];
        float radius = minimap_find_radii[r];
        // Test every direction on this ring; pick the hit whose
        // walk-back endpoint sits closest to the click. All samples in
        // the ring are equidistant from the click, but the walls in
        // between vary, so the walked-back positions differ.
        float  has_best     = 0;
        float  best_dist_sq = 0;
        vector best_xy      = '0 0 0';
        float  best_floor_z = 0;
        for (int d = 0; d < n_dir; d++) {
            int idx = r * MINIMAP_FIND_MAX_DIRS + d;
            float a  = ((float)d / n_dir) * two_pi;
            vector candidate = [click_xy.x + cos(a) * radius,
                                click_xy.y + sin(a) * radius, 0];
            if (!MinimapTraceFloorAt(candidate, floor_z) ||
                !MinimapCanStandAt(candidate, floor_z)) {
                minimap_debug_sample_state[idx] = MINIMAP_SAMPLE_MISS;
                continue;
            }
            minimap_debug_sample_state[idx] = MINIMAP_SAMPLE_HIT;
            // Walk the player bbox from this candidate toward the click;
            // trace_endpos is the closest valid landing for this dir.
            float standing_z = floor_z + MINIMAP_TELEPORT_Z_LIFT;
            tracebox([candidate.x,  candidate.y,  standing_z],
                     '-16 -16 -24', '16 16 32',
                     [click_xy.x,   click_xy.y,   standing_z],
                     MOVE_NORMAL | MOVE_NOMONSTERS, world);
            float dx = trace_endpos.x - click_xy.x;
            float dy = trace_endpos.y - click_xy.y;
            float d2 = dx * dx + dy * dy;
            if (!has_best || d2 < best_dist_sq) {
                has_best     = 1;
                best_dist_sq = d2;
                best_xy      = [trace_endpos.x, trace_endpos.y, 0];
                best_floor_z = floor_z;
            }
        }
        if (has_best) {
            dest_xy = best_xy;
            floor_z = best_floor_z;
            return 1;
        }
    }
    dest_xy = '0 0 0';
    return 0;
};

// Stand test: can a player-sized bbox actually fit at this XY/floor_z?
// Degenerate tracebox at the standing position (start == end) just
// runs the engine's overlap test - same primitive player physics uses
// for collision. trace_startsolid==1 means any part of the bbox is in
// solid (walls, ceilings, or floor brush itself), so we reject. This
// is stricter than a single pointcontents at the center: the center
// can be in air while the edges clip a nearby wall.
float(vector xy, float floor_z) MinimapCanStandAt =
{
    vector stand = [xy.x, xy.y, floor_z + MINIMAP_TELEPORT_Z_LIFT];
    tracebox(stand, '-16 -16 -24', '16 16 32', stand,
             MOVE_NORMAL | MOVE_NOMONSTERS, world);
    return !trace_startsolid;
};

// Traceline straight down from above `click_xy` to find a surface a
// player can actually stand on. Returns 1 and writes the floor's Z into
// `floor_z` on a hit; returns 0 if no usable surface was found.
//
// Rejected up front:
//   - click_xy outside the narrowed playable AABB (minimap_world_dx/dy
//     around minimap_center). MinimapNarrowByTraceline already scanned
//     a grid and shrank the bbox to cells with ceiling+air+floor, so
//     anything outside is guaranteed not to be playable - no need to
//     re-derive it per click.
//
// Rejected during the trace:
//   - Inside a minimap cull volume (configured roofs) - walk past, the
//     visible floor is below.
//   - Sky / PLAYERCLIP / MONSTERCLIP surfaces - false floors. setpos
//     onto sky drops the player into void; clips are invisible. The
//     whole column is given up (return 0) since brush depth is unknown
//     and stepping 1 unit into a multi-unit brush traps the next trace
//     in solid. The ring search picks a neighbouring column instead.
float(vector click_xy, __out float floor_z) MinimapTraceFloorAt =
{
    floor_z = 0;

    // Bounds check against the narrowed playable AABB (set in
    // MinimapNarrowByTraceline). Anything outside is the exterior hull
    // or void - same surfaces that produced false positives before.
    float bbox_hx = minimap_world_dx * 0.5;
    float bbox_hy = minimap_world_dy * 0.5;
    if (bbox_hx <= 0 || bbox_hy <= 0) {
        return 0;  // bounds not yet derived
    }
    if (click_xy.x < minimap_center.x - bbox_hx ||
        click_xy.x > minimap_center.x + bbox_hx ||
        click_xy.y < minimap_center.y - bbox_hy ||
        click_xy.y > minimap_center.y + bbox_hy) {
        return 0;
    }

    float reject_bits = CONTENTBIT_SKY | CONTENTBIT_PLAYERCLIP | CONTENTBIT_MONSTERCLIP;
    float top_z      = minimap_world_top_z + 32;
    float bottom_z   = minimap_center.z - 4096;
    vector ray_start = [click_xy.x, click_xy.y, top_z];
    vector ray_end   = [click_xy.x, click_xy.y, bottom_z];
    float steps      = 16;
    while (steps > 0) {
        steps--;
        traceline(ray_start, ray_end, MOVE_NORMAL | MOVE_NOMONSTERS, world);
        if (trace_fraction == 1) {
            return 0;
        }
        float vol = MinimapPointInCullVolume(trace_endpos);
        if (vol >= 0) {
            // Inside a configured cull volume - jump to its bottom.
            ray_start = [trace_endpos.x, trace_endpos.y,
                         minimap_volumes[vol].mins.z - 1];
            if (ray_start.z <= ray_end.z) {
                return 0;
            }
            continue;
        }
        if (trace_endcontents & reject_bits) {
            return 0;
        }
        floor_z = trace_endpos.z;
        return 1;
    }
    return 0;
};

