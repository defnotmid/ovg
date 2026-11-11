package ovg

import "base:runtime"
import "core:math"
import "core:mem"
import "core:sync"

import cv "deps:ocurves"
import ft "deps:oglyph/font"

// Shapes drawn by per-pixel coverage: ovg's handle on ocurves' curves
// package (its curves.odin: the word layout, the coverage and winding
// functions; its curves.glsl is their GPU twin). A `Shape` owns its
// words; it is built once (from a path, a stroke or a glyph) by whatever
// owns it and drawn under any transform with `fill_shape`.

Shape :: struct {
	data:      []u32,
	// A slot and its generation, `gen << 32 | slot`, never 0: GPU backends
	// find their copy of the shape by it, uploading it when they have none.
	// shape_destroy frees the slot for a later shape under a new
	// generation, so an id names one shape and the slots stay as many as
	// the shapes alive at once (shape_id_slots).
	id:        u64,
	// Shape units to the units the shape was built in (path units, or font
	// units with y down): `p = origin + q * extent`.
	origin:    Vec2,
	extent:    f32,
	// In shape units, as the words' header holds them: drawing reads them
	// here, beside the transform, not from the words.
	bounds:    Bounds,
	allocator: mem.Allocator,
	// Coarser copies of its curves, for drawing it much smaller than its
	// detail (shape_level): blocks of `data` after its own words, coarser
	// down the list.
	levels:      [len(SHAPE_LEVEL_ERRORS)]Shape_Level,
	level_count: int,
}

// A coarser copy of a shape's curves: where its words start in
// Shape.data, and how far, in shape units, it may lie from the shape.
Shape_Level :: struct {
	at:  u32,
	err: f32,
}

// The errors coarse levels are made at, in shape units (the shape spans
// 1 across), finest first. A level is kept when it has at most a quarter
// of the curves of the last one kept (the shape's own at first), so a
// shape's levels hold at most a third more words than it does, and a
// shape whose curves don't thin out keeps none.
SHAPE_LEVEL_ERRORS :: [3]f32{1.0 / 1024, 1.0 / 128, 1.0 / 16}

// How far, in pixels, a level drawn may lie from its shape: below a
// pixel's coverage step at an edge, so neighbouring shapes stay joined
// within what their antialiased edges already leave.
SHAPE_LEVEL_PIXELS :: 0.125

// The words `s` draws under `t` (its words to drawing coordinates): its
// coarsest level whose error, stretched as far as `t` stretches any
// direction, stays within SHAPE_LEVEL_PIXELS, else its own; as a range of
// `data`, and the level's number (0 for its own words).
shape_level :: proc "contextless" (s: ^Shape, t: Transform2D) -> (lo, hi: u32, level: int) {
	hi = s.levels[0].at if s.level_count > 0 else u32(len(s.data))
	stretch := transform_max_stretch(t)
	for k := s.level_count - 1; k >= 0; k -= 1 {
		if s.levels[k].err * stretch <= SHAPE_LEVEL_PIXELS {
			lo = s.levels[k].at
			hi = s.levels[k + 1].at if k + 1 < s.level_count else u32(len(s.data))
			return lo, hi, k + 1
		}
	}
	return 0, hi, 0
}

// The most `t` stretches a length in any direction: its linear part's
// largest singular value.
@(private)
transform_max_stretch :: proc "contextless" (t: Transform2D) -> f32 {
	a, b, c, d := t[0], t[1], t[2], t[3]
	h := (a * a + b * b + c * c + d * d) * 0.5
	det := a * d - b * c
	return math.sqrt(h + math.sqrt(max(h * h - det * det, 0)))
}

shape_destroy :: proc(s: ^Shape) {
	delete(s.data, s.allocator)
	shape_id_free(s.id)
	s^ = {}
}

// The id slots: each one's generation and the free ones, shared by every
// thread building and destroying shapes. Its arrays are on the heap
// allocator, for the process's life.
@(private = "file")
Shape_Ids :: struct {
	lock:  sync.Mutex,
	gens:  [dynamic]u32,
	free:  [dynamic]u32,
	// len(gens), for shape_id_slots to read without the lock.
	slots: int,
}

@(private = "file")
shape_ids: Shape_Ids

