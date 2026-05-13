/*
 * Copyright (c) 2024 Daniel Svensson <dsvensson@gmail.com>
 *
 * Permission to use, copy, modify, and/or distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 */

/*
 * Top-level CSQC entry points. The actual feature code lives in:
 *   pip_camera.qc   - powerup-cam scheduling state
 *   pip_render.qc   - PiP overlay rendering
 *   xray.qc         - through-walls player silhouettes
 *   minimap.qc      - top-down map view
 *   score_overlay.qc - 1v1 / 2-team score header
 *   itemtimer.qc    - powerup spawn timers
 *   commands.qc     - console command handlers
 *   easing.qc       - small math helpers
 */

void(float apilevel, string enginename, float engineversion) CSQC_Init =
{
    registercommand("pip");
    registercommand("minimap", "Top-down minimap. Subcommands: reload, status, help");
    MinimapRegisterDescriptions();
};

void() CSQC_WorldLoaded =
{
    XrayInit();

    match_start_time = -1;
    ResetCamera();
    PipResetTimers(match_start_time);

    if (PipLoadItems()) {
        deltalisten("progs/quaddama.mdl", PipPowerupSpawnListener, RSES_NOLERP);
        deltalisten("progs/invulner.mdl", PipPowerupSpawnListener, RSES_NOLERP);
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

    PipResetTimers(match_start_time);
    SelectNextCamera();
};

// Render order for the frame:
//   1. Main player view (with engine HUD + xray pass)
//   2. PiP powerup overlay (if scheduled and pip enabled)
//   3. Minimap viewport
//   4. Score overlay (top-most UI)
void(float vwidth, float vheight, float notmenu) CSQC_UpdateView =
{
    vector main_min, main_size;
    float draw_main = MinimapMainViewport(vwidth, vheight, main_min, main_size);

    if (draw_main) {
        clearscene();
        setviewprop(VF_VIEWENTITY, 0);
        setviewprop(VF_MIN, main_min);
        setviewprop(VF_SIZE, main_size);
        addentities(MASK_ENGINE | MASK_VIEWMODEL);
        setviewprop(VF_DRAWENGINESBAR, 1);
        setviewprop(VF_DRAWCROSSHAIR, 1);
        renderscene();
        clearscene();

        setviewprop(VF_MIN, main_min);
        setviewprop(VF_SIZE, main_size);
        addentities(MASK_XRAY);
        setviewprop(VF_DRAWWORLD, 0);
        renderscene();
    }

    // SelectNextCamera early-returns when a camera is already in its
    // active window, so calling it unconditionally only advances the
    // schedule when the current pick has expired (or never existed).
    SelectNextCamera();

    if (draw_main && autocvar_pip_enabled) {
        PipRender(main_min, main_size, vwidth, vheight);
    }

    MinimapRender(vwidth, vheight);
    ScoreOverlayDraw('0 0 0', [vwidth, vheight, 0], vwidth, vheight);
};
