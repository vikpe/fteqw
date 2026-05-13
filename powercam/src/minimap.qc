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

// VF_CULLVOLUME (226) is an engine-side extension fteqcc doesn't know about;
// silence the spurious "unknown argument" warning on setproperty calls.
#pragma warning disable F333

#define MINIMAP_OFF   0
#define MINIMAP_PIP   1
#define MINIMAP_SPLIT 2
#define MINIMAP_FULL  3

#define MINIMAP_MAX_CULL_VOLUMES 32

typedef struct {
    vector mins;
    vector maxs;
} minimap_volume_t;

var float  autocvar_qdw_minimap_mode             = MINIMAP_SPLIT;
var float  autocvar_qdw_minimap_ortho            = 0;
var float  autocvar_qdw_minimap_height_offset    = 0;
var vector autocvar_qdw_minimap_center_override  = '0 0 0';
var float  autocvar_qdw_minimap_player_radius           = 7;
var float  autocvar_qdw_minimap_player_alpha_occluded   = 0.8;
var float  autocvar_qdw_minimap_player_label_name_length       = 4;
var float  autocvar_qdw_minimap_player_label_font_size  = 6;
// '0 0 0' = sentinel for "use the built-in default" (green for team, red
// for enemy). Any non-zero value overrides.
var vector autocvar_qdw_minimap_player_color_team       = '0 0 0';
var vector autocvar_qdw_minimap_player_color_enemy      = '0 0 0';
var vector autocvar_qdw_minimap_player_color_self       = '1 1 0';

// Built-in defaults used when the team/enemy color cvars are left at '0 0 0'.
var vector minimap_default_color_team  = '0 1 0';
var vector minimap_default_color_enemy = '1 0 0';

var minimap_volume_t minimap_volumes[MINIMAP_MAX_CULL_VOLUMES];
var int    minimap_num_volumes = 0;
var vector minimap_center      = '0 0 0';
var float  minimap_ortho       = 2048;
var float  minimap_height      = 4096;
var float  minimap_world_top_z = 0;   // BSP maxs.z, set in MinimapAutoBounds
var float  minimap_world_dx    = 0;   // BSP width  (maxs.x - mins.x)
var float  minimap_world_dy    = 0;   // BSP depth  (maxs.y - mins.y)
var float  minimap_loaded      = 0;

// Auto-cull state. Populated lazily on the first render after world load,
// once the server has sent baseline entities for the pickups. Highest pickup
// origin Z (weapons, armor, health, ammo) defines the play-floor ceiling -
// anything above that is roof/upper geometry the minimap should see through.
var float  minimap_auto_pickup_max_z = -99999;
var float  minimap_auto_pickup_known = 0;
var string minimap_loaded_for  = "";

// Forward declarations.
float(vector p) MinimapPointInCullVolume;

void() MinimapResetState =
{
    minimap_num_volumes = 0;
    minimap_center      = '0 0 0';
    minimap_ortho       = 2048;
    minimap_height      = 4096;
    minimap_auto_pickup_max_z = -99999;
    minimap_auto_pickup_known = 0;
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
    string fname = sprintf("locs/%s.loc", mapname);
    filestream fh = fopen(fname, FILE_READ);
    if (fh < 0) {
        return 0;
    }

    float minx =  99999, miny =  99999;
    float maxx = -99999, maxy = -99999;
    float count = 0;

    string line;
    while ((line = fgets(fh))) {
        if (line == "") continue;

        if (strstrofs(line, ",", 0) >= 0) {
            // FTE AABB format - six comma-separated coords
            float nt = tokenizebyseparator(line, ",");
            if (nt < 6) continue;
            float a = stof(argv(0)), b = stof(argv(1));
            float c = stof(argv(3)), d = stof(argv(4));
            if (a < minx) minx = a;
            if (c < minx) minx = c;
            if (a > maxx) maxx = a;
            if (c > maxx) maxx = c;
            if (b < miny) miny = b;
            if (d < miny) miny = d;
            if (b > maxy) maxy = b;
            if (d > maxy) maxy = d;
            count++;
            continue;
        }

        // QW classic: integer eighths, space-separated
        float n = tokenize_console(line);
        if (n < 4) continue;
        if (argv(0) == "" || !(stof(argv(0)) != 0 || argv(0) == "0")) continue;
        float x = stof(argv(0)) / 8;
        float y = stof(argv(1)) / 8;
        if (x < minx) minx = x;
        if (y < miny) miny = y;
        if (x > maxx) maxx = x;
        if (y > maxy) maxy = y;
        count++;
    }
    fclose(fh);

    if (count == 0 || maxx <= minx) {
        return 0;
    }

    // .loc files only mark named landmarks, not the full playable extent.
    // Inflate generously so corners/walls of the playable area aren't
    // cropped, then only adopt the result if it's actually tighter than
    // the BSP-derived bounds.
    float pad = 256;
    minx -= pad;  miny -= pad;
    maxx += pad;  maxy += pad;

    float new_ext   = max(maxx - minx, maxy - miny);
    float new_ortho = new_ext * 0.5 + 64;
    if (new_ortho >= minimap_ortho) {
        return 0;
    }

    minimap_center.x = (minx + maxx) * 0.5;
    minimap_center.y = (miny + maxy) * 0.5;
    minimap_ortho = new_ortho;
    // Also feed the tighter bounds into the world extents so MinimapRender's
    // scale calc uses them. Otherwise the render keeps padding 15% around the
    // full BSP and you get ugly empty borders on maps that .loc has tightened.
    minimap_world_dx = maxx - minx;
    minimap_world_dy = maxy - miny;
    debug("minimap: locs/%s.loc narrowed bounds (%g points), center %v, ortho %g",
          mapname, count, minimap_center, minimap_ortho);
    return 1;
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
    MinimapNarrowToLocFile();

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

// Split-mode horizontal partition: player view on the left, minimap on
// the right. 0.60 = player view gets 60% of the screen width.
#define MINIMAP_SPLIT_MAIN_FRAC 0.50

// Returns 1 if the main player view should render, filling vmin/vsize with
// its viewport rect. Returns 0 when the minimap is in FULL mode (main view
// is hidden).
float(float vw, float vh, __out vector vmin, __out vector vsize) MinimapMainViewport =
{
    float mode = autocvar_qdw_minimap_mode;
    if (mode == MINIMAP_SPLIT) {
        vmin  = '0 0 0';
        vsize = [vw * MINIMAP_SPLIT_MAIN_FRAC, vh, 0];
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
        vmin  = [vw * MINIMAP_SPLIT_MAIN_FRAC, 0, 0];
        vsize = [vw * (1 - MINIMAP_SPLIT_MAIN_FRAC), vh, 0];
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
            vmin  = [(vw - target_w) * 0.5, (vh - target_h) * 0.5, 0];
            vsize = [target_w, target_h, 0];
        } else {
            vmin  = '0 0 0';
            vsize = [vw, vh, 0];
        }
        break;
    }
};

