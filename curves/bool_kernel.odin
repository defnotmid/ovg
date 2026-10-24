package curves

import "core:math"
import "core:slice"

// The kernels path booleans are built on, in f64: the one length scale,
// pieces monotone in x and y, the winding of a point about a cubic, and the
// near-set of two pieces.

// The boolean's length scale for coordinates up to M in magnitude: eps is 8
// f32 ulps of M, a power of two, so scaling the input by 2^k scales every
// decision by 2^k; delta = eps / 4 is how exactly near-sets are found.
snap_epsilon :: proc "contextless" (M: f64) -> (eps, delta: f64) {
	if !(M > 0) || math.is_inf(M) {
		return 0, 0
	}
	// M = f 2^e with f in [0.5, 1): M lies in [2^(e-1), 2^e), whose f32 ulp
	// is 2^(e-24).
	_, e := math.frexp(M)
	eps = math.ldexp(f64(1), e - 21)
	return eps, eps / 4
}

// A piece of a source segment, monotone in x and in y: its control points
// lie in the box of its ends (so the box of its ends bounds it), and it
// covers [t0, t1] of the segment's parameter. A line piece runs straight
// from p[0] to p[3].
Piece :: struct {
	p:       [4][2]f64,
	t0, t1:  f64,
	row:     u32, // the segment, an index into Contours.kinds
	operand: u16,
	line:    bool,
}

// Appends the pieces of segment q (row `row` of `operand`, a line when
// `line`) to `out`: a line is one piece; a cubic is cut where it turns in x
// or y, each piece's controls pinned into the box of its ends (exact, as
// the derivative vanishes there); a cubic whose controls lie within `flat`
// of its chord's line becomes line pieces.
monotone_pieces :: proc(q: [4][2]f64, line: bool, row: u32, operand: u16, flat: f64, out: ^[dynamic]Piece) {
	if line {
		append(out, Piece{q, 0, 1, row, operand, true})
		return
	}
	cuts: [6]f64
	n := 1
	cuts[0] = 0
	for axis in 0 ..< 2 {
		ts, k := cubic_extrema(q, axis)
		for t in ts[:k] {
			cuts[n] = t
			n += 1
		}
	}
	cuts[n] = 1
	n += 1
	slice.sort(cuts[1:n - 1])
	straight := near_line(q, flat)
	for i in 0 ..< n - 1 {
		t0, t1 := cuts[i], cuts[i + 1]
		if t1 <= t0 {
			continue
		}
		p := cubic_range(q, t0, t1)
		lo, hi := box_of_ends(p)
		for k in 1 ..= 2 {
			p[k] = {clamp(p[k].x, lo.x, hi.x), clamp(p[k].y, lo.y, hi.y)}
		}
		if straight {
			p[1], p[2] = p[0] + (p[3] - p[0]) / 3, p[0] + (p[3] - p[0]) * (2.0 / 3)
		}
		append(out, Piece{p, t0, t1, row, operand, straight})
	}
}

// The winding of the cubic p about q: its signed crossings of the ray from
// q towards +x, counted half-open in y (where one end is above q.y and the
// other at or below it), +1 going towards +y. Comparisons only: the curve
// is halved until each cell's control box misses q; a cell right of q
// crosses as its chord does, any other cell misses the ray. `on` reports q
// within `on_tol` of the curve (a cell that small still holds it).
curve_winding :: proc(p: [4][2]f64, q: [2]f64, on_tol: f64, stack: ^[dynamic][2]f64) -> (w: i32, on: bool) {
	clear(stack)
	append(stack, [2]f64{0, 1})
	for len(stack) > 0 {
		r := pop(stack)
		c := cubic_range(p, r[0], r[1])
		lo, hi := box_of(c)
		if q.x < lo.x || q.x > hi.x || q.y < lo.y || q.y > hi.y {
			if lo.x > q.x && (c[0].y > q.y) != (c[3].y > q.y) {
				w += 1 if c[3].y > q.y else -1
			}
			continue
		}
		if max(hi.x - lo.x, hi.y - lo.y) <= on_tol {
			on = true
			continue
		}
		m := (r[0] + r[1]) / 2
		append(stack, [2]f64{r[0], m}, [2]f64{m, r[1]})
	}
	return
}

// A stretch where two pieces come within the tolerance: [s0, s1] of the
// first piece's parameter against [t0, t1] of the second's; `point` when it
// is small (a crossing or a touch) rather than an overlap.
Run :: struct {
	s0, s1, t0, t1: f64,
	point:          bool,
}

Kernel_Scratch :: struct {
	stack:  [dynamic][4]f64, // cell pairs: s0, s1, t0, t1
	leaves: [dynamic]Run,
}

