// SPDX-License-Identifier: 0BSD

/*
 * Per-seat mouselock prompt.
 *
 * CSQC_Init enables absolute-mouse mode (setcursormode TRUE), which the
 * web engine maps to "release pointer lock". The browser only re-grabs
 * the pointer when Module.FTE_RequestPointerLock fires from a user
 * gesture handler. This addon paints a small label per splitscreen seat
 * whenever the cursor hovers inside that seat's viewport rect, and a
 * left-click on the label:
 *   - flips CSQC out of cursor mode so the engine's per-frame
 *     emscriptenfte_updatepointerlock poll stops actively releasing
 *     the lock (gl_vidweb.c:732), and
 *   - issues the `requestpointerlock` engine command (registered in
 *     engine/web/sys_web.c) which forwards to the JS bridge.
 *
 * State tracking:
 *   mouselock_is_active = 1 while we believe the browser holds the
 *   lock. Flipped on by the click handler. Flipped off when an
 *   IE_MOUSEABS event arrives - the web engine only emits absolute
 *   mouse events while pointer lock is released, so the first
 *   IE_MOUSEABS after lock signals release (e.g. user hit Escape).
 *   On release we restore cursor mode so QC overlays receive clicks.
 *
 * Hit-test order (CSQC_InputEvent in main.qc) puts this first so a
 * click that lands on the button cannot fall through to player_info
 * or the minimap teleport handler.
 */

#define MOUSELOCK_MAX_SEATS 4

// Web app overlays a demo time slider along the bottom of the FTE viewport
// during demo playback; reserve extra vertical margin so the button clears
// it. Mirrors DEMO_TIMESLIDER_HEIGHT_PX in player_info.qc.
#define DEMO_TIMESLIDER_HEIGHT_PX 32

// Cvars.
// mouselock                 0/1   - master enable
// mouselock_font_size       px    - label font height; the button auto-fits
//                                   around this value with mouselock_padding
// mouselock_padding         "X Y" - inner padding inside the button (px on
//                                   each side; Y adds vertical breathing room
//                                   above/below the label)
// mouselock_margin          "X Y" - inset from the seat's bottom-left corner
// mouselock_radius          px    - corner radius for the rounded fill
// mouselock_idle_color      "R G B A" (RGB 0..255, A 0..1) - non-hover fill
// mouselock_hover_color     "R G B A" - fill while cursor is over the button
// mouselock_text_color      "R G B A" - label color
// mouselock_label           string - text inside the button
var float  autocvar_mouselock              = 1;
// Web-app-driven flag (set via Module.setCanvasHover in bindings.cpp). When
// the cursor isn't over the FTE canvas the embedding page flips this to 0
// and the addon hides itself, matching the time-slider's auto-hide rule.
// Defaults to 1 so behavior is correct even when the web app doesn't wire
// the signal yet.
var float  autocvar_canvas_hover           = 1;
// Web-app-driven flag (set via Module.setCanvasFocus). Gates the Tab/Space
// pass-through in MouseLockSwallowMissed - when the user is typing into a
// non-FTE input (chat box, demo URL field, etc.) the page should set this
// to 0 so a Space doesn't trigger scoreboard/+jump as a side effect.
// Defaults to 1 so behavior is correct without explicit wiring.
var float  autocvar_canvas_focus           = 1;
var float  autocvar_mouselock_font_size    = 10;
var vector autocvar_mouselock_padding      = '5 5 0';
var vector autocvar_mouselock_margin       = '16 16 0';
var float  autocvar_mouselock_radius       = 3;
var string autocvar_mouselock_idle_color   = "30 80 160 0.9";
var string autocvar_mouselock_hover_color  = "15 45 110 0.95";
var string autocvar_mouselock_text_color   = "255 255 255 1";
var string autocvar_mouselock_label        = "CAPTURE MOUSE";

// Per-seat hit rect populated by MouseLockDraw, consumed by
// MouseLockInputEvent. Cleared each frame by MouseLockBeginFrame.
typedef struct {
    vector pos;
    vector size;
    float  is_valid;
} mouselock_hit_t;
var mouselock_hit_t mouselock_hits[MOUSELOCK_MAX_SEATS];

// Sticky lock-state flag. See file header for the IE_MOUSEABS-based
// release detection.
var float mouselock_is_active = 0;

