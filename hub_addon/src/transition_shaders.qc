#define TRANSITION_EFFECT_MELT         0
#define TRANSITION_EFFECT_CRT_OFF      1
#define TRANSITION_EFFECT_SWIRL        2
#define TRANSITION_EFFECT_SHOCKWAVE    3
#define TRANSITION_EFFECT_PIXELATE     4
#define TRANSITION_EFFECT_BULGE_PINCH  5
#define TRANSITION_EFFECT_MATRIX       6
#define TRANSITION_EFFECT_PLASMA_BURN  7
#define TRANSITION_EFFECT_COUNT        8

#define TRANSITION_EFFECT_DEFAULT      TRANSITION_EFFECT_MELT

void()                                   TransitionRegisterEffectShaders;
string(float effect)                     TransitionShaderName;
string(float effect)                     TransitionEffectName;
string()                                 TransitionStylesString;
float(string name)                       TransitionParseStyle;
float(float effect, float base_duration) TransitionEffectDuration;
float(float effect)                      TransitionEffectLoopsWhileWaiting;

string(float effect) TransitionShaderName =
{
    switch (effect) {
    case TRANSITION_EFFECT_CRT_OFF:      return "hub_transition_crt_off";
    case TRANSITION_EFFECT_SWIRL:        return "hub_transition_swirl";
    case TRANSITION_EFFECT_SHOCKWAVE:    return "hub_transition_shockwave";
    case TRANSITION_EFFECT_PIXELATE:     return "hub_transition_pixelate";
    case TRANSITION_EFFECT_BULGE_PINCH:  return "hub_transition_bulge_pinch";
    case TRANSITION_EFFECT_MATRIX:       return "hub_transition_matrix";
    case TRANSITION_EFFECT_PLASMA_BURN:  return "hub_transition_plasma_burn";
    default:                             return "hub_transition_melt";
    }
};

// User-facing name used by the `transition` command and help text.
string(float effect) TransitionEffectName =
{
    switch (effect) {
    case TRANSITION_EFFECT_MELT:         return "melt";
    case TRANSITION_EFFECT_CRT_OFF:      return "crt_off";
    case TRANSITION_EFFECT_SWIRL:        return "swirl";
    case TRANSITION_EFFECT_SHOCKWAVE:    return "shockwave";
    case TRANSITION_EFFECT_PIXELATE:     return "pixelate";
    case TRANSITION_EFFECT_BULGE_PINCH:  return "bulge_pinch";
    case TRANSITION_EFFECT_MATRIX:       return "matrix";
    case TRANSITION_EFFECT_PLASMA_BURN:  return "plasma_burn";
    default:                             return "";
    }
};

string() TransitionStylesString =
{
    string s = "";
    for (float i = 0; i < TRANSITION_EFFECT_COUNT; i++) {
        if (i > 0) s = strcat(s, ", ");
        s = strcat(s, TransitionEffectName(i));
    }
    return s;
};

float(string name) TransitionParseStyle =
{
    for (float i = 0; i < TRANSITION_EFFECT_COUNT; i++) {
        if (name == TransitionEffectName(i)) return i;
    }
    return -1;
};

// Per-effect duration scaling (in seconds, relative to base_duration).
float(float effect, float base_duration) TransitionEffectDuration =
{
    if (effect == TRANSITION_EFFECT_PIXELATE)    return base_duration * 1.6;
    if (effect == TRANSITION_EFFECT_PLASMA_BURN) return base_duration * 1.3;
    return base_duration;
};

