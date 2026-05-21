#define TRANSITION_RT_NAME "hub_transition_src"

var float  autocvar_transition_enabled        = 1;
var string autocvar_transition_style          = "randomize";
var float  autocvar_transition_duration       = 0.8;
var float  autocvar_transition_max_wait       = 5.0;

float  transition_is_active;
float  transition_start_time;
float  transition_duration;
float  transition_effect;

float  transition_should_capture;
float  transition_is_capturing;
float  transition_is_waiting;
float  transition_wait_start_time;
float  transition_prev_con_stayhidden;
float  transition_prev_con_notifylines;

void()                                TransitionRegisterShaders;
void()                                TransitionRegisterEffectShaders;
void()                                TransitionOnSpawn;
void()                                TransitionOnQtvCapture;
void(float vwidth, float vheight)     TransitionBeginCapture;
void(float vwidth, float vheight)     TransitionEndCapture;
void(float vwidth, float vheight)     TransitionDrawLoading;
void()                                TransitionPollTriggers;
void(float effect, float duration)    TransitionStart;
float()                               TransitionCmd;

float(string name)                    TransitionParseStyle;
float()                               TransitionDefaultEffect;
float()                               TransitionPickEffect;
void()                                TransitionFinish;
float(float effect, float base_duration) TransitionEffectDuration;
void(float vwidth, float vheight)     TransitionDrawOverlay;
void(float vwidth, float vheight)     TransitionBlitCaptured;
void(string shader_name, float vwidth, float vheight, float progress) TransitionDrawQuad;
float(float now)                      TransitionProgress;

void() TransitionOnSpawn =
{
    if (!transition_is_waiting) return;
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
    transition_prev_con_stayhidden  = cvar("con_stayhidden");
    transition_prev_con_notifylines = cvar("con_notifylines");
    cvar_set("con_stayhidden",  "1");
    cvar_set("con_notifylines", "0");
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
        TransitionBlitCaptured(vwidth, vheight);
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
        TransitionBlitCaptured(vwidth, vheight);
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
    if ((cltime - transition_wait_start_time) <= autocvar_transition_max_wait) return;

    transition_is_waiting = 0;
    transition_is_active  = 1;
    transition_start_time = cltime;
};

void(float effect, float duration) TransitionStart =
{
    transition_effect         = effect;
    transition_duration       = bound(0.05, TransitionEffectDuration(effect, duration), 5);
    transition_start_time     = cltime;
    transition_is_active      = 1;
    transition_is_waiting     = 0;
    transition_should_capture = 1;
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
        println("  styles: melt, telefrag, crt_off, swirl, water_drop, pixelate");
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

float(string name) TransitionParseStyle =
{
    if (name == "melt")         return TRANSITION_EFFECT_MELT;
    if (name == "telefrag")     return TRANSITION_EFFECT_TELEFRAG;
    if (name == "crt_off")      return TRANSITION_EFFECT_CRT_OFF;
    if (name == "swirl")        return TRANSITION_EFFECT_SWIRL;
    if (name == "water_drop")   return TRANSITION_EFFECT_WATER_DROP;
    if (name == "pixelate")     return TRANSITION_EFFECT_PIXELATE;
    return -1;
};

float() TransitionDefaultEffect =
{
    float effect = TransitionParseStyle(autocvar_transition_style);
    if (effect < 0) effect = TRANSITION_EFFECT_MELT;
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
    float progress = TransitionProgress(cltime);
    if (progress >= 1) {
        TransitionFinish();
        return;
    }
    if (progress < 0) progress = 0;

    TransitionDrawQuad(TransitionShaderName(transition_effect),
                       vwidth, vheight, progress);
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

float(float effect, float base_duration) TransitionEffectDuration =
{
    if (effect == TRANSITION_EFFECT_PIXELATE) return base_duration * 1.6;
    return base_duration;
};

void(string shader_name, float vwidth, float vheight, float progress) TransitionDrawQuad =
{
    R_BeginPolygon(shader_name, 0, 1);
    R_PolygonVertex([0, 0, 0],            [0, 0, 0], '1 1 1', progress);
    R_PolygonVertex([vwidth, 0, 0],       [1, 0, 0], '1 1 1', progress);
    R_PolygonVertex([vwidth, vheight, 0], [1, 1, 0], '1 1 1', progress);
    R_PolygonVertex([0, vheight, 0],      [0, 1, 0], '1 1 1', progress);
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
