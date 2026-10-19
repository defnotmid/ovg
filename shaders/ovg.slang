// ovg's vertex and fragment shaders for SDL_GPU, compiled by build.sh to
// SPIR-V (Vulkan) and MSL (Metal).
//
// Port of femtovg's GL shader: the math must stay identical to the software
// backend, which is the pixel reference. SDL_GPU has no specialization
// constants, so the shader type and glyph mode are read from the paint and
// branched on at runtime, as femtovg originally did.
//
// Every vertex names its paint: a row of `paints` (ovg.Params packed by
// ovg.pack_frag_uniforms), so draws with different paints share one draw
// call.
//
// SDL_GPU binding convention: vertex uniforms set 1; fragment samplers,
// then storage buffers, set 2.

#include "curves.slang"

static const int FILL_GRADIENT = 0;
static const int FILL_IMAGE = 1;
static const int STENCIL = 2;
static const int FILL_IMAGE_GRADIENT = 3;
static const int FILTER_IMAGE = 4;
static const int FILL_COLOR = 5;
static const int TEXTURE_COPY_UNCLIPPED = 6;
static const int FILL_GRADIENT_CONIC = 8;
static const int FILL_IMAGE_GRADIENT_CONIC = 9;
static const int FILTER_COLOR_MATRIX = 10;
static const int FILTER_BLEND = 11;
static const int FILTER_COMPOSITE = 12;
static const int FILTER_COLOR_SPACE = 13;
static const int FILTER_COMPONENT_TRANSFER = 14;
static const int FILTER_MORPHOLOGY = 15;
static const int FILTER_LIGHTING = 16;
static const int FILTER_TILE = 17;
static const int FILTER_DISPLACEMENT = 18;
static const int FILTER_CONVOLVE = 19;
static const int FILTER_TURBULENCE = 20;
static const int TURBULENCE_MAX_OCTAVES = 24;
static const int MORPHOLOGY_MAX_RADIUS = 256;
static const int CONVOLVE_MAX_KERNEL = 36;
static const int BLUR_MAX_TAPS = 24;

static const float TAU = 6.28318530717958647692528676655900577;

// Target size in pixels (xy; zw unused).
// Target size (xy) and the drawing coordinates of its top-left pixel (zw).
struct View {
    float4 size;
};

// ovg.Params packed as 14 vec4s (ovg.pack_frag_uniforms).
struct Paint {
    float4 frag[14];
};

[[vk::binding(0, 1)]] ConstantBuffer<View> view : register(b0, space1);
[[vk::binding(0, 2)]] Sampler2D tex : register(t0, space2);
[[vk::binding(1, 2)]] Sampler2D glyphtex : register(t1, space2);
// Metal takes storage buffers after the uniform buffers (none here), so
// [[buffer(0)]]; slang numbers it from the register (no DXIL is built).
[[vk::binding(2, 2)]] StructuredBuffer<Paint> paints : register(t0, space2);

// The fragment's paint (set by fs_main).
static uint paint_index;

struct VS_In {
    float2 vertex : TEXCOORD0;
    float2 tcoord : TEXCOORD1;
    uint paint : TEXCOORD2;
};

struct VS_Out {
    float4 position : SV_Position;
    float2 ftcoord : TEXCOORD0;
    float2 fpos : TEXCOORD1;
    nointerpolation uint paint : TEXCOORD2;
};

// SDL_GPU puts NDC +1 at the top row of every target (screen or texture),
// so y = 0 is the top in both and images stay top-down.
[shader("vertex")]
VS_Out vs_main(VS_In i) {
    VS_Out o;
    o.ftcoord = i.tcoord;
    o.fpos = i.vertex;
    o.paint = i.paint;
    float2 p = i.vertex - view.size.zw;
    o.position = float4(2.0 * p.x / view.size.x - 1.0, 1.0 - 2.0 * p.y / view.size.y, 0, 1);
    return o;
}

float4 P(int i) { return paints[paint_index].frag[i]; }

// `mat3(frag[base].xyz, frag[base + 1].xyz, frag[base + 2].xyz) * vec3(p, 1)`.
float2 transform_point(int base, float2 p) {
    return (P(base).xyz * p.x + P(base + 1).xyz * p.y + P(base + 2).xyz).xy;
}

