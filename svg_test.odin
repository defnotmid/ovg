package ovg

import "core:testing"

// SVG import: parsing into the document tables, then drawing on the
// software backend and reading pixels back.

@(private = "file")
Svg_Fx :: struct {
	backend: Software_Backend,
	canvas:  Canvas,
	layers:  Layer_Stack,
	r:       Svg_Renderer,
	fonts:   Font_Collection,
	doc:     Svg_Document,
}

@(private = "file")
svg_fx_open :: proc(s: ^Svg_Fx, markup: string) -> Svg_Error {
	software_backend_init(&s.backend)
	canvas_init(&s.canvas, software_backend(&s.backend))
	font_collection_init(&s.fonts)
	s.r.fonts = &s.fonts
	err: Svg_Error
	s.doc, err = svg_parse(transmute([]u8)markup, {fonts = &s.fonts})
	return err
}

@(private = "file")
svg_fx_close :: proc(s: ^Svg_Fx) {
	svg_renderer_destroy(&s.r, &s.canvas)
	svg_destroy(&s.doc)
	layer_stack_destroy(&s.layers, &s.canvas)
	canvas_destroy(&s.canvas)
	software_backend_destroy(&s.backend)
	font_collection_destroy(&s.fonts)
}

// Draws the document at its size on white (premultiplied output).
@(private = "file")
svg_fx_draw :: proc(s: ^Svg_Fx, overrides: []Svg_Override = nil) {
	w, h := u32(s.doc.width), u32(s.doc.height)
	set_size(&s.canvas, w, h)
	clear_rect(&s.canvas, 0, 0, w, h, WHITE)
	layer_stack_begin(&s.layers, &s.canvas, w, h, nil, s.doc.uses_blend)
	svg_draw(&s.canvas, &s.layers, &s.r, &s.doc, TRANSFORM_IDENTITY, overrides)
	layer_stack_end(&s.layers, &s.canvas)
	flush(&s.canvas)
}

@(private = "file")
svg_px :: proc(s: ^Svg_Fx, x, y: int) -> [4]u8 {
	i := (y * int(s.backend.width) + x) * 4
	p := s.backend.pixels
	return {p[i], p[i + 1], p[i + 2], p[i + 3]}
}

@(private = "file")
close_to :: proc(a, b: [4]u8, tol := 2) -> bool {
	for i in 0 ..< 4 {
		if abs(int(a[i]) - int(b[i])) > tol {
			return false
		}
	}
	return true
}

