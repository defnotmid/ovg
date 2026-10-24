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

// A piece of a source segment, monotone in x and in y (so it lies in the
// box of its ends, though its controls needn't), covering [t0, t1] of the
// segment's parameter. A line piece runs straight from p[0] to p[3].
Piece :: struct {
	p:       [4][2]f64,
	t0, t1:  f64,
	row:     u32, // the segment, an index into Contours.kinds
	operand: u16,
	line:    bool,
}

// Appends the pieces of segment q (row `row` of `operand`, a line when
// `line`) to `out`: a line is one piece; a cubic is cut where it turns in x
// or y, the control next to such a cut pinned to the cut's coordinate on
// that axis (exact, as the derivative vanishes there); a cubic whose
// controls lie within `flat` of its chord's line becomes line pieces.
monotone_pieces :: proc(q: [4][2]f64, line: bool, row: u32, operand: u16, flat: f64, out: ^[dynamic]Piece) {
	if line {
		append(out, Piece{q, 0, 1, row, operand, true})
		return
	}
	// Each cut and the axis it turns on (-1 for the ends).
	cuts: [6]f64
	axes: [6]int
	n := 1
	cuts[0], axes[0] = 0, -1
	// A turning point within `flat` of an end (a tangent along an axis
	// there, found a hair inside) cuts nothing but a sliver.
	for axis in 0 ..< 2 {
		ts, k := cubic_extrema(q, axis)
		for t in ts[:k] {
			p := cubic_at(q, t)
			if length(p - q[0]) > flat && length(p - q[3]) > flat {
				cuts[n], axes[n] = t, axis
				n += 1
			}
		}
	}
	cuts[n], axes[n] = 1, -1
	n += 1
	for i in 2 ..< n - 1 {
		for j := i; j > 1 && cuts[j] < cuts[j - 1]; j -= 1 {
			cuts[j], cuts[j - 1] = cuts[j - 1], cuts[j]
			axes[j], axes[j - 1] = axes[j - 1], axes[j]
		}
	}
	straight := near_line(q, flat)
	for i in 0 ..< n - 1 {
		t0, t1 := cuts[i], cuts[i + 1]
		if t1 <= t0 {
			continue
		}
		p := cubic_range(q, t0, t1)
		if a := axes[i]; a >= 0 {
			p[1][a] = p[0][a]
		}
		if a := axes[i + 1]; a >= 0 {
			p[2][a] = p[3][a]
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
		// A cell this small, or one f64 can't halve any more, holds q.
		m := (r[0] + r[1]) / 2
		if max(hi.x - lo.x, hi.y - lo.y) <= on_tol || m <= r[0] || m >= r[1] {
			on = true
			continue
		}
		// One at a time: a single append stores in place, two copy
		// through memmove.
		append(stack, [2]f64{r[0], m})
		append(stack, [2]f64{m, r[1]})
	}
	return
}

// A stretch where two pieces come within the tolerance: [s0, s1] of the
// first piece's parameter against [t0, t1] of the second's; `point` when it
// is small (a crossing or a touch, its ends within the caller's `point`
// distance of its middle) rather than an overlap.
Run :: struct {
	s0, s1, t0, t1: f64,
	point:          bool,
}

// A pair of cells: [s0, s1] of the first piece and [t0, t1] of the
// second, with the pieces' controls over them.
Cell_Pair :: struct {
	r:      [4]f64, // s0, s1, t0, t1
	pa, pb: [4][2]f64,
}

Kernel_Scratch :: struct {
	stack:  [dynamic]Cell_Pair,
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
// crossing is missed whatever the rounding. A run is a point when all its
// ends lie within `point` of its middle. The search covers `root` (s0, s1
// of a, t0, t1 of b): a caller that knows every near pair lies there skips
// the rest. `budget` counts cell pairs (false when it runs out).
near_runs :: proc(a, b: ^Piece, tol, delta, point: f64, s: ^Kernel_Scratch, out: ^[dynamic]Run, budget: ^int, root := [4]f64{0, 1, 0, 1}) -> bool {
	clear(&s.stack)
	clear(&s.leaves)
	append(&s.stack, Cell_Pair{root, piece_range(a, root[0], root[1]), piece_range(b, root[2], root[3])})
	reach := tol + delta / 2
	flat := tol / 16
	for len(s.stack) > 0 {
		if budget^ -= 1; budget^ < 0 {
			return false
		}
		top := pop(&s.stack)
		cell, pa, pb := top.r, top.pa, top.pb
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
				append(&s.leaves, Run{span_at(cell[0], cell[1], u0), span_at(cell[0], cell[1], u1), span_at(cell[2], cell[3], v0), span_at(cell[2], cell[3], v1), false})
			}
			continue
		}
		// Halve the larger cell that isn't flat (only its controls are new);
		// cells f64 can't halve any more are compared as they are. Pushed
		// one at a time, as in curve_winding.
		split_a := !fa && (fb || box_size(alo, ahi) >= box_size(blo, bhi))
		ma, mb := (cell[0] + cell[1]) / 2, (cell[2] + cell[3]) / 2
		if (split_a && (ma <= cell[0] || ma >= cell[1])) || (!split_a && (mb <= cell[2] || mb >= cell[3])) {
			u0, u1, v0, v1, near := segments_near(pa[0], pa[3], pb[0], pb[3], tol)
			if near {
				append(&s.leaves, Run{span_at(cell[0], cell[1], u0), span_at(cell[0], cell[1], u1), span_at(cell[2], cell[3], v0), span_at(cell[2], cell[3], v1), false})
			}
			continue
		}
		if split_a {
			m := (cell[0] + cell[1]) / 2
			append(&s.stack, Cell_Pair{{cell[0], m, cell[2], cell[3]}, piece_range(a, cell[0], m), pb})
			append(&s.stack, Cell_Pair{{m, cell[1], cell[2], cell[3]}, piece_range(a, m, cell[1]), pb})
		} else {
			m := (cell[2] + cell[3]) / 2
			append(&s.stack, Cell_Pair{{cell[0], cell[1], cell[2], m}, pa, piece_range(b, cell[2], m)})
			append(&s.stack, Cell_Pair{{cell[0], cell[1], m, cell[3]}, pa, piece_range(b, m, cell[3])})
		}
	}
	merge_runs(a, b, point, s, out)
	return true
}

