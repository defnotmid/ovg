package ovg

import "core:testing"

// Expected pixels come from an independent transcription of the W3C
// Compositing and SVG Filter Effects formulas, rounded to 8 bits.

@(private = "file")
Fx :: struct {
	backend: Software_Backend,
	canvas:  Canvas,
}

@(private = "file")
fx_open :: proc(s: ^Fx) {
	software_backend_init(&s.backend)
	canvas_init(&s.canvas, software_backend(&s.backend))
	set_size(&s.canvas, 4, 4)
}

@(private = "file")
fx_close :: proc(s: ^Fx) {
	canvas_destroy(&s.canvas)
	software_backend_destroy(&s.backend)
}

// A 1x1 premultiplied image of `px`.
@(private = "file")
pixel_image :: proc(s: ^Fx, px: [4]u8) -> Image_Id {
	px := px
	id, _ := create_image(&s.canvas, image_source_rgba(px[:], 1, 1), {.Premultiplied})
	return id
}

@(private = "file")
pixel_of :: proc(s: ^Fx, id: Image_Id) -> [4]u8 {
	p := image_store_get(&s.canvas.images, id).image.pixels
	return {p[0], p[1], p[2], p[3]}
}

@(private = "file")
near :: proc(a, b: [4]u8) -> bool {
	for i in 0 ..< 4 {
		if abs(int(a[i]) - int(b[i])) > 1 {
			return false
		}
	}
	return true
}

@(private = "file")
run_filter :: proc(s: ^Fx, filter: Image_Filter, src: [4]u8) -> [4]u8 {
	a := pixel_image(s, src)
	dst := pixel_image(s, {})
	filter_image(&s.canvas, dst, filter, a)
	flush(&s.canvas)
	return pixel_of(s, dst)
}

@(test)
test_filter_blend_modes :: proc(t: ^testing.T) {
	s: Fx
	fx_open(&s)
	defer fx_close(&s)
	src := [4]u8{204, 102, 51, 255}
	back := [4]u8{77, 153, 230, 255}
	want := [Blend_Mode][4]u8 {
		.Normal      = {204, 102, 51, 255},
		.Multiply    = {62, 61, 46, 255},
		.Screen      = {219, 194, 235, 255},
		.Overlay     = {123, 133, 215, 255},
		.Darken      = {77, 102, 51, 255},
		.Lighten     = {204, 153, 230, 255},
		.Color_Dodge = {255, 255, 255, 255},
		.Color_Burn  = {33, 0, 130, 255},
		.Hard_Light  = {184, 122, 92, 255},
		.Soft_Light  = {115, 141, 216, 255},
		.Difference  = {127, 51, 179, 255},
		.Exclusion   = {158, 133, 189, 255},
		.Hue         = {216, 114, 63, 255},
		.Saturation  = {77, 153, 230, 255},
		.Color       = {216, 114, 63, 255},
		.Luminosity  = {65, 141, 218, 255},
	}
	for mode in Blend_Mode {
		b := pixel_image(&s, back)
		got := run_filter(&s, Blend{mode, b}, src)
		testing.expectf(t, near(got, want[mode]), "%v: got %v want %v", mode, got, want[mode])
	}
	// Translucent inputs exercise the compositing part.
	semi := [3]struct {
		mode: Blend_Mode,
		want: [4]u8,
	}{{.Normal, {130, 108, 112, 223}}, {.Multiply, {77, 93, 110, 223}}, {.Screen, {136, 143, 180, 223}}}
	for c in semi {
		b := pixel_image(&s, {57, 115, 172, 191})
		got := run_filter(&s, Blend{c.mode, b}, {102, 51, 26, 128})
		testing.expectf(t, near(got, c.want), "semi %v: got %v want %v", c.mode, got, c.want)
	}
}

