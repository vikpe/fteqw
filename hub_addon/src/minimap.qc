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
        minimap_view_valid = 0;
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

    // Snapshot the world->screen transform via project(). The minimap
    // camera's view is still active here (renderscene didn't clear it), so
    // project() returns coords in the current viewport. Caching the engine's
    // own output dodges any axis-convention ambiguity - the inverse at
    // click time is purely linear-algebra (minimap_teleport.qc).
    minimap_view_valid          = 1;
    minimap_view_rect           = viewport;
    minimap_view_center_screen  = project(minimap_center);
    minimap_view_wx_delta       = project(minimap_center + '1 0 0') - minimap_view_center_screen;
    minimap_view_wy_delta       = project(minimap_center + '0 1 0') - minimap_view_center_screen;

    // External heatmap: web app feeds a "x0 y0 x1 y1 ..." cvar via
    // Module.setMinimapHeatmap. Two-pass render:
    //   1. Compute a density energy per point (distance-weighted count
    //      of neighbours within HEATMAP_NEIGHBOUR_R world units).
    //   2. Map energy to a green->yellow->red color and draw a soft,
    //      additively-blended blob per point at that color. Overlapping
    //      blobs accumulate brightness, giving clusters a cloud-like
    //      glow with bright cores while isolated points stay faint.
    // Drawn before players so player markers stay readable on hot spots.
    if (autocvar_minimap_heatmap != "") {
        #define HEATMAP_MAX_POINTS 256
        #define HEATMAP_NEIGHBOUR_R 384  // world units
        float hxs[HEATMAP_MAX_POINTS];
        float hys[HEATMAP_MAX_POINTS];
        float energies[HEATMAP_MAX_POINTS];
        int   hcount   = 0;
        float hn       = tokenize(autocvar_minimap_heatmap);
        for (int i = 0; i + 1 < hn && hcount < HEATMAP_MAX_POINTS; i += 2) {
            hxs[hcount] = stof(argv(i));
            hys[hcount] = stof(argv(i + 1));
            hcount++;
        }

        // Pass 1: energy per point. Linear falloff (1 - d^2/r^2) gives a
        // smoother gradient than a hard-edge count; the self term is
        // included so a lone point still has e == 1 and gets the cold
        // color rather than dividing by zero downstream.
        float r2  = HEATMAP_NEIGHBOUR_R * HEATMAP_NEIGHBOUR_R;
        // Initial sentinel: max possible energy per point is HEATMAP_MAX_POINTS
        // (each contributing up to 1.0), so anything > 256 sits safely above
        // the real range. fteqcc doesn't parse scientific notation.
        float min_e = 1000000;
        float max_e = 0;
        for (int i = 0; i < hcount; i++) {
            float e = 0;
            for (int j = 0; j < hcount; j++) {
                float dx = hxs[i] - hxs[j];
                float dy = hys[i] - hys[j];
                float d2 = dx * dx + dy * dy;
                if (d2 < r2) e += 1 - d2 / r2;
            }
            energies[i] = e;
            if (e < min_e) min_e = e;
            if (e > max_e) max_e = e;
        }

        // Pass 2: draw one cloud blob per point. `scale` is the local
        // world-units-per-pixel factor used to size fov earlier, so a
        // world-space blob radius converts to pixels by dividing through
        // it. Clamped to >= 12 px so tightly-zoomed PIP renders still
        // produce a visible halo. Color piecewise green -> yellow -> red
        // across the [min_e, max_e] band so the user sees relative
        // density regardless of absolute counts; uniform fields
        // (max == min) fall back to green. Radius, intensity and falloff
        // come from cvars so the web app can tune them live via the
        // setMinimapHeatmap config arg.
        float hz        = minimap_center.z;
        float erng      = max_e - min_e;
        float blob_px   = autocvar_minimap_heatmap_radius / scale;
        float intensity = autocvar_minimap_heatmap_intensity;
        float falloff   = autocvar_minimap_heatmap_falloff;
        if (blob_px < 12) blob_px = 12;
        if (falloff < 0.0001) falloff = 0.0001;
        for (int i = 0; i < hcount; i++) {
            float t = erng > 0 ? (energies[i] - min_e) / erng : 0;
            vector color;
            if (t < 0.5)
                color = [t * 2, 1, 0];          // green -> yellow
            else
                color = [1, 1 - (t - 0.5) * 2, 0]; // yellow -> red
            vector sp = project([hxs[i], hys[i], hz]);
            MinimapDrawCloudBlob(sp, blob_px, color, intensity, falloff);
        }
    }

    // Overlay players (project() reads the view state we just set).
    MinimapDrawPlayers(cam_origin);

    drawsetcliparea(vmin.x, vmin.y, vsize.x, vsize.y);

    // "You are here" magenta dot for free-fly spectators (tracked specs
    // and live players already get a real player marker above).
    if (MinimapIsFreeflySpectator()) {
        vector cam_screen = project(CullEditPlayerOrigin());
        drawfill([cam_screen.x - 2, cam_screen.y - 2, 0], '4 4 0', '1 0 1', 1);
    }

    // External highlight: web app drops a world coordinate here via the
    // minimap_highlight cvar (set by Module.setMinimapHighlight on event
    // hover). Renders as a yellow ring at the projected XY. Z is ignored
    // by the orthographic projection but kept in the cvar so the
    // round-trip stays explicit.
    if (autocvar_minimap_highlight != "") {
        // Per-point format: "x y z shape size r g b angle" (9 tokens).
        // angle = entity yaw in degrees (0 when the entity has no
        // angle field). Used to orient the arrowhead at the
        // destination of a teleporter pair so it shows which way
        // the player ends up facing after the teleport. The engine
        // emits one group for single highlights and two for
        // teleporter pairs in (entrance, destination) order.
        float n = tokenize(autocvar_minimap_highlight);
        int points = (int)floor(n / 9);
        vector hs_prev = '0 0 0';
        for (int p = 0; p < points; p++) {
            int i = p * 9;
            vector hl = [stof(argv(i)), stof(argv(i + 1)),
                         stof(argv(i + 2))];
            string shape = argv(i + 3);
            float  size  = stof(argv(i + 4));
            vector color = [stof(argv(i + 5)), stof(argv(i + 6)),
                            stof(argv(i + 7))];
            float  angle = stof(argv(i + 8));
            vector hs = project(hl);
            // Connecting line between this point and the previous one
            // (entrance <-> destination for teleporters). Single quad
            // driven by minimap_dotted_line.frag - the shader stamps
            // anti-aliased dots via fwidth(), so the spacing reads
            // smooth at any zoom level. Drawn first so the endpoint
            // markers paint over the line's start/end.
            if (p > 0) {
                float dx     = hs.x - hs_prev.x;
                float dy     = hs.y - hs_prev.y;
                float length = sqrt(dx * dx + dy * dy);

                // Arrow direction (post-teleport facing). Independent
                // of the projected line length, so we compute it
                // unconditionally - the arrow always renders, even
                // when entrance/destination project to the same
                // pixel (e.g. vertically stacked teleporters).
                float yaw_rad = angle * (M_PI / 180);
                float wx = cos(yaw_rad);
                float wy = sin(yaw_rad);
                vector wxd = minimap_view_wx_delta;
                vector wyd = minimap_view_wy_delta;
                float arx = wx * wxd.x + wy * wyd.x;
                float ary = wx * wxd.y + wy * wyd.y;
                float arlen = sqrt(arx * arx + ary * ary);
                float aux, auy;
                if (arlen > 0.001) {
                    aux = arx / arlen;
                    auy = ary / arlen;
                } else if (length > 0.001) {
                    aux = dx / length;
                    auy = dy / length;
                } else {
                    aux = 0;
                    auy = -1;
                }

                float arrow_len  = 9;
                float arrow_half = 3.75;
                float tip_x = hs.x + aux * (arrow_len * 0.5);
                float tip_y = hs.y + auy * (arrow_len * 0.5);

                // Dotted connector chevrons between entrance and
                // exit. Each "dash" is a small ">" formed by two
                // drawline segments; the row is animated at
                // flow_speed px/sec to read the teleport direction
                // at a glance. cltime keeps ticking through pauses.
                // Skipped when the two endpoints project too close
                // - no useful chevrons fit.
                if (length >= 6) {
                    float ux = dx / length;
                    float uy = dy / length;
                    float chev_half_len  = 1.6;
                    float chev_half_wing = 1.6;
                    float clong_x = ux * chev_half_len;
                    float clong_y = uy * chev_half_len;
                    float cperp_x = -uy * chev_half_wing;
                    float cperp_y =  ux * chev_half_wing;

                    float spacing    = 8;
                    float flow_speed = 16;
                    float phase      = cltime * flow_speed;
                    phase = phase - floor(phase / spacing) * spacing;
                    float start_clear = size;
                    float end_clear   = arrow_len * 0.5;
                    int   steps       = (int)floor(length / spacing) + 1;
                    float fade_dist   = spacing * 1.5;
                    float min_t       = start_clear;
                    float max_t       = length - end_clear;
                    for (int s = 0; s <= steps; s++) {
                        float t = phase + s * spacing;
                        if (t < min_t) continue;
                        if (t > max_t) continue;
                        float alpha = 0.5;
                        float d_in  = t - min_t;
                        float d_out = max_t - t;
                        if (d_in  < fade_dist) alpha *= d_in  / fade_dist;
                        if (d_out < fade_dist) alpha *= d_out / fade_dist;
                        float cx = hs_prev.x + ux * t;
                        float cy = hs_prev.y + uy * t;
                        vector tip = [cx + clong_x, cy + clong_y, 0];
                        vector wl  = [cx - clong_x + cperp_x,
                                      cy - clong_y + cperp_y, 0];
                        vector wr  = [cx - clong_x - cperp_x,
                                      cy - clong_y - cperp_y, 0];
                        drawline(1, wl, tip, color, alpha);
                        drawline(1, tip, wr, color, alpha);
                    }
                }

                // Arrowhead at the destination, always drawn.
                float base_x  = tip_x - aux * arrow_len;
                float base_y  = tip_y - auy * arrow_len;
                float bperp_x = -auy * arrow_half;
                float bperp_y =  aux * arrow_half;
                R_BeginPolygon("minimap_fill_v3", 0, 1);
                R_PolygonVertex([tip_x, tip_y, 0],
                                '0 0 0', color, 0.95);
                R_PolygonVertex([base_x + bperp_x, base_y + bperp_y, 0],
                                '0 0 0', color, 0.95);
                R_PolygonVertex([base_x - bperp_x, base_y - bperp_y, 0],
                                '0 0 0', color, 0.95);
                R_EndPolygon();
            }
            // First-point disc (entrance / single-point marker).
            // Subsequent points use the arrow above instead.
            if (p == 0) {
                if (shape == "disc") {
                    MinimapDrawRing(hs, size, color, 1.0, 1);
                } else {
                    MinimapDrawDisc(hs, size, color, 1.0, 1.0);
                }
            }
            hs_prev = hs;
        }
    }

    // Ring-search debug overlay: concentric circles at each radius
    // sampled by MinimapFindNearestFloor for the last click, plus dots
    // at every sample point. Click epicenter is a single yellow pixel;
    // sample misses red; sample hits green; walk-back endpoint orange.
    //
    // Radii are in world units, so we project each circle vertex through
    // the same minimap view to keep them aligned with the click point.
    // c_z must sit inside the orthographic frustum (camera at
    // center.z+minimap_height looking down) or project() returns
    // clipped/garbage coords. MinimapScreenToWorld stores click XY with
    // z=0 which can fall past the far plane on maps whose floor sits
    // far above 0, so we project at minimap_center.z instead.
    if (autocvar_minimap_debug_rings && minimap_debug_click_valid) {
        float two_pi = M_PI * 2;
        float c_z    = minimap_center.z;
        for (int r = 0; r < MINIMAP_FIND_RING_COUNT; r++) {
            float radius = minimap_find_radii[r];
            // Circle outline (32 segments).
            int   seg_count = 32;
            vector prev = '0 0 0';
            for (int s = 0; s <= seg_count; s++) {
                float a = ((float)s / seg_count) * two_pi;
                vector p = project([minimap_debug_click_xy.x + cos(a) * radius,
                                    minimap_debug_click_xy.y + sin(a) * radius,
                                    c_z]);
                if (s > 0) {
                    drawline(1, prev, p, '0.4 0.4 0.4', 0.7);
                }
                prev = p;
            }
            // Per-sample dot - gray for untested (early-exit skipped it),
            // red for tested miss, green for tested hit.
            int n_dir = (int)minimap_find_dirs[r];
            for (int d = 0; d < n_dir; d++) {
                float a = ((float)d / n_dir) * two_pi;
                vector p = project([minimap_debug_click_xy.x + cos(a) * radius,
                                    minimap_debug_click_xy.y + sin(a) * radius,
                                    c_z]);
                float st = minimap_debug_sample_state[r * MINIMAP_FIND_MAX_DIRS + d];
                vector color;
                if (st == MINIMAP_SAMPLE_HIT)       color = '0 1 0';
                else if (st == MINIMAP_SAMPLE_MISS) color = '1 0 0';
                else                                color = '0.3 0.3 0.3';
                drawfill([p.x - 1, p.y - 1, 0], '2 2 0', color, 1);
            }
        }
        // Click epicenter - single yellow pixel.
        vector click_screen = project([minimap_debug_click_xy.x,
                                       minimap_debug_click_xy.y, c_z]);
        drawfill([click_screen.x, click_screen.y, 0], '1 1 0', '1 1 0', 1);
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
