#define TRANSITION_RT_NAME "hub_transition_src"

var float  autocvar_transition_enabled        = 1;
var string autocvar_transition_style          = "randomize";
var float  autocvar_transition_duration       = 0.8;
var float  autocvar_transition_max_wait       = 5.0;
// Debug: force the transition into the looping/waiting phase forever
// (never auto-promote to active, never time out). Lets you preview the
// pre-resolve animation of loops-while-waiting effects continuously.
var float  autocvar_transition_debug_loop     = 0;

float  transition_is_active;
float  transition_start_time;
float  transition_duration;
float  transition_effect;

// Per-transition random seed passed to non-loop effect shaders via
// vc.r, so deterministic-looking effects (e.g. plasma_burn) can
// scramble their pattern each time. Regenerated on every TransitionStart
// and TransitionOnQtvCapture.
float  transition_seed;

float  transition_should_capture;
float  transition_is_capturing;
float  transition_is_waiting;
float  transition_wait_start_time;
float  transition_prev_con_stayhidden;
float  transition_prev_con_notifylines;

// Captured at the waiting->active handoff. Lets the framework pass a
// continuous elapsed-seconds value (wait_duration + active_elapsed) to
// loops-while-waiting shaders, so their time-driven animation doesn't
// snap back to 0 when the active phase begins.
float  transition_wait_duration;

// Monotonic in-transition timer. We accumulate dt = cltime - last each
// frame, so even if cltime pauses or jumps at the map-load boundary the
// counter still increases smoothly. Used for the time-driven shader
// animations that need to survive the waiting->active handoff.
float  transition_render_time;
float  transition_render_last_cltime;

void()                                TransitionRegisterShaders;
void(float vwidth, float vheight)     TransitionDrawWaiting;
void()                                TransitionOnSpawn;
void()                                TransitionOnQtvCapture;
void(float vwidth, float vheight)     TransitionBeginCapture;
void(float vwidth, float vheight)     TransitionEndCapture;
void(float vwidth, float vheight)     TransitionDrawLoading;
void()                                TransitionPollTriggers;
void(float effect, float duration)    TransitionStart;
float()                               TransitionCmd;

float()                               TransitionDefaultEffect;
float()                               TransitionPickEffect;
void()                                TransitionFinish;
void(float vwidth, float vheight)     TransitionDrawOverlay;
void(float vwidth, float vheight)     TransitionBlitCaptured;
void(string shader_name, float vwidth, float vheight, vector color, float progress) TransitionDrawQuad;
void()                                TransitionTickRenderTime;
float(float now)                      TransitionProgress;

void() TransitionOnSpawn =
{
    if (!transition_is_waiting) return;
    if (autocvar_transition_debug_loop) return;   // stay in waiting forever
    transition_wait_duration = cltime - transition_wait_start_time;
    transition_is_waiting  = 0;
    transition_is_active   = 1;
    transition_start_time  = cltime;
};

void() TransitionOnQtvCapture =
{
    transition_effect          = TransitionPickEffect();
    transition_duration        = bound(0.05, TransitionEffectDuration(transition_effect, autocvar_transition_duration), 5);
    transition_is_active       = 0;
    transition_is_waiting      = 1;
    transition_should_capture  = 0;
    transition_wait_start_time = cltime;
    transition_render_time     = 0;
    transition_render_last_cltime = cltime;
    transition_seed            = random();
    transition_prev_con_stayhidden  = cvar("con_stayhidden");
    transition_prev_con_notifylines = cvar("con_notifylines");
    cvar_set("con_stayhidden",  "1");
    cvar_set("con_notifylines", "0");
};

// Bump the monotonic in-transition timer each frame. Caps dt so a
// map-load pause/reset of cltime can't cause a huge spike, and clamps
// to >=0 so a cltime rewind can't pull the counter backward.
void() TransitionTickRenderTime =
{
    float dt = cltime - transition_render_last_cltime;
    if (dt > 0.0 && dt < 0.5) {
        transition_render_time += dt;
    }
    transition_render_last_cltime = cltime;
};

