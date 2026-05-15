// SPDX-License-Identifier: 0BSD

// Top-level CSQC entry points. See progs.src for the file list.

void(float apilevel, string enginename, float engineversion) CSQC_Init =
{
    registercommand("powcam");
    registercommand("minimap", "Top-down minimap. Subcommands: reload, status, help");
    registercommand("minimap_editor_add",    "Add a minimap cull volume. Run once at the first corner, then again at the opposite corner. Requires minimap_editor 1; doesn't write the file (use minimap_editor_export).");
    registercommand("minimap_editor_remove", "Remove the currently highlighted cull volume (the closest one in range, shown brighter with a yellow accent border).");
    registercommand("minimap_editor_undo",   "Undo the last minimap_editor_add or minimap_editor_remove. Single level - no redo.");
    registercommand("minimap_editor_export",   "Write the current in-memory cull volumes to maps/<map>.cull. The only command that touches the file system.");
    MinimapRegisterDescriptions();
};

void() CSQC_WorldLoaded =
{
    XrayInit();

    match_start_time = -1;
    PowcamReset();
    ItemTimerResetAll(match_start_time);

    if (PowcamLoadItems()) {
        deltalisten("progs/quaddama.mdl", ItemTimerSpawnListener, RSES_NOLERP);
        deltalisten("progs/invulner.mdl", ItemTimerSpawnListener, RSES_NOLERP);
    }

    CullEditResetState();
    MinimapRegisterShaders();
    // MinimapLoad is deferred to the first MinimapRender frame so the
    // entity-scan narrowing pass can see pickups (the engine populates the
    // CSQC entity table after CSQC_WorldLoaded returns).
};


// Chain-of-responsibility input dispatcher. Each addon owns a handler that
// self-gates on its current state and returns 1 to consume the event; the
// first consumer wins. Returning 0 from CSQC_InputEvent passes the event
// through to the engine's normal binding/+attack pipeline.
//
// The web-app side (engine/web/ftejslib.js FTEC.preEvent) decides only
// whether to forward an event to FTE at all; once forwarded, dispatch is
// entirely FTE's responsibility.
float(float evtype, float scanx, float chary, float devid) CSQC_InputEvent =
{
    if (MinimapInputEvent(evtype, scanx, chary, devid)) return 1;
    return 0;
};

void() CSQC_ServerInfoChanged =
{
    Misc_OnServerInfoChanged();

    if (match_start_time >= 0.0f) {
        return;
    }

    string status = serverkey("status");
    if (!strcasecmp(status, "standby") || !strcasecmp(status, "countdown")) {
        return;
    }

    match_start_time = time;

    ItemTimerResetAll(match_start_time);
    PowcamSelectNext();
};

// Forward declarations (top-down ordering).
void(float seat, float seat_count, vector view_min, vector view_size,
     __out vector r_min, __out vector r_size) MainViewSeatRect;

