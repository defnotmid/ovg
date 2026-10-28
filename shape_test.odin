package ovg

import "core:math"
import "core:mem"
import "core:slice"
import "core:testing"

import cv "deps:ocurves"
import ft "deps:oglyph/font"

@(private = "file")
coverage_at :: proc(s: ^Shape, t: Transform2D, x, y: f32, even_odd := false) -> f32 {
	full := transform_multiply(shape_local(s), t)
	u, v := shape_footprint(full)
	return shape_coverage(s.data, transform_point(transform_inverse(full), x, y), u, v, even_odd)
}

// Area of the pixel at (x, y) the shape covers, from 32x32 winding samples.
@(private = "file")
area_at :: proc(s: ^Shape, t: Transform2D, x, y: f32) -> f32 {
	full := transform_multiply(shape_local(s), t)
	inv := transform_inverse(full)
	N :: 32
	inside := 0
	for sy in 0 ..< N {
		for sx in 0 ..< N {
			p := transform_point(inv, x - 0.5 + (f32(sx) + 0.5) / N, y - 0.5 + (f32(sy) + 0.5) / N)
			inside += int(cv.winding(s.data, p) != 0)
		}
	}
	return f32(inside) / (N * N)
}

@(test)
test_shape_square :: proc(t: ^testing.T) {
	p: Path
	defer path_destroy(&p)
	path_rect(&p, 10.3, 10.3, 10.4, 10.4)
	s, ok := shape_from_path(&p)
	defer shape_destroy(&s)
	testing.expect(t, ok)
	id := TRANSFORM_IDENTITY
	near :: proc(a, b: f32) -> bool {return abs(a - b) < 1e-3}
	testing.expect(t, near(coverage_at(&s, id, 15.5, 15.5), 1))
	testing.expect(t, near(coverage_at(&s, id, 9.5, 15.5), 0))
	// Edges: the part of the pixel inside.
	testing.expect(t, near(coverage_at(&s, id, 10.5, 15.5), 0.7))
	testing.expect(t, near(coverage_at(&s, id, 15.5, 20.5), 0.7))
	testing.expect(t, near(coverage_at(&s, id, 20.5, 15.5), 0.7))
	// Under a scale and a translation the edge moves with the shape.
	tr := Transform2D{2, 0, 0, 2, 0.25, 0}
	testing.expect(t, near(coverage_at(&s, tr, 20.85, 30.5), 0.5))
}

@(test)
test_shape_fill_rules :: proc(t: ^testing.T) {
	// Two squares wound the same way: the inner one is a hole only under
	// even-odd.
	p: Path
	defer path_destroy(&p)
	path_rect(&p, 0, 0, 30, 30)
	path_rect(&p, 10, 10, 10, 10)
	s, _ := shape_from_path(&p)
	defer shape_destroy(&s)
	id := TRANSFORM_IDENTITY
	testing.expect(t, abs(coverage_at(&s, id, 15.5, 15.5) - 1) < 1e-3)
	testing.expect(t, coverage_at(&s, id, 15.5, 15.5, true) < 1e-3)
	testing.expect(t, abs(coverage_at(&s, id, 5.5, 15.5, true) - 1) < 1e-3)
}

@(test)
test_shape_quadratics_kept :: proc(t: ^testing.T) {
	// path_quad_to stores raised cubics: they come back as one quadratic.
	p: Path
	defer path_destroy(&p)
	path_move_to(&p, 0, 0)
	path_quad_to(&p, 10, 20, 20, 0)
	path_quad_to(&p, 10, -20, 0, 0)
	b: Shape_Builder
	defer shape_builder_destroy(&b)
	shape_add_path(&b, &p)
	testing.expect_value(t, len(b.curves), 2)
	testing.expect_value(t, b.curves[0], Shape_Curve{{0, 0}, {10, 20}, {20, 0}})
}

