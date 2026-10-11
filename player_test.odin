package ovg

import "core:testing"

// A recording canvas played through a software backend draws what the same
// canvas on that backend draws: gradients (ramp images made and released
// across frames), shared and updated images, blurred layers from the pool.

@(private = "file")
Player_Scene :: struct {
	layers: Layer_Stack,
	path:   Path,
	image:  Image_Id,
	pixels: [16 * 16 * 4]u8,
}

@(private = "file")
player_scene_draw :: proc(s: ^Player_Scene, c: ^Canvas, frame: int) {
	set_size(c, 64, 48)
	reset(c)
	clear_rect(c, 0, 0, 64, 48, rgb(10, 20, 30))
	if !image_id_valid(s.image) {
		for &p, i in s.pixels {
			p = u8(i * 7)
		}
		s.image, _ = create_image_shared(c, image_source_rgba(s.pixels[:], 16, 16), 1, stable = true, flags = {.Premultiplied})
	}
	layer_stack_begin(&s.layers, c, 64, 48)
	// A gradient whose stops change every other frame (new ramps, old
	// ones released).
	stops := [3]Gradient_Stop{{0, rgb(255, 0, 0)}, {0.5, rgba(0, 255, 0, 128)}, {1, rgb(0, u8(frame / 2 * 60), 255)}}
	path_reset(&s.path)
	path_rect(&s.path, 4, 4, 40, 30)
	fill_path(c, &s.path, paint_linear_gradient_stops(4, 4, 44, 34, stops[:]))
	// A blurred layer with the image in it.
	layer_push(&s.layers, c, {blur = 2, opacity = 0.8})
	path_reset(&s.path)
	path_rect(&s.path, f32(20 + frame), 10, 24, 24)
	fill_path(c, &s.path, paint_image(s.image, f32(20 + frame), 10, 24, 24, 0))
	layer_pop(&s.layers, c)
	layer_stack_end(&s.layers, c)
}

@(test)
test_recording_matches_canvas :: proc(t: ^testing.T) {
	direct: Software_Backend
	software_backend_init(&direct)
	defer software_backend_destroy(&direct)
	dc: Canvas
	canvas_init(&dc, software_backend(&direct))
	ds: Player_Scene

	played: Software_Backend
	software_backend_init(&played)
	defer software_backend_destroy(&played)
	shared: Shared_Images
	shared_images_init(&shared, software_backend(&played))
	p: Player
	player_init(&p, software_backend(&played), &shared)
	rc: Canvas
	canvas_init_recording(&rc)
	rs: Player_Scene
	rec: Recorded_Frame

	for frame in 0 ..< 6 {
		player_scene_draw(&ds, &dc, frame)
		flush(&dc)
		player_scene_draw(&rs, &rc, frame)
		canvas_take(&rc, &rec)
		player_apply(&p, &rec)
		player_render(&p, &rec)
		testing.expect_value(t, len(played.pixels), len(direct.pixels))
		same := true
		for v, i in direct.pixels {
			if played.pixels[i] != v {
				same = false
				break
			}
		}
		testing.expectf(t, same, "frame %d differs", frame)
	}

	layer_stack_destroy(&rs.layers, &rc)
	path_destroy(&rs.path)
	canvas_destroy(&rc)
	recorded_frame_destroy(&rec)
	player_destroy(&p)
	shared_images_destroy(&shared)
	layer_stack_destroy(&ds.layers, &dc)
	path_destroy(&ds.path)
	canvas_destroy(&dc)
}
