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

    clearscene();
    setviewprop(VF_DRAWWORLD,      1);
    setviewprop(VF_VIEWENTITY,     0);
    setviewprop(VF_DRAWENGINESBAR, 0);
    setviewprop(VF_DRAWCROSSHAIR,  0);
    setviewprop(VF_PERSPECTIVE,    0);
    setviewprop(VF_AFOV,           ortho);
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

float() MinimapCmdHelp =
{
    println("Minimap Commands");
    println(" * reload  - Reload maps/<mapname>.cull");
    println(" * status  - Print current state");
    println("Cvars:");
    println(" * minimap_mode             0=off 1=pip 2=split 3=full");
    println(" * minimap_ortho            half-extent in QU; 0 = use file value");
    println(" * minimap_height_offset    camera Z above center; 0 = use file value");
    println(" * minimap_center_override  vector; '0 0 0' = use file value");
    return 1;
};