@(private = "file")
shape_id_new :: proc() -> u64 {
	ids := &shape_ids
	sync.mutex_lock(&ids.lock)
	defer sync.mutex_unlock(&ids.lock)
	if ids.gens.allocator.procedure == nil {
		ids.gens.allocator = runtime.heap_allocator()
		ids.free.allocator = runtime.heap_allocator()
	}
	slot: u32
	if n := len(ids.free); n > 0 {
		slot = ids.free[n - 1]
		resize(&ids.free, n - 1)
	} else {
		slot = u32(len(ids.gens))
		append(&ids.gens, 1)
		sync.atomic_store(&ids.slots, len(ids.gens))
	}
	return u64(ids.gens[slot]) << 32 | u64(slot)
}

// Frees `id`'s slot for a later shape, under the next generation (never 0).
@(private = "file")
shape_id_free :: proc(id: u64) {
	if id == 0 {
		return
	}
	ids := &shape_ids
	sync.mutex_lock(&ids.lock)
	defer sync.mutex_unlock(&ids.lock)
	slot := u32(id)
	ids.gens[slot] += 1
	if ids.gens[slot] == 0 {
		ids.gens[slot] = 1
	}
	append(&ids.free, slot)
}

// How many id slots there are: every live shape's id has `u32(id)` below
// it, so a backend can keep a table by slot of that length.
shape_id_slots :: proc "contextless" () -> int {
	return sync.atomic_load(&shape_ids.slots)
}

// Shape units to the shape's source units.
shape_local :: proc "contextless" (s: ^Shape) -> Transform2D {
	return {s.extent, 0, 0, s.extent, s.origin.x, s.origin.y}
}

// Bounds in shape units.
shape_bounds :: proc "contextless" (s: ^Shape) -> (minx, miny, maxx, maxy: f32) {
	return s.bounds.minx, s.bounds.miny, s.bounds.maxx, s.bounds.maxy
}

// ---- building -------------------------------------------------------------------

Shape_Curve :: cv.Curve
Shape_Builder :: cv.Builder

shape_builder_destroy :: cv.builder_destroy
shape_builder_reset :: cv.builder_reset
shape_move_to :: cv.move_to
shape_line_to :: cv.line_to
shape_quad_to :: cv.quad_to
shape_cubic_to :: cv.cubic_to
shape_close :: cv.close

// Winds the current contour as `.Solid` (positive area, y down) or
// `.Hole`, reversing it if needed, as fill_path does (path_solidity).
shape_solidity :: proc(b: ^Shape_Builder, s: Solidity) {
	switch s {
	case .Solid:
		cv.orient(b, .Solid)
	case .Hole:
		cv.orient(b, .Hole)
	case .None:
	}
}

// Adds a path's contours under `t`. Every contour is closed, as filling
// does (with `b.outline`, one the path leaves open stays open in the
// outline).
shape_add_path :: proc(b: ^Shape_Builder, p: ^Path, t := TRANSFORM_IDENTITY) {
	at :: proc(t: Transform2D, p: Vec2) -> Vec2 {
		return transform_point(t, p.x, p.y)
	}
	for ct, ci in p.contours {
		shape_move_to(b, at(t, p.pts[ct.start]))
		it := cv.contour_segments(p, ci)
		for s in cv.segments_next(&it) {
			if s.kind == .Line {
				shape_line_to(b, at(t, s.p[3]))
			} else {
				shape_cubic_to(b, at(t, s.p[1]), at(t, s.p[2]), at(t, s.p[3]))
			}
		}
		if ct.closed || !b.outline {
			shape_close(b)
		} else {
			cv.end_open(b)
		}
	}
}

// Adds a glyph's outline in font units, y down (the pen at the origin),
// reading it into `o`; false when it has none.
shape_add_glyph :: proc(b: ^Shape_Builder, f: ^Font, g: Glyph_Index, o: ^ft.Outline) -> bool {
	if !ft.glyph_outline(&f.face, ft.Glyph(g), o) {
		return false
	}
	i := 0
	for v in o.verbs {
		p := o.points[i:]
		switch v {
		case .Move:
			shape_move_to(b, {p[0].x, -p[0].y})
			i += 1
		case .Line:
			shape_line_to(b, {p[0].x, -p[0].y})
			i += 1
		case .Quad:
			shape_quad_to(b, {p[0].x, -p[0].y}, {p[1].x, -p[1].y})
			i += 2
		case .Cubic:
			shape_cubic_to(b, {p[0].x, -p[0].y}, {p[1].x, -p[1].y}, {p[2].x, -p[2].y})
			i += 3
		}
	}
	shape_close(b)
	return true
}

