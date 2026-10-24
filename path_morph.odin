package ovg

import "core:math"
import "core:slice"

// Shape tweening between two arbitrary paths, as flubber / MorphSVG do.
// `path_morph_prepare` does the work once per pair of paths: it flattens
// both (`path_flatten`), sorts each contour into solid or hole under its
// path's fill rule, pairs the contours of `a` with those of `b` (solids with
// solids, holes with holes, by position within the path's bounds and by
// share of its area), and resamples every pair by arc length to the same
// points, wound the same way and started at the offset that moves the
// points least. `path_morph_eval` then blends the points at any `t` into a
// path, without allocating once the output path is warm.
//
// Contours without a partner (the counts differ: "A" has 2, a circle 1,
// "B" 3) shrink to a point or grow from one: their centroid, carried along
// by the contour they sit in (a hole by its enclosing solid, a solid by the
// nearest paired solid) as that one moves to its partner.
//
// The output keeps every point of both flattened paths: at t = 0 it is `a`
// as polylines (`path_flatten`'s segments of about 1.5 units) and at t = 1
// it is `b`, with extra points on the edges. Solids wind as `.Solid`, holes
// as `.Hole` (marked with those verbs), so the blend fills the same under
// the non-zero and the even-odd rule. Contours are morphed as filled
// shapes: open contours are closed, and contours of fewer than three points
// are dropped. `t` outside [0, 1] extrapolates (overshooting easings).
Path_Morph :: struct {
	// The points of every output contour at t = 0 and at t = 1.
	from, to: [dynamic]Vec2,
	contours: [dynamic]Morph_Contour,
	// Scratch of `path_morph_prepare`.
	flat:     [2]Flat_Path,
	rings:    [2][dynamic]Morph_Ring,
	cands:    [dynamic]Morph_Candidate,
	params:   [dynamic]f32,
	samples:  [dynamic]Vec2,
}

Morph_Contour :: struct {
	// Into `Path_Morph.from` / `to`.
	first, count: u32,
	hole:         bool,
	kind:         Morph_Kind,
}

Morph_Kind :: enum u8 {
	// In both paths.
	Pair,
	// Only in `a`: shrinks to a point, gone at t >= 1.
	Shrink,
	// Only in `b`: grows from a point, absent at t <= 0.
	Grow,
}

// A flattened contour of one side, wound as its solidity wants.
@(private)
Morph_Ring :: struct {
	// Into the side's flat points (no closing duplicate).
	first, count: u32,
	area:         f32,
	centroid:     Vec2,
	hole:         bool,
	// The index of its partner on the other side, or -1.
	match:        i32,
}

@(private)
Morph_Candidate :: struct {
	a, b: i32,
	cost: f32,
}

// A morph allocating from `allocator`.
path_morph_init :: proc(m: ^Path_Morph, allocator := context.allocator) {
	m^ = {}
	m.from.allocator, m.to.allocator, m.contours.allocator = allocator, allocator, allocator
	for &f in m.flat {
		flat_path_init(&f, allocator)
	}
	for &r in m.rings {
		r.allocator = allocator
	}
	m.cands.allocator, m.params.allocator, m.samples.allocator = allocator, allocator, allocator
}

path_morph_destroy :: proc(m: ^Path_Morph) {
	delete(m.from)
	delete(m.to)
	delete(m.contours)
	for &f in m.flat {
		flat_path_destroy(&f)
	}
	for r in m.rings {
		delete(r)
	}
	delete(m.cands)
	delete(m.params)
	delete(m.samples)
	m^ = {}
}

// Prepares the morph from `a` (t = 0) to `b` (t = 1) into `m` (cleared,
// buffers kept). `rule_a` / `rule_b` are the fill rules the paths are drawn
// with: they decide which contours are holes. The paths are not kept.
path_morph_prepare :: proc(m: ^Path_Morph, a, b: ^Path, rule_a: Fill_Rule = .Non_Zero, rule_b: Fill_Rule = .Non_Zero) {
	clear(&m.from)
	clear(&m.to)
	clear(&m.contours)
	path_flatten(a, &m.flat[0])
	path_flatten(b, &m.flat[1])
	morph_rings(&m.flat[0], &m.rings[0], rule_a)
	morph_rings(&m.flat[1], &m.rings[1], rule_b)
	morph_match(m)

	ra, rb := m.rings[0][:], m.rings[1][:]
	for r, i in ra {
		if r.match >= 0 {
			morph_pair(m, morph_ring_points(m, 0, r), morph_ring_points(m, 1, rb[r.match]), r.hole)
		} else {
			morph_lone(m, 0, i32(i), .Shrink)
		}
	}
	for r, j in rb {
		if r.match < 0 {
			morph_lone(m, 1, i32(j), .Grow)
		}
	}
}

