/*
 * Top-down minimap pass for demo analysis.
 *
 * Renders an orthographic view from high above the map, with roofs/upper
 * geometry hidden via per-map AABB cull volumes that suppress matching
 * BSP nodes in the renderer.
 *
 * On map load, center / ortho / height are auto-derived from the worldmodel
 * AABB (probing for the highest geometry above the BSP center). Values in
 * the .cull file override the auto values.
 *
 * Cull volumes are loaded from maps/<mapname>.cull. Format:
 *
 *   # comments allowed; blank lines ignored
 *   center X Y Z           # camera XY and reference Z (override auto)
 *   ortho HALF_SIZE        # half-extent in QU per side (override auto)
 *   height OFFSET          # camera Z added to center.z (override auto)
 *
 *   # any line with 6 numbers is parsed as: mins.x mins.y mins.z  maxs.x maxs.y maxs.z
 *   -512 -384 192    512 384 99999
 *
 * Cvars (override file values when non-zero):
 *   minimap_mode             0=off 1=pip 2=split 3=full
 *   minimap_ortho            half-extent override
 *   minimap_height_offset    Z offset override
 *   minimap_center_override  vector override
 *
 * Requires engine support for VF_CULLVOLUME / VF_CULLVOLUMES_COUNT.
 */

const float VF_CULLVOLUME        = 226;
const float VF_CULLVOLUMES_COUNT = 227;

#define MINIMAP_OFF   0
#define MINIMAP_PIP   1
#define MINIMAP_SPLIT 2
#define MINIMAP_FULL  3

#define MINIMAP_MAX_CULL_VOLUMES 32

typedef struct {
    vector mins;
    vector maxs;
} minimap_volume_t;

var float  autocvar_minimap_mode             = MINIMAP_OFF;
var float  autocvar_minimap_ortho            = 0;
var float  autocvar_minimap_height_offset    = 0;
var vector autocvar_minimap_center_override  = '0 0 0';
var float  autocvar_minimap_player_radius    = 6;
var float  autocvar_minimap_player_dir_len   = 14;
var float  autocvar_minimap_player_visible   = 0;  // 1 = always draw circle, 0 = only when occluded
var vector autocvar_minimap_player_color_team   = '0 1 0';
var vector autocvar_minimap_player_color_enemy  = '1 0 0';
var vector autocvar_minimap_player_color_self   = '1 1 0';

var minimap_volume_t minimap_volumes[MINIMAP_MAX_CULL_VOLUMES];
var int    minimap_num_volumes = 0;
var vector minimap_center      = '0 0 0';
var float  minimap_ortho       = 2048;
var float  minimap_height      = 4096;
var float  minimap_loaded      = 0;
var string minimap_loaded_for  = "";

void() MinimapResetState =
{
    minimap_num_volumes = 0;
    minimap_center      = '0 0 0';
    minimap_ortho       = 2048;
    minimap_height      = 4096;
};