float4 inner_col() { return P(6); }
float4 outer_col() { return P(7); }
float2 scissor_ext() { return P(8).xy; }
float2 scissor_scale() { return P(8).zw; }
float2 extent() { return P(9).xy; }
float radius() { return P(9).z; }
float feather() { return P(9).w; }
float stroke_mult() { return P(10).x; }
float stroke_thr() { return P(10).y; }
int tex_type() { return int(P(10).z); }
int shader_type() { return int(P(10).w); }
int glyph_texture_type() { return int(P(11).x); }
float2 blur_direction() { return P(11).yz; }
int blur_taps() { return int(P(11).w); }
float3 blur_coeff() { return P(12).xyz; }
int blur_edge() { return int(P(12).w); }
float spread() { return P(13).x; }
// Filter passes: the operation (blend mode, composite operator, color
// space direction) and the second input's tex type.
int filter_op() { return int(P(9).z); }
int backdrop_tex_type() { return int(P(13).x); }

float sd_round_rect(float2 pt, float2 ext, float rad) {
    float2 ext2 = ext - float2(rad, rad);
    float2 d = abs(pt) - ext2;
    return min(max(d.x, d.y), 0.0) + length(max(d, 0.0)) - rad;
}

float scissor_mask(float2 p) {
    float2 sc = abs(transform_point(0, p)) - scissor_ext();
    sc = float2(0.5, 0.5) - sc * scissor_scale();
    return clamp(sc.x, 0.0, 1.0) * clamp(sc.y, 0.0, 1.0);
}

// Coverage from the vertex (u, v): a pyramid across the stroke with a
// one-pixel slope, times the edge fade in v.
float stroke_mask(float2 ftcoord) {
    float m = min(1.0, (1.0 - abs(ftcoord.x * 2.0 - 1.0)) * stroke_mult()) * min(1.0, ftcoord.y);
    // frag[0].w: smooth edge (ovg.Params.smooth_edge).
    return P(0).w != 0.0 ? m * m * (3.0 - 2.0 * m) : m;
}

float4 apply_tt(float4 color, int tt) {
    if (tt == 1) return float4(color.xyz * color.w, color.w);
    if (tt == 2) return float4(color.x);
    return color;
}

float4 apply_tex_type(float4 color) {
    return apply_tt(color, tex_type());
}

// SVG spreadMethod: 0 pad, 1 reflect, 2 repeat.
float spread_t(float t) {
    int s = int(spread());
    if (s == 1) {
        float m = t - 2.0 * floor(t * 0.5);
        return m > 1.0 ? 2.0 - m : m;
    }
    if (s == 2) return t - floor(t);
    return clamp(t, 0.0, 1.0);
}

// Two-point conical (focal) radial gradient: the largest t whose circle,
// from the focal circle (focal, fr) to the outer one (origin, r), passes
// through pt. Matches `focal_gradient_t` in filter_math.odin.
float focal_t(float2 pt) {
    float r = extent().x;
    float fr = extent().y;
    float2 f = P(13).zw;
    float2 cd = -f;
    float dr = r - fr;
    float2 pd = pt - f;
    float a = dot(cd, cd) - dr * dr;
    float b = dot(pd, cd) + fr * dr;
    float c = dot(pd, pd) - fr * fr;
    if (abs(a) < 1e-6) {
        return abs(b) > 1e-12 ? c / (2.0 * b) : 0.0;
    }
    float sq = sqrt(max(b * b - a * c, 0.0));
    float hi = a > 0.0 ? (b + sq) / a : (b - sq) / a;
    if (fr + hi * dr >= 0.0) return hi;
    return a > 0.0 ? (b - sq) / a : (b + sq) / a;
}

float gradient_t(float2 fpos) {
    float2 pt = transform_point(3, fpos);
    if (P(13).y != 0.0) return spread_t(focal_t(pt));
    return spread_t((sd_round_rect(pt, extent(), radius()) + feather() * 0.5) / feather());
}

float conic_fraction(float2 fpos) {
    float2 pt = transform_point(3, fpos);
    return (-atan2(pt.x, pt.y) / TAU) + 0.5;
}

// One blur tap at pixel position `p` of an `ext`-sized image: transparent
// beyond it, or the nearest edge pixel (`clamp_edge`).
float4 blur_tap(float2 p, float2 ext, bool clamp_edge) {
    if (clamp_edge) {
        p = clamp(p, float2(0.5, 0.5), ext - 0.5);
    } else if (p.x < 0.0 || p.y < 0.0 || p.x > ext.x || p.y > ext.y) {
        return float4(0, 0, 0, 0);
    }
    return tex.SampleLevel(p / ext, 0);
}

