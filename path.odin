package ovg

import "core:math"

// Cubic bezier handle length (relative to radius) for a 90 degree arc.
KAPPA90 :: 0.5522848

DEFAULT_DIST_TOL :: 0.01

Verb :: enum u8 {
	Move_To,
	Line_To,
	Bezier_To,
	Solid,
	Hole,
	Close,
}

verb_num_coords :: proc "contextless" (v: Verb) -> int {
	switch v {
	case .Move_To, .Line_To:
		return 1
	case .Bezier_To:
		return 3
	case .Solid, .Hole, .Close:
		return 0
	}
	return 0
}

// A vector path: verbs plus their coordinates, read-only while drawn (one
// path can be drawn by several canvases at once). Reuse a `Path` across
// frames (`path_reset`) to keep its buffers. Uses the context allocator
// current at the first append.
Path :: struct {
	verbs:    [dynamic]Verb,
	coords:   [dynamic]Vec2,
	last_pos: Vec2,
	// Tolerance for merging points in `path_arc_to`; 0 means the default.
	dist_tol: f32,
}

// A path allocating from `allocator`.
path_init :: proc(p: ^Path, allocator := context.allocator) {
	p^ = {}
	p.verbs.allocator, p.coords.allocator = allocator, allocator
}

path_destroy :: proc(p: ^Path) {
	delete(p.verbs)
	delete(p.coords)
	p^ = {}
}

// Clears the path but keeps its allocations.
path_reset :: proc(p: ^Path) {
	clear(&p.verbs)
	clear(&p.coords)
	p.last_pos = {}
}

path_is_empty :: proc "contextless" (p: ^Path) -> bool {
	return len(p.verbs) == 0
}

// Appends verbs and their coordinates (`verb_num_coords` each), e.g. path
// data parsed once and drawn many times.
path_append :: proc(p: ^Path, verbs: []Verb, coords: []Vec2) {
	if len(coords) != 0 {
		p.last_pos = coords[len(coords) - 1]
	}
	append(&p.verbs, ..verbs)
	append(&p.coords, ..coords)
}

path_move_to :: proc(p: ^Path, x, y: f32) {
	path_append(p, {.Move_To}, {{x, y}})
}

path_line_to :: proc(p: ^Path, x, y: f32) {
	path_append(p, {.Line_To}, {{x, y}})
}

path_bezier_to :: proc(p: ^Path, c1x, c1y, c2x, c2y, x, y: f32) {
	path_append(p, {.Bezier_To}, {{c1x, c1y}, {c2x, c2y}, {x, y}})
}

path_quad_to :: proc(p: ^Path, cx, cy, x, y: f32) {
	p0 := p.last_pos
	cp := Vec2{cx, cy}
	end := Vec2{x, y}
	path_append(p, {.Bezier_To}, {p0 + (cp - p0) * (2.0 / 3.0), end + (cp - end) * (2.0 / 3.0), end})
}

path_close :: proc(p: ^Path) {
	path_append(p, {.Close}, {})
}

// Forces the winding of the current contour: `.Solid` contours fill, `.Hole`
// contours cut out of solid ones under the non-zero rule.
path_solidity :: proc(p: ^Path, s: Solidity) {
	switch s {
	case .Solid:
		path_append(p, {.Solid}, {})
	case .Hole:
		path_append(p, {.Hole}, {})
	case .None:
	}
}

path_rect :: proc(p: ^Path, x, y, w, h: f32) {
	path_append(p, {.Move_To, .Line_To, .Line_To, .Line_To, .Close}, {{x, y}, {x, y + h}, {x + w, y + h}, {x + w, y}})
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
	path_append(
		p,
		{.Move_To, .Line_To, .Bezier_To, .Line_To, .Bezier_To, .Line_To, .Bezier_To, .Line_To, .Bezier_To, .Close},
		{
			{x, y + ry_tl},
			{x, y + h - ry_bl},
			{x, y + h - ry_bl * K},
			{x + rx_bl * K, y + h},
			{x + rx_bl, y + h},
			{x + w - rx_br, y + h},
			{x + w - rx_br * K, y + h},
			{x + w, y + h - ry_br * K},
			{x + w, y + h - ry_br},
			{x + w, y + ry_tr},
			{x + w, y + ry_tr * K},
			{x + w - rx_tr * K, y},
			{x + w - rx_tr, y},
			{x + rx_tl, y},
			{x + rx_tl * K, y},
			{x, y + ry_tl * K},
			{x, y + ry_tl},
		},
	)
}

