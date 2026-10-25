// Benchmarks the CPU side of ovg on generated workloads (no third-party
// files): parsing, then recording warm frames on a recording canvas (no
// rasterization), with the allocations each warm frame makes, heap and
// temp allocator counted apart, and the frame's size.
//
//     odin run tools/bench -collection:deps=.. -o:speed [-- -n:200 -only:svg]
//
// Workloads: a styled SVG scene (cascade, gradients, clips, masks, group
// opacity, a filter), an SVG of text, a Lottie scene (keyframes, trims,
// dashes, a repeater, precomps, a text layer with an animator), mixed
// script text layout, and canvas drawing (gradients fading per frame,
// dashed strokes, nested layers). Compare runs before and after a change;
// a warm frame should allocate nothing.
package bench

import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"
import vg "../.."

Result :: struct {
	name:        string,
	parse_ms:    f64, // best of the runs; 0 when nothing parses
	frame_ms:    f64, // median warm frame
	allocs:      f64, // heap allocations per warm frame
	alloc_kib:   f64,
	temp_allocs: f64, // temp allocator allocations per warm frame
	temp_kib:    f64,
	commands:    int,
	command_kib: f64,
	verts:       int,
	image_ops:   int, // image allocations, uploads and frees handed to the backend
}

Bench :: struct {
	frames:  int,
	canvas:  vg.Canvas,
	layers:  vg.Layer_Stack,
	frame:   vg.Recorded_Frame,
	fonts:   vg.Font_Collection,
	results: [dynamic]Result,
}

// The state a workload draws with; `draw` records frame `i`.
Workload :: struct {
	name:  string,
	user:  rawptr,
	draw:  proc(b: ^Bench, user: rawptr, i: int),
	parse: proc(b: ^Bench, user: rawptr) -> f64, // ms of one parse, nil if none
}

main :: proc() {
	b: Bench
	b.frames = 120
	only := ""
	for a in os.args[1:] {
		switch {
		case strings.has_prefix(a, "-n:"):
			b.frames, _ = strconv.parse_int(a[3:])
		case strings.has_prefix(a, "-only:"):
			only = a[6:]
		case:
			fmt.eprintln("usage: bench [-n:frames] [-only:name-prefix]")
			os.exit(2)
		}
	}
	vg.canvas_init_recording(&b.canvas)
	vg.font_collection_init(&b.fonts)

	svg := svg_scene_open(&b, svg_scene_markup(8000))
	svg_text := svg_scene_open(&b, svg_text_markup(300))
	lottie := lottie_open(&b, lottie_scene_json(200))
	text: Text_Work
	canvas: Canvas_Work
	works := [?]Workload {
		{"svg scene", &svg, svg_draw, svg_parse},
		{"svg text", &svg_text, svg_draw, svg_parse},
		{"lottie scene", &lottie, lottie_draw_frame, lottie_parse},
		{"text layout", &text, text_draw, nil},
		{"canvas", &canvas, canvas_draw, nil},
	}
	for &w in works {
		if only == "" || strings.has_prefix(w.name, only) {
			run(&b, &w)
		}
	}

	fmt.printfln("%d warm frames each (recording canvas, no rasterization)\n", b.frames)
	fmt.printfln("%-14s %9s %9s %9s %9s %9s %9s %9s %9s %8s %8s", "workload", "parse ms", "frame ms", "allocs", "KiB", "temp", "temp KiB", "commands", "cmd KiB", "verts", "img ops")
	// Odin pads numbers given a width with zeros: format them first.
	f :: proc(v: f64, decimals := 1) -> string {
		return fmt.tprintf("%.*f", decimals, v)
	}
	for r in b.results {
		parse := f(r.parse_ms, 2) if r.parse_ms > 0 else "-"
		fmt.printfln("%-14s %9s %9s %9s %9s %9s %9s %9s %9s %8s %8s", r.name, parse, f(r.frame_ms, 3), f(r.allocs), f(r.alloc_kib), f(r.temp_allocs), f(r.temp_kib), fmt.tprint(r.commands), f(r.command_kib), fmt.tprint(r.verts), fmt.tprint(r.image_ops))
	}
	fmt.printfln("\nallocs / KiB: heap allocations per warm frame; temp: context.temp_allocator's; img ops: the last frame's image work for the backend (uploads). Command size: %d bytes.", size_of(vg.Command))
}

