/*
 * Powcam (powerup-cam) scheduling: tracks which powerup spawn the powcam
 * should be focused on, and the start/end/transition timestamps around it.
 * The actual rendering is in powcam_render.qc; this file just maintains the
 * schedule state.
 */

#define POWCAM_START_RESET 9999999
#define POWCAM_END_RESET   9999999

var float match_start_time = -1;
var int   powcam_index = -1;
var float powcam_intro = 4.0;
var float powcam_outro = 2.5;
var float powcam_transition = 1.0;

var float powcam_start = POWCAM_START_RESET;
var float powcam_start_transition = POWCAM_START_RESET;
var float powcam_end = POWCAM_END_RESET;
var float powcam_end_transition = POWCAM_END_RESET;

var vector powcam_bg_color = '1 1 1';
var string powcam_item_name = "none";

var float  autocvar_qdw_debug = 0;
var float  autocvar_qdw_powcam_enabled = 1;
var float  autocvar_qdw_powcam_intro = 5.0;
var float  autocvar_qdw_powcam_outro = 3.5;
var float  autocvar_qdw_powcam_transition = 0.8;
var vector autocvar_qdw_powcam_bg_quad_color = '0.2 0.2 0.5';
var vector autocvar_qdw_powcam_bg_pent_color = '0.5 0.2 0.2';

void() ResetCamera =
{
    powcam_start = POWCAM_START_RESET;
    powcam_start_transition = POWCAM_START_RESET;
    powcam_end = POWCAM_END_RESET;
    powcam_end_transition = POWCAM_END_RESET;
    powcam_index = -1;
};

void() SelectNextCamera =
{
    if (match_start_time == -1) {
        return;
    }

    if (time >= powcam_start && time < powcam_end) {
        return;
    }

    itemtimer_t *timers = PowcamGetTimers();

    itemtype_t candidate_type = IT_NONE;
    float candidate_respawn = POWCAM_START_RESET;
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
        powcam_intro = autocvar_qdw_powcam_intro;
        powcam_outro = autocvar_qdw_powcam_outro;
        powcam_transition = autocvar_qdw_powcam_transition;

        powcam_index = candidate_index;
        powcam_start = max(match_start_time, candidate_respawn - powcam_intro);
        powcam_start_transition = powcam_start + powcam_transition;
        powcam_end = POWCAM_END_RESET;
        powcam_end_transition = POWCAM_END_RESET;

        switch (candidate_type) {
        case IT_QUAD:
            powcam_bg_color = autocvar_qdw_powcam_bg_quad_color;
            powcam_item_name = "Quad";
            break;
        case IT_PENT:
            powcam_bg_color = autocvar_qdw_powcam_bg_pent_color;
            powcam_item_name = "Pent";
            break;
        default:
            powcam_bg_color = '1 1 1';
            break;
        }
    }
};
