package ovg

import "core:testing"

// A small scene using every table the check reads: a square path, a solid
// paint, a mask drawn from a fill, main drawing a clipped fill and a masked
// layer.
@(private = "file")
scene_sample :: proc(s: ^Scene) -> (square: Path_Id, t: Transform_Id, paint: Paint_Id, mask: Mask_Id) {
	scene_init(s)
	t = scene_add_transform(s, TRANSFORM_IDENTITY)
	square = scene_add_path(s, {.Move, .Line, .Line, .Line, .Close}, {{0, 0}, {10, 0}, {10, 10}, {0, 10}})
	paint = scene_add_paint(s, Scene_Solid{{1, 0, 0, 1}})
	// The mask's draws first, outside main.
	at := u32(len(s.draws))
	append(&s.draws, Scene_Fill{path = square, transform = t, look = scene_look(paint)})
	append(&s.masks, Scene_Mask{draws = {at, 1}, read = .Luminance})
	mask = Mask_Id(len(s.masks))
	scene_draw(s, Clip_Push{Clip_Rect{0, 0, 8, 8}})
	scene_draw(s, Scene_Fill{path = square, transform = t, look = scene_look(paint)})
	scene_draw(s, Clip_Pop{})
	scene_draw(s, Layer_Push{opacity = 0.5, mask = mask})
	scene_draw(s, Clip_Push{Clip_Path{square, t, .Even_Odd}})
	scene_draw(s, Scene_Fill{path = square, transform = t, look = scene_look(paint)})
	scene_draw(s, Clip_Pop{})
	scene_draw(s, Layer_Pop{})
	return
}

@(test)
test_scene_check_accepts :: proc(t: ^testing.T) {
	s: Scene
	scene_sample(&s)
	defer scene_destroy(&s)
	p := scene_check(&s)
	testing.expectf(t, p.error == .None, "a well-formed scene: %v", p)
	testing.expect_value(t, s.main, Range{1, 8})
	testing.expect_value(t, s.paths[0].bounds, Bounds{0, 0, 10, 10})
}

// Zero is never a row: a draw left at its zero value names no path, so the
// check rejects it rather than drawing row 0; an optional handle at zero is
// none. A look's zero opacity is transparent; scene_look's is 1.
@(test)
test_scene_zero_handles :: proc(t: ^testing.T) {
	s: Scene
	_, _, paint, _ := scene_sample(&s)
	defer scene_destroy(&s)
	scene_draw(&s, Scene_Fill{})
	p := scene_check(&s)
	testing.expect_value(t, p, Scene_Problem{.Missing_Handle, .Draws, len(s.draws) - 1})
	look := scene_look(paint)
	testing.expect(t, look.mask == 0 && look.motion == 0 && look.opacity == 1)
	testing.expect_value(t, Scene_Look{}.opacity, 0)
}

