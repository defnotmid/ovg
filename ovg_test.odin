package ovg

import "core:math"
import "core:mem"
import "core:testing"

// ---- helpers ------------------------------------------------------------------

@(private = "file")
Sw :: struct {
	backend: Software_Backend,
	canvas:  Canvas,
}

@(private = "file")
sw_open :: proc(s: ^Sw, w, h: u32) {
	software_backend_init(&s.backend)
	canvas_init(&s.canvas, software_backend(&s.backend))
	set_size(&s.canvas, w, h)
}

@(private = "file")
sw_close :: proc(s: ^Sw) {
	canvas_destroy(&s.canvas)
	software_backend_destroy(&s.backend)
}

@(private = "file")
px :: proc(s: ^Sw, x, y: u32) -> [4]u8 {
	i := (y * s.backend.width + x) * 4
	p := s.backend.pixels
	return {p[i], p[i + 1], p[i + 2], p[i + 3]}
}

// ---- geometry / color / containers --------------------------------------------------

@(test)
test_transform :: proc(t: ^testing.T) {
	p := transform_point(transform_translation(10, 20), 5, 7)
	testing.expect_value(t, p, Vec2{15, 27})

	m := transform_rotation(0.73)
	m[4] += 4
	m[5] -= 2
	m = transform_multiply(m, transform_scaling(1.5, 2))
	id := transform_multiply(m, transform_inverse(m))
	for v, i in TRANSFORM_IDENTITY {
		testing.expect(t, abs(id[i] - v) < 1e-4)
	}
}

@(test)
test_vector_math :: proc(t: ^testing.T) {
	v := Vec2{3, 4}
	testing.expect(t, abs(normalize(&v) - 5) < 1e-6)
	testing.expect(t, abs(v.x - 0.6) < 1e-6 && abs(v.y - 0.8) < 1e-6)
	// femtovg's sign convention: negated standard cross product.
	testing.expect_value(t, cross({1, 0}, {0, 1}), -1)
}

@(test)
test_rect_intersect :: proc(t: ^testing.T) {
	testing.expect_value(t, rect_intersect({0, 0, 10, 10}, {5, 5, 10, 10}), Rect{5, 5, 5, 5})
}

@(test)
test_color :: proc(t: ^testing.T) {
	c := hex_color("#ff8000")
	testing.expect(t, c.r == 1 && abs(c.g - 128.0 / 255) < 1e-6 && c.b == 0)
	c = hex_color("00ff00cc")
	testing.expect(t, abs(c.a - 204.0 / 255) < 1e-6)
	testing.expect_value(t, hex_color("zzz"), BLACK)
	testing.expect_value(t, hex_color("#F90"), rgb(255, 153, 0))
	testing.expect_value(t, hex_color("f90"), rgb(255, 153, 0))
	testing.expect_value(t, hex_color("#F90A"), rgba(255, 153, 0, 170))
	testing.expect_value(t, hex_color("#000"), BLACK)
	_, ok := hex_color_parse("#12345")
	testing.expect(t, !ok)
	_, ok = hex_color_parse("#12G")
	testing.expect(t, !ok)
	_, ok = hex_color_parse("")
	testing.expect(t, !ok)
	c, ok = hex_color_parse("#11223344")
	testing.expect(t, ok && c == rgba(0x11, 0x22, 0x33, 0x44))
	testing.expect_value(t, premultiplied({0.5, 0.5, 0.5, 0.5}), Color{0.25, 0.25, 0.25, 0.5})
	g := hsl(1.0 / 3.0, 1, 0.5)
	testing.expect(t, abs(g.g - 1) < 1e-4 && abs(g.r) < 1e-4)
}

@(test)
test_slot_map :: proc(t: ^testing.T) {
	m: Slot_Map(u32)
	slot_map_init(&m)
	defer slot_map_destroy(&m)
	a := slot_map_insert(&m, 42)
	testing.expect_value(t, slot_map_get(&m, a)^, 42)
	v, ok := slot_map_remove(&m, a)
	testing.expect(t, ok && v == 42)
	testing.expect(t, slot_map_get(&m, a) == nil)
	b := slot_map_insert(&m, 99)
	testing.expect(t, b.idx == a.idx && b.gen != a.gen)
	testing.expect(t, slot_map_get(&m, a) == nil)
	testing.expect_value(t, slot_map_get(&m, b)^, 99)
}

@(test)
test_atlas :: proc(t: ^testing.T) {
	a: Atlas
	atlas_init(&a, 128, 128)
	defer atlas_destroy(&a)
	x, y, ok := atlas_add_rect(&a, 32, 32)
	testing.expect(t, ok && x == 0 && y == 0)
	x, y, ok = atlas_add_rect(&a, 32, 16)
	testing.expect(t, ok && x == 32 && y == 0)
	x, y, ok = atlas_add_rect(&a, 96, 16)
	testing.expect(t, ok && x == 32 && y == 16)

	small: Atlas
	atlas_init(&small, 32, 32)
	defer atlas_destroy(&small)
	_, _, ok = atlas_add_rect(&small, 31, 31)
	testing.expect(t, ok)
	_, _, ok = atlas_add_rect(&small, 32, 32)
	testing.expect(t, !ok)
}

// ---- paths -----------------------------------------------------------------------------

@(test)
test_path_shapes :: proc(t: ^testing.T) {
	p: Path
	defer path_destroy(&p)
	path_rect(&p, 1, 2, 10, 20)
	testing.expect_value(t, len(p.verbs), 5)
	testing.expect_value(t, p.coords[2], Vec2{11, 22})

	path_reset(&p)
	path_circle(&p, 0, 0, 10)
	testing.expect_value(t, len(p.verbs), 6)
	testing.expect_value(t, len(p.coords), 13)
}

