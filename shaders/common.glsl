// What every fragment shader of ovg's SDL_GPU backend shares, in GLSL ES 3.0
// as oksl compiles it: the paints and the paint's colour. The backend
// compiles each unit with this ahead of it (oksl's Options.prelude); the
// math must stay identical to the software backend's.
//
// A draw's paint is a row of `paints` (ovg.Params packed as 14 vec4s by
// ovg.pack_frag_uniforms), so draws with different paints share one draw
// call. SDL_GPU binds a fragment shader's samplers, then its storage
// buffers, in declaration order: `tex`, `glyphtex`, then `paints` and the
// shape units' buffers (shapes.glsl).

const int FILL_GRADIENT = 0;
const int FILL_IMAGE = 1;
const int FILL_IMAGE_GRADIENT = 3;
const int FILTER_IMAGE = 4;
const int FILL_COLOR = 5;
const int TEXTURE_COPY_UNCLIPPED = 6;
const int FILL_GRADIENT_CONIC = 8;
const int FILL_IMAGE_GRADIENT_CONIC = 9;
const int FILTER_COLOR_MATRIX = 10;
const int FILTER_BLEND = 11;
const int FILTER_COMPOSITE = 12;
const int FILTER_COLOR_SPACE = 13;
const int FILTER_COMPONENT_TRANSFER = 14;
const int FILTER_MORPHOLOGY = 15;
const int FILTER_LIGHTING = 16;
const int FILTER_TILE = 17;
const int FILTER_DISPLACEMENT = 18;
const int FILTER_CONVOLVE = 19;
const int FILTER_TURBULENCE = 20;
const int FILTER_BLOOM_BRIGHT = 21;
const int FILTER_BLOOM_ADD = 22;

const float TAU = 6.28318530717958647692528676655900577;

uniform sampler2D tex;
uniform sampler2D glyphtex;

layout(std430) readonly buffer Paints { vec4 rows[]; } paints;

// The fragment's paint row (set by each unit's main).
uint paint_index;

vec4 P(int i) { return paints.rows[paint_index * 14u + uint(i)]; }

// `mat3(P(base).xyz, P(base + 1).xyz, P(base + 2).xyz) * vec3(p, 1)`.
vec2 transform_point(int base, vec2 p) {
    return (P(base).xyz * p.x + P(base + 1).xyz * p.y + P(base + 2).xyz).xy;
}

vec4 inner_col() { return P(6); }
vec4 outer_col() { return P(7); }
vec2 scissor_ext() { return P(8).xy; }
vec2 scissor_scale() { return P(8).zw; }
vec2 extent() { return P(9).xy; }
float radius() { return P(9).z; }
float feather() { return P(9).w; }
float stroke_mult() { return P(10).x; }
float stroke_thr() { return P(10).y; }
int tex_type() { return int(P(10).z); }
int shader_type() { return int(P(10).w); }

float sd_round_rect(vec2 pt, vec2 ext, float rad) {
    vec2 ext2 = ext - vec2(rad, rad);
    vec2 d = abs(pt) - ext2;
    return min(max(d.x, d.y), 0.0) + length(max(d, 0.0)) - rad;
}

float scissor_mask(vec2 p) {
    vec2 sc = abs(transform_point(0, p)) - scissor_ext();
    sc = vec2(0.5, 0.5) - sc * scissor_scale();
    return clamp(sc.x, 0.0, 1.0) * clamp(sc.y, 0.0, 1.0);
}

// Coverage from the vertex (u, v): a pyramid across the stroke with a
// one-pixel slope, times the edge fade in v.
float stroke_mask(vec2 ftcoord) {
    return min(1.0, (1.0 - abs(ftcoord.x * 2.0 - 1.0)) * stroke_mult()) * min(1.0, ftcoord.y);
}

vec4 apply_tt(vec4 color, int tt) {
    if (tt == 1) return vec4(color.xyz * color.w, color.w);
    if (tt == 2) return vec4(color.x);
    return color;
}

vec4 apply_tex_type(vec4 color) {
    return apply_tt(color, tex_type());
}

// SVG spreadMethod: 0 pad, 1 reflect, 2 repeat.
float spread_t(float t) {
    int s = int(P(13).x);
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
float focal_t(vec2 pt) {
    float r = extent().x;
    float fr = extent().y;
    vec2 f = P(13).zw;
    vec2 cd = -f;
    float dr = r - fr;
    vec2 pd = pt - f;
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

float gradient_t(vec2 fpos) {
    vec2 pt = transform_point(3, fpos);
    if (P(13).y != 0.0) return spread_t(focal_t(pt));
    return spread_t((sd_round_rect(pt, extent(), radius()) + feather() * 0.5) / feather());
}

float conic_fraction(vec2 fpos) {
    vec2 pt = transform_point(3, fpos);
    return (-atan(pt.x, pt.y) / TAU) + 0.5;
}

// The paint's colour at `fpos` for the fill types (gradients, images, solid
// colours). Textures are sampled at level 0: there are no mipmaps.
vec4 fill_color(int type, vec2 fpos) {
    if (type == FILL_GRADIENT) {
        return mix(inner_col(), outer_col(), gradient_t(fpos));
    } else if (type == FILL_IMAGE_GRADIENT) {
        // The ramp is the stops; inner_col carries the paint's alpha.
        return textureLod(tex, vec2(gradient_t(fpos), 0.0), 0.0) * inner_col();
    } else if (type == FILL_IMAGE) {
        vec2 pt = transform_point(3, fpos) / extent();
        return apply_tex_type(textureLod(tex, pt, 0.0)) * inner_col();
    } else if (type == FILL_GRADIENT_CONIC) {
        return mix(inner_col(), outer_col(), conic_fraction(fpos));
    } else if (type == FILL_IMAGE_GRADIENT_CONIC) {
        return textureLod(tex, vec2(conic_fraction(fpos), 0.0), 0.0) * inner_col();
    }
    return inner_col();
}

// A layer's or a group's motion `g` (a twin pixel), faded by `opacity` and
// cut to the coverage `a` it composites with where that is less (a clip or
// mask): what it adds to the twin (premultiplied source-over).
vec4 twin_composite(vec4 g, float a, float opacity) {
    return g * (g.a > a ? opacity * a / g.a : opacity);
}
