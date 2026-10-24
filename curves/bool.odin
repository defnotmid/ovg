package curves

import "core:math"
import "core:slice"

// Booleans of filled contours that keep their curves: union, difference,
// intersection and xor of any number of operands, and simplify (one
// operand under its fill rule). One arrangement of all operands' pieces:
//
//   pieces monotone in x and y, with their source segment and t range, and
//     their ends at their contour's nodes (one point per joint); identical
//     pieces one, their windings summed, and gone when they cancel;
//   one point wherever two pieces come within eps (a crossing, a touch, an
//     overlap's end), cut into both, or the node of an end within eps;
//   vertices: points within eps merged, pieces cut where a vertex lies
//     within eps of them, and edges sharing no vertex that come within eps
//     met there, until nothing changes, so such edges are more than eps
//     apart;
//   edges between consecutive cuts, their curves snapped to their vertices;
//     edges along the same curve between the same vertices merged, their
//     windings summed;
//   edges ordered around each vertex, faces walked, each face's winding
//     per operand propagated across edges from an outer face per
//     component;
//   the edges between a kept face and a dropped one traced into contours,
//     consecutive pieces of one source segment joined back into it.
//
// Every table is the caller's Bool_Scratch, cleared per call: no
// allocation once it is warm.

Bool_Op :: enum u8 {
	// Inside any operand.
	Union,
	// Inside the first and none of the rest.
	Difference,
	// Inside every operand.
	Intersection,
	// Inside an odd number of operands.
	Xor,
}

Bool_Error :: enum u8 {
	None,
	Non_Finite,
	// The work budget ran out.
	Limit,
	// The arrangement didn't hold together (a bug, or input beyond what
	// eps can resolve); the result is left empty.
	Inconsistent,
}

// An operand: contours [first, first + count) of the input table, filled
// by its rule. Open contours close with a line, as fills do.
Bool_Input :: struct {
	first, count: u32,
	even_odd:     bool,
}

// What a run did, for tests.
Bool_Stats :: struct {
	pieces, pairs, vertices, edges, faces, snap_rounds, ties: int,
}

Bool_Scratch :: struct {
	// Input segments, closing lines of open contours included.
	rows:    [dynamic]Bool_Row,
	pieces:  [dynamic]Piece,
	pnode:   [dynamic][2]u32, // per piece: the points at its ends
	pdelta:  [dynamic]i32, // per piece: its winding per operand
	boxes:   [dynamic][2][2]f64,
	eboxes:  [dynamic][2][2]f64,
	order:   [dynamic]u32,
	keys:    [dynamic]u64, // sort keys of order, reused by stages
	tkeys:   [dynamic]u64,
	torder:  [dynamic]u32,
	cells:   [dynamic]u32, // starts of runs of points in one eps cell
	cand:    [dynamic]u64, // hot pixel candidates: vertex << 32 | piece
	kernel:  Kernel_Scratch,
	runs:    [dynamic]Run,
	// Cuts on pieces at points (several cuts can share one); points merge
	// into vertices.
	cuts:    [dynamic]Bool_Cut,
	tcuts:   [dynamic]Bool_Cut,
	pstart:  [dynamic]u32, // per piece: its cuts' span of plist
	plist:   [dynamic]u32,
	pts:     [dynamic][2]f64,
	input:   [dynamic]bool, // the point is a source segment's end
	parent:  [dynamic]u32,
	vert:    [dynamic]u32, // point -> vertex
	vfirst:  [dynamic]u32, // vertex -> its lowest-index point (its root)
	vpos:    [dynamic][2]f64,
	vrad:    [dynamic]f64,
	vout:    [dynamic]Vec2, // vertex positions rounded to f32, once
	edges:   [dynamic]Bool_Edge,
	ecurve:  [dynamic][4][2]f64,
	edelta:  [dynamic]i32, // operands per edge
	// Half-edges 2e (v0 -> v1) and 2e + 1 (back), ordered around vertices.
	hdir:    [dynamic][2]f64,
	vstart:  [dynamic]u32,
	vlist:   [dynamic]u32,
	hpos:    [dynamic]u32,
	hnext:   [dynamic]u32,
	hface:   [dynamic]u32,
	fhalf:   [dynamic]u32, // per face: its lowest-index half-edge
	farea:   [dynamic]f64,
	fwind:   [dynamic]i32, // operands per face
	fdone:   [dynamic]bool,
	inside:  [dynamic]bool,
	comp:    [dynamic]u32,
	cleft:   [dynamic]u32, // per component root: its leftmost vertex
	queue:   [dynamic]u32,
	stack:   [dynamic][2]f64,
	keep:    [dynamic]bool,
	used:    [dynamic]bool,
	counts:  [dynamic]u32, // per vertex, reused by stages
	placed:  [dynamic]bool,
	// The result, and per segment where it came from: its source segment
	// (an index into the input's kinds, or max(u32) for a closing line
	// added to an open contour) and the t range it covers there.
	out:     Contours,
	out_row: [dynamic]u32,
	out_t:   [dynamic][2]f32,
	// bool_divide: each region's contours in `out` (first, count), and
	// whether it lies inside each operand under its rule (k per region).
	faces:    [dynamic][2]u32,
	faces_in: [dynamic]bool,
	fcomp:   [dynamic]u32, // per face: its component
	cparent: [dynamic]u32, // per face of a component's outside: the face holding it
	stats:   Bool_Stats,
}

Bool_Row :: struct {
	p:       [4][2]f64,
	src:     [4]Vec2,
	row:     u32,
	operand: u16,
	line:    bool,
	first:   bool, // the first of its contour
}

Bool_Cut :: struct {
	piece: u32,
	t:     f64,
	point: u32,
	pos:   [2]f64, // the piece's point at t
}

Bool_Edge :: struct {
	piece:  u32,
	t0, t1: f64, // its range of the piece's parameter
	v0, v1: u32,
	alive:  bool,
}

bool_scratch_destroy :: proc(s: ^Bool_Scratch) {
	delete(s.rows)
	delete(s.pieces)
	delete(s.pnode)
	delete(s.pdelta)
	delete(s.boxes)
	delete(s.eboxes)
	delete(s.order)
	delete(s.keys)
	delete(s.tkeys)
	delete(s.torder)
	delete(s.cells)
	delete(s.cand)
	kernel_scratch_destroy(&s.kernel)
	delete(s.runs)
	delete(s.cuts)
	delete(s.tcuts)
	delete(s.pstart)
	delete(s.plist)
	delete(s.pts)
	delete(s.input)
	delete(s.parent)
	delete(s.vert)
	delete(s.vfirst)
	delete(s.vpos)
	delete(s.vrad)
	delete(s.vout)
	delete(s.edges)
	delete(s.ecurve)
	delete(s.edelta)
	delete(s.hdir)
	delete(s.vstart)
	delete(s.vlist)
	delete(s.hpos)
	delete(s.hnext)
	delete(s.hface)
	delete(s.fhalf)
	delete(s.farea)
	delete(s.fwind)
	delete(s.fdone)
	delete(s.inside)
	delete(s.comp)
	delete(s.cleft)
	delete(s.queue)
	delete(s.stack)
	delete(s.keep)
	delete(s.used)
	delete(s.counts)
	delete(s.placed)
	contours_destroy(&s.out)
	delete(s.out_row)
	delete(s.out_t)
	delete(s.faces)
	delete(s.faces_in)
	delete(s.fcomp)
	delete(s.cparent)
	s^ = {}
}

// Runs `op` over the operands `inputs` of table `c`; the result is in
// s.out, Solid-wound with holes reversed and no contour crossing another,
// so either fill rule fills it alike. `budget` bounds the work (kernel cell
// pairs and snap rounds). On an error s.out is empty.
bool_run :: proc(s: ^Bool_Scratch, c: ^Contours, inputs: []Bool_Input, op: Bool_Op, budget: ^int) -> (err: Bool_Error) {
	if !(bool_arrange(s, c, inputs, budget) or_return) {
		return
	}
	k := len(inputs)
	for f in 0 ..< len(s.farea) {
		s.inside[f] = bool_inside(s.fwind[f * k:][:k], inputs, op)
	}
	bool_emit(s)
	return
}

