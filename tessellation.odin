package ovg

import "base:runtime"
import "core:math"
import "core:slice"

// Flattens a `Path` under a transform into contours of points, then expands
// them into fill triangles and fringe/stroke strips. Port of femtovg's
// `path/cache.rs`; constants and branch structure match it.

Point_Flag :: enum u8 {
	Corner,
	Left,
	Bevel,
	Inner_Bevel,
}
Point_Flags :: bit_set[Point_Flag;u8]

Convexity :: enum u8 {
	Unknown,
	Concave,
	Convex,
}

Point :: struct {
	pos:   Vec2,
	// Unit direction to the next point.
	dpos:  Vec2,
	// Distance to the next point.
	len:   f32,
	// Miter direction, scaled so `pos + dmpos * w` is the offset corner.
	dmpos: Vec2,
	flags: Point_Flags,
}

Contour :: struct {
	point_start: u32,
	point_end:   u32,
	closed:      bool,
	bevel:       u32,
	solidity:    Solidity,
	convexity:   Convexity,
	// Encloses no area (a line, points on one line): fills draw nothing.
	zero_area:   bool,
	// Ranges into `Tessellation.fill_verts` / `stroke_verts`.
	fill:        Range,
	stroke:      Range,
}

Tessellation :: struct {
	contours:     [dynamic]Contour,
	points:       [dynamic]Point,
	bounds:       Bounds,
	// Fill triangle lists of all contours.
	fill_verts:   [dynamic]Path_Vertex,
	// Fringe or stroke triangle strips of all contours.
	stroke_verts: [dynamic]Path_Vertex,
	fan:          [dynamic]Path_Vertex,
	// The fill fringe goes on the outside of positive-area (counter-clockwise
	// in y-down) contours. `fill_flip` is set when the path's largest contour
	// is clockwise, so fills reverse every contour; `flipped` is whether the
	// points are currently stored reversed.
	fill_flip:    bool,
	flipped:      bool,
}

tessellation_destroy :: proc(c: ^Tessellation) {
	delete(c.contours)
	delete(c.points)
	delete(c.fill_verts)
	delete(c.stroke_verts)
	delete(c.fan)
	c^ = {}
}

contour_points :: #force_inline proc "contextless" (c: ^Tessellation, ct: Contour) -> []Point {
	return c.points[ct.point_start:ct.point_end]
}

// Rebuilds `c` from `p` under `t`, reusing its buffers.
tessellation_build :: proc(c: ^Tessellation, p: ^Path, t: Transform2D, tess_tol, dist_tol: f32) {
	clear(&c.contours)
	clear(&c.points)
	clear(&c.fill_verts)
	clear(&c.stroke_verts)
	c.bounds = EMPTY_BOUNDS
	c.flipped = false

	it := path_iter(p)
	for verb, coords in path_iter_next(&it) {
		switch verb {
		case .Move_To:
			add_contour(c)
			q := transform_point(t, coords[0].x, coords[0].y)
			add_point(c, q, {.Corner}, dist_tol)
		case .Line_To:
			q := transform_point(t, coords[0].x, coords[0].y)
			add_point(c, q, {.Corner}, dist_tol)
		case .Bezier_To:
			if len(c.points) == 0 {
				continue
			}
			last := c.points[len(c.points) - 1].pos
			q1 := transform_point(t, coords[0].x, coords[0].y)
			q2 := transform_point(t, coords[1].x, coords[1].y)
			q3 := transform_point(t, coords[2].x, coords[2].y)
			tesselate_bezier(c, last, q1, q2, q3, 0, {.Corner}, tess_tol, dist_tol)
		case .Close:
			if len(c.contours) != 0 {
				c.contours[len(c.contours) - 1].closed = true
			}
		case .Solid:
			if len(c.contours) != 0 {
				c.contours[len(c.contours) - 1].solidity = .Solid
			}
		case .Hole:
			if len(c.contours) != 0 {
				c.contours[len(c.contours) - 1].solidity = .Hole
			}
		}
	}

	// Drop degenerate contours, fuse a closing point that duplicates the
	// first, enforce winding, and compute segment directions and bounds.
	write := 0
	largest: f32 = 0
	for read in 0 ..< len(c.contours) {
		ct := c.contours[read]
		pts := contour_points(c, ct)
		if len(pts) >= 2 && points_equal(pts[len(pts) - 1].pos, pts[0].pos, dist_tol) {
			ct.point_end -= 1
			ct.closed = true
			pts = contour_points(c, ct)
		}
		if len(pts) < 2 {
			continue
		}
		area := polygon_area(pts)
		if (ct.solidity == .Solid && area < 0) || (ct.solidity == .Hole && area > 0) {
			slice.reverse(pts)
			area = -area
		}
		if abs(area) > abs(largest) {
			largest = area
		}
		ct.zero_area = abs(area) < 1e-4
		for i in 0 ..< len(pts) {
			p0 := &pts[len(pts) - 1 if i == 0 else i - 1]
			p0.dpos = pts[i].pos - p0.pos
			p0.len = normalize(&p0.dpos)
			c.bounds.minx = min(c.bounds.minx, p0.pos.x)
			c.bounds.miny = min(c.bounds.miny, p0.pos.y)
			c.bounds.maxx = max(c.bounds.maxx, p0.pos.x)
			c.bounds.maxy = max(c.bounds.maxy, p0.pos.y)
		}
		c.contours[write] = ct
		write += 1
	}
	resize(&c.contours, write)
	c.fill_flip = largest < 0
}