kernel_scratch_destroy :: proc(s: ^Kernel_Scratch) {
	delete(s.stack)
	delete(s.leaves)
}

// Appends to `out` the runs where pieces a and b come within `tol`: every
// pair of points closer than tol - delta lies in a run, and every leaf of
// the search found its pairs within tol + delta. Cell pairs are halved
// until both are flat, then compared as segments in closed form; a pair is
// dropped only when its boxes are proved farther apart than tol, so no
// crossing is missed whatever the rounding. `budget` counts cell pairs
// (false when it runs out).
near_runs :: proc(a, b: ^Piece, tol, delta: f64, s: ^Kernel_Scratch, out: ^[dynamic]Run, budget: ^int) -> bool {
	clear(&s.stack)
	clear(&s.leaves)
	append(&s.stack, [4]f64{0, 1, 0, 1})
	reach := tol + delta / 2
	flat := tol / 16
	for len(s.stack) > 0 {
		if budget^ -= 1; budget^ < 0 {
			return false
		}
		cell := pop(&s.stack)
		pa := piece_range(a, cell[0], cell[1])
		pb := piece_range(b, cell[2], cell[3])
		alo, ahi := box_of(pa)
		blo, bhi := box_of(pb)
		dx := max(alo.x - bhi.x, blo.x - ahi.x, 0)
		dy := max(alo.y - bhi.y, blo.y - ahi.y, 0)
		if dx * dx + dy * dy > reach * reach {
			continue
		}
		fa := a.line || chord_flat(pa, flat)
		fb := b.line || chord_flat(pb, flat)
		if fa && fb {
			u0, u1, v0, v1, near := segments_near(pa[0], pa[3], pb[0], pb[3], tol)
			if near {
				ds, dt := cell[1] - cell[0], cell[3] - cell[2]
				append(&s.leaves, Run{cell[0] + u0 * ds, cell[0] + u1 * ds, cell[2] + v0 * dt, cell[2] + v1 * dt, false})
			}
			continue
		}
		// Halve the larger cell that isn't flat.
		split_a := !fa && (fb || box_size(alo, ahi) >= box_size(blo, bhi))
		if split_a {
			m := (cell[0] + cell[1]) / 2
			append(&s.stack, [4]f64{cell[0], m, cell[2], cell[3]}, [4]f64{m, cell[1], cell[2], cell[3]})
		} else {
			m := (cell[2] + cell[3]) / 2
			append(&s.stack, [4]f64{cell[0], cell[1], cell[2], m}, [4]f64{cell[0], cell[1], m, cell[3]})
		}
	}
	merge_runs(a, b, tol, s, out)
	return true
}

// The leaves' connected stretches as runs, each a point run when all its
// ends lie within 2 tol of its middle.
@(private = "file")
merge_runs :: proc(a, b: ^Piece, tol: f64, s: ^Kernel_Scratch, out: ^[dynamic]Run) {
	if len(s.leaves) == 0 {
		return
	}
	slice.sort_by(s.leaves[:], proc(x, y: Run) -> bool {return x.s0 < y.s0})
	// Leaves of neighbouring cells meet at the cells' shared edge, up to
	// the closed form's bisection.
	gap :: 1e-12
	first := len(out)
	cur := s.leaves[0]
	for l in s.leaves[1:] {
		if l.s0 <= cur.s1 + gap && l.t0 <= cur.t1 + gap && l.t1 >= cur.t0 - gap {
			cur = {cur.s0, max(cur.s1, l.s1), min(cur.t0, l.t0), max(cur.t1, l.t1), false}
		} else {
			append(out, cur)
			cur = l
		}
	}
	append(out, cur)
	for &r in out[first:] {
		m := (piece_at(a, (r.s0 + r.s1) / 2) + piece_at(b, (r.t0 + r.t1) / 2)) / 2
		ends := [4][2]f64{piece_at(a, r.s0), piece_at(a, r.s1), piece_at(b, r.t0), piece_at(b, r.t1)}
		r.point = true
		for e in ends {
			if length(e - m) > 2 * tol {
				r.point = false
			}
		}
	}
}