@(test)
test_scene_check_rejects :: proc(t: ^testing.T) {
	Case :: enum {
		Handle_Past_Table,
		Path_Points,
		Mask_Range,
		Pop_Without_Push,
		Crossed_Nesting,
		Unclosed_In_Mask,
		Image_Handle,
	}
	for c in Case {
		s: Scene
		square, tr, paint, _ := scene_sample(&s)
		want: Scene_Problem
		switch c {
		case .Handle_Past_Table:
			scene_draw(&s, Scene_Fill{path = square, transform = tr, look = scene_look(paint + 5)})
			want = {.Handle_Out_Of_Range, .Draws, len(s.draws) - 1}
		case .Path_Points:
			append(&s.verbs, Path_Verb.Quad)
			append(&s.paths, Scene_Path{verbs = {u32(len(s.verbs) - 1), 1}, points = {0, 1}})
			want = {.Path_Points_Mismatch, .Paths, len(s.paths) - 1}
		case .Mask_Range:
			append(&s.masks, Scene_Mask{draws = {0, 100}})
			want = {.Range_Out_Of_Bounds, .Masks, len(s.masks) - 1}
		case .Pop_Without_Push:
			scene_draw(&s, Clip_Pop{})
			want = {.Unbalanced, .Draws, len(s.draws) - 1}
		case .Crossed_Nesting:
			scene_draw(&s, Clip_Push{Clip_Rect{0, 0, 4, 4}})
			scene_draw(&s, Layer_Push{opacity = 1})
			scene_draw(&s, Clip_Pop{})
			scene_draw(&s, Layer_Pop{})
			want = {.Unbalanced, .Draws, len(s.draws) - 2}
		case .Unclosed_In_Mask:
			// Balanced in main is not enough: each range on its own.
			at := u32(len(s.draws))
			append(&s.draws, Clip_Push{Clip_Rect{0, 0, 2, 2}})
			append(&s.masks, Scene_Mask{draws = {at, 1}})
			s.main = {1, 8}
			want = {.Unbalanced, .Draws, int(at)}
		case .Image_Handle:
			scene_add_paint(&s, Scene_Image_Paint{image = 0, transform = tr})
			want = {.Missing_Handle, .Paints, len(s.paints) - 1}
		}
		testing.expectf(t, scene_check(&s) == want, "%v: %v, wanted %v", c, scene_check(&s), want)
		scene_destroy(&s)
	}
}

// A mask's draws may name only masks and patterns whose draws come before
// its own in `draws`: itself, a later one, or a cycle through a pattern is
// rejected; main may name any.
@(test)
test_scene_dependency_order :: proc(t: ^testing.T) {
	{
		// A mask whose draw names itself.
		s: Scene
		square, tr, paint, _ := scene_sample(&s)
		at := u32(len(s.draws))
		self := Mask_Id(len(s.masks) + 1)
		look := scene_look(paint)
		look.mask = self
		append(&s.draws, Scene_Fill{path = square, transform = tr, look = look})
		append(&s.masks, Scene_Mask{draws = {at, 1}})
		s.main = {1, 8}
		testing.expect_value(t, scene_check(&s), Scene_Problem{.Dependency_Order, .Draws, int(at)})
		scene_destroy(&s)
	}
	{
		// A pattern cell under a mask whose draws paint with that pattern:
		// a cycle through both tables.
		s: Scene
		square, tr, paint, _ := scene_sample(&s)
		cell_at := u32(len(s.draws))
		mask := Mask_Id(len(s.masks) + 1)
		look := scene_look(paint)
		look.mask = mask
		append(&s.draws, Scene_Fill{path = square, transform = tr, look = look})
		append(&s.patterns, Pattern_Cell{draws = {cell_at, 1}, transform = tr, step = {10, 10}})
		pattern_paint := scene_add_paint(&s, Scene_Pattern_Paint{pattern = Pattern_Id(len(s.patterns))})
		mask_at := u32(len(s.draws))
		append(&s.draws, Scene_Fill{path = square, transform = tr, look = scene_look(pattern_paint)})
		append(&s.masks, Scene_Mask{draws = {mask_at, 1}})
		s.main = {1, 8}
		testing.expect_value(t, scene_check(&s), Scene_Problem{.Dependency_Order, .Draws, int(cell_at)})
		scene_destroy(&s)
	}
	{
		// The same pattern without the mask: its draws come before the
		// draw that paints with it, so it's accepted, and main may name a
		// mask defined after it.
		s: Scene
		square, tr, paint, _ := scene_sample(&s)
		cell_at := u32(len(s.draws))
		append(&s.draws, Scene_Fill{path = square, transform = tr, look = scene_look(paint)})
		append(&s.patterns, Pattern_Cell{draws = {cell_at, 1}, transform = tr, step = {10, 10}})
		pattern_paint := scene_add_paint(&s, Scene_Pattern_Paint{pattern = Pattern_Id(len(s.patterns))})
		mask_at := u32(len(s.draws))
		append(&s.draws, Scene_Fill{path = square, transform = tr, look = scene_look(pattern_paint)})
		append(&s.masks, Scene_Mask{draws = {mask_at, 1}})
		s.main = {1, 8}
		testing.expect_value(t, scene_check(&s), Scene_Problem{})
		scene_destroy(&s)
	}
}