// Stores every contour reversed when `flip` is set, forward otherwise.
// Reversing all contours negates every winding number, so the non-zero and
// even-odd fill stay the same while the fringe moves to the other side of
// each edge. Holes wound against the largest contour flip with it.
@(private = "file")
orient_contours :: proc(c: ^Tessellation, flip: bool) {
	if c.flipped == flip {
		return
	}
	c.flipped = flip
	for ct in c.contours {
		pts := contour_points(c, ct)
		slice.reverse(pts)
		for i in 0 ..< len(pts) {
			p0 := &pts[len(pts) - 1 if i == 0 else i - 1]
			p0.dpos = pts[i].pos - p0.pos
			p0.len = normalize(&p0.dpos)
		}
	}
}

@(private = "file")
add_contour :: proc(c: ^Tessellation) {
	start := u32(len(c.points))
	append(&c.contours, Contour{point_start = start, point_end = start})
}

@(private = "file")
add_point :: proc(c: ^Tessellation, pos: Vec2, flags: Point_Flags, dist_tol: f32) {
	if len(c.contours) == 0 {
		return
	}
	ct := &c.contours[len(c.contours) - 1]
	if ct.point_end > ct.point_start {
		last := &c.points[ct.point_end - 1]
		if points_equal(last.pos, pos, dist_tol) {
			last.flags += flags
			return
		}
	}
	append(&c.points, Point{pos = pos, flags = flags})
	ct.point_end += 1
}

@(private = "file")
tesselate_bezier :: proc(c: ^Tessellation, p1, p2, p3, p4: Vec2, level: int, flags: Point_Flags, tess_tol, dist_tol: f32) {
	if level > 10 {
		return
	}
	p12 := (p1 + p2) * 0.5
	p23 := (p2 + p3) * 0.5
	p34 := (p3 + p4) * 0.5
	p123 := (p12 + p23) * 0.5

	dx := p4.x - p1.x
	dy := p4.y - p1.y
	d2 := abs((p2.x - p4.x) * dy - (p2.y - p4.y) * dx)
	d3 := abs((p3.x - p4.x) * dy - (p3.y - p4.y) * dx)
	if (d2 + d3) * (d2 + d3) < tess_tol * (dx * dx + dy * dy) {
		add_point(c, p4, flags, dist_tol)
		return
	}

	p234 := (p23 + p34) * 0.5
	p1234 := (p123 + p234) * 0.5
	tesselate_bezier(c, p1, p12, p123, p1234, level + 1, {}, tess_tol, dist_tol)
	tesselate_bezier(c, p1234, p234, p34, p4, level + 1, flags, tess_tol, dist_tol)
}

