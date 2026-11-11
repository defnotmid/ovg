package ovg

import "core:math"
import "core:testing"

import cv "deps:ocurves"

// A noisy ring: an outer contour of `n` vertices around (0, 0), radius 1,
// with detail far below a thousandth of its size, and with `hole` an inner
// one, radius 0.5, the other way round (or the same way, for even-odd).
@(private = "file")
level_ring :: proc(p: ^Path, n: int, hole: bool, same_way := false) {
	r: u64 = 0x9e3779b97f4a7c15
	noise :: proc(r: ^u64) -> f32 {
		r^ ~= r^ << 13
		r^ ~= r^ >> 7
		r^ ~= r^ << 17
		return f32(r^ >> 40) / f32(1 << 24) - 0.5
	}
	path_reset(p)
	for k in 0 ..< n {
		a := 2 * math.PI * f32(k) / f32(n)
		rr := 1 + 0.0004 * noise(&r) + 0.05 * math.sin(a * 5)
		if k == 0 {
			path_move_to(p, rr * math.cos(a), rr * math.sin(a))
		} else {
			path_line_to(p, rr * math.cos(a), rr * math.sin(a))
		}
	}
	path_close(p)
	if hole {
		for k in 0 ..< n {
			a := 2 * math.PI * f32(k) / f32(n) * (1 if same_way else -1)
			rr := 0.5 + 0.0002 * noise(&r)
			if k == 0 {
				path_move_to(p, rr * math.cos(a), rr * math.sin(a))
			} else {
				path_line_to(p, rr * math.cos(a), rr * math.sin(a))
			}
		}
		path_close(p)
	}
}

// The shape with its levels dropped: what it draws at any scale.
@(private = "file")
level_fine :: proc(s: Shape) -> Shape {
	f := s
	f.level_count = 0
	f.data = s.data[:s.levels[0].at] if s.level_count > 0 else s.data
	return f
}

// A shape with detail far below what it is drawn at keeps coarser levels,
// each with at most a quarter of the curves of the last; one under 12
// curves keeps none. A draw takes the coarsest level within
// SHAPE_LEVEL_PIXELS by the most the transform stretches any way, so a
// squashed, rotated or skewed draw takes what its longest stretch allows.
@(test)
test_shape_levels :: proc(t: ^testing.T) {
	p: Path
	path_init(&p)
	defer path_destroy(&p)
	level_ring(&p, 4096, false)
	s, ok := shape_from_path(&p, search = false)
	testing.expect(t, ok)
	defer shape_destroy(&s)
	testing.expectf(t, s.level_count >= 2, "%d levels", s.level_count)
	own := int(s.levels[0].at)
	last := own
	for k in 0 ..< s.level_count {
		hi := int(s.levels[k + 1].at) if k + 1 < s.level_count else len(s.data)
		words := hi - int(s.levels[k].at)
		testing.expectf(t, words < last / 2, "level %d: %d words after %d", k, words, last)
		testing.expect(t, k == 0 || s.levels[k].err > s.levels[k - 1].err)
		last = words
	}
	testing.expectf(t, len(s.data) - own <= own / 3, "levels %d words on %d", len(s.data) - own, own)

	path_reset(&p)
	path_rect(&p, 0, 0, 4, 4)
	simple, _ := shape_from_path(&p)
	defer shape_destroy(&simple)
	testing.expect_value(t, simple.level_count, 0)

	// The level each scale takes: the coarsest within SHAPE_LEVEL_PIXELS.
	want :: proc(s: ^Shape, stretch: f32) -> int {
		for k := s.level_count - 1; k >= 0; k -= 1 {
			if s.levels[k].err * stretch <= SHAPE_LEVEL_PIXELS {
				return k + 1
			}
		}
		return 0
	}
	for scale in ([?]f32{2000, 200, 60, 20, 4, 1, 0.5}) {
		// Measured: the longest of a unit vector's images, sampled.
		measure :: proc(m: Transform2D) -> f32 {
			most: f32
			for k in 0 ..< 3600 {
				a := f32(k) * math.PI / 1800
				q := transform_point({m[0], m[1], m[2], m[3], 0, 0}, math.cos(a), math.sin(a))
				most = max(most, math.hypot(q.x, q.y))
			}
			return most
		}
		for m in ([?]Transform2D{{scale, 0, 0, scale, 3, 4}, {scale, 0, 0, scale / 125, 0, 0}, transform_multiply({scale, 0, 0, scale, 0, 0}, transform_rotation(0.7)), {scale, 0, scale * 0.6, scale * 0.3, 0, 0}}) {
			_, _, level := shape_level(&s, m)
			stretch := measure(m)
			testing.expectf(t, abs(transform_max_stretch(m) - stretch) <= stretch * 1e-3, "%v: stretch %f, sampled %f", m, transform_max_stretch(m), stretch)
			testing.expectf(t, level == want(&s, stretch) || level == want(&s, stretch * 1.001) || level == want(&s, stretch * 0.999), "%v: level %d, want %d", m, level, want(&s, stretch))
		}
	}
	// Each scale takes the coarsest level it allows, not just one within.
	for k in 0 ..< s.level_count {
		_, _, level := shape_level(&s, {SHAPE_LEVEL_PIXELS / s.levels[k].err, 0, 0, SHAPE_LEVEL_PIXELS / s.levels[k].err, 0, 0})
		testing.expectf(t, level == k + 1, "at level %d's scale: level %d", k + 1, level)
	}
	// Squashed 125 times along one axis, a draw keeps the level its long
	// axis allows: the fine words at 500 across.
	_, _, squashed := shape_level(&s, {500, 0, 0, 4, 0, 0})
	testing.expect_value(t, squashed, want(&s, 500))
}

