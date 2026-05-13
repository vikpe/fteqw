/*
 * Picture-in-Picture camera scheduling: tracks which powerup spawn the PiP
 * should be focused on, and the start/end/transition timestamps around it.
 * The actual rendering is in pip_render.qc; this file just maintains the
 * schedule state.
 */

#define CAMERA_START_RESET 9999999
#define CAMERA_END_RESET   9999999

var float match_start_time = -1;
var int   camera_index = -1;
var float camera_intro = 4.0;
var float camera_outro = 2.5;
var float camera_transition = 1.0;

var float camera_start = CAMERA_START_RESET;
var float camera_start_transition = CAMERA_START_RESET;
var float camera_end = CAMERA_END_RESET;
var float camera_end_transition = CAMERA_END_RESET;

var vector camera_bg_color = '1 1 1';
var string camera_item_name = "none";

var float  autocvar_pip_debug = 0;
var float  autocvar_pip_enabled = 1;
var float  autocvar_pip_camera_intro = 5.0;
var float  autocvar_pip_camera_outro = 3.5;
var float  autocvar_pip_camera_transition = 0.8;
var vector autocvar_pip_bg_quad_color = '0.2 0.2 0.5';
var vector autocvar_pip_bg_pent_color = '0.5 0.2 0.2';

void() ResetCamera =
{
    camera_start = CAMERA_START_RESET;
    camera_start_transition = CAMERA_START_RESET;
    camera_end = CAMERA_END_RESET;
    camera_end_transition = CAMERA_END_RESET;
    camera_index = -1;
};

void() SelectNextCamera =
{
    if (match_start_time == -1) {
        return;
    }

    if (time >= camera_start && time < camera_end) {
        return;
    }

    itemtimer_t *timers = PipGetTimers();

    itemtype_t candidate_type = IT_NONE;
    float candidate_respawn = CAMERA_START_RESET;
    int   candidate_index = -1;

    for (int i = 0; i < MAX_POWERUPS; i++) {
        itemtimer_t *timer = &timers[i];
        item_t *item = timer->item;
        if (!item) {
            continue;
        }

        // Prefer earliest respawn; pent wins ties.
        if (timer->respawn < candidate_respawn ||
            (item->type == IT_PENT && timer->respawn == candidate_respawn)) {
            candidate_type = item->type;
            candidate_respawn = timer->respawn;
            candidate_index = i;
        }
    }
    if (candidate_index != -1) {
        // Reload any cvar changes.
        camera_intro = autocvar_pip_camera_intro;
        camera_outro = autocvar_pip_camera_outro;
        camera_transition = autocvar_pip_camera_transition;

        camera_index = candidate_index;
        camera_start = max(match_start_time, candidate_respawn - camera_intro);
        camera_start_transition = camera_start + camera_transition;
        camera_end = CAMERA_END_RESET;
        camera_end_transition = CAMERA_END_RESET;

        switch (candidate_type) {
        case IT_QUAD:
            camera_bg_color = autocvar_pip_bg_quad_color;
            camera_item_name = "Quad";
            break;
        case IT_PENT:
            camera_bg_color = autocvar_pip_bg_pent_color;
            camera_item_name = "Pent";
            break;
        default:
            camera_bg_color = '1 1 1';
            break;
        }
    }
};