void() TransitionRegisterShaders =
{
    shaderforname("hub_transition_blit", R"({
    program
    {
!!ver 100
!!samps 1
#ifdef VERTEX_SHADER
attribute vec2 v_texcoord;
varying vec2 tc;
void main() { tc = v_texcoord; gl_Position = ftetransform(); }
#endif
#ifdef FRAGMENT_SHADER
varying vec2 tc;
void main() { gl_FragColor = vec4(texture2D(s_t0, vec2(tc.x, 1.0 - tc.y)).rgb, 1.0); }
#endif
    }
    {
        map $nearest:$sourcecolour
        blendfunc replace
    }
})");

    TransitionRegisterEffectShaders();
};

void(float vwidth, float vheight) TransitionBeginCapture =
{
    transition_is_capturing = 0;
    if (!autocvar_transition_enabled) return;
    if (!transition_should_capture)   return;

    setviewprop(VF_RT_DESTCOLOUR, TRANSITION_RT_NAME,
                -IMGFMT_R8G8B8A8, [vwidth, vheight, 0]);
    transition_is_capturing = 1;
};

void(float vwidth, float vheight) TransitionEndCapture =
{
    if (transition_is_capturing) {
        setviewprop(VF_RT_DESTCOLOUR, "");
        setviewprop(VF_RT_SOURCECOLOUR, TRANSITION_RT_NAME);
        transition_is_capturing   = 0;
        transition_should_capture = 0;
        TransitionBlitCaptured(vwidth, vheight);
        setviewprop(VF_RT_SOURCECOLOUR, "");
        return;
    }

    if (transition_is_waiting) {
        setviewprop(VF_RT_SOURCECOLOUR, TRANSITION_RT_NAME);
        TransitionDrawWaiting(vwidth, vheight);
        setviewprop(VF_RT_SOURCECOLOUR, "");
        return;
    }

    if (transition_is_active) {
        setviewprop(VF_RT_SOURCECOLOUR, TRANSITION_RT_NAME);
        TransitionDrawOverlay(vwidth, vheight);
        setviewprop(VF_RT_SOURCECOLOUR, "");
    }
};

void(float vwidth, float vheight) TransitionDrawLoading =
{
    drawfill([0, 0, 0], [vwidth, vheight, 0], '0 0 0', 1);
    TransitionPollTriggers();

    if (transition_is_waiting) {
        setviewprop(VF_RT_SOURCECOLOUR, TRANSITION_RT_NAME);
        TransitionDrawWaiting(vwidth, vheight);
        setviewprop(VF_RT_SOURCECOLOUR, "");
        return;
    }

    if (transition_is_active) {
        setviewprop(VF_RT_SOURCECOLOUR, TRANSITION_RT_NAME);
        TransitionDrawOverlay(vwidth, vheight);
        setviewprop(VF_RT_SOURCECOLOUR, "");
    }
};

void() TransitionPollTriggers =
{
    if (!autocvar_transition_enabled) return;
    if (!transition_is_waiting)       return;
    if (autocvar_transition_debug_loop) return;   // no timeout in debug
    if ((cltime - transition_wait_start_time) <= autocvar_transition_max_wait) return;

    transition_wait_duration = cltime - transition_wait_start_time;
    transition_is_waiting = 0;
    transition_is_active  = 1;
    transition_start_time = cltime;
};

void(float effect, float duration) TransitionStart =
{
    transition_effect         = effect;
    transition_duration       = bound(0.05, TransitionEffectDuration(effect, duration), 5);
    transition_start_time     = cltime;
    transition_should_capture = 1;
    transition_render_time     = 0;
    transition_render_last_cltime = cltime;
    transition_seed           = random();
    if (autocvar_transition_debug_loop) {
        // Debug: enter the looping/waiting phase and stay there. The
        // OnSpawn/PollTriggers checks above bail out so we never promote
        // to active. Lets you preview the pre-resolve animation
        // continuously by just running `transition <style>`.
        transition_is_active       = 0;
        transition_is_waiting      = 1;
        transition_wait_start_time = cltime;
    } else {
        transition_is_active  = 1;
        transition_is_waiting = 0;
    }
    transition_wait_duration = 0;   // manual trigger skips the wait phase
    transition_prev_con_stayhidden  = cvar("con_stayhidden");
    transition_prev_con_notifylines = cvar("con_notifylines");
    cvar_set("con_stayhidden",  "1");
    cvar_set("con_notifylines", "0");
};

