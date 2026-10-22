package ovg

import "core:testing"

// Writes uv-derived colors, with the first uniform float as alpha, plus
// channel 0 sampled at the pixel's uv.
@(private = "file")
test_program_cpu :: proc(user: rawptr, uniforms: []u8, width, height: int, out: []u8, stride: int, format: Pixel_Format, sampler: Program_Sampler) {
	alpha := (^f32)(raw_data(uniforms))^
	for y in 0 ..< height {
		for x in 0 ..< width {
			uv := [2]f32{(f32(x) + 0.5) / f32(width), (f32(y) + 0.5) / f32(height)}
			s := sampler.sample(sampler.data, 0, uv, 0)
			if format == .RGBA16F {
				// Unclamped: the channel doubled, alpha as given.
				(^[4]f16)(&out[y * stride + x * 8])^ = {f16(s.r * 2), f16(s.g * 2), f16(uv.x * 4), f16(alpha)}
				continue
			}
			p := out[y * stride + x * 4:]
			p[0] = u8(uv.x * 255)
			p[1] = u8(s.g * 255)
			p[2] = u8(user != nil) * 255
			p[3] = u8(alpha * 255)
		}
	}
}

// Keeps the channel sizes the sampler carries in `user`.
@(private = "file")
test_program_sizes :: proc(user: rawptr, uniforms: []u8, width, height: int, out: []u8, stride: int, format: Pixel_Format, sampler: Program_Sampler) {
	(^[PROGRAM_MAX_CHANNELS][2]i32)(user)^ = sampler.sizes
}

// The sampler gives each bound channel's size in texels, 0 x 0 unbound.
@(test)
test_program_channel_sizes :: proc(t: ^testing.T) {
	b: Software_Backend
	software_backend_init(&b)
	defer software_backend_destroy(&b)
	c: Canvas
	canvas_init(&c, software_backend(&b))
	defer canvas_destroy(&c)
	set_size(&c, 4, 4)
	sizes: [PROGRAM_MAX_CHANNELS][2]i32
	prog, _ := create_program(&c, {num_samplers = 2, cpu = test_program_sizes, cpu_user = &sizes})
	wide, _ := create_image_empty(&c, 3, 2, .RGBA8, {.Premultiplied})
	tall, _ := create_image_empty(&c, 1, 5, .RGBA16F)
	dst, _ := create_image_empty(&c, 2, 2, .RGBA8, {.Premultiplied})
	run_program(&c, prog, dst, nil, {wide, {}, tall})
	flush(&c)
	testing.expect_value(t, sizes, [PROGRAM_MAX_CHANNELS][2]i32{{3, 2}, {0, 0}, {1, 5}, {0, 0}})
}

@(test)
test_run_program_software :: proc(t: ^testing.T) {
	b: Software_Backend
	software_backend_init(&b)
	defer software_backend_destroy(&b)
	c: Canvas
	canvas_init(&c, software_backend(&b))
	defer canvas_destroy(&c)
	set_size(&c, 4, 4)

	marker := 1
	prog, err := create_program(&c, {uniform_size = 16, num_samplers = 1, cpu = test_program_cpu, cpu_user = &marker})
	testing.expect_value(t, err, Error.None)
	green := [4]u8{0, 200, 0, 255}
	src, _ := create_image(&c, image_source_rgba(green[:], 1, 1))
	dst, _ := create_image_empty(&c, 2, 2, .RGBA8, {.Premultiplied})

	block := [4]f32{0.5, 0, 0, 0}
	testing.expect_value(t, run_program(&c, prog, dst, ([^]u8)(&block)[:16], {src}), Error.None)
	// The block is copied at record time.
	block[0] = 0
	testing.expect_value(t, run_program(&c, prog, dst, nil, {dst}), Error.Unsupported_Operation)
	flush(&c)
	e := image_store_get(&c.images, dst)
	testing.expect_value(t, e.image.pixels[0], u8(63))
	testing.expect_value(t, e.image.pixels[1], u8(200))
	testing.expect_value(t, e.image.pixels[2], u8(255))
	testing.expect_value(t, e.image.pixels[3], u8(127))

	// Opaque forces alpha to 1; unbound channels read transparent black.
	block[0] = 0.25
	run_program(&c, prog, dst, ([^]u8)(&block)[:16], nil, {.Opaque})
	flush(&c)
	testing.expect_value(t, e.image.pixels[1], u8(0))
	testing.expect_value(t, e.image.pixels[3], u8(255))

	// Half-float targets keep values above 1, and read back as stored;
	// sampled as a channel they come back unclamped.
	hdr, _ := create_image_empty(&c, 2, 2, .RGBA16F)
	hdr2, _ := create_image_empty(&c, 2, 2, .RGBA16F)
	block[0] = 3
	testing.expect_value(t, run_program(&c, prog, hdr, ([^]u8)(&block)[:16], {src}), Error.None)
	testing.expect_value(t, run_program(&c, prog, hdr2, ([^]u8)(&block)[:16], {hdr}), Error.None)
	flush(&c)
	texels, rerr := read_image(&c, hdr2, context.temp_allocator)
	testing.expect_value(t, rerr, Error.None)
	testing.expect_value(t, len(texels), 2 * 2 * 8)
	px := (^[4]f16)(&texels[8])^
	testing.expect_value(t, px, [4]f16{0, f16(200.0 / 255 * 4), 3, 3})

	delete_program(&c, prog)
	testing.expect_value(t, run_program(&c, prog, dst, nil), Error.General)
}

@(test)
test_program_unsupported :: proc(t: ^testing.T) {
	b: Software_Backend
	software_backend_init(&b)
	defer software_backend_destroy(&b)
	c: Canvas
	canvas_init(&c, software_backend(&b))
	defer canvas_destroy(&c)
	// No CPU program: the software backend can't run it.
	_, err := create_program(&c, {frag_spirv = {1, 2, 3, 4}})
	testing.expect_value(t, err, Error.Unsupported_Operation)
}

