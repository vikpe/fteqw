// SPDX-License-Identifier: 0BSD

// Top-level CSQC entry points. See progs.src for the file list.

void(float apilevel, string enginename, float engineversion) CSQC_Init =
{
    registercommand("powcam");
    registercommand("minimap", "Top-down minimap. Subcommands: reload, status, help");
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

    MinimapRegisterShaders();
    MinimapLoad();
};

void() CSQC_ServerInfoChanged =
{
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
    ScoreOverlayDraw([vwidth, vheight, 0], vwidth);
};

// Per-seat sub-rect inside the main player view. Mirrors the engine's
// SCR_VRectForPlayer (view.c): grow a w*h grid until it covers seat_count,
// adding the axis whose per-cell aspect stays closer to 16:10.
void(float seat, float seat_count, vector view_min, vector view_size,
     __out vector r_min, __out vector r_size) MainViewSeatRect =
{
    if (seat_count <= 1) {
        r_min  = view_min;
        r_size = view_size;
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
    int seat_i = (int)seat;
    int col = seat_i % w;
    int row = seat_i / w;
    r_min  = [view_min.x + col * cell_w, view_min.y + row * cell_h, 0];
    r_size = [cell_w, cell_h, 0];
};