// Builds the shape from the builder's curves; false (and no shape) when
// there are none. `search` sizes the grid for the fastest drawing
// (cv.build); with `b.outline` (set before adding curves) it also draws as
// a hairline (`hairline_shape`).
shape_build :: proc(b: ^Shape_Builder, allocator := context.allocator, search := true, levels: ^Level_Scratch = nil) -> (s: Shape, ok: bool) {
	out := make([dynamic]u32, allocator)
	origin, extent, built := cv.build_append(b, &out, search)
	if !built {
		delete(out)
		return
	}
	own := len(out)
	shape_add_levels(b, &out, origin, extent, &s, levels)
	// The levels' appends grew it geometrically: keep only the words.
	if cap(out) > len(out) {
		shrink(&out)
	}
	s.data, s.origin, s.extent, s.allocator, s.id = out[:], origin, extent, allocator, shape_id_new()
	s.bounds = words_bounds(s.data[:own])
	return s, true
}

// ---- levels ----------------------------------------------------------------------

// What making a shape's levels works in, kept by a caller that builds
// many (Shape_Scratch): the shape's contours after the linear pass (their
// curves, each contour a range of them; per end, a curve's start and each
// contour's last, the least deviation of the splits keeping it, infinite
// for pinned ends; which curves the outline skips), and the builder a
// level is built from.
@(private)
Level_Scratch :: struct {
	curves:   [dynamic]cv.Curve,
	sig:      [dynamic]f32,
	hidden:   [dynamic]bool,
	contours: [dynamic][2]int,
	builder:  Shape_Builder,
}

@(private)
level_scratch_init :: proc(ls: ^Level_Scratch, allocator: mem.Allocator) {
	ls^ = {}
	ls.curves.allocator, ls.sig.allocator, ls.hidden.allocator, ls.contours.allocator = allocator, allocator, allocator, allocator
	ls.builder.curves.allocator = allocator
}

@(private)
level_scratch_destroy :: proc(ls: ^Level_Scratch) {
	delete(ls.curves)
	delete(ls.sig)
	delete(ls.hidden)
	delete(ls.contours)
	shape_builder_destroy(&ls.builder)
	ls^ = {}
}

// Appends the shape's levels to `out` (SHAPE_LEVEL_ERRORS). Each contour
// is simplified between pinned points (its start, its extreme points and
// the ends of curves closing contours left open, which its outline skips):
// first a linear pass merges each run of curves lying within a quarter of
// the finest error of where it starts into one line; then the farthest-
// point split (Ramer-Douglas-Peucker) over the curves' ends and control
// points runs once, giving each end the least deviation of the splits down
// to it, so a level keeps the ends past what is left of its error (the
// same ends as a split run at that error). A level is built in the shape's
// frame, without grid search (it is only drawn small), when it keeps at
// most a quarter of the curves of the last level kept.
@(private = "file")
shape_add_levels :: proc(b: ^Shape_Builder, out: ^[dynamic]u32, origin: Vec2, extent: f32, s: ^Shape, scratch: ^Level_Scratch) {
	// A contour keeps at least 3 curves, so under 12 no level cuts them 4 times.
	if len(b.curves) < 12 {
		return
	}
	temp: Level_Scratch
	ls := scratch
	if ls == nil {
		level_scratch_init(&temp, runtime.heap_allocator())
		ls = &temp
	}
	defer if scratch == nil {
		level_scratch_destroy(&temp)
	}
	errors := SHAPE_LEVEL_ERRORS
	pre := errors[0] * extent / 4
	level_split_all(ls, b.curves[:], b.unstroked[:], pre, errors[0] * extent - pre)
	kept := len(b.curves)
	for err in errors {
		tol := err * extent - pre
		// The curves it would have: each contour's ends kept past its start.
		n, base := 0, 0
		for c in ls.contours {
			for k in 1 ..= c[1] - c[0] {
				n += 1 if ls.sig[base + k] > tol else 0
			}
			base += c[1] - c[0] + 1
		}
		if 4 * n > kept {
			continue
		}
		cb := &ls.builder
		shape_builder_reset(cb)
		cb.outline = b.outline
		level_emit(ls, tol, cb)
		at := len(out)
		if _, _, ok := cv.build_append(cb, out, false, cv.Frame{origin, extent}); !ok {
			resize(out, at)
			continue
		}
		s.levels[s.level_count] = {u32(at), err}
		s.level_count += 1
		kept = n
		if kept < 12 {
			break
		}
	}
}

