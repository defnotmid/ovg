// The GPU twin of ovg's curves package (curves/curves.odin): Slug's
// per-pixel coverage (Eric Lengyel, JCGT 2017; reference shaders MIT, patent
// dedicated to the public domain) over a shape's 32-bit words in a storage
// buffer, the same steps in the same order. `words` holds any number of
// shapes; `s` is a shape's first word. The layout is documented in
// curves.odin. Include this file; it binds nothing.

float curves_f(StructuredBuffer<uint> words, uint i) { return asfloat(words[i]); }

// Which of a curve's two roots cross the ray: bit 0 the first, bit 8 the
// second.
uint curves_root_code(float y1, float y2, float y3) {
    uint i1 = asuint(y1) >> 31u;
    uint i2 = asuint(y2) >> 30u;
    uint i3 = asuint(y3) >> 29u;
    uint shift = (i2 & 2u) | (i1 & ~2u);
    shift = (i3 & 4u) | (shift & ~4u);
    return (0x2E74u >> shift) & 0x0101u;
}

// Roots of the curve (relative to the sample) on y = 0 (axis 1) or x = 0
// (axis 0): the other coordinate at each.
float2 curves_solve(float2 p1, float2 p2, float2 p3, int axis) {
    int other = 1 - axis;
    float2 a = p1 - p2 * 2.0 + p3;
    float2 b = p1 - p2;
    float ra = 1.0 / a[axis];
    float rb = 0.5 / b[axis];
    float d = sqrt(max(b[axis] * b[axis] - a[axis] * p1[axis], 0.0));
    float t1 = (b[axis] - d) * ra;
    float t2 = (b[axis] + d) * ra;
    if (abs(a[axis]) < 1.0 / 65536.0) {
        t1 = p1[axis] * rb;
        t2 = t1;
    }
    return float2((a[other] * t1 - b[other] * 2.0) * t1 + p1[other], (a[other] * t2 - b[other] * 2.0) * t2 + p1[other]);
}

// Coverage of the pixel centered at `rc` (shape units), the pixel spanning
// `footprint` shape units along each axis (fwidth(rc), or curves_footprint).
float curves_coverage(StructuredBuffer<uint> words, uint s, float2 rc, float2 footprint, bool even_odd) {
    float2 ppe = 1.0 / footprint;
    int h_count = int(words[s]);
    int v_count = int(words[s + 1]);
    float2 scale = float2(curves_f(words, s + 2), curves_f(words, s + 3));
    float2 offset = float2(curves_f(words, s + 4), curves_f(words, s + 5));
    int bx = clamp(int(rc.x * scale.x + offset.x), 0, v_count - 1);
    int by = clamp(int(rc.y * scale.y + offset.y), 0, h_count - 1);
    uint curves = s + words[s + 6];

    float xcov = 0.0;
    float xwgt = 0.0;
    uint hb = s + 12 + 2 * uint(by);
    uint list = s + words[hb + 1];
    uint count = words[hb];
    for (uint k = 0; k < count; k++) {
        uint c = curves + 6 * words[list + k];
        float2 p1 = float2(curves_f(words, c), curves_f(words, c + 1)) - rc;
        float2 p2 = float2(curves_f(words, c + 2), curves_f(words, c + 3)) - rc;
        float2 p3 = float2(curves_f(words, c + 4), curves_f(words, c + 5)) - rc;
        if (max(max(p1.x, p2.x), p3.x) * ppe.x < -0.5) break;
        uint code = curves_root_code(p1.y, p2.y, p3.y);
        if (code != 0u) {
            float2 r = curves_solve(p1, p2, p3, 1) * ppe.x;
            if ((code & 1u) != 0u) {
                xcov += clamp(r.x + 0.5, 0.0, 1.0);
                xwgt = max(xwgt, clamp(1.0 - abs(r.x) * 2.0, 0.0, 1.0));
            }
            if (code > 1u) {
                xcov -= clamp(r.y + 0.5, 0.0, 1.0);
                xwgt = max(xwgt, clamp(1.0 - abs(r.y) * 2.0, 0.0, 1.0));
            }
        }
    }

    float ycov = 0.0;
    float ywgt = 0.0;
    uint vb = s + 12 + 2 * uint(h_count + bx);
    list = s + words[vb + 1];
    count = words[vb];
    for (uint k = 0; k < count; k++) {
        uint c = curves + 6 * words[list + k];
        float2 p1 = float2(curves_f(words, c), curves_f(words, c + 1)) - rc;
        float2 p2 = float2(curves_f(words, c + 2), curves_f(words, c + 3)) - rc;
        float2 p3 = float2(curves_f(words, c + 4), curves_f(words, c + 5)) - rc;
        if (max(max(p1.y, p2.y), p3.y) * ppe.y < -0.5) break;
        uint code = curves_root_code(p1.x, p2.x, p3.x);
        if (code != 0u) {
            float2 r = curves_solve(p1, p2, p3, 0) * ppe.y;
            if ((code & 1u) != 0u) {
                ycov -= clamp(r.x + 0.5, 0.0, 1.0);
                ywgt = max(ywgt, clamp(1.0 - abs(r.x) * 2.0, 0.0, 1.0));
            }
            if (code > 1u) {
                ycov += clamp(r.y + 0.5, 0.0, 1.0);
                ywgt = max(ywgt, clamp(1.0 - abs(r.y) * 2.0, 0.0, 1.0));
            }
        }
    }

    float cov = max(abs(xcov * xwgt + ycov * ywgt) / max(xwgt + ywgt, 1.0 / 65536.0), min(abs(xcov), abs(ycov)));
    if (even_odd) {
        return 1.0 - abs(1.0 - (cov * 0.5 - floor(cov * 0.5)) * 2.0);
    }
    return clamp(cov, 0.0, 1.0);
}

