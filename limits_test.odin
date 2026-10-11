package ovg

import "base:runtime"
import "core:strings"
import "core:testing"

// Hostile input (limits.odin): each file finishes quickly, cut short with the
// limit recorded, instead of crashing, hanging or exhausting memory. These
// documents grow large arrays: the heap allocator, as programs use (the test
// runner's rollback stack copies a whole block on every resize).

@(private = "file")
Limits_Fx :: struct {
	backend: Software_Backend,
	canvas:  Canvas,
	layers:  Layer_Stack,
}

@(private = "file")
limits_fx_open :: proc(s: ^Limits_Fx) {
	software_backend_init(&s.backend)
	canvas_init(&s.canvas, software_backend(&s.backend))
	set_size(&s.canvas, 64, 64)
}

@(private = "file")
limits_fx_close :: proc(s: ^Limits_Fx) {
	layer_stack_destroy(&s.layers, &s.canvas)
	canvas_destroy(&s.canvas)
	software_backend_destroy(&s.backend)
}

@(private = "file")
has_warning :: proc(warnings: []string, part: string) -> bool {
	for w in warnings {
		if strings.contains(w, part) {
			return true
		}
	}
	return false
}

// Parses and draws `markup`; returns its warnings joined (temp allocator).
@(private = "file")
svg_hostile :: proc(t: ^testing.T, s: ^Limits_Fx, markup: string, loc := #caller_location) -> string {
	fonts: Font_Collection
	font_collection_init(&fonts)
	defer font_collection_destroy(&fonts)
	doc, err := svg_parse(transmute([]u8)markup, {fonts = &fonts})
	defer svg_destroy(&doc)
	testing.expect_value(t, err, Svg_Error.None, loc = loc)
	r: Svg_Renderer
	r.fonts = &fonts
	defer svg_renderer_destroy(&r, &s.canvas)
	clear_rect(&s.canvas, 0, 0, 64, 64, WHITE)
	layer_stack_begin(&s.layers, &s.canvas, 64, 64, nil, doc.uses_blend)
	svg_draw(&s.canvas, &s.layers, &r, &doc)
	layer_stack_end(&s.layers, &s.canvas)
	flush(&s.canvas)
	return strings.join(doc.warnings[:], "\n", context.temp_allocator)
}

