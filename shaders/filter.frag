// Image filters, after common.glsl: full-target quads reading the source
// (`tex`) and, for two-input filters, the backdrop (`glyphtex`) at the same
// pixel, in passes of their own so that the shader every draw uses doesn't
// carry them. Mirrors filter_math.odin and the software backend.

const int TURBULENCE_MAX_OCTAVES = 24;
const int MORPHOLOGY_MAX_RADIUS = 256;
const int CONVOLVE_MAX_KERNEL = 36;
const int BLUR_MAX_TAPS = 24;

layout(location = 0) in vec2 ftcoord;
layout(location = 1) in vec2 fpos;
layout(location = 2) flat in uint fpaint;

layout(location = 0) out vec4 color;

vec2 blur_direction() { return P(11).yz; }
int blur_taps() { return int(P(11).w); }
vec3 blur_coeff() { return P(12).xyz; }
int blur_edge() { return int(P(12).w); }
// The operation (blend mode, composite operator, colour space direction)
// and the second input's tex type.
int filter_op() { return int(P(9).z); }
int backdrop_tex_type() { return int(P(13).x); }

// One blur tap at pixel position `p` of an `ext`-sized image: transparent
// beyond it, or the nearest edge pixel (`clamp_edge`).
vec4 blur_tap(vec2 p, vec2 ext, bool clamp_edge) {
    if (clamp_edge) {
        p = clamp(p, vec2(0.5, 0.5), ext - 0.5);
    } else if (p.x < 0.0 || p.y < 0.0 || p.x > ext.x || p.y > ext.y) {
        return vec4(0.0);
    }
    return textureLod(tex, p / ext, 0.0);
}

// One direction of a separable gaussian with incremental coefficients.
vec4 render_filtered_image(vec2 p) {
    vec2 ext = extent();
    bool clamp_edge = blur_edge() == 1;
    vec2 dir = blur_direction();
    int taps = blur_taps();
    vec3 coeff = blur_coeff();
    vec4 color_sum = textureLod(tex, p / ext, 0.0) * coeff.x;
    float coeff_sum = coeff.x;
    coeff.xy *= coeff.yz;
    for (int i = 1; i <= BLUR_MAX_TAPS; i++) {
        if (i > taps) {
            break;
        }
        vec2 d = float(i) * dir;
        color_sum += blur_tap(p - d, ext, clamp_edge) * coeff.x;
        color_sum += blur_tap(p + d, ext, clamp_edge) * coeff.x;
        coeff_sum += 2.0 * coeff.x;
        coeff.xy *= coeff.yz;
    }
    return apply_tex_type(color_sum / coeff_sum);
}

vec4 unpremultiply(vec4 c) {
    if (c.w <= 0.0) return vec4(0.0);
    return vec4(c.xyz / c.w, c.w);
}

vec4 premultiply(vec4 c) {
    return vec4(c.xyz * c.w, c.w);
}

float srgb_to_linear(float v) {
    return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4);
}

float linear_to_srgb(float v) {
    return v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1.0 / 2.4) - 0.055;
}

float lum(vec3 c) {
    return 0.3 * c.x + 0.59 * c.y + 0.11 * c.z;
}

vec3 clip_color(vec3 c) {
    float l = lum(c);
    float n = min(c.x, min(c.y, c.z));
    float x = max(c.x, max(c.y, c.z));
    if (n < 0.0 && l - n > 0.0) c = l + (c - l) * l / (l - n);
    if (x > 1.0 && x - l > 0.0) c = l + (c - l) * (1.0 - l) / (x - l);
    return c;
}

vec3 set_lum(vec3 c, float l) {
    return clip_color(c + (l - lum(c)));
}

float sat(vec3 c) {
    return max(c.x, max(c.y, c.z)) - min(c.x, min(c.y, c.z));
}