// Returns 1 if the effect's shader handles the waiting/looping phase
// itself (vc.a >= 1.5 is "elapsed wait time + 2.0", with no resolve).
float(float effect) TransitionEffectLoopsWhileWaiting =
{
    if (effect == TRANSITION_EFFECT_MATRIX)     return 1;
    return 0;
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

    shaderforname("hub_transition_shockwave", R"({
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
    // Phase arc: 0 at start/end, 1 at the midpoint - drives the
    // grid from sharp (512) to max-blocky (24) and back. Scene swap
    // happens at the peak (t = 0.5).
    float t = vc.a;
    float phase = 1.0 - abs(t - 0.5) * 2.0;
    phase = smoothstep(0.0, 1.0, phase);

    // Log-space interpolation gives perceptually even block growth.
    float grid = exp(mix(log(512.0), log(24.0), phase));

    vec2 quantized = (floor(tc * grid) + 0.5) / grid;
    vec2 flipped   = vec2(quantized.x, 1.0 - quantized.y);
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

    shaderforname("hub_transition_bulge_pinch", R"({
    program
    {
!!ver 100
!!samps 2
// Ported from PixiJS BulgePinchFilter (pixijs/filters), MIT License.
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
    float strength = -phase * 1.3;

    vec2 center = vec2(0.5, 0.5);
    float radius = 0.85;

    vec2 coord = tc - center;
    float dist = length(coord);

    vec2 pinched;
    if (dist < radius && dist > 0.001) {
        float percent = dist / radius;
        pinched = coord * mix(1.0, pow(percent, 1.0 + strength * 0.75) * radius / dist, 1.0 - percent);
    } else {
        pinched = coord;
    }

    // Radial motion blur: average N samples between pinched point and a
    // shorter version of itself toward center. Produces star-streak look.
    const int N = 8;
    vec3 sum_old = vec3(0.0);
    vec3 sum_new = vec3(0.0);
    for (int i = 0; i < N; i++) {
        float k = float(i) / float(N - 1);
        float scale = 1.0 - phase * 0.2 * (1.0 - k);
        vec2 s = pinched * scale + center;
        vec2 sf = vec2(s.x, 1.0 - s.y);
        sum_old += texture2D(s_t0, sf).rgb;
        sum_new += texture2D(s_t1, sf).rgb;
    }
    sum_old /= float(N);
    sum_new /= float(N);

    float swap = smoothstep(0.47, 0.53, t);
    vec3 src = mix(sum_old, sum_new, swap);
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

    shaderforname("hub_transition_matrix", R"({
    program
    {
!!ver 100
!!samps 2
// Matrix-rain shader (CELLS/FALLERS) ported from a Shadertoy snippet.
// Characters drawn from procedural 5x5 bitmaps via character().
// Each column shows either a '0' or a '1' glyph.
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

// Forward declarations - implementations live below main().
float hash11(float p);
float character(float n, vec2 p);
float pickN(vec2 cell, float step);
float pickBinary(vec2 cell, float step);
float fallerSpeed(float col, float faller);

void main()
{
    // Fixed pixel size per cell - chars stay the same size regardless of
    // the screen resolution. Larger screens get more cells, smaller fewer.
    const float MATRIX_CELL_PX = 24.0;
    // Per-faller cycle period in mod-space. Sized so the cycle
    // (~ MATRIX_FALLER_HEIGHT / speed iTime units, ~22 s) outlasts the
    // max wait (5 s), while the per-faller spacing
    // (MATRIX_FALLER_HEIGHT / N) is short enough that several drops are
    // visible per column at once instead of one sparse drop with gaps
    // between cycles.
    const float MATRIX_FALLER_HEIGHT = 20.0;

    // vc.a encoding: [0, 1] = active progress; >= 1.5 = looping wait
    // phase. vc.r carries continuous elapsed seconds since the
    // transition started (wait_duration + active_elapsed), so the
    // rain's iTime never snaps back to 0 at the wait->active handoff.
    float vc_a    = vc.a;
    float looping = step(1.5, vc_a);
    float t_eff   = vc_a * (1.0 - looping);
    float iTime   = vc.r * 1.5;

    // Cells are defined in pixel space via gl_FragCoord (y-up by default
    // in WebGL/GLSL ES), so chars are a fixed pixel size regardless of
    // resolution. cell.y=0 is at the bottom of the screen.
    vec2 pix  = fract(gl_FragCoord.xy / MATRIX_CELL_PX);
    vec2 cell = floor(gl_FragCoord.xy / MATRIX_CELL_PX);

    // Default: static background = binary 0/1 per cell. Cells inside an
    // active drop/trail override their glyph with a random 0-9 (so the
    // streak reveals decimal digits as it scrolls past).
    float n = pickBinary(cell, 0.0);

    // Trail length scales with the column's speed: slow columns get
    // short trails, fast columns get long ones (max 8 chars).
    float col_speed = fallerSpeed(cell.x, 0.0);
    float trail_len = mix(2.0, 8.0, clamp((col_speed - 0.04) / 0.30, 0.0, 1.0));

    float drop_amt  = 0.0;
    float trail_amt = 0.0;
    for (int i = 0; i < 10; i++) {
        float fi = float(i);
        float m = mod((iTime + fi * 3534.34 + cell.x * 17.0) * col_speed, MATRIX_FALLER_HEIGHT);
        float head_y = floor((3.0 - m) / 0.05);
        float offset = cell.y - head_y;
        // Glyph varies per (cell, faller) so each row of a streak shows
        // its own random 0-9 digit. The 3-col-wide glyph design keeps
        // sideways jitter to a minimum even with this variation.
        if (offset > -0.5 && offset < 0.5) {
            drop_amt += 1.0;
            n = pickN(cell, fi + 1.0);
        } else if (offset > 0.5 && offset < trail_len + 0.5) {
            trail_amt += (trail_len + 1.0 - offset) / trail_len;
            n = pickN(cell, fi + 1.0);
        }
    }

    float mask = character(n, vec2(-1.0) + pix * 2.0);
    // Depth cue: slow columns are dimmer (appear further away).
    float depth_alpha = mix(0.25, 1.0, clamp((col_speed - 0.04) / 0.30, 0.0, 1.0));
    float rain_alpha = clamp(drop_amt + trail_amt, 0.0, 1.0) * mask * 0.5 * depth_alpha;

    // Luminance of the scene; drives the matrix green channel below.
    // Raw [0, 1] - char_shift handles visibility at both extremes.
    vec2 flipped_tc = vec2(tc.x, 1.0 - tc.y);
    vec3 old_col    = texture2D(s_t0, flipped_tc).rgb;
    float gray      = dot(old_col, vec3(0.3, 0.59, 0.11));

    // 1. Static layer: chars shift the green channel in opposite
    //    directions depending on the scene brightness - brighter than
    //    the scene where the scene is dark, darker than the scene where
    //    the scene is bright. Guarantees visible contrast at both
    //    extremes (unlike Overlay blend, which fades to invisible near
    //    pure black or white).
    float char_shift = mix(0.1, -0.1, gray);
    float g_static   = gray + mask * char_shift;

    // 2. Rain layer: screen blend (lightens) on the static layer's green
    //    channel. drop cell gets near-full screen (1.0); trail fades.
    float g_final = 1.0 - (1.0 - g_static) * (1.0 - rain_alpha);

    vec3 matrix_out = vec3(0.0, g_final, 0.0);

    // Fade the matrix effect in over the first 0.2 s of the transition
    // (vc.r is monotonic elapsed seconds). Avoids the snap from raw
    // scene -> full matrix when the transition starts.
    float fade_in = smoothstep(0.0, 0.2, vc.r);
    vec3 combined = mix(old_col, matrix_out, fade_in);

    // Fade to new scene only during the active phase (latter half).
    // Looping forces fade = 0 so the new scene stays hidden until ready.
    vec3 new_col = texture2D(s_t1, flipped_tc).rgb;
    float fade   = smoothstep(0.5, 1.0, t_eff) * (1.0 - looping);

    vec3 src = mix(combined, new_col, fade);
    gl_FragColor = vec4(src, 1.0);
}

float hash11(float p) { return fract(sin(p * 91.345) * 47453.5); }

// 5x5 bitmap glyph: bit (p.x + 5*p.y) of n is the lit pixel.
float character(float n, vec2 p)
{
    p = floor(p * vec2(4.0, 4.0) + 2.5);
    if (clamp(p.x, 0.0, 4.0) == p.x && clamp(p.y, 0.0, 4.0) == p.y) {
        if (mod(floor(n / exp2(p.x + 5.0 * p.y)), 2.0) >= 1.0) return 1.0;
    }
    return 0.0;
}

// 5x5 digit bitmaps. All glyphs lit only in the central 3 columns
// (cols 1, 2, 3); cols 0 and 4 stay blank so adjacent cells with
// different glyphs don't shift the lit area sideways - eliminates the
// horizontal jitter that wider glyphs caused.
float pickN(vec2 cell, float step)
{
    float h = hash11(cell.x * 23.7 + cell.y * 91.3 + step * 13.1);
    float idx = floor(h * 10.0);
    if (idx < 1.0) return 15018318.0;  // 0
    if (idx < 2.0) return 4395150.0;   // 1
    if (idx < 3.0) return 14954574.0;  // 2
    if (idx < 4.0) return 14954766.0;  // 3
    if (idx < 5.0) return 10828040.0;  // 4
    if (idx < 6.0) return 14752014.0;  // 5
    if (idx < 7.0) return 14752078.0;  // 6
    if (idx < 8.0) return 14946436.0;  // 7
    if (idx < 9.0) return 15022414.0;  // 8
    return 15022350.0;                 // 9
}

// Binary subset: only '0' or '1' for the static background field.
float pickBinary(vec2 cell, float step)
{
    float h = hash11(cell.x * 23.7 + cell.y * 91.3 + step * 13.1);
    return h < 0.5 ? 15018318.0 : 4395150.0;
}

// Per-column speed only (per-faller variation causes bunching ->
// pulsation). Wide column-to-column spread (0.15-0.45 = 3x range) so
// you can clearly see some columns fall faster than others.
float fallerSpeed(float col, float faller)
{
    return mod(cos(col * 363.435), 0.3) + 0.04;
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

    shaderforname("hub_transition_plasma_burn", R"({
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

    // vc.r is a per-transition random seed in [0, 1). Used to offset
    // the plasma field's spatial position, rotation, and per-octave
    // phase so the reveal pattern differs each transition.
    float seed = vc.r;
    float ang  = seed * 6.2831853;
    float ca   = cos(ang);
    float sa   = sin(ang);
    vec2 offset    = vec2(seed * 17.3, seed * 29.7);
    mat2 rot       = mat2(ca, -sa, sa, ca);
    vec2 hotspot   = vec2(4.0) + (rot * vec2(seed * 3.0 - 1.5, seed * 2.0 - 1.0));

    // 4-octave sin-plasma normalized to [0, 1]. Used as the per-pixel
    // reveal threshold so the new scene bleeds through following the
    // plasma field's contours.
    vec2 p = rot * (tc * 8.0) + offset;
    float plasma = sin(p.x + t * 4.0 + seed * 11.0)
                 + sin(p.y - t * 3.0 + seed * 7.3)
                 + sin((p.x + p.y) * 0.7 + t * 5.0 + seed * 5.1)
                 + sin(length(p - hotspot) * 1.5 + t * 6.0 + seed * 13.7);
    plasma = (plasma + 4.0) / 8.0;

    float reveal = smoothstep(plasma - 0.08, plasma + 0.08, t);

    vec2 flipped = vec2(tc.x, 1.0 - tc.y);
    vec3 old_col = texture2D(s_t0, flipped).rgb;
    vec3 new_col = texture2D(s_t1, flipped).rgb;
    vec3 src = mix(old_col, new_col, reveal);

    // Hot edge: bright where reveal is mid-transition.
    float edge = 1.0 - abs(reveal - 0.5) * 2.0;
    edge = smoothstep(0.6, 1.0, edge);
    src += vec3(1.2, 0.55, 0.12) * edge;

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