// Splits the operands into every face they make (Illustrator's divide):
// each bounded face inside at least one operand becomes a region of its
// own, its outline Solid-wound and the components nested directly in it
// as holes, curves kept as bool_run keeps them. s.faces holds each
// region's contours in s.out, s.faces_in the operands it lies inside.
bool_divide :: proc(s: ^Bool_Scratch, c: ^Contours, inputs: []Bool_Input, budget: ^int) -> (err: Bool_Error) {
	clear(&s.faces)
	clear(&s.faces_in)
	if !(bool_arrange(s, c, inputs, budget) or_return) {
		return
	}
	k := len(inputs)
	nf := len(s.farea)
	// Each face's component, and the face holding each component's
	// outside: the smallest bounded face of another component winding
	// about its leftmost vertex.
	resize(&s.fcomp, nf)
	for e, i in s.edges {
		if e.alive {
			r := find(s.comp[:], e.v0)
			s.fcomp[s.hface[2 * i]], s.fcomp[s.hface[2 * i + 1]] = r, r
		}
	}
	resize(&s.cparent, nf)
	slice.fill(s.cparent[:], max(u32))
	for f in 0 ..< nf {
		if s.farea[f] >= 0 {
			continue
		}
		lv := s.cleft[s.fcomp[f]]
		best := math.INF_F64
		for g in 0 ..< nf {
			if s.farea[g] <= 0 || s.fcomp[g] == s.fcomp[f] || s.farea[g] >= best {
				continue
			}
			w: i32
			h := s.fhalf[g]
			for {
				q := s.ecurve[h >> 1]
				if h & 1 == 1 {
					q = {q[3], q[2], q[1], q[0]}
				}
				cw, _ := curve_winding(q, s.vpos[lv], 0, &s.stack)
				w += cw
				h = s.hnext[h]
				if h == s.fhalf[g] {
					break
				}
			}
			if w != 0 {
				best, s.cparent[f] = s.farea[g], u32(g)
			}
		}
	}
	// The regions, in face order.
	for f in 0 ..< nf {
		if s.farea[f] <= 0 {
			continue
		}
		any := false
		for o in 0 ..< k {
			any ||= fill_inside(s.fwind[f * k + o], inputs[o].even_odd)
		}
		if !any {
			continue
		}
		first := u32(len(s.out.contours))
		emit_face_reversed(s, u32(f))
		for g in 0 ..< nf {
			if s.cparent[g] == u32(f) {
				emit_face_reversed(s, u32(g))
			}
		}
		append(&s.faces, [2]u32{first, u32(len(s.out.contours)) - first})
		for o in 0 ..< k {
			append(&s.faces_in, fill_inside(s.fwind[f * k + o], inputs[o].even_odd))
		}
	}
	return
}

// The arrangement of the operands up to each face's winding per operand;
// false when there is nothing to arrange.
@(private = "file")
bool_arrange :: proc(s: ^Bool_Scratch, c: ^Contours, inputs: []Bool_Input, budget: ^int) -> (ok: bool, err: Bool_Error) {
	contours_clear(&s.out)
	clear(&s.out_row)
	clear(&s.out_t)
	s.stats = {}
	k := len(inputs)
	if k == 0 {
		return
	}
	eps, delta := bool_gather(s, c, inputs) or_return
	if len(s.rows) == 0 {
		return
	}
	bool_pieces(s, eps)
	merge_identical(s, k)
	bool_cuts(s, eps, delta, budget) or_return
	bool_vertices(s, eps, delta, budget) or_return
	bool_edges(s, k, eps, delta, budget) or_return
	bool_faces(s, k, eps)
	bool_windings(s, k, eps) or_return
	return true, nil
}

// Emits face f's cycle as a closed contour run backwards (a bounded face's
// cycle then winds Solid, a component's outside winds as a hole).
@(private = "file")
emit_face_reversed :: proc(s: ^Bool_Scratch, f: u32) {
	clear(&s.queue)
	he := s.fhalf[f]
	for {
		append(&s.queue, he)
		he = s.hnext[he]
		if he == s.fhalf[f] {
			break
		}
	}
	// Backwards: the twins, last first.
	begun := false
	run_row := max(u32)
	run_t0, run_t1: f64
	run_v0, end_v: u32
	#reverse for x in s.queue {
		h := x ~ 1
		e := s.edges[h >> 1]
		p := &s.pieces[e.piece]
		ta, tb := source_t(p, e.t0), source_t(p, e.t1)
		v0, v1 := e.v0, e.v1
		if h & 1 == 1 {
			ta, tb, v0, v1 = tb, ta, v1, v0
		}
		switch {
		case !begun:
			contours_begin(&s.out, s.vout[v0])
			begun = true
			run_row, run_t0, run_t1, run_v0 = p.row, ta, tb, v0
		case p.row == run_row && ta == run_t1 && (tb > ta) == (run_t1 > run_t0):
			run_t1 = tb
		case:
			emit_range(s, run_row, run_t0, run_t1, run_v0, v0)
			run_row, run_t0, run_t1, run_v0 = p.row, ta, tb, v0
		}
		end_v = v1
	}
	emit_range(s, run_row, run_t0, run_t1, run_v0, end_v)
	contours_end(&s.out, true, false)
}

@(private = "file")
bool_inside :: proc(w: []i32, inputs: []Bool_Input, op: Bool_Op) -> bool {
	n := 0
	first := false
	for x, i in w {
		if fill_inside(x, inputs[i].even_odd) {
			n += 1
			first ||= i == 0
		}
	}
	switch op {
	case .Union:
		return n > 0
	case .Intersection:
		return n == len(w)
	case .Difference:
		return first && n == 1
	case .Xor:
		return n & 1 == 1
	}
	return false
}

// S0: the operands' segments in f64, closing lines of open contours added,
// zero-length ones dropped; eps from the largest coordinate.
@(private = "file")
bool_gather :: proc(s: ^Bool_Scratch, c: ^Contours, inputs: []Bool_Input) -> (eps, delta: f64, err: Bool_Error) {
	clear(&s.rows)
	M: f64
	f :: #force_inline proc "contextless" (v: Vec2) -> [2]f64 {
		return {f64(v.x), f64(v.y)}
	}
	add :: proc(s: ^Bool_Scratch, src: [4]Vec2, row: u32, operand: u16, line: bool) {
		if src[0] == src[1] && src[1] == src[2] && src[2] == src[3] {
			return
		}
		append(&s.rows, Bool_Row{{f(src[0]), f(src[1]), f(src[2]), f(src[3])}, src, row, operand, line, false})
	}
	for in_, k in inputs {
		for ct in c.contours[in_.first:][:in_.count] {
			if ct.segs == 0 {
				continue
			}
			first := len(s.rows)
			pts := c.pts[ct.start:][:3 * ct.segs + 1]
			for p in pts {
				if math.is_nan(p.x) || math.is_nan(p.y) || math.is_inf(p.x) || math.is_inf(p.y) {
					return 0, 0, .Non_Finite
				}
				M = max(M, abs(f64(p.x)), abs(f64(p.y)))
			}
			for i in 0 ..< ct.segs {
				q := pts[3 * i:][:4]
				add(s, {q[0], q[1], q[2], q[3]}, ct.seg + i, u16(k), c.kinds[ct.seg + i] == .Line)
			}
			if a, b := pts[len(pts) - 1], pts[0]; a != b {
				add(s, {a, a + (b - a) / 3, a + (b - a) * (2.0 / 3), b}, max(u32), u16(k), true)
			}
			if first < len(s.rows) {
				s.rows[first].first = true
			}
		}
	}
	eps, delta = snap_epsilon(M)
	return
}