// Where segments a0 a1 and b0 b1 come within tol: the ranges of their
// parameters (u on a, v on b) holding such a pair. The set is convex, so
// each range is found from the nearest pair outwards by bisection.
@(private = "file")
segments_near :: proc "contextless" (a0, a1, b0, b1: [2]f64, tol: f64) -> (u0, u1, v0, v1: f64, near: bool) {
	range :: proc "contextless" (a0, a1, b0, b1: [2]f64, tol: f64) -> (lo, hi: f64, ok: bool) {
		// g(u): the distance from a(u) to segment b, convex in u.
		g :: proc "contextless" (u: f64, a0, a1, b0, b1: [2]f64) -> f64 {
			return point_segment_distance(a0 + (a1 - a0) * u, b0, b1)
		}
		// The minimum by golden-section search, then the edges of
		// {g <= tol} by bisection.
		x0, x1 := 0.0, 1.0
		for _ in 0 ..< 80 {
			m0, m1 := x0 + (x1 - x0) * 0.381966, x0 + (x1 - x0) * 0.618034
			if g(m0, a0, a1, b0, b1) <= g(m1, a0, a1, b0, b1) {
				x1 = m1
			} else {
				x0 = m0
			}
		}
		um := (x0 + x1) / 2
		if g(um, a0, a1, b0, b1) > tol {
			return 0, 0, false
		}
		lo, hi = 0, 1
		if g(0, a0, a1, b0, b1) > tol {
			l, r := 0.0, um
			for _ in 0 ..< 60 {
				if m := (l + r) / 2; g(m, a0, a1, b0, b1) > tol {l = m} else {r = m}
			}
			lo = l
		}
		if g(1, a0, a1, b0, b1) > tol {
			l, r := um, 1.0
			for _ in 0 ..< 60 {
				if m := (l + r) / 2; g(m, a0, a1, b0, b1) > tol {r = m} else {l = m}
			}
			hi = r
		}
		return lo, hi, true
	}
	ok: bool
	u0, u1, ok = range(a0, a1, b0, b1, tol)
	if !ok {
		return
	}
	v0, v1, ok = range(b0, b1, a0, a1, tol)
	return u0, u1, v0, v1, ok
}

@(private = "file")
point_segment_distance :: proc "contextless" (p, a, b: [2]f64) -> f64 {
	d := b - a
	l := d.x * d.x + d.y * d.y
	t := clamp(((p.x - a.x) * d.x + (p.y - a.y) * d.y) / l, 0, 1) if l > 0 else 0
	return length(p - (a + d * t))
}

// The piece's controls over [s0, s1] of its parameter.
piece_range :: #force_inline proc "contextless" (p: ^Piece, s0, s1: f64) -> [4][2]f64 {
	if p.line {
		a, b := p.p[0] + (p.p[3] - p.p[0]) * s0, p.p[0] + (p.p[3] - p.p[0]) * s1
		return {a, a, b, b}
	}
	return cubic_range(p.p, s0, s1)
}

piece_at :: #force_inline proc "contextless" (p: ^Piece, s: f64) -> [2]f64 {
	return p.p[0] + (p.p[3] - p.p[0]) * s if p.line else cubic_at(p.p, s)
}

// Whether the cubic's controls lie within `tol` of the line through its
// ends (of its start when the ends meet).
@(private = "file")
near_line :: proc "contextless" (p: [4][2]f64, tol: f64) -> bool {
	d := p[3] - p[0]
	l := length(d)
	for k in 1 ..= 2 {
		e := p[k] - p[0]
		off := abs(e.x * d.y - e.y * d.x) / l if l > 0 else length(e)
		if off > tol {
			return false
		}
	}
	return true
}

// Whether the cubic's controls lie within `tol` of its chord's thirds.
chord_flat :: proc "contextless" (p: [4][2]f64, tol: f64) -> bool {
	d := p[3] - p[0]
	return length(p[1] - (p[0] + d / 3)) <= tol && length(p[2] - (p[0] + d * (2.0 / 3))) <= tol
}

box_of :: #force_inline proc "contextless" (p: [4][2]f64) -> (lo, hi: [2]f64) {
	lo = {min(p[0].x, p[1].x, p[2].x, p[3].x), min(p[0].y, p[1].y, p[2].y, p[3].y)}
	hi = {max(p[0].x, p[1].x, p[2].x, p[3].x), max(p[0].y, p[1].y, p[2].y, p[3].y)}
	return
}

@(private = "file")
box_of_ends :: #force_inline proc "contextless" (p: [4][2]f64) -> (lo, hi: [2]f64) {
	return {min(p[0].x, p[3].x), min(p[0].y, p[3].y)}, {max(p[0].x, p[3].x), max(p[0].y, p[3].y)}
}

@(private = "file")
box_size :: #force_inline proc "contextless" (lo, hi: [2]f64) -> f64 {
	return max(hi.x - lo.x, hi.y - lo.y)
}

@(private = "file")
length :: #force_inline proc "contextless" (v: [2]f64) -> f64 {
	return math.sqrt(v.x * v.x + v.y * v.y)
}