// The parameter at u along [lo, hi], each end exactly.
@(private = "file")
span_at :: #force_inline proc "contextless" (lo, hi, u: f64) -> f64 {
	return hi if u == 1 else lo + (hi - lo) * u
}

// The leaves' connected stretches as runs, each a point run when all its
// ends lie within `point` of its middle.
@(private = "file")
merge_runs :: proc(a, b: ^Piece, point: f64, s: ^Kernel_Scratch, out: ^[dynamic]Run) {
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
			if length(e - m) > point {
				r.point = false
			}
		}
	}
}

// Where segments a0 a1 and b0 b1 come within tol: the ranges of their
// parameters (u on a, v on b) holding such a pair.
@(private = "file")
segments_near :: proc "contextless" (a0, a1, b0, b1: [2]f64, tol: f64) -> (u0, u1, v0, v1: f64, near: bool) {
	ok: bool
	u0, u1, ok = capsule_range(a0, a1, b0, b1, tol)
	if !ok {
		return
	}
	v0, v1, ok = capsule_range(b0, b1, a0, a1, tol)
	return u0, u1, v0, v1, ok
}

// The range of u in [0, 1] where a0 + u (a1 - a0) lies within tol of
// segment b0 b1: the line clipped by the capsule around the segment (its
// rectangle and its end discs; convex, so one interval).
@(private = "file")
capsule_range :: proc "contextless" (a0, a1, b0, b1: [2]f64, tol: f64) -> (lo, hi: f64, ok: bool) {
	d := a1 - a0
	lo, hi = math.INF_F64, -math.INF_F64
	dd := d.x * d.x + d.y * d.y
	if dd == 0 {
		// A point: all of [0, 1] or nothing.
		if point_segment_distance(a0, b0, b1) <= tol {
			return 0, 1, true
		}
		return 0, 0, false
	}
	// The end discs.
	for c in ([2][2]f64{b0, b1}) {
		w := a0 - c
		b := d.x * w.x + d.y * w.y
		disc := b * b - dd * (w.x * w.x + w.y * w.y - tol * tol)
		if disc >= 0 {
			r := math.sqrt(disc)
			lo, hi = min(lo, (-b - r) / dd), max(hi, (-b + r) / dd)
		}
	}
	// The rectangle: along the segment within its length, across it within
	// tol, each a bound linear in u (alpha + beta u >= 0).
	e := b1 - b0
	ee := e.x * e.x + e.y * e.y
	if ee > 0 {
		w := a0 - b0
		el := math.sqrt(ee)
		along, along_d := w.x * e.x + w.y * e.y, d.x * e.x + d.y * e.y
		across, across_d := e.x * w.y - e.y * w.x, e.x * d.y - e.y * d.x
		bounds := [4][2]f64{{along, along_d}, {ee - along, -along_d}, {tol * el - across, -across_d}, {tol * el + across, across_d}}
		r0, r1 := -math.INF_F64, math.INF_F64
		for bd in bounds {
			switch {
			case bd[1] > 0:
				r0 = max(r0, -bd[0] / bd[1])
			case bd[1] < 0:
				r1 = min(r1, -bd[0] / bd[1])
			case bd[0] < 0:
				r0, r1 = 1, 0
			}
		}
		if r0 <= r1 {
			lo, hi = min(lo, r0), max(hi, r1)
		}
	}
	lo, hi = max(lo, 0), min(hi, 1)
	return lo, hi, lo <= hi
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
box_size :: #force_inline proc "contextless" (lo, hi: [2]f64) -> f64 {
	return max(hi.x - lo.x, hi.y - lo.y)
}

@(private = "file")
length :: #force_inline proc "contextless" (v: [2]f64) -> f64 {
	return math.sqrt(v.x * v.x + v.y * v.y)
}