// S1: monotone pieces, their ends at their contour's nodes (consecutive
// pieces share their joint's point bitwise, and a contour's last piece
// ends at its first's start), and their boxes grown by eps.
@(private = "file")
bool_pieces :: proc(s: ^Bool_Scratch, eps: f64) {
	clear(&s.pieces)
	for r, i in s.rows {
		monotone_pieces(r.p, r.line, u32(i), r.operand, eps / 16, &s.pieces)
	}
	clear(&s.pts)
	clear(&s.input)
	clear(&s.parent)
	resize(&s.pnode, len(s.pieces))
	start, prev: u32
	for p, i in s.pieces {
		if p.t0 == 0 && s.rows[p.row].first {
			start = add_point(s, p.p[0], true)
			prev = start
		}
		last := i + 1 == len(s.pieces) || (s.pieces[i + 1].t0 == 0 && s.rows[s.pieces[i + 1].row].first)
		end := start if last else add_point(s, p.p[3], p.t1 == 1)
		s.pnode[i] = {prev, end}
		prev = end
	}
	resize(&s.boxes, len(s.pieces))
	for p, i in s.pieces {
		lo, hi := box_of(p.p)
		s.boxes[i] = {lo - eps, hi + eps}
	}
}

// Identical pieces (the same line, or the same cubic, either way round: the
// shared sides of tiled shapes) are one: their windings per operand sum
// into the first, and a piece whose windings cancel goes. Pieces are sorted
// by their lesser end (a key of the top halves of its coordinates' keys, so
// equal ends share one) and compared within each run of equal keys.
@(private = "file")
merge_identical :: proc(s: ^Bool_Scratch, k: int) {
	n := len(s.pieces)
	resize(&s.pdelta, n * k)
	slice.fill(s.pdelta[:], 0)
	for p, i in s.pieces {
		s.pdelta[i * k + int(p.operand)] = 1
	}
	start :: proc(p: Piece) -> [2]f64 {
		a, b := p.p[0], p.p[3]
		return a if a.x < b.x || (a.x == b.x && a.y <= b.y) else b
	}
	resize(&s.order, n)
	resize(&s.keys, n)
	for p, i in s.pieces {
		e := start(p)
		s.order[i] = u32(i)
		s.keys[i] = f64_key(e.x) >> 32 << 32 | f64_key(e.y) >> 32
	}
	sort_keyed(s.keys[:], s.order[:], &s.tkeys, &s.torder)
	for i := 0; i < n; {
		j := i + 1
		for j < n && s.keys[j] == s.keys[i] {
			j += 1
		}
		// Each piece into the first identical one before it (in index order
		// within the group), which no earlier piece took.
		for b in i + 1 ..< j {
			for a in i ..< b {
				pa, pb := int(s.order[a]), int(s.order[b])
				if dir := same_piece(&s.pieces[pa], &s.pieces[pb]); dir != 0 {
					for o in 0 ..< k {
						s.pdelta[pa * k + o] += dir * s.pdelta[pb * k + o]
						s.pdelta[pb * k + o] = 0
					}
					break
				}
			}
		}
		i = j
	}
	w := 0
	for i in 0 ..< n {
		if slice.all_of(s.pdelta[i * k:][:k], 0) {
			continue
		}
		s.pieces[w], s.pnode[w], s.boxes[w] = s.pieces[i], s.pnode[i], s.boxes[i]
		copy(s.pdelta[w * k:][:k], s.pdelta[i * k:][:k])
		w += 1
	}
	resize(&s.pieces, w)
	resize(&s.pnode, w)
	resize(&s.boxes, w)
	resize(&s.pdelta, w * k)
	s.stats.pieces = w
}

// 1 when pieces a and b are the same, -1 when the same reversed, else 0: a
// line by its ends, a cubic by its controls.
@(private = "file")
same_piece :: proc "contextless" (a, b: ^Piece) -> i32 {
	if a.line != b.line {
		return 0
	}
	p, q := a.p, b.p
	switch {
	case p[0] == q[0] && p[3] == q[3] && (a.line || (p[1] == q[1] && p[2] == q[2])):
		return 1
	case p[0] == q[3] && p[3] == q[0] && (a.line || (p[1] == q[2] && p[2] == q[1])):
		return -1
	}
	return 0
}

// Calls `visit` for each pair of pieces whose grown boxes meet, by a sweep
// over boxes sorted by their left edge.
@(private = "file")
bool_pairs :: proc(s: ^Bool_Scratch, boxes: [][2][2]f64, visit: proc(s: ^Bool_Scratch, a, b: u32, data: rawptr) -> bool, data: rawptr) -> bool {
	resize(&s.order, len(boxes))
	resize(&s.keys, len(boxes))
	for &o, i in s.order {
		o = u32(i)
		s.keys[i] = f64_key(boxes[i][0].x)
	}
	sort_keyed(s.keys[:], s.order[:], &s.tkeys, &s.torder)
	for i in 0 ..< len(s.order) {
		a := s.order[i]
		ba := boxes[a]
		for j in i + 1 ..< len(s.order) {
			b := s.order[j]
			bb := boxes[b]
			if bb[0].x > ba[1].x {
				break
			}
			if bb[0].y > ba[1].y || bb[1].y < ba[0].y {
				continue
			}
			if !visit(s, min(a, b), max(a, b), data) {
				return false
			}
		}
	}
	return true
}

@(private = "file")
Cut_Pass :: struct {
	eps, delta: f64,
	budget:     ^int,
}

// S2-S3: each piece cut at its ends' nodes, and one point wherever two
// pieces come within eps.
@(private = "file")
bool_cuts :: proc(s: ^Bool_Scratch, eps, delta: f64, budget: ^int) -> Bool_Error {
	clear(&s.cuts)
	for n, i in s.pnode {
		add_cut(s, u32(i), 0, n[0])
		add_cut(s, u32(i), 1, n[1])
	}
	pass := Cut_Pass{eps, delta, budget}
	ok := bool_pairs(s, s.boxes[:], proc(s: ^Bool_Scratch, a, b: u32, data: rawptr) -> bool {
		pass := (^Cut_Pass)(data)
		pa, pb := &s.pieces[a], &s.pieces[b]
		clear(&s.runs)
		cell := shared_corner(s, a, b, pass.eps + pass.delta)
		if !near_runs(pa, pb, pass.eps, pass.delta, &s.kernel, &s.runs, pass.budget, cell) {
			return false
		}
		s.stats.pairs += 1
		for r in s.runs {
			if r.point {
				meet_pieces(s, a, (r.s0 + r.s1) / 2, b, (r.t0 + r.t1) / 2, pass.eps)
				continue
			}
			ta, tb := overlap_ends(pa, pb, r)
			if u, v, crossed := crossing(pa, pb, ta, tb); crossed {
				meet_pieces(s, a, u, b, v, pass.eps)
				continue
			}
			for e in 0 ..< 2 {
				meet_pieces(s, a, ta[e], b, tb[e], pass.eps)
			}
		}
		return true
	}, &pass)
	return nil if ok else .Limit
}

// Where every pair of points of pieces a and b within r of each other lies
// (s0, s1 of a, t0, t1 of b): near the end they share when they lie on
// opposite sides of it in x or y. Each piece is monotone, so on that axis
// every point of a is on one side of the shared point p (or level with it,
// when its far end is) and every point of b on the other, and two points
// within r both lie within r of p there. Only a curve's stretch is bounded:
// the search never halves a line.
@(private = "file")
shared_corner :: proc(s: ^Bool_Scratch, a, b: u32, r: f64) -> (cell: [4]f64) {
	cell = {0, 1, 0, 1}
	na, nb := s.pnode[a], s.pnode[b]
	ea, eb: int // the shared end of each (0 or 1)
	switch {
	case na[1] == nb[0] && na[0] != nb[1]:
		ea, eb = 1, 0
	case na[0] == nb[1] && na[1] != nb[0]:
		ea, eb = 0, 1
	case:
		return
	}
	pa, pb := &s.pieces[a], &s.pieces[b]
	p := pa.p[3 * ea]
	for axis in 0 ..< 2 {
		da, db := pa.p[3 - 3 * ea][axis] - p[axis], pb.p[3 - 3 * eb][axis] - p[axis]
		if da * db > 0 || (da == 0 && db == 0) {
			continue
		}
		if !pa.line {
			narrow(cell[0:2], ea, near_end(pa, ea, axis, p[axis], r))
		}
		if !pb.line {
			narrow(cell[2:4], eb, near_end(pb, eb, axis, p[axis], r))
		}
	}
	return
}

