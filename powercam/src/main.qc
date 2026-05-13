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

// Render order for the frame:
//   1. Main player view (with engine HUD + xray pass)
//   2. powcam powerup overlay (if scheduled and pip enabled)
//   3. Minimap viewport
//   4. Score overlay (top-most UI)
void(float vwidth, float vheight, float notmenu) CSQC_UpdateView =
{
    minimap_rect_t main_view;
    MinimapMainViewport(vwidth, vheight, main_view);
    float draw_main = (main_view.size != '0 0 0');

    if (draw_main) {
        clearscene();
        setviewprop(VF_VIEWENTITY, 0);
        setviewprop(VF_MIN, main_view.min);
        setviewprop(VF_SIZE, main_view.size);
        addentities(MASK_ENGINE | MASK_VIEWMODEL);
        setviewprop(VF_DRAWENGINESBAR, 1);
        setviewprop(VF_DRAWCROSSHAIR, 1);
        renderscene();
        clearscene();

        setviewprop(VF_MIN, main_view.min);
        setviewprop(VF_SIZE, main_view.size);
        addentities(MASK_XRAY);
        setviewprop(VF_DRAWWORLD, 0);
        renderscene();
    }

    // PowcamSelectNext early-returns when a camera is already in its
    // active window, so calling it unconditionally only advances the
    // schedule when the current pick has expired (or never existed).
    PowcamSelectNext();

    if (draw_main && autocvar_qdw_powcam_enabled) {
        PowcamRender(main_view.min, main_view.size, vwidth, vheight);
    }

    MinimapRender(vwidth, vheight);
    ScoreOverlayDraw('0 0 0', [vwidth, vheight, 0], vwidth, vheight);
};