// Sanitize a player name for display via drawstring: keep printable ASCII,
// QW ^X color codes, and any chars Quake's font can render (high-bit bronze
// bytes when utf8_enable is off; qchar codepoints 0xE000..0xE0FF when on).
// Both ranges are accepted unconditionally - whichever the engine actually
// uses depends on utf8_enable, the other range will simply be empty in
// practice.
string(string raw) MinimapNormalizeName =
{
    string out = "";
    float n = strlen(raw);
    float i;
    for (i = 0; i < n; i++) {
        float c = str2chr(raw, i);
        // ^X is a 2-byte color marker; keep both bytes verbatim (^^ -> literal ^).
        if (c == '^' && i + 1 < n) {
            float nxt = str2chr(raw, i + 1);
            out = strcat(out, chr2str(c));
            out = strcat(out, chr2str(nxt));
            i++;
            continue;
        }
        // Quake's font has renderable glyphs across the full byte range:
        //   16..17    brackets [ ]
        //   18..27    gold numbers 0-9
        //   33..126   standard ASCII
        //   144..145  brackets [ ] (high-bit duplicate)
        //   146..155  gold numbers 0-9 (high-bit duplicate)
        //   161..254  brown ASCII a-z, A-Z, 0-9, punctuation
        // We accept bytes 16..255 (drop only the few leading control-range
        // chars that all render as blank) and the full UTF-8 qchar range
        // 0xE000..0xE0FF used when utf8_enable is on.
        if ((c >= 16 && c <= 255) || (c >= 0xE000 && c <= 0xE0FF)) {
            out = strcat(out, chr2str(c));
        }
    }
    return out;
};

// Returns the first `n_visible` characters of a colored name, copying any ^X
// markup verbatim alongside the kept chars so drawstring still recolors them.
string(string colored, float n_visible) MinimapColoredPrefix =
{
    string out = "";
    float len = strlen(colored);
    float visible = 0;
    float i;
    for (i = 0; i < len; i++) {
        if (visible >= n_visible) {
            break;
        }
        float c = str2chr(colored, i);
        if (c == '^' && i + 1 < len) {
            float nxt = str2chr(colored, i + 1);
            out = strcat(out, chr2str(c));
            out = strcat(out, chr2str(nxt));
            i++;
            if (nxt == '^') {
                visible++;  // ^^ unescapes to a single visible '^'
            }
            continue;
        }
        out = strcat(out, chr2str(c));
        visible++;
    }
    return out;
};

// Per-frame cache of player names. We keep two versions:
//   _name  - sanitized, retains ^X color codes & bronze chars (for drawing)
//   _plain - markup-stripped variant (for prefix uniqueness comparisons)
#define MINIMAP_MAX_PLAYERS 32
var string minimap_label_name[MINIMAP_MAX_PLAYERS];
var string minimap_label_plain[MINIMAP_MAX_PLAYERS];

// Per-frame doppelganger overlays for players the minimap camera can't see
// directly. Engine-side player entities aren't exposed as QC entities
// (deltalisten isn't registered unless qdw_xray is on), so we can't flip
// EF_NODEPTHTEST on them. Instead, for each occluded player we spawn a
// throwaway QC entity that mirrors the player's pose and add it to the
// scene with NODEPTHTEST + alpha so it shows through walls/roofs.
// Visible players are skipped - the engine already draws them at full
// opacity, and we don't want a double-render.
var entity minimap_doppel_ents[MINIMAP_MAX_PLAYERS];
var int    minimap_doppel_count = 0;

// Returns 1 if the line from cam_origin to the player's head is blocked by
// world geometry that isn't part of a minimap cull volume. Mirrors the
// xray-style traceline pattern from main.qc:301, with extra walking through
// cull volumes since the minimap camera looks down through roofs that are
// intentionally hidden in the render.
float(vector cam_origin, vector player_origin) MinimapPlayerOccluded =
{
    vector head = [player_origin.x, player_origin.y, player_origin.z + 24];
    // Start just inside the BSP. cam_origin sits above the outer hull, and
    // tracing from outside into BSP space hits the hull's top first, which
    // would falsely flag every player as occluded.
    vector trace_from = [cam_origin.x, cam_origin.y, minimap_world_top_z - 1];
    if (trace_from.z <= head.z) {
        return 0;
    }
    float steps = 8;
    while (steps > 0) {
        steps--;
        traceline(trace_from, head, MOVE_NORMAL | MOVE_NOMONSTERS, world);
        if (trace_fraction == 1) {
            return 0;
        }
        float vol = MinimapPointInCullVolume(trace_endpos);
        if (vol < 0) {
            return 1;
        }
        trace_from = [trace_endpos.x, trace_endpos.y, minimap_volumes[vol].mins.z - 1];
        if (trace_from.z <= head.z) {
            return 0;
        }
    }
    return 0;
};

