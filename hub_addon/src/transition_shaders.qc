#define TRANSITION_EFFECT_MELT         0
#define TRANSITION_EFFECT_TELEFRAG     1
#define TRANSITION_EFFECT_CRT_OFF      2
#define TRANSITION_EFFECT_SWIRL        3
#define TRANSITION_EFFECT_WATER_DROP   4
#define TRANSITION_EFFECT_PIXELATE     5
#define TRANSITION_EFFECT_COUNT        6

void()                TransitionRegisterEffectShaders;
string(float effect)  TransitionShaderName;

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

void() TransitionRegisterEffectShaders =
{
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