// One direction of a separable gaussian with incremental coefficients.
float4 render_filtered_image(float2 fpos) {
    float2 ext = extent();
    bool clamp_edge = blur_edge() == 1;
    float2 dir = blur_direction();
    int taps = blur_taps();
    float3 coeff = blur_coeff();
    float4 color_sum = tex.SampleLevel(fpos / ext, 0) * coeff.x;
    float coeff_sum = coeff.x;
    coeff.xy *= coeff.yz;
    for (int i = 1; i <= BLUR_MAX_TAPS; i++) {
        if (i > taps) {
            break;
        }
        float2 d = float(i) * dir;
        color_sum += blur_tap(fpos - d, ext, clamp_edge) * coeff.x;
        color_sum += blur_tap(fpos + d, ext, clamp_edge) * coeff.x;
        coeff_sum += 2.0 * coeff.x;
        coeff.xy *= coeff.yz;
    }
    return apply_tex_type(color_sum / coeff_sum);
}

// ---- filters (mirror ovg/filter_math.odin) -----------------------------

float4 unpremultiply(float4 c) {
    if (c.w <= 0.0) return float4(0, 0, 0, 0);
    return float4(c.xyz / c.w, c.w);
}

float4 premultiply(float4 c) {
    return float4(c.xyz * c.w, c.w);
}

float srgb_to_linear(float v) {
    return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4);
}

float linear_to_srgb(float v) {
    return v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1.0 / 2.4) - 0.055;
}

float lum(float3 c) {
    return 0.3 * c.x + 0.59 * c.y + 0.11 * c.z;
}

float3 clip_color(float3 c) {
    float l = lum(c);
    float n = min(c.x, min(c.y, c.z));
    float x = max(c.x, max(c.y, c.z));
    if (n < 0.0 && l - n > 0.0) c = l + (c - l) * l / (l - n);
    if (x > 1.0 && x - l > 0.0) c = l + (c - l) * (1.0 - l) / (x - l);
    return c;
}

float3 set_lum(float3 c, float l) {
    return clip_color(c + (l - lum(c)));
}

float sat(float3 c) {
    return max(c.x, max(c.y, c.z)) - min(c.x, min(c.y, c.z));
}

float3 set_sat(float3 c, float s) {
    float lo = min(c.x, min(c.y, c.z));
    float hi = max(c.x, max(c.y, c.z));
    if (hi <= lo) return float3(0, 0, 0);
    return (c - lo) * (s / (hi - lo));
}

float hard_light(float cb, float cs) {
    if (cs <= 0.5) return cb * 2.0 * cs;
    float s = 2.0 * cs - 1.0;
    return cb + s - cb * s;
}

float blend_channel(int mode, float cb, float cs) {
    if (mode == 1) return cb * cs;
    if (mode == 2) return cb + cs - cb * cs;
    if (mode == 3) return hard_light(cs, cb);
    if (mode == 4) return min(cb, cs);
    if (mode == 5) return max(cb, cs);
    if (mode == 6) {
        if (cb <= 0.0) return 0.0;
        if (cs >= 1.0) return 1.0;
        return min(1.0, cb / (1.0 - cs));
    }
    if (mode == 7) {
        if (cb >= 1.0) return 1.0;
        if (cs <= 0.0) return 0.0;
        return 1.0 - min(1.0, (1.0 - cb) / cs);
    }
    if (mode == 8) return hard_light(cb, cs);
    if (mode == 9) {
        if (cs <= 0.5) return cb - (1.0 - 2.0 * cs) * cb * (1.0 - cb);
        float d = cb <= 0.25 ? ((16.0 * cb - 12.0) * cb + 4.0) * cb : sqrt(cb);
        return cb + (2.0 * cs - 1.0) * (d - cb);
    }
    if (mode == 10) return abs(cb - cs);
    if (mode == 11) return cb + cs - 2.0 * cb * cs;
    return cs;
}

float3 blend_function(int mode, float3 cb, float3 cs) {
    if (mode == 12) return set_lum(set_sat(cs, sat(cb)), lum(cb));
    if (mode == 13) return set_lum(set_sat(cb, sat(cs)), lum(cb));
    if (mode == 14) return set_lum(cs, lum(cb));
    if (mode == 15) return set_lum(cb, lum(cs));
    return float3(blend_channel(mode, cb.x, cs.x), blend_channel(mode, cb.y, cs.y), blend_channel(mode, cb.z, cs.z));
}

