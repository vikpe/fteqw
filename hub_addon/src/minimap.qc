// SPDX-License-Identifier: 0BSD

/*
 * Top-down minimap render pass.
 *
 * Renders an orthographic view from high above the map, with roofs/upper
 * geometry hidden via per-map AABB cull volumes (loaded in minimap_load.qc).
 * The 2D player overlay is drawn after renderscene by minimap_players.qc.
 *
 * Cvars:
 *   minimap_mode             0=off 1=pip 2=split 3=full
 *
 * Requires engine support for VF_CULLVOLUME.
 */

// Split-mode horizontal partition: player view on the left, minimap on
// the right. 0.50 = each gets half the screen width.
#define MINIMAP_SPLIT_MAIN_FRAC 0.50

// Screen-pixel margin between the world AABB and the viewport edge, applied
// uniformly on all four sides.
#define MINIMAP_MARGIN_PX 8

// Forward declarations (top-down ordering).
void(float mode, float vw, float vh, __out minimap_rect_t r) MinimapViewport;

void(float vwidth, float vheight) MinimapRender =
{
    float mode = autocvar_minimap_mode;
    if (mode <= MINIMAP_OFF) {
        return;
    }

    // Pause while the engine fast-parses through a demo seek - player
    // positions/stats churn through transient mid-seek values and would
    // just flicker the overlay.
    if (isdemoseeking()) {
        return;
    }

    if (minimap_loaded_for != mapname) {
        MinimapLoad();
    }

    vector center      = minimap_center;
    float height_above = minimap_height;

    minimap_rect_t viewport;
    MinimapViewport(mode, vwidth, vheight, viewport);
    vector vmin  = viewport.min;
    vector vsize = viewport.size;

    // VF_FOV in orthographic mode is "world units across the viewport".
    // Scale = world units per screen pixel, uniform on both axes; pick the
    // tighter dimension so the world AABB just fits without stretching.
    //
    // Camera angles '90 0 0' (looking straight down) rotate the world axes:
    // screen horizontal = world Y, screen vertical = world X. So fov_x
    // covers world_dy and fov_y covers world_dx.
    //
    // MINIMAP_MARGIN_PX of slack on each side: shrink the effective fit-to
    // area, then let the larger fov values expand the rendered world range
    // so the world AABB lands MARGIN_PX inside the viewport.
    float inner_w = max(1, vsize.x - MINIMAP_MARGIN_PX * 2);
    float inner_h = max(1, vsize.y - MINIMAP_MARGIN_PX * 2);
    float need_x  = minimap_world_dy / inner_w;
    float need_y  = minimap_world_dx / inner_h;
    float scale   = (need_x > need_y) ? need_x : need_y;
    float fov_x   = vsize.x * scale;
    float fov_y   = vsize.y * scale;

    // PVS-culling is keyed to the player's position. With the camera lifted
    // far above the map the player's PVS doesn't cover the visible
    // orthographic frustum, so leaves outside it (and the entities in them)
    // would be culled. Disable PVS for the minimap pass and restore after.
    float prev_novis = cvar("r_novis");
    cvar_set("r_novis", "1");

    // The engine draws scr_autoid nametags + health/armor/weapon overlays
    // from inside renderscene (pr_csqc.c PF_R_RenderScene -> R_DrawNameTags),
    // using the current viewport. Spectators want autoid in the main view,
    // but the minimap pass would re-draw them on top of our own markers.
    // Suppress just for our renderscene; main view restores them. Both
    // scr_autoid and scr_autoid_team must be cleared - in teamplay, the
    // team variant still draws teammates regardless of scr_autoid.
    float prev_autoid      = cvar("scr_autoid");
    float prev_autoid_team = cvar("scr_autoid_team");
    cvar_set("scr_autoid", "0");
    cvar_set("scr_autoid_team", "0");

    // Top-down minimap doesn't need the skybox - it just adds bright clutter
    // around the map. r_fastsky=1 short-circuits the sky pass to a flat color.
    float prev_fastsky = cvar("r_fastsky");
    cvar_set("r_fastsky", "1");

    // Black background: 2D draws issued before clearscene/renderscene land
    // behind the scene (renderscene leaves non-geometry pixels alone), so a
    // drawfill here gives empty viewport regions a solid black canvas
    // instead of bleeding the main game view through (matters most in PIP).
    drawfill(vmin, vsize, '0 0 0', 1);
    drawfill('0 0 0', '0 0 0', '1 1 1', 1);  // reset blendmode (FTE quirk)

    clearscene();
    setviewprop(VF_DRAWWORLD,      1);
    setviewprop(VF_VIEWENTITY,     0);
    setviewprop(VF_DRAWENGINESBAR, 0);
    setviewprop(VF_DRAWCROSSHAIR,  0);
    setviewprop(VF_PERSPECTIVE,    0);
    setviewprop(VF_FOV,            [fov_x, fov_y, 0]);
    setviewprop(VF_ORIGIN,         [center.x, center.y, center.z + height_above]);
    setviewprop(VF_ANGLES,         '90 0 0');
    setviewprop(VF_MIN,            vmin);
    setviewprop(VF_SIZE,           vsize);

    for (int i = 0; i < minimap_num_volumes; i++) {
        setviewprop(VF_CULLVOLUME, i,
                    minimap_volumes[i].mins,
                    minimap_volumes[i].maxs);
    }
    // Live preview: apply the editor's in-flight volume as a temporary
    // extra cull volume so the user sees its culling effect on the
    // minimap as they move around adjusting the second corner. Only
    // appended (engine resets numcullvolumes on next clearscene) and
    // only if there's room under the cap.
    vector edit_mins, edit_maxs;
    if (CullEditInFlightBounds(edit_mins, edit_maxs) &&
        minimap_num_volumes < MINIMAP_MAX_CULL_VOLUMES) {
        setviewprop(VF_CULLVOLUME, minimap_num_volumes,
                    edit_mins, edit_maxs);
    }

    // MASK_LOCAL pulls in the POV player. XrayResetPlayer sets the local
    // player's drawmask to MASK_LOCAL (and 0 for everyone else), so the
    // engine's normal "hide self in first-person" suppression is bypassed.
    vector cam_origin = [center.x, center.y, center.z + height_above];
    addentities(MASK_ENGINE | MASK_LOCAL);
    MinimapSpawnOccludedDoppelgangers(cam_origin);
    renderscene();
    MinimapRemoveDoppelgangers();

    cvar_set("r_novis",        ftos(prev_novis));
    cvar_set("scr_autoid",     ftos(prev_autoid));
    cvar_set("scr_autoid_team", ftos(prev_autoid_team));
    cvar_set("r_fastsky",      ftos(prev_fastsky));

    // Overlay players (project() reads the view state we just set).
    MinimapDrawPlayers(cam_origin);

    drawsetcliparea(vmin.x, vmin.y, vsize.x, vsize.y);

    // "You are here" magenta dot for free-fly spectators (tracked specs
    // and live players already get a real player marker above).
    if (MinimapIsFreeflySpectator()) {
        vector cam_screen = project(CullEditPlayerOrigin());
        drawfill([cam_screen.x - 2, cam_screen.y - 2, 0], '4 4 0', '1 0 1', 1);
    }

    // In-flight cull-volume editor preview: yellow stroked rectangle of
    // the volume's XY footprint. Helps the user see where the second
    // corner will land before they commit. Minimap is orthographic
    // top-down, so any Z inside the AABB projects to the same XY screen
    // coords - pick the midpoint.
    vector ce_mins, ce_maxs;
    if (CullEditInFlightBounds(ce_mins, ce_maxs)) {
        float z = (ce_mins.z + ce_maxs.z) * 0.5;
        vector p00 = project([ce_mins.x, ce_mins.y, z]);
        vector p10 = project([ce_maxs.x, ce_mins.y, z]);
        vector p11 = project([ce_maxs.x, ce_maxs.y, z]);
        vector p01 = project([ce_mins.x, ce_maxs.y, z]);
        drawline(1, p00, p10, '1 1 0', 1);
        drawline(1, p10, p11, '1 1 0', 1);
        drawline(1, p11, p01, '1 1 0', 1);
        drawline(1, p01, p00, '1 1 0', 1);
    }

    // Debug: cyan outline of the world bounding box used by the minimap
    // projection (post-derivation). Editor-only - helps confirm
    // center/extents match the playable area while tuning cull volumes.
    float hx = minimap_world_dx * 0.5;
    float hy = minimap_world_dy * 0.5;
    if (autocvar_minimap_editor && hx > 0 && hy > 0) {
        float bz = minimap_center.z;
        vector b00 = project([minimap_center.x - hx, minimap_center.y - hy, bz]);
        vector b10 = project([minimap_center.x + hx, minimap_center.y - hy, bz]);
        vector b11 = project([minimap_center.x + hx, minimap_center.y + hy, bz]);
        vector b01 = project([minimap_center.x - hx, minimap_center.y + hy, bz]);
        drawline(1, b00, b10, '0 1 1', 1);
        drawline(1, b10, b11, '0 1 1', 1);
        drawline(1, b11, b01, '0 1 1', 1);
        drawline(1, b01, b00, '0 1 1', 1);
    }

    drawresetcliparea();
};

