package svg

import "base:runtime"
import "core:mem"
import "core:slice"
import "core:strings"
import "core:testing"

import common "deps:odecs/common"
import vg ".."
import cv "deps:ocurves"

// SVG import: parsing into the document tables, then drawing on the
// software backend and reading pixels back.

@(private = "file")
Fx :: struct {
	backend: vg.Software_Backend,
	canvas:  vg.Canvas,
	layers:  vg.Layer_Stack,
	r:       Renderer,
	fonts:   vg.Font_Collection,
	doc:     Document,
	text:    Layout,
}

@(private = "file")
fx_open :: proc(s: ^Fx, markup: string) -> Error {
	vg.software_backend_init(&s.backend)
	vg.canvas_init(&s.canvas, vg.software_backend(&s.backend))
	vg.font_collection_init(&s.fonts)
	err: Error
	s.doc, err = parse(transmute([]u8)markup, {fonts = &s.fonts})
	layout(&s.doc, &s.fonts, &s.text)
	renderer_bind(&s.r, &s.canvas, &s.doc)
	return err
}

@(private = "file")
fx_close :: proc(s: ^Fx) {
	renderer_destroy(&s.r, &s.canvas)
	layout_destroy(&s.text)
	destroy(&s.doc)
	vg.layer_stack_destroy(&s.layers, &s.canvas)
	vg.canvas_destroy(&s.canvas)
	vg.software_backend_destroy(&s.backend)
	vg.font_collection_destroy(&s.fonts)
}

// Draws the document at its size on white (premultiplied output).
@(private = "file")
fx_draw :: proc(s: ^Fx, overrides: []Override = nil) {
	w, h := u32(s.doc.width), u32(s.doc.height)
	vg.set_size(&s.canvas, w, h)
	vg.clear_rect(&s.canvas, 0, 0, w, h, vg.WHITE)
	vg.layer_stack_begin(&s.layers, &s.canvas, w, h, nil, s.doc.uses_blend)
	draw(&s.canvas, &s.layers, &s.r, &s.doc, &s.text, vg.TRANSFORM_IDENTITY, overrides)
	vg.layer_stack_end(&s.layers, &s.canvas)
	vg.flush(&s.canvas)
}