float4 blend_pixel(int mode, float4 s, float4 b) {
    float4 us = unpremultiply(s);
    float4 ub = unpremultiply(b);
    float3 f = blend_function(mode, ub.xyz, us.xyz);
    float3 rgb = s.xyz * (1.0 - b.w) + b.xyz * (1.0 - s.w) + f * (s.w * b.w);
    float a = s.w + b.w - s.w * b.w;
    return clamp(float4(rgb, a), 0.0, 1.0);
}

float4 composite_pixel(int op, float4 k, float4 i1, float4 i2) {
    float4 o;
    if (op == 0) o = i1 + i2 * (1.0 - i1.w);
    else if (op == 1) o = i1 * i2.w;
    else if (op == 2) o = i1 * (1.0 - i2.w);
    else if (op == 3) o = i1 * i2.w + i2 * (1.0 - i1.w);
    else if (op == 4) o = i1 * (1.0 - i2.w) + i2 * (1.0 - i1.w);
    else if (op == 5) o = i1 + i2;
    else o = i1 * i2 * k.x + i1 * k.y + i2 * k.z + k.w;
    float a = clamp(o.w, 0.0, 1.0);
    return float4(clamp(o.xyz, 0.0, a), a);
}

// ---- neighbourhood filters (mirror backend_software.odin) ---------------
//
// Uniforms: the valid rectangle (x0, y0, x1, y1) in frag[9].zw, frag[10].xy;
// per filter parameters in frag[0..8], frag[11], frag[12].

float4 valid_rect() { return float4(P(9).zw, P(10).xy); }

// The source's pixel p (premultiplied), transparent beyond the image.
float4 texel(int2 p) {
    float2 ext = extent();
    if (p.x < 0 || p.y < 0 || float(p.x) >= ext.x || float(p.y) >= ext.y) return float4(0, 0, 0, 0);
    return apply_tex_type(tex.SampleLevel((float2(p) + 0.5) / ext, 0));
}

float4 backdrop_texel(int2 p) {
    float2 ext = extent();
    if (p.x < 0 || p.y < 0 || float(p.x) >= ext.x || float(p.y) >= ext.y) return float4(0, 0, 0, 0);
    return apply_tt(glyphtex.SampleLevel((float2(p) + 0.5) / ext, 0), backdrop_tex_type());
}

float floor_round(float v) {
    return floor(abs(v) + 0.5) * (v >= 0.0 ? 1.0 : -1.0);
}

float4 morphology(int2 p) {
    float rf = clamp(P(0).x, 0.0, float(MORPHOLOGY_MAX_RADIUS));
    int r = int(rf);
    float frac = rf - float(r);
    bool dilate = P(0).y != 0.0;
    int axis = int(P(0).z);
    float4 vr = valid_rect();
    int c = axis == 0 ? p.x : p.y;
    int lo = int(axis == 0 ? vr.x : vr.y);
    int hi = int(axis == 0 ? vr.z : vr.w) - 1;
    if (lo > hi) return float4(0, 0, 0, 0);
    float4 acc = dilate ? float4(0, 0, 0, 0) : float4(1, 1, 1, 1);
    int t0 = max(c - r, lo);
    int t1 = min(c + r, hi);
    for (int i = 0; i <= 2 * MORPHOLOGY_MAX_RADIUS; i++) {
        int t = t0 + i;
        if (t > t1) break;
        float4 v = texel(axis == 0 ? int2(t, p.y) : int2(p.x, t));
        acc = dilate ? max(acc, v) : min(acc, v);
    }
    if (frac > 0.0) {
        float4 ring = acc;
        for (int s = -1; s <= 1; s += 2) {
            int t = c + s * (r + 1);
            if (t < lo || t > hi) continue;
            float4 v = texel(axis == 0 ? int2(t, p.y) : int2(p.x, t));
            ring = dilate ? max(ring, v) : min(ring, v);
        }
        acc = lerp(acc, ring, frac);
    }
    return acc;
}