@(test)
test_filter_composite :: proc(t: ^testing.T) {
	s: Fx
	fx_open(&s)
	defer fx_close(&s)
	cases := [7]struct {
		op:   Composite_Operator,
		k:    [4]f32,
		want: [4]u8,
	} {
		{.Over, {}, {130, 108, 112, 223}},
		{.In, {}, {76, 38, 19, 96}},
		{.Out, {}, {26, 13, 7, 32}},
		{.Atop, {}, {105, 95, 105, 191}},
		{.Xor, {}, {54, 70, 92, 127}},
		{.Lighter, {}, {159, 166, 198, 255}},
		{.Arithmetic, {0.5, 0.5, 0.25, 0.1}, {102, 91, 90, 185}},
	}
	for c in cases {
		b := pixel_image(&s, {57, 115, 172, 191})
		got := run_filter(&s, Composite{c.op, c.k, b}, {102, 51, 26, 128})
		testing.expectf(t, near(got, c.want), "%v: got %v want %v", c.op, got, c.want)
	}
}

@(test)
test_filter_color_matrix :: proc(t: ^testing.T) {
	s: Fx
	fx_open(&s)
	defer fx_close(&s)
	testing.expect_value(t, run_filter(&s, COLOR_MATRIX_IDENTITY, {10, 20, 30, 40}), [4]u8{10, 20, 30, 40})
	got := run_filter(&s, color_matrix_saturate(0), {255, 0, 0, 255})
	testing.expectf(t, near(got, {54, 54, 54, 255}), "saturate red %v", got)
	got = run_filter(&s, color_matrix_saturate(0), {128, 0, 0, 128})
	testing.expectf(t, near(got, {27, 27, 27, 128}), "saturate translucent red %v", got)
	got = run_filter(&s, color_matrix_hue_rotate(180), {255, 0, 0, 255})
	testing.expectf(t, near(got, {0, 109, 109, 255}), "hue 180 %v", got)
	got = run_filter(&s, color_matrix_luminance_to_alpha(), {255, 255, 255, 255})
	testing.expectf(t, near(got, {0, 0, 0, 255}), "l2a white %v", got)
	got = run_filter(&s, color_matrix_luminance_to_alpha(), {0, 255, 0, 255})
	testing.expectf(t, near(got, {0, 0, 0, 182}), "l2a green %v", got)
	// The fifth column is an offset in 0..1 units.
	m := COLOR_MATRIX_IDENTITY
	m.m[4] = 0.5
	got = run_filter(&s, m, {0, 0, 0, 255})
	testing.expectf(t, near(got, {128, 0, 0, 255}), "offset %v", got)
}

@(test)
test_filter_color_space :: proc(t: ^testing.T) {
	s: Fx
	fx_open(&s)
	defer fx_close(&s)
	got := run_filter(&s, Color_Space_Convert{true}, {128, 128, 128, 255})
	testing.expectf(t, near(got, {55, 55, 55, 255}), "to linear %v", got)
	got = run_filter(&s, Color_Space_Convert{false}, {55, 55, 55, 255})
	testing.expectf(t, near(got, {128, 128, 128, 255}), "to sRGB %v", got)
	// Premultiplied input converts its straight color.
	got = run_filter(&s, Color_Space_Convert{true}, {64, 64, 64, 128})
	testing.expectf(t, near(got, {28, 28, 28, 128}), "translucent %v", got)
}

@(test)
test_filter_aliasing :: proc(t: ^testing.T) {
	s: Fx
	fx_open(&s)
	defer fx_close(&s)
	a := pixel_image(&s, {204, 102, 51, 255})
	b := pixel_image(&s, {77, 153, 230, 255})
	// Blend in place onto the backdrop.
	filter_image(&s.canvas, b, Blend{.Multiply, b}, a)
	flush(&s.canvas)
	testing.expect(t, near(pixel_of(&s, b), {62, 61, 46, 255}))
}

