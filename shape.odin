package ovg

import "base:runtime"
import "core:mem"
import "core:sync"
import stbtt "vendor:stb/truetype"

import cv "curves"

// Shapes drawn by per-pixel coverage: ovg's handle on the curves package
// (curves/curves.odin: Slug's algorithm, the word layout, the coverage and
// winding functions; shaders/curves.slang is its GPU twin). A `Shape` owns
// its words and an id the GPU backends know its copy by; it is built once
// (from a path or a glyph) and drawn under any transform with `fill_shape`.

Shape :: struct {
	data:      []u32,
	// Unique for the process's life: GPU backends find their copy of the
	// shape by it, so a shape may be moved.
	id:        u64,
	// Shape units to the units the shape was built in (path units, or font
	// units with y down): `p = origin + q * extent`.
	origin:    Vec2,
	extent:    f32,
	allocator: mem.Allocator,
}

// Frees the shape and every GPU backend's copy of it.
shape_destroy :: proc(s: ^Shape) {
	if s.id != 0 {
		sync.mutex_lock(&shape_stores.lock)
		for st in shape_stores.list {
			st.forget(st.data, s.id)
		}
		sync.mutex_unlock(&shape_stores.lock)
	}
	delete(s.data, s.allocator)
	s^ = {}
}

// A backend that keeps copies of shapes (in GPU memory) registers here, so
// a shape's copies are freed with it: `forget` runs from `shape_destroy`,
// on whatever thread destroys the shape.
Shape_Store_Hook :: struct {
	data:   rawptr,
	forget: proc(data: rawptr, id: u64),
}

shape_store_register :: proc(h: Shape_Store_Hook) {
	sync.mutex_lock(&shape_stores.lock)
	defer sync.mutex_unlock(&shape_stores.lock)
	if shape_stores.list == nil {
		shape_stores.list = make([dynamic]Shape_Store_Hook, runtime.heap_allocator())
	}
	append(&shape_stores.list, h)
}

shape_store_unregister :: proc(data: rawptr) {
	sync.mutex_lock(&shape_stores.lock)
	defer sync.mutex_unlock(&shape_stores.lock)
	for h, i in shape_stores.list {
		if h.data == data {
			unordered_remove(&shape_stores.list, i)
			break
		}
	}
	if len(shape_stores.list) == 0 {
		delete(shape_stores.list)
		shape_stores.list = nil
	}
}

@(private = "file")
shape_stores: struct {
	lock: sync.Mutex,
	list: [dynamic]Shape_Store_Hook,
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

// Adds a path's contours. Every contour is closed, as filling does.
shape_add_path :: proc(b: ^Shape_Builder, p: ^Path) {
	it := path_iter(p)
	for verb, coords in path_iter_next(&it) {
		switch verb {
		case .Move_To:
			shape_move_to(b, coords[0])
		case .Line_To:
			shape_line_to(b, coords[0])
		case .Bezier_To:
			shape_cubic_to(b, coords[0], coords[1], coords[2])
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

// Adds a glyph's outline in font units, y down (the pen at the origin);
// false when it has none.
shape_add_glyph :: proc(b: ^Shape_Builder, f: ^Font, g: Glyph_Index) -> bool {
	verts: [^]stbtt.vertex
	n := stbtt.GetGlyphShape(&f.info, i32(g), &verts)
	if n <= 0 {
		return false
	}
	defer stbtt.FreeShape(&f.info, verts)
	for v in verts[:n] {
		p := Vec2{f32(v.x), -f32(v.y)}
		#partial switch stbtt.vmove(v.type) {
		case .vmove:
			shape_move_to(b, p)
		case .vline:
			shape_line_to(b, p)
		case .vcurve:
			shape_quad_to(b, {f32(v.cx), -f32(v.cy)}, p)
		case .vcubic:
			shape_cubic_to(b, {f32(v.cx), -f32(v.cy)}, {f32(v.cx1), -f32(v.cy1)}, p)
		}
	}
	shape_close(b)
	return true
}

// Builds the shape from the builder's curves; false (and no shape) when
// there are none.
shape_build :: proc(b: ^Shape_Builder, allocator := context.allocator) -> (s: Shape, ok: bool) {
	words, origin, extent := cv.build(b, allocator) or_return
	return {data = words, origin = origin, extent = extent, allocator = allocator, id = sync.atomic_add(&shape_next_id, 1) + 1}, true
}

// Builds a path's shape.
shape_from_path :: proc(p: ^Path, allocator := context.allocator) -> (Shape, bool) {
	b: Shape_Builder
	b.curves.allocator = context.temp_allocator
	shape_add_path(&b, p)
	return shape_build(&b, allocator)
}

// Builds a glyph's shape (font units, y down, the pen at the origin);
// false for glyphs without an outline.
shape_from_glyph :: proc(f: ^Font, g: Glyph_Index, allocator := context.allocator) -> (Shape, bool) {
	b: Shape_Builder
	b.curves.allocator = context.temp_allocator
	if !shape_add_glyph(&b, f, g) {
		return {}, false
	}
	return shape_build(&b, allocator)
}

// ---- coverage ----------------------------------------------------------------------

// Coverage of the pixel centered at `rc` (shape units), the pixel spanning
// `ems_per_pixel` shape units along each axis (`shape_ems_per_pixel`); `s`
// is a shape's words. See cv.coverage.
shape_coverage :: cv.coverage

// Shape units spanned by one pixel along each axis under `t` (shape units
// to device pixels): what `fwidth` of the shape coordinate gives a shader
// (cv.footprint_of the inverse's Jacobian).
shape_ems_per_pixel :: proc "contextless" (t: Transform2D) -> Vec2 {
	inv := transform_inverse(t)
	return cv.footprint_of(matrix[2, 2]f32{inv[0], inv[2], inv[1], inv[3]})
}