run :: proc(b: ^Bench, w: ^Workload) {
	r := Result{name = w.name}
	if w.parse != nil {
		r.parse_ms = max(f64)
		for _ in 0 ..< 5 {
			r.parse_ms = min(r.parse_ms, w.parse(b, w.user))
		}
	}
	// Warm up: every buffer grows to its size.
	for i in 0 ..< 10 {
		record(b, w, i)
	}
	heap: mem.Tracking_Allocator
	mem.tracking_allocator_init(&heap, context.allocator)
	defer mem.tracking_allocator_destroy(&heap)
	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	defer virtual.arena_destroy(&arena)
	temp: mem.Tracking_Allocator
	mem.tracking_allocator_init(&temp, virtual.arena_allocator(&arena))
	defer mem.tracking_allocator_destroy(&temp)

	times := make([]f64, b.frames)
	defer delete(times)
	{
		context.allocator = mem.tracking_allocator(&heap)
		context.temp_allocator = mem.tracking_allocator(&temp)
		for i in 0 ..< b.frames {
			t0 := time.tick_now()
			record(b, w, 10 + i)
			times[i] = time.duration_milliseconds(time.tick_since(t0))
		}
	}
	slice.sort(times)
	n := f64(b.frames)
	r.frame_ms = times[len(times) / 2]
	r.allocs = f64(heap.total_allocation_count) / n
	r.alloc_kib = f64(heap.total_memory_allocated) / n / 1024
	r.temp_allocs = f64(temp.total_allocation_count) / n
	r.temp_kib = f64(temp.total_memory_allocated) / n / 1024
	r.commands = len(b.frame.commands)
	r.command_kib = f64(len(b.frame.commands) * size_of(vg.Command)) / 1024
	r.verts = len(b.frame.verts)
	r.image_ops = len(b.frame.image_ops)
	append(&b.results, r)
}

record :: proc(b: ^Bench, w: ^Workload, i: int) {
	vg.set_size(&b.canvas, 1000, 1000)
	vg.layer_stack_begin(&b.layers, &b.canvas, 1000, 1000)
	w.draw(b, w.user, i)
	vg.layer_stack_end(&b.layers, &b.canvas)
	vg.canvas_take(&b.canvas, &b.frame)
}

// A deterministic stream of numbers in [0, 1).
Rng :: struct {
	s: u32,
}

rand :: proc(r: ^Rng) -> f32 {
	r.s = r.s * 1664525 + 1013904223
	return f32(r.s >> 8) / f32(1 << 24)
}

// ---- SVG -------------------------------------------------------------------------

Svg_Work :: struct {
	markup:   string,
	doc:      vg.Svg_Document,
	text:     vg.Svg_Layout,
	renderer: vg.Svg_Renderer,
}

svg_scene_open :: proc(b: ^Bench, markup: string) -> Svg_Work {
	w := Svg_Work{markup = markup}
	doc, err := vg.svg_parse(transmute([]u8)markup, {fonts = &b.fonts})
	if err != nil {
		fmt.eprintln("svg parse failed:", err)
		os.exit(1)
	}
	w.doc = doc
	vg.svg_layout(&w.doc, &b.fonts, &w.text)
	vg.svg_renderer_bind(&w.renderer, &b.canvas, &w.doc)
	return w
}

svg_parse :: proc(b: ^Bench, user: rawptr) -> f64 {
	w := (^Svg_Work)(user)
	t0 := time.tick_now()
	doc, _ := vg.svg_parse(transmute([]u8)w.markup, {fonts = &b.fonts})
	ms := time.duration_milliseconds(time.tick_since(t0))
	vg.svg_destroy(&doc)
	return ms
}

svg_draw :: proc(b: ^Bench, user: rawptr, i: int) {
	w := (^Svg_Work)(user)
	// One part moves every frame, as a host animating by id would.
	ovs := [?]vg.Svg_Override{{id = "g3", transform = vg.transform_rotation(f32(i) * 0.01)}}
	xf := vg.transform_scaling(1000 / w.doc.width, 1000 / w.doc.height)
	vg.svg_draw(&b.canvas, &b.layers, &w.renderer, &w.doc, &w.text, xf, ovs[:])
}

