package ovg

import "core:slice"
import "core:testing"

@(private = "file")
Mo :: struct {
	backend: Software_Backend,
	canvas:  Canvas,
	layers:  Layer_Stack,
	path:    Path,
}

@(private = "file")
mo_open :: proc(s: ^Mo, w, h: u32) {
	software_backend_init(&s.backend)
	canvas_init(&s.canvas, software_backend(&s.backend))
	canvas_motion_blur(&s.canvas, true)
	set_size(&s.canvas, w, h)
}

@(private = "file")
mo_close :: proc(s: ^Mo) {
	path_destroy(&s.path)
	layer_stack_destroy(&s.layers, &s.canvas)
	canvas_destroy(&s.canvas)
	software_backend_destroy(&s.backend)
}

@(private = "file")
mo_rect :: proc(s: ^Mo, x, y, w, h: f32, col: Color) {
	path_reset(&s.path)
	path_rect(&s.path, x, y, w, h)
	fill_path(&s.canvas, &s.path, paint_color(col))
}

// The velocity and nearness at pixel (x, y) of the last frame.
@(private = "file")
mo_at :: proc(s: ^Mo, x, y: int) -> (Vec2, f32) {
	v, n := software_backend_velocity(&s.backend)
	i := y * int(s.backend.width) + x
	return v[i], n[i]
}

// A draw's velocity is its motion's at each pixel center: p minus where
// `opened` puts p, scaled by the draw's coverage at its edges.
@(test)
test_motion_affine :: proc(t: ^testing.T) {
	s: Mo
	mo_open(&s, 64, 48)
	defer mo_close(&s)
	c := &s.canvas
	opened := Transform2D{0.9, 0.1, -0.05, 1.1, 3, -2}
	set_motion(c, opened)
	// Pixel column 8 is half covered.
	mo_rect(&s, 8.5, 8, 32, 24, WHITE)
	flush(c)
	v, n := software_backend_velocity(&s.backend)
	testing.expect_value(t, len(v), 64 * 48)
	testing.expect_value(t, len(n), 64 * 48)
	worst: f32
	for y in 8 ..< 32 {
		for x in 9 ..< 40 {
			p := Vec2{f32(x) + 0.5, f32(y) + 0.5}
			want := p - transform_point(opened, p.x, p.y)
			got, near := mo_at(&s, x, y)
			worst = max(worst, abs(got.x - want.x), abs(got.y - want.y))
			testing.expect_value(t, near, 2)
		}
	}
	testing.expectf(t, worst < 1e-4, "interior velocity off by %v", worst)
	p := Vec2{8.5, 20.5}
	want := (p - transform_point(opened, p.x, p.y)) * 0.5
	got, near := mo_at(&s, 8, 20)
	testing.expectf(t, abs(got.x - want.x) < 0.02 && abs(got.y - want.y) < 0.02 && abs(near - 1) < 0.01, "edge %v %v, want %v at nearness 1", got, near, want)
	got, near = mo_at(&s, 50, 40)
	testing.expect(t, got == {} && near == 0)

	// Each frame's motion starts still, though nothing clears the screen.
	set_size(c, 64, 48)
	set_motion(c, transform_translation(1, 1))
	mo_rect(&s, 0, 0, 8, 8, WHITE)
	flush(c)
	got, near = mo_at(&s, 20, 20)
	testing.expectf(t, got == {} && near == 0, "last frame's motion stayed: %v %v", got, near)
	got, near = mo_at(&s, 4, 4)
	testing.expect(t, got == {-1, -1} && near == 2)

	// A frame without motion blur gives none.
	canvas_motion_blur(c, false)
	set_size(c, 64, 48)
	mo_rect(&s, 0, 0, 64, 48, WHITE)
	flush(c)
	v, n = software_backend_velocity(&s.backend)
	testing.expect(t, len(v) == 0 && len(n) == 0)
}

