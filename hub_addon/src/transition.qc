#define TRANSITION_EFFECT_MELT         0
#define TRANSITION_EFFECT_TELEFRAG     1
#define TRANSITION_EFFECT_CRT_OFF      2
#define TRANSITION_EFFECT_SWIRL        3
#define TRANSITION_EFFECT_WATER_DROP   4
#define TRANSITION_EFFECT_PIXELATE     5
#define TRANSITION_EFFECT_COUNT        6

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
float(float effect, float base_duration) TransitionEffectDuration;
void(float vwidth, float vheight)     TransitionDrawOverlay;
void(float vwidth, float vheight)     TransitionBlitCaptured;
string(float effect)                  TransitionShaderName;
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

    shaderforname("hub_transition_melt", R"({
    program
    {
!!ver 100
!!samps 1
#ifdef VERTEX_SHADER
attribute vec2 v_texcoord;
attribute vec4 v_colour;
varying vec2 tc;
varying vec4 vc;
void main() { tc = v_texcoord; vc = v_colour; gl_Position = ftetransform(); }
#endif
#ifdef FRAGMENT_SHADER
varying vec2 tc;
varying vec4 vc;
void main()
{
    float t = vc.a;
    float col_seed = floor(tc.x * 320.0);
    float col_rand = fract(sin(col_seed * 12.9898) * 43758.5453);
    float start_delay = col_rand * 0.15;
    float lt  = max(0.0, t - start_delay);
    float off = lt * lt * 1.1 + lt * 0.05;
    float sy  = tc.y - off;
    if (sy < 0.0) discard;
    gl_FragColor = vec4(texture2D(s_t0, vec2(tc.x, 1.0 - sy)).rgb, 1.0);
}
#endif
    }
    {
        map $nearest:$sourcecolour
        blendfunc replace
    }
})");

    shaderforname("hub_transition_telefrag", R"({
    program
    {
!!ver 100
!!samps 1
#ifdef VERTEX_SHADER
attribute vec2 v_texcoord;
attribute vec4 v_colour;
varying vec2 tc;
varying vec4 vc;
void main() { tc = v_texcoord; vc = v_colour; gl_Position = ftetransform(); }
#endif
#ifdef FRAGMENT_SHADER
varying vec2 tc;
varying vec4 vc;
void main()
{
    float t = vc.a;
    float h = fract(sin(dot(tc * 256.0, vec2(12.9898, 78.233))) * 43758.5453);

    float split = t * 0.015;
    vec2 stc = vec2(tc.x, 1.0 - tc.y);
    float r = texture2D(s_t0, stc + vec2(split, 0.0)).r;
    float g = texture2D(s_t0, stc).g;
    float b = texture2D(s_t0, stc - vec2(split, 0.0)).b;
    vec3 src = vec3(r, g, b);

    if (h < t) {
        float n = fract(sin(dot(tc * 512.0 + vec2(t * 17.0, t * 11.0),
                                vec2(127.1, 311.7))) * 43758.5);
        vec3 spark = mix(vec3(0.0, 0.8, 1.0), vec3(1.0, 0.2, 0.9), n);
        src = step(0.75, n) * spark * (1.0 - smoothstep(0.7, 1.0, t));
    }

    src *= 1.0 - smoothstep(0.8, 1.0, t);
    gl_FragColor = vec4(src, 1.0);
}
#endif
    }
    {
        map $nearest:$sourcecolour
        blendfunc replace
    }
})");

    shaderforname("hub_transition_crt_off", R"({
    program
    {
!!ver 100
!!samps 2
#ifdef VERTEX_SHADER
attribute vec2 v_texcoord;
attribute vec4 v_colour;
varying vec2 tc;
varying vec4 vc;
void main() { tc = v_texcoord; vc = v_colour; gl_Position = ftetransform(); }
#endif
#ifdef FRAGMENT_SHADER
varying vec2 tc;
varying vec4 vc;
void main()
{
    float t = vc.a;
    float ys, xs;
    if (t < 0.4) {
        ys = mix(1.0, 0.008, smoothstep(0.0, 0.4, t));
        xs = 1.0;
    } else if (t < 0.5) {
        ys = 0.008;
        xs = mix(1.0, 0.008, smoothstep(0.4, 0.5, t));
    } else if (t < 0.6) {
        ys = 0.008;
        xs = mix(0.008, 1.0, smoothstep(0.5, 0.6, t));
    } else {
        ys = mix(0.008, 1.0, smoothstep(0.6, 1.0, t));
        xs = 1.0;
    }

    vec2 c = tc - vec2(0.5, 0.5);
    if (abs(c.x) > xs * 0.5 || abs(c.y) > ys * 0.5) {
        gl_FragColor = vec4(0.0, 0.0, 0.0, 1.0);
        return;
    }
    vec2 src_uv  = vec2(c.x / xs + 0.5, c.y / ys + 0.5);
    vec2 flipped = vec2(src_uv.x, 1.0 - src_uv.y);

    vec3 src;
    if (t < 0.5) {
        src = texture2D(s_t0, flipped).rgb;
    } else {
        src = texture2D(s_t1, flipped).rgb;
    }

    float edge_y     = abs(c.y) / max(ys * 0.5, 0.001);
    float y_phase    = step(t, 0.4) + step(0.6, t);
    src += vec3(0.5, 0.45, 0.35) * smoothstep(0.85, 1.0, edge_y) * y_phase * 0.7;

    gl_FragColor = vec4(src, 1.0);
}
#endif
    }
    {
        map $sourcecolour
        blendfunc replace
    }
    {
        map $currentrender
    }
})");

    shaderforname("hub_transition_swirl", R"({
    program
    {
!!ver 100
!!samps 2
#ifdef VERTEX_SHADER
attribute vec2 v_texcoord;
attribute vec4 v_colour;
varying vec2 tc;
varying vec4 vc;
void main() { tc = v_texcoord; vc = v_colour; gl_Position = ftetransform(); }
#endif
#ifdef FRAGMENT_SHADER
varying vec2 tc;
varying vec4 vc;
void main()
{
    float t = vc.a;
    vec2 c = tc - vec2(0.5, 0.5);
    float r = length(c);
    float a = atan(c.y, c.x);

    float phase = 1.0 - abs(t - 0.5) * 2.0;
    phase = smoothstep(0.0, 1.0, phase);
    float twist = phase * 16.0 * r;

    float na = a + twist;
    vec2 src_uv = vec2(cos(na), sin(na)) * r + vec2(0.5, 0.5);
    vec2 flipped = vec2(src_uv.x, 1.0 - src_uv.y);

    vec3 old_col = texture2D(s_t0, flipped).rgb;
    vec3 new_col = texture2D(s_t1, flipped).rgb;

    float swap = smoothstep(0.47, 0.53, t);
    vec3 src = mix(old_col, new_col, swap);
    gl_FragColor = vec4(src, 1.0);
}
#endif
    }
    {
        map $sourcecolour
        blendfunc replace
    }
    {
        map $currentrender
    }
})");

    shaderforname("hub_transition_water_drop", R"({
    program
    {
!!ver 100
!!samps 2
#ifdef VERTEX_SHADER
attribute vec2 v_texcoord;
attribute vec4 v_colour;
varying vec2 tc;
varying vec4 vc;
void main() { tc = v_texcoord; vc = v_colour; gl_Position = ftetransform(); }
#endif
#ifdef FRAGMENT_SHADER
varying vec2 tc;
varying vec4 vc;
void main()
{
    float t = vc.a;
    vec2 c = tc - vec2(0.5, 0.5);
    float r = length(c);
    float phase = 1.0 - abs(t - 0.5) * 2.0;
    phase = smoothstep(0.0, 1.0, phase);

    float wave_phase = r * 25.0 - t * 18.0;
    float wave_amp   = phase * 0.06;
    float disp       = sin(wave_phase) * wave_amp;
    vec2 dir = (r > 0.001) ? c / r : vec2(0.0, 1.0);
    vec2 sample_uv = tc + dir * disp;

    vec2 flipped = vec2(sample_uv.x, 1.0 - sample_uv.y);
    vec3 src = (t < 0.5) ? texture2D(s_t0, flipped).rgb
                         : texture2D(s_t1, flipped).rgb;

    src = mix(src, src * vec3(0.85, 0.95, 1.1), phase * 0.35);
    gl_FragColor = vec4(src, 1.0);
}
#endif
    }
    {
        map $sourcecolour
        blendfunc replace
    }
    {
        map $currentrender
    }
})");

    shaderforname("hub_transition_pixelate", R"({
    program
    {
!!ver 100
!!samps 2
#ifdef VERTEX_SHADER
attribute vec2 v_texcoord;
attribute vec4 v_colour;
varying vec2 tc;
varying vec4 vc;
void main() { tc = v_texcoord; vc = v_colour; gl_Position = ftetransform(); }
#endif
#ifdef FRAGMENT_SHADER
varying vec2 tc;
varying vec4 vc;
void main()
{
    float t = vc.a;
    float phase = 1.0 - abs(t - 0.5) * 2.0;
    phase = smoothstep(0.0, 1.0, phase);

    float grid = mix(512.0, 12.0, phase);
    vec2 quantized = (floor(tc * grid) + 0.5) / grid;

    vec2 flipped = vec2(quantized.x, 1.0 - quantized.y);
    vec3 src = (t < 0.5) ? texture2D(s_t0, flipped).rgb
                         : texture2D(s_t1, flipped).rgb;
    gl_FragColor = vec4(src, 1.0);
}
#endif
    }
    {
        map $sourcecolour
        blendfunc replace
    }
    {
        map $currentrender
    }
})");

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
        transition_is_active = 0;
        cvar_set("con_stayhidden",  ftos(transition_prev_con_stayhidden));
        cvar_set("con_notifylines", ftos(transition_prev_con_notifylines));
        return;
    }
    if (progress < 0) progress = 0;

    TransitionDrawQuad(TransitionShaderName(transition_effect),
                       vwidth, vheight, progress);
};

float(float effect, float base_duration) TransitionEffectDuration =
{
    if (effect == TRANSITION_EFFECT_PIXELATE) return base_duration * 1.6;
    return base_duration;
};

string(float effect) TransitionShaderName =
{
    switch (effect) {
    case TRANSITION_EFFECT_TELEFRAG:     return "hub_transition_telefrag";
    case TRANSITION_EFFECT_CRT_OFF:      return "hub_transition_crt_off";
    case TRANSITION_EFFECT_SWIRL:        return "hub_transition_swirl";
    case TRANSITION_EFFECT_WATER_DROP:   return "hub_transition_water_drop";
    case TRANSITION_EFFECT_PIXELATE:     return "hub_transition_pixelate";
    default:                             return "hub_transition_melt";
    }
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