// Appends the morph at `t` to `out`: one closed polyline per contour,
// marked `.Solid` or `.Hole`. No allocation once `out` has the capacity.
path_morph_eval :: proc(m: ^Path_Morph, t: f32, out: ^Path) {
	for ct in m.contours {
		if (ct.kind == .Grow && t <= 0) || (ct.kind == .Shrink && t >= 1) {
			continue
		}
		n := int(ct.count)
		v0, c0 := len(out.verbs), len(out.coords)
		resize(&out.verbs, v0 + n + 2)
		resize(&out.coords, c0 + n)
		verbs := out.verbs[v0:]
		coords := out.coords[c0:]
		from := m.from[ct.first:][:n]
		to := m.to[ct.first:][:n]
		for k in 0 ..< n {
			verbs[k] = .Line_To
			coords[k] = from[k] + (to[k] - from[k]) * t
		}
		verbs[0] = .Move_To
		verbs[n] = .Close
		verbs[n + 1] = .Hole if ct.hole else .Solid
		out.last_pos = coords[n - 1]
	}
}

// The contours of `f` as rings, classified and wound in place: solids with
// a positive `morph_area` (path solidity `.Solid`), holes negative.
@(private = "file")
morph_rings :: proc(f: ^Flat_Path, rings: ^[dynamic]Morph_Ring, rule: Fill_Rule) {
	clear(rings)
	for ct in f.contours {
		n := ct.count
		pts := f.points[ct.first:][:n]
		if n > 1 && pts[n - 1] == pts[0] {
			n -= 1
		}
		if n < 3 {
			continue
		}
		pts = pts[:n]
		area, centroid := morph_area(pts)
		append(rings, Morph_Ring{first = ct.first, count = n, area = area, centroid = centroid, match = -1})
	}
	// A contour is a hole when the rest of the path fills just outside it
	// and nothing fills just inside it.
	for &r, i in rings {
		pts := f.points[r.first:][:r.count]
		p := morph_edge_point(pts)
		w := 0
		for o, j in rings {
			if j != i {
				w += morph_winding(f.points[o.first:][:o.count], p)
			}
		}
		if rule == .Even_Odd {
			r.hole = w % 2 != 0
		} else {
			// A positive area winds -1 around its inside.
			own := -1 if r.area > 0 else 1 if r.area < 0 else 0
			r.hole = w != 0 && w + own == 0
		}
	}
	for &r in rings {
		if r.hole == (r.area > 0) {
			slice.reverse(f.points[r.first:][:r.count])
		}
		r.area = abs(r.area)
	}
}

// Pairs the rings of both sides greedily, cheapest first: the distance
// between centroids placed within each path's bounds, plus the difference
// in share of the side's solid (or hole) area.
@(private = "file")
morph_match :: proc(m: ^Path_Morph) {
	origin: [2]Vec2
	scale: [2]f32
	total: [2][2]f32 // side, hole
	for side in 0 ..< 2 {
		lo := Vec2{math.F32_MAX, math.F32_MAX}
		hi := -lo
		for r in m.rings[side] {
			for q in m.flat[side].points[r.first:][:r.count] {
				lo = {min(lo.x, q.x), min(lo.y, q.y)}
				hi = {max(hi.x, q.x), max(hi.y, q.y)}
			}
			total[side][int(r.hole)] += r.area
		}
		size := max(hi.x - lo.x, hi.y - lo.y)
		origin[side] = lo
		scale[side] = 1 / size if size > 0 else 1
	}
	clear(&m.cands)
	for ra, i in m.rings[0] {
		na := (ra.centroid - origin[0]) * scale[0]
		sa := ra.area / max(total[0][int(ra.hole)], 1e-12)
		for rb, j in m.rings[1] {
			if rb.hole != ra.hole {
				continue
			}
			nb := (rb.centroid - origin[1]) * scale[1]
			sb := rb.area / max(total[1][int(rb.hole)], 1e-12)
			append(&m.cands, Morph_Candidate{i32(i), i32(j), mag2(na - nb) + (sa - sb) * (sa - sb)})
		}
	}
	slice.sort_by(m.cands[:], proc(x, y: Morph_Candidate) -> bool {return x.cost < y.cost})
	for c in m.cands {
		ra, rb := &m.rings[0][c.a], &m.rings[1][c.b]
		if ra.match < 0 && rb.match < 0 {
			ra.match, rb.match = c.b, c.a
		}
	}
}