// The linear pass and the split, contour by contour, into `ls`. A contour
// is the curves from one whose start the builder's curves reach again
// (every contour ends where it starts).
@(private = "file")
level_split_all :: proc(ls: ^Level_Scratch, curves: []cv.Curve, unstroked: []u32, pre, floor: f32) {
	clear(&ls.curves)
	clear(&ls.sig)
	clear(&ls.hidden)
	clear(&ls.contours)
	q2 := pre * pre
	near :: #force_inline proc "contextless" (p, o: Vec2, q2: f32) -> bool {
		d := p - o
		return d.x * d.x + d.y * d.y <= q2
	}
	// The contour's next curve its outline skips, as an index into it (-1: none).
	next_hidden :: proc "contextless" (unstroked: []u32, u: ^int, i, n: int) -> int {
		for u^ < len(unstroked) && int(unstroked[u^]) < i {
			u^ += 1
		}
		return int(unstroked[u^]) - i if u^ < len(unstroked) && int(unstroked[u^]) < i + n else -1
	}
	u := 0
	for i := 0; i < len(curves); {
		start := curves[i].p1
		j := i
		for j < len(curves) - 1 && curves[j].p3 != start {
			j += 1
		}
		contour := curves[i:j + 1]
		n := len(contour)
		lo, hi: [2]int
		for k in 0 ..< n {
			p := contour[k].p1
			for a in 0 ..< 2 {
				if p[a] < contour[lo[a]].p1[a] {
					lo[a] = k
				}
				if p[a] > contour[hi[a]].p1[a] {
					hi[a] = k
				}
			}
		}
		extreme :: #force_inline proc "contextless" (k: int, lo, hi: [2]int) -> bool {
			return k == lo[0] || k == lo[1] || k == hi[0] || k == hi[1]
		}
		hide := next_hidden(unstroked, &u, i, n)
		first, base := len(ls.curves), len(ls.sig)
		append(&ls.sig, math.INF_F32)
		for k := 0; k < n; {
			o := contour[k].p1
			m := k
			for m < n && m != hide && near(contour[m].p2, o, q2) && near(contour[m].p3, o, q2) {
				m += 1
				if m == n || extreme(m, lo, hi) || m == hide {
					break
				}
			}
			hidden := false
			if m - k >= 2 {
				end := contour[m - 1].p3
				append(&ls.curves, cv.Curve{o, (o + end) * 0.5, end})
				k = m
			} else {
				append(&ls.curves, contour[k])
				hidden = k == hide
				k += 1
				if hidden {
					u += 1
					hide = next_hidden(unstroked, &u, i, n)
				}
			}
			append(&ls.hidden, hidden)
			// The end reached: pinned, or its deviation set by the split.
			pinned := k == n || extreme(k, lo, hi) || hidden || k == hide
			append(&ls.sig, math.INF_F32 if pinned else -1)
		}
		last := len(ls.curves)
		append(&ls.contours, [2]int{first, last})
		a := 0
		for k in 1 ..= last - first {
			if ls.sig[base + k] == math.INF_F32 {
				level_split(ls.curves[first:last], ls.sig[base:][:last - first + 1], a, k, math.INF_F32, floor)
				a = k
			}
		}
		i = j + 1
	}
}

