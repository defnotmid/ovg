// The GPU twin of ovg's curves package (curves/curves.odin): exact
// coverage of a pixel's footprint box by a shape's monotone quadratic curves
// in horizontal bands (the bands are Eric Lengyel's Slug, JCGT 2017; MIT,
// patent public domain), the same steps in the same order. `words` holds any number of shapes;
// `s` is a shape's first word. The layout is documented in curves.odin.
// Include this file; it binds nothing.

float curves_f(StructuredBuffer<uint> words, uint i) { return asfloat(words[i]); }

float2 curves_point(StructuredBuffer<uint> words, uint c, float2 rc) {
    return float2(curves_f(words, c), curves_f(words, c + 1)) - rc;
}

int curves_band_of(StructuredBuffer<uint> words, uint s, float y) {
    return clamp(int(y * curves_f(words, s + 3) + curves_f(words, s + 5)), 0, int(words[s]) - 1);
}

// The rows of `band` it answers for, clipped to [y0, y1] (relative to ry).
float2 curves_band_rows(StructuredBuffer<uint> words, uint s, int band, float ry, float y0, float y1) {
    float scale = curves_f(words, s + 3);
    float offset = curves_f(words, s + 5);
    float lo = band == 0 ? y0 : max(y0, (float(band) - offset) / scale - ry);
    float hi = band == int(words[s]) - 1 ? y1 : min(y1, (float(band + 1) - offset) / scale - ry);
    return float2(lo, hi);
}

// t in [0, 1] where a t^2 + b t + c = v, for a coordinate monotone on
// [0, 1].
float curves_solve_monotone(float a, float b, float c, float v) {
    float cc = c - v;
    if (abs(a) <= 1e-7 * abs(b)) {
        return clamp(-cc / b, 0.0, 1.0);
    }
    float d = sqrt(max(b * b - 4.0 * a * cc, 0.0));
    float q = -0.5 * (b + (b >= 0.0 ? d : -d));
    float t1 = q / a;
    float t2 = q != 0.0 ? cc / q : t1;
    float e1 = max(max(-t1, t1 - 1.0), 0.0);
    float e2 = max(max(-t2, t2 - 1.0), 0.0);
    return clamp(e1 <= e2 ? t1 : t2, 0.0, 1.0);
}

// The integral over [t0, t1] of g(t) y'(t), g = gp t^2 + gq t + gr, y' = 2 yd t + ye.
float curves_area_term(float gp, float gq, float gr, float yd, float ye, float t0, float t1) {
    float k3 = gp * yd * 0.5;
    float k2 = (gp * ye + 2.0 * gq * yd) / 3.0;
    float k1 = (gq * ye + 2.0 * gr * yd) * 0.5;
    float k0 = gr * ye;
    float g1 = ((k3 * t1 + k2) * t1 + k1) * t1 * t1 + k0 * t1;
    float g0 = ((k3 * t0 + k2) * t0 + k1) * t0 * t0 + k0 * t0;
    return g1 - g0;
}

float curves_fill(float area, bool even_odd) {
    float cov = abs(area);
    if (even_odd) {
        return 1.0 - abs(1.0 - (cov * 0.5 - floor(cov * 0.5)) * 2.0);
    }
    return min(cov, 1.0);
}

// A curve as polynomials: x(t) = A t^2 + B t + C, y(t) = D t^2 + E t + F.
struct Curves_Quadratic {
    float A, B, C, D, E, F;
};

Curves_Quadratic curves_quadratic(float2 p1, float2 p2, float2 p3) {
    Curves_Quadratic q;
    q.A = p1.x - 2.0 * p2.x + p3.x;
    q.B = 2.0 * (p2.x - p1.x);
    q.C = p1.x;
    q.D = p1.y - 2.0 * p2.y + p3.y;
    q.E = 2.0 * (p2.y - p1.y);
    q.F = p1.y;
    return q;
}

// The area a piece [t0, t1] of a curve adds to the box [x0, x1].
float curves_box_piece(Curves_Quadratic q, float x0, float x1, float t0, float t1) {
    if (t1 <= t0) return 0.0;
    float tm = (t0 + t1) * 0.5;
    float xm = (q.A * tm + q.B) * tm + q.C;
    if (xm <= x0) return 0.0;
    if (xm >= x1) return (x1 - x0) * (((q.D * t1 + q.E) * t1 + q.F) - ((q.D * t0 + q.E) * t0 + q.F));
    return curves_area_term(q.A, q.B, q.C - x0, q.D, q.E, t0, t1);
}

