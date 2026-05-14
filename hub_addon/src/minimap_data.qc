// SPDX-License-Identifier: 0BSD

/*
 * Minimap data: shared state, constants, types, color tables, low-level
 * drawing primitives, and shader registration.
 *
 * Anything that:
 *   - is read from more than one minimap_*.qc file, OR
 *   - is pure data (color tables, pickup model whitelist), OR
 *   - is a geometric primitive (disc, ring, thick line, point-in-volume)
 * lives here so it has a single definition order. Per-feature logic
 * (loading, players, rendering, commands) lives in its own file.
 */

const float VF_CULLVOLUME        = 226;

// VF_CULLVOLUME (226) is an engine-side extension fteqcc doesn't know about;
// silence the spurious "unknown argument" warning on setproperty calls.
#pragma warning disable F333

#define MINIMAP_OFF   0
#define MINIMAP_PIP   1
#define MINIMAP_SPLIT 2
#define MINIMAP_FULL  3

#define MINIMAP_MAX_CULL_VOLUMES 32
#define MINIMAP_MAX_PLAYERS      32

// Segment count for disc/ring tessellation. Higher = smoother edges, more
// vertices. 32 looks circular at the typical marker size (~7px radius).
#define MINIMAP_CIRCLE_SEGMENTS 32

typedef struct {
    vector mins;
    vector maxs;
} minimap_volume_t;

// 2D viewport rect: screen-space origin and size in pixels.
typedef struct {
    vector min;
    vector size;
} minimap_rect_t;

// STAT_ITEMS bits we surface on the minimap.
#define MM_IT_GRENADE_LAUNCHER 16
#define MM_IT_ROCKET_LAUNCHER  32
#define MM_IT_LIGHTNING        64
#define MM_IT_ARMOR1           8192    // Green Armor   (max 100)
#define MM_IT_ARMOR2           16384   // Yellow Armor  (max 150)
#define MM_IT_ARMOR3           32768   // Red Armor     (max 200)

// ----------------------------------------------------------------------------
// Cvars.
// ----------------------------------------------------------------------------

var float  autocvar_minimap_mode               = MINIMAP_OFF;
var float  autocvar_minimap_player_radius      = 7;
var float  autocvar_minimap_player_alpha       = 0.8;
var float  autocvar_minimap_player_name_length = 4;
var float  autocvar_minimap_player_name_size   = 6;
// '0 0 0' = sentinel for "use the built-in default" (green for team, red
// for enemy). Any non-zero value overrides.
var vector autocvar_minimap_player_teamcolor         = '0 0 0';
var vector autocvar_minimap_player_enemycolor        = '0 0 0';
var vector autocvar_minimap_player_selfcolor         = '1 1 0';

// Built-in defaults used when the team/enemy color cvars are left at '0 0 0'.
var vector minimap_default_color_team  = '0 1 0';
var vector minimap_default_color_enemy = '1 0 0';

// ----------------------------------------------------------------------------
// Shared module state. All consumers (load, render, players, commands) read
// these; load.qc writes most of them.
// ----------------------------------------------------------------------------

// Cull volumes (AABBs) suppressed from the minimap render. Populated from
// the .cull file or the runtime editor.
var minimap_volume_t minimap_volumes[MINIMAP_MAX_CULL_VOLUMES];
var int    minimap_num_volumes = 0;

// Derived camera and projection params for the minimap render. Computed
// from the BSP AABB (MinimapAutoBounds), narrowed by MinimapNarrowByTraceline,
// and finally height-adjusted by MinimapDeriveBoundsFromVolumes if a .cull
// file is loaded. minimap_height is the camera Z above minimap_center;
// minimap_ortho is a single-axis extent used as a lower bound on the
// auto-computed scale in MinimapRender.
var vector minimap_center      = '0 0 0';
var float  minimap_ortho       = 2048;
var float  minimap_height      = 4096;
var float  minimap_world_top_z = 0;   // BSP maxs.z, set in MinimapAutoBounds
var float  minimap_world_dx    = 0;   // BSP width  (maxs.x - mins.x)
var float  minimap_world_dy    = 0;   // BSP depth  (maxs.y - mins.y)

