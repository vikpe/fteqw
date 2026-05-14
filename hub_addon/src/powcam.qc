// SPDX-License-Identifier: 0BSD

/*
 * Powcam (powerup-cam) scheduling: tracks which powerup spawn the powcam
 * should be focused on, and the start/end/transition timestamps around it.
 * The actual rendering is in powcam_render.qc; this file just maintains the
 * schedule state.
 */

// Sentinel value for unscheduled powcam timestamps. Chosen high enough that
// `time < powcam.start` and `time >= powcam.end` both read as "no window".
#define POWCAM_TIME_RESET 9999999

// Wall-clock time (engine `time`) when the current match started, or -1 if
// no match has started yet. Set in main.qc:CSQC_ServerInfoChanged on the
// first non-standby/non-countdown serverinfo, and consumed by the powcam
// scheduler as the earliest legal camera-start timestamp. Shared with
// main.qc so its lifecycle hooks can detect the "match running" state.
var float match_start_time = -1;

// Currently scheduled powcam window. All fields move together: written
// atomically by PowcamSelectNext, cleared by PowcamReset, consumed by
// PowcamRender. `index` is -1 and the four timestamps are POWCAM_TIME_RESET
// when no camera is scheduled.
typedef struct {
    int    index;               // index into item_timers[] (-1 = unscheduled)
    float  intro_seconds;       // snapshot of autocvar_powcam_intro
    float  outro_seconds;       // snapshot of autocvar_powcam_outro
    float  transition_seconds;  // snapshot of autocvar_powcam_transition
    float  start;               // render begins
    float  start_transition;    // slide-in completes
    float  end_transition;      // slide-out begins
    float  end;                 // render ends
    vector bg_color;            // frame fill for this window
    string item_name;           // caption label ("Quad" / "Pent")
} powcam_schedule_t;

var powcam_schedule_t powcam;

// Cvars (auto-prefixed accessors). Read at PowcamSelectNext time.
var float  autocvar_powcam_enabled         = 1;
var float  autocvar_powcam_intro           = 5.0;
var float  autocvar_powcam_outro           = 3.5;
var float  autocvar_powcam_transition      = 0.8;
var vector autocvar_powcam_bg_quad_color   = '0.2 0.2 0.5';
var vector autocvar_powcam_bg_pent_color   = '0.5 0.2 0.2';

void() PowcamReset =
{
    powcam.index              = -1;
    powcam.intro_seconds      = 4.0;
    powcam.outro_seconds      = 2.5;
    powcam.transition_seconds = 1.0;
    powcam.start              = POWCAM_TIME_RESET;
    powcam.start_transition   = POWCAM_TIME_RESET;
    powcam.end_transition     = POWCAM_TIME_RESET;
    powcam.end                = POWCAM_TIME_RESET;
    powcam.bg_color           = '1 1 1';
    powcam.item_name          = "none";
};

void() PowcamSelectNext =
{
    // Powcam is demo-only: outside demo playback we never load camera
    // items (powcam_active_items is nil) and never want to schedule.
    if (!isdemo()) {
        return;
    }

    if (match_start_time == -1) {
        return;
    }

    if (time >= powcam.start && time < powcam.end) {
        return;
    }

    item_timer_t *timers = ItemTimerGetAll();

    itemtype_t candidate_type    = IT_NONE;
    float      candidate_respawn = POWCAM_TIME_RESET;
    int        candidate_index   = -1;

    for (int i = 0; i < MAX_POWERUPS; i++) {
        item_timer_t *timer = &timers[i];
        powcam_item_t *item = timer->item;
        if (!item) {
            continue;
        }

        // Prefer earliest respawn; pent wins ties.
        if (timer->respawn < candidate_respawn ||
            (item->type == IT_PENT && timer->respawn == candidate_respawn)) {
            candidate_type    = item->type;
            candidate_respawn = timer->respawn;
            candidate_index   = i;
        }
    }
    if (candidate_index != -1) {
        // Reload any cvar changes.
        powcam.intro_seconds      = autocvar_powcam_intro;
        powcam.outro_seconds      = autocvar_powcam_outro;
        powcam.transition_seconds = autocvar_powcam_transition;

        powcam.index            = candidate_index;
        powcam.start            = max(match_start_time, candidate_respawn - powcam.intro_seconds);
        powcam.start_transition = powcam.start + powcam.transition_seconds;
        powcam.end              = POWCAM_TIME_RESET;
        powcam.end_transition   = POWCAM_TIME_RESET;

        switch (candidate_type) {
        case IT_QUAD:
            powcam.bg_color  = autocvar_powcam_bg_quad_color;
            powcam.item_name = "Quad";
            break;
        case IT_PENT:
            powcam.bg_color  = autocvar_powcam_bg_pent_color;
            powcam.item_name = "Pent";
            break;
        default:
            powcam.bg_color = '1 1 1';
            break;
        }
    }
};