// `n` shapes in groups of 20 under a style sheet, gradients, a pattern of
// effects (opacity, clips, masks, a blur) on some groups.
svg_scene_markup :: proc(n: int) -> string {
	sb := strings.builder_make()
	r := Rng{1}
	strings.write_string(&sb, `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1000 1000" width="1000" height="1000">
<style>.a { fill: #3366cc } .b { fill: url(#g1) } .s rect { stroke: #222; stroke-width: 2 } g > .c { fill-opacity: 0.6 } #g3 circle { stroke: red }</style>
<defs>`)
	for k in 0 ..< 8 {
		fmt.sbprintf(&sb, `<linearGradient id="g%d" x1="0" x2="1"><stop offset="0" stop-color="#%06x"/><stop offset="0.5" stop-color="#%06x" stop-opacity="0.5"/><stop offset="1" stop-color="#%06x"/></linearGradient>`, k, u32(rand(&r) * 0xffffff), u32(rand(&r) * 0xffffff), u32(rand(&r) * 0xffffff))
	}
	strings.write_string(&sb, `<radialGradient id="rg" fx="0.3" fy="0.3"><stop offset="0" stop-color="white"/><stop offset="1" stop-color="navy"/></radialGradient>
<clipPath id="clip"><circle cx="25" cy="25" r="25"/></clipPath>
<mask id="mask"><rect width="50" height="50" fill="white"/><circle cx="25" cy="25" r="10" fill="black"/></mask>
<filter id="blur"><feGaussianBlur stdDeviation="2"/></filter>
</defs>`)
	groups := (n + 19) / 20
	for gi in 0 ..< groups {
		x, y := f32(gi % 20) * 50, f32(gi / 20 % 20) * 50
		effect := ""
		switch gi % 16 {
		case 3:
			effect = ` opacity="0.5"`
		case 7:
			effect = ` clip-path="url(#clip)"`
		case 11:
			effect = ` mask="url(#mask)"`
		case 15:
			effect = ` filter="url(#blur)"`
		}
		fmt.sbprintf(&sb, `<g id="g%d" class="s" transform="translate(%.1f %.1f)"%s>`, gi, x, y, effect)
		for k in 0 ..< 20 {
			if gi * 20 + k >= n {
				break
			}
			px, py, s := rand(&r) * 40, rand(&r) * 40, 4 + rand(&r) * 10
			switch k % 5 {
			case 0:
				fmt.sbprintf(&sb, `<rect class="a" x="%.1f" y="%.1f" width="%.1f" height="%.1f" rx="2"/>`, px, py, s, s)
			case 1:
				fmt.sbprintf(&sb, `<circle class="c" cx="%.1f" cy="%.1f" r="%.1f" fill="url(#g%d)"/>`, px, py, s / 2, k % 8)
			case 2:
				fmt.sbprintf(&sb, `<path d="M%.1f %.1f c 5 -8 12 -8 %.1f 0 s 4 9 -3 %.1f z" fill="url(#rg)"/>`, px, py, s, s)
			case 3:
				fmt.sbprintf(&sb, `<ellipse class="b" cx="%.1f" cy="%.1f" rx="%.1f" ry="%.1f"/>`, px, py, s, s / 2)
			case 4:
				fmt.sbprintf(&sb, `<polyline points="%.1f,%.1f %.1f,%.1f %.1f,%.1f" fill="none" stroke="#0a0" stroke-dasharray="3 2"/>`, px, py, px + s, py + 2, px + 2, py + s)
			}
		}
		strings.write_string(&sb, "</g>")
	}
	strings.write_string(&sb, "</svg>")
	return strings.to_string(sb)
}

// `n` lines of text with tspans and letter-spacing.
svg_text_markup :: proc(n: int) -> string {
	sb := strings.builder_make()
	strings.write_string(&sb, `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1000 1000" width="1000" height="1000"><g id="g3">`)
	for k in 0 ..< n {
		fmt.sbprintf(&sb, `<text x="%d" y="%d" font-size="11">Line %d: the <tspan font-weight="bold">quick</tspan> brown fox <tspan letter-spacing="1">jumps</tspan> over 42 lazy dogs.</text>`, (k % 3) * 330, 12 + (k / 3) * 10 % 990, k)
	}
	strings.write_string(&sb, "</g></svg>")
	return strings.to_string(sb)
}

// ---- Lottie ------------------------------------------------------------------------

Lottie_Work :: struct {
	json:     string,
	doc:      vg.Lottie_Document,
	renderer: vg.Lottie_Renderer,
}