void(vector cam_origin) MinimapSpawnOccludedDoppelgangers =
{
    float plyr_mdl = getmodelindex("progs/player.mdl");
    minimap_doppel_count = 0;
    for (int i = 1; i <= maxclients; i++) {
        if (minimap_doppel_count >= MINIMAP_MAX_PLAYERS) break;
        float active = getentity(i, GE_ACTIVE);
        if (!active) continue;
        float modidx = getentity(i, GE_MODELINDEX);
        if (modidx != plyr_mdl) continue;
        vector origin = getentity(i, GE_ORIGIN);
        if (origin == '0 0 0') continue;
        if (!MinimapPlayerOccluded(cam_origin, origin)) continue;

        float occ_alpha = autocvar_qdw_minimap_player_alpha_occluded > 0
                          ? autocvar_qdw_minimap_player_alpha_occluded : 0.8;

        entity d = spawn();
        setmodelindex(d, plyr_mdl);
        setorigin(d, origin);
        d.angles  = getentity(i, GE_ANGLES);
        d.frame   = getentity(i, GE_FRAME);
        d.skin    = getentity(i, GE_SKIN);
        d.alpha   = occ_alpha;
        d.effects = EF_NODEPTHTEST;
        addentity(d);

        minimap_doppel_ents[minimap_doppel_count] = d;
        minimap_doppel_count++;
    }
};

void() MinimapRemoveDoppelgangers =
{
    for (int i = 0; i < minimap_doppel_count; i++) {
        if (minimap_doppel_ents[i]) {
            remove(minimap_doppel_ents[i]);
            minimap_doppel_ents[i] = nil;
        }
    }
    minimap_doppel_count = 0;
};

void() MinimapBuildPlayerLabels =
{
    float plyr_mdl = getmodelindex("progs/player.mdl");
    for (int i = 0; i < MINIMAP_MAX_PLAYERS; i++) {
        minimap_label_name[i]  = "";
        minimap_label_plain[i] = "";
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
        minimap_label_name[i]  = MinimapNormalizeName(raw);
        minimap_label_plain[i] = strdecolorize(minimap_label_name[i]);
    }
};

// Returns the shortest visible-character prefix of player `pi`'s name that no
// other active player's name starts with. Comparison uses the decolored plain
// form so two players named e.g. "^1Foo" and "^2Foo" still need disambiguation,
// but the returned string keeps its color markup for drawstring.
string(float pi) MinimapShortestUniquePrefix =
{
    string mine_plain = minimap_label_plain[pi];
    float my_len = strlen(mine_plain);
    if (my_len == 0) {
        return "";
    }
    for (float n = 1; n <= my_len; n++) {
        string my_prefix = substring(mine_plain, 0, n);
        float unique = 1;
        for (int j = 0; j < MINIMAP_MAX_PLAYERS; j++) {
            if (j == pi) continue;
            string other = minimap_label_plain[j];
            if (other == "") continue;
            if (substring(other, 0, n) == my_prefix) {
                unique = 0;
                break;
            }
        }
        if (unique) {
            return MinimapColoredPrefix(minimap_label_name[pi], n);
        }
    }
    return minimap_label_name[pi];
};

// STAT_ITEMS bits we surface on the minimap.
#define MM_IT_GRENADE_LAUNCHER 16
#define MM_IT_ROCKET_LAUNCHER  32
#define MM_IT_LIGHTNING        64
#define MM_IT_ARMOR1           8192    // Green Armor   (max 100)
#define MM_IT_ARMOR2           16384   // Yellow Armor  (max 150)
#define MM_IT_ARMOR3           32768   // Red Armor     (max 200)

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

string(float weapon_bit) MinimapWeaponName =
{
    switch ((int)weapon_bit) {
    case MM_IT_GRENADE_LAUNCHER: return "GL";
    case MM_IT_ROCKET_LAUNCHER:  return "RL";
    case MM_IT_LIGHTNING:        return "LG";
    default:                     return "";
    }
};

// Health/armor color tables, mirroring the autoid tables in view.c:1823 /
// view.c:1831 so the minimap and the engine's autoid overlay share a visual
// language. Bars are rendered in two segments: dim color on the depleted
// side, full color on the remaining side.
//
// healthcolours[r] (dim) + healthcolours[r+1] (full) where r=floor(hp/100).
const vector MINIMAP_HEALTH_C0 = '0.7 0.45 0.45';
const vector MINIMAP_HEALTH_C1 = '0.3 0 0';
const vector MINIMAP_HEALTH_C2 = '1 0 0';
const vector MINIMAP_HEALTH_C3 = '1 0.4 0';
const vector MINIMAP_HEALTH_C4 = '1 1 1';

vector(float idx) MinimapHealthColorAt =
{
    if (idx <= 0) return MINIMAP_HEALTH_C0;
    if (idx == 1) return MINIMAP_HEALTH_C1;
    if (idx == 2) return MINIMAP_HEALTH_C2;
    if (idx == 3) return MINIMAP_HEALTH_C3;
    return MINIMAP_HEALTH_C4;
};

// Armor tiers: 0/1 = GA dim/full, 2/3 = YA dim/full, 4/5 = RA dim/full.
const vector MINIMAP_ARMOR_GA_DIM  = '0 0.4 0';
const vector MINIMAP_ARMOR_GA_FULL = '0 1 0';
const vector MINIMAP_ARMOR_YA_DIM  = '0.4 0.4 0';
const vector MINIMAP_ARMOR_YA_FULL = '1 1 0';
const vector MINIMAP_ARMOR_RA_DIM  = '0.4 0 0';
const vector MINIMAP_ARMOR_RA_FULL = '1 0 0';