// Mirrors `lighting_gradient` / `lighting_pixel` in filter_math.odin.
float4 lighting(int2 p) {
    float4 vr = valid_rect();
    float2 fp = float2(p);
    bool left = fp.x - 1.0 >= vr.x;
    bool right = fp.x + 1.0 < vr.z;
    bool up = fp.y - 1.0 >= vr.y;
    bool down = fp.y + 1.0 < vr.w;
    float a[3][3];
    for (int j = 0; j < 3; j++) {
        for (int i = 0; i < 3; i++) {
            a[j][i] = texel(p + int2(i - 1, j - 1)).w;
        }
    }
    int xl = left ? 0 : 1;
    int xr = right ? 2 : 1;
    int yu = up ? 0 : 1;
    int yd = down ? 2 : 1;
    float2 g = float2(0, 0);
    if (xr > xl) {
        float sum = 0.0;
        float weight = 0.0;
        for (int row = yu; row <= yd; row++) {
            float w = row == 1 ? 2.0 : 1.0;
            sum += w * (a[row][xr] - a[row][xl]);
            weight += w;
        }
        g.x = sum / weight * 2.0 / float(xr - xl);
    }
    if (yd > yu) {
        float sum = 0.0;
        float weight = 0.0;
        for (int col = xl; col <= xr; col++) {
            float w = col == 1 ? 2.0 : 1.0;
            sum += w * (a[yd][col] - a[yu][col]);
            weight += w;
        }
        g.y = sum / weight * 2.0 / float(yd - yu);
    }
    float surface_scale = P(0).w;
    bool specular = P(1).x != 0.0;
    int kind = int(P(1).y);
    float constant = P(1).z;
    float spec_exp = P(1).w;
    float3 position = P(2).xyz;
    float3 n = float3(-g.x * surface_scale, -g.y * surface_scale, 1.0);
    float3 lv = position;
    if (kind != 0) {
        float3 v = position - float3(fp, a[1][1] * surface_scale);
        float len_v = length(v);
        lv = len_v > 0.0 ? v / len_v : v;
    }
    float3 color = P(0).xyz * 255.0;
    if (kind == 2) {
        float3 s = P(3).xyz - position;
        float len_s = length(s);
        if (len_s > 0.0) s /= len_s;
        float minus_l_dot_s = -dot(lv, s);
        if (minus_l_dot_s <= 0.0 || minus_l_dot_s < P(3).w) {
            color = float3(0, 0, 0);
        } else {
            float f = pow(minus_l_dot_s, P(2).w);
            color = floor(clamp(color * f, 0.0, 255.0) + 0.5);
        }
    }
    float len_n = length(n);
    float factor = 0.0;
    if (!specular) {
        factor = constant * dot(n, lv) / len_n;
    } else {
        float3 h = lv + float3(0, 0, 1);
        float len_h = length(h);
        if (len_h > 0.0) {
            float n_dot_h = dot(n, h) / len_n / len_h;
            if (spec_exp != 1.0) n_dot_h = pow(max(n_dot_h, 0.0), spec_exp);
            factor = constant * n_dot_h;
        }
    }
    float3 rgb = floor(clamp(color * factor, 0.0, 255.0) + 0.5) / 255.0;
    return float4(rgb, specular ? max(rgb.x, max(rgb.y, rgb.z)) : 1.0);
}

float4 tile(int2 p) {
    int4 r = int4(round(P(0)));
    if (r.z < 1 || r.w < 1) return float4(0, 0, 0, 0);
    int tx = ((p.x - r.x) % r.z + r.z) % r.z;
    int ty = ((p.y - r.y) % r.w + r.w) % r.w;
    return texel(int2(r.x + tx, r.y + ty));
}

float4 displacement(int2 p) {
    float4 m = backdrop_texel(p);
    float2 d = float2(m[int(P(0).z) & 3], m[int(P(0).w) & 3]) - 0.5;
    float2 o = float2(floor_round(float(p.x) + d.x * P(0).x), floor_round(float(p.y) + d.y * P(0).y));
    float4 vr = valid_rect();
    if (o.x >= vr.x && o.y >= vr.y && o.x < vr.z && o.y < vr.w) return texel(int2(o));
    return float4(0, 0, 0, 0);
}

float4 convolve(int2 p) {
    float4 vrf = valid_rect();
    int4 vr = int4(vrf);
    int vw = vr.z - vr.x;
    int vh = vr.w - vr.y;
    if (vw <= 0 || vh <= 0) return float4(0, 0, 0, 0);
    int2 order = int2(P(11).xy);
    int2 target = int2(P(11).zw);
    float divisor = P(12).x;
    float bias = P(12).y;
    int edge = int(P(12).z);
    bool preserve = P(12).w != 0.0;
    float4 sum = float4(0, 0, 0, 0);
    for (int i = 0; i < CONVOLVE_MAX_KERNEL; i++) {
        if (i >= order.x * order.y) break;
        int ox = i % order.x;
        int oy = i / order.x;
        int tx = p.x - target.x + ox;
        int ty = p.y - target.y + oy;
        if (edge == 2) {
            if (tx < vr.x || tx >= vr.z || ty < vr.y || ty >= vr.w) continue;
        } else if (edge == 1) {
            tx = vr.x + ((tx - vr.x) % vw + vw) % vw;
            ty = vr.y + ((ty - vr.y) % vh + vh) % vh;
        } else {
            tx = clamp(tx, vr.x, vr.z - 1);
            ty = clamp(ty, vr.y, vr.w - 1);
        }
        int ki = (order.y - oy - 1) * order.x + (order.x - ox - 1);
        float k = P(ki / 4)[ki % 4];
        float4 c = texel(int2(tx, ty));
        sum += (preserve ? unpremultiply(c) : c) * k;
    }
    float src_a = texel(p).w;
    float a = preserve ? src_a : sum.w / divisor + bias;
    float ba = clamp(a, 0.0, 1.0);
    float3 c = sum.xyz / divisor + bias * a;
    float3 rgb = preserve ? clamp(c, 0.0, 1.0) * ba : clamp(c, 0.0, ba);
    return float4(rgb, ba);
}