// What is drawn over a moving draw hides its motion, and each surface is
// nearer than those drawn before it: set_motion starts one, and so does
// drawing on after a restore brings an earlier one back.
@(test)
test_motion_occludes :: proc(t: ^testing.T) {
	s: Mo
	mo_open(&s, 64, 48)
	defer mo_close(&s)
	c := &s.canvas
	save(c)
	set_motion(c, transform_translation(-5, 0))
	mo_rect(&s, 0, 0, 40, 48, WHITE)
	restore(c)
	// The frame's first surface again, drawn over the moving one.
	mo_rect(&s, 20, 0, 10, 48, WHITE)
	set_motion(c, TRANSFORM_IDENTITY)
	mo_rect(&s, 30, 0, 20, 48, WHITE)
	flush(c)
	v, n := mo_at(&s, 10, 10)
	testing.expect(t, v == {5, 0} && n == 2)
	v1, n1 := mo_at(&s, 25, 10)
	testing.expect(t, v1 == {} && n1 > n)
	v2, n2 := mo_at(&s, 35, 10)
	testing.expect(t, v2 == {} && n2 > n1)
	v3, n3 := mo_at(&s, 55, 10)
	testing.expect(t, v3 == {} && n3 == 0)
}

// In a group that fades while its text slides, the text blurs: its motion
// composites at the group's coverage, the glyphs' times the opacity, over
// the still ground. A layer drawn as one group of shapes (layer_group) and
// one drawn through images (here clipped) give the same motion.
@(test)
test_motion_faded_group_slides :: proc(t: ^testing.T) {
	font, err := font_load(DEFAULT_FONT_DATA)
	testing.expect_value(t, err, nil)
	defer font_destroy(&font)
	text := "Motion"
	glyphs := make([]Positioned_Glyph, len(text))
	defer delete(glyphs)
	scale := font_scale_for_pixel_height(&font, 28)
	pen: f32 = 6
	for r, i in text {
		g := font_glyph_index(&font, r)
		glyphs[i] = {g, pen, 34}
		adv, _ := font_glyph_advance(&font, g)
		pen += f32(adv) * scale
	}
	clip: Path
	defer path_destroy(&clip)
	path_rect(&clip, 0, 0, 128, 48)
	velocity: [2][]Vec2
	for clipped, k in ([2]bool{false, true}) {
		s: Mo
		mo_open(&s, 128, 48)
		defer mo_close(&s)
		c := &s.canvas
		layer_stack_begin(&s.layers, c, 128, 48)
		set_motion(c, TRANSFORM_IDENTITY)
		mo_rect(&s, 0, 0, 128, 48, BLACK)
		layer_push(&s.layers, c, {opacity = 0.5, clip_path = &clip if clipped else nil})
		set_motion(c, transform_translation(-4, 0))
		fill_glyph_outlines(c, &font, glyphs, scale, paint_color(WHITE), &s.path)
		layer_pop(&s.layers, c)
		layer_stack_end(&s.layers, c)
		flush(c)
		// White text at half opacity over black: red is the group's
		// coverage, which the motion (4, 0) composites at.
		v, n := software_backend_velocity(&s.backend)
		worst, most: f32
		for p, i in v {
			cover := f32(s.backend.pixels[i * 4]) / 255
			worst = max(worst, abs(p.x - 4 * cover), abs(p.y))
			most = max(most, p.x)
			testing.expect(t, n[i] >= 2)
		}
		testing.expectf(t, worst < 0.03, "clipped %v: velocity off the group's coverage by %v", clipped, worst)
		testing.expectf(t, most > 1.9, "clipped %v: the text's velocity reaches %v, not 2", clipped, most)
		velocity[k] = make([]Vec2, len(v))
		copy(velocity[k], v)
	}
	defer delete(velocity[0])
	defer delete(velocity[1])
	worst: f32
	for p, i in velocity[0] {
		q := velocity[1][i]
		worst = max(worst, abs(p.x - q.x), abs(p.y - q.y))
	}
	// The clipped layer's coverage comes through an 8-bit image.
	testing.expectf(t, worst < 4.0 / 255, "grouped and clipped layers' velocity differ by %v", worst)
}