// Clearing keeps the tables' room, so a scene rebuilt each frame allocates
// nothing once warm.
@(test)
test_scene_clear_keeps_room :: proc(t: ^testing.T) {
	s: Scene
	scene_sample(&s)
	defer scene_destroy(&s)
	room := cap(s.draws)
	scene_clear(&s)
	testing.expect_value(t, len(s.draws), 0)
	testing.expect_value(t, cap(s.draws), room)
	testing.expect_value(t, s.main, Range{})
}

// ---- exact truth, drawn through scene_record on the software backend ---------------

@(private = "file")
Scene_Target :: struct {
	backend: Software_Backend,
	canvas:  Canvas,
	layers:  Layer_Stack,
	render:  Scene_Renderer,
}

@(private = "file")
target_open :: proc(t: ^Scene_Target, w, h: u32) {
	software_backend_init(&t.backend)
	canvas_init(&t.canvas, software_backend(&t.backend))
	set_size(&t.canvas, w, h)
	scene_renderer_init(&t.render)
}

@(private = "file")
target_close :: proc(t: ^Scene_Target) {
	scene_renderer_destroy(&t.render, &t.canvas)
	layer_stack_destroy(&t.layers, &t.canvas)
	canvas_destroy(&t.canvas)
	software_backend_destroy(&t.backend)
}

// Records and flushes `s`; the pixels as floats (premultiplied, 0..1).
@(private = "file")
target_draw :: proc(t: ^Scene_Target, s: ^Scene) -> Scene_Problem {
	p := scene_record(&t.render, &t.canvas, &t.layers, s)
	flush(&t.canvas)
	scene_renderer_release(&t.render, &t.canvas)
	return p
}

@(private = "file")
target_px :: proc(t: ^Scene_Target, x, y: int) -> [4]f32 {
	i := (y * int(t.backend.width) + x) * 4
	p := t.backend.pixels
	return {f32(p[i]), f32(p[i + 1]), f32(p[i + 2]), f32(p[i + 3])} / 255
}

// The area of convex polygon `poly` inside pixel (x, y): the polygon clipped
// to the pixel's square (Sutherland-Hodgman), then its shoelace area.
@(private = "file")
pixel_area :: proc(poly: []Vec2, x, y: int) -> f32 {
	buf_a, buf_b: [32]Vec2
	n := len(poly)
	copy(buf_a[:], poly)
	src, dst := buf_a[:], buf_b[:]
	edges := [4][3]f32{{1, 0, -f32(x)}, {-1, 0, f32(x + 1)}, {0, 1, -f32(y)}, {0, -1, f32(y + 1)}}
	for e in edges {
		m := 0
		for i in 0 ..< n {
			a, b := src[i], src[(i + 1) % n]
			da, db := e[0] * a.x + e[1] * a.y + e[2], e[0] * b.x + e[1] * b.y + e[2]
			if da >= 0 {
				dst[m] = a
				m += 1
			}
			if (da >= 0) != (db >= 0) {
				dst[m] = a + (b - a) * (da / (da - db))
				m += 1
			}
		}
		n = m
		src, dst = dst, src
	}
	area: f32
	for i in 0 ..< n {
		a, b := src[i], src[(i + 1) % n]
		area += a.x * b.y - b.x * a.y
	}
	return abs(area) * 0.5
}

@(private = "file")
scene_polygon :: proc(s: ^Scene, pts: []Vec2) -> Path_Id {
	verbs := make([]Path_Verb, len(pts) + 1, context.temp_allocator)
	verbs[0] = .Move
	for i in 1 ..< len(pts) {
		verbs[i] = .Line
	}
	verbs[len(pts)] = .Close
	return scene_add_path(s, verbs, pts)
}

