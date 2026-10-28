package ovg

import "core:math"

import cv "deps:ocurves"

// Cubic bezier handle length (relative to radius) for a 90 degree arc.
KAPPA90 :: 0.5522848

// Points closer than this merge in `path_arc_to`.
DEFAULT_DIST_TOL :: 0.01

// A vector path: its contours of lines and cubics in one table, ocurves'
// Contours (every contour's points, each segment's kind, a row per
// contour), so the booleans, hit tests, shapes and strokes read it as it
// is. The path_* calls keep it the way a fill reads it: drawing before the
// first move goes nowhere; a move starts a contour (one left without
// segments draws nothing, or a stroke's caps when closed); a quadratic is
// the cubic it is; a close draws the line back to the start when the pen
// isn't there and ends the contour; drawing after a close starts a contour
// where the closed one started; `path_solidity` winds the current contour
// as it stands. The pen is the last point. Read-only while drawn (one path
// can be drawn by several canvases at once). Reuse a `Path` across frames
// (`path_reset`) to keep its buffers. Uses the context allocator current
// at the first append.
Path :: cv.Contours

// A path allocating from `allocator`.
path_init :: proc(p: ^Path, allocator := context.allocator) {
	cv.contours_init(p, allocator)
}

path_destroy :: proc(p: ^Path) {
	cv.contours_destroy(p)
}

// Clears the path but keeps its allocations.
path_reset :: proc(p: ^Path) {
	cv.contours_clear(p)
}

path_is_empty :: proc "contextless" (p: ^Path) -> bool {
	return len(p.contours) == 0
}

// Where the next segment starts: the last point (the origin before any).
path_pen :: proc "contextless" (p: ^Path) -> Vec2 {
	return p.pts[len(p.pts) - 1] if len(p.pts) > 0 else {}
}

// Appends `src` under `t`.
path_append :: proc(p: ^Path, src: ^Path, t := TRANSFORM_IDENTITY) {
	path_append_contours(p, src, 0, len(src.contours), t)
}

// Appends contours [first, first + count) of `c` (a path's, or any contour
// table's) under `t`.
path_append_contours :: proc(p: ^Path, c: ^cv.Contours, first, count: int, t := TRANSFORM_IDENTITY) {
	at := len(p.pts)
	cv.contours_append(p, c, first, count)
	if t != TRANSFORM_IDENTITY {
		for &q in p.pts[at:] {
			q = transform_point(t, q.x, q.y)
		}
	}
}

// Keeps the first `n` contours.
path_truncate :: proc(p: ^Path, n: int) {
	if n >= len(p.contours) {
		return
	}
	ct := p.contours[n]
	resize(&p.pts, int(ct.start))
	resize(&p.kinds, int(ct.seg))
	resize(&p.contours, n)
}

path_move_to :: proc(p: ^Path, x, y: f32) {
	cv.contours_begin(p, {x, y})
}

// Whether a segment can be drawn: the current contour takes it, or after a
// close a new one where the closed one started; not before the first move.
@(private = "file")
pen_down :: proc(p: ^Path) -> bool {
	n := len(p.contours)
	if n == 0 {
		return false
	}
	if ct := p.contours[n - 1]; ct.closed {
		cv.contours_begin(p, p.pts[ct.start])
	}
	return true
}

path_line_to :: proc(p: ^Path, x, y: f32) {
	if pen_down(p) {
		cv.contours_line(p, {x, y})
	}
}

path_bezier_to :: proc(p: ^Path, c1x, c1y, c2x, c2y, x, y: f32) {
	if pen_down(p) {
		cv.contours_cubic(p, {c1x, c1y}, {c2x, c2y}, {x, y})
	}
}

path_quad_to :: proc(p: ^Path, cx, cy, x, y: f32) {
	if pen_down(p) {
		cv.contours_quad(p, {cx, cy}, {x, y})
	}
}

// Ends the current contour closed, with the line back to its start when
// the pen isn't there.
path_close :: proc(p: ^Path) {
	n := len(p.contours)
	if n == 0 || p.contours[n - 1].closed {
		return
	}
	if s := p.pts[p.contours[n - 1].start]; path_pen(p) != s {
		cv.contours_line(p, s)
	}
	cv.contours_end(p, true, false)
}