path_ellipse :: proc(p: ^Path, cx, cy, rx, ry: f32) {
	c := Vec2{cx, cy}
	h := Vec2{rx, 0}
	v := Vec2{0, ry}
	K :: KAPPA90
	path_append(
		p,
		{.Move_To, .Bezier_To, .Bezier_To, .Bezier_To, .Bezier_To, .Close},
		{
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
		},
	)
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

	verbs: [6]Verb
	coords: [16]Vec2
	nv, nc := 0, 0
	ppos, ptan: Vec2
	for i in 0 ..= ndivs {
		a := a0 + da * (f32(i) / f32(ndivs))
		dpos := from_angle(a)
		pos := c + dpos * r
		tan := -orthogonal(dpos) * (r * kappa)
		if i == 0 {
			verbs[nv] = .Move_To if len(p.verbs) == 0 else .Line_To
			coords[nc] = pos
			nv += 1
			nc += 1
		} else {
			verbs[nv] = .Bezier_To
			coords[nc] = ppos + ptan
			coords[nc + 1] = pos - tan
			coords[nc + 2] = pos
			nv += 1
			nc += 3
		}
		ppos = pos
		ptan = tan
	}
	path_append(p, verbs[:nv], coords[:nc])
}

// Arc tangent to the lines (last point -> (x1, y1)) and ((x1, y1) -> (x2, y2)).
path_arc_to :: proc(p: ^Path, x1, y1, x2, y2, radius: f32) {
	if len(p.verbs) == 0 {
		return
	}
	tol := p.dist_tol if p.dist_tol > 0 else DEFAULT_DIST_TOL
	pos0 := p.last_pos
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


// A path's drawing as events, normalized the way fill reads it: drawing
// before the first Move_To is skipped; Move_To begins a contour; a line or
// cubic carries the pen as p[0]; Close draws the closing line from the pen
// to the contour's start (of zero length too) and ends the contour; a
// drawing verb after Close begins a new contour at that start first; Solid
// and Hole come in verb order. Line and Close run from p[0] to p[1].
Path_Event_Kind :: enum u8 {
	Begin,
	Line,
	Cubic,
	Close,
	Solid,
	Hole,
}

Path_Event :: struct {
	kind: Path_Event_Kind,
	p:    [4]Vec2,
	verb: u32, // the verb it comes from
}

Path_Events :: struct {
	verbs:       []Verb,
	coords:      []Vec2,
	verb, coord: int,
	pen, start:  Vec2,
	moved, open: bool,
}

// The path must not grow while its events are read.
path_events :: proc "contextless" (p: ^Path) -> Path_Events {
	return {verbs = p.verbs[:], coords = p.coords[:]}
}

// `path_events` of path data held as verbs and coordinates.
path_events_of :: proc "contextless" (verbs: []Verb, coords: []Vec2) -> Path_Events {
	return {verbs = verbs, coords = coords}
}

path_events_next :: proc "contextless" (it: ^Path_Events) -> (e: Path_Event, ok: bool) {
	for it.verb < len(it.verbs) {
		v := it.verbs[it.verb]
		c := it.coords[it.coord:][:verb_num_coords(v)]
		e.verb = u32(it.verb)
		if (v == .Line_To || v == .Bezier_To) && !it.open {
			if !it.moved {
				it.verb, it.coord = it.verb + 1, it.coord + len(c)
				continue
			}
			// Drawing after Close: a new contour from the last start (the
			// verb is read again next call).
			it.open, it.pen = true, it.start
			e.kind, e.p[0] = .Begin, it.start
			return e, true
		}
		it.verb, it.coord = it.verb + 1, it.coord + len(c)
		switch v {
		case .Move_To:
			it.pen, it.start, it.moved, it.open = c[0], c[0], true, true
			e.kind, e.p[0] = .Begin, c[0]
		case .Line_To:
			e.kind, e.p[0], e.p[1] = .Line, it.pen, c[0]
			it.pen = c[0]
		case .Bezier_To:
			e.kind, e.p = .Cubic, {it.pen, c[0], c[1], c[2]}
			it.pen = c[2]
		case .Close:
			if !it.open {
				continue
			}
			e.kind, e.p[0], e.p[1] = .Close, it.pen, it.start
			it.pen, it.open = it.start, false
		case .Solid:
			e.kind = .Solid
		case .Hole:
			e.kind = .Hole
		}
		return e, true
	}
	return
}
