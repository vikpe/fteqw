// SPDX-License-Identifier: 0BSD

/*
 * Interactive minimap cull-volume editor.
 *
 *   minimap_editor 0/1           cvar: enable the editor (rendering and
 *                                commands). Off by default.
 *   minimap_editor_show_all 0/1  cvar: 1 to draw every volume regardless
 *                                of distance; 0 (default) draws only those
 *                                within CULL_EDIT_RENDER_RADIUS.
 *
 *   /minimap_editor_add          first call records the player's origin as
 *                                the first corner of a new AABB; second
 *                                call records the opposite corner and
 *                                appends the volume to minimap_volumes.
 *                                Does NOT write the .cull file.
 *   /minimap_editor_remove       deletes the currently highlighted volume
 *                                (closest in range, drawn brighter with a
 *                                yellow accent border).
 *   /minimap_editor_undo         reverses the most recent add or remove.
 *                                Single-level (no redo).
 *   /minimap_editor_export         writes the current in-memory volumes to
 *                                maps/<mapname>.cull. This is the only
 *                                command that touches the file.
 *
 * Rendering: CullEditDrawWireframes paints translucent green fills + edge
 * outlines for every volume in range, with the closest one highlighted in
 * a brighter green + yellow border. The in-flight (between two adds) box
 * is drawn yellow. Called from main.qc after each main renderscene,
 * scissored to the seat viewport.
 *
 * Writes land in <basedir>/<gamedir>/data/maps/<map>.cull (FTE FS sandbox).
 * Copy to the deploy location after dumping.
 */

// Forward declarations (top-down ordering).
void()                                                    CullEditInitTables;
vector()                                                  CullEditPlayerOrigin;
void()                                                    CullEditCachePlayerOrigin;
void(vector mins, vector maxs, vector color, float alpha) CullEditDrawAABB;
float(vector mins, vector maxs)                           CullEditBoxInRange;
float(vector mins, vector maxs)                           CullEditBoxDistanceSq;
void()                                                    CullEditWriteFile;
void(int idx)                                             CullEditRemoveAt;
float(__out vector mins, __out vector maxs)               CullEditInFlightBounds;
void()                                                    CullEditResetState;
void(vector a, vector b, __out vector mins, __out vector maxs) CullEditAABBFromPoints;

// Render radius for volume previews: any volume whose closest point lies
// within this distance from the local player is drawn. ~20 player model
// widths (player bbox is 32 wide; 20 * 32 = 640 QU). Declutters the view
// when many volumes pile up across the map.
#define CULL_EDIT_RENDER_RADIUS 640


// Last-action enum for the single-level undo stack. Stored alongside the
// volume's AABB so undo can either remove (if last was ADD) or re-insert
// (if last was REMOVE).
#define CULL_ACT_NONE   0
#define CULL_ACT_ADD    1
#define CULL_ACT_REMOVE 2

// State for the in-flight edit. `cull_edit_active` toggles between
// start/finish; cull_edit_start is the first corner the user marked.
var float  cull_edit_active = 0;
var vector cull_edit_start  = '0 0 0';

// Index of the currently-highlighted (closest) volume, or -1 if none is
// within range. Recomputed every frame inside CullEditDrawWireframes and
// consumed by /minimap_editor_remove.
var int    cull_edit_highlight = -1;

// Cached player camera origin for the current frame. Captured by main.qc
// inside the seat loop where the player view is active, then reused by
// CullEditPlayerOrigin / CullEditDrawWireframes / minimap.qc's in-flight
// bounds query. Decouples editor state from whatever view is currently
// active when these helpers run - especially important during the
// minimap pass where getviewprop(VF_ORIGIN) returns the minimap camera
// position (high above the map) instead of the player.
var vector cull_edit_player_origin = '0 0 0';

// Last-action record for /minimap_editor_undo. mins/maxs hold the AABB of
// the volume that was added or removed; action says which.
var float  cull_edit_last_action = CULL_ACT_NONE;
var vector cull_edit_last_mins   = '0 0 0';
var vector cull_edit_last_maxs   = '0 0 0';

