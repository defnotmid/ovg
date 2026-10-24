package ovg

import "core:mem"
import "core:sync"

import cv "curves"
import ft "font"

// Shapes drawn by per-pixel coverage: ovg's handle on the curves package
// (curves/curves.odin: the word layout, the coverage and winding
// functions; shaders/curves.slang is its GPU twin). A `Shape` owns its
// words; it is built once (from a path, a stroke or a glyph) by whatever
// owns it and drawn under any transform with `fill_shape`.

Shape :: struct {
	data:      []u32,
	// Unique for the process's life (never reused): GPU backends find
	// their copy of the shape by it, uploading it when they have none.
	id:        u64,
	// Shape units to the units the shape was built in (path units, or font
	// units with y down): `p = origin + q * extent`.
	origin:    Vec2,
	extent:    f32,
	allocator: mem.Allocator,
}

shape_destroy :: proc(s: ^Shape) {
	delete(s.data, s.allocator)
	s^ = {}
}

@(private = "file")
shape_next_id: u64

// Shape units to the shape's source units.
shape_local :: proc "contextless" (s: ^Shape) -> Transform2D {
	return {s.extent, 0, 0, s.extent, s.origin.x, s.origin.y}
}

// Bounds in shape units.
shape_bounds :: proc "contextless" (s: ^Shape) -> (minx, miny, maxx, maxy: f32) {
	return cv.bounds(s.data)
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
// does; segments before the first move go nowhere, and a segment after a
// close starts a contour where the closed one started.
shape_add_path :: proc(b: ^Shape_Builder, p: ^Path, t := TRANSFORM_IDENTITY) {
	at :: proc(t: Transform2D, p: Vec2) -> Vec2 {
		return transform_point(t, p.x, p.y)
	}
	it := path_events(p)
	for e in path_events_next(&it) {
		switch e.kind {
		case .Begin:
			shape_move_to(b, at(t, e.p[0]))
		case .Line:
			shape_line_to(b, at(t, e.p[1]))
		case .Cubic:
			shape_cubic_to(b, at(t, e.p[1]), at(t, e.p[2]), at(t, e.p[3]))
		case .Close:
			shape_close(b)
		case .Solid:
			shape_solidity(b, .Solid)
		case .Hole:
			shape_solidity(b, .Hole)
		}
	}
	shape_close(b)
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
// (cv.build).
shape_build :: proc(b: ^Shape_Builder, allocator := context.allocator, search := true) -> (s: Shape, ok: bool) {
	words, origin, extent := cv.build(b, allocator, search) or_return
	return {data = words, origin = origin, extent = extent, allocator = allocator, id = sync.atomic_add(&shape_next_id, 1) + 1}, true
}

// What building shapes needs, kept by a caller that builds many (it only
// grows); without one a build takes it from the context's temp allocator.
Shape_Scratch :: struct {
	builder: Shape_Builder,
	// Strokes: the outline's segments, the dashed path (and the measure of
	// the path it dashes), the dots of zero-length subpaths' caps.
	segs:    [dynamic]Stroke_Seg,
	dashed:  Path,
	flat:    Flat_Path,
	dots:    Path,
	// Hit tests: the path as contours, and the winding's cells.
	hit:     cv.Contours,
	stack:   [dynamic][2]f64,
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
	s.stack.allocator = allocator
}

shape_scratch_destroy :: proc(s: ^Shape_Scratch) {
	shape_builder_destroy(&s.builder)
	delete(s.segs)
	path_destroy(&s.dashed)
	flat_path_destroy(&s.flat)
	path_destroy(&s.dots)
	cv.contours_destroy(&s.hit)
	delete(s.stack)
	s^ = {}
}

// Builds a path's shape.
shape_from_path :: proc(p: ^Path, allocator := context.allocator, search := true, scratch: ^Shape_Scratch = nil) -> (Shape, bool) {
	temp: Shape_Scratch
	sc := scratch
	if sc == nil {
		shape_scratch_init(&temp, context.temp_allocator)
		sc = &temp
	}
	shape_builder_reset(&sc.builder)
	sc.builder.tol = 0
	shape_add_path(&sc.builder, p)
	return shape_build(&sc.builder, allocator, search)
}

// Builds the shape of `p`'s stroke with `s` (stroke.odin), in path units
// within 1/4096 of its size; false (and no shape) when it covers nothing.
// `complete` is false when the dashes ran past `max_dashes` (the stroke is
// then undashed).
shape_from_stroke :: proc(p: ^Path, s: Stroke_Settings, allocator := context.allocator, search := true, max_dashes := DEFAULT_LIMITS[.Dash_Segments], scratch: ^Shape_Scratch = nil) -> (shape: Shape, ok, complete: bool) {
	temp: Shape_Scratch
	sc := scratch
	if sc == nil {
		shape_scratch_init(&temp, context.temp_allocator)
		sc = &temp
	}
	shape_builder_reset(&sc.builder)
	sc.builder.tol = 0
	lo, hi := Vec2{max(f32), max(f32)}, Vec2{min(f32), min(f32)}
	for q in p.coords {
		lo, hi = {min(lo.x, q.x), min(lo.y, q.y)}, {max(hi.x, q.x), max(hi.y, q.y)}
	}
	tol := max(hi.x - lo.x, hi.y - lo.y, s.line_width) / 4096
	complete = stroke_add(sc, p, TRANSFORM_IDENTITY, s, tol, max_dashes)
	shape, ok = shape_build(&sc.builder, allocator, search)
	return
}

// Builds a glyph's shape (font units, y down, the pen at the origin);
// false for glyphs without an outline. `builder` is kept by a caller that
// builds many; without one a build takes it from the context's temp
// allocator.
shape_from_glyph :: proc(f: ^Font, g: Glyph_Index, o: ^ft.Outline, allocator := context.allocator, builder: ^Shape_Builder = nil) -> (Shape, bool) {
	temp: Shape_Builder
	b := builder
	if b == nil {
		temp.curves.allocator = context.temp_allocator
		b = &temp
	}
	shape_builder_reset(b)
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