@(test)
test_limits_svg :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	s: Limits_Fx
	limits_fx_open(&s)
	defer limits_fx_close(&s)
	b := strings.builder_make(context.temp_allocator)

	// 2000 nested groups: past Depth, the rest is skipped.
	strings.write_string(&b, `<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64">`)
	for _ in 0 ..< 2000 {
		strings.write_string(&b, "<g>")
	}
	strings.write_string(&b, `<rect width="10" height="10"/>`)
	for _ in 0 ..< 2000 {
		strings.write_string(&b, "</g>")
	}
	strings.write_string(&b, "</svg>")
	testing.expect(t, strings.contains(svg_hostile(t, &s, strings.to_string(b)), "nesting depth"))

	// <use> fan-out, ten copies a level: 10^7 elements asked for.
	strings.builder_reset(&b)
	strings.write_string(&b, `<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64"><defs><rect id="a0" width="1" height="1"/>`)
	for level in 1 ..= 7 {
		strings.write_string(&b, `<g id="a`)
		strings.write_int(&b, level)
		strings.write_string(&b, `">`)
		for _ in 0 ..< 10 {
			strings.write_string(&b, `<use href="#a`)
			strings.write_int(&b, level - 1)
			strings.write_string(&b, `"/>`)
		}
		strings.write_string(&b, "</g>")
	}
	strings.write_string(&b, `</defs><use href="#a7"/></svg>`)
	testing.expect(t, strings.contains(svg_hostile(t, &s, strings.to_string(b)), "SVG elements"))

	// Dashes too fine to count draw the stroke undashed.
	s.canvas.limited = {}
	svg_hostile(t, &s, `<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64"><path d="M0 32 H64" stroke="black" stroke-width="4" stroke-dasharray="1e-7"/></svg>`)
	testing.expect(t, .Dash_Segments in s.canvas.limited)
	testing.expect_value(t, s.backend.pixels[(32 * 64 + 32) * 4], 0)

	octaves := `<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64"><filter id="f"><feTurbulence baseFrequency="0.05" numOctaves="1000000000"/></filter><rect width="64" height="64" filter="url(#f)"/></svg>`
	testing.expect(t, strings.contains(svg_hostile(t, &s, octaves), "octaves"))

	strings.builder_reset(&b)
	strings.write_string(&b, `<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64"><filter id="f">`)
	for _ in 0 ..< 1000 {
		strings.write_string(&b, `<feOffset dx="0.01"/>`)
	}
	strings.write_string(&b, `</filter><rect width="10" height="10" filter="url(#f)"/></svg>`)
	testing.expect(t, strings.contains(svg_hostile(t, &s, strings.to_string(b)), "filter primitives"))

	// A descendant selector that cannot match backtracks over every
	// ancestor pairing: C(200, 4) steps for this one (selectors have at
	// most 6 parts).
	strings.builder_reset(&b)
	strings.write_string(&b, `<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64"><style>.nope g g g g rect { fill: red }</style>`)
	for _ in 0 ..< 200 {
		strings.write_string(&b, "<g>")
	}
	strings.write_string(&b, `<rect width="10" height="10"/>`)
	for _ in 0 ..< 200 {
		strings.write_string(&b, "</g>")
	}
	strings.write_string(&b, "</svg>")
	testing.expect(t, strings.contains(svg_hostile(t, &s, strings.to_string(b)), "CSS selector steps"))
}

@(private = "file")
lottie_hostile :: proc(t: ^testing.T, s: ^Limits_Fx, json: string, loc := #caller_location) -> (warnings: string, limited: bit_set[Limit]) {
	doc, err := lottie_parse(transmute([]u8)json)
	defer lottie_destroy(&doc)
	testing.expect_value(t, err, Lottie_Error.None, loc = loc)
	r: Lottie_Renderer
	defer lottie_renderer_destroy(&r, &s.canvas)
	for frame in ([]f32{0, 5}) {
		clear_rect(&s.canvas, 0, 0, 64, 64, WHITE)
		layer_stack_begin(&s.layers, &s.canvas, 64, 64, nil, doc.uses_blend)
		lottie_draw(&s.canvas, &s.layers, &r, &doc, frame)
		layer_stack_end(&s.layers, &s.canvas)
		flush(&s.canvas)
		limited += r.limited
	}
	return strings.join(doc.warnings[:], "\n", context.temp_allocator), limited
}