// The per-axis footprint from the shape coordinate's screen derivatives
// (ddx(rc), ddy(rc)): fwidth. Exact for scales; see curves.footprint_of
// for rotation and grazing angles.
float2 curves_footprint(float2 dx, float2 dy) {
    return abs(dx) + abs(dy);
}

// The fraction of the bounds the shape fills (non-zero rule).
float curves_mean_coverage(StructuredBuffer<uint> words, uint s) {
    return curves_f(words, s + 7);
}

// `cov` blended toward the mean coverage as the footprint grows from half
// the shape's size to all of it.
float curves_fade(StructuredBuffer<uint> words, uint s, float cov, float2 footprint) {
    float2 size = float2(curves_f(words, s + 10), curves_f(words, s + 11));
    float k = max(footprint.x / max(size.x, 1e-6), footprint.y / max(size.y, 1e-6));
    return lerp(cov, curves_mean_coverage(words, s), clamp(2.0 * k - 1.0, 0.0, 1.0));
}

// The winding number at `p` (shape units): signed crossings of the ray
// toward +x (non-zero: != 0; even-odd: odd). For sample masks.
int curves_winding(StructuredBuffer<uint> words, uint s, float2 p) {
    int h_count = int(words[s]);
    int by = clamp(int(p.y * curves_f(words, s + 3) + curves_f(words, s + 5)), 0, h_count - 1);
    uint curves = s + words[s + 6];
    uint hb = s + 12 + 2 * uint(by);
    uint list = s + words[hb + 1];
    uint count = words[hb];
    int w = 0;
    for (uint k = 0; k < count; k++) {
        uint c = curves + 6 * words[list + k];
        float2 p1 = float2(curves_f(words, c), curves_f(words, c + 1)) - p;
        float2 p2 = float2(curves_f(words, c + 2), curves_f(words, c + 3)) - p;
        float2 p3 = float2(curves_f(words, c + 4), curves_f(words, c + 5)) - p;
        if (max(max(p1.x, p2.x), p3.x) < 0.0) break;
        uint code = curves_root_code(p1.y, p2.y, p3.y);
        if (code != 0u) {
            float2 r = curves_solve(p1, p2, p3, 1);
            if ((code & 1u) != 0u && r.x > 0.0) w += 1;
            if (code > 1u && r.y > 0.0) w -= 1;
        }
    }
    return w;
}