// Fills with exact areas: white over black, each pixel the area of the
// shape it holds, within one 8-bit level.
@(test)
test_scene_truth_coverage :: proc(t: ^testing.T) {
	W, H :: 24, 24
	shapes := [2][]Vec2{{{2.25, 3.5}, {17.5, 3.5}, {17.5, 9.75}, {2.25, 9.75}}, {{3.1, 12.2}, {21.7, 14.9}, {8.4, 22.6}}}
	for poly in shapes {
		tg: Scene_Target
		target_open(&tg, W, H)
		s: Scene
		scene_init(&s)
		id := scene_add_transform(&s, TRANSFORM_IDENTITY)
		scene_draw(&s, Scene_Clear{{0, 0, W, H}, {0, 0, 0, 1}})
		scene_draw(&s, Scene_Fill{path = scene_polygon(&s, poly), transform = id, look = scene_look(scene_add_paint(&s, Scene_Solid{{1, 1, 1, 1}}))})
		testing.expect_value(t, target_draw(&tg, &s), Scene_Problem{})
		worst: f32
		for y in 0 ..< H {
			for x in 0 ..< W {
				worst = max(worst, abs(target_px(&tg, x, y)[0] - pixel_area(poly, x, y)))
			}
		}
		testing.expectf(t, worst * 255 <= 1, "a fill is %.2f levels off its exact areas", worst * 255)
		scene_destroy(&s)
		target_close(&tg)
	}
}

// Draws against their formulas: source-over at an opacity, Multiply and
// Screen over an opaque backdrop, and an opacity of 0 drawing nothing.
@(test)
test_scene_truth_blends :: proc(t: ^testing.T) {
	W, H :: 8, 8
	back := [4]f32{0.2, 0.6, 0.9, 1}
	src := [3]f32{0.9, 0.3, 0.5}
	Case :: struct {
		mode:    Blend_Mode,
		opacity: f32,
		want:    [3]f32,
	}
	over := back.rgb * 0.5 + src * 0.5
	cases := [4]Case{
		{.Normal, 0.5, over},
		{.Multiply, 1, src * back.rgb},
		{.Screen, 1, src + back.rgb - src * back.rgb},
		{.Normal, 0, back.rgb},
	}
	for cs in cases {
		tg: Scene_Target
		target_open(&tg, W, H)
		s: Scene
		scene_init(&s)
		id := scene_add_transform(&s, TRANSFORM_IDENTITY)
		scene_draw(&s, Scene_Clear{{0, 0, W, H}, back})
		look := scene_look(scene_add_paint(&s, Scene_Solid{{src.r, src.g, src.b, 1}}))
		look.opacity = cs.opacity
		look.blend.mode = cs.mode
		scene_draw(&s, Scene_Fill{path = scene_polygon(&s, {{0, 0}, {W, 0}, {W, H}, {0, H}}), transform = id, look = look})
		testing.expect_value(t, target_draw(&tg, &s), Scene_Problem{})
		got := target_px(&tg, 4, 4)
		d := max(abs(got.r - cs.want.r), abs(got.g - cs.want.g), abs(got.b - cs.want.b))
		testing.expectf(t, d * 255 <= 1, "%v at %v: %v, wanted %v", cs.mode, cs.opacity, got, cs.want)
		scene_destroy(&s)
		target_close(&tg)
	}
}