@(test)
test_svg_parse_tables :: proc(t: ^testing.T) {
	s: Svg_Fx
	defer svg_fx_close(&s)
	err := svg_fx_open(&s, `<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" viewBox="0 0 200 100" width="400">
		<style>.blue { fill: #0000ff } #big { stroke-width: 4 }</style>
		<defs>
			<linearGradient id="base" x1="0" x2="1"><stop offset="0" stop-color="red"/><stop offset="1" stop-color="blue"/></linearGradient>
			<linearGradient id="derived" xlink:href="#base" gradientUnits="userSpaceOnUse" x2="50"/>
			<symbol id="sym" viewBox="0 0 10 10"><rect id="cell" width="10" height="10"/></symbol>
		</defs>
		<g fill="green" color="#123456">
			<rect id="big" class="blue" x="10" y="10" width="50" height="20" stroke="currentColor"/>
			<circle cx="100" cy="50" r="20" fill="url(#derived)"/>
			<use xlink:href="#sym" x="150" y="10" width="40" height="40"/>
			<use xlink:href="#big" y="50"/>
		</g>
		<text x="10" y="90" font-size="12" dx="2">A <tspan font-weight="bold">B</tspan></text>
	</svg>`)
	testing.expect_value(t, err, Svg_Error.None)
	// width 400 with a 2:1 viewBox: the height follows its aspect.
	testing.expect_value(t, s.doc.width, 400)
	testing.expect_value(t, s.doc.height, 200)
	testing.expect_value(t, s.doc.nodes[0].transform, Transform2D{2, 0, 0, 2, 0, 0})

	big := svg_find(&s.doc, "big")
	testing.expect(t, big >= 0)
	sh := s.doc.shapes[s.doc.nodes[big].data]
	// Class rule beats the inherited fill; the id rule sets the width;
	// currentColor follows the inherited color.
	testing.expect_value(t, sh.style.fill.color, Color{0, 0, 1, 1})
	testing.expect_value(t, sh.style.stroke_width, 4)
	testing.expect(t, close_to({u8(sh.style.stroke.color.r * 255 + 0.5), u8(sh.style.stroke.color.g * 255 + 0.5), u8(sh.style.stroke.color.b * 255 + 0.5), 255}, {0x12, 0x34, 0x56, 255}, 0))
	testing.expect_value(t, s.doc.nodes[big].bbox, Rect{10, 10, 50, 20})

	// The derived gradient keeps the base's stops and x1 but its own units and x2.
	testing.expect_value(t, len(s.doc.servers), 1)
	g := s.doc.servers[0]
	testing.expect(t, !g.bbox_units)
	testing.expect_value(t, g.v[2], 50)
	testing.expect_value(t, g.stops.count, 2)

	// The <use> of #big is a second instance with the same id; the symbol
	// instance maps its viewBox into 40 x 40.
	instances := 0
	for n in s.doc.nodes {
		if n.id >= 0 && s.doc.ids[n.id] == "big" {
			instances += 1
		}
	}
	testing.expect_value(t, instances, 2)
	cell := svg_find(&s.doc, "cell")
	testing.expect(t, cell >= 0)
	sym := s.doc.nodes[s.doc.nodes[cell].parent]
	testing.expect_value(t, sym.transform, Transform2D{4, 0, 0, 4, 0, 0})
	testing.expect(t, .Clip_Rect in sym.flags)

	// Text: one chunk, "A " and "B" (whitespace collapsed, bold span).
	testing.expect_value(t, len(s.doc.texts), 1)
	testing.expect_value(t, len(s.doc.pieces), 2)
	testing.expect_value(t, s.doc.pieces[0].text, "A ")
	testing.expect_value(t, s.doc.pieces[0].dx, 2)
	testing.expect_value(t, s.doc.pieces[1].weight, 700)
}

@(test)
test_svg_parse_errors :: proc(t: ^testing.T) {
	_, err := svg_parse(transmute([]u8)string("<html></html>"))
	testing.expect_value(t, err, Svg_Error.Not_Svg)
	doc, err2 := svg_parse(transmute([]u8)string(`<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"><blink/><rect width="5" height="5" marker-end="url(#m)"/></svg>`))
	defer svg_destroy(&doc)
	testing.expect_value(t, err2, Svg_Error.None)
	testing.expect_value(t, len(doc.warnings), 2)
}

@(test)
test_svg_draw_shapes_and_overrides :: proc(t: ^testing.T) {
	s: Svg_Fx
	defer svg_fx_close(&s)
	svg_fx_open(&s, `<svg xmlns="http://www.w3.org/2000/svg" width="40" height="20">
		<rect id="a" x="0" y="0" width="20" height="20" fill="#ff0000"/>
		<g id="g" fill="#0000ff"><rect x="20" y="0" width="20" height="20"/></g>
		<rect id="hidden" x="0" y="0" width="10" height="10" fill="#00ff00" visibility="hidden"/>
	</svg>`)
	svg_fx_draw(&s)
	testing.expect(t, close_to(svg_px(&s, 15, 15), {255, 0, 0, 255}))
	testing.expect(t, close_to(svg_px(&s, 30, 10), {0, 0, 255, 255}))
	testing.expect(t, close_to(svg_px(&s, 5, 5), {255, 0, 0, 255}))

	// Overrides: a fill on the group reaches the inheriting child, opacity
	// and a local transform on #a, visibility forces #hidden on.
	ovs := [?]Svg_Override {
		{id = "g", fill = Color{0, 0, 0, 1}},
		{id = "a", opacity = 0.5, transform = transform_translation(0, 10)},
		{id = "hidden", visible = true},
	}
	svg_fx_draw(&s, ovs[:])
	testing.expect(t, close_to(svg_px(&s, 30, 10), {0, 0, 0, 255}))
	testing.expect(t, close_to(svg_px(&s, 15, 5), {255, 255, 255, 255}))
	testing.expect(t, close_to(svg_px(&s, 15, 15), {255, 128, 128, 255}))
	testing.expect(t, close_to(svg_px(&s, 5, 5), {0, 255, 0, 255}))
}