// ---- feTurbulence (mirrors turbulence_fill in filter_cpu.odin) -----------
//
// `tex` is the lattice image (turbulence_lattice_pixels): row 0 the
// permutation, row 1 + k channel k's gradients in 16-bit fixed point.
// Uniforms: see turbulence_uniforms in sdlgpu/render.odin. In f32 rather
// than the spec's f64: lattice indices are kept PerlinN (4096, a multiple
// of 256) lower than the spec's, so the cell fraction keeps f32 precision;
// the error is far below one 8-bit step. Octaves past
// TURBULENCE_MAX_OCTAVES (each adds under 2^-24) are skipped.

// Texel (x, y) of the lattice, sampled at its centre (slangc's MSL for
// Sampler2D.Load does not compile).
float4 lattice_texel(int x, int y) {
    return tex.SampleLevel(float2((float(x) + 0.5) / 256.0, (float(y) + 0.5) / 5.0), 0);
}

int lattice_select(int i) {
    return int(round(lattice_texel(i & 255, 0).x * 255.0));
}

float2 lattice_gradient(int k, int i) {
    float4 t = round(lattice_texel(i, k + 1) * 255.0);
    return float2(t.x * 256.0 + t.y, t.z * 256.0 + t.w) / 32767.5 - 1.0;
}

// The spec's noise2 for the four channels at lattice point v; st = stitch
// (width, height, wrap x, wrap y), wraps PerlinN lower too.
float4 noise2(float2 v, bool stitch, int4 st) {
    // The spec's int(v + PerlinN) truncates: floor above -PerlinN.
    float2 fi = float2(v.x >= -4096.0 ? floor(v.x) : ceil(v.x), v.y >= -4096.0 ? floor(v.y) : ceil(v.y));
    int2 b0 = int2(fi);
    int2 b1 = b0 + 1;
    float2 r0 = v - fi;
    float2 r1 = r0 - 1.0;
    if (stitch) {
        if (b0.x >= st.z) b0.x -= st.x;
        if (b1.x >= st.z) b1.x -= st.x;
        if (b0.y >= st.w) b0.y -= st.y;
        if (b1.y >= st.w) b1.y -= st.y;
    }
    b0 &= 255;
    b1 &= 255;
    int i = lattice_select(b0.x);
    int j = lattice_select(b1.x);
    int b00 = lattice_select(i + b0.y);
    int b10 = lattice_select(j + b0.y);
    int b01 = lattice_select(i + b1.y);
    int b11 = lattice_select(j + b1.y);
    float2 s = r0 * r0 * (3.0 - 2.0 * r0);
    float4 n;
    for (int k = 0; k < 4; k++) {
        float2 g = lattice_gradient(k, b00);
        float u = r0.x * g.x + r0.y * g.y;
        g = lattice_gradient(k, b10);
        float w = r1.x * g.x + r0.y * g.y;
        float a = u + s.x * (w - u);
        g = lattice_gradient(k, b01);
        u = r0.x * g.x + r1.y * g.y;
        g = lattice_gradient(k, b11);
        w = r1.x * g.x + r1.y * g.y;
        float b = u + s.x * (w - u);
        n[k] = a + s.y * (b - a);
    }
    return n;
}