@(test)
test_path_queries :: proc(t: ^testing.T) {
	vb: Void_Backend
	c: Canvas
	canvas_init(&c, void_backend(&vb))
	defer canvas_destroy(&c)
	set_size(&c, 100, 100)
	p: Path
	defer path_destroy(&p)
	path_rect(&p, 0, 0, 10, 20)
	testing.expect_value(t, path_bounds(&c, &p), Bounds{0, 0, 10, 20})
	testing.expect(t, contains_point(&c, &p, 5, 5, .Even_Odd))
	testing.expect(t, !contains_point(&c, &p, 20, 20, .Even_Odd))
	// Queries leave nothing in the frame.
	testing.expect_value(t, len(c.shape_words), 0)
	// A circle's bounds are exact (its turning points, not its controls).
	path_reset(&p)
	path_circle(&p, 50, 50, 10)
	testing.expect_value(t, path_bounds(&c, &p), Bounds{40, 40, 60, 60})
	// Two squares both drawn the Solid way round, the inner marked Hole:
	// Hole winds it the other way, so the middle is out under either rule.
	path_reset(&p)
	path_move_to(&p, 0, 0)
	path_line_to(&p, 0, 30)
	path_line_to(&p, 30, 30)
	path_line_to(&p, 30, 0)
	path_close(&p)
	path_move_to(&p, 10, 10)
	path_line_to(&p, 10, 20)
	path_line_to(&p, 20, 20)
	path_line_to(&p, 20, 10)
	path_close(&p)
	path_solidity(&p, .Hole)
	for rule in Fill_Rule {
		testing.expect(t, contains_point(&c, &p, 5, 5, rule))
		testing.expect(t, !contains_point(&c, &p, 15, 15, rule))
	}
	// Under the transform.
	translate(&c, 100, 0)
	testing.expect(t, contains_point(&c, &p, 105, 5, .Non_Zero))
	testing.expect(t, !contains_point(&c, &p, 5, 5, .Non_Zero))
}

@(test)
test_gradient_synthesize :: proc(t: ^testing.T) {
	stops := []Gradient_Stop{{0, {1, 0, 0, 1}}, {1, {0, 0, 1, 1}}}
	ramp: [GRADIENT_RAMP_WIDTH * 4]u8
	gradient_synthesize({stops, 1}, &ramp)
	testing.expect(t, ramp[0] == 255 && ramp[1] == 0 && ramp[3] == 255)
	testing.expect(t, ramp[1022] >= 253 && ramp[1020] <= 2)

	// A last stop before 1.0 pads to the end.
	short := []Gradient_Stop{{0, {1, 0, 0, 1}}, {0.5, {0, 1, 0, 1}}}
	gradient_synthesize({short, 1}, &ramp)
	testing.expect(t, ramp[255 * 4 + 1] == 255 && ramp[255 * 4 + 3] == 255)
}

// ---- canvas recording -------------------------------------------------------------------

@(test)
test_canvas_void :: proc(t: ^testing.T) {
	vb: Void_Backend
	c: Canvas
	canvas_init(&c, void_backend(&vb))
	defer canvas_destroy(&c)
	set_size(&c, 200, 200)
	p: Path
	defer path_destroy(&p)
	path_rect(&p, 10, 10, 50, 50)
	fill_path(&c, &p, paint_color(rgb(255, 0, 0)))
	sp := paint_color(BLACK)
	sp.stroke.line_width = 2
	stroke_path(&c, &p, sp)
	clear_rect(&c, 0, 0, 10, 10, WHITE)
	flush(&c)
	// The fill and the stroke are shapes in one draw (after the frame's
	// render target), then the clear; no triangles.
	testing.expect_value(t, vb.last_frame_commands, 3)
	testing.expect_value(t, vb.last_frame_verts, 0)

	save(&c)
	translate(&c, 10, 20)
	scale(&c, 2, 2)
	testing.expect_value(t, current_transform(&c)[0], 2)
	restore(&c)
	testing.expect_value(t, current_transform(&c)[0], 1)
}

// ---- software rasterizer -----------------------------------------------------------------

@(test)
test_sw_clear :: proc(t: ^testing.T) {
	s: Sw
	sw_open(&s, 16, 16)
	defer sw_close(&s)
	clear_rect(&s.canvas, 0, 0, 16, 16, rgb(255, 0, 0))
	clear_rect(&s.canvas, 4, 4, 2, 2, rgb(0, 0, 255))
	flush(&s.canvas)
	testing.expect_value(t, px(&s, 0, 0), [4]u8{255, 0, 0, 255})
	testing.expect_value(t, px(&s, 15, 15), [4]u8{255, 0, 0, 255})
	testing.expect_value(t, px(&s, 5, 5), [4]u8{0, 0, 255, 255})
	testing.expect_value(t, px(&s, 6, 6), [4]u8{255, 0, 0, 255})
}

@(test)
test_sw_fill_rect :: proc(t: ^testing.T) {
	s: Sw
	sw_open(&s, 32, 32)
	defer sw_close(&s)
	clear_rect(&s.canvas, 0, 0, 32, 32, WHITE)
	p: Path
	defer path_destroy(&p)
	path_rect(&p, 8, 8, 16, 16)
	fill_path(&s.canvas, &p, paint_color(rgb(0, 0, 255)))
	flush(&s.canvas)
	testing.expect_value(t, px(&s, 16, 16), [4]u8{0, 0, 255, 255})
	testing.expect_value(t, px(&s, 8, 8), [4]u8{0, 0, 255, 255})
	testing.expect_value(t, px(&s, 23, 23), [4]u8{0, 0, 255, 255})
	testing.expect_value(t, px(&s, 7, 16), [4]u8{255, 255, 255, 255})
	testing.expect_value(t, px(&s, 24, 16), [4]u8{255, 255, 255, 255})
}

// Translucent fills must not double-blend along the shared diagonal of their
// triangles (top-left rule).
@(test)
test_sw_no_seams :: proc(t: ^testing.T) {
	s: Sw
	sw_open(&s, 32, 32)
	defer sw_close(&s)
	p: Path
	defer path_destroy(&p)
	path_rect(&p, 4, 4, 24, 24)
	fp := paint_color({0, 0, 0, 0.5})
	fp.anti_alias = false
	fill_path(&s.canvas, &p, fp)
	flush(&s.canvas)
	want := px(&s, 6, 20)
	for i in u32(4) ..< 28 {
		testing.expectf(t, px(&s, i, i) == want, "diagonal pixel %d: %v != %v", i, px(&s, i, i), want)
	}
}

