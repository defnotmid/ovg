package ovg

import "core:math"

// Strokes as fills: a path's stroke becomes contours whose non-zero fill is
// the stroked area (each contour's outline: one side's offset forward, a
// cap, the other side's back, a cap; a closed contour's two sides apart),
// filled by coverage like any path. The outline is made in path units and
// then transformed, so a stroke under a non-uniform scale is the scaled
// stroke. Every contour winds negative (an open outline always does; a
// closed contour's outer ring is negative and its inner ring positive, so
// it keeps its hole), so where strokes cross, their windings add.
//
// Lines offset to lines and quadratics to quadratics (the offset ends'
// tangents meet at the control point), split until within the tolerance;
// cubics are quadratics first. A quadratic bending tighter than the stroke
// is wide (its inner offset would fold) is lines instead, each inner join
// passing through the point it turns at.

// Adds the stroke of `p` with `s` to the scratch's builder under `t`, as
// contours to fill non-zero, within `tol` path units: dashed in path units
// (at most `max_dashes` segments; false when they ran out), outlined, and
// the dots of zero-length subpaths' caps.
@(private)
stroke_add :: proc(scratch: ^Shape_Scratch, p: ^Path, t: Transform2D, s: Stroke_Settings, tol: f32, max_dashes: int) -> (complete: bool) {
	b := &scratch.builder
	complete = true
	p := p
	if len(s.dash) > 0 {
		path_reset(&scratch.dashed)
		complete = path_dash(p, s.dash, s.dash_offset, s.path_length, &scratch.dashed, &scratch.flat, max_dashes)
		p = &scratch.dashed
	}
	stroke_outline(b, p, t, s, tol, &scratch.segs)
	if s.line_cap_start != .Butt || s.line_cap_end != .Butt {
		// Zero length: within about a hundredth of a pixel.
		stroke_dots(p, s, tol * 0.16, &scratch.dots)
		shape_add_path(b, &scratch.dots, t)
	}
	return
}

// A line or quadratic of a contour. `corner`: its start is one of the
// path's own points, where the stroke's join applies (else it continues a
// curve).
@(private)
Stroke_Seg :: struct {
	p0, c, p1: Vec2,
	// Its directions at p0 and p1.
	d0, d1:    Vec2,
	line:      bool,
	corner:    bool,
}

// Adds the outline of `p`'s stroke to `b` under `t`, within `tol` path
// units. `segs` is scratch.
@(private = "file")
stroke_outline :: proc(b: ^Shape_Builder, p: ^Path, t: Transform2D, s: Stroke_Settings, tol: f32, segs: ^[dynamic]Stroke_Seg) {
	o := Outliner {
		b     = b,
		t     = t,
		hw    = s.line_width * 0.5,
		tol   = tol,
		join  = s.line_join,
		limit = s.miter_limit,
		caps  = {s.line_cap_start, s.line_cap_end},
	}
	if o.hw <= 0 {
		return
	}
	clear(segs)
	start, last: Vec2
	moved := false
	it := path_iter(p)
	for verb, coords in path_iter_next(&it) {
		switch verb {
		case .Move_To:
			outline_contour(&o, segs[:], false)
			clear(segs)
			start, last, moved = coords[0], coords[0], true
		case .Line_To:
			if moved {
				add_line(&o, segs, last, coords[0], true)
				last = coords[0]
			}
		case .Bezier_To:
			if !moved {
				continue
			}
			// n quadratics, each the midpoint approximation of its piece:
			// within sqrt(3)/36 |p3 - 3 c2 + 3 c1 - p0| / n^3 (curves.odin).
			p0, c1, c2, p3 := last, coords[0], coords[1], coords[2]
			d := p3 - 3 * c2 + 3 * c1 - p0
			n := clamp(int(math.ceil(math.cbrt(math.sqrt(f32(3)) / 36 * math.hypot(d.x, d.y) / tol))), 1, 64)
			from := p0
			for i in 0 ..< n {
				a0, a1, a2, a3 := cubic_split(p0, c1, c2, p3, f32(i) / f32(n), f32(i + 1) / f32(n))
				to := a3 if i < n - 1 else p3
				add_quad(&o, segs, from, (3 * (a1 + a2) - a0 - a3) * 0.25, to, i == 0)
				from = to
			}
			last = p3
		case .Close:
			if moved {
				add_line(&o, segs, last, start, true)
				outline_contour(&o, segs[:], true)
				clear(segs)
				// A segment after a close starts where the contour started.
				last = start
			}
		case .Solid, .Hole:
		}
	}
	outline_contour(&o, segs[:], false)
}