// A layer's motion is cut by its clip as its pixels are, and stays where
// its content drew when a filter (here a blur) spreads its pixels.
@(test)
test_motion_layer_coverage :: proc(t: ^testing.T) {
	s: Mo
	mo_open(&s, 96, 48)
	defer mo_close(&s)
	c := &s.canvas
	clip: Path
	defer path_destroy(&clip)
	path_rect(&clip, 0, 0, 24, 48)
	layer_stack_begin(&s.layers, c, 96, 48)
	layer_push(&s.layers, c, {clip_path = &clip})
	set_motion(c, transform_translation(-6, 0))
	mo_rect(&s, 8, 8, 32, 32, WHITE)
	layer_pop(&s.layers, c)
	layer_push(&s.layers, c, {blur = 3})
	set_motion(c, transform_translation(0, -6))
	mo_rect(&s, 56, 12, 24, 24, WHITE)
	layer_pop(&s.layers, c)
	layer_stack_end(&s.layers, c)
	flush(c)
	v, _ := mo_at(&s, 16, 24)
	testing.expectf(t, abs(v.x - 6) < 0.05 && v.y == 0, "inside the clip: %v", v)
	v, _ = mo_at(&s, 32, 24)
	testing.expectf(t, v == {}, "past the clip: %v", v)
	v, _ = mo_at(&s, 68, 24)
	testing.expectf(t, v.x == 0 && abs(v.y - 6) < 0.3, "in the blurred square: %v", v)
	// The blur's halo, beyond the square: its pixels show, no motion.
	halo := s.backend.pixels[(24 * 96 + 82) * 4 + 3]
	v, _ = mo_at(&s, 82, 24)
	testing.expectf(t, halo > 0 && v == {}, "in the halo (alpha %d): %v", halo, v)
}

// A frame recorded on one canvas and played on another backend carries its
// motion: the played velocity is the directly drawn one.
@(test)
test_motion_recorded :: proc(t: ^testing.T) {
	draw :: proc(s: ^Mo) {
		c := &s.canvas
		layer_stack_begin(&s.layers, c, 64, 48)
		set_motion(c, TRANSFORM_IDENTITY)
		mo_rect(s, 0, 0, 64, 48, BLACK)
		layer_push(&s.layers, c, {opacity = 0.5, blur = 1})
		set_motion(c, transform_translation(-3, 2))
		mo_rect(s, 10, 10, 30, 20, WHITE)
		layer_pop(&s.layers, c)
		layer_stack_end(&s.layers, c)
	}
	direct: Mo
	mo_open(&direct, 64, 48)
	defer mo_close(&direct)
	draw(&direct)
	flush(&direct.canvas)

	recording: Mo
	canvas_init_recording(&recording.canvas)
	canvas_motion_blur(&recording.canvas, true)
	set_size(&recording.canvas, 64, 48)
	draw(&recording)
	rec: Recorded_Frame
	defer recorded_frame_destroy(&rec)
	canvas_take(&recording.canvas, &rec)
	defer path_destroy(&recording.path)
	defer layer_stack_destroy(&recording.layers, &recording.canvas)
	defer canvas_destroy(&recording.canvas)
	played: Software_Backend
	software_backend_init(&played)
	defer software_backend_destroy(&played)
	p: Player
	player_init(&p, software_backend(&played))
	defer player_destroy(&p)
	player_apply(&p, &rec)
	player_render(&p, &rec)

	v, n := software_backend_velocity(&direct.backend)
	pv, pn := software_backend_velocity(&played)
	testing.expect_value(t, len(pv), len(v))
	testing.expect(t, len(v) == 64 * 48 && string(slice.to_bytes(v)) == string(slice.to_bytes(pv)) && string(slice.to_bytes(n)) == string(slice.to_bytes(pn)))
	moving, _ := mo_at(&direct, 25, 20)
	testing.expectf(t, abs(moving.x - 1.5) < 0.05 && abs(moving.y + 1) < 0.05, "the faded layer's velocity %v", moving)
}