lottie_open :: proc(b: ^Bench, json: string) -> Lottie_Work {
	w := Lottie_Work{json = json}
	doc, err := vg.lottie_parse(transmute([]u8)json)
	if err != nil {
		fmt.eprintln("lottie parse failed:", err)
		os.exit(1)
	}
	w.doc = doc
	vg.lottie_renderer_bind(&w.renderer, &b.canvas, &w.doc)
	return w
}

lottie_parse :: proc(b: ^Bench, user: rawptr) -> f64 {
	w := (^Lottie_Work)(user)
	t0 := time.tick_now()
	doc, _ := vg.lottie_parse(transmute([]u8)w.json)
	ms := time.duration_milliseconds(time.tick_since(t0))
	vg.lottie_destroy(&doc)
	return ms
}

lottie_draw_frame :: proc(b: ^Bench, user: rawptr, i: int) {
	w := (^Lottie_Work)(user)
	w.renderer.fonts = &b.fonts
	vg.lottie_draw(&b.canvas, &b.layers, &w.renderer, &w.doc, f32(i % 120), vg.transform_scaling(2, 2))
}

// `n` shape layers (keyframed groups with fills, dashed strokes and trims),
// a repeater, precomp instances and a text layer with an animator.
lottie_scene_json :: proc(n: int) -> string {
	sb := strings.builder_make()
	r := Rng{7}
	strings.write_string(&sb, `{"v": "5.7.0", "fr": 30, "ip": 0, "op": 120, "w": 500, "h": 500, "assets": [{"id": "pc", "layers": [`)
	shape_layer :: proc(sb: ^strings.Builder, r: ^Rng, ind: int) {
		x, y := rand(r) * 500, rand(r) * 500
		fmt.sbprintf(sb, `{{"ty": 4, "ind": %d, "ip": 0, "op": 120, "st": 0, "ks": {{"p": {{"a": 0, "k": [%.1f, %.1f]}}, "r": {{"a": 1, "k": [{{"t": 0, "s": [0], "o": {{"x": [0.4], "y": [0]}}, "i": {{"x": [0.6], "y": [1]}}}}, {{"t": 120, "s": [360]}}]}}}}, "shapes": [{{"ty": "gr", "it": [`, ind, x, y)
		fmt.sbprintf(sb, `{{"ty": "el", "p": {{"a": 0, "k": [0, 0]}}, "s": {{"a": 1, "k": [{{"t": 0, "s": [10, 10]}}, {{"t": 60, "s": [%.1f, 30]}}, {{"t": 120, "s": [10, 10]}}]}}}},`, 20 + rand(r) * 30)
		strings.write_string(sb, `{"ty": "rc", "p": {"a": 0, "k": [12, 0]}, "s": {"a": 0, "k": [16, 8]}, "r": {"a": 0, "k": 3}},`)
		strings.write_string(sb, `{"ty": "tm", "s": {"a": 0, "k": 0}, "e": {"a": 1, "k": [{"t": 0, "s": [20]}, {"t": 120, "s": [100]}]}, "o": {"a": 0, "k": 0}, "m": 1},`)
		fmt.sbprintf(sb, `{{"ty": "fl", "c": {{"a": 0, "k": [%.2f, %.2f, 0.8, 1]}}, "o": {{"a": 0, "k": 90}}}},`, rand(r), rand(r))
		strings.write_string(sb, `{"ty": "st", "c": {"a": 0, "k": [0, 0, 0, 1]}, "o": {"a": 0, "k": 100}, "w": {"a": 0, "k": 1.5}, "d": [{"n": "d", "v": {"a": 0, "k": 4}}, {"n": "g", "v": {"a": 0, "k": 2}}]},`)
		strings.write_string(sb, `{"ty": "tr", "o": {"a": 0, "k": 100}}]}]}`)
	}
	for k in 0 ..< 10 {
		if k > 0 {
			strings.write_string(&sb, ", ")
		}
		shape_layer(&sb, &r, k + 1)
	}
	strings.write_string(&sb, `]}], "layers": [`)
	strings.write_string(&sb, `{"ty": 5, "ind": 1, "ip": 0, "op": 120, "st": 0, "ks": {"p": {"a": 0, "k": [20, 40]}}, "t": {"d": {"k": [{"t": 0, "s": {"t": "Benchmarking ovg text, one letter at a time", "s": 18, "fc": [0, 0, 0], "lh": 22}}]}, "m": {"g": 1}, "a": [{"s": {"t": 0, "b": 1, "sh": 4, "s": {"a": 1, "k": [{"t": 0, "s": [0]}, {"t": 120, "s": [100]}]}}, "a": {"p": {"a": 0, "k": [0, -10]}, "o": {"a": 0, "k": 0}}}]}},`)
	strings.write_string(&sb, `{"ty": 4, "ind": 2, "ip": 0, "op": 120, "st": 0, "ks": {"p": {"a": 0, "k": [250, 250]}}, "shapes": [{"ty": "rc", "p": {"a": 0, "k": [100, 0]}, "s": {"a": 0, "k": [10, 4]}, "r": {"a": 0, "k": 0}}, {"ty": "fl", "c": {"a": 0, "k": [1, 0.5, 0, 1]}, "o": {"a": 0, "k": 100}}, {"ty": "rp", "c": {"a": 0, "k": 60}, "o": {"a": 0, "k": 0}, "m": 1, "tr": {"p": {"a": 0, "k": [0, 0]}, "a": {"a": 0, "k": [0, 0]}, "s": {"a": 0, "k": [100, 100]}, "r": {"a": 1, "k": [{"t": 0, "s": [6]}, {"t": 120, "s": [12]}]}, "so": {"a": 0, "k": 100}, "eo": {"a": 0, "k": 20}}}]},`)
	for k in 0 ..< 4 {
		fmt.sbprintf(&sb, `{{"ty": 0, "ind": %d, "refId": "pc", "ip": 0, "op": 120, "st": %d, "w": 500, "h": 500, "ks": {{"o": {{"a": 0, "k": 80}}}}}},`, 3 + k, -k * 10)
	}
	for k in 0 ..< n {
		if k > 0 {
			strings.write_string(&sb, ", ")
		}
		shape_layer(&sb, &r, 7 + k)
	}
	strings.write_string(&sb, "]}")
	return strings.to_string(sb)
}