// The cubic's control points restricted to [t0, t1].
@(private)
cubic_split :: proc "contextless" (p0, p1, p2, p3: Vec2, t0, t1: f32) -> (a, b, c, d: Vec2) {
	at :: proc "contextless" (p0, p1, p2, p3: Vec2, t: f32) -> Vec2 {
		u := 1 - t
		return u * u * u * p0 + 3 * u * u * t * p1 + 3 * u * t * t * p2 + t * t * t * p3
	}
	tangent :: proc "contextless" (p0, p1, p2, p3: Vec2, t: f32) -> Vec2 {
		u := 1 - t
		return 3 * (u * u * (p1 - p0) + 2 * u * t * (p2 - p1) + t * t * (p3 - p2))
	}
	h := (t1 - t0) / 3
	a = at(p0, p1, p2, p3, t0)
	d = at(p0, p1, p2, p3, t1)
	return a, a + tangent(p0, p1, p2, p3, t0) * h, d - tangent(p0, p1, p2, p3, t1) * h, d
}

@(private = "file")
Outliner :: struct {
	b:       ^Shape_Builder,
	t:       Transform2D,
	hw, tol: f32,
	join:    Line_Join,
	limit:   f32,
	caps:    [2]Line_Cap,
	// A contour is open in the builder.
	started: bool,
}

@(private = "file")
add_line :: proc(o: ^Outliner, segs: ^[dynamic]Stroke_Seg, p0, p1: Vec2, corner: bool) {
	if l := math.hypot(p1.x - p0.x, p1.y - p0.y); l > o.tol * 0.01 {
		d := (p1 - p0) / l
		append(segs, Stroke_Seg{p0, (p0 + p1) * 0.5, p1, d, d, true, corner})
	}
}

@(private = "file")
add_quad :: proc(o: ^Outliner, segs: ^[dynamic]Stroke_Seg, p0, c, p1: Vec2, corner: bool) {
	a, b := c - p0, p0 - 2 * c + p1
	if abs(cross(a, b)) <= 1e-6 * dot(a, a) + 1e-12 {
		// Straight (or its control on an end).
		add_line(o, segs, p0, p1, corner)
		return
	}
	// Its greatest curvature, where it moves slowest: |a x b| / 2 |q'/2|^3.
	t := clamp(-dot(a, b) / dot(b, b), 0, 1)
	v := a + t * b
	speed := math.hypot(v.x, v.y)
	if abs(cross(a, b)) * o.hw > speed * speed * speed {
		// Bends tighter than twice the half width: lines within tol.
		n := clamp(int(math.ceil(math.sqrt(math.hypot(b.x, b.y) / (4 * o.tol)))), 1, 256)
		from := p0
		for i in 1 ..= n {
			u := f32(i) / f32(n)
			to := (1 - u) * (1 - u) * p0 + 2 * u * (1 - u) * c + u * u * p1
			add_line(o, segs, from, to, corner && i == 1)
			from = to
		}
		return
	}
	append(segs, Stroke_Seg{p0, c, p1, unit(c - p0), unit(p1 - c), false, corner})
}

@(private = "file")
emit :: proc(o: ^Outliner, p: Vec2) {
	q := transform_point(o.t, p.x, p.y)
	if o.started {
		shape_line_to(o.b, q)
	} else {
		shape_move_to(o.b, q)
		o.started = true
	}
}

@(private = "file")
emit_quad :: proc(o: ^Outliner, c, p: Vec2) {
	shape_quad_to(o.b, transform_point(o.t, c.x, c.y), transform_point(o.t, p.x, p.y))
}

@(private = "file")
finish :: proc(o: ^Outliner) {
	shape_close(o.b)
	o.started = false
}

@(private = "file")
perp :: #force_inline proc "contextless" (d: Vec2) -> Vec2 {
	return {-d.y, d.x}
}

@(private = "file")
cross :: #force_inline proc "contextless" (a, b: Vec2) -> f32 {
	return a.x * b.y - a.y * b.x
}

@(private = "file")
dot :: #force_inline proc "contextless" (a, b: Vec2) -> f32 {
	return a.x * b.x + a.y * b.y
}

@(private = "file")
unit :: #force_inline proc "contextless" (v: Vec2) -> Vec2 {
	return v / math.hypot(v.x, v.y)
}

// The segment's directions at its start and end.
@(private = "file")
tangents :: #force_inline proc "contextless" (s: Stroke_Seg) -> (d0, d1: Vec2) {
	return s.d0, s.d1
}

// Segment i of the contour as traversed (`reverse`: from the end, each
// segment backwards, its corner the one at its new start).
@(private = "file")
seg_at :: proc "contextless" (segs: []Stroke_Seg, i: int, reverse, closed: bool) -> Stroke_Seg {
	if !reverse {
		return segs[i]
	}
	n := len(segs)
	k := n - 1 - i
	s := segs[k]
	s.p0, s.p1 = s.p1, s.p0
	s.d0, s.d1 = -s.d1, -s.d0
	s.corner = segs[(k + 1) % n].corner if k + 1 < n || closed else true
	return s
}