float4 turbulence(int2 p) {
    float2 v = (float2(p) + P(0).xy) * P(0).zw;
    int octaves = int(P(1).x);
    bool fractal = P(1).y != 0.0;
    bool stitch = P(1).z != 0.0;
    int4 st = int4(0, 0, 0, 0);
    if (stitch) {
        // resvg passes the pixel's place in the region as the tile origin.
        int2 cells = int2(P(2).xy);
        st = int4(cells, cells + int2(floor((float2(p) - P(2).zw) * P(3).xy)));
    }
    float4 sum = float4(0, 0, 0, 0);
    float ratio = 1.0;
    for (int o = 0; o < TURBULENCE_MAX_OCTAVES; o++) {
        if (o >= octaves) break;
        float4 n = noise2(v, stitch, st);
        sum += (fractal ? n : abs(n)) / ratio;
        v *= 2.0;
        ratio *= 2.0;
        st *= 2;
    }
    float4 c = fractal ? (sum * 255.0 + 255.0) / 2.0 : sum * 255.0;
    c = floor(clamp(c, 0.0, 255.0) + 0.5);
    // Premultiplied as resvg's multiply_alpha.
    return float4(floor(c.xyz * (c.w / 255.0) + 0.5), c.w) / 255.0;
}

// The single-pass filters: full-target quads reading the source (`tex`)
// and, for two-input filters, the backdrop (`glyphtex`) at the same pixel.
float4 render_filter(int type, float2 fpos) {
    int2 p = int2(floor(fpos));
    if (type == FILTER_MORPHOLOGY) return morphology(p);
    if (type == FILTER_LIGHTING) return lighting(p);
    if (type == FILTER_TILE) return tile(p);
    if (type == FILTER_DISPLACEMENT) return displacement(p);
    if (type == FILTER_CONVOLVE) return convolve(p);
    if (type == FILTER_TURBULENCE) return turbulence(p);
    float2 uv = fpos / extent();
    float4 s = apply_tex_type(tex.SampleLevel(uv, 0));
    if (type == FILTER_COMPONENT_TRANSFER) {
        float4 us = unpremultiply(s);
        float4 o;
        for (int k = 0; k < 4; k++) {
            float idx = floor(clamp(us[k], 0.0, 1.0) * 255.0 + 0.5);
            o[k] = glyphtex.SampleLevel(float2((idx + 0.5) / 256.0, 0.5), 0)[k];
        }
        return premultiply(o);
    }
    if (type == FILTER_COLOR_MATRIX) {
        float4 us = unpremultiply(s);
        float4 o;
        for (int row = 0; row < 4; row++) {
            o[row] = clamp(dot(P(row), us) + P(4)[row], 0.0, 1.0);
        }
        return premultiply(o);
    }
    if (type == FILTER_COLOR_SPACE) {
        float4 us = unpremultiply(s);
        bool to_linear = filter_op() == 1;
        for (int k = 0; k < 3; k++) {
            us[k] = to_linear ? srgb_to_linear(us[k]) : linear_to_srgb(us[k]);
        }
        return premultiply(us);
    }
    float4 b = apply_tt(glyphtex.SampleLevel(uv, 0), backdrop_tex_type());
    if (type == FILTER_BLEND) return blend_pixel(filter_op(), s, b);
    return composite_pixel(filter_op(), P(4), s, b);
}

// The paint's color at `fpos` for the fill types (gradients, images,
// solid colors).
float4 fill_color(int type, float2 fpos) {
    if (type == FILL_GRADIENT) {
        return lerp(inner_col(), outer_col(), gradient_t(fpos));
    } else if (type == FILL_IMAGE_GRADIENT) {
        // The ramp is the stops; inner_col carries the paint's alpha.
        return tex.SampleLevel(float2(gradient_t(fpos), 0.0), 0) * inner_col();
    } else if (type == FILL_IMAGE) {
        float2 pt = transform_point(3, fpos) / extent();
        return apply_tex_type(tex.SampleLevel(pt, 0)) * inner_col();
    } else if (type == FILL_GRADIENT_CONIC) {
        return lerp(inner_col(), outer_col(), conic_fraction(fpos));
    } else if (type == FILL_IMAGE_GRADIENT_CONIC) {
        return tex.SampleLevel(float2(conic_fraction(fpos), 0.0), 0) * inner_col();
    }
    return inner_col();
}