// Forward declarations (top-down ordering).
void(string spec, __out vector rgb, __out float alpha) ML_ParseColor;
void(vector view_min, vector view_size, string label,
     __out vector pos, __out vector size, __out vector font_size) ML_ButtonRect;
float(vector pos, vector size, vector cursor) ML_PointInRect;

// ----- entry points ---------------------------------------------------------

void() MouseLockBeginFrame =
{
    for (int seat = 0; seat < MOUSELOCK_MAX_SEATS; seat++) {
        mouselock_hits[seat].is_valid = 0;
    }
};

// Drawn once per splitscreen seat from CSQC_UpdateView. Visibility rule
// mirrors the web app's demo time slider: shown whenever the cursor is
// anywhere on the FTE canvas (autocvar_canvas_hover), hidden otherwise.
// Also hidden while the mouse lock is engaged - the cursor's gone and a
// per-seat AIM button is moot during gameplay.
void(float seat, vector view_min, vector view_size) MouseLockDraw =
{
    if (!autocvar_mouselock) return;
    if (mouselock_is_active) return;
    if (!autocvar_canvas_hover) return;
    if (view_size.x <= 0 || view_size.y <= 0) return;
    if (seat < 0 || seat >= MOUSELOCK_MAX_SEATS) return;

    vector cursor = getmousepos();

    string label = autocvar_mouselock_label;
    if (label == "") return;

    vector button_pos, button_size, font_size;
    ML_ButtonRect(view_min, view_size, label, button_pos, button_size, font_size);

    mouselock_hits[(int)seat].pos      = button_pos;
    mouselock_hits[(int)seat].size     = button_size;
    mouselock_hits[(int)seat].is_valid = 1;

    float is_hover = ML_PointInRect(button_pos, button_size, cursor);

    vector fill_rgb;
    float  fill_alpha;
    ML_ParseColor(is_hover ? autocvar_mouselock_hover_color
                           : autocvar_mouselock_idle_color,
                  fill_rgb, fill_alpha);
    float radius = autocvar_mouselock_radius;
    if (radius < 0) radius = 0;
    HubDrawRoundedRect(button_pos, button_size, radius, RR_ALL, fill_rgb, fill_alpha);

    vector text_rgb;
    float  text_alpha;
    ML_ParseColor(autocvar_mouselock_text_color, text_rgb, text_alpha);
    float  text_w   = stringwidth(label, 0, font_size);
    vector text_pos = [button_pos.x + (button_size.x - text_w) * 0.5,
                       button_pos.y + (button_size.y - font_size.y) * 0.5, 0];
    drawstring(text_pos, label, font_size, text_rgb, text_alpha, 0);
};

// Swallow input events while the cursor is visible (we don't hold the
// lock). Called LAST in the CSQC_InputEvent chain, after every addon's
// hit-test, so a UI-mode click that hit nothing doesn't fall through to
// the engine as +attack and a keystroke doesn't fire WASD/+jump on a
// player view the user isn't currently controlling.
//
// Consumes IE_KEYDOWN / IE_KEYUP - mouse buttons (K_MOUSE1..K_MOUSE10),
// the wheel (K_MWHEELUP/DOWN), and most keyboard scan codes. K_TAB and
// K_SPACE are whitelisted through ONLY when canvas_focus is set, so a
// Space pressed while typing into an external input (chat box, demo URL
// field) doesn't slip past as +jump / scoreboard. Mouse motion events
// (IE_MOUSEABS / IE_MOUSEDELTA) pass through so MouseLockInputEvent's
// release detection keeps working.
float(float evtype, float scanx) MouseLockSwallowMissed =
{
    if (!autocvar_mouselock) return 0;
    if (mouselock_is_active) return 0;
    if (evtype != IE_KEYDOWN && evtype != IE_KEYUP) return 0;
    if (autocvar_canvas_focus && (scanx == K_TAB || scanx == K_SPACE)) return 0;
    return 1;
};

