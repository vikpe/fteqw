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
var float  autocvar_minimap_player_radius           = 6;
var float  autocvar_minimap_player_dir_len          = 14;
var float  autocvar_minimap_player_alpha_occluded   = 0.5;
var float  autocvar_minimap_player_label_size       = 0;
// Set to '0 0 0' as a sentinel for "use auto-derived color from cl_teamskin /
// cl_enemyskin image average". A non-zero value overrides.
var vector autocvar_minimap_player_color_team       = '0 0 0';
var vector autocvar_minimap_player_color_enemy      = '0 0 0';
var vector autocvar_minimap_player_color_self       = '1 1 0';

// Average skin colors computed at world load, with sensible fallbacks.
var vector minimap_auto_color_team  = '0 1 0';
var vector minimap_auto_color_enemy = '1 0 0';

var minimap_volume_t minimap_volumes[MINIMAP_MAX_CULL_VOLUMES];
var int    minimap_num_volumes = 0;
var vector minimap_center      = '0 0 0';
var float  minimap_ortho       = 2048;
var float  minimap_height      = 4096;
var float  minimap_world_top_z = 0;   // BSP maxs.z, set in MinimapAutoBounds
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
        minimap_world_top_z = tmp.maxs.z;

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
    MinimapComputeAutoColors();

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

// Strip markup (color codes, bronze/qchar range) and keep only printable
// ASCII. strdecolorize is the engine's qchar/markup flattener (#477,
// DP_QC_STRINGCOLORFUNCTIONS) - it uses the same COM_ParseFunString +
// COM_DeFunString pipeline as SV_FixupName, so qchars in 0xe000..0xe0FF are
// folded to their ASCII equivalents and ^X codes are removed. We then drop
// any remaining bytes outside printable ASCII (real Unicode, control chars).
string(string raw) MinimapNormalizeName =
{
    string clean = strdecolorize(raw);
    string out = "";
    float n = strlen(clean);
    for (float i = 0; i < n; i++) {
        float c = str2chr(clean, i);
        if (c >= 32 && c <= 126) {
            out = strcat(out, chr2str(c));
        }
    }
    return out;
};

// Cache of normalized names for the current frame, indexed by player number
// (0..maxclients-1). Empty string for inactive slots.
#define MINIMAP_MAX_PLAYERS 32
var string minimap_label_name[MINIMAP_MAX_PLAYERS];

void() MinimapBuildPlayerLabels =
{
    float plyr_mdl = getmodelindex("progs/player.mdl");
    for (int i = 0; i < MINIMAP_MAX_PLAYERS; i++) {
        minimap_label_name[i] = "";
        if (i >= maxclients) {
            continue;
        }
        float entnum = i + 1;
        float active = getentity(entnum, GE_ACTIVE);
        if (!active) {
            continue;
        }
        float modidx = getentity(entnum, GE_MODELINDEX);
        if (modidx != plyr_mdl) {
            continue;
        }
        string raw = getplayerkeyvalue(i, "name");
        minimap_label_name[i] = MinimapNormalizeName(raw);
    }
};

// Returns the shortest prefix of player `pi`'s normalized name that no other
// active player's normalized name starts with. Falls back to the full name on
// exact collision.
string(float pi) MinimapShortestUniquePrefix =
{
    string mine = minimap_label_name[pi];
    float my_len = strlen(mine);
    if (my_len == 0) {
        return "";
    }
    for (float n = 1; n <= my_len; n++) {
        string my_prefix = substring(mine, 0, n);
        float unique = 1;
        for (int j = 0; j < MINIMAP_MAX_PLAYERS; j++) {
            if (j == pi) continue;
            string other = minimap_label_name[j];
            if (other == "") continue;
            if (substring(other, 0, n) == my_prefix) {
                unique = 0;
                break;
            }
        }
        if (unique) {
            return my_prefix;
        }
    }
    return mine;
};

// Map STAT_ACTIVEWEAPON to a short label, only for the weapons that matter
// for analysis (GL/RL/LG). Lower-tier weapons return "" so the label is
// omitted.
string(float w) MinimapWeaponLabel =
{
    switch ((int)w) {
    case 16:   return "GL";
    case 32:   return "RL";
    case 64:   return "LG";
    default:   return "";
    }
};

// Per-weapon label color. Matches the Quake color-code convention used by
// the scoreboard (engine/client/sbar.c:3661-3663): LG = cyan ^5, RL = the
// red/orange ^1, GL = green ^2.
vector(float w) MinimapWeaponColor =
{
    switch ((int)w) {
    case 16:   return '0.3 1 0.3';    // GL  - green
    case 32:   return '1 0.5 0.2';    // RL  - orange
    case 64:   return '0.3 0.8 1';    // LG  - cyan
    default:   return '1 1 1';
    }
};