tessellation_contains_point :: proc(c: ^Tessellation, x, y: f32, rule: Fill_Rule) -> bool {
	if !bounds_contains(c.bounds, x, y) {
		return false
	}
	// Crossings of all contours add up, so holes are outside.
	crossings, winding := 0, 0
	for ct in c.contours {
		pts := contour_points(c, ct)
		for i in 0 ..< len(pts) {
			p0 := pts[len(pts) - 1 if i == 0 else i - 1].pos
			p1 := pts[i].pos
			// Edges crossing the ray to the right of the point.
			if p0.y <= y {
				if p1.y > y && is_left(p0, p1, x, y) > 0 {
					crossings += 1
					winding += 1
				}
			} else if p1.y <= y && is_left(p0, p1, x, y) < 0 {
				crossings += 1
				winding -= 1
			}
		}
	}
	return winding != 0 if rule == .Non_Zero else crossings % 2 != 0
}

@(private = "file")
is_left :: proc "contextless" (p0, p1: Vec2, x, y: f32) -> f32 {
	return dot(p1 - p0, orthogonal(Vec2{x, y} - p0))
}

// Builds fill triangles (fan converted to a list) and, with a fringe, the
// antialiasing strip around each contour.
tessellation_fill :: proc(c: ^Tessellation, fringe_width: f32, line_join: Line_Join, miter_limit: f32) {
	has_fringe := fringe_width > 0
	orient_contours(c, c.fill_flip)
	calculate_joins(c, fringe_width, line_join, miter_limit)
	clear(&c.fill_verts)
	clear(&c.stroke_verts)

	convex := len(c.contours) == 1 && c.contours[0].convexity == .Convex
	woff := 0.5 * fringe_width

	for &ct in c.contours {
		if ct.zero_area {
			// No area: neither fill nor fringe (a line's fringe would
			// draw the line).
			ct.fill, ct.stroke = {}, {}
			continue
		}
		pts := contour_points(c, ct)
		clear(&c.fan)
		if has_fringe {
			for i in 0 ..< len(pts) {
				p0 := pts[len(pts) - 1 if i == 0 else i - 1]
				p1 := pts[i]
				if .Bevel in p1.flags {
					if .Left in p1.flags {
						append(&c.fan, vtx(p1.pos + p1.dmpos * woff, 0.5, 1))
					} else {
						append(&c.fan, vtx(p1.pos + orthogonal(p0.dpos) * woff, 0.5, 1))
						append(&c.fan, vtx(p1.pos + orthogonal(p1.dpos) * woff, 0.5, 1))
					}
				} else {
					append(&c.fan, vtx(p1.pos + p1.dmpos * woff, 0.5, 1))
				}
			}
		} else {
			for p in pts {
				append(&c.fan, vtx(p.pos, 0.5, 1))
			}
		}

		fill_start := u32(len(c.fill_verts))
		if len(c.fan) > 2 {
			center := c.fan[0]
			for i in 1 ..< len(c.fan) - 1 {
				push3(&c.fill_verts, center, c.fan[i], c.fan[i + 1])
			}
		}
		ct.fill = {fill_start, u32(len(c.fill_verts)) - fill_start}

		stroke_start := u32(len(c.stroke_verts))
		if has_fringe {
			rw := fringe_width - woff
			ru: f32 = 1
			lw, lu: f32 = woff, 0.5
			if !convex {
				lw, lu = fringe_width + woff, 0
			}
			for i in 0 ..< len(pts) {
				p0 := pts[len(pts) - 1 if i == 0 else i - 1]
				p1 := pts[i]
				if .Bevel in p1.flags || .Inner_Bevel in p1.flags {
					bevel_join(&c.stroke_verts, p0, p1, lw, rw, lu, ru)
				} else {
					push2(&c.stroke_verts, vtx(p1.pos + p1.dmpos * lw, lu, 1), vtx(p1.pos - p1.dmpos * rw, ru, 1))
				}
			}
			// Close the loop.
			a := c.stroke_verts[stroke_start]
			b := c.stroke_verts[stroke_start + 1]
			push2(&c.stroke_verts, Path_Vertex{a.x, a.y, lu, 1}, Path_Vertex{b.x, b.y, ru, 1})
		}
		ct.stroke = {stroke_start, u32(len(c.stroke_verts)) - stroke_start}
	}
}