@(test)
test_shape_curves_match_area :: proc(t: ^testing.T) {
	// A circle (cubics, split into quadratics), upright and rotated glyphs:
	// each edge pixel's coverage against the area the curves cover, exact up
	// to the samples' resolution.
	check :: proc(t: ^testing.T, s: ^Shape, tr: Transform2D, x0, y0, x1, y1: int, mean_max, max_max: f32) {
		sum, worst: f32
		n := 0
		for y in y0 ..< y1 {
			for x in x0 ..< x1 {
				c := coverage_at(s, tr, f32(x) + 0.5, f32(y) + 0.5)
				a := area_at(s, tr, f32(x) + 0.5, f32(y) + 0.5)
				if (a <= 0 && c <= 0) || (a >= 1 && c >= 1) {
					continue
				}
				sum += abs(c - a)
				worst = max(worst, abs(c - a))
				n += 1
			}
		}
		testing.expect(t, n > 0)
		testing.expectf(t, sum / f32(n) < mean_max, "mean error %v over %v edge pixels", sum / f32(n), n)
		testing.expectf(t, worst < max_max, "worst error %v", worst)
	}

	p: Path
	defer path_destroy(&p)
	path_circle(&p, 20, 20, 15.3)
	circle, _ := shape_from_path(&p)
	defer shape_destroy(&circle)
	check(t, &circle, TRANSFORM_IDENTITY, 2, 2, 38, 38, 0.01, 0.04)

	font, err := font_load(DEFAULT_FONT_DATA)
	testing.expect_value(t, err, Error.None)
	defer font_destroy(&font)
	sc := font_scale_for_em(&font, 14)
	o: ft.Outline
	defer ft.outline_destroy(&o)
	for r in "aRg@" {
		g, ok := shape_from_glyph(&font, font_glyph_index(&font, r), &o)
		testing.expect(t, ok)
		defer shape_destroy(&g)
		upright := transform_multiply(transform_scaling(sc, sc), transform_translation(20, 20))
		check(t, &g, upright, 0, 0, 40, 40, 0.01, 0.04)
		rotated := transform_multiply(transform_multiply(transform_scaling(sc, sc), transform_rotation(0.3)), transform_translation(20, 20))
		check(t, &g, rotated, 0, 0, 40, 40, 0.01, 0.04)
	}
	_, ok := shape_from_glyph(&font, font_glyph_index(&font, ' '), &o)
	testing.expect(t, !ok)
}

@(test)
test_sw_fill_shape :: proc(t: ^testing.T) {
	b: Software_Backend
	software_backend_init(&b)
	defer software_backend_destroy(&b)
	c: Canvas
	canvas_init(&c, software_backend(&b))
	defer canvas_destroy(&c)
	set_size(&c, 40, 20)
	clear_rect(&c, 0, 0, 40, 20, WHITE)

	p: Path
	defer path_destroy(&p)
	path_rect(&p, 0, 0, 10, 10)
	s, _ := shape_from_path(&p)
	defer shape_destroy(&s)
	fill_shape(&c, &s, paint_color(rgb(255, 0, 0)), transform_translation(2, 5))
	fill_shape(&c, &s, paint_color(rgb(0, 0, 255)), transform_translation(22.5, 5))
	// Both instances share one command, each with its own paint row.
	if d, ok := c.commands[len(c.commands) - 1].type.(Cmd_Draw_Shapes); testing.expect(t, ok) {
		testing.expect_value(t, d.instances.count, 2)
	}
	flush(&c)

	at :: proc(b: ^Software_Backend, x, y: int) -> [4]u8 {
		i := (y * int(b.width) + x) * 4
		return {b.pixels[i], b.pixels[i + 1], b.pixels[i + 2], b.pixels[i + 3]}
	}
	testing.expect_value(t, at(&b, 6, 9), [4]u8{255, 0, 0, 255})
	testing.expect_value(t, at(&b, 1, 9), [4]u8{255, 255, 255, 255})
	testing.expect_value(t, at(&b, 27, 9), [4]u8{0, 0, 255, 255})
	// Half the pixel at x = 22 is inside the second square.
	half := at(&b, 22, 9)
	testing.expectf(t, abs(int(half[0]) - 128) <= 1 && half[0] == half[1] && half[2] == 255, "half-covered pixel %v", half)
}