// 1 once MinimapLoad has finished its first pass for a map; reported by
// the status command.
var float  minimap_loaded      = 0;

// Name of the last map MinimapLoad processed. Used to re-run the load
// pipeline when `mapname` changes mid-session (e.g. demo seek across maps).
var string minimap_loaded_for  = "";

// Per-frame cache of player names, rebuilt by MinimapBuildPlayerLabels at
// the start of each DrawPlayers pass. Two parallel versions:
//   minimap_label_name  - sanitized, retains ^X color codes & bronze chars
//   minimap_label_plain - markup-stripped variant for prefix uniqueness
var string minimap_label_name [MINIMAP_MAX_PLAYERS];
var string minimap_label_plain[MINIMAP_MAX_PLAYERS];

// Per-frame doppelganger overlays for players the minimap camera can't see
// directly. Engine-side player entities aren't exposed as QC entities
// (deltalisten isn't registered unless xray is on), so we can't flip
// EF_NODEPTHTEST on them. Instead, for each occluded player we spawn a
// throwaway QC entity that mirrors the player's pose and add it to the
// scene with NODEPTHTEST + alpha so it shows through walls/roofs.
// Visible players are skipped - the engine already draws them at full
// opacity, and we don't want a double-render. Spawned at the top of the
// minimap render pass and removed immediately after renderscene().
var entity minimap_doppel_ents[MINIMAP_MAX_PLAYERS];
var int    minimap_doppel_count = 0;

void() MinimapResetState =
{
    minimap_num_volumes = 0;
    minimap_center      = '0 0 0';
    minimap_ortho       = 2048;
    minimap_height      = 4096;
};

// ----------------------------------------------------------------------------
// Color tables.
// ----------------------------------------------------------------------------

// Color matching the Quake color-code convention used by the scoreboard
// (engine/client/sbar.c:3661-3663): LG = cyan ^5, RL = red/orange ^1,
// GL = green ^2.
vector(float weapon_bit) MinimapWeaponColor =
{
    switch ((int)weapon_bit) {
    case MM_IT_GRENADE_LAUNCHER: return '0.3 1 0.3';
    case MM_IT_ROCKET_LAUNCHER:  return '1 0.5 0.2';
    case MM_IT_LIGHTNING:        return '0.3 0.8 1';
    default:                     return '1 1 1';
    }
};

// Health/armor color tables, mirroring the autoid tables in view.c:1823 /
// view.c:1831 so the minimap and the engine's autoid overlay share a visual
// language. Bars are rendered in two segments: dim color on the depleted
// side, full color on the remaining side.
//
// minimap_health_colors[r] (dim) + minimap_health_colors[r+1] (full) where
// r = floor(hp/100), clamped to [0,3].
const vector minimap_health_colors[5] = {
    '0.7 0.45 0.45',  // [0] dim   for hp <  100
    '0.3 0 0',        // [1] full  for hp <  100  / dim  for hp < 200
    '1 0 0',          // [2] full  for hp < 200  / dim  for hp < 300
    '1 0.4 0',        // [3] full  for hp < 300  / dim  for hp >= 300
    '1 1 1'           // [4] full  for hp >= 300
};

vector(float idx) MinimapHealthColorAt =
{
    if (idx < 0) idx = 0;
    if (idx > 4) idx = 4;
    return minimap_health_colors[(int)idx];
};