@(test)
test_sw_rounded_rect_aa :: proc(t: ^testing.T) {
	s: Sw
	sw_open(&s, 64, 64)
	defer sw_close(&s)
	clear_rect(&s.canvas, 0, 0, 64, 64, WHITE)
	p: Path
	defer path_destroy(&p)
	path_rounded_rect(&p, 8, 8, 48, 48, 12)
	fill_path(&s.canvas, &p, paint_color(rgb(0, 0, 255)))
	flush(&s.canvas)
	testing.expect_value(t, px(&s, 32, 32), [4]u8{0, 0, 255, 255})
	testing.expect_value(t, px(&s, 2, 2), [4]u8{255, 255, 255, 255})
	testing.expect(t, px(&s, 8, 8).r > 200)
	// Antialiased corner: some pixel along the corner diagonal is a blend.
	partial := false
	for i in u32(8) ..< 16 {
		r := px(&s, i, i).r
		if r > 20 && r < 235 {
			partial = true
		}
	}
	testing.expect(t, partial)
}

@(test)
test_sw_concave_star :: proc(t: ^testing.T) {
	s: Sw
	sw_open(&s, 64, 64)
	defer sw_close(&s)
	clear_rect(&s.canvas, 0, 0, 64, 64, WHITE)
	p: Path
	defer path_destroy(&p)
	pts := [?]Vec2{{32, 6}, {40, 26}, {60, 26}, {44, 38}, {50, 58}, {32, 46}, {14, 58}, {20, 38}, {4, 26}, {24, 26}}
	path_move_to(&p, pts[0].x, pts[0].y)
	for q in pts[1:] {
		path_line_to(&p, q.x, q.y)
	}
	path_close(&p)
	fill_path(&s.canvas, &p, paint_color(BLACK))
	flush(&s.canvas)
	testing.expect_value(t, px(&s, 32, 32), [4]u8{0, 0, 0, 255})
	testing.expect_value(t, px(&s, 1, 1), [4]u8{255, 255, 255, 255})
	testing.expect_value(t, px(&s, 32, 56), [4]u8{255, 255, 255, 255})
}

@(test)
test_sw_fill_rules :: proc(t: ^testing.T) {
	s: Sw
	sw_open(&s, 64, 64)
	defer sw_close(&s)
	clear_rect(&s.canvas, 0, 0, 64, 64, WHITE)
	p: Path
	defer path_destroy(&p)
	// Two same-direction squares, one inside the other.
	path_rect(&p, 4, 4, 56, 56)
	path_rect(&p, 20, 20, 24, 24)
	eo := paint_color(BLACK)
	eo.fill_rule = .Even_Odd
	fill_path(&s.canvas, &p, eo)
	flush(&s.canvas)
	testing.expect_value(t, px(&s, 10, 10), [4]u8{0, 0, 0, 255})
	testing.expect_value(t, px(&s, 32, 32), [4]u8{255, 255, 255, 255})

	clear_rect(&s.canvas, 0, 0, 64, 64, WHITE)
	fill_path(&s.canvas, &p, paint_color(BLACK))
	flush(&s.canvas)
	testing.expect_value(t, px(&s, 32, 32), [4]u8{0, 0, 0, 255})

	// A hole contour cuts out under non-zero.
	clear_rect(&s.canvas, 0, 0, 64, 64, WHITE)
	path_reset(&p)
	path_rect(&p, 4, 4, 56, 56)
	path_rect(&p, 20, 20, 24, 24)
	path_solidity(&p, .Hole)
	fill_path(&s.canvas, &p, paint_color(BLACK))
	flush(&s.canvas)
	testing.expect_value(t, px(&s, 10, 10), [4]u8{0, 0, 0, 255})
	testing.expect_value(t, px(&s, 32, 32), [4]u8{255, 255, 255, 255})
}

@(test)
test_sw_scissor :: proc(t: ^testing.T) {
	s: Sw
	sw_open(&s, 32, 32)
	defer sw_close(&s)
	clear_rect(&s.canvas, 0, 0, 32, 32, WHITE)
	scissor(&s.canvas, 0, 0, 16, 32)
	p: Path
	defer path_destroy(&p)
	path_rect(&p, 0, 0, 32, 32)
	fill_path(&s.canvas, &p, paint_color(rgb(255, 0, 0)))
	flush(&s.canvas)
	testing.expect_value(t, px(&s, 4, 16), [4]u8{255, 0, 0, 255})
	testing.expect_value(t, px(&s, 24, 16), [4]u8{255, 255, 255, 255})
}

@(test)
test_sw_rotated_scissor :: proc(t: ^testing.T) {
	s: Sw
	sw_open(&s, 64, 64)
	defer sw_close(&s)
	clear_rect(&s.canvas, 0, 0, 64, 64, WHITE)
	save(&s.canvas)
	translate(&s.canvas, 32, 32)
	rotate(&s.canvas, math.PI / 4)
	scissor(&s.canvas, -10, -10, 20, 20)
	restore(&s.canvas)
	scissor_state := s.canvas.states[len(s.canvas.states) - 1].scissor
	testing.expect(t, !scissor_state.has_extent)

	translate(&s.canvas, 32, 32)
	rotate(&s.canvas, math.PI / 4)
	scissor(&s.canvas, -10, -10, 20, 20)
	reset_transform(&s.canvas)
	p: Path
	defer path_destroy(&p)
	path_rect(&p, 0, 0, 64, 64)
	fill_path(&s.canvas, &p, paint_color(BLACK))
	flush(&s.canvas)
	testing.expect_value(t, px(&s, 32, 32), [4]u8{0, 0, 0, 255})
	// Inside the axis-aligned bounds of the diamond but outside the diamond.
	testing.expect_value(t, px(&s, 21, 21), [4]u8{255, 255, 255, 255})
	testing.expect_value(t, px(&s, 32, 20), [4]u8{0, 0, 0, 255})
}

@(test)
test_sw_image_paint :: proc(t: ^testing.T) {
	s: Sw
	sw_open(&s, 32, 32)
	defer sw_close(&s)
	clear_rect(&s.canvas, 0, 0, 32, 32, WHITE)
	pix := [?]u8{255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 0, 255}
	id, err := create_image(&s.canvas, image_source_rgba(pix[:], 2, 2), {.Nearest})
	testing.expect_value(t, err, Error.None)
	p: Path
	defer path_destroy(&p)
	path_rect(&p, 0, 0, 32, 32)
	ip := paint_image(id, 0, 0, 32, 32, 0)
	ip.anti_alias = false
	fill_path(&s.canvas, &p, ip)
	flush(&s.canvas)
	testing.expect_value(t, px(&s, 4, 4), [4]u8{255, 0, 0, 255})
	testing.expect_value(t, px(&s, 24, 4), [4]u8{0, 255, 0, 255})
	testing.expect_value(t, px(&s, 4, 24), [4]u8{0, 0, 255, 255})
	testing.expect_value(t, px(&s, 24, 24), [4]u8{255, 255, 0, 255})
}