@(test)
test_filter_blur :: proc(t: ^testing.T) {
	s: Fx
	fx_open(&s)
	defer fx_close(&s)
	W :: 16
	px: [W * W * 4]u8
	at :: proc(x, y: int) -> int {return (y * W + x) * 4}
	for k in 0 ..< 4 {px[at(8, 8) + k] = 255}
	src, _ := create_image(&s.canvas, image_source_rgba(px[:], W, W), {.Premultiplied})
	read :: proc(s: ^Fx, id: Image_Id, x, y: int) -> u8 {
		return image_store_get(&s.canvas.images, id).image.pixels[at(x, y) + 3]
	}

	// Sigma 0 copies.
	dst, _ := create_image_empty(&s.canvas, W, W, .RGBA8, {.Premultiplied})
	filter_image(&s.canvas, dst, Gaussian_Blur{0}, src)
	flush(&s.canvas)
	testing.expect_value(t, read(&s, dst, 8, 8), 255)
	testing.expect_value(t, read(&s, dst, 9, 8), 0)

	// Horizontal only: the row spreads, the column doesn't.
	filter_image(&s.canvas, dst, Blur_XY{2, 0, .Transparent}, src)
	flush(&s.canvas)
	testing.expect(t, read(&s, dst, 10, 8) > 0)
	testing.expect_value(t, read(&s, dst, 8, 10), 0)
	testing.expect_value(t, read(&s, dst, 6, 8), read(&s, dst, 10, 8))

	// Isotropic: symmetric, and the weights sum to one (the dot keeps its
	// energy within rounding).
	filter_image(&s.canvas, dst, Gaussian_Blur{1.5}, src)
	flush(&s.canvas)
	testing.expect_value(t, read(&s, dst, 8, 6), read(&s, dst, 6, 8))
	total := 0
	for y in 0 ..< W {
		for x in 0 ..< W {
			total += int(read(&s, dst, x, y))
		}
	}
	testing.expectf(t, abs(total - 255) < 30, "blurred dot keeps its energy: %d", total)

	// Edges: a full-alpha image blurred stays opaque with clamped edges and
	// loses alpha at the border with transparent ones.
	full: [W * W * 4]u8 = 255
	solid, _ := create_image(&s.canvas, image_source_rgba(full[:], W, W), {.Premultiplied})
	filter_image(&s.canvas, dst, Blur_XY{2, 2, .Clamp}, solid)
	flush(&s.canvas)
	testing.expect_value(t, read(&s, dst, 0, 0), 255)
	filter_image(&s.canvas, dst, Gaussian_Blur{2}, solid)
	flush(&s.canvas)
	testing.expect(t, read(&s, dst, 0, 0) < 200)
	testing.expect_value(t, read(&s, dst, 8, 8), 255)
}

@(test)
test_gradient_spread :: proc(t: ^testing.T) {
	s: Fx
	software_backend_init(&s.backend)
	canvas_init(&s.canvas, software_backend(&s.backend))
	defer fx_close(&s)
	set_size(&s.canvas, 40, 1)
	p: Path
	defer path_destroy(&p)
	path_rect(&p, 0, 0, 40, 1)
	red_at :: proc(s: ^Fx, x: int) -> u8 {return s.backend.pixels[x * 4]}
	for spread in Gradient_Spread {
		// Black to red over x = 0..10; beyond it the spread decides.
		paint := paint_linear_gradient(0, 0, 10, 0, BLACK, rgb(255, 0, 0))
		paint.spread = spread
		paint.anti_alias = false
		fill_path(&s.canvas, &p, paint)
		flush(&s.canvas)
		x := 15 // t = 1.55
		switch spread {
		case .Pad:
			testing.expect_value(t, red_at(&s, x), 255)
		case .Reflect:
			testing.expectf(t, abs(int(red_at(&s, x)) - 115) <= 2, "reflect %d", red_at(&s, x))
		case .Repeat:
			testing.expectf(t, abs(int(red_at(&s, x)) - 140) <= 2, "repeat %d", red_at(&s, x))
		}
		// Multi-stop gradients use the ramp texture with the same spread.
		stops := []Gradient_Stop{{0, BLACK}, {0.5, rgb(255, 0, 0)}, {1, BLACK}}
		multi := paint_linear_gradient_stops(0, 0, 10, 0, stops)
		multi.spread = spread
		multi.anti_alias = false
		fill_path(&s.canvas, &p, multi)
		flush(&s.canvas)
		x = 17 // t = 1.75
		switch spread {
		case .Pad:
			testing.expectf(t, red_at(&s, x) <= 2, "multi pad %d", red_at(&s, x))
		case .Reflect:
			// t reflects to 0.25: halfway up to red.
			testing.expectf(t, abs(int(red_at(&s, x)) - 127) <= 4, "multi reflect %d", red_at(&s, x))
		case .Repeat:
			testing.expectf(t, abs(int(red_at(&s, x)) - 127) <= 4, "multi repeat %d", red_at(&s, x))
		}
	}
}