// Narrows a piece's span [lo, hi] to the stretch between its end `end` and
// t.
@(private = "file")
narrow :: proc "contextless" (span: []f64, end: int, t: f64) {
	if end == 1 {
		span[0] = max(span[0], t)
	} else {
		span[1] = min(span[1], t)
	}
}

// Going from piece p's end `end` towards its other end, a parameter where
// its coordinate on `axis` (monotone) lies between r and 2 r from c, by
// bisection (or the other end, when it lies within 2 r): the stretch before
// it holds every point within r of c there.
@(private = "file")
near_end :: proc(p: ^Piece, end, axis: int, c, r: f64) -> f64 {
	near, far := f64(end), f64(1 - end)
	d := abs(piece_at(p, far)[axis] - c)
	for d > 2 * r {
		m := (near + far) / 2
		if m == near || m == far {
			break
		}
		if dm := abs(piece_at(p, m)[axis] - c); dm <= r {
			near = m
		} else {
			far, d = m, dm
		}
	}
	return far
}

// An overlap's two ends on each piece, each paired with the nearer end on
// the other.
@(private = "file")
overlap_ends :: proc(a, b: ^Piece, r: Run) -> (ta, tb: [2]f64) {
	ta, tb = {r.s0, r.s1}, {r.t0, r.t1}
	d :: proc(a, b: ^Piece, s, t: f64) -> f64 {
		v := piece_at(a, s) - piece_at(b, t)
		return v.x * v.x + v.y * v.y
	}
	if d(a, b, ta[0], tb[0]) + d(a, b, ta[1], tb[1]) > d(a, b, ta[0], tb[1]) + d(a, b, ta[1], tb[0]) {
		tb = {tb[1], tb[0]}
	}
	return
}

// Where pieces a and b cross within a run whose ends pair a's ta[i] with
// b's tb[i]: at each end b lies on a side of a, and when the sides are
// opposite they cross between, at the parameters interpolated where the
// side changes. A shallow crossing's run is long, but it is still one
// meeting; a touch or an overlap keeps to one side.
@(private = "file")
crossing :: proc(a, b: ^Piece, ta, tb: [2]f64) -> (u, v: f64, crossed: bool) {
	side :: proc(a, b: ^Piece, s, t: f64) -> f64 {
		d, w := cubic_tangent(a.p, s), piece_at(b, t) - piece_at(a, s)
		return d.x * w.y - d.y * w.x
	}
	d0, d1 := side(a, b, ta[0], tb[0]), side(a, b, ta[1], tb[1])
	if !(d0 < 0 && d1 > 0) && !(d0 > 0 && d1 < 0) {
		return
	}
	k := d0 / (d0 - d1)
	return ta[0] + (ta[1] - ta[0]) * k, tb[0] + (tb[1] - tb[0]) * k, true
}

// Pieces a and b meet at their parameters ta and tb, halfway between them.
@(private = "file")
meet_pieces :: proc(s: ^Bool_Scratch, a: u32, ta: f64, b: u32, tb: f64, eps: f64) {
	pa, pb := &s.pieces[a], &s.pieces[b]
	m := (piece_at(pa, ta) + piece_at(pb, tb)) / 2
	ea := end_near(s.pnode[a], {pa.p[0], pa.p[3]}, m, eps)
	eb := end_near(s.pnode[b], {pb.p[0], pb.p[3]}, m, eps)
	meet(s, a, ta, ea, b, tb, eb, m)
}

// Of the points e at an edge's or a piece's two ends (at q), the nearer m
// when within eps of it, or none.
@(private = "file")
end_near :: proc "contextless" (e: [2]u32, q: [2][2]f64, m: [2]f64, eps: f64) -> u32 {
	d0, d1 := q[0] - m, q[1] - m
	l0, l1 := d0.x * d0.x + d0.y * d0.y, d1.x * d1.x + d1.y * d1.y
	if min(l0, l1) > eps * eps {
		return max(u32)
	}
	return e[0] if l0 <= l1 else e[1]
}

// Pieces a and b meet at their parameters ta and tb near m: at the point ea
// or eb at an end of either within eps of m (both: the points are one),
// else at a new point m, cut into both.
@(private = "file")
meet :: proc(s: ^Bool_Scratch, a: u32, ta: f64, ea: u32, b: u32, tb: f64, eb: u32, m: [2]f64) {
	switch {
	case ea != max(u32) && eb != max(u32):
		unite(s.parent[:], ea, eb)
	case ea != max(u32):
		add_cut(s, b, tb, ea)
	case eb != max(u32):
		add_cut(s, a, ta, eb)
	case:
		p := add_point(s, m, false)
		add_cut(s, a, ta, p)
		add_cut(s, b, tb, p)
	}
}

@(private = "file")
add_point :: proc(s: ^Bool_Scratch, p: [2]f64, input: bool) -> u32 {
	i := u32(len(s.pts))
	append(&s.pts, p)
	append(&s.parent, i)
	append(&s.input, input)
	return i
}

@(private = "file")
add_cut :: proc(s: ^Bool_Scratch, piece: u32, t: f64, point: u32) {
	p := &s.pieces[piece]
	append(&s.cuts, Bool_Cut{piece, t, point, p.p[0] if t == 0 else p.p[3] if t == 1 else piece_at(p, t)})
}

// Sorts keys (and idx with them, when given) stably: insertion for a few,
// else LSD radix over the bytes where the keys differ.
@(private = "file")
sort_keyed :: proc(keys: []u64, idx: []u32, tkeys: ^[dynamic]u64, tidx: ^[dynamic]u32) {
	n := len(keys)
	with_idx := len(idx) == n
	if n < 64 {
		for i in 1 ..< n {
			k := keys[i]
			x := idx[i] if with_idx else 0
			j := i
			for j > 0 && keys[j - 1] > k {
				keys[j] = keys[j - 1]
				if with_idx {
					idx[j] = idx[j - 1]
				}
				j -= 1
			}
			keys[j] = k
			if with_idx {
				idx[j] = x
			}
		}
		return
	}
	resize(tkeys, n)
	resize(tidx, n if with_idx else 0)
	ka, kb, ia, ib := keys, tkeys[:], idx, tidx[:]
	for shift := u64(0); shift < 64; shift += 8 {
		count: [257]int
		for k in ka {
			count[((k >> shift) & 0xff) + 1] += 1
		}
		if count[((ka[0] >> shift) & 0xff) + 1] == n {
			continue
		}
		for b in 1 ..< 257 {
			count[b] += count[b - 1]
		}
		for k, i in ka {
			d := (k >> shift) & 0xff
			kb[count[d]] = k
			if with_idx {
				ib[count[d]] = ia[i]
			}
			count[d] += 1
		}
		ka, kb, ia, ib = kb, ka, ib, ia
	}
	if raw_data(ka) != raw_data(keys) {
		copy(keys, ka)
		if with_idx {
			copy(idx, ia)
		}
	}
}

// A key ordering f64s as numbers (-0 with +0).
@(private = "file")
f64_key :: #force_inline proc "contextless" (x: f64) -> u64 {
	if x == 0 {
		return 1 << 63
	}
	b := transmute(u64)x
	return ~b if b >> 63 == 1 else b | 1 << 63
}

// The key of the eps-wide cell holding p, ordered by column then row.
@(private = "file")
cell_key :: #force_inline proc "contextless" (p: [2]f64, eps: f64) -> u64 {
	cx, cy := i64(math.floor(p.x / eps)), i64(math.floor(p.y / eps))
	return u64(cx + 1 << 31) << 32 | u64(cy + 1 << 31)
}

@(private = "file")
find :: proc(parent: []u32, x: u32) -> u32 {
	x := x
	for parent[x] != x {
		parent[x] = parent[parent[x]]
		x = parent[x]
	}
	return x
}

@(private = "file")
unite :: proc(parent: []u32, a, b: u32) -> bool {
	ra, rb := find(parent, a), find(parent, b)
	if ra == rb {
		return false
	}
	// The lower index is the root, so the order of unions doesn't matter.
	if ra < rb {
		parent[rb] = ra
	} else {
		parent[ra] = rb
	}
	return true
}