// Builds the stroke strip of each contour. `stroke_width` is half the line
// width.
tessellation_stroke :: proc(
	c: ^Tessellation,
	stroke_width_in: f32,
	fringe_width: f32,
	line_cap_start, line_cap_end: Line_Cap,
	line_join: Line_Join,
	miter_limit: f32,
	tess_tol: f32,
) {
	ncap := curve_divisions(stroke_width_in, math.PI, tess_tol)
	stroke_width := stroke_width_in + fringe_width * 0.5
	uv0, uv1: f32 = 0, 1
	if fringe_width == 0 {
		uv0, uv1 = 0.5, 0.5
	}

	orient_contours(c, false)
	calculate_joins(c, stroke_width, line_join, miter_limit)
	clear(&c.fill_verts)
	clear(&c.stroke_verts)

	for &ct in c.contours {
		pts := contour_points(c, ct)
		pc := len(pts)
		v := &c.stroke_verts
		start := u32(len(v))
		ct.fill = {}

		for i in 0 ..< pc {
			p0 := pts[pc - 1 if i == 0 else i - 1]
			p1 := pts[i]

			if !ct.closed && i == 1 {
				switch line_cap_start {
				case .Butt:
					butt_cap_start(v, p0, p0, stroke_width, -fringe_width * 0.5, fringe_width, uv0, uv1)
				case .Square:
					butt_cap_start(v, p0, p0, stroke_width, stroke_width - fringe_width, fringe_width, uv0, uv1)
				case .Round:
					round_cap_start(v, p0, p0, stroke_width, ncap, uv0, uv1)
				}
			}

			if (i > 0 && i < pc - 1) || ct.closed {
				if .Bevel in p1.flags || .Inner_Bevel in p1.flags {
					if line_join == .Round {
						round_join(v, p0, p1, stroke_width, stroke_width, uv0, uv1, ncap)
					} else {
						bevel_join(v, p0, p1, stroke_width, stroke_width, uv0, uv1)
					}
				} else {
					push2(v, vtx(p1.pos + p1.dmpos * stroke_width, uv0, 1), vtx(p1.pos - p1.dmpos * stroke_width, uv1, 1))
				}
			}

			if !ct.closed && i == pc - 1 {
				switch line_cap_end {
				case .Butt:
					butt_cap_end(v, p1, p0, stroke_width, -fringe_width * 0.5, fringe_width, uv0, uv1)
				case .Square:
					butt_cap_end(v, p1, p0, stroke_width, stroke_width - fringe_width, fringe_width, uv0, uv1)
				case .Round:
					round_cap_end(v, p1, p0, stroke_width, ncap, uv0, uv1)
				}
			}
		}

		if ct.closed && u32(len(v)) >= start + 2 {
			a := v[start]
			b := v[start + 1]
			push2(v, Path_Vertex{a.x, a.y, uv0, 1}, Path_Vertex{b.x, b.y, uv1, 1})
		}
		ct.stroke = {start, u32(len(v)) - start}
	}
}