// True when the local seat is a free-flying spectator - i.e. a spec
// without a tracked player to view through. Used to drive minimap UI
// that needs to know whether the seat already has its own player marker
// (a tracked spec or live player does), or needs an explicit "you are
// here" indicator (free-fly).
//
// Detection:
//   - Spectator if any of: MVD demo (isdemo == 2), seat slot past real
//     players, or *spectator userinfo flag.
//   - Free-fly iff player_localentnum doesn't reference an active
//     player entity. Tracking sets it to the followed player's entity
//     (in the 1..maxclients range and active); free-fly leaves it at
//     the seat's own playernum+1 which has no live entity in either
//     live or MVD demo playback.
float() MinimapIsFreeflySpectator =
{
    float is_spectator = (isdemo() > 0) ||
                         (player_localnum >= maxclients) ||
                         (stof(getplayerkeyvalue(player_localnum, "*spectator")) > 0);
    if (!is_spectator) return 0;
    if (player_localentnum < 1 || player_localentnum > maxclients) {
        return 1;
    }
    float active = getentity(player_localentnum, GE_ACTIVE);
    return !active;
};

// Armor tier colors. Indexed by armor type with two entries each (dim, full).
//   [0]=GA dim, [1]=GA full, [2]=YA dim, [3]=YA full, [4]=RA dim, [5]=RA full.
const vector minimap_armor_colors[6] = {
    '0 0.4 0',    // GA dim
    '0 1 0',      // GA full
    '0.4 0.4 0',  // YA dim
    '1 1 0',      // YA full
    '0.4 0 0',    // RA dim
    '1 0 0'       // RA full
};

// ----------------------------------------------------------------------------
// Pickup-model whitelist. Used by the /minimap status pickup probe as a
// diagnostic for sizing manual .cull volumes.
// ----------------------------------------------------------------------------

// Known Quake 1 pickup model names. Anything in this set sits on the play
// floor when spawned. Excludes monsters, gibs, dropped backpacks.
//
// Teleport entrances/destinations and player spawn points would also be
// useful but they have no client-visible model in vanilla Quake
// (info_teleport_destination sets self.model = "" explicitly; spawn
// points have no model at all; trigger_teleport is a brush trigger). CSQC
// has no way to query entity classname (no GE_CLASSNAME), so they can't
// be detected here without engine help.
float(string mname) MinimapIsFloorAnchor =
{
    switch (mname) {
    // Weapons.
    case "progs/g_shot.mdl":
    case "progs/g_nail.mdl":
    case "progs/g_nail2.mdl":
    case "progs/g_rock.mdl":
    case "progs/g_rock2.mdl":
    case "progs/g_light.mdl":
    // Armor (single mdl, colored via .skin).
    case "progs/armor.mdl":
    // Powerups.
    case "progs/quaddama.mdl":
    case "progs/invulner.mdl":
    case "progs/suit.mdl":
    case "progs/invisibl.mdl":
    // Health boxes (BSP submodels).
    case "maps/b_bh100.bsp":
    case "maps/b_bh25.bsp":
    case "maps/b_bh10.bsp":
    // Ammo boxes.
    case "maps/b_shell0.bsp":
    case "maps/b_shell1.bsp":
    case "maps/b_nail0.bsp":
    case "maps/b_nail1.bsp":
    case "maps/b_rock0.bsp":
    case "maps/b_rock1.bsp":
    case "maps/b_batt0.bsp":
    case "maps/b_batt1.bsp":
        return 1;
    default:
        return 0;
    }
};

// ----------------------------------------------------------------------------
// Shader registration. Called once from CSQC_WorldLoaded.
// ----------------------------------------------------------------------------

// "minimap_fill_v3" is a simple 2D fill shader with per-vertex color and
// alpha - identical to the one PF_CL_drawline uses
// (engine/client/pr_menu.c:1074-1083). Used by R_BeginPolygon callers
// (discs, rings, score-overlay rounded rects, the player-arrowhead tri).
void() MinimapRegisterShaders =
{
    // The defaultfill GLSL program reads the full 4-component vertex color
    // (engine/gl/r_bishaders.h:4471-4491) and writes it straight to
    // gl_FragColor, so rgbgen/alphagen directives are redundant - and seem to
    // suppress alpha output on some paths. Keep the shader minimal: just
    // alpha-blended fill via the program and vertex colors.
    shaderforname("minimap_fill_v3", R"({
    program defaultfill
    {
        map $whiteimage
        blendfunc blend
    }
})");
};