@(test)
test_shape_tolerance :: proc(t: ^testing.T) {
	// A quarter circle of radius 1000 as one cubic. Built within 1/1000 of
	// a unit, points 1/500 of a unit either side of it fall on their sides
	// (as a shape magnified 500x must); within the default 1/4096 of its
	// size some do not.
	k :: 0.5522847498
	pts := [4]Vec2{{1000, 0}, {1000, 1000 * k}, {1000 * k, 1000}, {0, 1000}}
	p: Path
	path_init(&p)
	defer path_destroy(&p)
	path_move_to(&p, 0, 0)
	path_line_to(&p, pts[0].x, pts[0].y)
	path_bezier_to(&p, pts[1].x, pts[1].y, pts[2].x, pts[2].y, pts[3].x, pts[3].y)
	path_close(&p)
	wrong :: proc(s: ^Shape, pts: [4]Vec2) -> (n: int) {
		for i in 1 ..< 100 {
			a := f32(i) / 100
			b := 1 - a
			q := b * b * b * pts[0] + 3 * b * b * a * pts[1] + 3 * b * a * a * pts[2] + a * a * a * pts[3]
			// Nearly the normal: the cubic is nearly the circle.
			out := q / math.hypot(q.x, q.y) * 0.002
			if cv.winding(s.data, (q - out - s.origin) / s.extent) == 0 {
				n += 1
			}
			if cv.winding(s.data, (q + out - s.origin) / s.extent) != 0 {
				n += 1
			}
		}
		return
	}
	fine, ok := shape_from_path(&p, tol = 0.001)
	testing.expect(t, ok)
	defer shape_destroy(&fine)
	coarse, _ := shape_from_path(&p)
	defer shape_destroy(&coarse)
	testing.expect_value(t, wrong(&fine, pts), 0)
	testing.expect(t, wrong(&coarse, pts) > 0)
	// A stroke's outline too: 5 units either side of the cubic (along its
	// normal, away from the joins), 1/500 of a unit in is in, out is out.
	st := DEFAULT_STROKE
	st.line_width = 10
	stroke, sok, _ := shape_from_stroke(&p, st, tol = 0.001)
	testing.expect(t, sok)
	defer shape_destroy(&stroke)
	off := 0
	for i in 5 ..< 96 {
		a := f32(i) / 100
		b := 1 - a
		q := b * b * b * pts[0] + 3 * b * b * a * pts[1] + 3 * b * a * a * pts[2] + a * a * a * pts[3]
		d := 3 * b * b * (pts[1] - pts[0]) + 6 * b * a * (pts[2] - pts[1]) + 3 * a * a * (pts[3] - pts[2])
		n := Vec2{d.y, -d.x} / math.hypot(d.x, d.y)
		for side in ([2]f32{-1, 1}) {
			edge := q + n * (5 * side)
			if cv.winding(stroke.data, (edge - n * (0.002 * side) - stroke.origin) / stroke.extent) == 0 {
				off += 1
			}
			if cv.winding(stroke.data, (edge + n * (0.002 * side) - stroke.origin) / stroke.extent) != 0 {
				off += 1
			}
		}
	}
	testing.expect_value(t, off, 0)
}

@(test)
test_sw_fill_shapes :: proc(t: ^testing.T) {
	// One shape at many places, one paint row: the pixels fill_shape draws
	// at each (the one off the target skipped).
	draw :: proc(batch: bool) -> (pixels: []u8, paints, instances: int) {
		b: Software_Backend
		software_backend_init(&b)
		defer software_backend_destroy(&b)
		c: Canvas
		canvas_init(&c, software_backend(&b))
		defer canvas_destroy(&c)
		set_size(&c, 40, 20)
		clear_rect(&c, 0, 0, 40, 20, WHITE)
		p: Path
		defer path_destroy(&p)
		path_circle(&p, 0, 0, 3)
		s, _ := shape_from_path(&p)
		defer shape_destroy(&s)
		locals := [?]Transform2D{transform_translation(5, 5), transform_translation(12.5, 9.25), transform_multiply(transform_scaling(2, 1), transform_translation(30, 12)), transform_translation(80, 5)}
		translate(&c, 1, 0)
		paint := paint_color(rgb(0, 0, 255))
		if batch {
			fill_shapes(&c, &s, paint, locals[:])
		} else {
			for l in locals {
				fill_shape(&c, &s, paint, l)
			}
		}
		paints, instances = len(c.paints), len(c.shapes)
		flush(&c)
		return slice.clone(b.pixels), paints, instances
	}
	one, one_paints, one_instances := draw(false)
	defer delete(one)
	many, paints, instances := draw(true)
	defer delete(many)
	testing.expect_value(t, one_instances, 3)
	testing.expect_value(t, one_paints, 3)
	testing.expect_value(t, instances, 3)
	testing.expect_value(t, paints, 1)
	testing.expect(t, slice.equal(one, many))
}