@(private = "file")
morph_ring_points :: proc(m: ^Path_Morph, side: int, r: Morph_Ring) -> []Vec2 {
	return m.flat[side].points[r.first:][:r.count]
}

// A contour of one side only: its points at their end, a point at the other.
@(private = "file")
morph_lone :: proc(m: ^Path_Morph, side: int, i: i32, kind: Morph_Kind) {
	r := m.rings[side][i]
	pts := morph_ring_points(m, side, r)
	// The contour that carries it: a hole's enclosing solid when that one
	// is paired, else the nearest paired solid.
	carrier: i32 = -1
	if r.hole {
		best: f32 = math.F32_MAX
		for o, j in m.rings[side] {
			if !o.hole && o.area < best && morph_winding(morph_ring_points(m, side, o), pts[0]) != 0 {
				carrier, best = i32(j), o.area
			}
		}
		if carrier >= 0 && m.rings[side][carrier].match < 0 {
			carrier = -1
		}
	}
	if carrier < 0 {
		best: f32 = math.F32_MAX
		for o, j in m.rings[side] {
			if !o.hole && o.match >= 0 {
				if d := mag2(o.centroid - r.centroid); d < best {
					carrier, best = i32(j), d
				}
			}
		}
	}
	anchor := r.centroid
	if carrier >= 0 {
		o := m.rings[side][carrier]
		anchor += m.rings[1 - side][o.match].centroid - o.centroid
	}
	first := u32(len(m.from))
	for q in pts {
		append(&m.from, q if kind == .Shrink else anchor)
		append(&m.to, anchor if kind == .Shrink else q)
	}
	append(&m.contours, Morph_Contour{first, u32(len(pts)), r.hole, kind})
}

// Resamples a pair of rings (wound alike) to shared arc-length parameters:
// every vertex of both, `b` shifted by the offset that moves least.
@(private = "file")
morph_pair :: proc(m: ^Path_Morph, a, b: []Vec2, hole: bool) {
	clear(&m.params)
	morph_params(&m.params, a)
	morph_params(&m.params, b)
	pa := m.params[:len(a)]
	pb := m.params[len(a):]

	// Offset: the best of M evenly spaced shifts of M samples, refined
	// between its neighbours.
	M :: 64
	REFINE :: 8
	resize(&m.samples, 2 * M)
	sa, sb := m.samples[:M], m.samples[M:]
	for k in 0 ..< M {
		sa[k] = morph_at(a, pa, f32(k) / M)
		sb[k] = morph_at(b, pb, f32(k) / M)
	}
	best, best_cost := 0, f32(math.F32_MAX)
	for s in 0 ..< M {
		cost: f32 = 0
		for k in 0 ..< M {
			cost += mag2(sa[k] - sb[(k + s) % M])
		}
		if cost < best_cost {
			best, best_cost = s, cost
		}
	}
	shift := f32(best) / M
	base := shift
	for r in -REFINE ..= REFINE {
		d := base + f32(r) / (M * REFINE)
		if r == 0 {
			continue
		}
		cost: f32 = 0
		for k in 0 ..< M {
			cost += mag2(sa[k] - morph_at(b, pb, f32(k) / M + d))
		}
		if cost < best_cost {
			shift, best_cost = d, cost
		}
	}
	shift -= f32(int(shift))
	if shift < 0 {
		shift += 1
	}

	// Merge a's parameters with b's moved to a's start (b's from the first
	// at or after `shift`, wrapping).
	j0 := 0
	for j0 < len(pb) && pb[j0] < shift {
		j0 += 1
	}
	first := u32(len(m.from))
	i, jn := 0, 0
	EPS :: 1e-6
	for i < len(a) || jn < len(b) {
		j := (j0 + jn) % len(b)
		ub := pb[j] - shift + (1 if j0 + jn >= len(b) else 0)
		ua := pa[i] if i < len(a) else 2
		if jn >= len(b) || ua < ub - EPS {
			append(&m.from, a[i])
			append(&m.to, morph_at(b, pb, ua + shift))
			i += 1
		} else if i >= len(a) || ub < ua - EPS {
			append(&m.from, morph_at(a, pa, ub))
			append(&m.to, b[j])
			jn += 1
		} else {
			append(&m.from, a[i])
			append(&m.to, b[j])
			i += 1
			jn += 1
		}
	}
	append(&m.contours, Morph_Contour{first, u32(len(m.from)) - first, hole, .Pair})
}