@(private = "file")
calculate_joins :: proc(c: ^Tessellation, stroke_width: f32, line_join: Line_Join, miter_limit: f32) {
	inv_sw: f32 = 1.0 / stroke_width if stroke_width > 0 else 0

	for &ct in c.contours {
		pts := contour_points(c, ct)
		nleft := 0
		ct.bevel = 0
		x_sign, y_sign, x_first_sign, y_first_sign := 0, 0, 0, 0
		x_flips, y_flips := 0, 0

		for i in 0 ..< len(pts) {
			p0 := pts[len(pts) - 1 if i == 0 else i - 1]
			p1 := &pts[i]

			dl0 := orthogonal(p0.dpos)
			dl1 := orthogonal(p1.dpos)
			p1.dmpos = (dl0 + dl1) * 0.5
			dmr2 := mag2(p1.dmpos)
			if dmr2 > 0.000_001 {
				p1.dmpos *= min(1.0 / dmr2, 600.0)
			}

			// Keep only the corner marker.
			p1.flags &= {.Corner}

			if cross(p0.dpos, p1.dpos) > 0 {
				nleft += 1
				p1.flags += {.Left}
			}

			if p1.dpos.x > 0 {
				if x_sign == 0 {
					x_first_sign = 1
				} else if x_sign < 0 {
					x_flips += 1
				}
				x_sign = 1
			} else if p1.dpos.x < 0 {
				if x_sign == 0 {
					x_first_sign = -1
				} else if x_sign > 0 {
					x_flips += 1
				}
				x_sign = -1
			}

			if p1.dpos.y > 0 {
				if y_sign == 0 {
					y_first_sign = 1
				} else if y_sign < 0 {
					y_flips += 1
				}
				y_sign = 1
			} else if p1.dpos.y < 0 {
				if y_sign == 0 {
					y_first_sign = -1
				} else if y_sign > 0 {
					y_flips += 1
				}
				y_sign = -1
			}

			limit := max(min(p0.len, p1.len) * inv_sw, 1.01)
			if dmr2 * limit * limit < 1 {
				p1.flags += {.Inner_Bevel}
			}
			if .Corner in p1.flags {
				if dmr2 * miter_limit * miter_limit < 1 || line_join == .Bevel || line_join == .Round {
					p1.flags += {.Bevel}
				}
			}
			if .Bevel in p1.flags || .Inner_Bevel in p1.flags {
				ct.bevel += 1
			}
		}

		if x_sign != 0 && x_first_sign != 0 && x_sign != x_first_sign {
			x_flips += 1
		}
		if y_sign != 0 && y_first_sign != 0 && y_sign != y_first_sign {
			y_flips += 1
		}
		convex_shape := x_flips == 2 && y_flips == 2
		ct.convexity = .Convex if nleft == len(pts) && convex_shape else .Concave
	}
}

// The axis-aligned rectangle, if the path is exactly one filled rectangle.
tessellation_fill_is_rect :: proc(c: ^Tessellation) -> (Rect, bool) {
	if len(c.contours) != 1 || c.contours[0].fill.count != 6 {
		return {}, false
	}
	v := c.fill_verts[c.contours[0].fill.start:][:6]
	tl, bl, br, tl2, br2, tr := v[0], v[1], v[2], v[3], v[4], v[5]
	if tl == tl2 && br == br2 && tl.x == bl.x && tl.y == tr.y && br.x == tr.x && br2.y == bl.y {
		return {tl.x, tl.y, tr.x - tl.x, bl.y - tl.y}, true
	}
	return {}, false
}

// A tessellated point and its (u, v) (see `Vertex`), before the canvas
// gives it a paint.
Path_Vertex :: struct {
	x, y, u, v: f32,
}

@(private = "file")
vtx :: #force_inline proc "contextless" (p: Vec2, u, v: f32) -> Path_Vertex {
	return {p.x, p.y, u, v}
}

@(private = "file")
polygon_area :: proc "contextless" (pts: []Point) -> f32 {
	area: f32 = 0
	for i in 0 ..< len(pts) {
		p0 := pts[len(pts) - 1 if i == 0 else i - 1].pos
		p1 := pts[i].pos
		area += (p1.x - p0.x) * (p1.y + p0.y)
	}
	return area * 0.5
}

@(private = "file")
curve_divisions :: proc "contextless" (radius, arc, tol: f32) -> int {
	da := math.acos(radius / (radius + tol)) * 2
	return max(int(math.ceil(arc / da)), 2)
}