@(test)
test_sw_multi_stop_gradient :: proc(t: ^testing.T) {
	s: Sw
	sw_open(&s, 64, 16)
	defer sw_close(&s)
	clear_rect(&s.canvas, 0, 0, 64, 16, WHITE)
	p: Path
	defer path_destroy(&p)
	path_rect(&p, 0, 0, 64, 16)
	stops := []Gradient_Stop{{0, rgb(255, 0, 0)}, {0.5, rgb(0, 255, 0)}, {1, rgb(0, 0, 255)}}
	fill_path(&s.canvas, &p, paint_linear_gradient_stops(0, 0, 64, 0, stops))
	flush(&s.canvas)
	l, m, r := px(&s, 4, 8), px(&s, 32, 8), px(&s, 60, 8)
	testing.expect(t, l.r > 200 && l.g < 64 && l.b < 64)
	testing.expect(t, m.g > 150 && m.r < 128)
	testing.expect(t, r.b > 200 && r.r < 64)
	// The ramp texture survives one unused frame, then is freed.
	testing.expect_value(t, len(s.canvas.gradients.prev_frame), 1)
	flush(&s.canvas)
	flush(&s.canvas)
	testing.expect_value(t, len(s.canvas.gradients.prev_frame) + len(s.canvas.gradients.this_frame), 0)
}

@(test)
test_sw_radial_gradient :: proc(t: ^testing.T) {
	s: Sw
	sw_open(&s, 64, 64)
	defer sw_close(&s)
	p: Path
	defer path_destroy(&p)
	path_rect(&p, 0, 0, 64, 64)
	fill_path(&s.canvas, &p, paint_radial_gradient(32, 32, 8, 24, WHITE, BLACK))
	flush(&s.canvas)
	testing.expect_value(t, px(&s, 32, 32), [4]u8{255, 255, 255, 255})
	testing.expect_value(t, px(&s, 2, 2), [4]u8{0, 0, 0, 255})
	// Halfway between the radii is mid grey.
	mid := px(&s, 32 + 16, 32).r
	testing.expectf(t, mid > 110 && mid < 145, "mid %d", mid)
}

@(test)
test_sw_destination_over :: proc(t: ^testing.T) {
	s: Sw
	sw_open(&s, 32, 16)
	defer sw_close(&s)
	left, full: Path
	defer path_destroy(&left)
	defer path_destroy(&full)
	path_rect(&left, 0, 0, 16, 16)
	path_rect(&full, 0, 0, 32, 16)
	wp := paint_color(WHITE)
	wp.anti_alias = false
	fill_path(&s.canvas, &left, wp)
	set_composite_operation(&s.canvas, .Destination_Over)
	rp := paint_color(rgb(255, 0, 0))
	rp.anti_alias = false
	fill_path(&s.canvas, &full, rp)
	flush(&s.canvas)
	testing.expect_value(t, px(&s, 4, 8), [4]u8{255, 255, 255, 255})
	testing.expect_value(t, px(&s, 24, 8), [4]u8{255, 0, 0, 255})
}

@(test)
test_sw_stroke_once :: proc(t: ^testing.T) {
	s: Sw
	sw_open(&s, 64, 64)
	defer sw_close(&s)
	clear_rect(&s.canvas, 0, 0, 64, 64, WHITE)
	p: Path
	defer path_destroy(&p)
	path_move_to(&p, 8, 8)
	path_line_to(&p, 56, 56)
	path_line_to(&p, 8, 56)
	path_line_to(&p, 56, 8)
	sp := paint_color(rgba(0, 0, 0, 128))
	sp.stroke.line_width = 6
	stroke_path(&s.canvas, &p, sp)
	flush(&s.canvas)
	single, crossing := px(&s, 20, 20), px(&s, 32, 32)
	testing.expectf(t, abs(int(single.r) - int(crossing.r)) <= 2, "single %v crossing %v", single, crossing)
	testing.expect(t, single.r > 100 && single.r < 150)
}

@(test)
test_sw_conic :: proc(t: ^testing.T) {
	s: Sw
	sw_open(&s, 64, 64)
	defer sw_close(&s)
	p: Path
	defer path_destroy(&p)
	path_rect(&p, 0, 0, 64, 64)
	stops := []Gradient_Stop{{0, rgb(255, 0, 0)}, {1, rgb(0, 0, 255)}}
	fill_path(&s.canvas, &p, paint_conic_gradient_stops(32, 32, stops))
	flush(&s.canvas)
	top, bottom, left, right := px(&s, 32, 4), px(&s, 32, 60), px(&s, 4, 32), px(&s, 60, 32)
	testing.expect(t, top.r > 200 && top.b < 64)
	testing.expect(t, bottom.r > 80 && bottom.r < 180 && bottom.b > 80 && bottom.b < 180)
	testing.expect(t, left.b > left.r)
	testing.expect(t, right.r > right.b)
}

@(test)
test_sw_glyph_mask :: proc(t: ^testing.T) {
	s: Sw
	sw_open(&s, 32, 32)
	defer sw_close(&s)
	clear_rect(&s.canvas, 0, 0, 32, 32, WHITE)

	font: Font
	atlas: Glyph_Atlas
	testing.expect_value(t, glyph_atlas_init(&atlas, 32, 32, &s.canvas), Error.None)
	defer glyph_atlas_destroy(&atlas, &s.canvas)
	// An 8x8 glyph written straight into the bitmap: fill_glyph_run uploads
	// the dirty rows before drawing.
	for y in 0 ..< 8 {
		mem.set(&atlas.pixels[y * 32], 255, 8)
	}
	atlas.dirty_y0, atlas.dirty_y1 = 0, 8
	atlas.cache[glyph_key(&font, 42, 1)] = {0, 0, 8, 8, 0, 0, true}

	glyphs := []Positioned_Glyph{{42, 12, 12}}
	testing.expect_value(t, fill_glyph_run(&s.canvas, &font, &atlas, glyphs, 1, paint_color(rgb(255, 0, 0))), Error.None)
	_, _, dirty := glyph_atlas_take_dirty(&atlas)
	testing.expect(t, !dirty)
	flush(&s.canvas)
	testing.expect_value(t, px(&s, 15, 15), [4]u8{255, 0, 0, 255})
	testing.expect_value(t, px(&s, 4, 4), [4]u8{255, 255, 255, 255})
}