// Health bar fill color: cyan for mega-overheal, green/yellow/red on the way
// down. Matches the rough convention from autoid.
vector(float health) MinimapHealthColor =
{
    if (health > 100) return '0.4 0.6 1';
    if (health > 50)  return '0 1 0';
    if (health > 25)  return '1 1 0';
    return '1 0 0';
};

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

// 2D ring approximated by line segments.
void(vector pos, float radius, vector color, float alpha) MinimapDrawRing =
{
    float N = 20;
    float two_pi = M_PI * 2;
    vector prev = [pos.x + radius, pos.y, 0];
    for (int i = 1; i <= N; i++) {
        float a = ((float)i / N) * two_pi;
        vector p = [pos.x + cos(a) * radius, pos.y + sin(a) * radius, 0];
        drawline(1, prev, p, color, alpha);
        prev = p;
    }
};

// Pick a color for a player relative to the local POV. '0 0 0' cvars fall back
// to the auto-derived skin-average colors.
vector(float pnum) MinimapPlayerColor =
{
    if (pnum == player_localnum) {
        return autocvar_minimap_player_color_self;
    }
    string pov_team = getplayerkeyvalue(player_localnum, "team");
    string his_team = getplayerkeyvalue(pnum, "team");
    float same_team = (pov_team == his_team && pov_team != "");
    vector c = same_team ? autocvar_minimap_player_color_team : autocvar_minimap_player_color_enemy;
    if (c == '0 0 0') {
        return same_team ? minimap_auto_color_team : minimap_auto_color_enemy;
    }
    return c;
};

// Reads an image file and returns its average RGB color, ignoring fully
// transparent pixels. Returns '-1 -1 -1' if the file can't be read or is empty.
vector(string path) MinimapAverageImageColor =
{
    int width, height, fmt;
    int *data = r_readimage(path, width, height, fmt);
    if (!data) {
        return '-1 -1 -1';
    }
    float rs = 0, gs = 0, bs = 0;
    int count = 0;
    int total = width * height;
    for (int i = 0; i < total; i++) {
        int p = data[i];
        int a = (p >> 24) & 255;
        if (a == 0) continue;
        rs += p & 255;
        gs += (p >> 8) & 255;
        bs += (p >> 16) & 255;
        count++;
    }
    memfree(data);
    if (count == 0) {
        return '-1 -1 -1';
    }
    float inv = 1.0 / (count * 255);
    return [rs * inv, gs * inv, bs * inv];
};

// Look up the team/enemy skin images via the engine cvars cl_teamskin /
// cl_enemyskin and store their average color.
void() MinimapComputeAutoColors =
{
    string ts = cvar_string("cl_teamskin");
    if (ts != "") {
        vector c = MinimapAverageImageColor(sprintf("skins/%s", ts));
        if (c.x >= 0) minimap_auto_color_team = c;
    }
    string es = cvar_string("cl_enemyskin");
    if (es != "") {
        vector c = MinimapAverageImageColor(sprintf("skins/%s", es));
        if (c.x >= 0) minimap_auto_color_enemy = c;
    }
    debug("minimap: auto team color %v, enemy color %v",
          minimap_auto_color_team, minimap_auto_color_enemy);
};