@(private = "file")
butt_cap_start :: proc(v: ^[dynamic]Path_Vertex, p0, p1: Point, w, d, aa, uv0, uv1: f32) {
	ppos := p0.pos - p1.dpos * d
	dl := orthogonal(p1.dpos)
	push4(v, vtx(ppos + dl * w - p1.dpos * aa, uv0, 0), vtx(ppos - dl * w - p1.dpos * aa, uv1, 0), vtx(ppos + dl * w, uv0, 1), vtx(ppos - dl * w, uv1, 1))
}

@(private = "file")
butt_cap_end :: proc(v: ^[dynamic]Path_Vertex, p0, p1: Point, w, d, aa, uv0, uv1: f32) {
	ppos := p0.pos + p1.dpos * d
	dl := orthogonal(p1.dpos)
	push4(v, vtx(ppos + dl * w, uv0, 1), vtx(ppos - dl * w, uv1, 1), vtx(ppos + dl * w + p1.dpos * aa, uv0, 0), vtx(ppos - dl * w + p1.dpos * aa, uv1, 0))
}

@(private = "file")
round_cap_start :: proc(v: ^[dynamic]Path_Vertex, p0, p1: Point, w: f32, ncap: int, uv0, uv1: f32) {
	ppos := p0.pos
	dl := orthogonal(p1.dpos)
	for i in 0 ..< ncap {
		a := f32(i) / f32(ncap - 1) * math.PI
		offset := with_basis(from_angle(a), -dl, -p1.dpos) * w
		push2(v, vtx(ppos + offset, uv0, 1), vtx(ppos, 0.5, 1))
	}
	push2(v, vtx(ppos + dl * w, uv0, 1), vtx(ppos - dl * w, uv1, 1))
}

@(private = "file")
round_cap_end :: proc(v: ^[dynamic]Path_Vertex, p0, p1: Point, w: f32, ncap: int, uv0, uv1: f32) {
	ppos := p0.pos
	dl := orthogonal(p1.dpos)
	push2(v, vtx(ppos + dl * w, uv0, 1), vtx(ppos - dl * w, uv1, 1))
	for i in 0 ..< ncap {
		a := f32(i) / f32(ncap - 1) * math.PI
		offset := with_basis(from_angle(a), -dl, p1.dpos) * w
		push2(v, vtx(ppos, 0.5, 1), vtx(ppos + offset, uv0, 1))
	}
}

@(private = "file")
choose_bevel :: proc "contextless" (bevel: bool, p0, p1: Point, w: f32) -> (Vec2, Vec2) {
	if bevel {
		return p1.pos + orthogonal(p0.dpos) * w, p1.pos + orthogonal(p1.dpos) * w
	}
	pos := p1.pos + p1.dmpos * w
	return pos, pos
}

@(private = "file")
round_join :: proc(v: ^[dynamic]Path_Vertex, p0, p1: Point, lw, rw, lu, ru: f32, ncap: int) {
	dl0 := orthogonal(p0.dpos)
	dl1 := orthogonal(p1.dpos)

	if .Left in p1.flags {
		la, lb := choose_bevel(.Inner_Bevel in p1.flags, p0, p1, lw)
		a0 := angle(-dl0)
		a1 := angle(-dl1)
		if a1 > a0 {
			a1 -= math.TAU
		}
		push2(v, vtx(la, lu, 1), vtx(p1.pos - dl0 * rw, ru, 1))
		n := clamp(int(math.ceil((a0 - a1) / math.PI * f32(ncap))), 2, ncap)
		for i in 0 ..< n {
			u := f32(i) / f32(n - 1)
			a := a0 + u * (a1 - a0)
			push2(v, vtx(p1.pos, 0.5, 1), vtx(p1.pos + from_angle(a) * rw, ru, 1))
		}
		push2(v, vtx(lb, lu, 1), vtx(p1.pos - dl1 * rw, ru, 1))
	} else {
		ra, rb := choose_bevel(.Inner_Bevel in p1.flags, p0, p1, -rw)
		a0 := angle(dl0)
		a1 := angle(dl1)
		if a1 < a0 {
			a1 += math.TAU
		}
		push2(v, vtx(p1.pos + dl0 * rw, lu, 1), vtx(ra, ru, 1))
		n := clamp(int(math.ceil((a1 - a0) / math.PI * f32(ncap))), 2, ncap)
		for i in 0 ..< n {
			u := f32(i) / f32(n - 1)
			a := a0 + u * (a1 - a0)
			push2(v, vtx(p1.pos + from_angle(a) * lw, lu, 1), vtx(p1.pos, 0.5, 1))
		}
		push2(v, vtx(p1.pos + dl1 * rw, lu, 1), vtx(rb, ru, 1))
	}
}

