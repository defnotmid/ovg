// The GPU twin of ovg's curves package (curves/curves.odin): exact
// coverage of a pixel's footprint (a box, or any parallelogram) by a shape's
// monotone quadratic pieces in a grid of cells with backdrops. The same
// arithmetic, except that a pixel's crossing pieces are integrated after
// the scan (see curves_coverage), so sums may round differently. `words`
// holds any number of shapes; `s` is a shape's first word. The layout is
// documented in curves.odin, and its number is curves.FORMAT: a renderer
// compiling this file checks it against the curves package it builds with.
// Include this file; it binds nothing.

float curves_f(StructuredBuffer<uint> words, uint i) { return asfloat(words[i]); }

float2 curves_point(StructuredBuffer<uint> words, uint c, float2 rc) {
    return float2(curves_f(words, c), curves_f(words, c + 1)) - rc;
}

// The cells a footprint covers (columns x, rows y, clamped to the grid) and
// the grid's size.
struct Curves_Span {
    int nx, ny, i0, i1, j0, j1;
    float y0, y1;
};

Curves_Span curves_span(StructuredBuffer<uint> words, uint s, float2 rc, float x0, float x1, float y0, float y1) {
    Curves_Span g;
    g.nx = int(words[s]);
    g.ny = int(words[s + 1]);
    float cw = curves_f(words, s + 2);
    float ch = curves_f(words, s + 3);
    g.i0 = clamp(int(floor((rc.x + x0) / cw)), 0, g.nx - 1);
    g.i1 = clamp(int(floor((rc.x + x1) / cw)), 0, g.nx - 1);
    g.j0 = clamp(int(floor((rc.y + y0) / ch)), 0, g.ny - 1);
    g.j1 = clamp(int(floor((rc.y + y1) / ch)), 0, g.ny - 1);
    g.y0 = y0;
    g.y1 = y1;
    return g;
}

// Row j's part of the footprint's rows (xy; the first and last rows reach
// out) and the row's own extent (zw), relative to ry.
float4 curves_rows(StructuredBuffer<uint> words, uint s, Curves_Span g, int j, float ry) {
    float ch = curves_f(words, s + 3);
    float rlo = float(j) * ch - ry;
    float rhi = float(j + 1) * ch - ry;
    return float4(j == 0 ? g.y0 : max(g.y0, rlo), j == g.ny - 1 ? g.y1 : min(g.y1, rhi), rlo, rhi);
}

uint curves_cell(uint s, Curves_Span g, int i, int j) {
    return s + 12 + 4 * uint(j * g.nx + i);
}