float() TransitionCmd =
{
    string style = argv(1);
    if (style == "" || style == "help") {
        println("usage: transition <style> [duration_seconds]");
        println("  styles: %s", TransitionStylesString());
        return 1;
    }
    float effect = TransitionParseStyle(style);
    if (effect < 0) {
        println("transition: unknown style '%s'", style);
        return 1;
    }
    float duration = autocvar_transition_duration;
    if (argv(2) != "") {
        duration = stof(argv(2));
    }
    TransitionStart(effect, duration);
    return 1;
};

float() TransitionDefaultEffect =
{
    float effect = TransitionParseStyle(autocvar_transition_style);
    if (effect < 0) effect = TRANSITION_EFFECT_DEFAULT;
    return effect;
};

float() TransitionPickEffect =
{
    if (autocvar_transition_style == "randomize")
        return floor(random() * TRANSITION_EFFECT_COUNT);
    return TransitionDefaultEffect();
};

float(float now) TransitionProgress =
{
    if (transition_duration <= 0) return 1;
    return (now - transition_start_time) / transition_duration;
};

void(float vwidth, float vheight) TransitionDrawOverlay =
{
    TransitionTickRenderTime();
    float progress = TransitionProgress(cltime);
    if (progress >= 1) {
        TransitionFinish();
        return;
    }
    if (progress < 0) progress = 0;

    string name = TransitionShaderName(transition_effect);
    // For loops-while-waiting effects, pass the monotonic in-transition
    // timer via vc.r so the shader's time-driven animation stays
    // continuous across the waiting->active handoff (and through any
    // cltime pause/reset at map load).
    if (TransitionEffectLoopsWhileWaiting(transition_effect)) {
        TransitionDrawQuad(name, vwidth, vheight,
                           [transition_render_time, 0, 0], progress);
        return;
    }
    // vc.r carries the per-transition random seed for shaders that
    // want to scramble their pattern each run (plasma_burn etc.).
    TransitionDrawQuad(name, vwidth, vheight,
                       [transition_seed, 1, 1], progress);
};

void() TransitionFinish =
{
    transition_is_active      = 0;
    transition_is_waiting     = 0;
    transition_is_capturing   = 0;
    transition_should_capture = 0;
    setviewprop(VF_RT_DESTCOLOUR, "");
    setviewprop(VF_RT_SOURCECOLOUR, "");
    cvar_set("con_stayhidden",  ftos(transition_prev_con_stayhidden));
    cvar_set("con_notifylines", ftos(transition_prev_con_notifylines));
};

void(string shader_name, float vwidth, float vheight, vector color, float progress) TransitionDrawQuad =
{
    R_BeginPolygon(shader_name, 0, 1);
    R_PolygonVertex([0, 0, 0],            [0, 0, 0], color, progress);
    R_PolygonVertex([vwidth, 0, 0],       [1, 0, 0], color, progress);
    R_PolygonVertex([vwidth, vheight, 0], [1, 1, 0], color, progress);
    R_PolygonVertex([0, vheight, 0],      [0, 1, 0], color, progress);
    R_EndPolygon();
};

void(float vwidth, float vheight) TransitionBlitCaptured =
{
    R_BeginPolygon("hub_transition_blit", 0, 1);
    R_PolygonVertex([0, 0, 0],            [0, 0, 0], '1 1 1', 1);
    R_PolygonVertex([vwidth, 0, 0],       [1, 0, 0], '1 1 1', 1);
    R_PolygonVertex([vwidth, vheight, 0], [1, 1, 0], '1 1 1', 1);
    R_PolygonVertex([0, vheight, 0],      [0, 1, 0], '1 1 1', 1);
    R_EndPolygon();
};

// Waiting-phase draw: opt-in effects animate during the wait via the
// shader (with elapsed time encoded as vc.a + 2.0); the rest fall back
// to a plain blit of the captured scene.
void(float vwidth, float vheight) TransitionDrawWaiting =
{
    if (!TransitionEffectLoopsWhileWaiting(transition_effect)) {
        TransitionBlitCaptured(vwidth, vheight);
        return;
    }
    TransitionTickRenderTime();
    float loop_t = transition_render_time + 2.0;   // vc.a encoding for "looping phase"
    TransitionDrawQuad(TransitionShaderName(transition_effect),
                       vwidth, vheight, [transition_render_time, 0, 0], loop_t);
};
