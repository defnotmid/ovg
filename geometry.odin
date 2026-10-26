package ovg

import "core:math"

// 2D point or direction. Positions and vectors share one type so array
// arithmetic (`p + v * s`) works directly.
Vec2 :: [2]f32

dot :: #force_inline proc "contextless" (a, b: Vec2) -> f32 {
	return a.x * b.x + a.y * b.y
}

// femtovg's cross product: `orthogonal(a) · b`, the negated standard 2D cross.
cross :: #force_inline proc "contextless" (a, b: Vec2) -> f32 {
	return dot(orthogonal(a), b)
}

orthogonal :: #force_inline proc "contextless" (v: Vec2) -> Vec2 {
	return {v.y, -v.x}
}

mag2 :: #force_inline proc "contextless" (v: Vec2) -> f32 {
	return dot(v, v)
}

from_angle :: #force_inline proc "contextless" (a: f32) -> Vec2 {
	return {math.cos(a), math.sin(a)}
}

angle :: #force_inline proc "contextless" (v: Vec2) -> f32 {
	return math.atan2(v.y, v.x)
}

// `bx * v.x + by * v.y`.
with_basis :: #force_inline proc "contextless" (v, bx, by: Vec2) -> Vec2 {
	return bx * v.x + by * v.y
}

// Normalizes `v` in place and returns its previous length. Vectors shorter
// than 1e-6 are left untouched.
normalize :: proc "contextless" (v: ^Vec2) -> f32 {
	d := math.hypot(v.x, v.y)
	if d > 1e-6 {
		v^ *= 1.0 / d
	}
	return d
}

points_equal :: proc "contextless" (p1, p2: Vec2, tol: f32) -> bool {
	return mag2(p2 - p1) < tol * tol
}

// Squared distance from `p` to the segment `a -> b`.
segment_distance :: proc "contextless" (p, a, b: Vec2) -> f32 {
	pq := b - a
	dp := p - a
	d := mag2(pq)
	t := dot(pq, dp)
	if d > 0 {
		t /= d
	}
	t = clamp(t, 0, 1)
	return mag2(a - p + pq * t)
}

// 2x3 affine transform stored as `[a, b, c, d, tx, ty]`, i.e. the matrix
// `[a c tx; b d ty; 0 0 1]`. Same layout as femtovg.
Transform2D :: distinct [6]f32

TRANSFORM_IDENTITY :: Transform2D{1, 0, 0, 1, 0, 0}

transform_translation :: proc "contextless" (tx, ty: f32) -> Transform2D {
	return {1, 0, 0, 1, tx, ty}
}

transform_rotation :: proc "contextless" (a: f32) -> Transform2D {
	s, c := math.sin(a), math.cos(a)
	return {c, s, -s, c, 0, 0}
}

transform_scaling :: proc "contextless" (sx, sy: f32) -> Transform2D {
	return {sx, 0, 0, sy, 0, 0}
}

transform_skew_x :: proc "contextless" (a: f32) -> Transform2D {
	return {1, 0, math.tan(a), 1, 0, 0}
}

transform_skew_y :: proc "contextless" (a: f32) -> Transform2D {
	return {1, math.tan(a), 0, 1, 0, 0}
}

// `a * b`: applies `a` first, then `b`.
transform_multiply :: proc "contextless" (a, b: Transform2D) -> Transform2D {
	return {
		a[0] * b[0] + a[1] * b[2],
		a[0] * b[1] + a[1] * b[3],
		a[2] * b[0] + a[3] * b[2],
		a[2] * b[1] + a[3] * b[3],
		a[4] * b[0] + a[5] * b[2] + b[4],
		a[4] * b[1] + a[5] * b[3] + b[5],
	}
}

// `t = other * t`.
transform_premultiply :: proc "contextless" (t: ^Transform2D, other: Transform2D) {
	t^ = transform_multiply(other, t^)
}

// Whether `t` has no inverse: its determinant is zero relative to its own
// terms, beyond f32 rounding (so a tiny but invertible scale, as 0.001, is
// not singular).
transform_singular :: proc "contextless" (t: Transform2D) -> bool {
	a, b, c, d := f64(t[0]), f64(t[1]), f64(t[2]), f64(t[3])
	return abs(a * d - c * b) <= 1e-6 * max(abs(a * d), abs(c * b))
}

// The inverse of `t`; the identity for a singular `t` (transform_singular).
transform_inverse :: proc "contextless" (t: Transform2D) -> Transform2D {
	// The determinant is computed in f64 for stability, as in femtovg.
	a, b, c, d := f64(t[0]), f64(t[1]), f64(t[2]), f64(t[3])
	x, y := f64(t[4]), f64(t[5])
	det := a * d - c * b
	if transform_singular(t) {
		return TRANSFORM_IDENTITY
	}
	inv := 1.0 / det
	return {
		f32(d * inv),
		f32(-b * inv),
		f32(-c * inv),
		f32(a * inv),
		f32((c * y - d * x) * inv),
		f32((b * x - a * y) * inv),
	}
}

// A vector's length.
vec_len :: #force_inline proc "contextless" (v: Vec2) -> f32 {
	return math.sqrt(v.x * v.x + v.y * v.y)
}

transform_point :: #force_inline proc "contextless" (t: Transform2D, x, y: f32) -> Vec2 {
	return {x * t[0] + y * t[2] + t[4], x * t[1] + y * t[3] + t[5]}
}

transform_average_scale :: proc "contextless" (t: Transform2D) -> f32 {
	sx := math.hypot(t[0], t[2])
	sy := math.hypot(t[1], t[3])
	return (sx + sy) * 0.5
}

transform_is_pure_translation :: proc "contextless" (t: Transform2D, epsilon: f32) -> bool {
	return abs(t[0] - 1) < epsilon && abs(t[1]) < epsilon && abs(t[2]) < epsilon && abs(t[3] - 1) < epsilon
}

// Column-major mat3 padded to three vec4 columns, as uploaded to shaders.
transform_to_mat3x4 :: proc "contextless" (t: Transform2D) -> [12]f32 {
	return {t[0], t[1], 0, 0, t[2], t[3], 0, 0, t[4], t[5], 1, 0}
}

Rect :: struct {
	x, y, w, h: f32,
}

rect_is_empty :: proc "contextless" (r: Rect) -> bool {
	return r.w <= 0 || r.h <= 0
}

rect_intersect :: proc "contextless" (a, b: Rect) -> Rect {
	minx := max(a.x, b.x)
	miny := max(a.y, b.y)
	maxx := min(a.x + a.w, b.x + b.w)
	maxy := min(a.y + a.h, b.y + b.h)
	return {minx, miny, max(0, maxx - minx), max(0, maxy - miny)}
}

rect_contains_rect :: proc "contextless" (a, b: Rect) -> bool {
	return rect_is_empty(b) || (a.x <= b.x && b.x + b.w <= a.x + a.w && a.y <= b.y && b.y + b.h <= a.y + a.h)
}

Bounds :: struct {
	minx, miny, maxx, maxy: f32,
}

EMPTY_BOUNDS :: Bounds{1e6, 1e6, -1e6, -1e6}

bounds_contains :: proc "contextless" (b: Bounds, x, y: f32) -> bool {
	return x >= b.minx && x <= b.maxx && y >= b.miny && y <= b.maxy
}