// A luminance mask on a translucent colour: what it lets through is the
// straight colour's luminance times its alpha, by Rec. 709's weights or
// PDF's; an alpha mask lets through the alpha.
@(test)
test_scene_truth_masks :: proc(t: ^testing.T) {
	W, H :: 8, 8
	straight := [3]f32{0.2, 0.7, 0.4}
	a: f32 = 0.6
	Case :: struct {
		read: Scene_Mask_Read,
		want: f32,
	}
	cases := [3]Case{
		{.Luminance, (0.2125 * straight.r + 0.7154 * straight.g + 0.0721 * straight.b) * a},
		{.Luminance_Pdf, (0.3 * straight.r + 0.59 * straight.g + 0.11 * straight.b) * a},
		{.Alpha, a},
	}
	for cs in cases {
		tg: Scene_Target
		target_open(&tg, W, H)
		s: Scene
		scene_init(&s)
		id := scene_add_transform(&s, TRANSFORM_IDENTITY)
		square := scene_polygon(&s, {{0, 0}, {W, 0}, {W, H}, {0, H}})
		at := u32(len(s.draws))
		append(&s.draws, Scene_Fill{path = square, transform = id, look = scene_look(scene_add_paint(&s, Scene_Solid{{straight.r * a, straight.g * a, straight.b * a, a}}))})
		append(&s.masks, Scene_Mask{draws = {at, 1}, read = cs.read})
		look := scene_look(scene_add_paint(&s, Scene_Solid{{1, 1, 1, 1}}))
		look.mask = Mask_Id(len(s.masks))
		scene_draw(&s, Scene_Clear{{0, 0, W, H}, {0, 0, 0, 1}})
		scene_draw(&s, Scene_Fill{path = square, transform = id, look = look})
		testing.expect_value(t, target_draw(&tg, &s), Scene_Problem{})
		got := target_px(&tg, 3, 3)[0]
		testing.expectf(t, abs(got - cs.want) * 255 <= 1, "%v mask: %v, wanted %v", cs.read, got, cs.want)
		scene_destroy(&s)
		target_close(&tg)
	}
}

// Nested clips: a whole-pixel rectangle and a path, white over black, each
// pixel the product of their exact coverages.
@(test)
test_scene_truth_clips :: proc(t: ^testing.T) {
	W, H :: 24, 24
	tri := []Vec2{{2.6, 1.3}, {22.4, 6.8}, {9.1, 21.5}}
	rect := Clip_Rect{5, 4, 18, 20}
	tg: Scene_Target
	target_open(&tg, W, H)
	defer target_close(&tg)
	s: Scene
	scene_init(&s)
	defer scene_destroy(&s)
	id := scene_add_transform(&s, TRANSFORM_IDENTITY)
	scene_draw(&s, Scene_Clear{{0, 0, W, H}, {0, 0, 0, 1}})
	scene_draw(&s, Clip_Push{rect})
	scene_draw(&s, Clip_Push{Clip_Path{scene_polygon(&s, tri), id, .Non_Zero}})
	scene_draw(&s, Scene_Fill{path = scene_polygon(&s, {{0, 0}, {W, 0}, {W, H}, {0, H}}), transform = id, look = scene_look(scene_add_paint(&s, Scene_Solid{{1, 1, 1, 1}}))})
	scene_draw(&s, Clip_Pop{})
	scene_draw(&s, Clip_Pop{})
	testing.expect_value(t, target_draw(&tg, &s), Scene_Problem{})
	worst: f32
	for y in 0 ..< H {
		for x in 0 ..< W {
			in_rect: f32 = 1 if x >= int(rect[0]) && x < int(rect[2]) && y >= int(rect[1]) && y < int(rect[3]) else 0
			worst = max(worst, abs(target_px(&tg, x, y)[0] - in_rect * pixel_area(tri, x, y)))
		}
	}
	testing.expectf(t, worst * 255 <= 1, "nested clips are %.2f levels off the product of their coverages", worst * 255)
}