// Gives the ends strictly inside the chain of curves `a ..< b` the least
// deviation of the splits down to them (`parent`: the chain's): its
// farthest end splits it, its deviation the most of any end or control
// point from the chord. A chain within `floor` (the finest level's) is
// left: no level keeps an end inside it.
@(private = "file")
level_split :: proc(curves: []cv.Curve, sig: []f32, a, b: int, parent, floor: f32) {
	if b <= a + 1 {
		return
	}
	pa, pd := curves[a].p1, curves[b - 1].p3 - curves[a].p1
	pl := pd.x * pd.x + pd.y * pd.y
	inv := 1 / pl if pl > 0 else 0
	// Squared distance from the chord.
	dist :: #force_inline proc "contextless" (p, a, d: Vec2, inv: f32) -> f32 {
		q := a + d * clamp(((p.x - a.x) * d.x + (p.y - a.y) * d.y) * inv, 0, 1) - p
		return q.x * q.x + q.y * q.y
	}
	far, efar := f32(0), f32(-1)
	kfar := a + 1
	for c, k in curves[a:b] {
		// A line's control point is its midpoint, no farther than its ends.
		if c.p2 != (c.p1 + c.p3) * 0.5 {
			far = max(far, dist(c.p2, pa, pd, inv))
		}
		if k > 0 {
			if d := dist(c.p1, pa, pd, inv); d > efar {
				efar, kfar = d, a + k
			}
		}
	}
	far = max(far, efar)
	if far <= floor * floor {
		return
	}
	s := min(math.sqrt(far), parent)
	sig[kfar] = s
	level_split(curves, sig, a, kfar, s, floor)
	level_split(curves, sig, kfar, b, s, floor)
}

// Builds the contours keeping the ends past `tol`: a kept curve as it is
// (its chord when its control point lies within `tol`), the curves
// between kept ends as one line.
@(private = "file")
level_emit :: proc(ls: ^Level_Scratch, tol: f32, cb: ^Shape_Builder) {
	tol2 := tol * tol
	base := 0
	for c in ls.contours {
		curves := ls.curves[c[0]:c[1]]
		sig := ls.sig[base:][:len(curves) + 1]
		hidden := ls.hidden[c[0]:c[1]]
		base += len(curves) + 1
		cv.move_to(cb, curves[0].p1)
		a := 0
		for k in 1 ..= len(curves) {
			if sig[k] <= tol {
				continue
			}
			if k > a + 1 {
				cv.line_to(cb, curves[k - 1].p3)
			} else {
				cc := curves[a]
				d := cc.p3 - cc.p1
				l := d.x * d.x + d.y * d.y
				e := cc.p1 + d * (clamp(((cc.p2.x - cc.p1.x) * d.x + (cc.p2.y - cc.p1.y) * d.y) / l, 0, 1) if l > 0 else 0) - cc.p2
				if !hidden[a] && e.x * e.x + e.y * e.y <= tol2 {
					cv.line_to(cb, cc.p3)
				} else {
					cv.quad_to(cb, cc.p2, cc.p3)
				}
				if hidden[a] {
					append(&cb.unstroked, u32(len(cb.curves) - 1))
				}
			}
			a = k
		}
		cv.close(cb)
	}
}

// What building shapes needs, kept by a caller that builds many (it only
// grows, and a warm one allocates nothing); without one a build makes its
// own on the heap and frees it after, so building shapes one by one, with
// any temp allocator, leaves nothing behind.
Shape_Scratch :: struct {
	builder: Shape_Builder,
	// Strokes: the outline's segments, the dashed path (and the measure of
	// the path it dashes), the dots of zero-length subpaths' caps.
	segs:    [dynamic]Stroke_Seg,
	dashed:  Path,
	flat:    Flat_Path,
	dots:    Path,
	// Hit tests: the path under the transform.
	hit:     Path,
	// Shapes' coarse levels.
	levels:  Level_Scratch,
}

// A scratch allocating from `allocator`.
shape_scratch_init :: proc(s: ^Shape_Scratch, allocator := context.allocator) {
	s^ = {}
	s.builder.curves.allocator = allocator
	s.segs.allocator = allocator
	path_init(&s.dashed, allocator)
	path_init(&s.dots, allocator)
	flat_path_init(&s.flat, allocator)
	cv.contours_init(&s.hit, allocator)
	level_scratch_init(&s.levels, allocator)
}

shape_scratch_destroy :: proc(s: ^Shape_Scratch) {
	shape_builder_destroy(&s.builder)
	delete(s.segs)
	path_destroy(&s.dashed)
	flat_path_destroy(&s.flat)
	path_destroy(&s.dots)
	cv.contours_destroy(&s.hit)
	level_scratch_destroy(&s.levels)
	s^ = {}
}