@(test)
test_sw_hairline_shape :: proc(t: ^testing.T) {
	b: Software_Backend
	software_backend_init(&b)
	defer software_backend_destroy(&b)
	c: Canvas
	canvas_init(&c, software_backend(&b))
	defer canvas_destroy(&c)
	set_size(&c, 60, 40)
	clear_rect(&c, 0, 0, 60, 40, WHITE)
	at :: proc(b: ^Software_Backend, x, y: int) -> u8 {
		return b.pixels[(y * int(b.width) + x) * 4]
	}
	// An open L (its closing edge fills, not drawn), magnified 4x: the
	// hairline stays 1 px, centered on the lines x = 10.5 and y = 30.5.
	p: Path
	defer path_destroy(&p)
	path_move_to(&p, 2.5, 1.25)
	path_line_to(&p, 2.5, 7.5)
	path_line_to(&p, 12.5, 7.5)
	s, ok := shape_from_path(&p, outline = true)
	testing.expect(t, ok)
	defer shape_destroy(&s)
	plain, _ := shape_from_path(&p)
	defer shape_destroy(&plain)
	m := transform_multiply(transform_scaling(4, 4), transform_translation(0.5, 0.5))
	hairline_shape(&c, &s, paint_color(rgb(0, 0, 0)), 1, m)
	// Without an outline nothing draws.
	hairline_shape(&c, &plain, paint_color(rgb(0, 0, 0)), 1, transform_translation(5, 0))
	flush(&c)
	testing.expect_value(t, at(&b, 10, 20), 0)
	testing.expect_value(t, at(&b, 30, 30), 0)
	testing.expect_value(t, at(&b, 9, 20), 255)
	testing.expect_value(t, at(&b, 11, 20), 255)
	testing.expect_value(t, at(&b, 30, 29), 255)
	// The closing edge, from (10.5, 5.5) to (50.5, 30.5), is not drawn.
	testing.expect_value(t, at(&b, 30, 18), 255)
	testing.expect_value(t, at(&b, 15, 20), 255)
	testing.expect_value(t, at(&b, 50, 20), 255)
}

@(test)
test_sw_fill_markers :: proc(t: ^testing.T) {
	b: Software_Backend
	software_backend_init(&b)
	defer software_backend_destroy(&b)
	c: Canvas
	canvas_init(&c, software_backend(&b))
	defer canvas_destroy(&c)
	set_size(&c, 60, 30)
	clear_rect(&c, 0, 0, 60, 30, WHITE)
	at :: proc(b: ^Software_Backend, x, y: int) -> [4]u8 {
		i := (y * int(b.width) + x) * 4
		return {b.pixels[i], b.pixels[i + 1], b.pixels[i + 2], b.pixels[i + 3]}
	}
	// Two circles overlapping (one batch: one group, one paint row), the
	// scale of the transform not changing their size, and an outlined
	// square; the marker off the target is left out.
	scale(&c, 2, 2)
	points := [?]Vec2{{6.25, 7.5}, {8.75, 7.5}, {100, 100}}
	paints := len(c.paints)
	fill_markers(&c, .Circle, 5, 0, paint_color(rgb(0, 0, 255)), points[:])
	testing.expect_value(t, len(c.paints) - paints, 1)
	if d, ok := c.commands[len(c.commands) - 1].type.(Cmd_Draw_Shapes); testing.expect(t, ok) {
		testing.expect_value(t, d.instances.count, 2)
		testing.expect(t, d.group != 0)
	}
	reset_transform(&c)
	fill_markers(&c, .Square, 6, 2, paint_color(rgb(255, 0, 0)), []Vec2{{45, 15}})
	flush(&c)
	// Inside the circles, and where they overlap: blue once, not twice.
	testing.expect_value(t, at(&b, 12, 15), [4]u8{0, 0, 255, 255})
	testing.expect_value(t, at(&b, 15, 15), [4]u8{0, 0, 255, 255})
	testing.expect_value(t, at(&b, 30, 15), [4]u8{255, 255, 255, 255})
	// The square, radius 6 around (45, 15), outlined 2 px on its edge: 5 to
	// 7 px from its center red, its inside and outside white.
	testing.expect_value(t, at(&b, 39, 15), [4]u8{255, 0, 0, 255})
	testing.expect_value(t, at(&b, 45, 15), [4]u8{255, 255, 255, 255})
	testing.expect_value(t, at(&b, 36, 15), [4]u8{255, 255, 255, 255})
}