// Routed from CSQC_InputEvent (must be first in the chain). Returns 1
// (consume) when a left click lands on any seat's button rect; 0
// (passthrough) otherwise.
float(float evtype, float scanx, float chary, float devid) MouseLockInputEvent =
{
    if (!autocvar_mouselock) return 0;

    // Absolute-mouse events only arrive while pointer lock is released.
    // The first one after we engaged lock signals release (user hit
    // Escape, alt-tabbed, etc.) - flip our state and restore cursor
    // mode so PlayerInfo / Minimap clicks work again.
    if (evtype == IE_MOUSEABS) {
        if (mouselock_is_active) {
            mouselock_is_active = 0;
            setcursormode(TRUE, "");
        }
        return 0;
    }

    if (evtype != IE_KEYDOWN || scanx != K_MOUSE1) return 0;

    // While we hold the lock, mouse clicks are gameplay input. Don't
    // hit-test against the cached button rect - the cursor's frozen at
    // its pre-lock position (likely still on the button), so the test
    // would consume every +attack.
    if (mouselock_is_active) return 0;

    vector cursor = getmousepos();
    for (int seat = 0; seat < MOUSELOCK_MAX_SEATS; seat++) {
        if (!mouselock_hits[seat].is_valid) continue;
        if (!ML_PointInRect(mouselock_hits[seat].pos,
                            mouselock_hits[seat].size, cursor))
            continue;
        // Route subsequent mouse/keyboard input to this seat. in_forceseat
        // is 1-based; 0 means "use device->seat mapping" which on the web
        // build always resolves to seat 0 (single mouse). Setting it
        // before lock acquisition so the very first relative-mouse event
        // lands on the intended player view.
        cvar_set("in_forceseat", sprintf("%d", seat + 1));
        // Drop out of cursor mode first so gl_vidweb.c:732's per-frame
        // emscriptenfte_updatepointerlock(0, 1) call doesn't immediately
        // release the lock we're about to acquire. Then ask the engine
        // bridge to fire Module.FTE_RequestPointerLock - the cbuf flush
        // runs inside the same task as this input dispatch, so
        // transient user activation is still valid for the browser.
        mouselock_is_active = 1;
        setcursormode(FALSE);
        localcmd("requestpointerlock\n");
        return 1;
    }
    return 0;
};

// ----- helpers --------------------------------------------------------------

// Button geometry: anchored to the seat viewport's bottom-left corner with
// the configured margin. Inner size = label width + 2 * pad_x by font +
// 2 * pad_y, so the hit zone (and hover fill) grows around the text on all
// four sides instead of hugging it tight.
void(vector view_min, vector view_size, string label,
     __out vector pos, __out vector size, __out vector font_size) ML_ButtonRect =
{
    float font_px = autocvar_mouselock_font_size;
    if (font_px < 6) font_px = 6;
    font_size = [font_px, font_px, 0];

    float pad_x = autocvar_mouselock_padding.x;
    float pad_y = autocvar_mouselock_padding.y;
    if (pad_x < 0) pad_x = 0;
    if (pad_y < 0) pad_y = 0;

    float text_w = stringwidth(label, 0, font_size);
    float width  = text_w  + pad_x * 2;
    float height = font_px + pad_y * 2;
    size = [width, height, 0];

    float margin_x = autocvar_mouselock_margin.x;
    float margin_y = autocvar_mouselock_margin.y;
    // Clear the demo time slider when the web app overlays one along the
    // bottom of the canvas during demo playback (same rule as
    // player_info.qc's bottom-anchored widget).
    if (isdemo()) {
        margin_y += DEMO_TIMESLIDER_HEIGHT_PX;
    }
    pos = [view_min.x + margin_x,
           view_min.y + view_size.y - margin_y - height, 0];
};

float(vector pos, vector size, vector cursor) ML_PointInRect =
{
    if (cursor.x < pos.x || cursor.x >= pos.x + size.x) return 0;
    if (cursor.y < pos.y || cursor.y >= pos.y + size.y) return 0;
    return 1;
};

// Parses "R G B A" with RGB in 0..255 and alpha in 0..1, matching the
// playerinfo_frame_color / playerinfo_track_color convention. Missing
// fields fall back to opaque black.
void(string spec, __out vector rgb, __out float alpha) ML_ParseColor =
{
    float argc = tokenize(spec);
    float r = (argc >= 1) ? stof(argv(0)) : 0;
    float g = (argc >= 2) ? stof(argv(1)) : 0;
    float b = (argc >= 3) ? stof(argv(2)) : 0;
    alpha   = (argc >= 4) ? stof(argv(3)) : 1;
    rgb     = [r, g, b] / 255;
};