// S4: points within eps merge into vertices; pieces are cut where a vertex
// lies within eps of them; edges sharing no vertex that come within eps
// meet; until nothing meets.
@(private = "file")
bool_vertices :: proc(s: ^Bool_Scratch, eps, delta: f64, budget: ^int) -> Bool_Error {
	for round := 0;; round += 1 {
		s.stats.snap_rounds = round + 1
		if budget^ -= len(s.pts); budget^ < 0 {
			return .Limit
		}
		// Points within eps, by cells eps wide: each cell against itself
		// and the four after it of its eight neighbours.
		resize(&s.order, len(s.pts))
		resize(&s.keys, len(s.pts))
		for p, i in s.pts {
			s.order[i] = u32(i)
			s.keys[i] = cell_key(p, eps)
		}
		sort_keyed(s.keys[:], s.order[:], &s.tkeys, &s.torder)
		clear(&s.cells)
		for i in 0 ..< len(s.keys) {
			if i == 0 || s.keys[i] != s.keys[i - 1] {
				append(&s.cells, u32(i))
			}
		}
		nc := len(s.cells)
		append(&s.cells, u32(len(s.keys)))
		for c in 0 ..< nc {
			a0, a1 := s.cells[c], s.cells[c + 1]
			near_points(s, a0, a1, a0, a1, eps)
			cx, cy := i64(s.keys[a0] >> 32), i64(s.keys[a0] & 0xffff_ffff)
			for d in ([4][2]i64{{0, 1}, {1, -1}, {1, 0}, {1, 1}}) {
				key := u64(cx + d[0]) << 32 | u64(cy + d[1])
				lo, hi := c + 1, nc
				for lo < hi {
					m := (lo + hi) / 2
					if s.keys[s.cells[m]] < key {
						lo = m + 1
					} else {
						hi = m
					}
				}
				if lo < nc && s.keys[s.cells[lo]] == key {
					near_points(s, a0, a1, s.cells[lo], s.cells[lo + 1], eps)
				}
			}
		}
		// Hot pixels: a vertex within eps of a piece it isn't a cut of cuts it
		// there, once (that makes no vertex). Candidates by a sweep of the
		// pieces' boxes over the vertices sorted by x, then taken vertex by
		// vertex.
		{
			number_vertices(s)
			n := len(s.cuts)
			group_cuts(s, n)
			resize(&s.order, len(s.vpos))
			resize(&s.keys, len(s.vpos))
			for v, i in s.vpos {
				s.order[i] = u32(i)
				s.keys[i] = f64_key(v.x)
			}
			sort_keyed(s.keys[:], s.order[:], &s.tkeys, &s.torder)
			clear(&s.cand)
			// Each piece's own vertices stamped with it first (counts, per
			// vertex), so whether it has one is a lookup.
			resize(&s.counts, len(s.vpos))
			slice.fill(s.counts[:], 0)
			for b, pi in s.boxes {
				for c in s.plist[s.pstart[pi]:s.pstart[pi + 1]] {
					s.counts[s.vert[s.cuts[c].point]] = u32(pi) + 1
				}
				x0, x1 := f64_key(b[0].x), f64_key(b[1].x)
				lo, hi := 0, len(s.keys)
				for lo < hi {
					m := (lo + hi) / 2
					if s.keys[m] < x0 {
						lo = m + 1
					} else {
						hi = m
					}
				}
				for i := lo; i < len(s.keys) && s.keys[i] <= x1; i += 1 {
					vi := s.order[i]
					if y := s.vpos[vi].y; y < b[0].y || y > b[1].y || s.counts[vi] == u32(pi) + 1 {
						continue
					}
					append(&s.cand, u64(vi) << 32 | u64(pi))
				}
			}
			sort_keyed(s.cand[:], nil, &s.tkeys, &s.torder)
			for c in s.cand {
				vi, pi := u32(c >> 32), u32(c & 0xffff_ffff)
				v := s.vpos[vi]
				dot := Piece{p = {v, v, v, v}, line = true}
				clear(&s.runs)
				if !near_runs(&s.pieces[pi], &dot, eps, delta, &s.kernel, &s.runs, budget) {
					return .Limit
				}
				for r in s.runs {
					add_cut(s, pi, (r.s0 + r.s1) / 2, s.vfirst[vi])
				}
			}
		}
		number_vertices(s)
		// Edges sharing no vertex must stay more than eps apart: where two
		// come within eps, they meet.
		repaired, err := repair_edges(s, eps, delta, budget)
		if err != nil {
			return err
		}
		if !repaired {
			break
		}
		if round > 64 {
			return .Limit
		}
	}
	// The last repair found nothing to change: its edges stand.
	s.stats.vertices = len(s.vpos)
	return nil
}

// Numbers the union-find roots as vertices: each at the position of its
// lowest-index source end if it has one (input points stay put), else of
// its lowest-index point; its radius the farthest cut at it.
@(private = "file")
number_vertices :: proc(s: ^Bool_Scratch) {
	resize(&s.vert, len(s.pts))
	clear(&s.vfirst)
	clear(&s.vpos)
	clear(&s.vrad)
	for i in 0 ..< len(s.pts) {
		s.vert[i] = max(u32)
	}
	for i in 0 ..< len(s.pts) {
		r := find(s.parent[:], u32(i))
		if s.vert[r] == max(u32) {
			s.vert[r] = u32(len(s.vpos))
			append(&s.vfirst, r)
			append(&s.vpos, s.pts[r])
			append(&s.vrad, 0)
		}
		s.vert[i] = s.vert[r]
	}
	// Prefer a source end's position.
	resize(&s.placed, len(s.vpos))
	slice.fill(s.placed[:], false)
	for i in 0 ..< len(s.pts) {
		v := s.vert[i]
		if s.input[i] && !s.placed[v] {
			s.vpos[v], s.placed[v] = s.pts[i], true
		}
	}
	for c in s.cuts {
		v := s.vert[c.point]
		d := c.pos - s.vpos[v]
		s.vrad[v] = max(s.vrad[v], math.sqrt(d.x * d.x + d.y * d.y))
	}
}

// Unites the points of order[a0:a1] with those of order[b0:b1] within eps
// (with the later ones of the same span when they are one).
@(private = "file")
near_points :: proc(s: ^Bool_Scratch, a0, a1, b0, b1: u32, eps: f64) {
	for i in a0 ..< a1 {
		a := s.order[i]
		for j in (i + 1 if a0 == b0 else b0) ..< b1 {
			b := s.order[j]
			if d := s.pts[a] - s.pts[b]; d.x * d.x + d.y * d.y <= eps * eps {
				unite(s.parent[:], a, b)
			}
		}
	}
}

// Each piece's cuts among the first n, as its span of plist.
@(private = "file")
group_cuts :: proc(s: ^Bool_Scratch, n: int) {
	resize(&s.pstart, len(s.pieces) + 1)
	slice.fill(s.pstart[:], 0)
	for c in s.cuts[:n] {
		s.pstart[c.piece + 1] += 1
	}
	for i in 1 ..< len(s.pstart) {
		s.pstart[i] += s.pstart[i - 1]
	}
	// Fill with the starts as cursors, then shift them back.
	resize(&s.plist, n)
	for c, i in s.cuts[:n] {
		s.plist[s.pstart[c.piece]] = u32(i)
		s.pstart[c.piece] += 1
	}
	for i := len(s.pstart) - 1; i > 0; i -= 1 {
		s.pstart[i] = s.pstart[i - 1]
	}
	s.pstart[0] = 0
}

// By piece, then t, then point: grouped by piece, each piece's few cuts
// sorted by insertion.
@(private = "file")
sort_cuts :: proc(s: ^Bool_Scratch) {
	n := len(s.cuts)
	group_cuts(s, n)
	resize(&s.tcuts, n)
	for pi in 0 ..< len(s.pieces) {
		a0, a1 := int(s.pstart[pi]), int(s.pstart[pi + 1])
		for i in a0 ..< a1 {
			x := s.cuts[s.plist[i]]
			j := i
			for j > a0 && cut_after(s.tcuts[j - 1], x) {
				s.tcuts[j] = s.tcuts[j - 1]
				j -= 1
			}
			s.tcuts[j] = x
		}
	}
	s.cuts, s.tcuts = s.tcuts, s.cuts
}