// Exact coverage of the axis-aligned box `footprint` centered at `rc`
// (fwidth(rc), or curves_footprint).
float curves_coverage(StructuredBuffer<uint> words, uint s, float2 rc, float2 footprint, bool even_odd) {
    float fx = footprint.x;
    float fy = footprint.y;
    if (fx <= 0.0 || fy <= 0.0) return 0.0;
    float x0 = -0.5 * fx;
    float x1 = 0.5 * fx;
    float y0 = -0.5 * fy;
    float y1 = 0.5 * fy;
    uint curves = s + words[s + 6];
    float area = 0.0;
    int b_hi = curves_band_of(words, s, rc.y + y1);
    for (int band = curves_band_of(words, s, rc.y + y0); band <= b_hi; band++) {
        float2 rows = curves_band_rows(words, s, band, rc.y, y0, y1);
        if (rows.x >= rows.y) continue;
        uint hb = s + 12 + 2 * uint(band);
        uint list = s + words[hb + 1];
        uint count = words[hb];
        for (uint k = 0; k < count; k++) {
            uint c = curves + 6 * words[list + k];
            float2 p1 = curves_point(words, c, rc);
            float2 p2 = curves_point(words, c + 2, rc);
            float2 p3 = curves_point(words, c + 4, rc);
            float cxmax = max(p1.x, p3.x);
            if (cxmax <= x0) break;
            float ca = max(rows.x, min(p1.y, p3.y));
            float cb = min(rows.y, max(p1.y, p3.y));
            if (ca >= cb) continue;
            float cxmin = min(p1.x, p3.x);
            if (cxmin >= x1) {
                area += (p3.y > p1.y ? fx : -fx) * (cb - ca);
                continue;
            }
            Curves_Quadratic q = curves_quadratic(p1, p2, p3);
            float ta = curves_solve_monotone(q.D, q.E, q.F, ca);
            float tb = curves_solve_monotone(q.D, q.E, q.F, cb);
            float tlo = min(ta, tb);
            float thi = max(ta, tb);
            float xa = (q.A * tlo + q.B) * tlo + q.C;
            float xb = (q.A * thi + q.B) * thi + q.C;
            float xlo = min(xa, xb);
            float xhi = max(xa, xb);
            if (xhi <= x0) continue;
            if (xlo >= x1) {
                area += (p3.y > p1.y ? fx : -fx) * (cb - ca);
                continue;
            }
            float s1 = thi;
            float s2 = thi;
            if (x0 > xlo && x0 < xhi) s1 = clamp(curves_solve_monotone(q.A, q.B, q.C, x0), tlo, thi);
            if (x1 > xlo && x1 < xhi) s2 = clamp(curves_solve_monotone(q.A, q.B, q.C, x1), tlo, thi);
            float lo = min(s1, s2);
            float hi = max(s1, s2);
            area += curves_box_piece(q, x0, x1, tlo, lo) + curves_box_piece(q, x0, x1, lo, hi) + curves_box_piece(q, x0, x1, hi, thi);
        }
    }
    return curves_fill(area / (fx * fy), even_odd);
}

// The per-axis extent of the footprint from the shape coordinate's screen
// derivatives (ddx(rc), ddy(rc)): fwidth.
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
    int band = curves_band_of(words, s, p.y);
    uint curves = s + words[s + 6];
    uint hb = s + 12 + 2 * uint(band);
    uint list = s + words[hb + 1];
    uint count = words[hb];
    int w = 0;
    for (uint k = 0; k < count; k++) {
        uint c = curves + 6 * words[list + k];
        float2 p1 = curves_point(words, c, p);
        float2 p2 = curves_point(words, c + 2, p);
        float2 p3 = curves_point(words, c + 4, p);
        if (max(p1.x, p3.x) <= 0.0) break;
        float lo = min(p1.y, p3.y);
        float hi = max(p1.y, p3.y);
        if (0.0 < lo || 0.0 >= hi) continue;
        float t = curves_solve_monotone(p1.y - 2.0 * p2.y + p3.y, 2.0 * (p2.y - p1.y), p1.y, 0.0);
        if (((p1.x - 2.0 * p2.x + p3.x) * t + 2.0 * (p2.x - p1.x)) * t + p1.x > 0.0) {
            w += p3.y > p1.y ? 1 : -1;
        }
    }
    return w;
}