@(test)
test_svg_draw_clip_mask_gradient :: proc(t: ^testing.T) {
	s: Svg_Fx
	defer svg_fx_close(&s)
	svg_fx_open(&s, `<svg xmlns="http://www.w3.org/2000/svg" width="60" height="20">
		<clipPath id="c" clipPathUnits="objectBoundingBox"><rect width="0.5" height="1"/></clipPath>
		<mask id="m"><rect x="20" y="0" width="20" height="20" fill="#808080"/></mask>
		<linearGradient id="lg"><stop offset="0" stop-color="#000"/><stop offset="1" stop-color="#fff"/></linearGradient>
		<rect width="20" height="20" fill="#ff0000" clip-path="url(#c)"/>
		<rect x="20" width="20" height="20" fill="#0000ff" mask="url(#m)"/>
		<rect x="40" width="20" height="20" fill="url(#lg)"/>
	</svg>`)
	svg_fx_draw(&s)
	testing.expect(t, close_to(svg_px(&s, 4, 10), {255, 0, 0, 255}))
	testing.expect(t, close_to(svg_px(&s, 15, 10), {255, 255, 255, 255}))
	// A 50% grey luminance mask (sRGB luminance of #808080 is 0.502).
	testing.expect(t, close_to(svg_px(&s, 30, 10), {127, 127, 255, 255}, 3))
	// The gradient runs over the shape's box: dark at its left, light at its right.
	l, r := svg_px(&s, 41, 10), svg_px(&s, 58, 10)
	testing.expect(t, l[0] < 30 && r[0] > 225)
}

@(test)
test_svg_filter_region :: proc(t: ^testing.T) {
	s: Svg_Fx
	defer svg_fx_close(&s)
	// A flood would cover the whole canvas: the region cuts it to the
	// shape's box grown by 10%.
	svg_fx_open(&s, `<svg xmlns="http://www.w3.org/2000/svg" width="100" height="100">
		<filter id="f"><feFlood flood-color="#00ff00"/></filter>
		<rect x="40" y="40" width="20" height="20" fill="#000" filter="url(#f)"/>
	</svg>`)
	svg_fx_draw(&s)
	testing.expect(t, close_to(svg_px(&s, 50, 50), {0, 255, 0, 255}))
	testing.expect(t, close_to(svg_px(&s, 39, 50), {0, 255, 0, 255}))
	testing.expect(t, close_to(svg_px(&s, 35, 50), {255, 255, 255, 255}))
	testing.expect(t, close_to(svg_px(&s, 5, 5), {255, 255, 255, 255}))
}

@(test)
test_filter_region_layer :: proc(t: ^testing.T) {
	// The canvas API: a userSpaceOnUse region under a scale.
	sw: Software_Backend
	software_backend_init(&sw)
	defer software_backend_destroy(&sw)
	c: Canvas
	canvas_init(&c, software_backend(&sw))
	defer canvas_destroy(&c)
	ls: Layer_Stack
	defer layer_stack_destroy(&ls, &c)
	set_size(&c, 64, 64)
	clear_rect(&c, 0, 0, 64, 64, TRANSPARENT)
	layer_stack_begin(&ls, &c, 64, 64)
	scale(&c, 2, 2)
	prims := [?]Filter_Primitive{{op = .Flood, color = WHITE}}
	f := Filter {
		primitives = prims[:],
		srgb       = true,
		region     = {units = .User_Space_On_Use, x = 4, y = 4, w = 8, h = 8},
	}
	layer_push(&ls, &c, {filter = &f})
	p: Path
	defer path_destroy(&p)
	path_rect(&p, 0, 0, 1, 1)
	fill_path(&c, &p, paint_color(BLACK))
	layer_pop(&ls, &c)
	layer_stack_end(&ls, &c)
	flush(&c)
	at :: proc(sw: ^Software_Backend, x, y: int) -> u8 {
		return sw.pixels[(y * 64 + x) * 4 + 3]
	}
	testing.expect_value(t, at(&sw, 8, 8), 255)
	testing.expect_value(t, at(&sw, 23, 23), 255)
	testing.expect_value(t, at(&sw, 7, 8), 0)
	testing.expect_value(t, at(&sw, 24, 24), 0)
	testing.expect_value(t, at(&sw, 40, 40), 0)
}