@(private = "file")
bevel_join :: proc(v: ^[dynamic]Path_Vertex, p0, p1: Point, lw, rw, lu, ru: f32) {
	dl0 := orthogonal(p0.dpos)
	dl1 := orthogonal(p1.dpos)

	if .Left in p1.flags {
		la, lb := choose_bevel(.Inner_Bevel in p1.flags, p0, p1, lw)
		push2(v, vtx(la, lu, 1), vtx(p1.pos - dl0 * rw, ru, 1))
		if .Bevel in p1.flags {
			push2(v, vtx(la, lu, 1), vtx(p1.pos - dl0 * rw, ru, 1))
			push2(v, vtx(lb, lu, 1), vtx(p1.pos - dl1 * rw, ru, 1))
		} else {
			r0 := p1.pos - p1.dmpos * rw
			push2(v, vtx(p1.pos, 0.5, 1), vtx(p1.pos - dl0 * rw, ru, 1))
			push2(v, vtx(r0, ru, 1), vtx(r0, ru, 1))
			push2(v, vtx(p1.pos, 0.5, 1), vtx(p1.pos - dl1 * rw, ru, 1))
		}
		push2(v, vtx(lb, lu, 1), vtx(p1.pos - dl1 * rw, ru, 1))
	} else {
		ra, rb := choose_bevel(.Inner_Bevel in p1.flags, p0, p1, -rw)
		push2(v, vtx(p1.pos + dl0 * lw, lu, 1), vtx(ra, ru, 1))
		if .Bevel in p1.flags {
			push2(v, vtx(p1.pos + dl0 * lw, lu, 1), vtx(ra, ru, 1))
			push2(v, vtx(p1.pos + dl1 * lw, lu, 1), vtx(rb, ru, 1))
		} else {
			l0 := p1.pos + p1.dmpos * lw
			push2(v, vtx(p1.pos + dl0 * lw, lu, 1), vtx(p1.pos, 0.5, 1))
			push2(v, vtx(l0, lu, 1), vtx(l0, lu, 1))
			push2(v, vtx(p1.pos + dl1 * lw, lu, 1), vtx(p1.pos, 0.5, 1))
		}
		push2(v, vtx(p1.pos + dl1 * lw, lu, 1), vtx(rb, ru, 1))
	}
}

// Appends 2, 3 or 4 vertices with direct writes: append's variadic form
// copies them through memcpy, which profiles showed as a fifth of a frame.
@(private = "file")
push_n :: #force_inline proc(v: ^[dynamic]Path_Vertex, n: int) -> []Path_Vertex {
	at := len(v)
	if at + n > cap(v) {
		reserve(v, max(2 * cap(v), at + n, 64))
	}
	(^runtime.Raw_Dynamic_Array)(v).len = at + n
	return v[at:][:n]
}

@(private = "file")
push2 :: #force_inline proc(v: ^[dynamic]Path_Vertex, a, b: Path_Vertex) {
	out := push_n(v, 2)
	out[0], out[1] = a, b
}

@(private = "file")
push3 :: #force_inline proc(v: ^[dynamic]Path_Vertex, a, b, c: Path_Vertex) {
	out := push_n(v, 3)
	out[0], out[1], out[2] = a, b, c
}

@(private = "file")
push4 :: #force_inline proc(v: ^[dynamic]Path_Vertex, a, b, c, d: Path_Vertex) {
	out := push_n(v, 4)
	out[0], out[1], out[2], out[3] = a, b, c, d
}