// Drawn small, a shape's levels lie within SHAPE_LEVEL_PIXELS of it: the
// pixels move by a coverage step or so at edges, and a hole stays a hole,
// with either fill rule; drawn large it draws its own words, pixel for
// pixel. An open contour drawn as a hairline from a level still skips its
// closing edge.
@(test)
test_shape_levels_draw :: proc(t: ^testing.T) {
	p: Path
	path_init(&p)
	defer path_destroy(&p)
	curved := false
	render :: proc(s: ^Shape, scale: f32, rule: Fill_Rule, hairline: f32 = 0) -> []u8 {
		sw: Software_Backend
		software_backend_init(&sw)
		defer software_backend_destroy(&sw)
		c: Canvas
		canvas_init(&c, software_backend(&sw))
		defer canvas_destroy(&c)
		side := u32(scale * 2.4) + 4
		set_size(&c, side, side)
		clear_rect(&c, 0, 0, side, side, WHITE)
		paint := paint_color(BLACK)
		paint.fill_rule = rule
		local := Transform2D{scale, 0, 0, scale, f32(side) / 2, f32(side) / 2}
		if hairline > 0 {
			hairline_shape(&c, s, paint, hairline, local)
		} else {
			fill_shape(&c, s, paint, local)
		}
		flush(&c)
		return slice_clone_u8(sw.pixels[:side * side * 4])
	}
	for rule in ([3]Fill_Rule{.Non_Zero, .Even_Odd, .Non_Zero}) {
		level_ring(&p, 4096, true, rule == .Even_Odd)
		if rule == .Non_Zero && curved {
			// Quadratic pieces whose control points bulge a little past the
			// chord, below and above what the levels may move.
			path_reset(&p)
			for ring in 0 ..< 2 {
				rr: f32 = 1 if ring == 0 else 0.5
				dir: f32 = 1 if ring == 0 else -1
				path_move_to(&p, rr, 0)
				for k in 1 ..= 1024 {
					a0, a1 := dir * 2 * math.PI * (f32(k) - 0.5) / 1024, dir * 2 * math.PI * f32(k) / 1024
					bulge := rr * (1 + (0.002 if k % 3 == 0 else 0.0001))
					path_quad_to(&p, bulge * math.cos(a0), bulge * math.sin(a0), rr * math.cos(a1), rr * math.sin(a1))
				}
				path_close(&p)
			}
		}
		curved = rule == .Even_Odd
		s, _ := shape_from_path(&p, search = false)
		defer shape_destroy(&s)
		testing.expect(t, s.level_count > 0)
		fine := level_fine(s)
		for scale in ([?]f32{30, 400}) {
			a, b := render(&s, scale, rule), render(&fine, scale, rule)
			defer delete(a)
			defer delete(b)
			most := 0
			for v, i in a {
				most = max(most, abs(int(v) - int(b[i])))
			}
			if scale >= 400 {
				testing.expectf(t, most == 0, "%v at %v: %d levels apart", rule, scale, most)
			} else {
				testing.expectf(t, most <= 40, "%v at %v: %d levels apart", rule, scale, most)
			}
			side := int(scale * 2.4) + 4
			centre := (side / 2 * side + side / 2) * 4
			testing.expectf(t, a[centre] == 255, "%v at %v: the hole's centre is %d", rule, scale, a[centre])
		}
	}

	// An open arc, outlined: its closing edge (the chord across) is skipped
	// at every level.
	path_reset(&p)
	for k in 0 ..= 3000 {
		a := math.PI * f32(k) / 3000
		r := 1 + 0.0004 * math.sin(f32(k) * 1.7)
		if k == 0 {
			path_move_to(&p, r * math.cos(a), -r * math.sin(a))
		} else {
			path_line_to(&p, r * math.cos(a), -r * math.sin(a))
		}
	}
	arc, _ := shape_from_path(&p, search = false, outline = true)
	defer shape_destroy(&arc)
	testing.expect(t, arc.level_count > 0)
	for scale in ([?]f32{30, 100}) {
		a := render(&arc, scale, .Non_Zero, 1)
		defer delete(a)
		side := int(scale * 2.4) + 4
		// The chord runs along y = 0 between the arc's ends; its middle.
		mid := (side / 2 * side + side / 2) * 4
		testing.expectf(t, a[mid] == 255, "at %v the chord shows: %d", scale, a[mid])
	}
}