@(private = "file")
px :: proc(s: ^Fx, x, y: int) -> [4]u8 {
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
	s: Fx
	defer fx_close(&s)
	err := fx_open(&s, `<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" viewBox="0 0 200 100" width="400">
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
	testing.expect_value(t, err, Error.None)
	// width 400 with a 2:1 viewBox: the height follows its aspect.
	testing.expect_value(t, s.doc.width, 400)
	testing.expect_value(t, s.doc.height, 200)
	testing.expect_value(t, s.doc.nodes[0].transform, vg.Transform2D{2, 0, 0, 2, 0, 0})

	big := find(&s.doc, "big")
	testing.expect(t, big >= 0)
	sh := s.doc.shapes[s.doc.nodes[big].data]
	// Class rule beats the inherited fill; the id rule sets the width;
	// currentColor follows the inherited color.
	testing.expect_value(t, sh.style.fill.color, vg.Color{0, 0, 1, 1})
	testing.expect_value(t, sh.style.stroke_width, 4)
	testing.expect(t, close_to({u8(sh.style.stroke.color.r * 255 + 0.5), u8(sh.style.stroke.color.g * 255 + 0.5), u8(sh.style.stroke.color.b * 255 + 0.5), 255}, {0x12, 0x34, 0x56, 255}, 0))
	testing.expect_value(t, s.doc.nodes[big].bbox, vg.Rect{10, 10, 50, 20})

	// The derived gradient keeps the base's stops and x1 but its own units and x2.
	testing.expect_value(t, len(s.doc.servers), 1)
	g := s.doc.servers[0]
	testing.expect(t, !g.bbox_units)
	testing.expect_value(t, g.v[2], 50)
	testing.expect_value(t, g.stops.count, 2)

	// The <use> of #big draws the rect's own node; the symbol's use maps
	// its viewBox into 40 x 40 and draws the symbol's content, converted
	// outside the drawing.
	cell := find(&s.doc, "cell")
	testing.expect(t, cell >= 0)
	instances, big_use, sym_use := 0, -1, -1
	for n, i in s.doc.nodes {
		if n.id >= 0 && s.doc.ids[n.id] == "big" {
			instances += 1
		}
		if n.kind == .Use && n.data == big {
			big_use = i
		}
		if n.kind == .Use && n.data == s.doc.nodes[cell].parent {
			sym_use = i
		}
	}
	testing.expect_value(t, instances, 1)
	testing.expect(t, big_use >= 0 && sym_use >= 0)
	testing.expect_value(t, s.doc.nodes[big_use].transform, vg.Transform2D{1, 0, 0, 1, 0, 50})
	sym := s.doc.nodes[sym_use]
	testing.expect_value(t, sym.transform, vg.Transform2D{4, 0, 0, 4, 0, 0})
	testing.expect(t, .Clip_Rect in sym.flags)
	testing.expect_value(t, s.doc.nodes[s.doc.nodes[cell].parent].parent, -1)

	// Text: one chunk, "A " and "B" (whitespace collapsed, bold span).
	testing.expect_value(t, len(s.doc.texts), 1)
	testing.expect_value(t, len(s.doc.pieces), 2)
	testing.expect_value(t, s.doc.pieces[0].text, "A ")
	testing.expect_value(t, s.doc.pieces[0].dx, 2)
	testing.expect_value(t, s.doc.pieces[1].weight, 700)
}

// Uses draw definitions by reference: uses starting from the same style
// share one, a use of a use refers to a use, a symbol's content converts
// once; an id names one node, which overrides and bounding boxes follow
// through the uses. Kept attributes and groups for editors.
@(test)
test_use_references :: proc(t: ^testing.T) {
	keep := [?]string{"inkscape:label", "inkscape:groupmode", "class"}
	doc, err := parse(transmute([]u8)string(`<svg xmlns="http://www.w3.org/2000/svg" xmlns:inkscape="http://www.inkscape.org/namespaces/inkscape" width="100" height="40">
		<defs>
			<rect id="cell" width="10" height="10"/>
			<symbol id="sym" viewBox="0 0 10 10"><use id="inner" href="#cell"/></symbol>
		</defs>
		<g id="layer" inkscape:label="Cells" inkscape:groupmode="layer" class="a b">
			<use id="u1" href="#cell" fill="red"/>
			<use id="u2" href="#cell" x="20" fill="red"/>
			<use id="u3" href="#cell" x="40" fill="blue"/>
			<use id="u4" href="#u1" x="60"/>
			<use id="s1" href="#sym" y="20" width="20" height="20"/>
			<use id="s2" href="#sym" x="30" y="20" width="20" height="20"/>
		</g>
		<g><rect x="90" width="5" height="5"/></g>
	</svg>`), {keep_attributes = keep[:], keep_groups = true})
	defer destroy(&doc)
	testing.expect_value(t, err, Error.None)
	node :: proc(doc: ^Document, id: string) -> Node {
		return doc.nodes[find(doc, id)]
	}
	u1, u2, u3, u4 := node(&doc, "u1"), node(&doc, "u2"), node(&doc, "u3"), node(&doc, "u4")
	testing.expect(t, u1.kind == .Use && u2.kind == .Use && u3.kind == .Use && u4.kind == .Use)
	testing.expect_value(t, u2.data, u1.data)
	// Blue inherits into the rect: a definition of its own, with the id.
	testing.expect(t, u3.data != u1.data && doc.nodes[u3.data].id == doc.nodes[u1.data].id)
	testing.expect_value(t, u4.data, find(&doc, "u1"))
	s1, s2 := node(&doc, "s1"), node(&doc, "s2")
	sym_use := doc.nodes[s1.first_child]
	testing.expect_value(t, sym_use.kind, Node_Kind.Use)
	testing.expect_value(t, doc.nodes[s2.first_child].data, sym_use.data)
	testing.expect_value(t, doc.nodes[sym_use.data].parent, -1)
	// Three definitions of #cell (red, blue, and black in the symbol), and
	// the last rect.
	testing.expect_value(t, len(doc.shapes), 4)
	// #inner sits in the symbol's content: where s1 puts it.
	b, ok := element_bbox(&doc, "inner")
	testing.expect(t, ok)
	testing.expect_value(t, b, vg.Rect{0, 20, 20, 20})
	box, _ := element_bbox(&doc, "u4")
	testing.expect_value(t, box, vg.Rect{60, 0, 10, 10})

	layer := find(&doc, "layer")
	kept: [3]string
	for a in doc.attributes {
		if a.node == layer {
			kept[a.name] = a.value
		}
	}
	testing.expect_value(t, kept, [3]string{"Cells", "layer", "a b"})
	// keep_groups: the group around the last rect has a node.
	last := doc.nodes[len(doc.nodes) - 1]
	testing.expect(t, last.kind == .Shape && doc.nodes[last.parent].kind == .Group && last.parent != 0)
}

@(test)
test_use_references_draw :: proc(t: ^testing.T) {
	s: Fx
	defer fx_close(&s)
	fx_open(&s, `<svg xmlns="http://www.w3.org/2000/svg" width="100" height="40">
		<defs>
			<rect id="cell" width="10" height="10"/>
			<symbol id="sym" viewBox="0 0 10 10"><use href="#cell"/></symbol>
		</defs>
		<use id="u1" href="#cell" fill="red"/>
		<use href="#cell" x="20" fill="red"/>
		<use href="#cell" x="40" fill="blue"/>
		<use href="#u1" x="60"/>
		<use href="#sym" y="20" width="20" height="20"/>
		<use href="#sym" x="30" y="20" width="20" height="20"/>
	</svg>`)
	fx_draw(&s)
	RED, BLUE, BLACK, WHITE :: [4]u8{255, 0, 0, 255}, [4]u8{0, 0, 255, 255}, [4]u8{0, 0, 0, 255}, [4]u8{255, 255, 255, 255}
	testing.expect(t, close_to(px(&s, 5, 5), RED))
	testing.expect(t, close_to(px(&s, 25, 5), RED))
	testing.expect(t, close_to(px(&s, 45, 5), BLUE))
	testing.expect(t, close_to(px(&s, 65, 5), RED))
	testing.expect(t, close_to(px(&s, 15, 35), BLACK))
	testing.expect(t, close_to(px(&s, 45, 35), BLACK))
	testing.expect(t, close_to(px(&s, 15, 5), WHITE))
	// An override of #cell reaches every use of every definition of it.
	ovs := [?]Override{{id = "cell", fill = vg.Color{0, 1, 0, 1}}}
	fx_draw(&s, ovs[:])
	for q in ([][2]int{{5, 5}, {25, 5}, {45, 5}, {65, 5}, {15, 35}, {45, 35}}) {
		testing.expect(t, close_to(px(&s, q.x, q.y), {0, 255, 0, 255}))
	}
}

@(test)
test_use_before_target :: proc(t: ^testing.T) {
	// Uses before their target (an editor's clones below the original).
	src := `<svg xmlns="http://www.w3.org/2000/svg" width="100" height="20">
		<use id="u1" href="#cell" x="20"/>
		<g fill="blue"><use id="u2" href="#cell" x="40"/></g>
		<rect id="cell" width="10" height="10"/>
		<use id="u3" href="#cell" x="60"/>
	</svg>`
	doc, err := parse(transmute([]u8)string(src))
	defer destroy(&doc)
	testing.expect_value(t, err, Error.None)
	// The definition u1 made is the drawing's node of #cell, as if u1 came
	// after it; u2's style differs (blue inherits): its own, outside.
	cell := find(&doc, "cell")
	testing.expect_value(t, doc.nodes[cell].parent, 0)
	u1, u2, u3 := doc.nodes[find(&doc, "u1")], doc.nodes[find(&doc, "u2")], doc.nodes[find(&doc, "u3")]
	testing.expect_value(t, u1.data, cell)
	testing.expect_value(t, u3.data, cell)
	testing.expect(t, u2.kind == .Use && u2.data != cell && doc.nodes[u2.data].parent == -1)
	testing.expect_value(t, len(doc.shapes), 2)
	box, _ := element_bbox(&doc, "cell")
	testing.expect_value(t, box, vg.Rect{0, 0, 10, 10})
	box, _ = element_bbox(&doc, "u1")
	testing.expect_value(t, box, vg.Rect{20, 0, 10, 10})

	s: Fx
	defer fx_close(&s)
	fx_open(&s, src)
	fx_draw(&s)
	BLUE, BLACK, WHITE :: [4]u8{0, 0, 255, 255}, [4]u8{0, 0, 0, 255}, [4]u8{255, 255, 255, 255}
	for q in ([][2]int{{5, 5}, {25, 5}, {65, 5}}) {
		testing.expect(t, close_to(px(&s, q.x, q.y), BLACK))
	}
	testing.expect(t, close_to(px(&s, 45, 5), BLUE))
	testing.expect(t, close_to(px(&s, 15, 5), WHITE))
}

@(test)
test_svg_parse_errors :: proc(t: ^testing.T) {
	_, err := parse(transmute([]u8)string("<html></html>"))
	testing.expect_value(t, err, Error.Not_Svg)
	doc, err2 := parse(transmute([]u8)string(`<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"><blink/><rect width="5" height="5" marker-end="url(#m)"/></svg>`))
	defer destroy(&doc)
	testing.expect_value(t, err2, Error.None)
	testing.expect_value(t, len(doc.warnings), 2)
}

@(test)
test_svg_draw_shapes_and_overrides :: proc(t: ^testing.T) {
	s: Fx
	defer fx_close(&s)
	fx_open(&s, `<svg xmlns="http://www.w3.org/2000/svg" width="40" height="20">
		<rect id="a" x="0" y="0" width="20" height="20" fill="#ff0000"/>
		<g id="g" fill="#0000ff"><rect x="20" y="0" width="20" height="20"/></g>
		<rect id="hidden" x="0" y="0" width="10" height="10" fill="#00ff00" visibility="hidden"/>
	</svg>`)
	fx_draw(&s)
	testing.expect(t, close_to(px(&s, 15, 15), {255, 0, 0, 255}))
	testing.expect(t, close_to(px(&s, 30, 10), {0, 0, 255, 255}))
	testing.expect(t, close_to(px(&s, 5, 5), {255, 0, 0, 255}))

	// Overrides: a fill on the group reaches the inheriting child, opacity
	// and a local transform on #a, visibility forces #hidden on.
	ovs := [?]Override {
		{id = "g", fill = vg.Color{0, 0, 0, 1}},
		{id = "a", opacity = 0.5, transform = vg.transform_translation(0, 10)},
		{id = "hidden", visible = true},
	}
	fx_draw(&s, ovs[:])
	testing.expect(t, close_to(px(&s, 30, 10), {0, 0, 0, 255}))
	testing.expect(t, close_to(px(&s, 15, 5), {255, 255, 255, 255}))
	testing.expect(t, close_to(px(&s, 15, 15), {255, 128, 128, 255}))
	testing.expect(t, close_to(px(&s, 5, 5), {0, 255, 0, 255}))
}

@(test)
test_svg_draw_clip_mask_gradient :: proc(t: ^testing.T) {
	s: Fx
	defer fx_close(&s)
	fx_open(&s, `<svg xmlns="http://www.w3.org/2000/svg" width="60" height="20">
		<clipPath id="c" clipPathUnits="objectBoundingBox"><rect width="0.5" height="1"/></clipPath>
		<mask id="m"><rect x="20" y="0" width="20" height="20" fill="#808080"/></mask>
		<linearGradient id="lg"><stop offset="0" stop-color="#000"/><stop offset="1" stop-color="#fff"/></linearGradient>
		<rect width="20" height="20" fill="#ff0000" clip-path="url(#c)"/>
		<rect x="20" width="20" height="20" fill="#0000ff" mask="url(#m)"/>
		<rect x="40" width="20" height="20" fill="url(#lg)"/>
	</svg>`)
	fx_draw(&s)
	testing.expect(t, close_to(px(&s, 4, 10), {255, 0, 0, 255}))
	testing.expect(t, close_to(px(&s, 15, 10), {255, 255, 255, 255}))
	// A 50% grey luminance mask (sRGB luminance of #808080 is 0.502).
	testing.expect(t, close_to(px(&s, 30, 10), {127, 127, 255, 255}, 3))
	// The gradient runs over the shape's box: dark at its left, light at its right.
	l, r := px(&s, 41, 10), px(&s, 58, 10)
	testing.expect(t, l[0] < 30 && r[0] > 225)
}

@(test)
test_svg_filter_region :: proc(t: ^testing.T) {
	s: Fx
	defer fx_close(&s)
	// A flood would cover the whole canvas: the region cuts it to the
	// shape's box grown by 10%.
	fx_open(&s, `<svg xmlns="http://www.w3.org/2000/svg" width="100" height="100">
		<filter id="f"><feFlood flood-color="#00ff00"/></filter>
		<rect x="40" y="40" width="20" height="20" fill="#000" filter="url(#f)"/>
	</svg>`)
	fx_draw(&s)
	testing.expect(t, close_to(px(&s, 50, 50), {0, 255, 0, 255}))
	testing.expect(t, close_to(px(&s, 39, 50), {0, 255, 0, 255}))
	testing.expect(t, close_to(px(&s, 35, 50), {255, 255, 255, 255}))
	testing.expect(t, close_to(px(&s, 5, 5), {255, 255, 255, 255}))
}

@(test)
test_zero_length_caps :: proc(t: ^testing.T) {
	s: Fx
	defer fx_close(&s)
	fx_open(&s, `<svg xmlns="http://www.w3.org/2000/svg" width="40" height="20">
		<path d="M10 10 L10 10" stroke="#000" stroke-width="10" stroke-linecap="round"/>
		<path d="M30 10 Z" stroke="#000" stroke-width="10" stroke-linecap="butt"/>
	</svg>`)
	fx_draw(&s)
	testing.expect(t, close_to(px(&s, 10, 10), {0, 0, 0, 255}))
	testing.expect(t, close_to(px(&s, 13, 10), {0, 0, 0, 255}))
	testing.expect(t, close_to(px(&s, 30, 10), {255, 255, 255, 255}))
}

@(test)
test_svg_css_colors :: proc(t: ^testing.T) {
	c, ok := vg.css_color_parse("rgb(255, 0, 0)")
	testing.expect(t, ok && c == vg.Color{1, 0, 0, 1})
	c, ok = vg.css_color_parse("cornflowerblue")
	testing.expect(t, ok && close_to({u8(c.r * 255 + 0.5), u8(c.g * 255 + 0.5), u8(c.b * 255 + 0.5), 255}, {100, 149, 237, 255}, 0))
	c, ok = vg.css_color_parse("hsla(120, 100%, 50%, 0.5)")
	testing.expect(t, ok && c == vg.Color{0, 1, 0, 0.5})
	_, ok = vg.css_color_parse("notacolor")
	testing.expect(t, !ok)
}

// display="none" with an id is kept, off: drawn only when an override shows it.
@(test)
test_svg_display_none_override :: proc(t: ^testing.T) {
	src := `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10">
		<g id="alt" display="none"><rect x="0" y="0" width="10" height="10" fill="#00ff00"/></g>
		<rect id="gone" display="none" x="0" y="0" width="1" height="1" fill="#ff0000"/>
	</svg>`
	doc, err := parse(transmute([]u8)src)
	testing.expect_value(t, err, Error.None)
	defer destroy(&doc)
	_, has_alt := doc.id_map["alt"]
	_, has_gone := doc.id_map["gone"]
	testing.expect(t, has_alt && has_gone)
}


// An override showing a visibility="hidden" group shows what inherits its
// visibility; a child with its own visibility="hidden" stays hidden.
@(test)
test_svg_visible_override :: proc(t: ^testing.T) {
	s: Fx
	defer fx_close(&s)
	err := fx_open(&s, `<svg xmlns="http://www.w3.org/2000/svg" width="40" height="20">
		<g id="eyes" visibility="hidden">
			<rect width="20" height="20" fill="red"/>
			<rect x="20" width="20" height="20" fill="blue" visibility="hidden"/>
		</g></svg>`)
	testing.expect_value(t, err, Error.None)
	fx_draw(&s)
	testing.expect(t, close_to(px(&s, 10, 10), {255, 255, 255, 255}))
	ovs := [?]Override{{id = "eyes", visible = true}}
	fx_draw(&s, ovs[:])
	testing.expect(t, close_to(px(&s, 10, 10), {255, 0, 0, 255}))
	testing.expect(t, close_to(px(&s, 30, 10), {255, 255, 255, 255}))
}

// An element kept with display="none" (for an override to show) is not in
// its parent's bounding box: a bounding-box flood on the group covers only
// the visible rect.
@(test)
test_svg_off_bbox :: proc(t: ^testing.T) {
	s: Fx
	defer fx_close(&s)
	err := fx_open(&s, `<svg xmlns="http://www.w3.org/2000/svg" width="100" height="100">
		<filter id="f" x="0" y="0" width="1" height="1"><feFlood flood-color="blue"/></filter>
		<g filter="url(#f)">
			<rect width="20" height="20" fill="red"/>
			<rect id="alt" x="60" y="60" width="20" height="20" display="none"/>
		</g></svg>`)
	testing.expect_value(t, err, Error.None)
	fx_draw(&s)
	testing.expect(t, close_to(px(&s, 10, 10), {0, 0, 255, 255}))
	testing.expect(t, close_to(px(&s, 50, 50), {255, 255, 255, 255}))
}

// Blur under a non-uniform scale is per axis: stdDeviation 2 under
// scale(4, 1) is sigma 8 across and 2 down (resvg), not 5 both ways.
@(test)
test_svg_blur_axis_scale :: proc(t: ^testing.T) {
	s: Fx
	defer fx_close(&s)
	err := fx_open(&s, `<svg xmlns="http://www.w3.org/2000/svg" width="120" height="80">
		<filter id="b" filterUnits="userSpaceOnUse" x="-100" y="-100" width="400" height="400"><feGaussianBlur stdDeviation="2"/></filter>
		<g transform="scale(4,1)"><rect x="10" y="20" width="5" height="20" filter="url(#b)"/></g></svg>`)
	testing.expect_value(t, err, Error.None)
	fx_draw(&s)
	// 4 px below the bottom edge (y = 40): about 2 sigma at sigma 2.
	below := px(&s, 50, 44)
	// 8 px right of the right edge (x = 60): 1 sigma at sigma 8.
	right := px(&s, 68, 30)
	testing.expectf(t, below.r > 245, "below the edge: %v", below)
	testing.expectf(t, right.r < 230, "right of the edge: %v", right)
}

// Once warm, drawing a document allocates nothing: shapes, gradients, a
// dashed stroke, group opacity, a clip, a mask, a filter, text and an
// override that moves every frame.
@(test)
test_svg_no_allocation_when_warm :: proc(t: ^testing.T) {
	s: Fx
	defer fx_close(&s)
	err := fx_open(&s, `<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64">
		<defs>
			<linearGradient id="g"><stop offset="0" stop-color="red"/><stop offset="0.5" stop-color="lime" stop-opacity="0.5"/><stop offset="1" stop-color="blue"/></linearGradient>
			<clipPath id="c"><circle cx="20" cy="20" r="18"/></clipPath>
			<mask id="m"><rect width="64" height="64" fill="white"/><circle cx="40" cy="40" r="8" fill="black"/></mask>
			<filter id="f"><feGaussianBlur stdDeviation="1.5"/><feOffset dx="2" dy="2"/></filter>
		</defs>
		<g id="spin" opacity="0.8"><rect width="40" height="40" fill="url(#g)" stroke="black" stroke-dasharray="3 2"/></g>
		<g clip-path="url(#c)"><rect width="64" height="64" fill="orange"/></g>
		<g mask="url(#m)" filter="url(#f)"><circle cx="40" cy="40" r="16" fill="purple"/></g>
		<text x="4" y="60" font-size="10">Warm <tspan font-weight="bold">text</tspan></text>
		</svg>`)
	testing.expect_value(t, err, Error.None)
	draw :: proc(s: ^Fx, i: int) {
		ovs := [?]Override{{id = "spin", transform = vg.transform_rotation(f32(i) * 0.05)}}
		fx_draw(s, ovs[:])
	}
	for i in 0 ..< 30 {
		draw(&s, i)
	}
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	{
		context.allocator = mem.tracking_allocator(&track)
		for i in 0 ..< 30 {
			draw(&s, i)
		}
	}
	testing.expect_value(t, track.total_allocation_count, 0)
}

// Every property has a row: a unique name the lookup finds, a parser and a
// copy (props, PROP_ALIASES).
@(test)
test_svg_prop_table :: proc(t: ^testing.T) {
	for info, prop in props {
		testing.expectf(t, info.name != "" && info.apply != nil && info.copy != nil, "%v: incomplete row", prop)
		found, ok := prop_from_name(info.name)
		testing.expectf(t, ok && found == prop, "%q finds %v", info.name, found)
	}
	for alias in PROP_ALIASES {
		found, ok := prop_from_name(alias.name)
		testing.expectf(t, ok && found == alias.prop, "alias %q finds %v", alias.name, found)
	}
}

// A clip path uses its text's outlines whatever the text's own fill
// (fill="none" included), as it does for shapes (both are filled white
// when parsed into a clip).
@(test)
test_svg_clip_text_fill_none :: proc(t: ^testing.T) {
	s: Fx
	defer fx_close(&s)
	err := fx_open(&s, `<svg xmlns="http://www.w3.org/2000/svg" width="80" height="60">
		<clipPath id="c"><text x="4" y="50" font-size="60" fill="none">H</text></clipPath>
		<rect width="80" height="60" fill="blue" clip-path="url(#c)"/></svg>`)
	testing.expect_value(t, err, Error.None)
	fx_draw(&s)
	blue := 0
	for y in 0 ..< 60 {
		for x in 0 ..< 80 {
			if p := px(&s, x, y); p.b > 200 && p.r < 50 {
				blue += 1
			}
		}
	}
	testing.expectf(t, blue > 100, "clipped area: %d blue pixels", blue)
}

// Bands on the caller's pool (odecs' Work_Pool) draw what one thread draws:
// a frame's runs, a group, a two-pass blur and feTurbulence.
@(test)
test_sw_pool_bands_match :: proc(t: ^testing.T) {
	pool: common.Static_Pool
	common.init_static_pool(&pool, 2)
	defer common.destroy_static_pool(&pool)
	s: Fx
	defer fx_close(&s)
	err := fx_open(&s, `<svg xmlns="http://www.w3.org/2000/svg" width="64" height="128">
		<filter id="f"><feTurbulence baseFrequency="0.05" numOctaves="2"/></filter>
		<filter id="b"><feGaussianBlur stdDeviation="3"/></filter>
		<rect width="64" height="128" filter="url(#f)"/>
		<g opacity="0.5"><circle cx="32" cy="40" r="20" fill="#08f" filter="url(#b)"/>
		<rect x="8" y="70" width="48" height="40" rx="6" fill="#f80"/></g></svg>`)
	testing.expect_value(t, err, Error.None)
	fx_draw(&s)
	alone := slice.clone(s.backend.pixels, context.temp_allocator)
	s.backend.pool = &pool.work_pool
	fx_draw(&s)
	s.backend.pool = nil
	testing.expect(t, slice.equal(alone, s.backend.pixels))
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
	testing.expect(t, strings.contains(hostile(t, &s, strings.to_string(b)), "nesting depth"))

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
	testing.expect(t, strings.contains(hostile(t, &s, strings.to_string(b)), "SVG elements"))

	// Dashes too fine to count draw the stroke undashed (dashed when
	// parsed).
	testing.expect(t, strings.contains(hostile(t, &s, `<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64"><path d="M0 32 H64" stroke="black" stroke-width="4" stroke-dasharray="1e-7"/></svg>`), "dashes per stroke"))
	testing.expect_value(t, s.backend.pixels[(32 * 64 + 32) * 4], 0)

	octaves := `<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64"><filter id="f"><feTurbulence baseFrequency="0.05" numOctaves="1000000000"/></filter><rect width="64" height="64" filter="url(#f)"/></svg>`
	testing.expect(t, strings.contains(hostile(t, &s, octaves), "octaves"))

	strings.builder_reset(&b)
	strings.write_string(&b, `<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64"><filter id="f">`)
	for _ in 0 ..< 1000 {
		strings.write_string(&b, `<feOffset dx="0.01"/>`)
	}
	strings.write_string(&b, `</filter><rect width="10" height="10" filter="url(#f)"/></svg>`)
	testing.expect(t, strings.contains(hostile(t, &s, strings.to_string(b)), "filter primitives"))

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
	testing.expect(t, strings.contains(hostile(t, &s, strings.to_string(b)), "CSS selector steps"))
}

// An SVG's filled geometry as one path, under its transforms, skipping what
// draws nothing; an element's subtree by id.
@(test)
test_svg_element_path :: proc(t: ^testing.T) {
	markup := `<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="200" height="100" viewBox="0 0 100 50">
	<defs><rect id="tile" width="4" height="4"/></defs>
	<g id="mark" transform="translate(10 5)">
		<rect width="20" height="10"/>
		<circle cx="40" cy="5" r="5" fill-rule="evenodd"/>
		<use xlink:href="#tile" x="60"/>
	</g>
	<rect x="0" y="40" width="5" height="5" display="none"/>
	<rect x="10" y="40" width="5" height="5" visibility="hidden"/>
	<rect x="20" y="40" width="5" height="5" fill="none" stroke="black"/>
	<rect x="30" y="40" width="5" height="5" opacity="0"/>
	<g id="shown"><rect x="90" y="40" width="5" height="5"/></g>
	<g id="spare" display="none"><rect x="40" y="40" width="5" height="5"/><rect x="50" y="40" width="5" height="5" display="none"/></g>
</svg>`
	doc, err := parse(transmute([]u8)string(markup))
	defer destroy(&doc)
	testing.expect_value(t, err, Error.None)
	p: vg.Path
	defer vg.path_destroy(&p)

	rule, mixed, found := element_path(&doc, &p)
	testing.expect(t, found && mixed)
	_, n := flat_area(&p)
	testing.expect_value(t, n, 4) // the mark's three shapes and the shown rect
	// Document coordinates: the viewBox scales by 2.
	testing.expect(t, filled(&p, 2 * (10 + 10), 2 * (5 + 5), .Non_Zero)) // rect
	testing.expect(t, filled(&p, 2 * (10 + 40), 2 * (5 + 5), .Non_Zero)) // circle
	testing.expect(t, filled(&p, 2 * (10 + 62), 2 * (5 + 2), .Non_Zero)) // use
	testing.expect(t, filled(&p, 2 * 92, 2 * 42, .Non_Zero))
	for x in ([?]f32{2, 12, 22, 32}) {
		testing.expect(t, !filled(&p, 2 * x, 2 * 42, .Non_Zero))
	}

	vg.path_reset(&p)
	rule, mixed, found = element_path(&doc, &p, "shown")
	testing.expect(t, found && !mixed && rule == .Non_Zero)
	_, n = flat_area(&p)
	testing.expect_value(t, n, 1)

	vg.path_reset(&p)
	_, _, found = element_path(&doc, &p, "mark")
	_, n = flat_area(&p)
	testing.expect(t, found)
	testing.expect_value(t, n, 3)
	testing.expect(t, filled(&p, 2 * (10 + 10), 2 * (5 + 5), .Non_Zero))

	// Asked for by id, a display="none" element gives its geometry (not
	// that of its own hidden children).
	vg.path_reset(&p)
	_, _, found = element_path(&doc, &p, "spare")
	_, n = flat_area(&p)
	testing.expect(t, found)
	testing.expect_value(t, n, 1)

	_, _, found = element_path(&doc, &p, "nope")
	testing.expect(t, !found)
}

// SVG text joins the path when the document's layout is given.
@(test)
test_svg_element_path_text :: proc(t: ^testing.T) {
	fonts: vg.Font_Collection
	vg.font_collection_init(&fonts)
	defer vg.font_collection_destroy(&fonts)
	markup := `<svg xmlns="http://www.w3.org/2000/svg" width="200" height="100"><g transform="translate(100 0)"><text id="t" x="10" y="60" font-size="40">Hi</text></g></svg>`
	doc, _ := parse(transmute([]u8)string(markup), {fonts = &fonts})
	defer destroy(&doc)
	text: Layout
	defer layout_destroy(&text)
	layout(&doc, &fonts, &text)
	p: vg.Path
	defer vg.path_destroy(&p)
	element_path(&doc, &p)
	testing.expect(t, vg.path_is_empty(&p)) // no layout, no text
	rule, mixed, found := element_path(&doc, &p, "t", &text)
	testing.expect(t, found && !mixed && rule == .Non_Zero)
	_, n := flat_area(&p)
	testing.expect(t, n >= 2)
	f: vg.Flat_Path
	defer vg.flat_path_destroy(&f)
	vg.path_flatten(&p, &f)
	for q in f.points {
		testing.expect(t, q.x >= 110 && q.x < 200 && q.y > 20 && q.y <= 60.5)
	}
}

// SVG 2 wrapped text: shape-inside's rect less shape-padding, lines
// placed from its top and those reaching below it not drawn; inline-size
// from the text's x, y, each line centred by text-anchor; white-space's
// newlines and line-height as a percentage and as a number.
@(test)
test_svg_wrapped_text :: proc(t: ^testing.T) {
	fonts: vg.Font_Collection
	vg.font_collection_init(&fonts)
	defer vg.font_collection_destroy(&fonts)
	markup := `<svg xmlns="http://www.w3.org/2000/svg" width="200" height="200">
<rect id="r" x="10" y="20" width="100" height="30" display="none"/>
<text style="font-size:10px;line-height:150%;shape-inside:url(#r);shape-padding:5">aaa bbb ccc ddd eee fff ggg hhh</text>
<text x="50" y="80" style="font-size:10px;inline-size:40px;text-anchor:middle">aa bb cc dd ee</text>
<text x="0" y="120" style="font-size:10px;line-height:2;white-space:pre-line">a
   b</text>
</svg>`
	doc, err := parse(transmute([]u8)string(markup), {fonts = &fonts})
	defer destroy(&doc)
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, len(doc.texts), 3)
	w := doc.texts[0].wrap
	testing.expect(t, w.inside && w.width == 90 && w.x == 15 && w.y == 25 && w.bottom == 45 && w.line_height == 15)
	l: vg.Text_Layout
	defer vg.text_layout_destroy(&l)
	pieces: [dynamic]vg.Text_Piece
	defer delete(pieces)
	tp: vg.Text_Path
	defer vg.text_path_destroy(&tp)
	lay :: proc(fonts: ^vg.Font_Collection, doc: ^Document, i: int, l: ^vg.Text_Layout, pieces: ^[dynamic]vg.Text_Piece, tp: ^vg.Text_Path) {
		tx := &doc.texts[i]
		layout_chunk(fonts, doc, &doc.chunks[tx.chunks.start], {}, 0, l, pieces, tp, &tx.wrap)
	}
	lay(&fonts, &doc, 0, &l, &pieces, &tp)
	testing.expect(t, len(l.lines) >= 2 && abs(l.lines[1].y - l.lines[0].y - 15) < 0.01)
	first_line := l.lines[0].count
	// Only the first line's box (25 to 40) fits above 45.
	text: Layout
	defer layout_destroy(&text)
	layout(&doc, &fonts, &text)
	drawn: u32
	for run in text.runs[text.texts[0].start:][:text.texts[0].count] {
		drawn += run.glyphs.count
	}
	testing.expect_value(t, int(drawn), first_line)
	// inline-size: lines of at most 40 px, each centred on x = 50.
	w = doc.texts[1].wrap
	testing.expect(t, !w.inside && w.width == 40)
	lay(&fonts, &doc, 1, &l, &pieces, &tp)
	testing.expect(t, len(l.lines) >= 2)
	for line in l.lines {
		testing.expect(t, abs(l.glyphs[line.first].x - (50 - line.width / 2)) < 0.01)
	}
	// pre-line: the newline breaks the line, the spaces after it go; the
	// lines two font sizes apart.
	testing.expect_value(t, doc.pieces[doc.chunks[doc.texts[2].chunks.start].pieces.start].text, "a\nb")
	testing.expect_value(t, doc.texts[2].wrap.line_height, 20)
	lay(&fonts, &doc, 2, &l, &pieces, &tp)
	testing.expect(t, len(l.lines) == 2 && abs(l.lines[1].y - l.lines[0].y - 20) < 0.01)
}

// Hostile input (limits.odin): each file finishes quickly, cut short with the
// limit recorded, instead of crashing, hanging or exhausting memory. These
// documents grow large arrays: the heap allocator, as programs use (the test
// runner's rollback stack copies a whole block on every resize).

@(private = "file")
Limits_Fx :: struct {
	backend: vg.Software_Backend,
	canvas:  vg.Canvas,
	layers:  vg.Layer_Stack,
}

@(private = "file")
limits_fx_open :: proc(s: ^Limits_Fx) {
	vg.software_backend_init(&s.backend)
	vg.canvas_init(&s.canvas, vg.software_backend(&s.backend))
	vg.set_size(&s.canvas, 64, 64)
}

@(private = "file")
limits_fx_close :: proc(s: ^Limits_Fx) {
	vg.layer_stack_destroy(&s.layers, &s.canvas)
	vg.canvas_destroy(&s.canvas)
	vg.software_backend_destroy(&s.backend)
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
hostile :: proc(t: ^testing.T, s: ^Limits_Fx, markup: string, loc := #caller_location) -> string {
	fonts: vg.Font_Collection
	vg.font_collection_init(&fonts)
	defer vg.font_collection_destroy(&fonts)
	doc, err := parse(transmute([]u8)markup, {fonts = &fonts})
	defer destroy(&doc)
	testing.expect_value(t, err, Error.None, loc = loc)
	r: Renderer
	defer renderer_destroy(&r, &s.canvas)
	text: Layout
	layout(&doc, &fonts, &text)
	defer layout_destroy(&text)
	renderer_bind(&r, &s.canvas, &doc)
	vg.clear_rect(&s.canvas, 0, 0, 64, 64, vg.WHITE)
	vg.layer_stack_begin(&s.layers, &s.canvas, 64, 64, nil, doc.uses_blend)
	draw(&s.canvas, &s.layers, &r, &doc, &text)
	vg.layer_stack_end(&s.layers, &s.canvas)
	vg.flush(&s.canvas)
	return strings.join(doc.warnings[:], "\n", context.temp_allocator)
}

// The fill of `p` at (x, y) under `rule`.
@(private = "file")
filled :: proc(p: ^vg.Path, x, y: f32, rule: vg.Fill_Rule) -> bool {
	s, ok := vg.shape_from_path(p)
	if !ok {
		return false
	}
	defer vg.shape_destroy(&s)
	w := cv.winding(s.data, (vg.Vec2{x, y} - s.origin) / s.extent)
	return cv.fill_inside(w, rule)
}

// Total |area| of the polylines of `p` and its contour count.
@(private = "file")
flat_area :: proc(p: ^vg.Path) -> (area: f32, contours: int) {
	f: vg.Flat_Path
	defer vg.flat_path_destroy(&f)
	vg.path_flatten(p, &f)
	for ct in f.contours {
		pts := f.points[ct.first:][:ct.count]
		s: f32 = 0
		for k in 0 ..< len(pts) {
			p0, p1 := pts[k], pts[(k + 1) % len(pts)]
			s += (p1.x - p0.x) * (p1.y + p0.y)
		}
		area += abs(s) * 0.5
	}
	return area, len(f.contours)
}