// 0 (default): editor off. Rendering returns early and all commands print
// a "not enabled" notice. 1: editor active - wireframes drawn, commands
// enabled, bbox outline shown.
var float  autocvar_minimap_editor = 0;

// 0 (default): only draw loaded volumes within CULL_EDIT_RENDER_RADIUS.
// 1: draw every volume regardless of distance. In-flight box always drawn.
var float  autocvar_minimap_editor_show_all = 1;

// Globals for the wireframe pipeline. FTEQCC local arrays of basic types
// have sized inconsistently with var-arrays; hoist scratch buffers and
// lookup tables to file scope where minimap_volumes-style declarations
// work reliably.
var vector cull_edit_corners[8];
var vector cull_edit_projected[8];

// 12 edges as flat (a, b) index pairs into cull_edit_corners; populated
// in CullEditInitTables (called lazily) since FTEQCC's inline array
// initializer has produced runtime boundcheck failures with var-arrays.
var float cull_edit_edges[24];
var float cull_edit_tables_inited = 0;

// ----- commands -------------------------------------------------------------

// Toggling add. First call: record first corner, start preview. Second
// call: record second corner, push the AABB into minimap_volumes. Doesn't
// write the .cull file - use /minimap_editor_export for that.
float() CullEditAddCmd =
{
    if (!autocvar_minimap_editor) {
        println("[minimap_editor] disabled - set minimap_editor 1 first");
        return 1;
    }
    if (!cull_edit_active) {
        cull_edit_start  = CullEditPlayerOrigin();
        cull_edit_active = 1;
        println("[minimap_editor] first corner at %v - run /minimap_editor_add again at the opposite corner", cull_edit_start);
        return 1;
    }

    cull_edit_active = 0;

    vector b = CullEditPlayerOrigin();
    vector mins, maxs;
    CullEditAABBFromPoints(cull_edit_start, b, mins, maxs);

    if (minimap_num_volumes >= MINIMAP_MAX_CULL_VOLUMES) {
        println("[minimap_editor] full (%i volumes); remove some before adding more",
                (int)MINIMAP_MAX_CULL_VOLUMES);
        return 1;
    }
    minimap_volumes[minimap_num_volumes].mins = mins;
    minimap_volumes[minimap_num_volumes].maxs = maxs;
    minimap_num_volumes++;
    minimap_loaded = 1;

    cull_edit_last_action = CULL_ACT_ADD;
    cull_edit_last_mins   = mins;
    cull_edit_last_maxs   = maxs;

    println("[minimap_editor] added volume %v..%v (%d total, unsaved)",
            mins, maxs, (float)minimap_num_volumes);
    return 1;
};

// Discards an in-flight edit if one is open, otherwise removes the
// currently highlighted volume (the closest one in range).
float() CullEditRemoveCmd =
{
    if (!autocvar_minimap_editor) {
        println("[minimap_editor] disabled - set minimap_editor 1 first");
        return 1;
    }

    // Cancel-in-progress takes priority over deleting a finalized volume -
    // an open edit is more "recent" intent than the highlight.
    if (cull_edit_active) {
        cull_edit_active = 0;
        println("[minimap_editor] discarded in-flight volume");
        return 1;
    }

    if (cull_edit_highlight < 0 || cull_edit_highlight >= minimap_num_volumes) {
        println("[minimap_editor] no volume highlighted - move closer to one");
        return 1;
    }
    int idx = cull_edit_highlight;
    vector gone_mins = minimap_volumes[idx].mins;
    vector gone_maxs = minimap_volumes[idx].maxs;

    CullEditRemoveAt(idx);
    cull_edit_highlight = -1;

    cull_edit_last_action = CULL_ACT_REMOVE;
    cull_edit_last_mins   = gone_mins;
    cull_edit_last_maxs   = gone_maxs;

    println("[minimap_editor] removed volume %v..%v (%d remaining, unsaved)",
            gone_mins, gone_maxs, (float)minimap_num_volumes);
    return 1;
};