[shader("fragment")]
float4 fs_main(VS_Out i) : SV_Target {
    paint_index = i.paint;
    int type = shader_type();
    if (type >= FILTER_COLOR_MATRIX) {
        return render_filter(type, i.fpos);
    }
    float stroke_alpha = 1.0;
    if (type != TEXTURE_COPY_UNCLIPPED) {
        stroke_alpha = stroke_mask(i.ftcoord);
        if (stroke_alpha < stroke_thr()) {
            discard;
        }
    }

    // Textures are sampled at level 0: there are no mipmaps, and no
    // derivatives are needed after the discard above.
    float4 result;
    if (type == TEXTURE_COPY_UNCLIPPED) {
        return apply_tex_type(tex.SampleLevel(i.ftcoord, 0)) * inner_col();
    } else if (type == STENCIL) {
        result = float4(1, 1, 1, 1);
    } else if (type == FILTER_IMAGE) {
        result = render_filtered_image(i.fpos);
    } else {
        result = fill_color(type, i.fpos);
    }

    float scissor = scissor_mask(i.fpos);
    int glyph = glyph_texture_type();
    if (glyph != 0) {
        float4 mask = glyphtex.SampleLevel(i.ftcoord, 0);
        if (glyph == 1) {
            mask = float4(mask.x);
        } else {
            result = float4(1, 1, 1, 1);
            mask = float4(mask.xyz * mask.w, mask.w);
        }
        result *= mask * scissor;
    } else if (type != STENCIL && type != FILTER_IMAGE) {
        result *= stroke_alpha * scissor;
    }
    return result;
}

// ---- shapes (ovg shape.odin) ------------------------------------------------
//
// A shape instance is a quad over the shape's bounds, grown by a pixel,
// whose fragments compute coverage from the shape's curves (Slug's
// algorithm; `shape_coverage` in shape.odin is the same steps). The
// instances and the shapes come from storage buffers: no vertex input.

// Shape units to drawing coordinates (m: a b c d; t.xy: translation),
// the shape units one pixel spans (t.zw), the shape's bounds, and its word
// offset in `shapes`, paint row and flags (bit 0: even-odd).
struct Shape_Instance {
    float4 m;
    float4 t;
    float4 bounds;
    uint4 data;
};

// Vertex uniform slot 1: the draw's first instance (x) and, when not 0,
// one more than the paint row every instance takes instead of its own (y:
// a run's coverage mask is drawn in white).
struct Shape_Draw {
    uint4 base;
};

// Metal: after the two vertex uniform buffers, [[buffer(2)]].
[[vk::binding(0, 0)]] StructuredBuffer<Shape_Instance> shape_instances : register(t2, space0);
[[vk::binding(1, 1)]] ConstantBuffer<Shape_Draw> shape_draw : register(b1, space1);
[[vk::binding(3, 2)]] StructuredBuffer<uint> shapes : register(t1, space2);

struct VS_Shape_Out {
    float4 position : SV_Position;
    // Shape units.
    float2 rc : TEXCOORD0;
    // Drawing coordinates.
    float2 fpos : TEXCOORD1;
    nointerpolation float2 epp : TEXCOORD2;
    nointerpolation uint4 data : TEXCOORD3;
};

[shader("vertex")]
VS_Shape_Out vs_shape(uint vid : SV_VertexID, uint iid : SV_InstanceID) {
    Shape_Instance s = shape_instances[shape_draw.base.x + iid];
    // Two triangles: (0,0) (1,0) (1,1), (0,0) (1,1) (0,1).
    uint k = vid % 6;
    float cx = (k == 1 || k == 2 || k == 4) ? 1.0 : 0.0;
    float cy = (k == 2 || k == 4 || k == 5) ? 1.0 : 0.0;
    float2 epp = s.t.zw;
    float2 rc = float2(lerp(s.bounds.x - epp.x, s.bounds.z + epp.x, cx), lerp(s.bounds.y - epp.y, s.bounds.w + epp.y, cy));
    float2 d = float2(s.m.x * rc.x + s.m.z * rc.y + s.t.x, s.m.y * rc.x + s.m.w * rc.y + s.t.y);
    VS_Shape_Out o;
    o.rc = rc;
    o.fpos = d;
    o.epp = epp;
    o.data = s.data;
    if (shape_draw.base.y != 0u) {
        o.data.y = shape_draw.base.y - 1u;
    }
    float2 p = d - view.size.zw;
    o.position = float4(2.0 * p.x / view.size.x - 1.0, 1.0 - 2.0 * p.y / view.size.y, 0, 1);
    return o;
}

[shader("fragment")]
float4 fs_shape(VS_Shape_Out i) : SV_Target {
    paint_index = i.data.y;
    float coverage = curves_coverage(shapes, i.data.x, i.rc, i.epp, (i.data.z & 1u) != 0u);
    if (coverage <= 0.0) {
        discard;
    }
    float4 result = fill_color(shader_type(), i.fpos);
    return result * (stroke_mask(float2(0.5, 1.0)) * scissor_mask(i.fpos) * coverage);
}
