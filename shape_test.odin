package ovg

import "core:mem"
import "core:slice"
import "core:testing"

import cv "curves"

@(private = "file")
coverage_at :: proc(s: ^Shape, t: Transform2D, x, y: f32, even_odd := false) -> f32 {
	full := transform_multiply(shape_local(s), t)
	return shape_coverage(s.data, transform_point(transform_inverse(full), x, y), shape_ems_per_pixel(full), even_odd)
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
	// each edge pixel's coverage against the area the curves cover. Exact up
	// to the samples' resolution, except that a rotated pixel's coverage is
	// that of the box enclosing it.
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
	for r in "aRg@" {
		g, ok := shape_from_glyph(&font, font_glyph_index(&font, r))
		testing.expect(t, ok)
		defer shape_destroy(&g)
		upright := transform_multiply(transform_scaling(sc, sc), transform_translation(20, 20))
		check(t, &g, upright, 0, 0, 40, 40, 0.01, 0.04)
		rotated := transform_multiply(transform_multiply(transform_scaling(sc, sc), transform_rotation(0.3)), transform_translation(20, 20))
		check(t, &g, rotated, 0, 0, 40, 40, 0.06, 0.3)
	}
	_, ok := shape_from_glyph(&font, font_glyph_index(&font, ' '))
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