@(test)
test_glyph_atlas_cpu :: proc(t: ^testing.T) {
	fonts: Font_Collection
	font_collection_init(&fonts)
	defer font_collection_destroy(&fonts)
	atlas: Glyph_Atlas
	testing.expect_value(t, glyph_atlas_init(&atlas, 128, 64), Error.None)
	defer glyph_atlas_destroy(&atlas)
	testing.expect(t, !image_id_valid(atlas.image_id))

	f := &fonts.fallback.font
	sc := font_scale_for_em(f, 20)
	a, err := glyph_atlas_get(&atlas, f, font_glyph_index(f, 'A'), sc)
	testing.expect_value(t, err, Error.None)
	testing.expect(t, a.visible && a.width > 4 && a.height > 8)
	space, _ := glyph_atlas_get(&atlas, f, font_glyph_index(f, ' '), sc)
	testing.expect(t, !space.visible)
	ink := 0
	for y in a.atlas_y ..< a.atlas_y + a.height {
		for x in a.atlas_x ..< a.atlas_x + a.width {
			ink += int(atlas.pixels[y * atlas.width + x] > 128)
		}
	}
	testing.expect(t, ink > 10)
	y0, y1, dirty := glyph_atlas_take_dirty(&atlas)
	testing.expect(t, dirty && y0 <= a.atlas_y && y1 >= a.atlas_y + a.height)
	_, _, dirty = glyph_atlas_take_dirty(&atlas)
	testing.expect(t, !dirty)

	// The same font through another Font value (a copy) hits the cache:
	// nothing new to upload. Another load of the same data is another font
	// (its data may be freed and the address reused while the atlas lives).
	copy_of := f^
	again, _ := glyph_atlas_get(&atlas, &copy_of, font_glyph_index(f, 'A'), sc)
	testing.expect_value(t, again, a)
	_, _, dirty = glyph_atlas_take_dirty(&atlas)
	testing.expect(t, !dirty)
	reloaded, _ := font_load(f.data)
	defer font_destroy(&reloaded)
	testing.expect(t, glyph_key(&reloaded, 1, sc) != glyph_key(f, 1, sc) && glyph_key(&copy_of, 1, sc) == glyph_key(f, 1, sc))

	glyph_atlas_reset(&atlas)
	y0, y1, dirty = glyph_atlas_take_dirty(&atlas)
	testing.expect(t, dirty && y0 == 0 && y1 == atlas.height)
	testing.expect_value(t, atlas.pixels[a.atlas_y * atlas.width + a.atlas_x + a.width / 2], 0)

	for _ in 0 ..< 1000 {
		if _, err = glyph_atlas_get(&atlas, f, font_glyph_index(f, 'W'), sc * f32(1 + len(atlas.cache))); err != nil {
			break
		}
	}
	testing.expect_value(t, err, Error.Atlas_Full)
}

