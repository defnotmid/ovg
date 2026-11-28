package ovg

import "core:testing"

// A software canvas `w x h` for clip tests.
@(private = "file")
Clip_Target :: struct {
	backend: Software_Backend,
	canvas:  Canvas,
}

@(private = "file")
clip_open :: proc(t: ^Clip_Target, w, h: u32) {
	software_backend_init(&t.backend)
	canvas_init(&t.canvas, software_backend(&t.backend))
	set_size(&t.canvas, w, h)
}

@(private = "file")
clip_close :: proc(t: ^Clip_Target) {
	canvas_destroy(&t.canvas)
	software_backend_destroy(&t.backend)
}

@(private = "file")
clip_px :: proc(t: ^Clip_Target, x, y: int) -> [4]f32 {
	i := (y * int(t.backend.width) + x) * 4
	p := t.backend.pixels
	return {f32(p[i]), f32(p[i + 1]), f32(p[i + 2]), f32(p[i + 3])} / 255
}

@(private = "file")
clip_polygon :: proc(p: ^Path, pts: []Vec2) {
	path_reset(p)
	path_move_to(p, pts[0].x, pts[0].y)
	for q in pts[1:] {
		path_line_to(p, q.x, q.y)
	}
	path_close(p)
}

// The worst difference, in levels, between the target and white at
// `want(x, y)` coverage over black.
@(private = "file")
clip_worst :: proc(t: ^Clip_Target, w, h: int, want: proc(x, y: int) -> f32) -> f32 {
	worst: f32
	for y in 0 ..< h {
		for x in 0 ..< w {
			a := want(x, y)
			got := clip_px(t, x, y)
			worst = max(worst, abs(got.r - a), abs(got.g - a), abs(got.b - a), abs(got.a - 1))
		}
	}
	return worst * 255
}

@(private = "file")
CLIP_TRI :: [3]Vec2{{1.5, 2}, {21, 4.5}, {6, 20.5}}
@(private = "file")
CLIP_RECT :: [4]Vec2{{4.5, 3.25}, {17.75, 3.25}, {17.75, 22}, {4.5, 22}}

// Draws under a path clip take its exact coverage; nested, the product of
// each clip's; and `restore` drops them.
@(test)
test_clip_path_coverage :: proc(t: ^testing.T) {
	W, H :: 24, 24
	for nested in ([2]bool{false, true}) {
		tg: Clip_Target
		clip_open(&tg, W, H)
		c := &tg.canvas
		p: Path
		path_init(&p)
		clear_rect(c, 0, 0, W, H, {0, 0, 0, 1})
		save(c)
		tri := CLIP_TRI
		clip_polygon(&p, tri[:])
		clip_path(c, &p)
		if nested {
			rect := CLIP_RECT
			clip_polygon(&p, rect[:])
			clip_path(c, &p)
		}
		path_reset(&p)
		path_rect(&p, 0, 0, W, H)
		fill_path(c, &p, paint_color({1, 1, 1, 1}))
		restore(c)
		// Unclipped after the restore: a rectangle off the clips.
		path_reset(&p)
		path_rect(&p, 22, 22, 2, 2)
		fill_path(c, &p, paint_color({1, 1, 1, 1}))
		flush(c)
		want := proc(x, y: int) -> f32 {
			if x >= 22 && y >= 22 {
				return 1
			}
			tri := CLIP_TRI
			return pixel_area(tri[:], x, y)
		}
		if nested {
			want = proc(x, y: int) -> f32 {
				if x >= 22 && y >= 22 {
					return 1
				}
				tri, rect := CLIP_TRI, CLIP_RECT
				return pixel_area(tri[:], x, y) * pixel_area(rect[:], x, y)
			}
		}
		worst := clip_worst(&tg, W, H, want)
		testing.expectf(t, worst <= 1, "clip (nested %v) is %.2f levels from exact", nested, worst)
		path_destroy(&p)
		clip_close(&tg)
	}
}

// A clip still held when the frame ends clips the next frame too.
@(test)
test_clip_path_across_flush :: proc(t: ^testing.T) {
	W, H :: 24, 24
	tg: Clip_Target
	clip_open(&tg, W, H)
	defer clip_close(&tg)
	c := &tg.canvas
	p: Path
	path_init(&p)
	defer path_destroy(&p)
	save(c)
	tri := CLIP_TRI
	clip_polygon(&p, tri[:])
	clip_path(c, &p)
	clear_rect(c, 0, 0, W, H, {0, 0, 0, 1})
	flush(c)
	clear_rect(c, 0, 0, W, H, {0, 0, 0, 1})
	path_reset(&p)
	path_rect(&p, 0, 0, W, H)
	fill_path(c, &p, paint_color({1, 1, 1, 1}))
	flush(c)
	restore(c)
	worst := clip_worst(&tg, W, H, proc(x, y: int) -> f32 {
		tri := CLIP_TRI
		return pixel_area(tri[:], x, y)
	})
	testing.expectf(t, worst <= 1, "carried clip is %.2f levels from exact", worst)
}