// Player view rect. .size = '0 0 0' means the main view should not render
// (minimap is in FULL mode). Called from main.qc CSQC_UpdateView.
void(float vw, float vh, __out minimap_rect_t r) MinimapMainViewport =
{
    r.min = '0 0 0';
    switch (autocvar_minimap_mode) {
    case MINIMAP_SPLIT:
        r.size = [vw * MINIMAP_SPLIT_MAIN_FRAC, vh, 0];
        break;
    case MINIMAP_FULL:
        r.size = '0 0 0';
        break;
    default:
        r.size = [vw, vh, 0];
        break;
    }
};

// Minimap viewport rect for the given display mode.
void(float mode, float vw, float vh, __out minimap_rect_t r) MinimapViewport =
{
    r.min  = '0 0 0';
    r.size = '0 0 0';
    switch (mode) {
    case MINIMAP_PIP:
        {
            // Inner area sized to the map's screen-space aspect, capped at
            // 16:9 so very wide maps don't produce an ultra-thin strip. Plus
            // MINIMAP_MARGIN_PX on every side. Width is capped at 25% of
            // the screen; height falls out from the aspect. Pinned to the
            // top-right corner with the same margin from both edges.
            //
            // Camera angles '90 0 0' map world Y to screen X and world X to
            // screen Y, so screen aspect = world_dy / world_dx.
            float margin = MINIMAP_MARGIN_PX;
            float aspect = 16.0 / 9.0;
            if (minimap_world_dx > 0 && minimap_world_dy > 0) {
                aspect = minimap_world_dy / minimap_world_dx;
                if (aspect > 16.0 / 9.0) aspect = 16.0 / 9.0;
            }
            float inner_w = vw * 0.25 - margin * 2;
            float inner_h = inner_w / aspect;
            float max_inner_h = vh - margin * 4;
            if (inner_h > max_inner_h) {
                inner_h = max_inner_h;
                inner_w = inner_h * aspect;
            }
            float pip_w = inner_w + margin * 2;
            float pip_h = inner_h + margin * 2;
            r.min  = [vw - margin - pip_w, margin, 0];
            r.size = [pip_w, pip_h, 0];
        }
        break;
    case MINIMAP_SPLIT:
    default:
        {
            // Letterbox to the map's aspect inside the allotted region so
            // the world AABB fills the available space on both axes.
            // SPLIT confines the box to the right half; FULL uses the whole
            // viewport. Camera angles '90 0 0' map world Y to screen X and
            // world X to screen Y, so screen-aspect = world_dy / world_dx.
            float avail_w;
            float avail_h = vh;
            float origin_x;
            if (mode == MINIMAP_SPLIT) {
                avail_w  = vw * (1 - MINIMAP_SPLIT_MAIN_FRAC);
                origin_x = vw * MINIMAP_SPLIT_MAIN_FRAC;
            } else {
                avail_w  = vw;
                origin_x = 0;
            }
            if (minimap_world_dx > 0 && minimap_world_dy > 0) {
                float map_aspect = minimap_world_dy / minimap_world_dx;
                float target_w = avail_h * map_aspect;
                float target_h = avail_h;
                if (target_w > avail_w) {
                    target_w = avail_w;
                    target_h = avail_w / map_aspect;
                }
                r.min  = [origin_x + (avail_w - target_w) * 0.5,
                          (avail_h - target_h) * 0.5, 0];
                r.size = [target_w, target_h, 0];
            } else {
                r.min  = [origin_x, 0, 0];
                r.size = [avail_w, avail_h, 0];
            }
        }
        break;
    }
};