// Whether a comes after b on their piece.
@(private = "file")
cut_after :: #force_inline proc "contextless" (a, b: Bool_Cut) -> bool {
	return a.t > b.t || (a.t == b.t && a.point > b.point)
}

// S5: an edge between consecutive cuts of a piece at different vertices,
// its curve the piece's range with its ends moved onto the vertices (the
// first and last controls moving with them), as the snap loop's last
// repair built them; edges along the same curve between the same vertices
// merge, their windings summed.
@(private = "file")
bool_edges :: proc(s: ^Bool_Scratch, k: int, eps, delta: f64, budget: ^int) -> Bool_Error {
	resize(&s.vout, len(s.vpos))
	for v, i in s.vpos {
		s.vout[i] = {f32(v.x), f32(v.y)}
	}
	resize(&s.edelta, len(s.edges) * k)
	for e, i in s.edges {
		for o in 0 ..< k {
			s.edelta[i * k + o] = s.pdelta[int(e.piece) * k + o]
		}
	}
	// Coincident edges: grouped by their vertex pair, merged when their
	// curves stay within 2 eps of each other end to end.
	return merge_coincident(s, k, eps, delta, budget)
}

// Edges between consecutive cuts of each piece at different vertices, each
// curve the piece's range with its ends moved onto its vertices (the first
// and last controls moving with them).
@(private = "file")
build_edges :: proc(s: ^Bool_Scratch) {
	sort_cuts(s)
	clear(&s.edges)
	clear(&s.ecurve)
	for i := 0; i < len(s.cuts); {
		j := i
		for j < len(s.cuts) && s.cuts[j].piece == s.cuts[i].piece {
			j += 1
		}
		pi := s.cuts[i].piece
		p := &s.pieces[pi]
		// The cuts next to an end at its vertex are that end (a touch with a
		// neighbour found a hair inside); order by t is kept.
		cs := s.cuts[i:j]
		for k := 1; k < len(cs) && s.vert[cs[k].point] == s.vert[cs[0].point]; k += 1 {
			cs[k].t = 0
		}
		for k := len(cs) - 2; k >= 0 && s.vert[cs[k].point] == s.vert[cs[len(cs) - 1].point]; k -= 1 {
			cs[k].t = 1
		}
		prev := i
		for c in i + 1 ..< j {
			a, b := s.cuts[prev], s.cuts[c]
			va, vb := s.vert[a.point], s.vert[b.point]
			if va == vb {
				continue
			}
			q := piece_range(p, a.t, b.t)
			da, db := s.vpos[va] - q[0], s.vpos[vb] - q[3]
			q[0], q[1], q[2], q[3] = q[0] + da, q[1] + da, q[2] + db, q[3] + db
			append(&s.edges, Bool_Edge{pi, a.t, b.t, va, vb, true})
			append(&s.ecurve, q)
			prev = c
		}
		i = j
	}
}

// Where two edges sharing no vertex come within eps, they meet as pieces do,
// except that an overlap only meets at the edges' own ends: where nearly
// parallel edges part is ill-conditioned (within delta of eps over a long
// stretch), and a new point there each round would creep along them. True
// when anything changed.
@(private = "file")
repair_edges :: proc(s: ^Bool_Scratch, eps, delta: f64, budget: ^int) -> (repaired: bool, err: Bool_Error) {
	build_edges(s)
	resize(&s.eboxes, len(s.edges))
	for q, i in s.ecurve {
		lo, hi := box_of(q)
		s.eboxes[i] = {lo - eps, hi + eps}
	}
	Repair :: struct {
		pass:     Cut_Pass,
		repaired: bool,
	}
	r := Repair{pass = {eps, delta, budget}}
	ok := bool_pairs(s, s.eboxes[:], proc(s: ^Bool_Scratch, a, b: u32, data: rawptr) -> bool {
		r := (^Repair)(data)
		ea, eb := s.edges[a], s.edges[b]
		if ea.v0 == eb.v0 || ea.v0 == eb.v1 || ea.v1 == eb.v0 || ea.v1 == eb.v1 {
			return true
		}
		pa := Piece{p = s.ecurve[a], line = s.pieces[ea.piece].line}
		pb := Piece{p = s.ecurve[b], line = s.pieces[eb.piece].line}
		clear(&s.runs)
		if !near_runs(&pa, &pb, r.pass.eps, r.pass.delta, &s.kernel, &s.runs, r.pass.budget) {
			return false
		}
		for run in s.runs {
			if run.point {
				r.repaired |= meet_edges(s, ea, (run.s0 + run.s1) / 2, eb, (run.t0 + run.t1) / 2, r.pass.eps, true)
				continue
			}
			ta, tb := overlap_ends(&pa, &pb, run)
			if u, v, crossed := crossing(&pa, &pb, ta, tb); crossed {
				r.repaired |= meet_edges(s, ea, u, eb, v, r.pass.eps, true)
				continue
			}
			for e in 0 ..< 2 {
				r.repaired |= meet_edges(s, ea, ta[e], eb, tb[e], r.pass.eps, false)
			}
		}
		return true
	}, &r)
	if !ok {
		return false, .Limit
	}
	return r.repaired, nil
}

// Edges a and b meet as pieces do at their own parameters ua and ub, their
// ends being their vertices; a new point only when `fresh`. True when
// anything changed.
@(private = "file")
meet_edges :: proc(s: ^Bool_Scratch, a: Bool_Edge, ua: f64, b: Bool_Edge, ub: f64, eps: f64, fresh: bool) -> bool {
	ta, tb := a.t0 + (a.t1 - a.t0) * ua, b.t0 + (b.t1 - b.t0) * ub
	m := (piece_at(&s.pieces[a.piece], ta) + piece_at(&s.pieces[b.piece], tb)) / 2
	ea := end_near({s.vfirst[a.v0], s.vfirst[a.v1]}, {s.vpos[a.v0], s.vpos[a.v1]}, m, eps)
	eb := end_near({s.vfirst[b.v0], s.vfirst[b.v1]}, {s.vpos[b.v0], s.vpos[b.v1]}, m, eps)
	switch {
	case ea != max(u32) && eb != max(u32):
		return unite(s.parent[:], ea, eb)
	case ea != max(u32):
		return cut_or_join(s, b.piece, tb, ea)
	case eb != max(u32):
		return cut_or_join(s, a.piece, ta, eb)
	case fresh:
		p := add_point(s, m, false)
		add_cut(s, a.piece, ta, p)
		add_cut(s, b.piece, tb, p)
		return true
	}
	return false
}

// Cuts piece pc at t through point p's vertex, unless the piece passes
// through that vertex already: then the stretch between there and t (within
// eps of it, as the piece is monotone) joins it. True when anything changed.
// (The piece's cuts are its span of the sorted cuts, as build_edges left
// them.)
@(private = "file")
cut_or_join :: proc(s: ^Bool_Scratch, pc: u32, t: f64, p: u32) -> bool {
	span := s.cuts[s.pstart[pc]:s.pstart[pc + 1]]
	for c in span {
		if s.vert[c.point] != s.vert[p] {
			continue
		}
		lo, hi := min(c.t, t), max(c.t, t)
		joined := false
		for d in span {
			if d.t >= lo && d.t <= hi {
				joined |= unite(s.parent[:], d.point, p)
			}
		}
		return joined
	}
	add_cut(s, pc, t, p)
	return true
}