// Undo the most recent add or remove. Single level (no redo).
float() CullEditUndoCmd =
{
    if (!autocvar_minimap_editor) {
        println("[minimap_editor] disabled - set minimap_editor 1 first");
        return 1;
    }
    if (cull_edit_last_action == CULL_ACT_NONE) {
        println("[minimap_editor] nothing to undo");
        return 1;
    }

    if (cull_edit_last_action == CULL_ACT_ADD) {
        // Find the matching volume (added at the end most recently) and
        // remove it. Search from the back since that's where the add
        // landed; protects against the case where a remove + add chain
        // pushed it elsewhere.
        int found = -1;
        for (int i = minimap_num_volumes - 1; i >= 0; i--) {
            if (minimap_volumes[i].mins == cull_edit_last_mins &&
                minimap_volumes[i].maxs == cull_edit_last_maxs) {
                found = i;
                break;
            }
        }
        if (found < 0) {
            println("[minimap_editor] undo failed - last-added volume not found");
        } else {
            CullEditRemoveAt(found);
            println("[minimap_editor] undid add of %v..%v",
                    cull_edit_last_mins, cull_edit_last_maxs);
        }
    } else if (cull_edit_last_action == CULL_ACT_REMOVE) {
        if (minimap_num_volumes >= MINIMAP_MAX_CULL_VOLUMES) {
            println("[minimap_editor] undo failed - volume table is full");
            return 1;
        }
        minimap_volumes[minimap_num_volumes].mins = cull_edit_last_mins;
        minimap_volumes[minimap_num_volumes].maxs = cull_edit_last_maxs;
        minimap_num_volumes++;
        minimap_loaded = 1;
        println("[minimap_editor] undid remove of %v..%v",
                cull_edit_last_mins, cull_edit_last_maxs);
    }

    cull_edit_last_action = CULL_ACT_NONE;
    return 1;
};

// Writes the current in-memory minimap_volumes to maps/<map>.cull. The
// only command that touches the file system.
float() CullEditExportCmd =
{
    if (!autocvar_minimap_editor) {
        println("[minimap_editor] disabled - set minimap_editor 1 first");
        return 1;
    }
    CullEditWriteFile();
    return 1;
};

// ----- rendering ------------------------------------------------------------

// Populate the edge/face index tables. Doing this at first-use rather than
// via inline initializer syntax avoids FTEQCC quirks around var-array
// initializers that have produced runtime boundcheck failures.
void() CullEditInitTables =
{
    if (cull_edit_tables_inited) return;
    cull_edit_tables_inited = 1;

    // 12 edges (24 indices). Bottom rect, top rect, vertical pillars.
    cull_edit_edges[0]  = 0; cull_edit_edges[1]  = 1;
    cull_edit_edges[2]  = 1; cull_edit_edges[3]  = 2;
    cull_edit_edges[4]  = 2; cull_edit_edges[5]  = 3;
    cull_edit_edges[6]  = 3; cull_edit_edges[7]  = 0;
    cull_edit_edges[8]  = 4; cull_edit_edges[9]  = 5;
    cull_edit_edges[10] = 5; cull_edit_edges[11] = 6;
    cull_edit_edges[12] = 6; cull_edit_edges[13] = 7;
    cull_edit_edges[14] = 7; cull_edit_edges[15] = 4;
    cull_edit_edges[16] = 0; cull_edit_edges[17] = 4;
    cull_edit_edges[18] = 1; cull_edit_edges[19] = 5;
    cull_edit_edges[20] = 2; cull_edit_edges[21] = 6;
    cull_edit_edges[22] = 3; cull_edit_edges[23] = 7;
};