vec3 set_sat(vec3 c, float s) {
    float lo = min(c.x, min(c.y, c.z));
    float hi = max(c.x, max(c.y, c.z));
    if (hi <= lo) return vec3(0.0);
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

vec3 blend_function(int mode, vec3 cb, vec3 cs) {
    if (mode == 12) return set_lum(set_sat(cs, sat(cb)), lum(cb));
    if (mode == 13) return set_lum(set_sat(cb, sat(cs)), lum(cb));
    if (mode == 14) return set_lum(cs, lum(cb));
    if (mode == 15) return set_lum(cb, lum(cs));
    return vec3(blend_channel(mode, cb.x, cs.x), blend_channel(mode, cb.y, cs.y), blend_channel(mode, cb.z, cs.z));
}

vec4 blend_pixel(int mode, vec4 s, vec4 b) {
    vec4 us = unpremultiply(s);
    vec4 ub = unpremultiply(b);
    vec3 f = blend_function(mode, ub.xyz, us.xyz);
    vec3 rgb = s.xyz * (1.0 - b.w) + b.xyz * (1.0 - s.w) + f * (s.w * b.w);
    float a = s.w + b.w - s.w * b.w;
    return clamp(vec4(rgb, a), 0.0, 1.0);
}

vec4 composite_pixel(int op, vec4 k, vec4 i1, vec4 i2) {
    vec4 o;
    if (op == 0) o = i1 + i2 * (1.0 - i1.w);
    else if (op == 1) o = i1 * i2.w;
    else if (op == 2) o = i1 * (1.0 - i2.w);
    else if (op == 3) o = i1 * i2.w + i2 * (1.0 - i1.w);
    else if (op == 4) o = i1 * (1.0 - i2.w) + i2 * (1.0 - i1.w);
    else if (op == 5) o = i1 + i2;
    else o = i1 * i2 * k.x + i1 * k.y + i2 * k.z + k.w;
    float a = clamp(o.w, 0.0, 1.0);
    return vec4(clamp(o.xyz, 0.0, a), a);
}

// ---- neighbourhood filters (mirror backend_software.odin) -------------------
//
// Uniforms: the valid rectangle (x0, y0, x1, y1) in P(9).zw, P(10).xy; per
// filter parameters in P(0..8), P(11), P(12).

vec4 valid_rect() { return vec4(P(9).zw, P(10).xy); }

// The source's pixel p (premultiplied), transparent beyond the image.
vec4 texel(ivec2 p) {
    vec2 ext = extent();
    if (p.x < 0 || p.y < 0 || float(p.x) >= ext.x || float(p.y) >= ext.y) return vec4(0.0);
    return apply_tex_type(textureLod(tex, (vec2(p) + 0.5) / ext, 0.0));
}

vec4 backdrop_texel(ivec2 p) {
    vec2 ext = extent();
    if (p.x < 0 || p.y < 0 || float(p.x) >= ext.x || float(p.y) >= ext.y) return vec4(0.0);
    return apply_tt(textureLod(glyphtex, (vec2(p) + 0.5) / ext, 0.0), backdrop_tex_type());
}

float floor_round(float v) {
    return floor(abs(v) + 0.5) * (v >= 0.0 ? 1.0 : -1.0);
}

vec4 morphology(ivec2 p) {
    float rf = clamp(P(0).x, 0.0, float(MORPHOLOGY_MAX_RADIUS));
    int r = int(rf);
    float frac = rf - float(r);
    bool dilate = P(0).y != 0.0;
    int axis = int(P(0).z);
    vec4 vr = valid_rect();
    int c = axis == 0 ? p.x : p.y;
    int lo = int(axis == 0 ? vr.x : vr.y);
    int hi = int(axis == 0 ? vr.z : vr.w) - 1;
    int t0 = max(c - r, lo);
    int t1 = min(c + r, hi);
    if (t0 > t1) return vec4(0.0);
    vec4 acc = dilate ? vec4(0.0) : vec4(1.0);
    for (int i = 0; i <= 2 * MORPHOLOGY_MAX_RADIUS; i++) {
        int t = t0 + i;
        if (t > t1) break;
        vec4 v = texel(axis == 0 ? ivec2(t, p.y) : ivec2(p.x, t));
        acc = dilate ? max(acc, v) : min(acc, v);
    }
    if (frac > 0.0) {
        vec4 ring = acc;
        for (int s = -1; s <= 1; s += 2) {
            int t = c + s * (r + 1);
            if (t < lo || t > hi) continue;
            vec4 v = texel(axis == 0 ? ivec2(t, p.y) : ivec2(p.x, t));
            ring = dilate ? max(ring, v) : min(ring, v);
        }
        acc = mix(acc, ring, frac);
    }
    return acc;
}

// Mirrors `lighting_gradient` / `lighting_pixel` in filter_math.odin; `a`
// is the 3 x 3 alpha neighbourhood, row by row.
vec4 lighting(ivec2 p) {
    vec4 vr = valid_rect();
    vec2 fp = vec2(p);
    bool left = fp.x - 1.0 >= vr.x;
    bool right = fp.x + 1.0 < vr.z;
    bool up = fp.y - 1.0 >= vr.y;
    bool down = fp.y + 1.0 < vr.w;
    float a[9];
    for (int j = 0; j < 3; j++) {
        for (int i = 0; i < 3; i++) {
            a[j * 3 + i] = texel(p + ivec2(i - 1, j - 1)).w;
        }
    }
    int xl = left ? 0 : 1;
    int xr = right ? 2 : 1;
    int yu = up ? 0 : 1;
    int yd = down ? 2 : 1;
    vec2 g = vec2(0.0);
    if (xr > xl) {
        float sum = 0.0;
        float weight = 0.0;
        for (int row = yu; row <= yd; row++) {
            float w = row == 1 ? 2.0 : 1.0;
            sum += w * (a[row * 3 + xr] - a[row * 3 + xl]);
            weight += w;
        }
        g.x = sum / weight * 2.0 / float(xr - xl);
    }
    if (yd > yu) {
        float sum = 0.0;
        float weight = 0.0;
        for (int col = xl; col <= xr; col++) {
            float w = col == 1 ? 2.0 : 1.0;
            sum += w * (a[yd * 3 + col] - a[yu * 3 + col]);
            weight += w;
        }
        g.y = sum / weight * 2.0 / float(yd - yu);
    }
    float surface_scale = P(0).w;
    bool specular = P(1).x != 0.0;
    int kind = int(P(1).y);
    float constant_ = P(1).z;
    float spec_exp = P(1).w;
    vec3 position = P(2).xyz;
    vec3 n = vec3(-g.x * surface_scale, -g.y * surface_scale, 1.0);
    vec3 lv = position;
    if (kind != 0) {
        vec3 v = position - vec3(fp, a[4] * surface_scale);
        float len_v = length(v);
        lv = len_v > 0.0 ? v / len_v : v;
    }
    vec3 light = P(0).xyz * 255.0;
    if (kind == 2) {
        vec3 s = P(3).xyz - position;
        float len_s = length(s);
        if (len_s > 0.0) s /= len_s;
        float minus_l_dot_s = -dot(lv, s);
        if (minus_l_dot_s <= 0.0 || minus_l_dot_s < P(3).w) {
            light = vec3(0.0);
        } else {
            float f = pow(minus_l_dot_s, P(2).w);
            light = floor(clamp(light * f, 0.0, 255.0) + 0.5);
        }
    }
    float len_n = length(n);
    float factor = 0.0;
    if (!specular) {
        factor = constant_ * dot(n, lv) / len_n;
    } else {
        vec3 h = lv + vec3(0.0, 0.0, 1.0);
        float len_h = length(h);
        if (len_h > 0.0) {
            float n_dot_h = dot(n, h) / len_n / len_h;
            if (spec_exp != 1.0) n_dot_h = pow(max(n_dot_h, 0.0), spec_exp);
            factor = constant_ * n_dot_h;
        }
    }
    vec3 rgb = floor(clamp(light * factor, 0.0, 255.0) + 0.5) / 255.0;
    return vec4(rgb, specular ? max(rgb.x, max(rgb.y, rgb.z)) : 1.0);
}

vec4 tile(ivec2 p) {
    ivec4 r = ivec4(round(P(0)));
    if (r.z < 1 || r.w < 1) return vec4(0.0);
    int tx = ((p.x - r.x) % r.z + r.z) % r.z;
    int ty = ((p.y - r.y) % r.w + r.w) % r.w;
    return texel(ivec2(r.x + tx, r.y + ty));
}

vec4 displacement(ivec2 p) {
    vec4 m = backdrop_texel(p);
    vec2 d = vec2(m[int(P(0).z) & 3], m[int(P(0).w) & 3]) - 0.5;
    vec2 o = vec2(floor_round(float(p.x) + d.x * P(0).x), floor_round(float(p.y) + d.y * P(0).y));
    vec4 vr = valid_rect();
    if (o.x >= vr.x && o.y >= vr.y && o.x < vr.z && o.y < vr.w) return texel(ivec2(o));
    return vec4(0.0);
}

vec4 convolve(ivec2 p) {
    vec4 vrf = valid_rect();
    ivec4 vr = ivec4(vrf);
    int vw = vr.z - vr.x;
    int vh = vr.w - vr.y;
    if (vw <= 0 || vh <= 0) return vec4(0.0);
    ivec2 order = ivec2(P(11).xy);
    ivec2 target = ivec2(P(11).zw);
    float divisor = P(12).x;
    float bias = P(12).y;
    int edge = int(P(12).z);
    bool preserve = P(12).w != 0.0;
    vec4 sum = vec4(0.0);
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
        vec4 c = texel(ivec2(tx, ty));
        sum += (preserve ? unpremultiply(c) : c) * k;
    }
    float src_a = texel(p).w;
    float a = preserve ? src_a : sum.w / divisor + bias;
    float ba = clamp(a, 0.0, 1.0);
    vec3 c = sum.xyz / divisor + bias * a;
    vec3 rgb = preserve ? clamp(c, 0.0, 1.0) * ba : clamp(c, 0.0, ba);
    return vec4(rgb, ba);
}