@(private = "file")
merge_coincident :: proc(s: ^Bool_Scratch, k: int, eps, delta: f64, budget: ^int) -> Bool_Error {
	resize(&s.order, len(s.edges))
	resize(&s.keys, len(s.edges))
	for e, i in s.edges {
		s.order[i] = u32(i)
		s.keys[i] = u64(min(e.v0, e.v1)) << 32 | u64(max(e.v0, e.v1))
	}
	sort_keyed(s.keys[:], s.order[:], &s.tkeys, &s.torder)
	for i := 0; i < len(s.order); {
		j := i + 1
		for j < len(s.order) && s.keys[j] == s.keys[i] {
			j += 1
		}
		for a in i ..< j {
			ea := s.order[a]
			if !s.edges[ea].alive {
				continue
			}
			for b in a + 1 ..< j {
				eb := s.order[b]
				if !s.edges[eb].alive {
					continue
				}
				pa := Piece{p = s.ecurve[ea], t0 = 0, t1 = 1}
				pb := Piece{p = s.ecurve[eb], t0 = 0, t1 = 1}
				pa.line, pb.line = s.pieces[s.edges[ea].piece].line, s.pieces[s.edges[eb].piece].line
				clear(&s.runs)
				if !near_runs(&pa, &pb, 2 * eps, delta, &s.kernel, &s.runs, budget) {
					return .Limit
				}
				if len(s.runs) != 1 || s.runs[0].s0 > 0 || s.runs[0].s1 < 1 || s.runs[0].t0 > 0 || s.runs[0].t1 < 1 {
					continue
				}
				same := s.edges[ea].v0 == s.edges[eb].v0
				for o in 0 ..< k {
					d := s.edelta[int(eb) * k + o]
					s.edelta[int(ea) * k + o] += d if same else -d
				}
				s.edges[eb].alive = false
			}
		}
		i = j
	}
	for &e, i in s.edges {
		if e.alive {
			zero := true
			for d in s.edelta[i * k:][:k] {
				zero &&= d == 0
			}
			e.alive = !zero
			s.stats.edges += int(e.alive)
		}
	}
	return nil
}

// S6-S7: half-edges ordered around each vertex by the direction to their
// curve's point at a radius past the vertex's cluster, and the faces they
// bound (each on the left of its half-edges).
@(private = "file")
bool_faces :: proc(s: ^Bool_Scratch, k: int, eps: f64) {
	ne := len(s.edges)
	resize(&s.hdir, 2 * ne)
	resize(&s.vstart, len(s.vpos) + 1)
	slice.fill(s.vstart[:], 0)
	for e in s.edges {
		if e.alive {
			s.vstart[e.v0 + 1] += 1
			s.vstart[e.v1 + 1] += 1
		}
	}
	for v in 1 ..< len(s.vstart) {
		s.vstart[v] += s.vstart[v - 1]
	}
	resize(&s.vlist, int(s.vstart[len(s.vpos)]))
	resize(&s.counts, len(s.vpos))
	slice.fill(s.counts[:], 0)
	for e, i in s.edges {
		if !e.alive {
			continue
		}
		s.vlist[s.vstart[e.v0] + s.counts[e.v0]] = u32(2 * i)
		s.counts[e.v0] += 1
		s.vlist[s.vstart[e.v1] + s.counts[e.v1]] = u32(2 * i + 1)
		s.counts[e.v1] += 1
	}
	resize(&s.hpos, 2 * ne)
	for v in 0 ..< len(s.vpos) {
		out := s.vlist[s.vstart[v]:s.vstart[v + 1]]
		// One or two half-edges are in either order; more by direction,
		// sorted by insertion (a vertex has few).
		if len(out) > 2 {
			for h in out {
				e := s.edges[h >> 1]
				w := e.v0 if h & 1 == 0 else e.v1
				s.hdir[h] = edge_direction(s.ecurve[h >> 1], s.vpos[w], s.vrad[w] + 4 * eps, s.pieces[e.piece].line, h & 1 == 1)
			}
			before :: proc(d: [][2]f64, a, b: u32) -> bool {
				da, db := d[a], d[b]
				sa, sb := sector(da), sector(db)
				if sa != sb {
					return sa < sb
				}
				c := da.x * db.y - da.y * db.x
				return c > 0 || (c == 0 && a < b)
			}
			for i in 1 ..< len(out) {
				x := out[i]
				j := i
				for j > 0 && before(s.hdir[:], x, out[j - 1]) {
					out[j] = out[j - 1]
					j -= 1
				}
				out[j] = x
			}
			for i in 1 ..< len(out) {
				p, q := s.hdir[out[i - 1]], s.hdir[out[i]]
				if sector(p) == sector(q) && p.x * q.y - p.y * q.x == 0 {
					s.stats.ties += 1
				}
			}
		}
		for h, i in out {
			s.hpos[h] = u32(i)
		}
	}
	// next(h): at h's end, the outgoing half-edge just before h's twin
	// counterclockwise keeps h's face on the left.
	resize(&s.hnext, 2 * ne)
	for e, i in s.edges {
		if !e.alive {
			continue
		}
		for h in ([2]u32{u32(2 * i), u32(2 * i + 1)}) {
			twin := h ~ 1
			v := e.v1 if h & 1 == 0 else e.v0
			n := s.vstart[v + 1] - s.vstart[v]
			s.hnext[h] = s.vlist[s.vstart[v] + (s.hpos[twin] + n - 1) % n]
		}
	}
	resize(&s.hface, 2 * ne)
	slice.fill(s.hface[:], max(u32))
	clear(&s.fhalf)
	clear(&s.farea)
	for e, i in s.edges {
		if !e.alive {
			continue
		}
		for h0 in ([2]u32{u32(2 * i), u32(2 * i + 1)}) {
			if s.hface[h0] != max(u32) {
				continue
			}
			// next is a permutation of the live half-edges (a twin, then
			// a step around its vertex), so each walk closes on h0.
			f := u32(len(s.farea))
			area: f64
			h := h0
			for {
				s.hface[h] = f
				q := s.ecurve[h >> 1]
				area -= cubic_area(q) if h & 1 == 0 else cubic_area([4][2]f64{q[3], q[2], q[1], q[0]})
				h = s.hnext[h]
				if h == h0 {
					break
				}
			}
			append(&s.fhalf, h0)
			append(&s.farea, area)
		}
	}
	s.stats.faces = len(s.farea)
	resize(&s.fwind, len(s.farea) * k)
	resize(&s.inside, len(s.farea))
}

// The direction from a vertex to its edge's curve at distance r (past the
// vertex's cluster, so distinct edges are told apart by points eps apart);
// a line's is its chord, the segment it is emitted as.
@(private = "file")
edge_direction :: proc(q: [4][2]f64, v: [2]f64, radius: f64, line, from_end: bool) -> [2]f64 {
	if line {
		return q[0] - q[3] if from_end else q[3] - q[0]
	}
	c := [4][2]f64{q[3], q[2], q[1], q[0]} if from_end else q
	end := c[3] - v
	r := min(radius, math.sqrt(end.x * end.x + end.y * end.y) / 2)
	// The point at distance r: monotone pieces move away from their ends,
	// so |c(t) - v|^2 - r^2 rises from -r^2 at 0 to at least 3 r^2 at 1.
	// Newton steps from the first-order guess, kept in the bracket by
	// bisection, until it is r to 24 bits (r is a few eps, so rounding in
	// the coordinates leaves |c(t) - v| good to about 30; the angle moves
	// by far less than eps over r).
	d0 := cubic_tangent(c, 0)
	l0 := math.sqrt(d0.x * d0.x + d0.y * d0.y)
	lo, hi := 0.0, 1.0
	t := r / l0 if l0 > 0 else 0.5
	d: [2]f64
	for _ in 0 ..< 64 {
		if !(t > lo && t < hi) {
			t = (lo + hi) / 2
		}
		d = cubic_at(c, t) - v
		f := d.x * d.x + d.y * d.y - r * r
		if abs(f) <= r * r / (1 << 24) {
			break
		}
		if f < 0 {
			lo = t
		} else {
			hi = t
		}
		g := cubic_tangent(c, t)
		df := 2 * (d.x * g.x + d.y * g.y)
		t = t - f / df if df > 0 else (lo + hi) / 2
	}
	return d
}