// Winds the current contour: `.Solid` contours fill, `.Hole` contours cut
// out of solid ones under the non-zero rule. It is reversed when its area
// (closed by a line) has the other sign; an open one goes on from its new
// end.
path_solidity :: proc(p: ^Path, s: Solidity) {
	n := len(p.contours)
	if n == 0 || s == .None {
		return
	}
	if a := cv.contours_area(p, n - 1); (s == .Solid && a < 0) || (s == .Hole && a > 0) {
		cv.contours_reverse(p, n - 1)
	}
}

path_rect :: proc(p: ^Path, x, y, w, h: f32) {
	path_move_to(p, x, y)
	path_line_to(p, x, y + h)
	path_line_to(p, x + w, y + h)
	path_line_to(p, x + w, y)
	path_close(p)
}

path_rounded_rect :: proc(p: ^Path, x, y, w, h, r: f32) {
	path_rounded_rect_varying(p, x, y, w, h, r, r, r, r)
}

path_rounded_rect_varying :: proc(p: ^Path, x, y, w, h, rad_tl, rad_tr, rad_br, rad_bl: f32) {
	if rad_tl < 0.1 && rad_tr < 0.1 && rad_br < 0.1 && rad_bl < 0.1 {
		path_rect(p, x, y, w, h)
		return
	}
	halfw := abs(w) * 0.5
	halfh := abs(h) * 0.5
	sw := math.sign(w)
	sh := math.sign(h)
	rx_bl, ry_bl := min(rad_bl, halfw) * sw, min(rad_bl, halfh) * sh
	rx_br, ry_br := min(rad_br, halfw) * sw, min(rad_br, halfh) * sh
	rx_tr, ry_tr := min(rad_tr, halfw) * sw, min(rad_tr, halfh) * sh
	rx_tl, ry_tl := min(rad_tl, halfw) * sw, min(rad_tl, halfh) * sh
	K :: 1 - KAPPA90
	path_move_to(p, x, y + ry_tl)
	path_line_to(p, x, y + h - ry_bl)
	path_bezier_to(p, x, y + h - ry_bl * K, x + rx_bl * K, y + h, x + rx_bl, y + h)
	path_line_to(p, x + w - rx_br, y + h)
	path_bezier_to(p, x + w - rx_br * K, y + h, x + w, y + h - ry_br * K, x + w, y + h - ry_br)
	path_line_to(p, x + w, y + ry_tr)
	path_bezier_to(p, x + w, y + ry_tr * K, x + w - rx_tr * K, y, x + w - rx_tr, y)
	path_line_to(p, x + rx_tl, y)
	path_bezier_to(p, x + rx_tl * K, y, x, y + ry_tl * K, x, y + ry_tl)
	path_close(p)
}

path_ellipse :: proc(p: ^Path, cx, cy, rx, ry: f32) {
	c := Vec2{cx, cy}
	h := Vec2{rx, 0}
	v := Vec2{0, ry}
	K :: KAPPA90
	q := [13]Vec2 {
		c - h,
		c - h + v * K,
		c - h * K + v,
		c + v,
		c + h * K + v,
		c + h + v * K,
		c + h,
		c + h - v * K,
		c + h * K - v,
		c - v,
		c - h * K - v,
		c - h - v * K,
		c - h,
	}
	path_move_to(p, q[0].x, q[0].y)
	for i := 1; i < 13; i += 3 {
		path_bezier_to(p, q[i].x, q[i].y, q[i + 1].x, q[i + 1].y, q[i + 2].x, q[i + 2].y)
	}
	path_close(p)
}

path_circle :: proc(p: ^Path, cx, cy, r: f32) {
	path_ellipse(p, cx, cy, r, r)
}