void(vector cam_origin) MinimapDrawPlayers =
{
    // Hard-coded fallbacks ensure markers render even when cvars are left at
    // 0 (e.g. from a stale config).
    float radius     = autocvar_minimap_player_radius        > 0 ? autocvar_minimap_player_radius        : 6;
    float dir_len    = autocvar_minimap_player_dir_len       > 0 ? autocvar_minimap_player_dir_len       : 14;
    float alpha_occ  = autocvar_minimap_player_alpha_occluded > 0 ? autocvar_minimap_player_alpha_occluded : 0.5;
    vector label_size = '8 8 0';

    MinimapBuildPlayerLabels();

    // Highlight the player the main view is tracking when there is one.
    // Skipped in FULL mode since there is no main view to correlate with.
    float highlight_enabled  = autocvar_minimap_mode != MINIMAP_FULL;
    float highlight_radius   = radius * (1.7 + sin(time * 4) * 0.1);
    float highlight_alpha    = 0.6;

    for (int i = 1; i <= maxclients; i++) {
        // The local POV player's entity may not show up in GE_ACTIVE / model
        // checks (engine hides own model). Detect players via their userinfo
        // name instead, which is set for every connected slot regardless.
        string pname = getplayerkeyvalue(i - 1, "name");
        if (pname == "") {
            continue;
        }
        vector origin = getentity(i, GE_ORIGIN);
        vector angles = getentity(i, GE_ANGLES);
        float  pnum   = i - 1;

        // 2D overlay is drawn after renderscene without depth test, so the
        // marker is always visible. Trace from player head straight UP to
        // detect a ceiling/floor above them. Starting at the player avoids
        // the "camera is in the outer void" problem. Hits inside a minimap
        // cull volume don't count - that's geometry the minimap intentionally
        // sees through, so we advance the trace past the volume and retry.
        vector head = [origin.x, origin.y, origin.z + 24];
        vector sky  = [origin.x, origin.y, origin.z + 100000];
        vector trace_from = head;
        float alpha = 1.0;
        float steps = 8;
        while (steps > 0) {
            steps--;
            traceline(trace_from, sky, MOVE_NOMONSTERS, world);
            if (trace_fraction >= 1) {
                break;  // exited cleanly
            }
            if (trace_endpos.z >= minimap_world_top_z - 32) {
                break;  // hit BSP outer boundary, treat as visible
            }
            float vol = MinimapPointInCullVolume(trace_endpos);
            if (vol < 0) {
                alpha = alpha_occ;  // genuine occlusion
                break;
            }
            // Hit a culled surface. Resume above the volume's top.
            trace_from = [trace_endpos.x, trace_endpos.y, minimap_volumes[vol].maxs.z + 1];
        }

        vector screen = project(origin);
        vector color  = MinimapPlayerColor(pnum);

        if (highlight_enabled && i == player_localentnum) {
            MinimapDrawRing(screen, highlight_radius, color, highlight_alpha);
        }

        MinimapDrawRing(screen, radius, color, alpha);

        // Look direction line from the player center. With camera looking
        // straight down (pitch 90, yaw 0), AngleVectors gives right=(0,-1,0)
        // and up=(1,0,0), so world +X projects to screen up and world +Y to
        // screen left. World yaw therefore maps to screen direction
        //   dx = -sin(yaw), dy = -cos(yaw)   (screen Y points down).
        float world_yaw = angles.y * M_PI / 180.0;
        float dx = -sin(world_yaw);
        float dy = -cos(world_yaw);
        vector dir_end = [screen.x + dx * dir_len, screen.y + dy * dir_len, 0];
        drawline(1, screen, dir_end, color, alpha);

        // Label is either a fixed-length prefix (when minimap_player_label_size > 0)
        // or the shortest prefix unique to this player.
        string label;
        if (autocvar_minimap_player_label_size > 0) {
            label = substring(minimap_label_name[pnum], 0, autocvar_minimap_player_label_size);
        } else {
            label = MinimapShortestUniquePrefix(pnum);
        }
        float text_y = screen.y + radius + 2;
        if (label != "") {
            float lw = stringwidth(label, 0, label_size);
            vector label_pos = [screen.x - lw * 0.5, text_y, 0];
            drawstring(label_pos, label, label_size, color, alpha, 0);
            text_y += label_size.y + 1;
        }

        // Health bar + active weapon, mirroring the autoid display from the
        // player view. getplayerstat works for any player in MVD playback.
        float health = getplayerstat(pnum, STAT_HEALTH, EV_FLOAT);
        if (health > 0) {
            float bar_w = 24;
            float bar_h = 2;
            vector bar_pos = [screen.x - bar_w * 0.5, text_y, 0];
            drawfill(bar_pos, [bar_w, bar_h], '0 0 0', alpha * 0.6);
            float frac = health > 100 ? 1 : health / 100;
            drawfill(bar_pos, [bar_w * frac, bar_h], MinimapHealthColor(health), alpha);
            text_y += bar_h + 2;

            float weapon = getplayerstat(pnum, STAT_ACTIVEWEAPON, EV_FLOAT);
            string wlabel = MinimapWeaponLabel(weapon);
            if (wlabel != "") {
                float ww = stringwidth(wlabel, 0, label_size);
                vector wpos = [screen.x - ww * 0.5, text_y, 0];
                drawstring(wpos, wlabel, label_size, MinimapWeaponColor(weapon), alpha, 0);
            }
        }
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
    MinimapDescribeCvar("minimap_player_alpha_occluded",
        "Alpha applied to player markers when the player is occluded from the minimap camera. Visible players are drawn at alpha 1. Default 0.5.");
    MinimapDescribeCvar("minimap_player_color_team",
        "Ring/triangle color for same-team players. '0 0 0' = average color of the cl_teamskin image.");
    MinimapDescribeCvar("minimap_player_color_enemy",
        "Ring/triangle color for opposing-team players. '0 0 0' = average color of the cl_enemyskin image.");
    MinimapDescribeCvar("minimap_player_color_self",
        "Ring/triangle color for the local player.");
    MinimapDescribeCvar("minimap_player_label_size",
        "Fixed number of characters to show in each player label. 0 = auto (shortest prefix unique among all current players).");
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