@(test)
test_paint_transform :: proc(t: ^testing.T) {
	s: Fx
	software_backend_init(&s.backend)
	canvas_init(&s.canvas, software_backend(&s.backend))
	defer fx_close(&s)
	set_size(&s.canvas, 40, 1)
	p: Path
	defer path_destroy(&p)
	path_rect(&p, 0, 0, 40, 1)
	// A 0..1 gradient stretched to 0..20 by its transform (objectBoundingBox
	// style).
	paint := paint_linear_gradient(0, 0, 1, 0, BLACK, rgb(255, 0, 0))
	paint.transform = transform_scaling(20, 1)
	paint.anti_alias = false
	fill_path(&s.canvas, &p, paint)
	flush(&s.canvas)
	r := s.backend.pixels[10 * 4]
	testing.expectf(t, abs(int(r) - 134) <= 3, "midway %d", r)
	testing.expect_value(t, s.backend.pixels[30 * 4], 255)

	// Image paints: the transform moves the image in paint space.
	img_px := [?]u8{255, 0, 0, 255, 0, 0, 255, 255}
	img, _ := create_image(&s.canvas, image_source_rgba(img_px[:], 2, 1), {.Nearest})
	ip := paint_image(img, 0, 0, 20, 1, 0)
	ip.transform = transform_translation(20, 0)
	ip.anti_alias = false
	fill_path(&s.canvas, &p, ip)
	flush(&s.canvas)
	testing.expect_value(t, s.backend.pixels[25 * 4], 255) // red half, moved right
	testing.expect_value(t, s.backend.pixels[35 * 4 + 2], 255) // blue half
}

// Linear-light intermediates keep sRGB's dark levels: a black to #303030
// ramp through a linearRGB bloom (onimite's recipe) keeps every level it
// had, and a filter that passes the source through returns it unchanged.
@(test)
test_filter_linear_keeps_darks :: proc(t: ^testing.T) {
	s: Fx
	fx_open(&s)
	defer fx_close(&s)
	c := &s.canvas
	W :: 256
	set_size(c, W, 2)
	ls: Layer_Stack
	defer layer_stack_destroy(&ls, c)
	ramp := paint_linear_gradient(0, 0, W, 0, BLACK, rgb(0x30, 0x30, 0x30))
	p: Path
	defer path_destroy(&p)
	path_rect(&p, 0, 0, W, 2)
	slope := f32(1 / (1 - 0.75))
	bloom := [?]Filter_Primitive {
		{op = .Composite, composite = .Arithmetic, in1 = {kind = .Source_Graphic}, in2 = {kind = .Source_Graphic}, k = {0, slope, 0, -0.75 * slope}},
		{op = .Gaussian_Blur, in1 = {kind = .Previous}, std = {8, 8}},
		{op = .Composite, composite = .Arithmetic, in1 = {kind = .Source_Graphic}, in2 = {kind = .Previous}, k = {0, 1, 0.7, 0}},
	}
	levels :: proc(px: []u8) -> (n: int) {
		seen: [256]bool
		for x in 0 ..< W {
			n += int(!seen[px[x * 4]])
			seen[px[x * 4]] = true
		}
		return
	}
	plain: [W * 4]u8
	for filtered in ([2]bool{false, true}) {
		clear_rect(c, 0, 0, W, 2, BLACK)
		layer_stack_begin(&ls, c, W, 2)
		f := Filter{primitives = bloom[:]}
		if filtered {
			layer_push(&ls, c, {filter = &f})
		}
		fill_path(c, &p, ramp)
		if filtered {
			layer_pop(&ls, c)
		}
		layer_stack_end(&ls, c)
		flush(c)
		px := s.backend.pixels[:W * 4]
		if !filtered {
			copy(plain[:], px)
			continue
		}
		testing.expectf(t, levels(px) == levels(plain[:]), "bloom keeps %d of %d levels", levels(px), levels(plain[:]))
		testing.expect(t, string(px) == string(plain[:]), "nothing passes the threshold, so the ramp is unchanged")
	}
}
