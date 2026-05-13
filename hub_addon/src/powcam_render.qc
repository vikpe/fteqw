// SPDX-License-Identifier: 0BSD

/*
 * Powcam overlay rendering. Drawn over the player view rect:
 * a small 3D scene from the powerup camera, plus a colored background
 * frame and a one-line caption underneath. Slide animation at the start
 * and end of the scheduled window is driven by EaseInExpo.
 *
 * Returns 1 if a powcam was rendered this frame, 0 otherwise. The main
 * lifecycle (CSQC_UpdateView) uses this to decide whether to also tick
 * the scheduler forward.
 */

float(vector main_min, vector main_size, float vwidth, float vheight) PowcamRender =
{
    if (time < powcam.start) {
        return 0;
    }

    item_timer_t *timer = ItemTimerGet(powcam.index);
    if (!timer) {
        return 0;
    }
    powcam_item_t *item = timer->item;

    if (powcam.end == POWCAM_TIME_RESET && timer->took > powcam.start) {
        powcam.end = timer->took + powcam.outro_seconds;
        powcam.end_transition = powcam.end - powcam.transition_seconds;
    }

    vector font_size = '8 8 0';

    // Anchor powcam to the player view rect so it stays over the player camera
    // (e.g. left half in split mode), not over the minimap.
    float aspect_ratio = vheight / vwidth;
    float width = main_size.x / 4.0;
    float height = width * aspect_ratio;

    float margin = width / 10.0;
    float x_offset = main_min.x + main_size.x - margin - width;

    // In split mode the player viewport occupies only the left half and the
    // score overlay (centered on the full screen) sits over its top edge -
    // shift the powcam down by the overlay's reserved height to avoid
    // overlapping. In the other modes the powcam sits to the right of the
    // overlay and doesn't need the offset.
    float y_anchor = main_min.y;
    if (autocvar_minimap_mode == MINIMAP_SPLIT) {
        y_anchor += ScoreOverlayReservedHeight(main_size);
    }

    float delta = 0.0;
    float slide_offset = 0;

    if (time >= powcam.start && time < powcam.start_transition) {
        delta = EaseInExpo((powcam.start_transition - time) / powcam.transition_seconds);
    }
    else if (time >= powcam.end_transition) {
        delta = 1.0 - EaseInExpo((powcam.end - time) / powcam.transition_seconds);
    }

    if (delta > 0.0) {
        // Slide powcam vertically (off the top of the player viewport). Sliding
        // horizontally crosses into the minimap area in split mode and ends
        // up rendering over it, since the powcam renderscene can't be clipped
        // by a 2D scissor.
        slide_offset = (height + margin) * delta;
    }

    // Item type colored background.
    float bg_offset_x = x_offset - margin / 4;
    float bg_offset_y = y_anchor + margin - margin / 4 - slide_offset;
    float bg_width = width + margin / 2;
    float bg_height = height + margin / 2 + font_size.y;
    float bg_alpha = 0.5;
    drawfill([bg_offset_x, bg_offset_y], [bg_width, bg_height], powcam.bg_color, bg_alpha);

    // Black contrasting inner border.
    float border_offset_x = x_offset - margin / 16;
    float border_offset_y = y_anchor + margin - margin / 16 - slide_offset;
    float border_width = width + margin / 8;
    float border_height = height + margin / 8;
    vector border_color = [0, 0, 0];
    float border_alpha = 0.4;
    drawfill([border_offset_x, border_offset_y],
             [border_width, border_height], border_color, border_alpha);

    // No-op to reset blending mode, bug in FTE.
    drawfill([0, 0], [0, 0], [1, 1, 1], 1);

    clearscene();
    setviewprop(VF_DRAWWORLD, 1);
    setviewprop(VF_VIEWENTITY, 1);
    setviewprop(VF_DRAWENGINESBAR, 0);
    setviewprop(VF_DRAWCROSSHAIR, 0);
    setviewprop(VF_ORIGIN, item->camera->origin);
    setviewprop(VF_MIN_X, x_offset);
    setviewprop(VF_MIN_Y, y_anchor + margin - slide_offset);
    setviewprop(VF_SIZE_X, width);
    setviewprop(VF_SIZE_Y, height);
    setviewprop(VF_ANGLES, item->camera->angles);
    setviewprop(VF_FOV, '110 0 0');
    addentities(MASK_ENGINE | MASK_LOCAL);

    cvar_set("scr_autoid_armor", "0");
    cvar_set("scr_autoid_health", "0");
    cvar_set("scr_autoid_weapon", "0");

    renderscene();

    cvar_set("scr_autoid_armor", "1");
    cvar_set("scr_autoid_health", "1");
    cvar_set("scr_autoid_weapon", "1");

    string text;
    if (time < timer->respawn && time > (timer->respawn - powcam.intro_seconds)) {
        text = sprintf("%s in %i sec", powcam.item_name, (int)ceil(timer->respawn - time));
    } else if (time > timer->took && timer->took > powcam.start) {
        string name = getplayerkeyvalue(timer->playernum - 1, INFOKEY_P_NAME);
        text = sprintf("%s's %s", name, powcam.item_name);
    } else {
        text = sprintf("%s spawned!", powcam.item_name);
    }

    float txt_offset_x = x_offset;
    float txt_offset_y = y_anchor + margin + height + margin / 8 - slide_offset;
    vector txt_color = [0.7, 0.7, 0.7];
    float txt_alpha = 1;
    drawsetcliparea(txt_offset_x, txt_offset_y, width, font_size.y);
    drawstring([txt_offset_x, txt_offset_y], text, font_size, txt_color, txt_alpha, 0);
    drawresetcliparea();

    if (time > powcam.end) {
        PowcamReset();
        PowcamSelectNext();
    }
    return 1;
};