@(test)
test_sw_draw_markers :: proc(t: ^testing.T) {
	b: Software_Backend
	software_backend_init(&b)
	defer software_backend_destroy(&b)
	c: Canvas
	canvas_init(&c, software_backend(&b))
	defer canvas_destroy(&c)
	set_size(&c, 60, 30)
	clear_rect(&c, 0, 0, 60, 30, rgb(128, 128, 128))
	at :: proc(b: ^Software_Backend, x, y: int) -> [4]u8 {
		i := (y * int(b.width) + x) * 4
		return {b.pixels[i], b.pixels[i + 1], b.pixels[i + 2], b.pixels[i + 3]}
	}
	// Squares filled white and outlined blue 2 px in one call (one group,
	// two paint rows): every outline over every fill, the second square's
	// outline over the first's fill where they overlap.
	paints := len(c.paints)
	draw_markers(&c, .Square, 6, 2, paint_color(rgb(255, 255, 255)), paint_color(rgb(0, 0, 255)), []Vec2{{12, 15}, {20, 15}})
	testing.expect_value(t, len(c.paints) - paints, 2)
	if d, ok := c.commands[len(c.commands) - 1].type.(Cmd_Draw_Shapes); testing.expect(t, ok) {
		testing.expect_value(t, d.instances.count, 2)
	}
	// Outlined only (a handle circle).
	draw_markers(&c, .Circle, 5, 2, nil, paint_color(rgb(255, 0, 0)), []Vec2{{45, 15}})
	flush(&c)
	WHITE_ :: [4]u8{255, 255, 255, 255}
	BLUE_ :: [4]u8{0, 0, 255, 255}
	GREY :: [4]u8{128, 128, 128, 255}
	testing.expect_value(t, at(&b, 10, 15), WHITE_)
	// x 14: the second square's outline (5 to 7 px left of 20.5 .. 20) over
	// the first's fill.
	testing.expect_value(t, at(&b, 14, 15), BLUE_)
	testing.expect_value(t, at(&b, 6, 15), BLUE_)
	testing.expect_value(t, at(&b, 22, 15), WHITE_)
	testing.expect_value(t, at(&b, 3, 15), GREY)
	// The ring is red (its corner here just outside the circle), its inside
	// the background.
	ring := at(&b, 39, 15)
	testing.expectf(t, ring[0] >= 250 && ring[1] <= 5 && ring[2] <= 5, "ring %v", ring)
	testing.expect_value(t, at(&b, 45, 15), GREY)
}

@(test)
test_font_glyph_shape :: proc(t: ^testing.T) {
	font, _ := font_load(DEFAULT_FONT_DATA)
	defer font_destroy(&font)
	a := font_glyph_shape(&font, font_glyph_index(&font, 'a'))
	testing.expect(t, a != nil)
	// Built once, then the same shape.
	testing.expect_value(t, font_glyph_shape(&font, font_glyph_index(&font, 'a')), a)
	testing.expect(t, font_glyph_shape(&font, font_glyph_index(&font, ' ')) == nil)
	// Shape units to font units (y down): 'a' sits on the baseline.
	_, _, _, y1 := shape_bounds(a)
	testing.expect(t, abs(transform_point(shape_local(a), 0, y1).y) < 40)
}

@(test)
test_shape_solidity :: proc(t: ^testing.T) {
	// The inner square is drawn the same way round as the outer one, then
	// declared a hole: under non-zero it cuts out, as with fill_path.
	p: Path
	defer path_destroy(&p)
	path_rect(&p, 0, 0, 30, 30)
	path_rect(&p, 10, 10, 10, 10)
	path_solidity(&p, .Hole)
	s, _ := shape_from_path(&p)
	defer shape_destroy(&s)
	testing.expect(t, coverage_at(&s, TRANSFORM_IDENTITY, 15.5, 15.5) < 1e-3)
	testing.expect(t, abs(coverage_at(&s, TRANSFORM_IDENTITY, 5.5, 15.5) - 1) < 1e-3)
}