void() CullEditDrawWireframes =
{
    if (!autocvar_minimap_editor) {
        // Cancel any in-flight edit when the editor cvar goes 0 so a
        // later re-enable doesn't pick up where it left off with a stale
        // cull_edit_start (which would otherwise survive across disables
        // and re-finalize at world coordinates the user no longer
        // remembers). Undo state intentionally preserved.
        cull_edit_active    = 0;
        cull_edit_highlight = -1;
        return;
    }
    CullEditInitTables();

    float show_all = autocvar_minimap_editor_show_all;
    vector c_edge_normal     = '0.4 0.4 0.4';
    vector c_edge_highlight  = '1 1 0';      // yellow accent border

    // Find the closest volume for highlight selection, regardless of
    // distance. Squared distance for argmin without sqrt. /remove always
    // operates on whatever is highlighted, so we want highlight to be
    // valid as long as any volume exists - no range gate. Suppressed
    // while an edit is in progress so /remove cancels the in-flight box
    // instead of accidentally removing a nearby committed volume.
    cull_edit_highlight = -1;
    if (!cull_edit_active) {
        float best_d2 = 999999999;
        for (int i = 0; i < minimap_num_volumes; i++) {
            float d2 = CullEditBoxDistanceSq(minimap_volumes[i].mins,
                                             minimap_volumes[i].maxs);
            if (d2 < best_d2) {
                best_d2 = d2;
                cull_edit_highlight = i;
            }
        }
    }

    // Filled-face pass intentionally skipped - the per-face quad fill
    // is unreliable when corners project to off-screen / behind-camera
    // coords (R_BeginPolygon's 2D batcher culls those polygons whole,
    // while drawline clips per-edge). The wireframe outline alone is
    // the source of truth.
    vector edit_mins;
    vector edit_maxs;
    float has_edit = CullEditInFlightBounds(edit_mins, edit_maxs);

    // Wireframe pass.
    for (int i = 0; i < minimap_num_volumes; i++) {
        if (!show_all &&
            !CullEditBoxInRange(minimap_volumes[i].mins, minimap_volumes[i].maxs)) {
            continue;
        }
        float is_highlight = (i == cull_edit_highlight);
        vector c = is_highlight ? c_edge_highlight : c_edge_normal;
        float  a = is_highlight ? 1.0 : 0.6;
        CullEditDrawAABB(minimap_volumes[i].mins, minimap_volumes[i].maxs, c, a);
    }
    if (has_edit) {
        CullEditDrawAABB(edit_mins, edit_maxs, '1 1 0', 1);
    }
};

// 12-edge wireframe of an AABB. Projects 8 world corners and strokes 2D
// line segments. Edges that cross the camera near plane are clipped in
// world space against the plane so the visible portion of every edge
// renders as a stable, closed shape. project() on a point behind the
// camera returns wrap-around coords that jitter with view changes, so
// without this clip the box's vertices appear to drift as you look or
// move; the clip pins them to the camera plane instead.
void(vector mins, vector maxs, vector color, float alpha) CullEditDrawAABB =
{
    // Clamp AABB to a reasonable window around the camera. Cull-file
    // volumes often carry maxs.z = 99999 (the "cull above" convention);
    // unclamped those top corners project thousands of pixels above the
    // viewport and the 2D batcher misbehaves. The underlying volume
    // data is untouched - clamping only affects what gets projected.
    vector cam      = getviewprop(VF_ORIGIN);
    float  cap      = 4096;
    float  vmins_x  = (mins.x < cam.x - cap) ? cam.x - cap : mins.x;
    float  vmins_y  = (mins.y < cam.y - cap) ? cam.y - cap : mins.y;
    float  vmins_z  = (mins.z < cam.z - cap) ? cam.z - cap : mins.z;
    float  vmaxs_x  = (maxs.x > cam.x + cap) ? cam.x + cap : maxs.x;
    float  vmaxs_y  = (maxs.y > cam.y + cap) ? cam.y + cap : maxs.y;
    float  vmaxs_z  = (maxs.z > cam.z + cap) ? cam.z + cap : maxs.z;

    cull_edit_corners[0] = [vmins_x, vmins_y, vmins_z];
    cull_edit_corners[1] = [vmaxs_x, vmins_y, vmins_z];
    cull_edit_corners[2] = [vmaxs_x, vmaxs_y, vmins_z];
    cull_edit_corners[3] = [vmins_x, vmaxs_y, vmins_z];
    cull_edit_corners[4] = [vmins_x, vmins_y, vmaxs_z];
    cull_edit_corners[5] = [vmaxs_x, vmins_y, vmaxs_z];
    cull_edit_corners[6] = [vmaxs_x, vmaxs_y, vmaxs_z];
    cull_edit_corners[7] = [vmins_x, vmaxs_y, vmaxs_z];

    for (int i = 0; i < 8; i++) {
        cull_edit_projected[i] = project(cull_edit_corners[i]);
    }

    vector cam_pos = cam;
    vector angles  = getviewprop(VF_ANGLES);
    makevectors(angles);
    float near_dist = 4;

    for (int k = 0; k < 12; k++) {
        int i0 = (int)cull_edit_edges[k*2];
        int i1 = (int)cull_edit_edges[k*2 + 1];
        vector w0 = cull_edit_corners[i0];
        vector w1 = cull_edit_corners[i1];

        // Signed distance from the near plane. vec * vec is dot product
        // in QC. Positive = in front of the camera.
        float d0 = (w0 - cam_pos) * v_forward - near_dist;
        float d1 = (w1 - cam_pos) * v_forward - near_dist;

        vector p0 = '0 0 0';
        vector p1 = '0 0 0';
        float t;
        if (d0 > 0 && d1 > 0) {
            p0 = cull_edit_projected[i0];
            p1 = cull_edit_projected[i1];
        } else if (d0 > 0) {
            t = d0 / (d0 - d1);
            p0 = cull_edit_projected[i0];
            p1 = project(w0 + (w1 - w0) * t);
        } else if (d1 > 0) {
            t = d1 / (d1 - d0);
            p0 = project(w1 + (w0 - w1) * t);
            p1 = cull_edit_projected[i1];
        } else {
            continue;  // both endpoints behind the camera
        }
        drawline(1, p0, p1, color, alpha);
    }
};