// ---- text and canvas ---------------------------------------------------------------

Text_Work :: struct {
	layout: vg.Text_Layout,
}

text_draw :: proc(b: ^Bench, user: rawptr, i: int) {
	w := (^Text_Work)(user)
	lines := [?]string {
		"The quick brown fox jumps over the lazy dog, 1234567890.",
		"Ligatures: office, affinity, flow; kerning: AVAT Ty To.",
		"Mixed: abc مرحبا 42 def and an emoji 👍 at the end.",
	}
	for line, k in lines {
		pieces := [?]vg.Text_Piece{{text = line, style = {size = 16 + f32(k)}}}
		vg.text_layout(&b.fonts, pieces[:], {x = 10, y = 30 + f32(k) * 24}, &w.layout)
		for run in w.layout.runs {
			vg.fill_glyph_outlines(&b.canvas, vg.text_layout_font(&w.layout, run), w.layout.glyphs[run.first:][:run.count], run.em, vg.paint_color(vg.BLACK), &b.layers.scratch)
		}
	}
}

Canvas_Work :: struct {
	path: vg.Path,
}

// Rounded rects with a multi-stop gradient fading with the frame, dashed
// outlines, and nested translucent layers.
canvas_draw :: proc(b: ^Bench, user: rawptr, i: int) {
	w := (^Canvas_Work)(user)
	c := &b.canvas
	fade := 0.5 + 0.5 * f32(i % 60) / 60
	stops := [?]vg.Gradient_Stop{{0, vg.rgb(255, 80, 0)}, {0.5, vg.rgba(0, 200, 120, 200)}, {1, vg.rgb(30, 60, 255)}}
	for depth in 0 ..< 3 {
		vg.layer_push(&b.layers, c, {opacity = 0.9})
		for k in 0 ..< 600 {
			x, y := f32(k % 30) * 32 + f32(depth) * 4, f32(k / 30) * 32 + f32(depth) * 4
			vg.path_reset(&w.path)
			vg.path_rounded_rect(&w.path, x, y, 26, 26, 5)
			p := vg.paint_linear_gradient_stops(x, y, x + 26, y + 26, stops[:])
			vg.set_global_alpha(c, fade)
			vg.fill_path(c, &w.path, p)
			vg.set_global_alpha(c, 1)
			st := vg.paint_color(vg.BLACK)
			st.stroke.line_width = 1
			dash := [?]f32{3, 2}
			st.stroke.dash = dash[:]
			vg.stroke_path(c, &w.path, st)
		}
	}
	for _ in 0 ..< 3 {
		vg.layer_pop(&b.layers, c)
	}
}
