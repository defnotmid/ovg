package curves

import "core:math"

// One cubic Bézier's math, for f32 and f64 points alike: what every
// producer and consumer of cubics in ovg shares (fills, strokes, dashes,
// flattening, Lottie, SVG, the boolean). A cubic is its four control points.

// The point at t.
cubic_at :: #force_inline proc "contextless" (p: [4][2]$T, t: T) -> [2]T {
	u := 1 - t
	return u * u * u * p[0] + 3 * u * u * t * p[1] + 3 * u * t * t * p[2] + t * t * t * p[3]
}

// The derivative at t.
cubic_tangent :: #force_inline proc "contextless" (p: [4][2]$T, t: T) -> [2]T {
	u := 1 - t
	return 3 * (u * u * (p[1] - p[0]) + 2 * u * t * (p[2] - p[1]) + t * t * (p[3] - p[2]))
}

// The control points of the cubic restricted to [t0, t1], from the
// original controls: ranges sharing an end share its point bitwise.
cubic_range :: #force_inline proc "contextless" (p: [4][2]$T, t0, t1: T) -> (q: [4][2]T) {
	h := (t1 - t0) / 3
	q[0] = cubic_at(p, t0)
	q[3] = cubic_at(p, t1)
	q[1] = q[0] + cubic_tangent(p, t0) * h
	q[2] = q[3] - cubic_tangent(p, t1) * h
	return
}

// How many quadratics approximate the cubic within `tol`: each is the
// midpoint approximation of its piece, off by at most
// sqrt(3)/36 |p3 - 3 p2 + 3 p1 - p0| / n^3.
cubic_quad_count :: proc "contextless" (p: [4]Vec2, tol: f32) -> int {
	d := p[3] - 3 * p[2] + 3 * p[1] - p[0]
	e := math.sqrt(f32(3)) / 36 * math.hypot(d.x, d.y)
	return clamp(int(math.ceil(math.cbrt(e / tol))), 1, 64)
}

// The control point and end of quadratic i of n (cubic_quad_count); the
// last ends exactly on p3.
cubic_quad :: #force_inline proc "contextless" (p: [4]Vec2, i, n: int) -> (c, end: Vec2) {
	q := cubic_range(p, f32(i) / f32(n), f32(i + 1) / f32(n))
	c = (3 * (q[1] + q[2]) - q[0] - q[3]) * 0.25
	end = q[3] if i < n - 1 else p[3]
	return
}

// The parameters in (0, 1) where the cubic turns along `axis` (the roots
// of its derivative), ascending.
cubic_extrema :: proc "contextless" (p: [4][2]$T, axis: int) -> (ts: [2]T, n: int) {
	p0, p1, p2, p3 := p[0][axis], p[1][axis], p[2][axis], p[3][axis]
	r1, r2 := roots_between(-p0 + 3 * p1 - 3 * p2 + p3, 2 * (p0 - 2 * p1 + p2), p1 - p0, 0, 1)
	for r in ([2]T{min(r1, r2), max(r1, r2)}) {
		if r < 1 {
			ts[n] = r
			n += 1
		}
	}
	return
}

// The cubic's exact bounding box: its ends and its turning points.
cubic_bounds :: proc "contextless" (p: [4][2]$T) -> (lo, hi: [2]T) {
	lo = {min(p[0].x, p[3].x), min(p[0].y, p[3].y)}
	hi = {max(p[0].x, p[3].x), max(p[0].y, p[3].y)}
	for axis in 0 ..< 2 {
		ts, n := cubic_extrema(p, axis)
		for t in ts[:n] {
			v := cubic_at(p, t)[axis]
			lo[axis] = min(lo[axis], v)
			hi[axis] = max(hi[axis], v)
		}
	}
	return
}

// Whether a winding number is inside under a fill rule.
fill_inside :: #force_inline proc "contextless" (w: i32, even_odd: bool) -> bool {
	return w & 1 != 0 if even_odd else w != 0
}