// ---- feTurbulence (mirrors turbulence_fill in filter_cpu.odin) --------------
//
// `tex` is the lattice image (turbulence_lattice_pixels): row 0 the
// permutation, row 1 + k channel k's gradients in 16-bit fixed point.
// Uniforms: see turbulence_uniforms in sdlgpu/render.odin. In f32 rather
// than the spec's f64: lattice indices are kept PerlinN (4096, a multiple
// of 256) lower than the spec's, so the cell fraction keeps f32 precision;
// the error is far below one 8-bit step. Octaves past
// TURBULENCE_MAX_OCTAVES (each adds under 2^-24) are skipped.

// Texel (x, y) of the lattice, sampled at its centre.
vec4 lattice_texel(int x, int y) {
    return textureLod(tex, vec2((float(x) + 0.5) / 256.0, (float(y) + 0.5) / 5.0), 0.0);
}

int lattice_select(int i) {
    return int(round(lattice_texel(i & 255, 0).x * 255.0));
}

vec2 lattice_gradient(int k, int i) {
    vec4 t = round(lattice_texel(i, k + 1) * 255.0);
    return vec2(t.x * 256.0 + t.y, t.z * 256.0 + t.w) / 32767.5 - 1.0;
}

// The spec's noise2 for the four channels at lattice point v; st = stitch
// (width, height, wrap x, wrap y), wraps PerlinN lower too.
vec4 noise2(vec2 v, bool stitch, ivec4 st) {
    // The spec's int(v + PerlinN) truncates: floor above -PerlinN.
    vec2 fi = vec2(v.x >= -4096.0 ? floor(v.x) : ceil(v.x), v.y >= -4096.0 ? floor(v.y) : ceil(v.y));
    ivec2 b0 = ivec2(fi);
    ivec2 b1 = b0 + 1;
    vec2 r0 = v - fi;
    vec2 r1 = r0 - 1.0;
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
    vec2 s = r0 * r0 * (3.0 - 2.0 * r0);
    vec4 n;
    for (int k = 0; k < 4; k++) {
        vec2 g = lattice_gradient(k, b00);
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

vec4 turbulence(ivec2 p) {
    vec2 v = (vec2(p) + P(0).xy) * P(0).zw;
    int octaves = int(P(1).x);
    bool fractal = P(1).y != 0.0;
    bool stitch = P(1).z != 0.0;
    ivec4 st = ivec4(0);
    if (stitch) {
        // resvg passes the pixel's place in the region as the tile origin.
        ivec2 cells = ivec2(P(2).xy);
        st = ivec4(cells, cells + ivec2(floor((vec2(p) - P(2).zw) * P(3).xy)));
    }
    vec4 sum = vec4(0.0);
    float ratio = 1.0;
    for (int o = 0; o < TURBULENCE_MAX_OCTAVES; o++) {
        if (o >= octaves) break;
        vec4 n = noise2(v, stitch, st);
        sum += (fractal ? n : abs(n)) / ratio;
        v *= 2.0;
        ratio *= 2.0;
        st *= 2;
    }
    vec4 c = fractal ? (sum * 255.0 + 255.0) / 2.0 : sum * 255.0;
    if (P(3).z != 0.0) {
        // An RGBA16F target: the noise unrounded, premultiplied.
        c = clamp(c, 0.0, 255.0) / 255.0;
        return vec4(c.xyz * c.w, c.w);
    }
    c = floor(clamp(c, 0.0, 255.0) + 0.5);
    // Premultiplied as resvg's multiply_alpha.
    return vec4(floor(c.xyz * (c.w / 255.0) + 0.5), c.w) / 255.0;
}

vec4 space_converted(vec4 s, bool to_linear) {
    vec4 us = unpremultiply(s);
    for (int k = 0; k < 3; k++) {
        us[k] = to_linear ? srgb_to_linear(us[k]) : linear_to_srgb(us[k]);
    }
    return premultiply(us);
}

// Bloom (layer_bloom_into): one source pixel's light above the threshold,
// at half the source's size four of them averaged; P(0): the threshold,
// whether the source is encoded, its size.
vec4 bloom_above(ivec2 q) {
    vec4 c = apply_tex_type(textureLod(tex, (vec2(q) + 0.5) / P(0).zw, 0.0));
    if (P(0).y != 0.0) {
        c = space_converted(c, true);
    }
    return max(c - P(0).x, vec4(0.0));
}

vec4 bloom_bright(ivec2 p) {
    ivec2 a = p * 2;
    ivec2 b = min(a + 1, ivec2(P(0).zw) - 1);
    return (bloom_above(a) + bloom_above(ivec2(b.x, a.y)) + bloom_above(ivec2(a.x, b.y)) + bloom_above(b)) * 0.25;
}

vec4 render_filter(int type, vec2 p) {
    ivec2 ip = ivec2(floor(p));
    if (type == FILTER_MORPHOLOGY) return morphology(ip);
    if (type == FILTER_LIGHTING) return lighting(ip);
    if (type == FILTER_TILE) return tile(ip);
    if (type == FILTER_DISPLACEMENT) return displacement(ip);
    if (type == FILTER_CONVOLVE) return convolve(ip);
    if (type == FILTER_TURBULENCE) return turbulence(ip);
    if (type == FILTER_BLOOM_BRIGHT) return bloom_bright(ip);
    vec2 uv = p / extent();
    vec4 s = apply_tex_type(textureLod(tex, uv, 0.0));
    if (type == FILTER_BLOOM_ADD) {
        // P(0): where the glow is read; P(1): how much, whether encoded.
        vec4 glow = apply_tt(textureLod(glyphtex, p * P(0).xy + P(0).zw, 0.0), backdrop_tex_type());
        bool encoded = P(1).y != 0.0;
        vec4 o = (encoded ? space_converted(s, true) : s) + glow * P(1).x;
        float a = clamp(o.a, 0.0, 1.0);
        o = vec4(clamp(o.rgb, vec3(0.0), vec3(a)), a);
        return encoded ? space_converted(o, false) : o;
    }
    if (type == FILTER_COMPONENT_TRANSFER) {
        vec4 us = unpremultiply(s);
        vec4 o;
        for (int k = 0; k < 4; k++) {
            float idx = floor(clamp(us[k], 0.0, 1.0) * 255.0 + 0.5);
            o[k] = textureLod(glyphtex, vec2((idx + 0.5) / 256.0, 0.5), 0.0)[k];
        }
        return premultiply(o);
    }
    if (type == FILTER_COLOR_MATRIX) {
        vec4 us = unpremultiply(s);
        vec4 o;
        for (int row = 0; row < 4; row++) {
            o[row] = clamp(dot(P(row), us) + P(4)[row], 0.0, 1.0);
        }
        return premultiply(o);
    }
    if (type == FILTER_COLOR_SPACE) {
        return space_converted(s, filter_op() == 1);
    }
    vec4 b = apply_tt(textureLod(glyphtex, uv, 0.0), backdrop_tex_type());
    if (type == FILTER_BLEND) return blend_pixel(filter_op(), s, b);
    return composite_pixel(filter_op(), P(4), s, b);
}

void main() {
    paint_index = fpaint;
    int type = shader_type();
    color = type == FILTER_IMAGE ? render_filtered_image(fpos) : render_filter(type, fpos);
}