// Shapes built for one frame (filled paths, strokes, a layout's glyphs)
// keep no levels: their words are their own.
@(test)
test_shape_levels_frame :: proc(t: ^testing.T) {
	p: Path
	path_init(&p)
	defer path_destroy(&p)
	level_ring(&p, 4096, false)
	kept, _ := shape_from_path(&p, search = false)
	defer shape_destroy(&kept)
	testing.expect(t, kept.level_count > 0)
	sw: Software_Backend
	software_backend_init(&sw)
	defer software_backend_destroy(&sw)
	c: Canvas
	canvas_init(&c, software_backend(&sw))
	defer canvas_destroy(&c)
	set_size(&c, 16, 16)
	translate(&c, 8, 8)
	scale(&c, 4, 4)
	fill_path(&c, &p, paint_color(BLACK))
	testing.expect_value(t, len(c.shapes), 1)
	// The same curves built alone: the frame holds just their words.
	b: Shape_Builder
	defer shape_builder_destroy(&b)
	b.tol = 1.0 / 16
	shape_add_path(&b, &p, state(&c).transform)
	alone: [dynamic]u32
	defer delete(alone)
	_, _, built := cv.build_append(&b, &alone, search = false)
	testing.expect(t, built)
	testing.expect_value(t, len(c.shape_words), len(alone))
	if len(c.shapes) == 1 {
		testing.expect(t, c.shapes[0].shape == nil)
		testing.expect_value(t, len(instance_words(c.shapes[0], c.shape_words[:])), len(c.shape_words))
	}
	flush(&c)
}

// A layer counts the words its instances draw: copies of a detailed shape
// group when drawn small (their coarse levels few words) and take a pass
// of their own drawn large.
@(test)
test_shape_levels_layer :: proc(t: ^testing.T) {
	p: Path
	path_init(&p)
	defer path_destroy(&p)
	level_ring(&p, 4096, false)
	s, _ := shape_from_path(&p, search = false)
	defer shape_destroy(&s)
	own := int(s.levels[0].at)
	copies := LAYER_GROUP_MAX_WORDS / own + 1
	sw: Software_Backend
	software_backend_init(&sw)
	defer software_backend_destroy(&sw)
	c: Canvas
	canvas_init(&c, software_backend(&sw))
	defer canvas_destroy(&c)
	ls: Layer_Stack
	defer layer_stack_destroy(&ls, &c)
	for scale in ([2]f32{100, 2}) {
		set_size(&c, 64, 64)
		layer_stack_begin(&ls, &c, 64, 64)
		layer_push(&ls, &c, {opacity = 0.5})
		for _ in 0 ..< copies {
			fill_shape(&c, &s, paint_color(BLACK), {scale, 0, 0, scale, 32, 32})
		}
		words := 0
		for inst in c.shapes {
			words += len(instance_words(inst, c.shape_words[:]))
		}
		layer_pop(&ls, &c)
		layer_stack_end(&ls, &c)
		grouped := false
		for cmd in c.commands {
			if d, is_shapes := cmd.type.(Cmd_Draw_Shapes); is_shapes && d.group != 0 {
				grouped = true
			}
		}
		testing.expectf(t, grouped == (scale < 10), "at %v: %d words, grouped %v", scale, words, grouped)
		flush(&c)
	}
}