@(test)
test_focal_gradient :: proc(t: ^testing.T) {
	// At the focal point the gradient is at its first stop, at the outer
	// circle at its last, whatever the offset.
	pt := Vec2{-3, 0}
	testing.expect(t, abs(focal_gradient_t(pt, 10, 0, {-3, 0})) < 1e-4)
	testing.expect(t, abs(focal_gradient_t({10, 0}, 10, 0, {-3, 0}) - 1) < 1e-4)
	testing.expect(t, abs(focal_gradient_t({0, -10}, 10, 0, {-3, 0}) - 1) < 1e-4)
	// Concentric with a focal radius: (|p| - fr) / (r - fr).
	testing.expect(t, abs(focal_gradient_t({6, 0}, 10, 2, {1e-4, 0}) - 0.5) < 1e-3)
}

@(test)
test_zero_length_caps :: proc(t: ^testing.T) {
	s: Svg_Fx
	defer svg_fx_close(&s)
	svg_fx_open(&s, `<svg xmlns="http://www.w3.org/2000/svg" width="40" height="20">
		<path d="M10 10 L10 10" stroke="#000" stroke-width="10" stroke-linecap="round"/>
		<path d="M30 10 Z" stroke="#000" stroke-width="10" stroke-linecap="butt"/>
	</svg>`)
	svg_fx_draw(&s)
	testing.expect(t, close_to(svg_px(&s, 10, 10), {0, 0, 0, 255}))
	testing.expect(t, close_to(svg_px(&s, 13, 10), {0, 0, 0, 255}))
	testing.expect(t, close_to(svg_px(&s, 30, 10), {255, 255, 255, 255}))
}

@(test)
test_svg_css_colors :: proc(t: ^testing.T) {
	c, ok := css_color_parse("rgb(255, 0, 0)")
	testing.expect(t, ok && c == Color{1, 0, 0, 1})
	c, ok = css_color_parse("cornflowerblue")
	testing.expect(t, ok && close_to({u8(c.r * 255 + 0.5), u8(c.g * 255 + 0.5), u8(c.b * 255 + 0.5), 255}, {100, 149, 237, 255}, 0))
	c, ok = css_color_parse("hsla(120, 100%, 50%, 0.5)")
	testing.expect(t, ok && c == Color{0, 1, 0, 0.5})
	_, ok = css_color_parse("notacolor")
	testing.expect(t, !ok)
}

// display="none" with an id is kept, off: drawn only when an override shows it.
@(test)
test_svg_display_none_override :: proc(t: ^testing.T) {
	src := `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10">
		<g id="alt" display="none"><rect x="0" y="0" width="10" height="10" fill="#00ff00"/></g>
		<rect id="gone" display="none" x="0" y="0" width="1" height="1" fill="#ff0000"/>
	</svg>`
	doc, err := svg_parse(transmute([]u8)src)
	testing.expect_value(t, err, Svg_Error.None)
	defer svg_destroy(&doc)
	_, has_alt := doc.id_map["alt"]
	_, has_gone := doc.id_map["gone"]
	testing.expect(t, has_alt && has_gone)
}


// An override showing a visibility="hidden" group shows what inherits its
// visibility; a child with its own visibility="hidden" stays hidden.
@(test)
test_svg_visible_override :: proc(t: ^testing.T) {
	s: Svg_Fx
	defer svg_fx_close(&s)
	err := svg_fx_open(&s, `<svg xmlns="http://www.w3.org/2000/svg" width="40" height="20">
		<g id="eyes" visibility="hidden">
			<rect width="20" height="20" fill="red"/>
			<rect x="20" width="20" height="20" fill="blue" visibility="hidden"/>
		</g></svg>`)
	testing.expect_value(t, err, Svg_Error.None)
	svg_fx_draw(&s)
	testing.expect(t, close_to(svg_px(&s, 10, 10), {255, 255, 255, 255}))
	ovs := [?]Svg_Override{{id = "eyes", visible = true}}
	svg_fx_draw(&s, ovs[:])
	testing.expect(t, close_to(svg_px(&s, 10, 10), {255, 0, 0, 255}))
	testing.expect(t, close_to(svg_px(&s, 30, 10), {255, 255, 255, 255}))
}
