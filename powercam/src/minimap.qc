// SPDX-License-Identifier: 0BSD

/*
 * Top-down minimap render pass.
 *
 * Renders an orthographic view from high above the map, with roofs/upper
 * geometry hidden via per-map AABB cull volumes (loaded in minimap_load.qc).
 * The 2D player overlay is drawn after renderscene by minimap_players.qc.
 *
 * Cvars (override file values when non-zero):
 *   qdw_minimap_mode             0=off 1=pip 2=split 3=full
 *   qdw_minimap_ortho            half-extent override
 *   qdw_minimap_height_offset    Z offset override
 *   qdw_minimap_center_override  vector override
 *
 * Requires engine support for VF_CULLVOLUME.
 */

// Split-mode horizontal partition: player view on the left, minimap on
// the right. 0.50 = each gets half the screen width.
#define MINIMAP_SPLIT_MAIN_FRAC 0.50

// Player view rect. .size = '0 0 0' means the main view should not render
// (minimap is in FULL mode).
void(float vw, float vh, __out minimap_rect_t r) MinimapMainViewport =
{
    r.min = '0 0 0';
    switch (autocvar_qdw_minimap_mode) {
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

void(float mode, float vw, float vh, __out minimap_rect_t r) MinimapViewport =
{
    r.min  = '0 0 0';
    r.size = '0 0 0';
    switch (mode) {
    case MINIMAP_PIP:
        {
            float w = vw / 4;
            float h = vh / 4;
            float m = w / 10;
            r.min  = [vw - m - w, m, 0];
            r.size = [w, h, 0];
        }
        break;
    case MINIMAP_SPLIT:
        r.min  = [vw * MINIMAP_SPLIT_MAIN_FRAC, 0, 0];
        r.size = [vw * (1 - MINIMAP_SPLIT_MAIN_FRAC), vh, 0];
        break;
    default:
        // FULL: letterbox the viewport to the map's aspect so the map
        // actually fills the visible area instead of leaving large empty
        // margins. Without this, a portrait map in a wide screen looks
        // tiny and centered.
        if (minimap_world_dx > 0 && minimap_world_dy > 0) {
            float map_aspect = minimap_world_dx / minimap_world_dy;
            float target_w = vh * map_aspect;
            float target_h = vh;
            if (target_w > vw) {
                target_w = vw;
                target_h = vw / map_aspect;
            }
            r.min  = [(vw - target_w) * 0.5, (vh - target_h) * 0.5, 0];
            r.size = [target_w, target_h, 0];
        } else {
            r.min  = '0 0 0';
            r.size = [vw, vh, 0];
        }
        break;
    }
};

void(float vwidth, float vheight) MinimapRender =
{
    float mode = autocvar_qdw_minimap_mode;
    if (mode <= MINIMAP_OFF) {
        return;
    }

    if (minimap_loaded_for != mapname) {
        MinimapLoad();
    }

    vector center = autocvar_qdw_minimap_center_override;
    if (center == '0 0 0') {
        center = minimap_center;
    }
    float ortho        = autocvar_qdw_minimap_ortho         > 0 ? autocvar_qdw_minimap_ortho         : minimap_ortho;
    float height_above = autocvar_qdw_minimap_height_offset > 0 ? autocvar_qdw_minimap_height_offset : minimap_height;

    minimap_rect_t viewport;
    MinimapViewport(mode, vwidth, vheight, viewport);
    vector vmin  = viewport.min;
    vector vsize = viewport.size;

    // VF_FOV in orthographic mode is "world units across the viewport".
    // Scale = world units per screen pixel. Computed to fit the world AABB
    // into the viewport along both axes (uniform scale, no stretching).
    //
    // Padding is shape-aware: square-ish maps (in any non-square viewport)
    // already get implicit slack on one axis from the aspect mismatch, so
    // we taper padding down toward small values. Elongated maps don't have
    // that extra slack and use the full 0.15.
    float largest_extent  = (minimap_world_dx > minimap_world_dy) ? minimap_world_dx : minimap_world_dy;
    float smallest_extent = (minimap_world_dx < minimap_world_dy) ? minimap_world_dx : minimap_world_dy;
    float aspect          = (smallest_extent > 0) ? (largest_extent / smallest_extent) : 1;
    float pad_factor;
    if (aspect >= 2)
        pad_factor = 0.10;
    else
        pad_factor = 0.05 + (aspect - 1) * 0.05;  // square -> 0.05, 2:1 -> 0.10
    float pad    = largest_extent * pad_factor;
    float need_x = (minimap_world_dx + pad * 2) / vsize.x;
    float need_y = (minimap_world_dy + pad * 2) / vsize.y;
    float scale  = (need_x > need_y) ? need_x : need_y;
    if (ortho > 0) {
        float ortho_scale = (ortho * 2) / vsize.x;
        if (ortho_scale > scale) scale = ortho_scale;
    }
    float fov_x = vsize.x * scale;
    float fov_y = vsize.y * scale;

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

    // Try the pickup-ceiling scan if we haven't yet. Pickup baselines arrive
    // a few frames after world load, so this runs lazily on each render
    // until it succeeds. The scan appends per-pickup cull volumes directly
    // to minimap_volumes alongside any volumes from the .cull file.
    if (!minimap_auto_pickup_known) {
        MinimapScanPickupCeiling();
    }

    for (int i = 0; i < minimap_num_volumes; i++) {
        setviewprop(VF_CULLVOLUME, i,
                    minimap_volumes[i].mins,
                    minimap_volumes[i].maxs);
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
};
