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

// Iterates verbs with their coordinates.
Path_Iter :: struct {
	path:      ^Path,
	verb_idx:  int,
	coord_idx: int,
}

path_iter :: proc "contextless" (p: ^Path) -> Path_Iter {
	return {path = p}
}

path_iter_next :: proc "contextless" (it: ^Path_Iter) -> (verb: Verb, coords: []Vec2, ok: bool) {
	if it.verb_idx >= len(it.path.verbs) {
		return
	}
	verb = it.path.verbs[it.verb_idx]
	n := verb_num_coords(verb)
	coords = it.path.coords[it.coord_idx:][:n]
	it.verb_idx += 1
	it.coord_idx += n
	return verb, coords, true
}