// One contour's outline: an open one as one contour, a closed one as its
// two sides (both negative when it encloses nothing, so the sides of a
// line there and back don't cancel).
@(private = "file")
outline_contour :: proc(o: ^Outliner, segs: []Stroke_Seg, closed: bool) {
	n := len(segs)
	if n == 0 {
		return
	}
	if !closed {
		side(o, segs, false, false)
		_, d := tangents(segs[n - 1])
		cap(o, segs[n - 1].p1, d, o.caps[1])
		side(o, segs, false, true)
		_, d = tangents(seg_at(segs, n - 1, true, false))
		cap(o, segs[0].p0, d, o.caps[0])
		finish(o)
		return
	}
	area: f32
	for s in segs {
		area += cross(s.p0, s.p1)
	}
	for reverse in ([2]bool{false, true}) {
		side(o, segs, true, reverse)
		finish(o)
		if area == 0 {
			shape_solidity(o.b, .Hole)
		}
	}
}

// The offset by +hw along the left normal of the contour as traversed,
// with the joins between its segments.
@(private = "file")
side :: proc(o: ^Outliner, segs: []Stroke_Seg, closed, reverse: bool) {
	n := len(segs)
	prev := seg_at(segs, n - 1, reverse, closed)
	for i in 0 ..< n {
		s := seg_at(segs, i, reverse, closed)
		d0, _ := tangents(s)
		if i > 0 || closed {
			_, e := tangents(prev)
			join(o, s.p0, e, d0, prev, s)
		} else {
			emit(o, s.p0 + perp(d0) * o.hw)
		}
		if s.line {
			emit(o, s.p1 + perp(d0) * o.hw)
		} else {
			offset_quad(o, s.p0, s.c, s.p1, 0)
		}
		prev = s
	}
}

// The quadratic's offset as quadratics: split while it turns by more than
// about 45 degrees or misses the true offset at its middle by over tol.
@(private = "file")
offset_quad :: proc(o: ^Outliner, p0, c, p1: Vec2, depth: int) {
	d0, d1 := unit(c - p0), unit(p1 - c)
	n0, n1 := perp(d0), perp(d1)
	dt := dot(d0, d1)
	ctrl := c + (n0 + n1) * (o.hw / (1 + dt))
	if depth < 8 {
		split := dt < 0.7
		if !split {
			// The offset's middle against the true offset there.
			mid := (p0 + 2 * c + p1) * 0.25 + perp(unit(p1 - p0)) * o.hw
			got := (p0 + n0 * o.hw + 2 * ctrl + p1 + n1 * o.hw) * 0.25
			split = math.hypot(got.x - mid.x, got.y - mid.y) > o.tol
		}
		if split {
			m := (p0 + 2 * c + p1) * 0.25
			offset_quad(o, p0, (p0 + c) * 0.5, m, depth + 1)
			offset_quad(o, m, (c + p1) * 0.5, p1, depth + 1)
			return
		}
	}
	emit_quad(o, ctrl, p1 + n1 * o.hw)
}

// The outline at point p, from segment `a` (ending in direction d0) to
// segment `b` (starting in d1), on the left side.
@(private = "file")
join :: proc(o: ^Outliner, p, d0, d1: Vec2, a, b: Stroke_Seg) {
	n0, n1 := perp(d0), perp(d1)
	from, to := p + n0 * o.hw, p + n1 * o.hw
	c, dt := cross(d0, d1), dot(d0, d1)
	if c == 0 && dt > 0 {
		emit(o, from)
		return
	}
	// Where the two offsets meet.
	miter := p + (n0 + n1) * (o.hw / (1 + dt)) if dt > -1 else from
	if c > 0 {
		// The inside of the turn: between lines, the offsets' crossing when
		// both reach it; else through p (the outline loops back over the
		// stroke).
		reach := math.hypot(miter.x - from.x, miter.y - from.y)
		if a.line && b.line && dt > -1 && reach <= math.hypot(a.p1.x - a.p0.x, a.p1.y - a.p0.y) && reach <= math.hypot(b.p1.x - b.p0.x, b.p1.y - b.p0.y) {
			emit(o, miter)
		} else {
			emit(o, from)
			emit(o, p)
			emit(o, to)
		}
		return
	}
	join := o.join
	if !b.corner {
		// A curve bends a little between its pieces; at a cusp it turns
		// round.
		if dt > 0.9 {
			emit(o, miter if a.line && b.line else to)
			return
		}
		join = .Round
	}
	emit(o, from)
	switch join {
	case .Miter:
		// SVG's miter ratio: 1 / sin of half the angle between the segments.
		if dt > -1 && 1 / math.sqrt((1 + dt) * 0.5) <= o.limit {
			emit(o, miter)
		}
		emit(o, to)
	case .Bevel:
		emit(o, to)
	case .Round:
		arc(o, p, n0, n1, d0 - d1)
	}
}