// ----------------------------------------------------------------------------
// Geometric primitives.
// ----------------------------------------------------------------------------

// Returns the index of the cull volume containing `p`, or -1 if none.
float(vector p) MinimapPointInCullVolume =
{
    for (int i = 0; i < minimap_num_volumes; i++) {
        if (p.x >= minimap_volumes[i].mins.x && p.x <= minimap_volumes[i].maxs.x &&
            p.y >= minimap_volumes[i].mins.y && p.y <= minimap_volumes[i].maxs.y &&
            p.z >= minimap_volumes[i].mins.z && p.z <= minimap_volumes[i].maxs.z) {
            return i;
        }
    }
    return -1;
};

// Filled disc with a radial gradient: alpha goes from `center_alpha` at the
// middle to `edge_alpha` at the rim, color is constant. Rendered as a
// triangle fan rooted at the center.
void(vector pos, float radius, vector color, float center_alpha, float edge_alpha) MinimapDrawDisc =
{
    float two_pi = M_PI * 2;
    R_BeginPolygon("minimap_fill_v3", 0, 1);
    R_PolygonVertex(pos, '0 0 0', color, center_alpha);
    for (int i = 0; i <= MINIMAP_CIRCLE_SEGMENTS; i++) {
        float a = ((float)(i % MINIMAP_CIRCLE_SEGMENTS) / MINIMAP_CIRCLE_SEGMENTS) * two_pi;
        vector p = [pos.x + cos(a) * radius, pos.y + sin(a) * radius, 0];
        R_PolygonVertex(p, '0 0 0', color, edge_alpha);
    }
    R_EndPolygon();
};

// 2D ring. For thickness == 1 we use line segments (cheap). For thicker
// rings we draw an annulus as a sequence of quads sharing inner/outer
// vertices with their neighbors - no butt-joint gaps and no overlap, unlike
// stacking thick-line segments end-to-end.
void(vector pos, float radius, vector color, float alpha, float thickness) MinimapDrawRing =
{
    float two_pi = M_PI * 2;

    if (thickness <= 1) {
        vector prev = [pos.x + radius, pos.y, 0];
        for (int j = 1; j <= MINIMAP_CIRCLE_SEGMENTS; j++) {
            float a = ((float)j / MINIMAP_CIRCLE_SEGMENTS) * two_pi;
            vector p = [pos.x + cos(a) * radius, pos.y + sin(a) * radius, 0];
            drawline(1, prev, p, color, alpha);
            prev = p;
        }
        return;
    }

    float inner = radius - thickness * 0.5;
    float outer = radius + thickness * 0.5;
    for (int i = 0; i < MINIMAP_CIRCLE_SEGMENTS; i++) {
        float a0 = ((float)i       / MINIMAP_CIRCLE_SEGMENTS) * two_pi;
        float a1 = ((float)(i + 1) / MINIMAP_CIRCLE_SEGMENTS) * two_pi;
        float c0 = cos(a0), s0 = sin(a0);
        float c1 = cos(a1), s1 = sin(a1);

        vector p_in_0  = [pos.x + c0 * inner, pos.y + s0 * inner, 0];
        vector p_out_0 = [pos.x + c0 * outer, pos.y + s0 * outer, 0];
        vector p_in_1  = [pos.x + c1 * inner, pos.y + s1 * inner, 0];
        vector p_out_1 = [pos.x + c1 * outer, pos.y + s1 * outer, 0];

        R_BeginPolygon("minimap_fill_v3", 0, 1);
        R_PolygonVertex(p_in_0,  '0 0 0', color, alpha);
        R_PolygonVertex(p_out_0, '0 0 0', color, alpha);
        R_PolygonVertex(p_out_1, '0 0 0', color, alpha);
        R_PolygonVertex(p_in_1,  '0 0 0', color, alpha);
        R_EndPolygon();
    }
};