@(test)
test_limits_lottie :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	s: Limits_Fx
	limits_fx_open(&s)
	defer limits_fx_close(&s)
	HEAD :: `{"v": "5.7.0", "fr": 30, "ip": 0, "op": 60, "w": 64, "h": 64, `

	// Keyframe values of the wrong type or length are dropped, not read
	// past their end.
	bad_keys := HEAD + `"layers": [{"ty": 4, "ip": 0, "op": 60, "st": 0,
		"ks": {"o": {"a": 1, "k": [{"t": 0, "s": {}}, {"t": 10, "s": [50]}]}},
		"shapes": [
			{"ty": "sh", "ks": {"a": 1, "k": [{"t": 0, "s": 5}, {"t": 10, "s": 6}]}},
			{"ty": "rc", "p": {"a": 0, "k": [32, 32]}, "s": {"a": 0, "k": [20, 20]}, "r": {"a": 0, "k": 0}},
			{"ty": "fl", "o": {"a": 0, "k": 100}, "c": {"a": 1, "k": [{"t": 0, "s": [1, 0, 0, 1], "e": [0.5]}, {"t": 10}]}}
		]}]}`
	w, _ := lottie_hostile(t, &s, bad_keys)
	testing.expect(t, strings.contains(w, "mismatched"))

	// Nested repeaters: 1000 x 1000 copies asked for.
	nested := HEAD + `"layers": [{"ty": 4, "ip": 0, "op": 60, "st": 0, "ks": {}, "shapes": [{"ty": "gr", "it": [
		{"ty": "gr", "it": [
			{"ty": "rc", "p": {"a": 0, "k": [32, 32]}, "s": {"a": 0, "k": [4, 4]}, "r": {"a": 0, "k": 0}},
			{"ty": "fl", "c": {"a": 0, "k": [1, 0, 0, 1]}, "o": {"a": 0, "k": 100}},
			{"ty": "rp", "c": {"a": 0, "k": 1000}, "tr": {}}]},
		{"ty": "rp", "c": {"a": 0, "k": 1000}, "tr": {}}]}]}]}`
	_, limited := lottie_hostile(t, &s, nested)
	testing.expect(t, .Repeater_Copies in limited)

	// A precomp drawing itself six times a level: 6^16 layers asked for.
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, HEAD + `"layers": [{"ty": 0, "refId": "c", "ip": 0, "op": 60, "st": 0, "ks": {}, "w": 64, "h": 64}], "assets": [{"id": "c", "w": 64, "h": 64, "layers": [`)
	for i in 0 ..< 6 {
		if i > 0 {
			strings.write_string(&b, ", ")
		}
		strings.write_string(&b, `{"ty": 0, "refId": "c", "ip": 0, "op": 60, "st": 0, "ks": {}, "w": 64, "h": 64}`)
	}
	strings.write_string(&b, "]}]}")
	_, limited = lottie_hostile(t, &s, strings.to_string(b))
	testing.expect(t, .Lottie_Layers in limited)

	star := HEAD + `"layers": [{"ty": 4, "ip": 0, "op": 60, "st": 0, "ks": {}, "shapes": [
		{"ty": "sr", "sy": 1, "p": {"a": 0, "k": [32, 32]}, "pt": {"a": 0, "k": 1e9}, "or": {"a": 0, "k": 20}, "ir": {"a": 0, "k": 10}, "r": {"a": 0, "k": 0}, "os": {"a": 0, "k": 0}, "is": {"a": 0, "k": 0}},
		{"ty": "fl", "c": {"a": 0, "k": [1, 0, 0, 1]}, "o": {"a": 0, "k": 100}}]}]}`
	_, limited = lottie_hostile(t, &s, star)
	testing.expect(t, .Star_Points in limited)

	// JSON nested past Depth is refused before core:encoding/json recurses.
	strings.builder_reset(&b)
	strings.write_string(&b, HEAD + `"layers": [], "x": `)
	for _ in 0 ..< 5000 {
		strings.write_byte(&b, '[')
	}
	for _ in 0 ..< 5000 {
		strings.write_byte(&b, ']')
	}
	strings.write_byte(&b, '}')
	doc, err := lottie_parse(transmute([]u8)strings.to_string(b))
	lottie_destroy(&doc)
	testing.expect_value(t, err, Lottie_Error.Too_Deep)
}

// The fill cap is per glyph: a face keeps drawing colour glyphs after
// thousands of fills are cached for earlier ones.
@(test)
test_colr_many_glyphs :: proc(t: ^testing.T) {
	f, err := font_load(EMOJI_FONT_DATA)
	testing.expect_value(t, err, nil)
	defer font_destroy(&f)
	cl := f.colr
	testing.expect(t, cl != nil)
	last := Colr_Glyph{}
	colour := 0
	for g in Glyph_Index(1) ..< 1000 {
		if font_glyph_is_colour(&f, g) {
			colour += 1
			last = colr_glyph(cl, g)
		}
	}
	testing.expect(t, colour > 500)
	testing.expect(t, len(cl.fills) > 4096)
	testing.expect(t, last.count > 0)
}