// Fills the target with the colour `user` points at.
test_program_fill :: proc(user: rawptr, uniforms: []u8, width, height: int, out: []u8, stride: int, format: Pixel_Format, sampler: Program_Sampler) {
	col := (^[4]u8)(user)^
	for y in 0 ..< height {
		for x in 0 ..< width {
			(^[4]u8)(&out[y * stride + x * 4])^ = col
		}
	}
}

// Programs on a recording canvas: a frame renders the same twice, and a
// deleted program's backend program goes with it (its key index reused).
@(test)
test_program_recording :: proc(t: ^testing.T) {
	b: Software_Backend
	software_backend_init(&b)
	defer software_backend_destroy(&b)
	p: Player
	player_init(&p, software_backend(&b))
	defer player_destroy(&p)
	rc: Canvas
	canvas_init_recording(&rc)
	defer canvas_destroy(&rc)
	rec: Recorded_Frame
	defer recorded_frame_destroy(&rec)
	set_size(&rc, 4, 4)

	red, green := [4]u8{255, 0, 0, 255}, [4]u8{0, 255, 0, 255}
	a, _ := create_program(&rc, {cpu = test_program_fill, cpu_user = &red})
	g, _ := create_program(&rc, {cpu = test_program_fill, cpu_user = &green})
	dst, _ := create_image_empty(&rc, 2, 2, .RGBA8, {.Premultiplied})
	run_program(&rc, g, dst, nil)
	canvas_take(&rc, &rec)
	player_apply(&p, &rec)
	for _ in 0 ..< 2 {
		player_render(&p, &rec)
		testing.expect_value(t, (^[4]u8)(&image_store_get(&p.images, dst).image.pixels[0])^, green)
	}

	delete_program(&rc, a)
	canvas_take(&rc, &rec)
	player_apply(&p, &rec)
	testing.expect_value(t, p.programs[a.key.idx], Backend_Program{})
	// The freed key index serves the next program.
	again, _ := create_program(&rc, {cpu = test_program_fill, cpu_user = &red})
	testing.expect_value(t, again.key.idx, a.key.idx)
	run_program(&rc, again, dst, nil)
	canvas_take(&rc, &rec)
	player_apply(&p, &rec)
	player_render(&p, &rec)
	testing.expect_value(t, (^[4]u8)(&image_store_get(&p.images, dst).image.pixels[0])^, red)
}

@(private = "file")
External_Probe :: struct {
	// The store the callback got.
	images: ^Image_Store,
	image:  Image_Id,
	// The image's first pixel when the callback ran.
	seen:   [4]u8,
	calls:  int,
	gpu:    rawptr,
}

// Records the image's first pixel, then paints the image blue.
@(private = "file")
test_external_probe :: proc(user: rawptr, gpu: rawptr, images: ^Image_Store) {
	probe := (^External_Probe)(user)
	probe.images = images
	pixels := image_store_get(images, probe.image).image.pixels
	probe.seen = (^[4]u8)(&pixels[0])^
	probe.calls += 1
	probe.gpu = gpu
	for i := 0; i < len(pixels); i += 4 {
		(^[4]u8)(&pixels[i])^ = {0, 0, 255, 255}
	}
}

// An external run sees what the commands before it made, and the commands
// after it see its output, live and in recorded frames (every render).
@(test)
test_run_external :: proc(t: ^testing.T) {
	b: Software_Backend
	software_backend_init(&b)
	defer software_backend_destroy(&b)
	red, blue := [4]u8{255, 0, 0, 255}, [4]u8{0, 0, 255, 255}
	record :: proc(c: ^Canvas, probe: ^External_Probe, red: ^[4]u8) {
		set_size(c, 4, 4)
		fill, _ := create_program(c, {cpu = test_program_fill, cpu_user = red})
		probe.image, _ = create_image_empty(c, 2, 2, .RGBA8, {.Premultiplied})
		run_program(c, fill, probe.image, nil)
		run_external(c, test_external_probe, probe)
		p: Path
		defer path_destroy(&p)
		path_rect(&p, 0, 0, 4, 4)
		fill_path(c, &p, paint_image(probe.image, 0, 0, 4, 4, 0))
	}

	c: Canvas
	canvas_init(&c, software_backend(&b))
	defer canvas_destroy(&c)
	live := External_Probe{gpu = &b}
	record(&c, &live, &red)
	flush(&c)
	testing.expect_value(t, live.calls, 1)
	testing.expect_value(t, live.seen, red)
	testing.expect_value(t, live.gpu, nil)
	testing.expect_value(t, live.images, &c.images)
	testing.expect_value(t, (^[4]u8)(&b.pixels[(2 * 4 + 1) * 4])^, blue)

	p: Player
	player_init(&p, software_backend(&b))
	defer player_destroy(&p)
	rc: Canvas
	canvas_init_recording(&rc)
	defer canvas_destroy(&rc)
	rec: Recorded_Frame
	defer recorded_frame_destroy(&rec)
	played: External_Probe
	record(&rc, &played, &red)
	canvas_take(&rc, &rec)
	player_apply(&p, &rec)
	for i in 1 ..= 2 {
		(^[4]u8)(&b.pixels[(2 * 4 + 1) * 4])^ = {}
		player_render(&p, &rec)
		testing.expect_value(t, played.calls, i)
		testing.expect_value(t, played.seen, red)
		testing.expect_value(t, played.images, &p.images)
		testing.expect_value(t, (^[4]u8)(&b.pixels[(2 * 4 + 1) * 4])^, blue)
	}
}