// A cap at the end p of a segment ending in direction d, from the left
// side's offset (already emitted) round to the right side's.
@(private = "file")
cap :: proc(o: ^Outliner, p, d: Vec2, style: Line_Cap) {
	n := perp(d)
	switch style {
	case .Butt:
		emit(o, p - n * o.hw)
	case .Square:
		emit(o, p + (n + d) * o.hw)
		emit(o, p + (d - n) * o.hw)
		emit(o, p - n * o.hw)
	case .Round:
		arc(o, p, n, -n, d)
	}
}

// The arc of radius hw around p from direction u to v through the side of
// `mid`, as quadratics of at most 45 degrees.
@(private = "file")
arc :: proc(o: ^Outliner, p, u, v, mid: Vec2) {
	m := unit(mid)
	half := math.acos(clamp(dot(u, m), -1, 1))
	k := max(1, int(math.ceil(2 * half / (math.PI / 4))))
	step := 2 * half / f32(k) * (1 if cross(u, m) > 0 else -1)
	a0 := math.atan2(u.y, u.x)
	r := o.hw / math.cos(step * 0.5)
	for i in 1 ..= k {
		ac := a0 + step * (f32(i) - 0.5)
		to := p + v * o.hw
		if i < k {
			ai := a0 + step * f32(i)
			to = p + Vec2{math.cos(ai), math.sin(ai)} * o.hw
		}
		emit_quad(o, p + Vec2{math.cos(ac), math.sin(ac)} * r, to)
	}
}

// Zero-length subpaths ("M p L p", "M p Z", zero dashes) have no stroke
// geometry, but round and square caps still draw a dot there (SVG): the
// dots into `dots`, wound as the stroke's outlines are; subpaths up to
// `tol` long count.
@(private = "file")
stroke_dots :: proc(p: ^Path, s: Stroke_Settings, tol: f32, dots: ^Path) {
	path_reset(dots)
	hw := s.line_width * 0.5
	caps := [2]Line_Cap{s.line_cap_start, s.line_cap_end}
	start, last, dir: Vec2
	length: f32
	open, has_seg := false, false
	// The dot is the start cap behind the subpath's direction and the end
	// cap ahead of it, each its own style.
	finish :: proc(dots: ^Path, open, has_seg: bool, length, tol: f32, at, dir: Vec2, hw: f32, caps: [2]Line_Cap) {
		if !open || !has_seg || length > tol {
			return
		}
		if caps == {.Round, .Round} {
			path_circle(dots, at.x, at.y, hw)
			path_solidity(dots, .Hole)
			return
		}
		d := dir if dir != {} else Vec2{1, 0}
		n := Vec2{-d.y, d.x}
		// One cap's half, from `at + from * hw` round to `at - from * hw`
		// on the `side` half-plane.
		half :: proc(dots: ^Path, at, from, side: Vec2, hw: f32, cap: Line_Cap) {
			switch cap {
			case .Butt:
			case .Square:
				for q in ([2]Vec2{at + (from + side) * hw, at + (side - from) * hw}) {
					path_line_to(dots, q.x, q.y)
				}
			case .Round:
				// Half a circle from `from` through `side` (path_arc: .Hole
				// sweeps to larger angles).
				a0 := math.atan2(from.y, from.x)
				up := from.x * side.y - from.y * side.x > 0
				path_arc(dots, at.x, at.y, hw, a0, a0 + (math.PI if up else -math.PI), .Hole if up else .Solid)
			}
			e := at - from * hw
			path_line_to(dots, e.x, e.y)
		}
		s := at + n * hw
		path_move_to(dots, s.x, s.y)
		half(dots, at, n, d, hw, caps[1])
		half(dots, at, -n, -d, hw, caps[0])
		path_close(dots)
		path_solidity(dots, .Hole)
	}
	it := path_iter(p)
	for verb, coords in path_iter_next(&it) {
		switch verb {
		case .Move_To:
			finish(dots, open, has_seg, length, tol, start, dir, hw, caps)
			start, last = coords[0], coords[0]
			length, dir = 0, {}
			open, has_seg = true, false
		case .Line_To, .Bezier_To:
			to := coords[len(coords) - 1]
			d := coords[0] - last
			if l := math.hypot(d.x, d.y); l > 0 && dir == {} {
				dir = d / l
			}
			for q in coords {
				e := q - last
				length += math.hypot(e.x, e.y)
				last = q
			}
			last = to
			has_seg = true
		case .Close:
			has_seg = true
			finish(dots, open, has_seg, length, tol, start, dir, hw, caps)
			open = false
		case .Solid, .Hole:
		}
	}
	finish(dots, open, has_seg, length, tol, start, dir, hw, caps)
}