// Appends each vertex's arc-length position around the closed ring, in
// [0, 1); evenly spaced for a ring of no length.
@(private = "file")
morph_params :: proc(out: ^[dynamic]f32, pts: []Vec2) {
	start := len(out)
	total: f32 = 0
	for q, k in pts {
		append(out, total)
		total += vec_len(pts[(k + 1) % len(pts)] - q)
	}
	ps := out[start:]
	for &p, k in ps {
		p = p / total if total > 0 else f32(k) / f32(len(ps))
	}
}

// The ring's point at arc-length position `u` (wrapped into [0, 1)).
@(private = "file")
morph_at :: proc(pts: []Vec2, params: []f32, at: f32) -> Vec2 {
	u := at - f32(int(at))
	if u < 0 {
		u += 1
	}
	// The last vertex at or before u.
	lo, hi := 0, len(params)
	for hi - lo > 1 {
		mid := (lo + hi) / 2
		if params[mid] <= u {
			lo = mid
		} else {
			hi = mid
		}
	}
	u0 := params[lo]
	u1: f32 = params[lo + 1] if lo + 1 < len(params) else 1
	p0, p1 := pts[lo], pts[(lo + 1) % len(pts)]
	if u1 <= u0 {
		return p0
	}
	return p0 + (p1 - p0) * ((u - u0) / (u1 - u0))
}

// The signed area of a ring of positions (positive for path solidity
// `.Solid`), and its area centroid (the
// vertex mean for a ring of no area).
@(private = "file")
morph_area :: proc "contextless" (pts: []Vec2) -> (area: f32, centroid: Vec2) {
	mean: Vec2
	o := pts[0]
	for k in 0 ..< len(pts) {
		p0, p1 := pts[k] - o, pts[(k + 1) % len(pts)] - o
		c := p1.x * p0.y - p0.x * p1.y // == (p1.x - p0.x) * (p1.y + p0.y) summed
		area += c
		centroid += (p0 + p1) * c
		mean += pts[k]
	}
	if abs(area) < 1e-9 {
		return 0, mean / f32(len(pts))
	}
	return area * 0.5, o + centroid / (3 * area)
}

// The middle of the ring's longest edge: a point on it away from corners,
// unlikely to lie on another contour.
@(private = "file")
morph_edge_point :: proc "contextless" (pts: []Vec2) -> Vec2 {
	best: f32 = -1
	k0 := 0
	for k in 0 ..< len(pts) {
		if d := mag2(pts[(k + 1) % len(pts)] - pts[k]); d > best {
			best, k0 = d, k
		}
	}
	return (pts[k0] + pts[(k0 + 1) % len(pts)]) * 0.5
}

// The winding number of the closed ring around `p`.
@(private = "file")
morph_winding :: proc "contextless" (pts: []Vec2, p: Vec2) -> int {
	w := 0
	for k in 0 ..< len(pts) {
		p0, p1 := pts[k], pts[(k + 1) % len(pts)]
		side := (p1.x - p0.x) * (p.y - p0.y) - (p.x - p0.x) * (p1.y - p0.y)
		if p0.y <= p.y {
			if p1.y > p.y && side > 0 {
				w += 1
			}
		} else if p1.y <= p.y && side < 0 {
			w -= 1
		}
	}
	return w
}