@(test)
test_font_shapes_own_allocator :: proc(t: ^testing.T) {
	// The first glyph is built under a short-lived arena: the font's shapes
	// still come from the font's allocator, and survive the arena.
	font, _ := font_load(DEFAULT_FONT_DATA)
	defer font_destroy(&font)
	buf := make([]u8, 1 << 16)
	defer delete(buf)
	arena: mem.Arena
	mem.arena_init(&arena, buf)
	g := font_glyph_index(&font, 'g')
	s: ^Shape
	{
		context.allocator = mem.arena_allocator(&arena)
		s = font_glyph_shape(&font, g)
	}
	testing.expect(t, s != nil)
	inside :: proc(p: rawptr, buf: []u8) -> bool {
		return uintptr(p) >= uintptr(raw_data(buf)) && uintptr(p) < uintptr(raw_data(buf)) + uintptr(len(buf))
	}
	testing.expect(t, !inside(s, buf) && !inside(raw_data(s.data), buf) && !inside(font.shapes, buf))
	// The arena's memory is reused: drawing still sees the shape intact.
	free_all(mem.arena_allocator(&arena))
	mem.set(raw_data(buf), 0xAA, len(buf))

	b: Software_Backend
	software_backend_init(&b)
	defer software_backend_destroy(&b)
	c: Canvas
	canvas_init(&c, software_backend(&b))
	defer canvas_destroy(&c)
	set_size(&c, 40, 40)
	clear_rect(&c, 0, 0, 40, 40, WHITE)
	sc := font_scale_for_em(&font, 30)
	fill_glyph_outlines(&c, &font, {{g, 8, 26}}, sc, paint_color(BLACK), nil)
	flush(&c)
	drawn := slice.clone(b.pixels)
	defer delete(drawn)

	fresh, _ := font_load(DEFAULT_FONT_DATA)
	defer font_destroy(&fresh)
	clear_rect(&c, 0, 0, 40, 40, WHITE)
	fill_glyph_outlines(&c, &fresh, {{g, 8, 26}}, sc, paint_color(BLACK), nil)
	flush(&c)
	testing.expect(t, string(drawn) == string(b.pixels))
	dark := 0
	for k := 0; k < len(drawn); k += 4 {
		dark += int(drawn[k] < 128)
	}
	testing.expect(t, dark > 30)
}