// Derive center/ortho/height from the worldmodel AABB.
// setmodel() on a temp entity with the BSP path fills .mins/.maxs from the
// brushmodel (per csplat.qc:976-977).
void() MinimapAutoBounds =
{
    entity tmp = spawn();
    string mname = sprintf("maps/%s.bsp", mapname);
    setmodel(tmp, mname);

    if (tmp.maxs.x > tmp.mins.x) {
        minimap_center.x = (tmp.mins.x + tmp.maxs.x) * 0.5;
        minimap_center.y = (tmp.mins.y + tmp.maxs.y) * 0.5;
        minimap_center.z = tmp.mins.z;

        float ext = max(tmp.maxs.x - tmp.mins.x, tmp.maxs.y - tmp.mins.y);
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

float(string line) MinimapParseLine =
{
    float n = tokenize_console(line);
    if (n <= 0) {
        return 0;
    }

    string head = argv(0);
    if (substring(head, 0, 1) == "#") {
        return 0;
    }

    if (head == "center" && n >= 4) {
        minimap_center = [stof(argv(1)), stof(argv(2)), stof(argv(3))];
        return 1;
    }
    if (head == "ortho" && n >= 2) {
        minimap_ortho = stof(argv(1));
        return 1;
    }
    if (head == "height" && n >= 2) {
        minimap_height = stof(argv(1));
        return 1;
    }

    if (n >= 6 && minimap_num_volumes < MINIMAP_MAX_CULL_VOLUMES) {
        minimap_volumes[minimap_num_volumes].mins =
            [stof(argv(0)), stof(argv(1)), stof(argv(2))];
        minimap_volumes[minimap_num_volumes].maxs =
            [stof(argv(3)), stof(argv(4)), stof(argv(5))];
        minimap_num_volumes++;
        return 1;
    }

    return 0;
};

float() MinimapLoad =
{
    MinimapResetState();
    minimap_loaded     = 0;
    minimap_loaded_for = mapname;

    if (mapname == "") {
        return 0;
    }

    MinimapAutoBounds();

    string fname = sprintf("maps/%s.cull", mapname);
    filestream fh = fopen(fname, FILE_READ);
    if (fh < 0) {
        debug("minimap: no cull file '%s'", fname);
        return 0;
    }

    string line;
    while ((line = fgets(fh))) {
        MinimapParseLine(line);
    }
    fclose(fh);

    minimap_loaded = 1;
    debug("minimap: %d volumes loaded from %s", (float)minimap_num_volumes, fname);
    return 1;
};

// Returns 1 if the main player view should render, filling vmin/vsize with
// its viewport rect. Returns 0 when the minimap is in FULL mode (main view
// is hidden).
float(float vw, float vh, __out vector vmin, __out vector vsize) MinimapMainViewport =
{
    float mode = autocvar_minimap_mode;
    if (mode == MINIMAP_SPLIT) {
        vmin  = '0 0 0';
        vsize = [vw * 0.5, vh, 0];
        return 1;
    }
    if (mode == MINIMAP_FULL) {
        vmin  = '0 0 0';
        vsize = '0 0 0';
        return 0;
    }
    vmin  = '0 0 0';
    vsize = [vw, vh, 0];
    return 1;
};

void(float mode, float vw, float vh, __out vector vmin, __out vector vsize) MinimapViewport =
{
    switch (mode) {
    case MINIMAP_PIP:
        {
            float w = vw / 4;
            float h = vh / 4;
            float m = w / 10;
            vmin  = [vw - m - w, m, 0];
            vsize = [w, h, 0];
        }
        break;
    case MINIMAP_SPLIT:
        vmin  = [vw / 2, 0, 0];
        vsize = [vw / 2, vh, 0];
        break;
    default:
        vmin  = '0 0 0';
        vsize = [vw, vh, 0];
        break;
    }
};

// Inline shader for the player direction triangle. rgbgen+alphagen vertex
// lets R_PolygonVertex's color/alpha drive the gradient.
void() MinimapRegisterShaders =
{
    shaderforname("minimap_dir", R"({
    nopicmip
    {
        map $whiteimage
        rgbgen vertex
        alphagen vertex
        blendfunc blend
    }
})");
};

// 2D ring approximated by line segments.
void(vector pos, float radius, vector color, float alpha) MinimapDrawRing =
{
    float N = 20;
    float two_pi = M_PI * 2;
    vector prev;
    for (int i = 0; i <= N; i++) {
        float a = ((float)i / N) * two_pi;
        vector p = [pos.x + cos(a) * radius, pos.y + sin(a) * radius, 0];
        if (i > 0) {
            drawline(1, prev, p, color, alpha);
        }
        prev = p;
    }
};

// Filled triangle from tip back to base, alpha fading from 1 at the tip to 0
// at the base. screen_yaw is in radians (0 = up the screen, increasing CW).
void(vector tip_pos, float screen_yaw, float length, float halfwidth, vector color) MinimapDrawDirectionTriangle =
{
    // forward (toward tip) and right vectors in screen space.
    // Note: screen Y points DOWN, so a "yaw=0 = up" mapping means dy = -cos.
    float fx = sin(screen_yaw);
    float fy = -cos(screen_yaw);
    float rx = -fy;
    float ry =  fx;

    vector base_center = [tip_pos.x - fx * length, tip_pos.y - fy * length, 0];
    vector base_l = [base_center.x + rx * halfwidth, base_center.y + ry * halfwidth, 0];
    vector base_r = [base_center.x - rx * halfwidth, base_center.y - ry * halfwidth, 0];

    R_BeginPolygon("minimap_dir", 0, 1);
    R_PolygonVertex(tip_pos, '0 0 0', color, 1.0);
    R_PolygonVertex(base_l,  '0 0 0', color, 0.0);
    R_PolygonVertex(base_r,  '0 0 0', color, 0.0);
    R_EndPolygon();
};

// Pick a color for a player relative to the local POV.
vector(float pnum) MinimapPlayerColor =
{
    if (pnum == player_localnum) {
        return autocvar_minimap_player_color_self;
    }
    string pov_team = getplayerkeyvalue(player_localnum, "team");
    string his_team = getplayerkeyvalue(pnum, "team");
    if (pov_team == his_team && pov_team != "") {
        return autocvar_minimap_player_color_team;
    }
    return autocvar_minimap_player_color_enemy;
};

void(vector cam_origin) MinimapDrawPlayers =
{
    float radius   = autocvar_minimap_player_radius;
    float dir_len  = autocvar_minimap_player_dir_len;
    float dir_half = radius * 0.85;
    float always   = autocvar_minimap_player_visible;
    float plyr_mdl = getmodelindex("progs/player.mdl");

    for (int i = 1; i <= maxclients; i++) {
        if (!getentity(i, GE_ACTIVE)) {
            continue;
        }
        if (getentity(i, GE_MODELINDEX) != plyr_mdl) {
            continue;
        }
        vector origin = getentity(i, GE_ORIGIN);
        vector angles = getentity(i, GE_ANGLES);
        float  pnum   = i - 1;

        // visibility test: trace from camera to head height.
        vector head = [origin.x, origin.y, origin.z + 24];
        traceline(cam_origin, head, MOVE_NOMONSTERS, world);
        float occluded = (trace_fraction < 1);

        if (!occluded && !always) {
            // player visible through the world; the rendered model already
            // appears at the right spot, skip the marker.
            continue;
        }

        vector screen = project(origin);
        vector color  = MinimapPlayerColor(pnum);

        MinimapDrawRing(screen, radius, color, 1);

        // Convert world yaw into a screen yaw. With camera looking straight
        // down (pitch 90, yaw 0), screen up corresponds to world +X. World
        // yaw 0 (looking toward +X) therefore points up on screen, world yaw
        // 90 (toward +Y) points right.
        float world_yaw = angles.y;
        float screen_yaw = world_yaw * M_PI / 180.0;
        vector tip = [screen.x + sin(screen_yaw) * (radius + dir_len),
                      screen.y - cos(screen_yaw) * (radius + dir_len),
                      0];
        MinimapDrawDirectionTriangle(tip, screen_yaw, dir_len, dir_half, color);
    }
};

void(float vwidth, float vheight) MinimapRender =
{
    float mode = autocvar_minimap_mode;
    if (mode <= MINIMAP_OFF) {
        return;
    }

    if (minimap_loaded_for != mapname) {
        MinimapLoad();
    }

    vector center = autocvar_minimap_center_override;
    if (center == '0 0 0') {
        center = minimap_center;
    }
    float ortho  = autocvar_minimap_ortho            > 0 ? autocvar_minimap_ortho            : minimap_ortho;
    float hoff   = autocvar_minimap_height_offset    > 0 ? autocvar_minimap_height_offset    : minimap_height;

    vector vmin, vsize;
    MinimapViewport(mode, vwidth, vheight, vmin, vsize);

    // In orthographic mode VF_FOV sets fov_x/fov_y as world-unit extents
    // (the renderer feeds them straight into the ortho matrix as -fov/2..+fov/2).
    // VF_AFOV instead treats the value as an FOV angle capped at 170 degrees,
    // which produces a ~170-unit viewport regardless of intent.
    float fov_x = ortho * 2;
    float fov_y = fov_x * (vsize.y / vsize.x);

    clearscene();
    setviewprop(VF_DRAWWORLD,      1);
    setviewprop(VF_VIEWENTITY,     0);
    setviewprop(VF_DRAWENGINESBAR, 0);
    setviewprop(VF_DRAWCROSSHAIR,  0);
    setviewprop(VF_PERSPECTIVE,    0);
    setviewprop(VF_FOV,            [fov_x, fov_y, 0]);
    setviewprop(VF_ORIGIN,         [center.x, center.y, center.z + hoff]);
    setviewprop(VF_ANGLES,         '90 0 0');
    setviewprop(VF_MIN,            vmin);
    setviewprop(VF_SIZE,           vsize);

    for (int i = 0; i < minimap_num_volumes; i++) {
        setviewprop(VF_CULLVOLUME, i,
                    minimap_volumes[i].mins,
                    minimap_volumes[i].maxs);
    }

    addentities(MASK_ENGINE);
    renderscene();

    // Overlay players (project() reads the view state we just set).
    vector cam_origin = [center.x, center.y, center.z + hoff];
    MinimapDrawPlayers(cam_origin);
};

float() MinimapCmdReload =
{
    MinimapLoad();
    println("Minimap: %d volumes, center %v, ortho %g, height %g",
            (float)minimap_num_volumes,
            minimap_center,
            minimap_ortho,
            minimap_height);
    return 1;
};

float() MinimapCmdStatus =
{
    println("Minimap mode: %g  (0=off 1=pip 2=split 3=full)", autocvar_minimap_mode);
    println("Map:          %s", mapname);
    println("Loaded:       %g", minimap_loaded);
    println("Volumes:      %d", minimap_num_volumes);
    println("Center:       %v", minimap_center);
    println("Ortho:        %g", minimap_ortho);
    println("Height:       %g", minimap_height);
    return 1;
};

// Adds a description to a cvar without disturbing its current value.
// Uses the engine's `set NAME "VALUE" // DESC` syntax, with $-expansion to
// echo the current value back. Cvars are created by the autocvar_*
// declarations before this runs, so the expansion resolves correctly.
void(string name, string desc) MinimapDescribeCvar =
{
    localcmd(sprintf("set %s \"$%s\" // %s\n", name, name, desc));
};

void() MinimapRegisterDescriptions =
{
    MinimapDescribeCvar("minimap_mode",
        "Minimap display mode. 0=off, 1=picture-in-picture (top right), 2=split screen (right half), 3=full screen.");
    MinimapDescribeCvar("minimap_ortho",
        "Orthographic half-extent in Quake units per side. 0 = use value from .cull file or auto-derived from worldmodel bounds.");
    MinimapDescribeCvar("minimap_height_offset",
        "Camera Z offset above the reference center. 0 = use value from .cull file or auto-derived (highest geometry at center + 512 margin).");
    MinimapDescribeCvar("minimap_center_override",
        "Camera XY position and reference Z, as a vector. '0 0 0' = use value from .cull file or worldmodel midpoint.");
    MinimapDescribeCvar("minimap_player_radius",
        "Radius of the player marker ring on the minimap, in screen pixels.");
    MinimapDescribeCvar("minimap_player_dir_len",
        "Length of the look-direction triangle extending out from the player ring, in screen pixels.");
    MinimapDescribeCvar("minimap_player_visible",
        "1 = always draw player marker. 0 = only when the player is occluded from the minimap camera.");
    MinimapDescribeCvar("minimap_player_color_team",
        "Ring/triangle color for same-team players.");
    MinimapDescribeCvar("minimap_player_color_enemy",
        "Ring/triangle color for opposing-team players.");
    MinimapDescribeCvar("minimap_player_color_self",
        "Ring/triangle color for the local player.");
};

float() MinimapCmdHelp =
{
    println("Minimap Commands");
    println(" * reload  - Reparse maps/<mapname>.cull and recompute auto bounds");
    println(" * status  - Print current mode, map, volume count, and view params");
    println(" * help    - Show this command list");
    println("Cvars:");
    println(" * minimap_mode             0=off 1=pip 2=split 3=full");
    println(" * minimap_ortho            half-extent in QU; 0 = use file value");
    println(" * minimap_height_offset    camera Z above center; 0 = use file value");
    println(" * minimap_center_override  vector; '0 0 0' = use file value");
    return 1;
};