// Builds a path's shape, its cubics within `tol` path units (0: each within
// 1/4096 of its size; a shape drawn magnified wants the pixel fraction it
// may miss by at its largest scale). With `outline` it also draws as the
// path's hairline (`hairline_shape`).
shape_from_path :: proc(p: ^Path, allocator := context.allocator, search := true, scratch: ^Shape_Scratch = nil, tol: f32 = 0, outline := false) -> (Shape, bool) {
	temp: Shape_Scratch
	sc := scratch
	if sc == nil {
		shape_scratch_init(&temp, runtime.heap_allocator())
		sc = &temp
	}
	defer if scratch == nil {
		shape_scratch_destroy(&temp)
	}
	shape_builder_reset(&sc.builder)
	sc.builder.tol = tol
	sc.builder.outline = outline
	shape_add_path(&sc.builder, p)
	return shape_build(&sc.builder, allocator, search, &sc.levels)
}

// Builds the shape of `p`'s stroke with `s` (stroke.odin), within `tol`
// path units (0: 1/4096 of its size, as shape_from_path); false (and no
// shape) when it covers nothing.
// `complete` is false when the dashes ran past `max_dashes` (the stroke is
// then undashed).
shape_from_stroke :: proc(p: ^Path, s: Stroke_Settings, allocator := context.allocator, search := true, max_dashes := DEFAULT_LIMITS[.Dash_Segments], scratch: ^Shape_Scratch = nil, tol: f32 = 0) -> (shape: Shape, ok, complete: bool) {
	temp: Shape_Scratch
	sc := scratch
	if sc == nil {
		shape_scratch_init(&temp, runtime.heap_allocator())
		sc = &temp
	}
	defer if scratch == nil {
		shape_scratch_destroy(&temp)
	}
	shape_builder_reset(&sc.builder)
	sc.builder.tol = 0
	lo, hi := Vec2{max(f32), max(f32)}, Vec2{min(f32), min(f32)}
	for q in p.pts {
		lo, hi = {min(lo.x, q.x), min(lo.y, q.y)}, {max(hi.x, q.x), max(hi.y, q.y)}
	}
	tol := tol
	if tol <= 0 {
		tol = max(hi.x - lo.x, hi.y - lo.y, s.line_width) / 4096
	}
	complete = stroke_add(sc, p, TRANSFORM_IDENTITY, s, tol, max_dashes)
	shape, ok = shape_build(&sc.builder, allocator, search, &sc.levels)
	return
}

// Builds a glyph's shape (font units, y down, the pen at the origin);
// false for glyphs without an outline. With `outline` it also draws as the
// glyph's contours (hairline_shape). `builder` is kept by a caller that
// builds many; without one a build makes its own on the heap and frees it
// after.
shape_from_glyph :: proc(f: ^Font, g: Glyph_Index, o: ^ft.Outline, allocator := context.allocator, builder: ^Shape_Builder = nil, outline := false) -> (Shape, bool) {
	temp: Shape_Builder
	b := builder
	if b == nil {
		temp.curves.allocator = runtime.heap_allocator()
		b = &temp
	}
	defer if builder == nil {
		shape_builder_destroy(&temp)
	}
	shape_builder_reset(b)
	b.outline = outline
	if !shape_add_glyph(b, f, g, o) {
		return {}, false
	}
	return shape_build(b, allocator)
}

// ---- coverage ----------------------------------------------------------------------

// Exact coverage of the pixel centered at `rc` (shape units) whose sides
// are `u` and `v` in shape units (`shape_footprint`); `s` is a shape's
// words. See cv.coverage_affine.
shape_coverage :: cv.coverage_affine

// A pixel's sides in shape units under `t` (shape units to device pixels):
// its footprint, a parallelogram (cv.coverage_affine).
shape_footprint :: proc "contextless" (t: Transform2D) -> (u, v: Vec2) {
	inv := transform_inverse(t)
	return {inv[0], inv[1]}, {inv[2], inv[3]}
}

// Shape units spanned by one pixel along each axis under `t` (shape units
// to device pixels): what `fwidth` of the shape coordinate gives a shader
// (cv.footprint_of the inverse's Jacobian).
shape_ems_per_pixel :: proc "contextless" (t: Transform2D) -> Vec2 {
	inv := transform_inverse(t)
	return cv.footprint_of(matrix[2, 2]f32{inv[0], inv[2], inv[1], inv[3]})
}
