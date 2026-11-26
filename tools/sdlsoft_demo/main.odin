// A window drawn by ovg's software backend and shown with no GPU device
// (sdlsoft): rounded panels, outlines, lines of text and a moving circle
// redrawn every frame. It prints, once a second, the frame time split into
// recording, rendering (flush, on a pool of every core) and presenting, and
// says at the start whether SDL could have made a GPU device here.
//
//	odin run tools/sdlsoft_demo -collection:deps=.. -o:speed [-- frames]
//
// With a frame count it quits after that many frames; otherwise on closing
// the window or Escape.
package sdlsoft_demo

import "core:fmt"
import "core:math"
import "core:os"
import "core:strconv"
import "core:time"
import common "deps:oicut/common"
import sdl "vendor:sdl3"
import vg "../.."
import "../../sdlsoft"

FONT :: #load("../../assets/Vera.ttf")

main :: proc() {
	limit := -1
	if len(os.args) > 1 {
		limit = strconv.parse_int(os.args[1]) or_else -1
	}
	if !sdl.Init({.VIDEO}) {
		fmt.eprintln("SDL video:", sdl.GetError())
		os.exit(1)
	}
	defer sdl.Quit()
	fmt.println("video driver:", sdl.GetCurrentVideoDriver())
	// Only to report: this demo never draws with it.
	if dev := sdl.CreateGPUDevice({.SPIRV, .DXBC, .DXIL, .MSL}, false, nil); dev != nil {
		fmt.println("SDL_GPU device available:", sdl.GetGPUDeviceDriver(dev), "(not used)")
		sdl.DestroyGPUDevice(dev)
	} else {
		fmt.println("no SDL_GPU device:", sdl.GetError())
	}
	window := sdl.CreateWindow("ovg software window", 1280, 800, {.RESIZABLE, .HIGH_PIXEL_DENSITY})
	if window == nil {
		fmt.eprintln("window:", sdl.GetError())
		os.exit(1)
	}
	defer sdl.DestroyWindow(window)

	sw: vg.Software_Backend
	vg.software_backend_init(&sw)
	defer vg.software_backend_destroy(&sw)
	pool: common.Static_Pool
	threads := os.get_processor_core_count()
	common.init_static_pool(&pool, threads)
	defer common.destroy_static_pool(&pool)
	sw.pool = &pool.work_pool
	c: vg.Canvas
	vg.canvas_init(&c, vg.software_backend(&sw))
	defer vg.canvas_destroy(&c)
	pr: sdlsoft.Presenter
	sdlsoft.presenter_init(&pr, window)
	defer sdlsoft.presenter_destroy(&pr)
	fonts: vg.Font_Collection
	vg.font_collection_init(&fonts, FONT)
	defer vg.font_collection_destroy(&fonts)
	lay: vg.Text_Layout
	defer vg.text_layout_destroy(&lay)
	p, scratch: vg.Path
	defer vg.path_destroy(&p)
	defer vg.path_destroy(&scratch)
	fmt.printfln("drawing on the CPU with %d threads, presented through the window surface", threads)

	start := time.tick_now()
	second := start
	frames, n: int
	rec, ren, pre: time.Duration
	loop: for limit < 0 || frames < limit {
		e: sdl.Event
		for sdl.PollEvent(&e) {
			#partial switch e.type {
			case .QUIT:
				break loop
			case .KEY_DOWN:
				if e.key.key == sdl.K_ESCAPE {
					break loop
				}
			}
		}
		w, h := sdlsoft.window_pixels(window)
		if w == 0 || h == 0 {
			continue
		}
		scale := f32(w) / 1280
		t := f32(time.duration_seconds(time.tick_since(start)))
		a := time.tick_now()
		vg.set_size(&c, w, h)
		vg.clear_rect(&c, 0, 0, w, h, vg.rgb(245, 246, 250))
		vg.save(&c)
		vg.scale(&c, scale, scale)
		for i in 0 ..< 300 {
			x, y := f32((i % 20) * 64), f32((i / 20) * 52)
			vg.path_reset(&p)
			vg.path_rounded_rect(&p, x + 2, y + 2, 60, 48, 6)
			vg.fill_path(&c, &p, vg.paint_color(vg.rgba(225, 228, 238, 255)))
			if i % 3 == 0 {
				o := vg.paint_color(vg.rgb(90, 100, 140))
				o.stroke.line_width = 1
				vg.stroke_path(&c, &p, o)
			}
		}
		for line in 0 ..< 40 {
			vg.text_layout(&fonts, {{text = "The quick brown fox jumps over the lazy dog 0123", style = {size = 13}}}, {x = 10, y = 20 + f32(line) * 19}, &lay)
			for run in lay.runs {
				vg.fill_glyph_outlines(&c, vg.text_layout_font(&lay, run), lay.glyphs[run.first:][:run.count], run.em, vg.paint_color(vg.rgb(20, 20, 30)), &scratch)
			}
		}
		vg.path_reset(&p)
		vg.path_circle(&p, 640 + 400 * math.cos(t), 400 + 250 * math.sin(1.3 * t), 60)
		vg.fill_path(&c, &p, vg.paint_color(vg.rgba(230, 80, 40, 200)))
		vg.restore(&c)
		b := time.tick_now()
		vg.flush(&c)
		d := time.tick_now()
		if !sdlsoft.present(&pr, &sw) {
			fmt.eprintln("present:", sdl.GetError())
			break
		}
		rec += time.tick_diff(a, b)
		ren += time.tick_diff(b, d)
		pre += time.tick_since(d)
		frames += 1
		n += 1
		if time.tick_since(second) >= time.Second {
			ms :: proc(d: time.Duration, n: int) -> f64 {return time.duration_milliseconds(d) / f64(n)}
			fmt.printfln("%dx%d  %d fps  record %.2f  render %.2f  present %.2f ms", w, h, n, ms(rec, n), ms(ren, n), ms(pre, n))
			second, n, rec, ren, pre = time.tick_now(), 0, 0, 0, 0
		}
	}
}