@(test)
test_sw_text :: proc(t: ^testing.T) {
	s: Sw
	sw_open(&s, 128, 48)
	defer sw_close(&s)
	clear_rect(&s.canvas, 0, 0, 128, 48, WHITE)

	font, err := font_load(#load("assets/Vera.ttf"))
	testing.expect_value(t, err, Error.None)
	defer font_destroy(&font)
	sc := font_scale_for_em(&font, 32)
	glyphs: [dynamic]Positioned_Glyph
	defer delete(glyphs)
	end := layout_simple(&font, "Hi!", 8, 38, sc, &glyphs)
	testing.expect_value(t, len(glyphs), 3)
	testing.expect(t, end > 40 && end < 100)

	scratch: Path
	defer path_destroy(&scratch)
	fill_glyph_outlines(&s.canvas, &font, glyphs[:], sc, paint_color(BLACK), &scratch)
	flush(&s.canvas)
	// The stem of the "H" is solid; the counter between its stems is not.
	dark := 0
	for x in u32(8) ..< 40 {
		if px(&s, x, 30).r < 40 {
			dark += 1
		}
	}
	testing.expect(t, dark >= 4)
	testing.expect_value(t, px(&s, 120, 4), [4]u8{255, 255, 255, 255})
}

@(test)
test_sw_render_target_orientation :: proc(t: ^testing.T) {
	s: Sw
	sw_open(&s, 32, 32)
	defer sw_close(&s)
	img, err := create_image_empty(&s.canvas, 16, 16, .RGBA8, {.Nearest, .Premultiplied})
	testing.expect_value(t, err, Error.None)
	set_render_target(&s.canvas, img)
	clear_rect(&s.canvas, 0, 0, 16, 16, BLACK)
	p: Path
	defer path_destroy(&p)
	path_rect(&p, 0, 0, 16, 4)
	fill_path(&s.canvas, &p, paint_color(rgb(255, 0, 0)))
	set_render_target(&s.canvas, nil)
	path_reset(&p)
	path_rect(&p, 0, 0, 16, 16)
	ip := paint_image(img, 0, 0, 16, 16, 0)
	ip.anti_alias = false
	fill_path(&s.canvas, &p, ip)
	flush(&s.canvas)
	// The red band drawn at the top of the image shows up at the top.
	testing.expect_value(t, px(&s, 8, 1), [4]u8{255, 0, 0, 255})
	testing.expect_value(t, px(&s, 8, 12), [4]u8{0, 0, 0, 255})
}

@(test)
test_sw_blur :: proc(t: ^testing.T) {
	s: Sw
	sw_open(&s, 64, 64)
	defer sw_close(&s)
	W :: 32
	src: [W * W * 4]u8
	c := (16 * W + 16) * 4
	src[c], src[c + 1], src[c + 2], src[c + 3] = 255, 255, 255, 255
	src_id, _ := create_image(&s.canvas, image_source_rgba(src[:], W, W), {.Premultiplied})
	dst_id, _ := create_image_empty(&s.canvas, W, W, .RGBA8, {.Premultiplied})
	filter_image(&s.canvas, dst_id, Gaussian_Blur{2}, src_id)
	flush(&s.canvas)
	d := image_store_get(&s.canvas.images, dst_id).image.pixels
	testing.expect(t, d[c + 3] < 200 && d[c + 3] > 0)
	testing.expect(t, d[(16 * W + 18) * 4 + 3] > 0)
	testing.expect(t, d[(2 * W + 2) * 4 + 3] == 0)
}

// The global alpha applies once, to the draws in a layer, not again to the
// layer's mask, clip and composite.
@(test)
test_sw_layer_global_alpha :: proc(t: ^testing.T) {
	near :: proc(t: ^testing.T, got, want: [4]u8, loc := #caller_location) {
		for i in 0 ..< 4 {
			testing.expectf(t, abs(int(got[i]) - int(want[i])) <= 1, "got %v, want %v", got, want, loc = loc)
		}
	}
	s: Sw
	sw_open(&s, 32, 32)
	defer sw_close(&s)
	c := &s.canvas
	ls: Layer_Stack
	defer layer_stack_destroy(&ls, c)
	p: Path
	defer path_destroy(&p)
	path_rect(&p, 0, 0, 16, 32)

	// Masked: alpha set after the mask is drawn, as lottie_draw does.
	clear_rect(c, 0, 0, 32, 32, TRANSPARENT)
	layer_stack_begin(&ls, c, 32, 32)
	layer_push(&ls, c, {})
	layer_mask_begin(&ls, c)
	fill_path(c, &p, paint_color(WHITE))
	layer_mask_end(&ls, c)
	set_global_alpha(c, 0.5)
	fill_path(c, &p, paint_color(rgb(255, 0, 0)))
	layer_pop(&ls, c)
	set_global_alpha(c, 1)
	layer_stack_end(&ls, c)
	flush(c)
	near(t, px(&s, 8, 8), {127, 0, 0, 127})

	// Blended: the rest of the backdrop is untouched.
	layer_stack_begin(&ls, c, 32, 32, nil, true)
	clear_rect(c, 0, 0, 32, 32, rgb(0, 0, 255))
	layer_push(&ls, c, {blend = .Multiply})
	set_global_alpha(c, 0.5)
	fill_path(c, &p, paint_color(rgb(255, 0, 0)))
	layer_pop(&ls, c)
	set_global_alpha(c, 1)
	layer_stack_end(&ls, c)
	flush(c)
	near(t, px(&s, 8, 8), {0, 0, 128, 255})
	near(t, px(&s, 24, 8), {0, 0, 255, 255})
}

// A layer with only an opacity over shapes draws as one group: the shapes
// composite, then fade once (the blue hides the red where they overlap).
@(test)
test_layer_opacity_group :: proc(t: ^testing.T) {
	s: Sw
	sw_open(&s, 32, 32)
	defer sw_close(&s)
	c := &s.canvas
	ls: Layer_Stack
	defer layer_stack_destroy(&ls, c)
	p: Path
	defer path_destroy(&p)
	clear_rect(c, 0, 0, 32, 32, WHITE)
	layer_stack_begin(&ls, c, 32, 32)
	layer_push(&ls, c, {opacity = 0.5})
	path_rect(&p, 0, 0, 20, 32)
	fill_path(c, &p, paint_color(rgb(255, 0, 0)))
	path_reset(&p)
	path_rect(&p, 12, 0, 20, 32)
	fill_path(c, &p, paint_color(rgb(0, 0, 255)))
	layer_pop(&ls, c)
	layer_stack_end(&ls, c)
	d, ok := c.commands[len(c.commands) - 1].type.(Cmd_Draw_Shapes)
	testing.expect(t, ok && d.group != 0 && d.instances.count == 2)
	flush(c)
	for x in ([2]u32{4, 16}) {
		want := [4]u8{255, 128, 128, 255} if x == 4 else {128, 128, 255, 255}
		got := px(&s, x, 8)
		for i in 0 ..< 4 {
			testing.expectf(t, abs(int(got[i]) - int(want[i])) <= 1, "x %d: got %v, want %v", x, got, want)
		}
	}
}

@(test)
test_sw_screenshot :: proc(t: ^testing.T) {
	s: Sw
	sw_open(&s, 4, 4)
	defer sw_close(&s)
	clear_rect(&s.canvas, 0, 0, 4, 4, rgb(12, 34, 56))
	flush(&s.canvas)
	shot, err := screenshot(&s.canvas)
	defer delete(shot.pixels)
	testing.expect_value(t, err, Error.None)
	testing.expect(t, shot.width == 4 && len(shot.pixels) == 64)
	testing.expect(t, shot.pixels[0] == 12 && shot.pixels[1] == 34 && shot.pixels[2] == 56)
}

// ---- fill orientation ---------------------------------------------------------------

// Coverage of black drawn on white, in pixels, and the number of partly
// covered pixels.
@(private = "file")
ink :: proc(s: ^Sw) -> (covered: f32, partial: int) {
	for i := 0; i < len(s.backend.pixels); i += 4 {
		r := s.backend.pixels[i]
		covered += f32(255 - r) / 255
		if r != 0 && r != 255 {
			partial += 1
		}
	}
	return
}

@(private = "file")
add_square :: proc(p: ^Path, x0, y0, x1, y1: f32, clockwise: bool) {
	path_move_to(p, x0, y0)
	if clockwise {
		path_line_to(p, x1, y0)
		path_line_to(p, x1, y1)
		path_line_to(p, x0, y1)
	} else {
		path_line_to(p, x0, y1)
		path_line_to(p, x1, y1)
		path_line_to(p, x1, y0)
	}
	path_close(p)
}

@(private = "file")
fill_ink :: proc(s: ^Sw, p: ^Path, rule: Fill_Rule) -> (f32, int) {
	clear_rect(&s.canvas, 0, 0, s.backend.width, s.backend.height, WHITE)
	fp := paint_color(BLACK)
	fp.fill_rule = rule
	fill_path(&s.canvas, p, fp)
	flush(&s.canvas)
	return ink(s)
}

// Clockwise and counter-clockwise squares cover the same pixels, exactly the
// square when it is pixel aligned (`M10 10 H200 V200 H10 Z` is 190x190).
@(test)
test_sw_fill_orientation :: proc(t: ^testing.T) {
	s: Sw
	sw_open(&s, 212, 212)
	defer sw_close(&s)
	p: Path
	defer path_destroy(&p)
	for rule in Fill_Rule {
		for cw in ([]bool{true, false}) {
			path_reset(&p)
			add_square(&p, 10, 10, 200, 200, cw)
			covered, partial := fill_ink(&s, &p, rule)
			testing.expectf(t, covered == 190 * 190 && partial == 0, "%v cw=%v: %v px, %d partial", rule, cw, covered, partial)
			testing.expect_value(t, px(&s, 9, 100), [4]u8{255, 255, 255, 255})
			testing.expect_value(t, px(&s, 200, 100), [4]u8{255, 255, 255, 255})
			testing.expect_value(t, px(&s, 10, 10), [4]u8{0, 0, 0, 255})

			// Off the pixel grid: the area still matches.
			path_reset(&p)
			add_square(&p, 10.5, 10.25, 100.5, 120.75, cw)
			covered, _ = fill_ink(&s, &p, rule)
			testing.expectf(t, abs(covered - 90 * 110.5) < 1, "%v cw=%v: %v px off grid", rule, cw, covered)
		}
	}
}

// A donut cuts its hole exactly when the hole winds against the outer
// contour (both rules), and under even-odd when it winds the same way.
@(test)
test_sw_fill_orientation_holes :: proc(t: ^testing.T) {
	s: Sw
	sw_open(&s, 64, 64)
	defer sw_close(&s)
	p: Path
	defer path_destroy(&p)
	for cw in ([]bool{true, false}) {
		path_reset(&p)
		add_square(&p, 4, 4, 60, 60, cw)
		add_square(&p, 20, 20, 44, 44, !cw)
		for rule in Fill_Rule {
			covered, partial := fill_ink(&s, &p, rule)
			testing.expectf(t, covered == 56 * 56 - 24 * 24 && partial == 0, "opposite hole %v cw=%v: %v px", rule, cw, covered)
			testing.expect_value(t, px(&s, 32, 32), [4]u8{255, 255, 255, 255})
			testing.expect(t, contains_point(&s.canvas, &p, 10, 10, rule))
			testing.expect(t, !contains_point(&s.canvas, &p, 32, 32, rule))
		}

		path_reset(&p)
		add_square(&p, 4, 4, 60, 60, cw)
		add_square(&p, 20, 20, 44, 44, cw)
		_, _ = fill_ink(&s, &p, .Even_Odd)
		testing.expect_value(t, px(&s, 32, 32), [4]u8{255, 255, 255, 255})
		testing.expect_value(t, px(&s, 10, 10), [4]u8{0, 0, 0, 255})
		testing.expect_value(t, px(&s, 3, 32), [4]u8{255, 255, 255, 255})
		testing.expect(t, !contains_point(&s.canvas, &p, 32, 32, .Even_Odd))
		testing.expect(t, contains_point(&s.canvas, &p, 32, 32, .Non_Zero))
		covered, _ := fill_ink(&s, &p, .Non_Zero)
		testing.expectf(t, covered == 56 * 56, "same hole non-zero cw=%v: %v px", cw, covered)
	}
}

// Glyph outlines cover their own area: no dilation along the perimeter.
@(test)
test_sw_glyph_outline_area :: proc(t: ^testing.T) {
	s: Sw
	sw_open(&s, 160, 64)
	defer sw_close(&s)
	font, err := font_load(#load("assets/Vera.ttf"))
	testing.expect_value(t, err, Error.None)
	defer font_destroy(&font)
	sc := font_scale_for_em(&font, 48)
	glyphs: [dynamic]Positioned_Glyph
	defer delete(glyphs)
	layout_simple(&font, "lOB", 8, 52, sc, &glyphs)
	p: Path
	defer path_destroy(&p)
	for g in glyphs {
		font_glyph_path(&font, g.glyph, g.x, g.y, sc, &p)
	}
	covered, _ := fill_ink(&s, &p, .Non_Zero)

	// Exact area and perimeter of the flattened outline.
	f: Flat_Path
	defer flat_path_destroy(&f)
	path_flatten(&p, &f)
	area, perimeter: f32
	for ct in f.contours {
		pts := f.points[ct.first:][:ct.count]
		for i in 0 ..< len(pts) {
			p0 := pts[len(pts) - 1 if i == 0 else i - 1]
			area += (pts[i].x - p0.x) * (pts[i].y + p0.y) * 0.5
			perimeter += math.hypot(pts[i].x - p0.x, pts[i].y - p0.y)
		}
	}
	area = abs(area)
	testing.expectf(t, abs(covered - area) < 0.05 * perimeter, "glyph ink %v vs area %v (perimeter %v)", covered, area, perimeter)
}

// Once warm, a canvas frame allocates nothing: multi-stop gradients, dashed
// strokes, nested translucent and blurred layers, text outlines.
@(test)
test_sw_no_allocation_when_warm :: proc(t: ^testing.T) {
	s: Sw
	sw_open(&s, 64, 64)
	defer sw_close(&s)
	c := &s.canvas
	ls: Layer_Stack
	defer layer_stack_destroy(&ls, c)
	p: Path
	defer path_destroy(&p)
	fonts: Font_Collection
	font_collection_init(&fonts)
	defer font_collection_destroy(&fonts)
	l: Text_Layout
	defer text_layout_destroy(&l)
	frame :: proc(c: ^Canvas, ls: ^Layer_Stack, p: ^Path, fonts: ^Font_Collection, l: ^Text_Layout, i: int) {
		clear_rect(c, 0, 0, 64, 64, WHITE)
		layer_stack_begin(ls, c, 64, 64)
		stops := [?]Gradient_Stop{{0, rgb(255, 0, 0)}, {0.5, rgba(0, 255, 0, 128)}, {1, rgb(0, 0, 255)}}
		layer_push(ls, c, {opacity = 0.8})
		layer_push(ls, c, {blur = 1})
		path_reset(p)
		path_rounded_rect(p, 4 + f32(i % 4), 4, 40, 30, 6)
		fill_path(c, p, paint_linear_gradient_stops(0, 0, 64, 0, stops[:]))
		st := paint_color(BLACK)
		st.stroke.line_width = 2
		dash := [?]f32{3, 2}
		st.stroke.dash = dash[:]
		stroke_path(c, p, st)
		layer_pop(ls, c)
		layer_pop(ls, c)
		text_layout(fonts, {{text = "warm frame", style = {size = 12}}}, {x = 4, y = 56}, l)
		for run in l.runs {
			fill_glyph_outlines(c, font_collection_font(fonts, run.face), l.glyphs[run.first:][:run.count], run.em, paint_color(BLACK), p)
		}
		layer_stack_end(ls, c)
		flush(c)
	}
	for i in 0 ..< 30 {
		frame(c, &ls, &p, &fonts, &l, i)
	}
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	{
		context.allocator = mem.tracking_allocator(&track)
		for i in 0 ..< 30 {
			frame(c, &ls, &p, &fonts, &l, i)
		}
	}
	testing.expect_value(t, track.total_allocation_count, 0)
}

// A zero-length subpath's dot is its start cap behind and its end cap
// ahead, each its own style: butt start + round end is half a disc.
@(test)
test_sw_zero_length_mixed_caps :: proc(t: ^testing.T) {
	s: Sw
	sw_open(&s, 64, 64)
	defer sw_close(&s)
	p: Path
	defer path_destroy(&p)
	path_move_to(&p, 32, 32)
	path_line_to(&p, 32, 32)
	st := paint_color(BLACK)
	st.stroke.line_width = 16
	st.stroke.line_cap_start, st.stroke.line_cap_end = .Butt, .Round
	clear_rect(&s.canvas, 0, 0, 64, 64, WHITE)
	stroke_path(&s.canvas, &p, st)
	flush(&s.canvas)
	testing.expect_value(t, px(&s, 36, 32), [4]u8{0, 0, 0, 255}) // ahead: the round end
	testing.expect_value(t, px(&s, 27, 32), [4]u8{255, 255, 255, 255}) // behind: butt
}

// A canvas allocates from its own allocator, whatever the context's is when
// it first fills, strokes, filters, runs a program or hands a frame over.
@(test)
test_canvas_uses_its_allocator :: proc(t: ^testing.T) {
	own, other: mem.Tracking_Allocator
	mem.tracking_allocator_init(&own, context.allocator)
	defer mem.tracking_allocator_destroy(&own)
	mem.tracking_allocator_init(&other, context.allocator)
	defer mem.tracking_allocator_destroy(&other)
	{
		c: Canvas
		canvas_init_recording(&c, mem.tracking_allocator(&own))
		rec: Recorded_Frame
		red := [4]u8{255, 0, 0, 255}
		prog, _ := create_program(&c, {cpu = test_program_fill, cpu_user = &red})
		src, _ := create_image_empty(&c, 4, 4, .RGBA8, {.Premultiplied})
		dst, _ := create_image_empty(&c, 4, 4, .RGBA8, {.Premultiplied})
		p: Path
		path_circle(&p, 16, 16, 8)
		stroke := paint_color(BLACK)
		stroke.stroke.line_width = 2
		dash := [?]f32{3, 1}
		stroke.stroke.dash = dash[:]
		context.allocator = mem.tracking_allocator(&other)
		for _ in 0 ..< 2 {
			fill_path(&c, &p, paint_color(BLACK))
			stroke_path(&c, &p, stroke)
			filter_image(&c, dst, Gaussian_Blur{sigma = 1}, src)
			run_program(&c, prog, dst, nil)
			canvas_take(&c, &rec)
		}
		testing.expect_value(t, other.total_allocation_count, 0)
		context.allocator = mem.tracking_allocator(&own)
		path_destroy(&p)
		recorded_frame_destroy(&rec)
		canvas_destroy(&c)
	}
	testing.expect_value(t, len(own.allocation_map), 0)
}

// A recording canvas renders nothing to read back.
@(test)
test_recording_screenshot :: proc(t: ^testing.T) {
	c: Canvas
	canvas_init_recording(&c)
	defer canvas_destroy(&c)
	_, err := screenshot(&c)
	testing.expect_value(t, err, Error.Unsupported_Operation)
}

// Small scales are invertible: only a singular matrix falls back to the
// identity.
@(test)
test_transform_inverse_small_scale :: proc(t: ^testing.T) {
	m := transform_scaling(0.001, 0.001)
	inv := transform_inverse(m)
	testing.expect(t, abs(inv[0] - 1000) < 0.01 && abs(inv[3] - 1000) < 0.01)
	testing.expect_value(t, transform_inverse(transform_scaling(0, 1)), TRANSFORM_IDENTITY)
}

// The round half of a mixed-cap dot is a smooth arc: at a large width its
// edge pixels sit on the circle.
@(test)
test_sw_zero_length_round_half_smooth :: proc(t: ^testing.T) {
	s: Sw
	sw_open(&s, 256, 256)
	defer sw_close(&s)
	p: Path
	defer path_destroy(&p)
	path_move_to(&p, 128, 128)
	path_line_to(&p, 128, 128)
	st := paint_color(BLACK)
	st.stroke.line_width = 200
	st.stroke.line_cap_start, st.stroke.line_cap_end = .Square, .Round
	clear_rect(&s.canvas, 0, 0, 256, 256, WHITE)
	stroke_path(&s.canvas, &p, st)
	flush(&s.canvas)
	// On the round side (x > 128), points just inside / outside the radius
	// at 40 degrees, where a 16-sided polygon's chord would cut in.
	inside := Vec2{128, 128} + Vec2{math.cos(f32(0.7)), math.sin(f32(0.7))} * 97
	outside := Vec2{128, 128} + Vec2{math.cos(f32(0.7)), math.sin(f32(0.7))} * 103
	testing.expect_value(t, px(&s, u32(inside.x), u32(inside.y)), [4]u8{0, 0, 0, 255})
	testing.expect_value(t, px(&s, u32(outside.x), u32(outside.y)), [4]u8{255, 255, 255, 255})
	// The square side reaches the corner.
	testing.expect_value(t, px(&s, 35, 35), [4]u8{0, 0, 0, 255})
}
