package ovg_sdlsoft

import "core:log"
import "core:testing"
import sdl "vendor:sdl3"
import vg ".."

// A frame drawn on the software backend reaches the window's framebuffer
// pixel for pixel, on SDL's offscreen video driver (no display, no GPU),
// and again after the window grows.
@(test)
test_present_offscreen :: proc(t: ^testing.T) {
	sdl.SetHint(sdl.HINT_VIDEO_DRIVER, "offscreen")
	if !sdl.Init({.VIDEO}) {
		testing.fail_now(t, "SDL video on the offscreen driver")
	}
	defer sdl.Quit()
	window := sdl.CreateWindow("ovg sdlsoft test", 64, 48, {})
	if window == nil {
		// The offscreen driver on macOS makes windows only with an EGL library.
		log.warnf("skipped: the offscreen driver makes no window here (%s)", sdl.GetError())
		return
	}
	defer sdl.DestroyWindow(window)

	sw: vg.Software_Backend
	vg.software_backend_init(&sw)
	defer vg.software_backend_destroy(&sw)
	c: vg.Canvas
	vg.canvas_init(&c, vg.software_backend(&sw))
	defer vg.canvas_destroy(&c)
	p: vg.Path
	defer vg.path_destroy(&p)
	pr: Presenter
	presenter_init(&pr, window)
	defer presenter_destroy(&pr)

	for size in ([?][2]i32{{64, 48}, {80, 60}}) {
		sdl.SetWindowSize(window, size.x, size.y)
		w, h := window_pixels(window)
		testing.expect_value(t, [2]u32{w, h}, [2]u32{u32(size.x), u32(size.y)})
		vg.set_size(&c, w, h)
		vg.clear_rect(&c, 0, 0, w, h, vg.rgb(30, 60, 90))
		vg.path_reset(&p)
		vg.path_circle(&p, f32(w) / 2, f32(h) / 2, 17.3)
		vg.fill_path(&c, &p, vg.paint_color(vg.rgba(250, 200, 20, 255)))
		vg.flush(&c)
		testing.expect(t, present(&pr, &sw))

		surface := sdl.GetWindowSurface(window)
		testing.expect(t, surface != nil)
		px := vg.software_backend_pixels(&sw).data
		worst := 0
		for y in 0 ..< int(h) {
			for x in 0 ..< int(w) {
				r, g, b, a: u8
				sdl.ReadSurfacePixel(surface, i32(x), i32(y), &r, &g, &b, &a)
				want := px[(y * int(w) + x) * 4:][:3]
				worst = max(worst, abs(int(r) - int(want[0])), abs(int(g) - int(want[1])), abs(int(b) - int(want[2])))
			}
		}
		testing.expectf(t, worst == 0, "window differs from the frame by %d at %v", worst, size)
	}

	// A frame drawn into an image, presented from the image's pixels.
	img, err := vg.create_image_empty(&c, 80, 60, .RGBA8, {.Premultiplied})
	testing.expect_value(t, err, nil)
	vg.set_render_target(&c, img)
	vg.clear_rect(&c, 0, 0, 80, 60, vg.rgb(200, 30, 60))
	vg.path_reset(&p)
	vg.path_rect(&p, 10, 10, 30, 20)
	vg.fill_path(&c, &p, vg.paint_color(vg.rgb(10, 220, 90)))
	vg.set_render_target(&c, nil)
	vg.flush(&c)
	src, ok := vg.software_backend_image(&c, img)
	testing.expect(t, ok)
	testing.expect(t, present_pixels(&pr, src))
	surface := sdl.GetWindowSurface(window)
	worst := 0
	for y in 0 ..< 60 {
		for x in 0 ..< 80 {
			r, g, b, a: u8
			sdl.ReadSurfacePixel(surface, i32(x), i32(y), &r, &g, &b, &a)
			want := src.data[(y * 80 + x) * 4:][:3]
			worst = max(worst, abs(int(r) - int(want[0])), abs(int(g) - int(want[1])), abs(int(b) - int(want[2])))
		}
	}
	testing.expectf(t, worst == 0, "window differs from the image by %d", worst)
	testing.expect(t, !present_pixels(&pr, {.Gray8, src.data, 80, 60, 0}))
}