// Known Quake 1 pickup model names. Anything in this set sits on the play
// floor when spawned, so their Z values give a clean baseline for the
// minimap's auto-cull height. Excludes monsters, gibs, dropped backpacks.
float(string mname) MinimapIsPickupModel =
{
    if (mname == "") return 0;
    // Weapons
    if (mname == "progs/g_shot.mdl")  return 1;
    if (mname == "progs/g_nail.mdl")  return 1;
    if (mname == "progs/g_nail2.mdl") return 1;
    if (mname == "progs/g_rock.mdl")  return 1;
    if (mname == "progs/g_rock2.mdl") return 1;
    if (mname == "progs/g_light.mdl") return 1;
    // Armor (single mdl, colored via .skin)
    if (mname == "progs/armor.mdl")   return 1;
    // Powerups
    if (mname == "progs/quaddama.mdl") return 1;
    if (mname == "progs/invulner.mdl") return 1;
    if (mname == "progs/suit.mdl")     return 1;
    if (mname == "progs/invisibl.mdl") return 1;
    // Health boxes (BSP submodels)
    if (mname == "maps/b_bh100.bsp")  return 1;
    if (mname == "maps/b_bh25.bsp")   return 1;
    if (mname == "maps/b_bh10.bsp")   return 1;
    // Ammo boxes
    if (mname == "maps/b_shell0.bsp") return 1;
    if (mname == "maps/b_shell1.bsp") return 1;
    if (mname == "maps/b_nail0.bsp")  return 1;
    if (mname == "maps/b_nail1.bsp")  return 1;
    if (mname == "maps/b_rock0.bsp")  return 1;
    if (mname == "maps/b_rock1.bsp")  return 1;
    if (mname == "maps/b_batt0.bsp")  return 1;
    if (mname == "maps/b_batt1.bsp")  return 1;
    return 0;
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
    int   added = 0;
    int   pad_outdoor = 0;

    // First pass: count pickups. Stops us adding partial cull volumes on
    // tiny / training / non-DM maps whose pickup geometry isn't a useful
    // signal for "where the play floor is".
    int found = 0;
    float n = getentity(0, GE_MAXENTS);
    for (float i = 1; i < n; i++) {
        float active = getentity(i, GE_ACTIVE);
        if (!active) continue;
        float midx = getentity(i, GE_MODELINDEX);
        if (midx == 0) continue;
        string mname = modelnameforindex(midx);
        if (MinimapIsPickupModel(mname)) found++;
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
    for (float j = 1; j < n && minimap_num_volumes < MINIMAP_MAX_CULL_VOLUMES; j++) {
        float active = getentity(j, GE_ACTIVE);
        if (!active) continue;
        float midx = getentity(j, GE_MODELINDEX);
        if (midx == 0) continue;
        string mname = modelnameforindex(midx);
        if (!MinimapIsPickupModel(mname)) continue;

        vector org = getentity(j, GE_ORIGIN);

        // Brushmodel pickups (maps/b_*.bsp) have their origin below the
        // visible floor - tracing straight up from origin would hit the
        // floor surface itself, not the ceiling. Start above the entity's
        // bounding-box top (or a safe player-head offset if absmax is
        // missing) so the trace only sees what is genuinely above.
        vector amax = getentity(j, GE_ABSMAX);
        float start_z = (amax.z > org.z + 1) ? amax.z + 1 : org.z + 56;
        traceline([org.x, org.y, start_z],
                  [org.x, org.y, start_z + 100000],
                  MOVE_NORMAL | MOVE_NOMONSTERS, world);
        if (trace_fraction == 1) {
            // Open sky above (no roof) - no auto-cull needed for this pickup.
            pad_outdoor++;
            continue;
        }
        float ceil_z = trace_endpos.z;
        // If the trace hit the BSP outer hull (near world_top_z), treat as
        // outdoor too - we don't want to cull the skybox itself.
        if (ceil_z >= minimap_world_top_z - 32) {
            pad_outdoor++;
            continue;
        }

        minimap_volumes[minimap_num_volumes].mins =
            [org.x - region_pad, org.y - region_pad, ceil_z + ceiling_margin];
        minimap_volumes[minimap_num_volumes].maxs =
            [org.x + region_pad, org.y + region_pad,  99999];
        minimap_num_volumes++;
        added++;

        // Keep the legacy summary value (used by the world_top_z safety in
        // MinimapPlayerOccluded) - max ceiling seen so far.
        if (ceil_z > minimap_auto_pickup_max_z) {
            minimap_auto_pickup_max_z = ceil_z;
        }
    }
    minimap_auto_pickup_known = 1;
    debug("minimap: scanned %d pickups (%d added cull volumes, %d outdoor)",
          (float)found, (float)added, (float)pad_outdoor);
    return 1;
};

// One-time shader registration. "qdw_minimap_fill" is a simple 2D fill shader
// with per-vertex color and alpha - identical to the one PF_CL_drawline
// uses (engine/client/pr_menu.c:1074-1083). Used to render thick lines as
// quads since drawline's width parameter is ignored by the engine.
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

// Draw a line of arbitrary thickness as a screen-space quad. Width is in
// pixels, applied perpendicular to the segment direction.
void(vector a, vector b, float width, vector color, float alpha) MinimapDrawThickLine =
{
    float dx = b.x - a.x;
    float dy = b.y - a.y;
    float len = sqrt(dx * dx + dy * dy);
    if (len <= 0) {
        return;
    }
    float nx = -dy / len * width * 0.5;
    float ny =  dx / len * width * 0.5;

    R_BeginPolygon("minimap_fill_v3", 0, 1);
    R_PolygonVertex([a.x + nx, a.y + ny, 0], '0 0 0', color, alpha);
    R_PolygonVertex([a.x - nx, a.y - ny, 0], '0 0 0', color, alpha);
    R_PolygonVertex([b.x - nx, b.y - ny, 0], '0 0 0', color, alpha);
    R_PolygonVertex([b.x + nx, b.y + ny, 0], '0 0 0', color, alpha);
    R_EndPolygon();
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

// Filled disc with a radial gradient: alpha goes from `center_alpha` at the
// middle to `edge_alpha` at the rim, color is constant. Rendered as a
// triangle fan rooted at the center.
void(vector pos, float radius, vector color, float center_alpha, float edge_alpha) MinimapDrawDisc =
{
    float N = 32;
    float two_pi = M_PI * 2;
    R_BeginPolygon("minimap_fill_v3", 0, 1);
    R_PolygonVertex(pos, '0 0 0', color, center_alpha);
    int i;
    for (i = 0; i <= N; i++) {
        float a = ((float)(i % N) / N) * two_pi;
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
    float N = 32;
    float two_pi = M_PI * 2;

    if (thickness <= 1) {
        vector prev = [pos.x + radius, pos.y, 0];
        int j;
        for (j = 1; j <= N; j++) {
            float a = ((float)j / N) * two_pi;
            vector p = [pos.x + cos(a) * radius, pos.y + sin(a) * radius, 0];
            drawline(1, prev, p, color, alpha);
            prev = p;
        }
        return;
    }

    float inner = radius - thickness * 0.5;
    float outer = radius + thickness * 0.5;
    int i;
    for (i = 0; i < N; i++) {
        float a0 = ((float)i       / N) * two_pi;
        float a1 = ((float)(i + 1) / N) * two_pi;
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

// Pick a color for a player relative to the tracked POV. While spectating,
// player_localnum points at the spectator slot (no team), so all players
// would read as "enemy". player_localentnum is the entity the engine is
// actually viewing through - the tracked player. Team coloring keys off
// that player's team instead, so teammates of whoever you're tracking
// render as team-colored.
//
// Mirrors the engine's TP_PlayerTeam / cl.teamplay pattern (zqtp.c:328,
// cl_cam.c:446): same-team only counts in teamplay mode. In FFA every
// non-self player is an enemy regardless of userinfo team strings.
vector(float pnum) MinimapPlayerColor =
{
    float pov_pnum = (player_localentnum > 0) ? (player_localentnum - 1) : player_localnum;
    if (pnum == pov_pnum) {
        return autocvar_qdw_minimap_player_color_self;
    }
    float same_team = 0;
    if (serverkeyfloat("teamplay") > 0) {
        string pov_team = getplayerkeyvalue(pov_pnum, "team");
        string his_team = getplayerkeyvalue(pnum, "team");
        same_team = (pov_team == his_team && pov_team != "");
    }
    vector c = same_team ? autocvar_qdw_minimap_player_color_team : autocvar_qdw_minimap_player_color_enemy;
    if (c == '0 0 0') {
        return same_team ? minimap_default_color_team : minimap_default_color_enemy;
    }
    return c;
};

void(vector cam_origin) MinimapDrawPlayers =
{
    // Hard-coded fallbacks ensure markers render even when cvars are left at
    // 0 (e.g. from a stale config).
    float radius     = autocvar_qdw_minimap_player_radius        > 0 ? autocvar_qdw_minimap_player_radius        : 7;
    float alpha_occ  = autocvar_qdw_minimap_player_alpha_occluded > 0 ? autocvar_qdw_minimap_player_alpha_occluded : 0.5;
    // Name labels use a cvar-controlled font size; weapon labels are fixed
    // at the same reduced size. Both default to 6 (25% smaller than 8).
    float name_fs = autocvar_qdw_minimap_player_label_font_size > 0
                    ? autocvar_qdw_minimap_player_label_font_size : 6;
    vector label_size  = [name_fs, name_fs, 0];
    vector weapon_size = '6 6 0';

    // Hide HUD-style indicators (health/armor/powerups/weapons) while the
    // match isn't ongoing. The server's status string only contains "min left"
    // once the round is actually running (standby/countdown have other text).
    float match_active = strstrofs(serverkey("status"), "min left", 0) >= 0;

    MinimapBuildPlayerLabels();

    // Highlight the player the main view is tracking when there is one.
    // Skipped in FULL mode since there is no main view to correlate with.
    float highlight_enabled  = autocvar_qdw_minimap_mode != MINIMAP_FULL;
    float highlight_radius   = radius + 4;
    float highlight_alpha    = 1;
    vector highlight_color   = '0 1 1';  // #00ffff

    float plyr_mdl = getmodelindex("progs/player.mdl");
    float is_demo  = isdemo();

    for (int i = 1; i <= maxclients; i++) {
        float pnum_idx = i - 1;
        // Slot must have a name (so it's connected).
        string pname = getplayerkeyvalue(pnum_idx, "name");
        if (pname == "") {
            continue;
        }
        // Spectators have userinfo but no playable entity.
        if (stof(getplayerkeyvalue(pnum_idx, "*spectator")) > 0) {
            continue;
        }
        // Mirrors bindings.cpp:getPlayers: on demo playback, post-match
        // ghost slots can linger with no frags and zeroed colors. Drop them.
        if (is_demo
            && stof(getplayerkeyvalue(pnum_idx, "frags"))       < 1
            && stof(getplayerkeyvalue(pnum_idx, "topcolor"))    == 0
            && stof(getplayerkeyvalue(pnum_idx, "bottomcolor")) == 0) {
            continue;
        }
        // Require an active player entity. Without this, slots whose entity
        // hasn't synced (typical for QTV during gaps) get phantom markers
        // even though the renderer has no model to draw.
        float active = getentity(i, GE_ACTIVE);
        if (!active) {
            continue;
        }
        float modidx = getentity(i, GE_MODELINDEX);
        if (modidx != plyr_mdl) {
            continue;
        }
        vector origin = getentity(i, GE_ORIGIN);
        // Origin at world zero usually means the entity slot exists but the
        // server hasn't placed it yet (mid-respawn, mid-pickup, sync gap).
        // Skip - the renderer won't draw the model there either.
        if (origin == '0 0 0') {
            continue;
        }
        vector angles = getentity(i, GE_ANGLES);
        float  pnum   = pnum_idx;

        // 2D overlay is drawn after renderscene without depth test, so the
        // marker is always visible. Mirrors main.qc:301's xray occlusion
        // test: trace from the minimap camera straight at the player. If
        // the hit point falls inside a cull volume, the geometry there is
        // hidden in the render, so we advance past the volume and retry.
        vector head = [origin.x, origin.y, origin.z + 24];
        vector trace_from = cam_origin;
        float alpha = 1.0;
        float steps = 8;
        while (steps > 0) {
            steps--;
            traceline(trace_from, head, MOVE_NORMAL | MOVE_NOMONSTERS, world);
            if (trace_fraction == 1) {
                break;  // unobstructed line of sight
            }
            float vol = MinimapPointInCullVolume(trace_endpos);
            if (vol < 0) {
                alpha = alpha_occ;  // genuine occlusion
                break;
            }
            // Hit geometry inside a cull volume. Resume just under it.
            trace_from = [trace_endpos.x, trace_endpos.y, minimap_volumes[vol].mins.z - 1];
            if (trace_from.z <= head.z) {
                break;  // descended past the target, treat as visible
            }
        }

        vector screen = project(origin);
        vector color  = MinimapPlayerColor(pnum);

        // One ring per player: tracked POV gets a cyan, 1.25x scaled,
        // 3-px-thick outline with a halo-style gradient disc extending 3x
        // further. Everyone else gets a regular team-colored ring.
        float is_tracked   = highlight_enabled && i == player_localentnum;
        float ring_radius  = radius;
        float disc_radius  = ring_radius;
        vector ring_color  = is_tracked ? highlight_color : color;
        float ring_thick   = is_tracked ? 1.5 : 1;

        // Tracked: fuller alpha at center (gradient still fades out to the
        // ring edge) so the disc reads as more "filled in" without growing
        // past the outline.
        float disc_center_alpha = is_tracked ? 1 : 0.5;
        MinimapDrawDisc(screen, disc_radius, ring_color, disc_center_alpha, 0);
        MinimapDrawRing(screen, ring_radius, ring_color, 1, ring_thick);

        // Active powerups (server sets EF_BLUE for Quad, EF_RED for Pent;
        // both may be set). Icons are drawn later, to the left of the bars.
        // Suppressed entirely outside of an ongoing match.
        float effects = getentity(i, GE_EFFECTS);
        float has_quad = match_active && ((int)effects & EF_BLUE);
        float has_pent = match_active && ((int)effects & EF_RED);

        // Look direction arrowhead sitting on the ring's edge. With camera
        // looking straight down (pitch 90, yaw 0), AngleVectors gives
        // right=(0,-1,0) and up=(1,0,0), so world +X projects to screen up
        // and world +Y to screen left. World yaw maps to screen direction
        //   dx = -sin(yaw), dy = -cos(yaw)   (screen Y points down).
        float world_yaw = angles.y * M_PI / 180.0;
        float dx = -sin(world_yaw);
        float dy = -cos(world_yaw);
        float tri_size  = ring_radius * 0.4 + 1;
        float half_base = tri_size * 0.5;
        float base_dist = ring_radius;
        vector tip = [screen.x + dx * (base_dist + tri_size),
                      screen.y + dy * (base_dist + tri_size), 0];
        vector b1  = [screen.x + dx * base_dist - dy * half_base,
                      screen.y + dy * base_dist + dx * half_base, 0];
        vector b2  = [screen.x + dx * base_dist + dy * half_base,
                      screen.y + dy * base_dist - dx * half_base, 0];
        R_BeginPolygon("minimap_fill_v3", 0, 1);
        R_PolygonVertex(tip, '0 0 0', ring_color, 1);
        R_PolygonVertex(b1,  '0 0 0', ring_color, 1);
        R_PolygonVertex(b2,  '0 0 0', ring_color, 1);
        R_EndPolygon();

        // Label is either a fixed-length visible-char prefix (when
        // minimap_player_label_name_length > 0) or the shortest prefix unique to
        // this player. Both forms keep any ^X markup in front of each kept
        // char so drawstring can recolor them.
        string label;
        if (autocvar_qdw_minimap_player_label_name_length > 0) {
            label = MinimapColoredPrefix(minimap_label_name[pnum], autocvar_qdw_minimap_player_label_name_length);
        } else {
            label = MinimapShortestUniquePrefix(pnum);
        }
        // Name label centered on the player marker; powerup icons sit to its
        // left as a prefix (do not shift the name).
        float icon_count = (has_quad ? 1 : 0) + (has_pent ? 1 : 0);
        float icon_h = label_size.y;
        float icon_w = icon_h;
        float icon_gap = icon_count > 0 ? 2 : 0;
        // usecolours=1 makes stringwidth ignore markup so layout matches what
        // drawstring actually paints.
        float lw = (label != "") ? stringwidth(label, 1, label_size) : 0;
        float top    = screen.y - radius - label_size.y - 2;
        float name_x = screen.x - lw * 0.5;
        float ix     = name_x - (icon_w * icon_count + icon_gap);
        if (has_quad) {
            drawpic([ix, top, 0], "sb_quad",
                    [icon_w, icon_h, 0], '1 1 1', 1, 0);
            ix += icon_w;
        }
        if (has_pent) {
            drawpic([ix, top, 0], "sb_invuln",
                    [icon_w, icon_h, 0], '1 1 1', 1, 0);
        }
        if (label != "") {
            // Pass white so drawstring uses the charset's native colors:
            // plain ASCII = white, qchars in bronze, ^X markup applied
            // per-character. Tinting via the rgb arg would override every
            // unmarked char with the team color.
            drawstring([name_x, top, 0], label, label_size, '1 1 1', 1, 0);
        }
        float text_y = screen.y + radius + 2;

        // Health bar, armor bar, owned-weapon labels - mirroring autoid.
        // getplayerstat works for any player in MVD playback. Hidden during
        // standby/countdown (match not actually started yet).
        float health = getplayerstat(pnum, STAT_HEALTH, EV_FLOAT);
        if (match_active && health > 0) {
            float bar_w = 17;
            float bar_h = 1;
            float bar_gap = 1;
            float bar_left = screen.x - bar_w * 0.5;
            float bar_top  = text_y;
            float bar_group_h = bar_h * 2 + bar_gap;

            // Health bar - two-tone, matching the autoid table in view.c:1823.
            // r = floor(hp/100); LEFT segment (width = bar_w*frac) draws the
            // brighter colours[r+1], RIGHT (1-frac) draws the dimmer colours[r].
            vector hpos = [bar_left, text_y, 0];
            float h_idx  = floor(health / 100);
            float h_frac = health / 100 - h_idx;
            if (h_idx > 3) { h_idx = 3; h_frac = 1; }
            if (h_idx < 0) { h_idx = 0; h_frac = 0; }
            vector h_dim  = MinimapHealthColorAt(h_idx);
            vector h_full = MinimapHealthColorAt(h_idx + 1);
            drawfill(hpos, [bar_w, bar_h], '0 0 0', 0.6);
            drawfill(hpos, [bar_w * h_frac, bar_h], h_full, 1);
            drawfill([bar_left + bar_w * h_frac, text_y, 0],
                     [bar_w * (1 - h_frac), bar_h], h_dim, 1);
            text_y += bar_h + bar_gap;

            // Read items once - used for both armor type and weapon labels.
            // STAT_ITEMS is queried as EV_INTEGER (csplat.qc:1841) since
            // runes/items2 are packed into the upper bits.
            int items = getplayerstat(pnum, STAT_ITEMS, EV_INTEGER);

            // Armor bar - two-tone, matching the autoid table in view.c:1831.
            // RA/YA/GA each have a dim/full color pair; remaining armor
            // draws full, depleted draws dim.
            float armor = getplayerstat(pnum, STAT_ARMOR, EV_FLOAT);
            float armor_max = 0;
            vector armor_dim  = '0 0 0';
            vector armor_full = '0 0 0';
            if (items & MM_IT_ARMOR3) {
                armor_max = 200;
                armor_dim  = MINIMAP_ARMOR_RA_DIM;
                armor_full = MINIMAP_ARMOR_RA_FULL;
            } else if (items & MM_IT_ARMOR2) {
                armor_max = 150;
                armor_dim  = MINIMAP_ARMOR_YA_DIM;
                armor_full = MINIMAP_ARMOR_YA_FULL;
            } else if (items & MM_IT_ARMOR1) {
                armor_max = 100;
                armor_dim  = MINIMAP_ARMOR_GA_DIM;
                armor_full = MINIMAP_ARMOR_GA_FULL;
            }
            if (armor_max > 0 && armor > 0) {
                vector apos = [bar_left, text_y, 0];
                float afrac = armor / armor_max;
                if (afrac > 1) afrac = 1;
                drawfill(apos, [bar_w, bar_h], '0 0 0', 0.6);
                drawfill(apos, [bar_w * afrac, bar_h], armor_full, 1);
                drawfill([bar_left + bar_w * afrac, text_y, 0],
                         [bar_w * (1 - afrac), bar_h], armor_dim, 1);
            }

            // Best-weapon indicator to the right of the bar stack, vertically
            // centered on the bar group. Priority: RLG (both) > RL > LG > GL.
            // For the combo, R uses the RL color and LG uses the LG color,
            // drawn as two adjacent strings.
            float has_rl = items & MM_IT_ROCKET_LAUNCHER;
            float has_lg = items & MM_IT_LIGHTNING;
            float has_gl = items & MM_IT_GRENADE_LAUNCHER;
            float wx  = bar_left + bar_w + 3;
            float wy  = bar_top + bar_group_h * 0.5 - weapon_size.y * 0.5;
            if (has_rl && has_lg) {
                vector wpos1 = [wx, wy, 0];
                drawstring(wpos1, "R", weapon_size, MinimapWeaponColor(MM_IT_ROCKET_LAUNCHER), 1, 0);
                vector wpos2 = [wx + stringwidth("R", 0, weapon_size), wy, 0];
                drawstring(wpos2, "LG", weapon_size, MinimapWeaponColor(MM_IT_LIGHTNING), 1, 0);
            } else if (has_rl) {
                drawstring([wx, wy, 0], "RL", weapon_size, MinimapWeaponColor(MM_IT_ROCKET_LAUNCHER), 1, 0);
            } else if (has_lg) {
                drawstring([wx, wy, 0], "LG", weapon_size, MinimapWeaponColor(MM_IT_LIGHTNING), 1, 0);
            } else if (has_gl) {
                drawstring([wx, wy, 0], "GL", weapon_size, MinimapWeaponColor(MM_IT_GRENADE_LAUNCHER), 1, 0);
            }
        }
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
    float ortho  = autocvar_qdw_minimap_ortho            > 0 ? autocvar_qdw_minimap_ortho            : minimap_ortho;
    float hoff   = autocvar_qdw_minimap_height_offset    > 0 ? autocvar_qdw_minimap_height_offset    : minimap_height;

    vector vmin, vsize;
    MinimapViewport(mode, vwidth, vheight, vmin, vsize);

    // VF_FOV in orthographic mode is "world units across the viewport".
    // Scale = world units per screen pixel. Computed to fit the world AABB
    // into the viewport along both axes (uniform scale, no stretching).
    //
    // Padding is shape-aware: square-ish maps (in any non-square viewport)
    // already get implicit slack on one axis from the aspect mismatch, so
    // we taper padding down toward small values. Elongated maps don't have
    // that extra slack and use the full 0.15.
    float largest  = (minimap_world_dx > minimap_world_dy) ? minimap_world_dx : minimap_world_dy;
    float smallest = (minimap_world_dx < minimap_world_dy) ? minimap_world_dx : minimap_world_dy;
    float aspect   = (smallest > 0) ? (largest / smallest) : 1;
    float pad_factor;
    if (aspect >= 2)
        pad_factor = 0.10;
    else
        pad_factor = 0.05 + (aspect - 1) * 0.05;  // square -> 0.05, 2:1 -> 0.10
    float pad     = largest * pad_factor;
    float need_x  = (minimap_world_dx + pad * 2) / vsize.x;
    float need_y  = (minimap_world_dy + pad * 2) / vsize.y;
    float scale   = (need_x > need_y) ? need_x : need_y;
    if (ortho > 0) {
        float ortho_scale = (ortho * 2) / vsize.x;
        if (ortho_scale > scale) scale = ortho_scale;
    }
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
    vector cam_origin = [center.x, center.y, center.z + hoff];
    addentities(MASK_ENGINE | MASK_LOCAL);
    MinimapSpawnOccludedDoppelgangers(cam_origin);
    renderscene();
    MinimapRemoveDoppelgangers();

    cvar_set("r_novis", ftos(prev_novis));
    cvar_set("scr_autoid", ftos(prev_autoid));
    cvar_set("scr_autoid_team", ftos(prev_autoid_team));
    cvar_set("r_fastsky", ftos(prev_fastsky));

    // Overlay players (project() reads the view state we just set).
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
    println("Minimap mode: %g  (0=off 1=pip 2=split 3=full)", autocvar_qdw_minimap_mode);
    println("Map:          %s", mapname);
    println("Loaded:       %g", minimap_loaded);
    println("Volumes:      %d", minimap_num_volumes);
    println("Center:       %v", minimap_center);
    println("Ortho:        %g", minimap_ortho);
    println("Height:       %g", minimap_height);
    println("Auto-cull:    known=%g, max_ceil_z=%g", minimap_auto_pickup_known, minimap_auto_pickup_max_z);
    for (int i = 0; i < minimap_num_volumes; i++) {
        println("  vol[%d]: mins=%v maxs=%v",
                (float)i, minimap_volumes[i].mins, minimap_volumes[i].maxs);
    }

    println("Probing networked entities for pickups...");
    int total = 0;
    int active = 0;
    int with_model = 0;
    int pickups = 0;
    float n = getentity(0, GE_MAXENTS);
    for (float j = 1; j < n; j++) {
        total++;
        float a = getentity(j, GE_ACTIVE);
        if (!a) continue;
        active++;
        float midx = getentity(j, GE_MODELINDEX);
        if (midx == 0) continue;
        with_model++;
        string mname = modelnameforindex(midx);
        if (MinimapIsPickupModel(mname)) {
            vector org = getentity(j, GE_ORIGIN);
            pickups++;
            println("  pickup ent %d '%s' at %v", (float)j, mname, org);
        }
    }
    println("Scanned %d slots: %d active, %d with model, %d pickups",
            (float)total, (float)active, (float)with_model, (float)pickups);
    return 1;
};

// Adds a description to a cvar without disturbing its current value.
// Reads the current value at call time (rather than via $-expansion at
// command-execution time) so the value can never be lost - even if the
// expansion context somehow lacks the cvar, we already captured its string.
void(string name, string desc) MinimapDescribeCvar =
{
    localcmd(sprintf("set %s \"%s\" // %s\n", name, cvar_string(name), desc));
};

void() MinimapRegisterDescriptions =
{
    MinimapDescribeCvar("qdw_minimap_mode",
        "Minimap display mode. 0=off, 1=picture-in-picture (top right), 2=split screen (right half), 3=full screen.");
    MinimapDescribeCvar("qdw_minimap_ortho",
        "Orthographic half-extent in Quake units per side. 0 = use value from .cull file or auto-derived from worldmodel bounds.");
    MinimapDescribeCvar("qdw_minimap_height_offset",
        "Camera Z offset above the reference center. 0 = use value from .cull file or auto-derived (highest geometry at center + 512 margin).");
    MinimapDescribeCvar("qdw_minimap_center_override",
        "Camera XY position and reference Z, as a vector. '0 0 0' = use value from .cull file or worldmodel midpoint.");
    MinimapDescribeCvar("qdw_minimap_player_radius",
        "Radius of the player marker ring on the minimap, in screen pixels.");
    MinimapDescribeCvar("qdw_minimap_player_alpha_occluded",
        "Alpha applied to a player model that the minimap camera can't see directly (drawn through walls/roofs via a doppelganger pass). Visible players use the engine's normal rendering. Default 0.8.");
    MinimapDescribeCvar("qdw_minimap_player_color_team",
        "Ring/triangle color for same-team players. '0 0 0' = default green.");
    MinimapDescribeCvar("qdw_minimap_player_color_enemy",
        "Ring/triangle color for opposing-team players. '0 0 0' = default red.");
    MinimapDescribeCvar("qdw_minimap_player_color_self",
        "Ring/triangle color for the local player.");
    MinimapDescribeCvar("qdw_minimap_player_label_name_length",
        "Fixed number of characters to show in each player label. Default 4. Set to 0 for auto (shortest prefix unique among all current players).");
    MinimapDescribeCvar("qdw_minimap_player_label_font_size",
        "Font size in pixels for the player name label above each marker. Default 6.");
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