// Clips one after another share their images by lifetime: where a
// backend's images are their own memory (the GPU's), a strip clip's image
// serves the next strip once the first is done; the outer clip's stays
// while its strips read it. Every draw is still cut exactly by its chain.
@(test)
test_clip_path_lifetimes :: proc(t: ^testing.T) {
	W, H :: 24, 24
	tg: Clip_Target
	clip_open(&tg, W, H)
	defer clip_close(&tg)
	c := &tg.canvas
	c.backend.transient_by_lifetime = false
	p: Path
	path_init(&p)
	defer path_destroy(&p)
	clear_rect(c, 0, 0, W, H, {0, 0, 0, 1})
	save(c)
	clip_polygon(&p, {{0, 0.5}, {20.5, 0.5}, {20.5, 24}, {0, 24}})
	clip_path(c, &p)
	for k in 0 ..< 6 {
		x := f32(k * 4) + 0.5
		save(c)
		clip_polygon(&p, {{x, 1}, {x + 3, 1.5}, {x + 3, 23}, {x, 23}})
		clip_path(c, &p)
		path_reset(&p)
		path_rect(&p, 0, 0, W, H)
		fill_path(c, &p, paint_color({1, 1, 1, 1}))
		restore(c)
	}
	restore(c)
	flush(c)
	testing.expectf(t, len(c.clip_pool) == 2, "%d clip images for 7 clips", len(c.clip_pool))
	worst := clip_worst(&tg, W, H, proc(x, y: int) -> f32 {
		outer := [4]Vec2{{0, 0.5}, {20.5, 0.5}, {20.5, 24}, {0, 24}}
		a: f32
		for k in 0 ..< 6 {
			s := f32(k * 4) + 0.5
			strip := [4]Vec2{{s, 1}, {s + 3, 1.5}, {s + 3, 23}, {s, 23}}
			a += pixel_area(strip[:], x, y)
		}
		return a * pixel_area(outer[:], x, y)
	})
	testing.expectf(t, worst <= 1, "clips sharing images are %.2f levels from exact", worst)
}

// A clip that is a rectangle on whole pixels is the scissor: no image.
@(test)
test_clip_path_whole_pixels :: proc(t: ^testing.T) {
	W, H :: 24, 24
	tg: Clip_Target
	clip_open(&tg, W, H)
	defer clip_close(&tg)
	c := &tg.canvas
	p: Path
	path_init(&p)
	defer path_destroy(&p)
	clear_rect(c, 0, 0, W, H, {0, 0, 0, 1})
	save(c)
	translate(c, 1, 2)
	clip_polygon(&p, {{2, 1}, {12, 1}, {12, 9}, {2, 9}})
	clip_path(c, &p)
	testing.expect_value(t, len(c.clips), 0)
	reset_transform(c)
	path_reset(&p)
	path_rect(&p, 0, 0, W, H)
	fill_path(c, &p, paint_color({1, 1, 1, 1}))
	restore(c)
	flush(c)
	worst := clip_worst(&tg, W, H, proc(x, y: int) -> f32 {
		return 1 if x >= 3 && x < 13 && y >= 3 && y < 11 else 0
	})
	testing.expectf(t, worst <= 0, "whole-pixel clip is %.2f levels off", worst)
}

// A 1:1 image under a clip (the software backend's direct copy can't cut
// it) takes the clip's coverage.
@(test)
test_clip_path_image :: proc(t: ^testing.T) {
	W, H :: 24, 24
	tg: Clip_Target
	clip_open(&tg, W, H)
	defer clip_close(&tg)
	c := &tg.canvas
	px := make([]u8, W * H * 4)
	defer delete(px)
	for i in 0 ..< W * H * 4 {
		px[i] = 255
	}
	img, err := create_image(c, {.RGBA8, px, W, H, 0}, {.Premultiplied})
	testing.expect_value(t, err, Error.None)
	p: Path
	path_init(&p)
	defer path_destroy(&p)
	clear_rect(c, 0, 0, W, H, {0, 0, 0, 1})
	save(c)
	tri := CLIP_TRI
	clip_polygon(&p, tri[:])
	clip_path(c, &p)
	path_reset(&p)
	path_rect(&p, 0, 0, W, H)
	fill_path(c, &p, paint_image(img, 0, 0, W, H, 0))
	restore(c)
	flush(c)
	worst := clip_worst(&tg, W, H, proc(x, y: int) -> f32 {
		tri := CLIP_TRI
		return pixel_area(tri[:], x, y)
	})
	testing.expectf(t, worst <= 1, "clipped image is %.2f levels from exact", worst)
}


// A clip that covers whole everything drawn under it cuts nothing: no
// image, its draws unclipped (and still exact); one that cuts keeps its.
@(test)
test_clip_path_covering :: proc(t: ^testing.T) {
	W, H :: 24, 24
	tg: Clip_Target
	clip_open(&tg, W, H)
	defer clip_close(&tg)
	c := &tg.canvas
	p: Path
	path_init(&p)
	defer path_destroy(&p)
	clear_rect(c, 0, 0, W, H, {0, 0, 0, 1})
	save(c)
	// A big triangle around a small square drawn inside it.
	clip_polygon(&p, {{-10, -10.5}, {40, 0.5}, {0.5, 40}})
	clip_path(c, &p)
	path_reset(&p)
	path_rect(&p, 2.5, 2.5, 6, 6)
	fill_path(c, &p, paint_color({1, 1, 1, 1}))
	restore(c)
	flush(c)
	testing.expectf(t, len(c.clip_pool) == 0, "%d clip images for a covering clip", len(c.clip_pool))
	worst := clip_worst(&tg, W, H, proc(x, y: int) -> f32 {
		sq := [4]Vec2{{2.5, 2.5}, {8.5, 2.5}, {8.5, 8.5}, {2.5, 8.5}}
		return pixel_area(sq[:], x, y)
	})
	testing.expectf(t, worst <= 1, "covering clip is %.2f levels from exact", worst)
}