// Arc around (cx, cy) from angle `a0` to `a1` (radians). `.Hole` sweeps
// clockwise on screen, `.Solid` counter-clockwise. Starts a new contour if
// the path is empty, otherwise connects with a line.
path_arc :: proc(p: ^Path, cx, cy, r, a0, a1: f32, dir: Solidity) {
	c := Vec2{cx, cy}
	da := a1 - a0
	if dir == .Hole {
		if abs(da) >= math.TAU {
			da = math.TAU
		} else {
			for da < 0 {da += math.TAU}
		}
	} else {
		if abs(da) >= math.TAU {
			da = -math.TAU
		} else {
			for da > 0 {da -= math.TAU}
		}
	}

	// At most 90 degrees per bezier segment.
	ndivs := clamp(int(abs(da) / (math.PI * 0.5) + 0.5), 1, 5)
	hda := (da / f32(ndivs)) / 2
	// A zero sweep has no handles (not 0 / 0).
	kappa := abs(4.0 / 3.0 * (1 - math.cos(hda)) / math.sin(hda)) if hda != 0 else 0
	if dir == .Solid {
		kappa = -kappa
	}

	ppos, ptan: Vec2
	for i in 0 ..= ndivs {
		a := a0 + da * (f32(i) / f32(ndivs))
		dpos := from_angle(a)
		pos := c + dpos * r
		tan := -orthogonal(dpos) * (r * kappa)
		if i == 0 {
			if path_is_empty(p) {
				path_move_to(p, pos.x, pos.y)
			} else {
				path_line_to(p, pos.x, pos.y)
			}
		} else {
			c1, c2 := ppos + ptan, pos - tan
			path_bezier_to(p, c1.x, c1.y, c2.x, c2.y, pos.x, pos.y)
		}
		ppos = pos
		ptan = tan
	}
}

// Arc tangent to the lines (last point -> (x1, y1)) and ((x1, y1) -> (x2, y2)).
path_arc_to :: proc(p: ^Path, x1, y1, x2, y2, radius: f32) {
	if path_is_empty(p) {
		return
	}
	tol :: DEFAULT_DIST_TOL
	pos0 := path_pen(p)
	pos1 := Vec2{x1, y1}
	pos2 := Vec2{x2, y2}
	if points_equal(pos0, pos1, tol) ||
	   points_equal(pos1, pos2, tol) ||
	   segment_distance(pos1, pos0, pos2) < tol * tol ||
	   radius < tol {
		path_line_to(p, x1, y1)
		return
	}

	d0 := pos0 - pos1
	d1 := pos2 - pos1
	normalize(&d0)
	normalize(&d1)
	a := math.acos(clamp(dot(d0, d1), -1, 1))
	d := radius / math.tan(a / 2)
	if d > 10000 {
		path_line_to(p, x1, y1)
		return
	}

	c: Vec2
	a0, a1: f32
	dir: Solidity
	if cross(d0, d1) > 0 {
		c = pos1 + d0 * d + orthogonal(d0) * radius
		a0 = angle(d0)
		a1 = angle(-d1)
		dir = .Hole
	} else {
		c = pos1 + d0 * d - orthogonal(d0) * radius
		a0 = angle(-d0)
		a1 = angle(d1)
		dir = .Solid
	}
	path_arc(p, c.x, c.y, radius, a0 + math.PI / 2, a1 + math.PI / 2, dir)
}

// The exact bounds of what contours [first, first + count) of `p` draw
// under `t`: each segment's ends and turning points (a contour without
// segments draws nothing); EMPTY_BOUNDS when nothing does.
path_contours_bounds :: proc(p: ^Path, first, count: int, t := TRANSFORM_IDENTITY) -> Bounds {
	b := Bounds{max(f32), max(f32), -max(f32), -max(f32)}
	for ci in first ..< first + count {
		it := cv.contour_segments(p, ci)
		for sg in cv.segments_next(&it) {
			s := sg.p
			lo, hi: Vec2
			if sg.kind == .Line {
				a, z := transform_point(t, s[0].x, s[0].y), transform_point(t, s[3].x, s[3].y)
				lo, hi = {min(a.x, z.x), min(a.y, z.y)}, {max(a.x, z.x), max(a.y, z.y)}
			} else {
				q: [4]Vec2
				for k in 0 ..< 4 {
					q[k] = transform_point(t, s[k].x, s[k].y)
				}
				lo, hi = cv.cubic_bounds(q)
			}
			b = {min(b.minx, lo.x), min(b.miny, lo.y), max(b.maxx, hi.x), max(b.maxy, hi.y)}
		}
	}
	return b if b.minx <= b.maxx else EMPTY_BOUNDS
}
