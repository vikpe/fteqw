// SPDX-License-Identifier: 0BSD

// Player-view gestures for mouse and touch: tap, double tap, long press, swipe.
// Runs after the UI handlers in CSQC_InputEvent, so presses they claim never start one.

var float autocvar_gestures             = 1;
var float autocvar_gestures_mouse_swipe = 0;  // touch swipes always count; mouse drags only when set

var float gesture_devid = -1;  // pointer being followed, -1 = none
vector    gesture_start_pos;
vector    gesture_end_pos;
float     gesture_start_time;
float     gesture_is_touch;
float     gesture_has_moved;
float     gesture_is_long_press;
float     gesture_has_pending_tap;
float     gesture_pending_tap_time;

void()           GestureCancel;
void(vector pos) GestureTap;
void(vector pos) GestureDoubleTap;
void()           GestureSingleTap;
float()          GestureIsSwipe;

#define GESTURE_TAP_SLOP_PX         12
#define GESTURE_LONG_PRESS_SECONDS  0.4
#define GESTURE_DOUBLE_TAP_SECONDS  0.3

// Per frame: starts a long press once a still press is held long enough,
// and resolves a pending tap as a single tap once no second tap followed.
void() GesturesFrame =
{
    if (gesture_devid >= 0) {
        if (!gesture_has_moved && !gesture_is_long_press
            && cltime - gesture_start_time >= GESTURE_LONG_PRESS_SECONDS) {
            gesture_is_long_press = 1;
            localcmd("+showscores\n");
        }
        return;
    }
    if (gesture_has_pending_tap && cltime - gesture_pending_tap_time > GESTURE_DOUBLE_TAP_SECONDS) {
        gesture_has_pending_tap = 0;
        GestureSingleTap();
    }
};

float(float evtype, float scanx, float chary, float devid) GesturesInputEvent =
{
    if (!autocvar_gestures) return 0;
    // Aim mode (pointer locked): clicks belong to the engine.
    if (mouselock_is_active) {
        GestureCancel();
        return 0;
    }

    if (evtype == IE_MOUSEABS) {
        if (devid == gesture_devid) {
            gesture_end_pos = [scanx, chary, 0];
            if (vlen(gesture_end_pos - gesture_start_pos) > GESTURE_TAP_SLOP_PX) {
                gesture_has_moved = 1;
            }
        }
        return 0;
    }
    if (scanx != K_MOUSE1 && scanx != K_TOUCH) return 0;

    if (evtype == IE_KEYDOWN) {
        // A second pointer (pinch, two-finger tap) cancels the gesture.
        if (gesture_devid >= 0) {
            GestureCancel();
            return 1;
        }
        // The engine moves the cursor to the finger on touch-down.
        gesture_devid         = devid;
        gesture_start_pos     = getmousepos();
        gesture_end_pos       = gesture_start_pos;
        gesture_start_time    = cltime;
        gesture_is_touch      = scanx == K_TOUCH;
        gesture_has_moved     = 0;
        gesture_is_long_press = 0;
        return 1;
    }

    if (evtype != IE_KEYUP || devid != gesture_devid) return 0;
    gesture_devid = -1;

    if (gesture_is_long_press) {
        gesture_is_long_press = 0;
        localcmd("-showscores\n");
        return 1;
    }
    if ((gesture_is_touch || autocvar_gestures_mouse_swipe) && GestureIsSwipe()) {
        TrackParticipantByDelta(gesture_end_pos.x > gesture_start_pos.x ? 1 : -1);
        return 1;
    }
    if (!gesture_has_moved) {
        GestureTap(gesture_start_pos);
    }
    return 1;
};

// Drops the followed press, releasing the scoreboard if a long press held it.
void() GestureCancel =
{
    if (gesture_is_long_press) {
        localcmd("-showscores\n");
    }
    gesture_devid         = -1;
    gesture_is_long_press = 0;
};

// A second tap within GESTURE_DOUBLE_TAP_SECONDS makes a double tap; otherwise
// GesturesFrame resolves the tap as a single tap.
void(vector pos) GestureTap =
{
    if (gesture_has_pending_tap && cltime - gesture_pending_tap_time <= GESTURE_DOUBLE_TAP_SECONDS) {
        gesture_has_pending_tap = 0;
        GestureDoubleTap(pos);
        return;
    }
    if (gesture_has_pending_tap) {
        GestureSingleTap();
    }
    gesture_has_pending_tap  = 1;
    gesture_pending_tap_time = cltime;
};

#define GESTURE_SEEK_ZONE_RATIO  0.25
#define GESTURE_SEEK_SECONDS     10

// Demo: left / right quarter seeks back / forward, center toggles fullscreen.
// QTV and live: fullscreen anywhere.
void(vector pos) GestureDoubleTap =
{
    if (serverkeyfloat("demo_is_seekable") > 0) {
        vector screen_size = getviewprop(VF_SCREENVSIZE);
        float  x_ratio     = pos.x / screen_size.x;
        if (x_ratio < GESTURE_SEEK_ZONE_RATIO) {
            localcmd(sprintf("demo_jump -%d\n", GESTURE_SEEK_SECONDS));
            return;
        }
        if (x_ratio > 1 - GESTURE_SEEK_ZONE_RATIO) {
            localcmd(sprintf("demo_jump +%d\n", GESTURE_SEEK_SECONDS));
            return;
        }
    }
    localcmd("hub_request fullscreen\n");
};

// Demo: toggle play / pause. Nothing for QTV and live.
void() GestureSingleTap =
{
    if (serverkeyfloat("demo_is_seekable") > 0) {
        localcmd("demo_toggle_pause\n");
    }
};

#define GESTURE_SWIPE_MAX_SECONDS      0.5
#define GESTURE_SWIPE_MIN_WIDTH_RATIO  0.08  // of the screen width
#define GESTURE_SWIPE_MIN_PX           40

// Quick, mostly horizontal movement of at least ~8% of the screen width.
float() GestureIsSwipe =
{
    if (cltime - gesture_start_time > GESTURE_SWIPE_MAX_SECONDS) return 0;

    vector screen_size = getviewprop(VF_SCREENVSIZE);
    float  delta_x     = gesture_end_pos.x - gesture_start_pos.x;
    float  delta_y     = gesture_end_pos.y - gesture_start_pos.y;
    float  min_dist    = max(GESTURE_SWIPE_MIN_PX, screen_size.x * GESTURE_SWIPE_MIN_WIDTH_RATIO);
    return fabs(delta_x) >= min_dist && fabs(delta_x) >= 2 * fabs(delta_y);
};