// Render order for the frame:
//   1. Main player view, once per splitscreen seat (engine HUD + xray pass)
//   2. powcam powerup overlay (if scheduled and pip enabled)
//   3. Minimap viewport
//   4. Score overlay (top-most UI)
void(float vwidth, float vheight, float notmenu) CSQC_UpdateView =
{
    minimap_rect_t main_view;
    MinimapMainViewport(vwidth, vheight, main_view);
    float draw_main = (main_view.size != '0 0 0');

    if (draw_main) {
        // The engine normally subdivides the screen across cl.splitclients
        // inside V_RenderView, but when CSQC owns the frame that loop is
        // skipped - we have to tile the seats inside main_view ourselves.
        float seat_count = numclientseats;
        if (seat_count < 1) {
            seat_count = 1;
        }

        for (float seat = 0; seat < seat_count; seat += 1) {
            vector seat_min, seat_size;
            MainViewSeatRect(seat, seat_count, main_view.min, main_view.size,
                             seat_min, seat_size);

            clearscene();
            // VF_ACTIVESEAT switches which cl.playerview the engine uses
            // for origin/angles/stats; V_CalcRefdef fires from the setter,
            // so override VF_MIN/VF_SIZE afterwards.
            setviewprop(VF_ACTIVESEAT, seat);
            setviewprop(VF_VIEWENTITY, 0);
            setviewprop(VF_MIN, seat_min);
            setviewprop(VF_SIZE, seat_size);
            addentities(MASK_ENGINE | MASK_VIEWMODEL);
            setviewprop(VF_DRAWENGINESBAR, 1);
            setviewprop(VF_DRAWCROSSHAIR, 1);
            renderscene();
            // Cache the player's view origin while this seat's view is
            // active. The minimap pass below uses a high-altitude camera,
            // so reading VF_ORIGIN there would give the minimap camera
            // position instead of the player - which would break the
            // highlight and in-flight box. Capture it once here.
            CullEditCachePlayerOrigin();
            // Cull-volume wireframes use project() against the view we
            // just rendered. drawline/R_BeginPolygon are 2D so they would
            // happily paint outside the seat rect into the minimap split
            // area; scissor to the seat's viewport for the duration.
            drawsetcliparea(seat_min.x, seat_min.y, seat_size.x, seat_size.y);
            CullEditDrawWireframes();
            drawresetcliparea();
            clearscene();

            setviewprop(VF_MIN, seat_min);
            setviewprop(VF_SIZE, seat_size);
            addentities(MASK_XRAY);
            setviewprop(VF_DRAWWORLD, 0);
            renderscene();
        }

        // Restore primary seat so the overlays below (powcam, minimap,
        // score) read seat 0's view state.
        if (seat_count > 1) {
            setviewprop(VF_ACTIVESEAT, 0);
        }
    }

    // PowcamSelectNext early-returns when a camera is already in its
    // active window, so calling it unconditionally only advances the
    // schedule when the current pick has expired (or never existed).
    PowcamSelectNext();

    if (draw_main && autocvar_powcam_enabled) {
        PowcamRender(main_view.min, main_view.size, vwidth, vheight);
    }

    MinimapRender(vwidth, vheight);
};

// Per-seat sub-rect inside the main player view.
//
// 3 seats get a special L-layout (avoids the empty bottom-right cell a 2x2
// grid would leave):
//   seat 0: top-left quadrant (50% w, 50% h)
//   seat 1: bottom-left quadrant (50% w, 50% h)
//   seat 2: full right half (50% w, 100% h)
//
// 2 / 4+ seats fall back to a regular grid that mirrors the engine's
// SCR_VRectForPlayer (view.c): grow w*h until it covers seat_count, adding
// the axis whose per-cell aspect stays closer to 16:10.
void(float seat, float seat_count, vector view_min, vector view_size,
     __out vector r_min, __out vector r_size) MainViewSeatRect =
{
    if (seat_count <= 1) {
        r_min  = view_min;
        r_size = view_size;
        return;
    }

    int seat_i = (int)seat;

    if (seat_count == 3) {
        float half_w = view_size.x * 0.5;
        float half_h = view_size.y * 0.5;
        if (seat_i == 0) {
            r_min  = view_min;
            r_size = [half_w, half_h, 0];
        } else if (seat_i == 1) {
            r_min  = [view_min.x, view_min.y + half_h, 0];
            r_size = [half_w, half_h, 0];
        } else {
            r_min  = [view_min.x + half_w, view_min.y, 0];
            r_size = [half_w, view_size.y, 0];
        }
        return;
    }

    int w = 1, h = 1;
    while (w * h < seat_count) {
        if (view_size.x / (w * 16) > view_size.y / (h * 10)) {
            w += 1;
        } else {
            h += 1;
        }
    }

    float cell_w = view_size.x / w;
    float cell_h = view_size.y / h;
    int col = seat_i % w;
    int row = seat_i / w;
    r_min  = [view_min.x + col * cell_w, view_min.y + row * cell_h, 0];
    r_size = [cell_w, cell_h, 0];
};