// ----- helpers --------------------------------------------------------------

// Returns the player camera origin captured at the top of this frame.
// Cached so calls during the minimap pass (where VF_ORIGIN is the minimap
// camera) still see the player's actual location. The cache is refreshed
// by CullEditCachePlayerOrigin from main.qc per seat.
vector() CullEditPlayerOrigin =
{
    return cull_edit_player_origin;
};

// Captures the current view's origin into the per-frame player cache.
// main.qc calls this once per seat while the player view is active, so
// subsequent CullEditDrawWireframes / CullEditInFlightBounds reads see
// the player's position rather than whatever view is current at the
// time of the call.
void() CullEditCachePlayerOrigin =
{
    cull_edit_player_origin = getviewprop(VF_ORIGIN);
};

// AABB-vs-sphere overlap: true when the closest point on the box lies
// within CULL_EDIT_RENDER_RADIUS of the local player. No trace, stable
// through walls so volumes don't flicker as the player turns.
float(vector mins, vector maxs) CullEditBoxInRange =
{
    float r = CULL_EDIT_RENDER_RADIUS;
    return CullEditBoxDistanceSq(mins, maxs) <= r * r;
};

// Squared distance from the local player to the closest point on the
// AABB. Squared so callers can argmin without sqrt. Returns 0 when the
// player is inside the box.
float(vector mins, vector maxs) CullEditBoxDistanceSq =
{
    vector p = CullEditPlayerOrigin();
    float dx = 0, dy = 0, dz = 0;
    if      (p.x < mins.x) dx = mins.x - p.x;
    else if (p.x > maxs.x) dx = p.x - maxs.x;
    if      (p.y < mins.y) dy = mins.y - p.y;
    else if (p.y > maxs.y) dy = p.y - maxs.y;
    if      (p.z < mins.z) dz = mins.z - p.z;
    else if (p.z > maxs.z) dz = p.z - maxs.z;
    return dx*dx + dy*dy + dz*dz;
};

// Normalizes two arbitrary points into a min/max AABB by taking the
// per-axis min/max. Shared by CullEditAddCmd (committing) and
// CullEditInFlightBounds (live preview) so the two stay consistent.
void(vector a, vector b, __out vector mins, __out vector maxs) CullEditAABBFromPoints =
{
    mins = [min(a.x, b.x), min(a.y, b.y), min(a.z, b.z)];
    maxs = [max(a.x, b.x), max(a.y, b.y), max(a.z, b.z)];
};