// A glyph run's coverage is its glyphs' union: two overlapping glyphs in
// one translucent colour paint the overlap once, not twice.
@(test)
test_scene_truth_run_union :: proc(t: ^testing.T) {
	W, H :: 16, 8
	tg: Scene_Target
	target_open(&tg, W, H)
	defer target_close(&tg)
	s: Scene
	scene_init(&s)
	defer scene_destroy(&s)
	id := scene_add_transform(&s, TRANSFORM_IDENTITY)
	square := scene_polygon(&s, {{0, 0}, {8, 0}, {8, 8}, {0, 8}})
	shift := scene_add_transform(&s, transform_translation(4, 0))
	g0 := u32(len(s.glyphs))
	append(&s.glyphs, Scene_Glyph{square, id}, Scene_Glyph{square, shift})
	append(&s.runs, Scene_Run{{g0, 2}, id})
	scene_draw(&s, Scene_Clear{{0, 0, W, H}, {0, 0, 0, 1}})
	scene_draw(&s, Scene_Glyphs{run = Run_Id(len(s.runs)), look = scene_look(scene_add_paint(&s, Scene_Solid{{0.5, 0.5, 0.5, 0.5}}))})
	testing.expect_value(t, target_draw(&tg, &s), Scene_Problem{})
	alone, overlap := target_px(&tg, 2, 4)[0], target_px(&tg, 6, 4)[0]
	testing.expectf(t, abs(alone - 0.5) * 255 <= 1 && abs(overlap - 0.5) * 255 <= 1, "a run's glyphs: %v alone, %v where they overlap; both should be 0.5", alone, overlap)
}

// What this recording can't draw exactly is rejected whole, not drawn
// approximately.
@(test)
test_scene_record_rejects_unsupported :: proc(t: ^testing.T) {
	tg: Scene_Target
	target_open(&tg, 8, 8)
	defer target_close(&tg)
	s: Scene
	scene_init(&s)
	defer scene_destroy(&s)
	scene_draw(&s, Layer_Push{opacity = 1, isolated = true, knockout = true})
	scene_draw(&s, Layer_Pop{})
	testing.expect_value(t, target_draw(&tg, &s), Scene_Problem{.Unsupported, .Draws, 0})

	// A Porter-Duff operation on a draw that goes through a layer (its
	// mask's or blend mode's).
	scene_clear(&s)
	id := scene_add_transform(&s, TRANSFORM_IDENTITY)
	square := scene_polygon(&s, {{0, 0}, {4, 0}, {4, 4}, {0, 4}})
	paint := scene_add_paint(&s, Scene_Solid{{1, 1, 1, 1}})
	look := scene_look(paint)
	look.blend = {op = .Source_In, mode = .Multiply}
	scene_draw(&s, Scene_Fill{path = square, transform = id, look = look})
	testing.expect_value(t, target_draw(&tg, &s), Scene_Problem{.Unsupported, .Draws, 0})

	// A stroke of a kept shape: only fills read kept shapes so far.
	scene_clear(&s)
	id = scene_add_transform(&s, TRANSFORM_IDENTITY)
	square = scene_polygon(&s, {{0, 0}, {4, 0}, {4, 4}, {0, 4}})
	paint = scene_add_paint(&s, Scene_Solid{{1, 1, 1, 1}})
	kept: Shape
	s.paths[square - 1].shape = &kept
	scene_draw(&s, Scene_Stroke{path = square, transform = id, style = scene_add_stroke(&s, {width = 1, miter_limit = 4}), look = scene_look(paint)})
	testing.expect_value(t, target_draw(&tg, &s), Scene_Problem{.Unsupported, .Draws, 0})

	// One image asked to sample two ways.
	scene_clear(&s)
	id = scene_add_transform(&s, TRANSFORM_IDENTITY)
	px := [4]u8{255, 255, 255, 255}
	img := scene_add_image(&s, Pixel_View{format = .RGBA8_Premul, data = px[:], width = 1, height = 1})
	scene_add_paint(&s, Scene_Image_Paint{image = img, transform = id, sampling = .Linear})
	scene_add_paint(&s, Scene_Image_Paint{image = img, transform = id, sampling = .Nearest})
	testing.expect_value(t, target_draw(&tg, &s), Scene_Problem{.Unsupported, .Paints, 1})
}