@(test)
test_translucent_text_fills_as_one :: proc(t: ^testing.T) {
	// Overlapping glyphs (negative spacing), drawn translucent three ways
	// (global alpha, a translucent colour, a translucent gradient): each must
	// equal the run drawn opaque and composited at that alpha, with no
	// darker overlaps.
	font, _ := font_load(DEFAULT_FONT_DATA)
	defer font_destroy(&font)
	sc := font_scale_for_em(&font, 40)
	glyphs: [dynamic]Positioned_Glyph
	defer delete(glyphs)
	x: f32 = 4
	for r in "OVERLAP" {
		g := font_glyph_index(&font, r)
		append(&glyphs, Positioned_Glyph{g, x, 40})
		adv, _ := font_glyph_advance(&font, g)
		x += f32(adv) * sc - 12
	}
	W, H :: 180, 56
	b: Software_Backend
	software_backend_init(&b)
	defer software_backend_destroy(&b)
	c: Canvas
	canvas_init(&c, software_backend(&b))
	defer canvas_destroy(&c)
	set_size(&c, W, H)

	// The opaque run on transparent: its alpha is the run's coverage.
	clear_rect(&c, 0, 0, W, H, TRANSPARENT)
	fill_glyph_outlines(&c, &font, glyphs[:], sc, paint_color(WHITE), nil)
	flush(&c)
	cover := make([]f32, W * H)
	defer delete(cover)
	for i in 0 ..< W * H {
		cover[i] = f32(b.pixels[i * 4 + 3]) / 255
	}
	bg := Color{0.06, 0.08, 0.1, 1}
	check :: proc(t: ^testing.T, b: ^Software_Backend, cover: []f32, bg: Color, a: f32, name: string) {
		worst := 0
		for i in 0 ..< len(cover) {
			k := cover[i] * a
			want := [3]f32{bg.r + (1 - bg.r) * k, bg.g + (1 - bg.g) * k, bg.b + (1 - bg.b) * k}
			for ch in 0 ..< 3 {
				worst = max(worst, abs(int(b.pixels[i * 4 + ch]) - int(want[ch] * 255 + 0.5)))
			}
		}
		testing.expectf(t, worst <= 2, "%v: off by %v from the opaque run at alpha %v", name, worst, a)
	}

	clear_rect(&c, 0, 0, W, H, bg)
	set_global_alpha(&c, 0.5)
	fill_glyph_outlines(&c, &font, glyphs[:], sc, paint_color(WHITE), nil)
	set_global_alpha(&c, 1)
	flush(&c)
	check(t, &b, cover, bg, 0.5, "global alpha")

	clear_rect(&c, 0, 0, W, H, bg)
	fill_glyph_outlines(&c, &font, glyphs[:], sc, paint_color({1, 1, 1, 0.5}), nil)
	flush(&c)
	check(t, &b, cover, bg, 0.5, "translucent colour")

	clear_rect(&c, 0, 0, W, H, bg)
	fill_glyph_outlines(&c, &font, glyphs[:], sc, paint_linear_gradient(0, 0, W, 0, {1, 1, 1, 0.5}, {1, 1, 1, 0.5}), nil)
	flush(&c)
	check(t, &b, cover, bg, 0.5, "translucent gradient")

	// The glyphs do overlap: drawn one by one they darken there.
	clear_rect(&c, 0, 0, W, H, bg)
	for g in glyphs {
		fill_glyph_outlines(&c, &font, {g}, sc, paint_color({1, 1, 1, 0.5}), nil)
	}
	flush(&c)
	brighter := 0
	for i in 0 ..< W * H {
		want := bg.r + (1 - bg.r) * cover[i] * 0.5
		brighter += int(int(b.pixels[i * 4]) > int(want * 255 + 0.5) + 8)
	}
	testing.expect(t, brighter > 20)
}

@(test)
test_winding_matches_coverage :: proc(t: ^testing.T) {
	// At points well away from edges, the winding number (sample masks) and
	// coverage at a tiny footprint agree.
	font, _ := font_load(DEFAULT_FONT_DATA)
	defer font_destroy(&font)
	for r in "aeg@&%B8" {
		s := font_glyph_shape(&font, font_glyph_index(&font, r))
		testing.expect(t, s != nil)
		_, _, x1, y1 := shape_bounds(s)
		disagree := 0
		for gy in 0 ..< 97 {
			for gx in 0 ..< 97 {
				p := Vec2{(f32(gx) + 0.5) / 97 * x1, (f32(gy) + 0.5) / 97 * y1}
				inside := cv.winding(s.data, p) != 0
				crisp := cv.coverage(s.data, p, {1e-6, 1e-6}, false) > 0.5
				disagree += int(inside != crisp)
			}
		}
		testing.expectf(t, disagree == 0, "'%c': %v of 97x97 points disagree", r, disagree)
	}
}

@(test)
test_shape_from_stroke :: proc(t: ^testing.T) {
	// A line 4 wide, butt caps: covered within 2 of the line, not past
	// its ends or beyond its width.
	p: Path
	defer path_destroy(&p)
	path_move_to(&p, 10, 10)
	path_line_to(&p, 50, 10)
	st := DEFAULT_STROKE
	st.line_width = 4
	s, ok, complete := shape_from_stroke(&p, st)
	testing.expect(t, ok && complete)
	defer shape_destroy(&s)
	inside :: proc(s: ^Shape, x, y: f32) -> bool {
		return cv.winding(s.data, (Vec2{x, y} - s.origin) / s.extent) != 0
	}
	testing.expect(t, inside(&s, 30, 10) && inside(&s, 30, 11.5) && inside(&s, 11, 9))
	testing.expect(t, !inside(&s, 30, 12.5) && !inside(&s, 8, 10) && !inside(&s, 52, 10))
}