// If a volume edit is in progress, fills mins/maxs with the current AABB
// (cull_edit_start <-> live camera position) and returns 1. Returns 0
// when no edit is active. Lets minimap.qc apply the in-flight box as a
// temporary cull volume so the user sees the culling effect live.
float(__out vector mins, __out vector maxs) CullEditInFlightBounds =
{
    if (!cull_edit_active) {
        mins = '0 0 0';
        maxs = '0 0 0';
        return 0;
    }
    vector b = CullEditPlayerOrigin();
    CullEditAABBFromPoints(cull_edit_start, b, mins, maxs);
    return 1;
};

// Shifts minimap_volumes[idx+1..] down by one and decrements the count.
// Shared by /minimap_editor_remove and /minimap_editor_undo (ADD path).
void(int idx) CullEditRemoveAt =
{
    if (idx < 0 || idx >= minimap_num_volumes) return;
    for (int i = idx; i < minimap_num_volumes - 1; i++) {
        minimap_volumes[i].mins = minimap_volumes[i + 1].mins;
        minimap_volumes[i].maxs = minimap_volumes[i + 1].maxs;
    }
    minimap_num_volumes--;
};

// Wipes all editor state. Called on map load (cull_edit_start is in
// world coords for the old map; undo payload references volumes that no
// longer exist) and from /minimap reload (volume array gets rebuilt). Not
// called from the cvar-disable path - that just halts rendering and lets
// undo state survive so re-enabling can still revert.
void() CullEditResetState =
{
    cull_edit_active      = 0;
    cull_edit_start       = '0 0 0';
    cull_edit_highlight   = -1;
    cull_edit_last_action = CULL_ACT_NONE;
    cull_edit_last_mins   = '0 0 0';
    cull_edit_last_maxs   = '0 0 0';
};

// Writes maps/<map>.cull from the current in-memory minimap_volumes
// state and also dumps the content to console + system clipboard. The
// file write goes through the engine's CSQC sandbox (which forces a
// data/ prefix - the file ends up at <gamedir>/data/maps/<map>.cull,
// not the gamedir root where cfg_save / writeconfig land). Web wrappers
// that only surface gamedir-root files won't see it; the clipboard and
// console dumps are fallbacks so the user can paste/copy elsewhere.
//
// Comments in any previous file are not preserved - this is a clean
// rebuild from minimap_volumes.
void() CullEditWriteFile =
{
    // Build the full file content as one string so we can hand the same
    // text to fputs, the clipboard, and the console.
    string body = "# regenerated by hub_addon minimap editor\n";
    for (int i = 0; i < minimap_num_volumes; i++) {
        vector mn = minimap_volumes[i].mins;
        vector mx = minimap_volumes[i].maxs;
        body = strcat(body, sprintf("%i %i %i   %i %i %i\n",
                                    (int)mn.x, (int)mn.y, (int)mn.z,
                                    (int)mx.x, (int)mx.y, (int)mx.z));
    }

    string path = sprintf("maps/%s.cull", mapname);
    filestream fh = fopen(path, FILE_WRITE);
    if (fh >= 0) {
        fputs(fh, body);
        fclose(fh);
        println("[minimap_editor] wrote %s (%d volumes; engine read path: data/%s)",
                path, (float)minimap_num_volumes, path);
    } else {
        println("[minimap_editor] file write failed for %s - clipboard/console copy below still works",
                path);
    }

    // Clipboard: cliptype 0 = system clipboard. Lets the user paste the
    // exact text into their .cull file regardless of where the engine's
    // FS sandbox put it.
    clipboard_set(0, body);
    println("[minimap_editor] copied %d volumes to clipboard", (float)minimap_num_volumes);

    // Console echo as the final fallback (in case clipboard_set is
    // unavailable on this platform - it's part of an extension that
    // some builds may strip).
    println("---- maps/%s.cull ----", mapname);
    print(body);
    println("---- end ----");
};