// The integral over rows [a, b] (relative to ry) of the cell's backdrop.
float curves_backdrop_box(StructuredBuffer<uint> words, uint s, uint cell, float ry, float a, float b) {
    if (a >= b) return 0.0;
    int v = int(words[cell + 2]);
    uint n = words[cell + 3];
    uint at = s + words[cell] + words[cell + 1];
    float area = 0.0;
    float pos = a;
    for (uint k = 0; k < n; k++) {
        float y = curves_f(words, at + 2 * k) - ry;
        if (y >= b) break;
        if (y > a) {
            area += float(v) * (y - pos);
            pos = y;
        }
        v += int(words[at + 2 * k + 1]);
    }
    return area + float(v) * (b - pos);
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

// `q` as a polynomial in s = t - t0.
Curves_Quadratic curves_from(Curves_Quadratic q, float t0) {
    Curves_Quadratic r;
    r.A = q.A;
    r.B = 2.0 * q.A * t0 + q.B;
    r.C = (q.A * t0 + q.B) * t0 + q.C;
    r.D = q.D;
    r.E = 2.0 * q.D * t0 + q.E;
    r.F = (q.D * t0 + q.E) * t0 + q.F;
    return r;
}

// The area a piece [t0, t1] of a curve adds to the box [x0, x1], the part
// inside in a parameter starting at t0 (as curves_affine_curve's).
float curves_box_piece(Curves_Quadratic q, float x0, float x1, float t0, float t1) {
    if (t1 <= t0) return 0.0;
    float tm = (t0 + t1) * 0.5;
    float xm = (q.A * tm + q.B) * tm + q.C;
    if (xm <= x0) return 0.0;
    if (xm >= x1) return (x1 - x0) * (((q.D * t1 + q.E) * t1 + q.F) - ((q.D * t0 + q.E) * t0 + q.F));
    Curves_Quadratic r = curves_from(q, t0);
    return curves_area_term(r.A, r.B, r.C - x0, r.D, r.E, 0.0, t1 - t0);
}

// The area a curve crossing the box adds over its rows [ca, cb].
float curves_box_curve(StructuredBuffer<uint> words, uint c, float2 rc, float ca, float cb, float x0, float x1) {
    float2 p1 = curves_point(words, c, rc);
    float2 p2 = curves_point(words, c + 2, rc);
    float2 p3 = curves_point(words, c + 4, rc);
    Curves_Quadratic q = curves_quadratic(p1, p2, p3);
    float ta = curves_solve_monotone(q.D, q.E, q.F, ca);
    float tb = curves_solve_monotone(q.D, q.E, q.F, cb);
    float tlo = min(ta, tb);
    float thi = max(ta, tb);
    float xa = (q.A * tlo + q.B) * tlo + q.C;
    float xb = (q.A * thi + q.B) * thi + q.C;
    float xlo = min(xa, xb);
    float xhi = max(xa, xb);
    if (xhi <= x0) return 0.0;
    if (xlo >= x1) return (p3.y > p1.y ? x1 - x0 : x0 - x1) * (cb - ca);
    float s1 = thi;
    float s2 = thi;
    if (x0 > xlo && x0 < xhi) s1 = clamp(curves_solve_monotone(q.A, q.B, q.C, x0), tlo, thi);
    if (x1 > xlo && x1 < xhi) s2 = clamp(curves_solve_monotone(q.A, q.B, q.C, x1), tlo, thi);
    float lo = min(s1, s2);
    float hi = max(s1, s2);
    return curves_box_piece(q, x0, x1, tlo, lo) + curves_box_piece(q, x0, x1, lo, hi) + curves_box_piece(q, x0, x1, hi, thi);
}

// Exact coverage of the axis-aligned box `footprint` centered at `rc`: a
// pixel without rotation or skew (curves_coverage_affine for the others).
// Its cells' pieces wholly right of it are summed as found and the few
// crossing it kept, integrated after: pixels running together then
// integrate together instead of each stalling the others' scans.
float curves_coverage(StructuredBuffer<uint> words, uint s, float2 rc, float2 footprint, bool even_odd) {
    float fx = footprint.x;
    float fy = footprint.y;
    if (fx <= 0.0 || fy <= 0.0) return 0.0;
    float x0 = -0.5 * fx;
    float x1 = 0.5 * fx;
    Curves_Span g = curves_span(words, s, rc, x0, x1, -0.5 * fy, 0.5 * fy);
    uint curves = s + words[s + 6];
    float area = 0.0;
    // Up to two crossing pieces: word offsets and rows.
    uint2 kept = uint2(0, 0);
    float2 kept_a = float2(0, 0);
    float2 kept_b = float2(0, 0);
    int n = 0;
    for (int j = g.j0; j <= g.j1; j++) {
        float4 rows = curves_rows(words, s, g, j, rc.y);
        if (rows.x >= rows.y) continue;
        for (int i = g.i0; i <= g.i1; i++) {
            uint cell = curves_cell(s, g, i, j);
            uint list = s + words[cell];
            uint count = words[cell + 1];
            for (uint k = 0; k < count; k++) {
                uint c = curves + 6 * words[list + k];
                float x1c = curves_f(words, c) - rc.x;
                float y1c = curves_f(words, c + 1) - rc.y;
                float x3c = curves_f(words, c + 4) - rc.x;
                float y3c = curves_f(words, c + 5) - rc.y;
                float ca = max(rows.x, min(y1c, y3c));
                float cb = min(rows.y, max(y1c, y3c));
                if (ca >= cb || max(x1c, x3c) <= x0) continue;
                if (min(x1c, x3c) >= x1) {
                    area += (y3c > y1c ? fx : -fx) * (cb - ca);
                } else if (n < 2) {
                    kept[n] = c;
                    kept_a[n] = ca;
                    kept_b[n] = cb;
                    n++;
                } else {
                    area += curves_box_curve(words, c, rc, ca, cb, x0, x1);
                }
            }
        }
        area += fx * curves_backdrop_box(words, s, curves_cell(s, g, g.i1, j), rc.y, max(rows.x, rows.z), min(rows.y, rows.w));
    }
    for (int i = 0; i < n; i++) {
        area += curves_box_curve(words, kept[i], rc, kept_a[i], kept_b[i], x0, x1);
    }
    return curves_fill(area / (fx * fy), even_odd);
}

// A pixel's parallelogram footprint centered on the origin (see Footprint
// in curves.odin): corners at heights -h0, -h1, h1, h0; long sides of slope
// s1 with intercepts c1, c2, short sides of slope s2 with c3, c4.
struct Curves_Footprint {
    float h0, h1, s1, s2, c1, c2, c3, c4, width, xmin, xmax;
};

bool curves_footprint_parallelogram(float2 u, float2 v, out Curves_Footprint fp) {
    float2 d1 = 0.5 * (u + v);
    float2 d2 = 0.5 * (u - v);
    if (abs(d1.y) < abs(d2.y)) { float2 tt = d1; d1 = d2; d2 = tt; }
    float2 b = d1.y <= 0.0 ? d1 : -d1;
    float2 p = d2.y <= 0.0 ? d2 : -d2;
    fp.h0 = -b.y;
    fp.h1 = -p.y;
    fp.s1 = 0.0;
    fp.s2 = 0.0;
    if (fp.h0 <= 0.0) {
        fp.c1 = fp.c2 = fp.c3 = fp.c4 = fp.width = fp.xmin = fp.xmax = 0.0;
        return false;
    }
    fp.s1 = (-p.x - b.x) / (fp.h1 + fp.h0);
    if (fp.h0 > fp.h1) fp.s2 = (p.x - b.x) / (fp.h0 - fp.h1);
    fp.c1 = b.x + fp.h0 * fp.s1;
    fp.c2 = p.x + fp.h1 * fp.s1;
    fp.c3 = b.x + fp.h0 * fp.s2;
    fp.c4 = -p.x - fp.h1 * fp.s2;
    fp.width = abs(fp.c2 - fp.c1);
    fp.xmin = min(min(b.x, p.x), min(-b.x, -p.x));
    fp.xmax = max(max(b.x, p.x), max(-b.x, -p.x));
    return fp.width > 0.0;
}

// The footprint's area below row y.
float curves_width_below(Curves_Footprint fp, float y) {
    if (y <= -fp.h0) return 0.0;
    float total = fp.width * (fp.h0 + fp.h1);
    if (y >= fp.h0) return total;
    if (y < -fp.h1) {
        float d = y + fp.h0;
        return 0.5 * fp.width * d * d / (fp.h0 - fp.h1);
    }
    if (y <= fp.h1) return 0.5 * fp.width * (fp.h0 - fp.h1) + fp.width * (y + fp.h1);
    float d = fp.h0 - y;
    return total - 0.5 * fp.width * d * d / (fp.h0 - fp.h1);
}

// Four values in ascending order (a sorting network).
float4 curves_sort4(float w, float x, float y, float z) {
    float a = min(w, x);
    float b = max(w, x);
    float c = min(y, z);
    float d = max(y, z);
    float a2 = min(a, c);
    float c2 = max(a, c);
    float b2 = min(b, d);
    float d2 = max(b, d);
    return float4(a2, min(b2, c2), max(b2, c2), d2);
}

// The real roots of a t^2 + b t + c in (lo, hi); `hi` stands for each one
// missing.
float2 curves_roots_between(float a, float b, float c, float lo, float hi) {
    float2 r = float2(hi, hi);
    float glo = (a * lo + b) * lo + c;
    float ghi = (a * hi + b) * hi + c;
    float vertex = a != 0.0 ? -b / (2.0 * a) : lo;
    if ((glo > 0.0) == (ghi > 0.0) && !(vertex > lo && vertex < hi)) return r;
    if (abs(a) <= 1e-9 * (abs(b) + abs(c))) {
        if (b != 0.0) {
            float t = -c / b;
            if (t > lo && t < hi) r.x = t;
        }
        return r;
    }
    float disc = b * b - 4.0 * a * c;
    if (disc < 0.0) return r;
    float d = sqrt(disc);
    float q = -0.5 * (b + (b >= 0.0 ? d : -d));
    float t1 = q / a;
    if (t1 > lo && t1 < hi) r.x = t1;
    if (q != 0.0) {
        float t2 = c / q;
        if (t2 > lo && t2 < hi) r.y = t2;
    }
    return r;
}

float curves_footprint_span(Curves_Footprint fp, Curves_Quadratic q, float ac, float as_, float bc, float bs, float t0, float t1) {
    if (t1 <= t0) return 0.0;
    float tm = (t0 + t1) * 0.5;
    float xm = (q.A * tm + q.B) * tm + q.C;
    float ym = (q.D * tm + q.E) * tm + q.F;
    if (xm <= ac + as_ * ym) return 0.0;
    if (xm >= bc + bs * ym) {
        return curves_width_below(fp, (q.D * t1 + q.E) * t1 + q.F) - curves_width_below(fp, (q.D * t0 + q.E) * t0 + q.F);
    }
    return curves_area_term(q.A - as_ * q.D, q.B - as_ * q.E, q.C - ac - as_ * q.F, q.D, q.E, t0, t1);
}

// The area the curve's stretch [ta, tb] adds within piece k (0 bottom, 1
// middle, 2 top) of the footprint.
float curves_footprint_piece(Curves_Footprint fp, int k, Curves_Quadratic q, float ta, float tb) {
    float t0 = min(ta, tb);
    float t1 = max(ta, tb);
    if (t1 <= t0) return 0.0;
    float ac = k == 2 ? fp.c2 : fp.c1;
    float as_ = fp.s1;
    float bc = k == 0 ? fp.c3 : (k == 1 ? fp.c2 : fp.c4);
    float bs = k == 1 ? fp.s1 : fp.s2;
    float y0 = (q.D * t0 + q.E) * t0 + q.F;
    float y1 = (q.D * t1 + q.E) * t1 + q.F;
    float ym = 0.5 * (y0 + y1);
    if (ac + as_ * ym > bc + bs * ym) {
        float tc = ac; ac = bc; bc = tc;
        float ts = as_; as_ = bs; bs = ts;
    }
    float xa = (q.A * t0 + q.B) * t0 + q.C;
    float xb = (q.A * t1 + q.B) * t1 + q.C;
    if (max(xa, xb) <= min(ac + as_ * y0, ac + as_ * y1)) return 0.0;
    if (min(xa, xb) >= max(bc + bs * y0, bc + bs * y1)) {
        return curves_width_below(fp, y1) - curves_width_below(fp, y0);
    }
    float2 l = curves_roots_between(q.A - as_ * q.D, q.B - as_ * q.E, q.C - ac - as_ * q.F, t0, t1);
    float2 r = curves_roots_between(q.A - bs * q.D, q.B - bs * q.E, q.C - bc - bs * q.F, t0, t1);
    float4 t = curves_sort4(l.x, l.y, r.x, r.y);
    float area = curves_footprint_span(fp, q, ac, as_, bc, bs, t0, t.x);
    area += curves_footprint_span(fp, q, ac, as_, bc, bs, t.x, t.y);
    area += curves_footprint_span(fp, q, ac, as_, bc, bs, t.y, t.z);
    area += curves_footprint_span(fp, q, ac, as_, bc, bs, t.z, t.w);
    area += curves_footprint_span(fp, q, ac, as_, bc, bs, t.w, t1);
    return area;
}

// The integral over rows [a, b] (relative to ry) of the cell's backdrop
// times the footprint's slice widths.
float curves_backdrop_fp(StructuredBuffer<uint> words, uint s, uint cell, float ry, float a, float b, Curves_Footprint fp) {
    if (a >= b) return 0.0;
    int v = int(words[cell + 2]);
    uint n = words[cell + 3];
    uint at = s + words[cell] + words[cell + 1];
    float area = 0.0;
    float pos = a;
    for (uint k = 0; k < n; k++) {
        float y = curves_f(words, at + 2 * k) - ry;
        if (y >= b) break;
        if (y > a) {
            area += float(v) * (curves_width_below(fp, y) - curves_width_below(fp, pos));
            pos = y;
        }
        v += int(words[at + 2 * k + 1]);
    }
    return area + float(v) * (curves_width_below(fp, b) - curves_width_below(fp, pos));
}

// The area a curve crossing the footprint adds over its rows [ca, cb]: its
// parameters at the rows' ends and where they cross the pieces'
// boundaries (no solve where those coincide), then each piece.

float curves_affine_curve(StructuredBuffer<uint> words, uint c, float2 rc, Curves_Footprint fp, float ca, float cb) {
    Curves_Quadratic q = curves_quadratic(curves_point(words, c, rc), curves_point(words, c + 2, rc), curves_point(words, c + 4, rc));
    float ta = curves_solve_monotone(q.D, q.E, q.F, ca);
    float tb = curves_solve_monotone(q.D, q.E, q.F, cb);
    float y1 = clamp(-fp.h1, ca, cb);
    float y2 = clamp(fp.h1, ca, cb);
    float t1 = y1 == ca ? ta : (y1 == cb ? tb : curves_solve_monotone(q.D, q.E, q.F, y1));
    float t2 = y2 == ca ? ta : (y2 == cb ? tb : curves_solve_monotone(q.D, q.E, q.F, y2));
    // Each piece in a parameter starting at its stretch (see affine_curve).
    return curves_footprint_piece(fp, 0, curves_from(q, ta), 0.0, t1 - ta) + curves_footprint_piece(fp, 1, curves_from(q, t1), 0.0, t2 - t1) + curves_footprint_piece(fp, 2, curves_from(q, t2), 0.0, tb - t2);
}

// Exact coverage of the parallelogram rc + a u + b v, a, b in [-1/2, 1/2]
// (u, v: ddx(rc), ddy(rc), or the inverse transform's columns).
float curves_coverage_affine(StructuredBuffer<uint> words, uint s, float2 rc, float2 u, float2 v, bool even_odd) {
    if (u.y == 0.0 && v.x == 0.0) {
        return curves_coverage(words, s, rc, float2(abs(u.x), abs(v.y)), even_odd);
    }
    Curves_Footprint fp;
    if (!curves_footprint_parallelogram(u, v, fp)) return 0.0;
    Curves_Span g = curves_span(words, s, rc, fp.xmin, fp.xmax, -fp.h0, fp.h0);
    uint curves = s + words[s + 6];
    float area = 0.0;
    // Up to two crossing pieces, integrated after the scan (as curves_coverage).
    uint2 kept = uint2(0, 0);
    float2 kept_a = float2(0, 0);
    float2 kept_b = float2(0, 0);
    int n = 0;
    for (int j = g.j0; j <= g.j1; j++) {
        float4 rows = curves_rows(words, s, g, j, rc.y);
        if (rows.x >= rows.y) continue;
        for (int i = g.i0; i <= g.i1; i++) {
            uint cell = curves_cell(s, g, i, j);
            uint list = s + words[cell];
            uint count = words[cell + 1];
            for (uint k = 0; k < count; k++) {
                uint c = curves + 6 * words[list + k];
                float x1c = curves_f(words, c) - rc.x;
                float y1c = curves_f(words, c + 1) - rc.y;
                float x3c = curves_f(words, c + 4) - rc.x;
                float y3c = curves_f(words, c + 5) - rc.y;
                float ca = max(rows.x, min(y1c, y3c));
                float cb = min(rows.y, max(y1c, y3c));
                if (ca >= cb || max(x1c, x3c) <= fp.xmin) continue;
                if (min(x1c, x3c) >= fp.xmax) {
                    area += (y3c > y1c ? 1.0 : -1.0) * (curves_width_below(fp, cb) - curves_width_below(fp, ca));
                } else if (n < 2) {
                    kept[n] = c;
                    kept_a[n] = ca;
                    kept_b[n] = cb;
                    n++;
                } else {
                    area += curves_affine_curve(words, c, rc, fp, ca, cb);
                }
            }
        }
        area += curves_backdrop_fp(words, s, curves_cell(s, g, g.i1, j), rc.y, max(rows.x, rows.z), min(rows.y, rows.w), fp);
    }
    for (int i = 0; i < n; i++) {
        area += curves_affine_curve(words, kept[i], rc, fp, kept_a[i], kept_b[i]);
    }
    return curves_fill(area / (fp.width * (fp.h0 + fp.h1)), even_odd);
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
    if (p.x >= curves_f(words, s + 10) || p.y < 0.0 || p.y >= curves_f(words, s + 11)) return 0;
    Curves_Span g = curves_span(words, s, p, 0.0, 0.0, 0.0, 0.0);
    uint cell = curves_cell(s, g, g.i0, g.j0);
    // The backdrop at p.y, then the cell's pieces right of p.
    int w = int(words[cell + 2]);
    uint at = s + words[cell] + words[cell + 1];
    uint steps = words[cell + 3];
    for (uint k = 0; k < steps; k++) {
        if (curves_f(words, at + 2 * k) <= p.y) w += int(words[at + 2 * k + 1]);
    }
    uint curves = s + words[s + 6];
    uint list = s + words[cell];
    uint count = words[cell + 1];
    for (uint k = 0; k < count; k++) {
        uint c = curves + 6 * words[list + k];
        float2 p1 = curves_point(words, c, p);
        float2 p2 = curves_point(words, c + 2, p);
        float2 p3 = curves_point(words, c + 4, p);
        float lo = min(p1.y, p3.y);
        float hi = max(p1.y, p3.y);
        if (0.0 < lo || 0.0 >= hi || max(p1.x, p3.x) <= 0.0) continue;
        float t = curves_solve_monotone(p1.y - 2.0 * p2.y + p3.y, 2.0 * (p2.y - p1.y), p1.y, 0.0);
        if (((p1.x - 2.0 * p2.x + p3.x) * t + 2.0 * (p2.x - p1.x)) * t + p1.x > 0.0) {
            w += p3.y > p1.y ? 1 : -1;
        }
    }
    return w;
}