// The direction's sector counterclockwise from +x: the four axes and the
// four open quadrants between them.
@(private = "file")
sector :: proc "contextless" (d: [2]f64) -> int {
	switch {
	case d.y == 0 && d.x > 0:
		return 0
	case d.x > 0 && d.y > 0:
		return 1
	case d.x == 0 && d.y > 0:
		return 2
	case d.x < 0 && d.y > 0:
		return 3
	case d.y == 0 && d.x < 0:
		return 4
	case d.x < 0 && d.y < 0:
		return 5
	case d.x == 0 && d.y < 0:
		return 6
	}
	return 7
}

// The winding of each face per operand: each component's outer face (the
// one with negative area) from the other components' edges at its leftmost
// vertex, then across edges (the face left of an edge winds its delta more
// than the face right of it).
@(private = "file")
bool_windings :: proc(s: ^Bool_Scratch, k: int, eps: f64) -> Bool_Error {
	// Components of vertices joined by live edges.
	resize(&s.comp, len(s.vpos))
	for &c, i in s.comp {
		c = u32(i)
	}
	for e in s.edges {
		if e.alive {
			unite(s.comp[:], e.v0, e.v1)
		}
	}
	// Per component: its leftmost vertex.
	resize(&s.cleft, len(s.vpos))
	slice.fill(s.cleft[:], max(u32))
	for p, v in s.vpos {
		r := find(s.comp[:], u32(v))
		l := s.cleft[r]
		if l == max(u32) || p.x < s.vpos[l].x || (p.x == s.vpos[l].x && p.y < s.vpos[l].y) {
			s.cleft[r] = u32(v)
		}
	}
	resize(&s.fdone, len(s.farea))
	slice.fill(s.fdone[:], false)
	slice.fill(s.fwind[:], 0)
	// Per component: its outer face.
	for e, i in s.edges {
		if !e.alive {
			continue
		}
		for h0 in ([2]u32{u32(2 * i), u32(2 * i + 1)}) {
			f := s.hface[h0]
			if s.fdone[f] || s.farea[f] >= 0 {
				continue
			}
			root := find(s.comp[:], e.v0)
			q := s.vpos[s.cleft[root]]
			w := s.fwind[int(f) * k:][:k]
			for e2, j in s.edges {
				// An edge whose box lies above, below or left of q can't
				// cross the ray (curve_winding's own first test).
				lo, hi := box_of(s.ecurve[j])
				if !e2.alive || q.y < lo.y || q.y > hi.y || hi.x < q.x || find(s.comp[:], e2.v0) == root {
					continue
				}
				cw, on := curve_winding(s.ecurve[j], q, eps / 64, &s.stack)
				if on {
					return .Inconsistent
				}
				if cw != 0 {
					for o in 0 ..< k {
						w[o] += cw * s.edelta[j * k + o]
					}
				}
			}
			// The outer face, then every face reachable across edges.
			s.fdone[f] = true
			clear(&s.queue)
			append(&s.queue, f)
			for len(s.queue) > 0 {
				g := pop(&s.queue)
				x := s.fhalf[g]
				for {
					// Crossing from the right of h (g) to its left.
					h := x ~ 1
					if to := s.hface[h]; !s.fdone[to] {
						j := int(h >> 1)
						sign: i32 = 1 if h & 1 == 0 else -1
						for o in 0 ..< k {
							s.fwind[int(to) * k + o] = s.fwind[int(g) * k + o] + sign * s.edelta[j * k + o]
						}
						s.fdone[to] = true
						append(&s.queue, to)
					}
					x = s.hnext[x]
					if x == s.fhalf[g] {
						break
					}
				}
			}
		}
	}
	for d in s.fdone {
		if !d {
			return .Inconsistent
		}
	}
	return nil
}

// S8: the half-edges with a kept face on their right and a dropped one on
// their left, traced into contours (so outer contours wind Solid and holes
// the other way); consecutive pieces of one source segment through
// vertices of two kept edges join back into one range of it, and a range
// covering its whole segment copies the source points.
@(private = "file")
bool_emit :: proc(s: ^Bool_Scratch) {
	ne := len(s.edges)
	resize(&s.keep, 2 * ne)
	resize(&s.used, 2 * ne)
	slice.fill(s.keep[:], false)
	slice.fill(s.used[:], false)
	resize(&s.counts, len(s.vpos))
	slice.fill(s.counts[:], 0)
	kept_out := s.counts[:]
	for e, i in s.edges {
		if !e.alive {
			continue
		}
		for h in ([2]u32{u32(2 * i), u32(2 * i + 1)}) {
			if s.inside[s.hface[h ~ 1]] && !s.inside[s.hface[h]] {
				s.keep[h] = true
				kept_out[e.v0 if h & 1 == 0 else e.v1] += 1
			}
		}
	}
	for h0 in 0 ..< 2 * ne {
		if !s.keep[h0] || s.used[h0] {
			continue
		}
		// Trace: at each vertex the next kept half-edge counterclockwise
		// after the twin keeps the kept face on the right.
		begin := true
		run_row := max(u32)
		run_t0, run_t1: f64
		run_v0: u32
		h := u32(h0)
		for {
			s.used[h] = true
			e := s.edges[h >> 1]
			p := &s.pieces[e.piece]
			// The piece's range in its source segment's t, in travel order.
			ta, tb := source_t(p, e.t0), source_t(p, e.t1)
			v0, v1 := e.v0, e.v1
			if h & 1 == 1 {
				ta, tb, v0, v1 = tb, ta, v1, v0
			}
			if begin {
				contours_begin(&s.out, s.vout[v0])
				begin = false
				run_row, run_t0, run_t1, run_v0 = p.row, ta, tb, v0
			} else if p.row == run_row && ta == run_t1 && kept_out[v0] == 1 && (tb > ta) == (run_t1 > run_t0) {
				run_t1 = tb
			} else {
				emit_range(s, run_row, run_t0, run_t1, run_v0, v0)
				run_row, run_t0, run_t1, run_v0 = p.row, ta, tb, v0
			}
			// Next.
			n := s.vstart[v1 + 1] - s.vstart[v1]
			at := s.hpos[h ~ 1]
			next := max(u32)
			for step in 1 ..= n {
				c := s.vlist[s.vstart[v1] + (at + step) % n]
				if s.keep[c] && !s.used[c] {
					next = c
					break
				}
			}
			if next == max(u32) {
				emit_range(s, run_row, run_t0, run_t1, run_v0, v1)
				break
			}
			h = next
		}
		contours_end(&s.out, true, false)
	}
}

// A piece parameter in its source segment's t; the piece's ends exactly.
@(private = "file")
source_t :: #force_inline proc "contextless" (p: ^Piece, t: f64) -> f64 {
	return p.t0 if t == 0 else p.t1 if t == 1 else p.t0 + (p.t1 - p.t0) * t
}

// Appends source row `row`'s range [t0, t1] (reversed when t0 > t1) from
// vertex a to vertex b to the open contour, with where it came from.
@(private = "file")
emit_range :: proc(s: ^Bool_Scratch, row: u32, t0, t1: f64, a, b: u32) {
	r := &s.rows[row]
	kind: Seg_Kind = .Line if r.line else .Cubic
	pa, pb := s.vout[a], s.vout[b]
	q: [4]Vec2
	switch {
	case t0 == 0 && t1 == 1 && pa == r.src[0] && pb == r.src[3]:
		q = r.src
	case t0 == 1 && t1 == 0 && pa == r.src[3] && pb == r.src[0]:
		q = {r.src[3], r.src[2], r.src[1], r.src[0]}
	case r.line:
		q = {pa, pa + (pb - pa) / 3, pa + (pb - pa) * (2.0 / 3), pb}
	case:
		c := cubic_range(r.p, t0, t1)
		da := [2]f64{f64(pa.x), f64(pa.y)} - c[0]
		db := [2]f64{f64(pb.x), f64(pb.y)} - c[3]
		c1, c2 := c[1] + da, c[2] + db
		q = {pa, {f32(c1.x), f32(c1.y)}, {f32(c2.x), f32(c2.y)}, pb}
	}
	contours_segment(&s.out, kind, q[1], q[2], q[3])
	append(&s.out_row, r.row)
	append(&s.out_t, [2]f32{f32(t0), f32(t1)})
}