@(private = "file")
slice_clone_u8 :: proc(b: []u8) -> []u8 {
	out := make([]u8, len(b))
	copy(out, b)
	return out
}

// Every level lies within its error of the shape, checked on two rings
// whose edges are known: points farther than a level's error (and the
// noise) inside and outside the edge, at every angle, fall inside and
// outside the level as they do the shape. The wavy ring's lines go; the
// round one's 32 quadratic arcs bulge about 2.5 times the finest error
// from their chords, so its levels keep them curved while the noisy
// lines between them go.
@(test)
test_shape_levels_error :: proc(t: ^testing.T) {
	p: Path
	path_init(&p)
	defer path_destroy(&p)
	inside :: proc(s: ^Shape, words: []u32, q: Vec2) -> bool {
		return cv.fill_inside(cv.winding(words, (q - s.origin) / s.extent), .Non_Zero)
	}
	for ring in 0 ..< 2 {
		edge: proc(a: f32) -> f32
		noise: f32
		if ring == 0 {
			level_ring(&p, 4096, false)
			edge, noise = proc(a: f32) -> f32 {return 1 + 0.05 * math.sin(a * 5)}, 0.0004
		} else {
			path_reset(&p)
			STEP :: 2 * math.PI / 32
			path_move_to(&p, 1, 0)
			for k in 0 ..< 32 {
				a0 := f32(k) * STEP
				// An arc of 0.8 of the step, then 40 short noisy lines.
				half: f32 = 0.4 * STEP
				cr := 1 / math.cos(half)
				path_quad_to(&p, cr * math.cos(a0 + half), cr * math.sin(a0 + half), math.cos(a0 + 2 * half), math.sin(a0 + 2 * half))
				for j in 1 ..= 40 {
					a := a0 + 2 * half + 0.2 * STEP * f32(j) / 40
					r: f32 = 1 + (0.0001 if j % 2 == 0 else 0) if j < 40 else 1
					path_line_to(&p, r * math.cos(a), r * math.sin(a))
				}
			}
			path_close(&p)
			edge, noise = proc(a: f32) -> f32 {return 1}, 0.0002
		}
		s, _ := shape_from_path(&p, search = false)
		defer shape_destroy(&s)
		testing.expectf(t, s.level_count > 0, "ring %d: no levels", ring)
		own := s.data[:s.levels[0].at] if s.level_count > 0 else s.data
		for k in 0 ..< s.level_count {
			hi := s.levels[k + 1].at if k + 1 < s.level_count else u32(len(s.data))
			words := s.data[s.levels[k].at:hi]
			// The wavy edge's slope is at most 0.25, so a radial step is at
			// least 0.97 of the distance to it: 1.2 times the error clears it.
			d := 1.2 * s.levels[k].err * s.extent + noise
			wrong, checked := 0, 0
			for j in 0 ..< 4096 {
				a := 2 * math.PI * (f32(j) + 0.25) / 4096
				r := edge(a)
				dir := Vec2{math.cos(a), math.sin(a)}
				outer, inner := dir * (r + d), dir * (r - d)
				if inside(&s, own, outer) || !inside(&s, own, inner) {
					continue
				}
				checked += 1
				if inside(&s, words, outer) || !inside(&s, words, inner) {
					wrong += 1
				}
			}
			testing.expectf(t, checked == 4096 && wrong == 0, "ring %d level %d (error %v): %d of %d angles on the wrong side", ring, k + 1, s.levels[k].err, wrong, checked)
		}
	}
}
