package ovg

import "core:fmt"
import "core:math"
import "core:mem"
import "core:strings"
import "core:testing"

// Lottie import: parsing into the document tables, evaluating properties,
// then drawing on the software backend and reading pixels back.

@(private = "file")
Lottie_Fx :: struct {
	backend: Software_Backend,
	canvas:  Canvas,
	layers:  Layer_Stack,
	r:       Lottie_Renderer,
	doc:     Lottie_Document,
}

@(private = "file")
lottie_fx_open :: proc(s: ^Lottie_Fx, json: string) -> Lottie_Error {
	software_backend_init(&s.backend)
	canvas_init(&s.canvas, software_backend(&s.backend))
	err: Lottie_Error
	s.doc, err = lottie_parse(transmute([]u8)json)
	lottie_renderer_bind(&s.r, &s.canvas, &s.doc)
	return err
}

@(private = "file")
lottie_fx_close :: proc(s: ^Lottie_Fx) {
	lottie_renderer_destroy(&s.r, &s.canvas)
	lottie_destroy(&s.doc)
	layer_stack_destroy(&s.layers, &s.canvas)
	canvas_destroy(&s.canvas)
	software_backend_destroy(&s.backend)
}

// Draws `frame` at the composition's size on white.
@(private = "file")
lottie_fx_draw :: proc(s: ^Lottie_Fx, frame: f32, overrides: []Lottie_Override = nil) {
	w, h := u32(s.doc.width), u32(s.doc.height)
	set_size(&s.canvas, w, h)
	clear_rect(&s.canvas, 0, 0, w, h, WHITE)
	layer_stack_begin(&s.layers, &s.canvas, w, h, nil, s.doc.uses_blend)
	lottie_draw(&s.canvas, &s.layers, &s.r, &s.doc, frame, TRANSFORM_IDENTITY, overrides)
	layer_stack_end(&s.layers, &s.canvas)
	flush(&s.canvas)
}

@(private = "file")
lottie_px :: proc(s: ^Lottie_Fx, x, y: int) -> [4]u8 {
	i := (y * int(s.backend.width) + x) * 4
	p := s.backend.pixels
	return {p[i], p[i + 1], p[i + 2], p[i + 3]}
}

@(private = "file")
near :: proc(a, b: [4]u8, tol := 3) -> bool {
	for i in 0 ..< 4 {
		if abs(int(a[i]) - int(b[i])) > tol {
			return false
		}
	}
	return true
}

@(private = "file")
RED :: [4]u8{255, 0, 0, 255}
@(private = "file")
BLUE :: [4]u8{0, 0, 255, 255}
@(private = "file")
PAPER :: [4]u8{255, 255, 255, 255}

@(test)
test_lottie_parse_tables :: proc(t: ^testing.T) {
	s: Lottie_Fx
	defer lottie_fx_close(&s)
	err := lottie_fx_open(&s, `{"v": "5.7.0", "fr": 30, "ip": 0, "op": 60, "w": 100, "h": 50,
		"assets": [{"id": "pre", "w": 20, "h": 20, "layers": [
			{"ty": 1, "ind": 1, "ip": 0, "op": 60, "sc": "#00ff00", "sw": 20, "sh": 20, "ks": {}}]}],
		"markers": [{"cm": "intro", "tm": 10, "dr": 5}],
		"layers": [
			{"ty": 0, "ind": 1, "refId": "pre", "w": 20, "h": 20, "ip": 0, "op": 60, "ks": {}, "parent": 2},
			{"ty": 3, "ind": 2, "ip": 0, "op": 60, "ks": {"p": {"a": 0, "k": [10, 10, 0]}}},
			{"ty": 4, "ind": 3, "ip": 0, "op": 60, "ks": {}, "tt": 1, "shapes": [
				{"ty": "gr", "it": [
					{"ty": "el", "p": {"a": 0, "k": [0, 0]}, "s": {"a": 0, "k": [10, 10]}},
					{"ty": "st", "c": {"a": 0, "k": [1, 0, 0, 1]}, "o": {"a": 0, "k": 100}, "w": {"a": 0, "k": 2}, "lc": 1, "lj": 3,
					 "d": [{"n": "d", "v": {"a": 0, "k": 4}}, {"n": "g", "v": {"a": 0, "k": 2}}, {"n": "o", "v": {"a": 0, "k": 1}}]},
					{"ty": "tr", "p": {"a": 0, "k": [5, 5]}, "o": {"a": 0, "k": 50}}]},
				{"ty": "mm", "mm": 1},
				{"ty": "tm", "s": {"a": 0, "k": 0}, "e": {"a": 0, "k": 50}, "o": {"a": 0, "k": 0}, "m": 2}]},
			{"ty": 13, "ind": 4, "ip": 0, "op": 60, "ks": {}, "bm": 1}]}`)
	testing.expect_value(t, err, Lottie_Error.None)
	d := &s.doc
	testing.expect_value(t, d.width, 100)
	testing.expect_value(t, d.fps, 30)
	testing.expect_value(t, len(d.comps), 2)
	testing.expect_value(t, d.comps[0].layers, Range{0, 4})
	testing.expect_value(t, d.comps[1].layers, Range{4, 1})
	testing.expect_value(t, d.layers[0].kind, Lottie_Layer_Kind.Precomp)
	testing.expect_value(t, d.layers[0].ref, 1)
	testing.expect_value(t, d.layers[0].parent, 1)
	testing.expect_value(t, d.layers[2].matte, Lottie_Matte.Alpha)
	// Old files: the matte is the layer above.
	testing.expect_value(t, d.layers[2].matte_layer, 1)
	testing.expect_value(t, d.layers[3].kind, Lottie_Layer_Kind.Other)
	testing.expect_value(t, d.layers[3].blend, Blend_Mode.Multiply)
	testing.expect(t, d.uses_blend)
	testing.expect_value(t, d.layers[4].color, Color{0, 1, 0, 1})
	// The group's children are contiguous, after the layer's items.
	sh := d.layers[2].shapes
	testing.expect_value(t, sh.count, 3)
	g := d.shapes[sh.start]
	testing.expect_value(t, g.kind, Lottie_Shape_Kind.Group)
	testing.expect_value(t, g.children.count, 2)
	testing.expect_value(t, g.paints, 1)
	testing.expect(t, g.transform >= 0)
	st := d.shapes[g.children.start + 1]
	testing.expect_value(t, st.kind, Lottie_Shape_Kind.Stroke)
	testing.expect_value(t, st.cap, Line_Cap.Butt)
	testing.expect_value(t, st.join, Line_Join.Bevel)
	testing.expect_value(t, st.dash.count, 3)
	testing.expect_value(t, d.shapes[sh.start + 1].kind, Lottie_Shape_Kind.Merge)
	testing.expect_value(t, d.shapes[sh.start + 1].stops, 1)
	tm := d.shapes[sh.start + 2]
	testing.expect_value(t, tm.kind, Lottie_Shape_Kind.Trim)
	testing.expect(t, .Trim_Sequential in tm.flags)
	testing.expect_value(t, len(d.markers), 1)
	testing.expect_value(t, d.markers[0].name, "intro")
	testing.expect_value(t, d.markers[0].frame, 10)
	// Warned: the camera.
	testing.expect_value(t, len(d.warnings), 1)

	_, bad := lottie_parse(transmute([]u8)string(`{"v": 1}`))
	testing.expect_value(t, bad, Lottie_Error.Not_Lottie)
	_, broken := lottie_parse(transmute([]u8)string(`{"v": `))
	testing.expect_value(t, broken, Lottie_Error.Json)
	testing.expect(t, lottie_sniff(transmute([]u8)string(` {"v":"5.7","layers":[]}`)))
	testing.expect(t, !lottie_sniff(transmute([]u8)string(`[1, 2]`)))
}

@(test)
test_lottie_keyframes :: proc(t: ^testing.T) {
	s: Lottie_Fx
	defer lottie_fx_close(&s)
	err := lottie_fx_open(&s, `{"v": "5.7.0", "fr": 30, "ip": 0, "op": 60, "w": 10, "h": 10, "layers": [
		{"ty": 3, "ind": 1, "ip": 0, "op": 60, "ks": {
			"o": {"a": 1, "k": [
				{"t": 0, "s": [0], "o": {"x": [0.42], "y": [0]}, "i": {"x": [0.58], "y": [1]}},
				{"t": 10, "s": [100], "h": 1},
				{"t": 20, "s": [50], "o": {"x": 0, "y": 0}, "i": {"x": 1, "y": 1}},
				{"t": 30, "s": [0]}]},
			"p": {"a": 1, "k": [
				{"t": 0, "s": [0, 0], "to": [0, -10], "ti": [0, -10], "o": {"x": 0, "y": 0}, "i": {"x": 1, "y": 1}},
				{"t": 10, "s": [20, 0]}]},
			"s": {"a": 1, "k": [
				{"t": 0, "s": [100, 100], "e": [200, 50], "o": {"x": [0, 0], "y": [0, 0]}, "i": {"x": [1, 1], "y": [1, 1]}},
				{"t": 10}]},
			"r": {"a": 0, "k": 45}}}]}`)
	testing.expect_value(t, err, Lottie_Error.None)
	d := &s.doc
	tr := &d.transforms[d.layers[0].transform]
	// Ease in-out: slow at the ends, half way at the middle (symmetric).
	testing.expect(t, abs(lottie_eval1(d, tr.opacity, 5, 0) - 50) < 0.5)
	testing.expect(t, lottie_eval1(d, tr.opacity, 1, 0) < 3)
	testing.expect(t, lottie_eval1(d, tr.opacity, 9, 0) > 97)
	testing.expect_value(t, lottie_eval1(d, tr.opacity, -5, 0), 0)
	// Hold: 100 until the next key.
	testing.expect_value(t, lottie_eval1(d, tr.opacity, 15, 0), 100)
	testing.expect_value(t, lottie_eval1(d, tr.opacity, 19.9, 0), 100)
	// Linear handles, then past the last key.
	testing.expect(t, abs(lottie_eval1(d, tr.opacity, 25, 0) - 25) < 1e-3)
	testing.expect_value(t, lottie_eval1(d, tr.opacity, 99, 0), 0)
	// Spatial: the motion path bulges up through (10, -7.5) at its middle.
	mid := lottie_eval2(d, tr.position, 5, {})
	testing.expect(t, abs(mid.x - 10) < 0.2 && abs(mid.y + 7.5) < 0.2)
	end := lottie_eval2(d, tr.position, 10, {})
	testing.expect_value(t, end, Vec2{20, 0})
	// Old format: the end value comes from "e"; the last key holds it.
	testing.expect(t, lottie_eval2(d, tr.scale, 5, {}) == Vec2{150, 75})
	testing.expect(t, lottie_eval2(d, tr.scale, 10, {}) == Vec2{200, 50})
	// The matrix: scale, rotate, move.
	m, _ := lottie_transform_matrix(d, d.layers[0].transform, 10)
	q := transform_point(m, 1, 0)
	c := math.cos(f32(math.PI / 4))
	testing.expect(t, abs(q.x - (20 + 2 * c)) < 1e-3 && abs(q.y - 2 * c) < 1e-3)
	// Easing curve solver.
	testing.expect(t, abs(lottie_ease(0.5, 0.25, 0.1, 0.25, 1) - 0.8024) < 1e-3)
	testing.expect_value(t, lottie_ease(0.3, 0.5, 0.5, 0.5, 0.5), 0.3)
}

@(test)
test_lottie_draw_layers :: proc(t: ^testing.T) {
	s: Lottie_Fx
	defer lottie_fx_close(&s)
	// Parented, with in / out points: layer 1 sits under the null 2 moved
	// to (20, 0); layer 3 shows only from frame 5.
	err := lottie_fx_open(&s, `{"v": "5.7.0", "fr": 30, "ip": 0, "op": 60, "w": 40, "h": 20, "layers": [
		{"ty": 4, "ind": 1, "parent": 2, "ip": 0, "op": 60, "ks": {}, "shapes": [
			{"ty": "rc", "p": {"a": 0, "k": [5, 10]}, "s": {"a": 0, "k": [10, 20]}, "r": {"a": 0, "k": 0}},
			{"ty": "fl", "c": {"a": 0, "k": [1, 0, 0, 1]}, "o": {"a": 0, "k": 100}}]},
		{"ty": 3, "ind": 2, "ip": 0, "op": 60, "ks": {"p": {"a": 0, "k": [20, 0]}}},
		{"ty": 1, "ind": 3, "ip": 5, "op": 60, "sc": "#0000ff", "sw": 10, "sh": 20, "ks": {}}]}`)
	testing.expect_value(t, err, Lottie_Error.None)
	lottie_fx_draw(&s, 0)
	testing.expect(t, near(lottie_px(&s, 25, 10), RED))
	testing.expect(t, near(lottie_px(&s, 5, 10), PAPER))
	lottie_fx_draw(&s, 6)
	testing.expect(t, near(lottie_px(&s, 5, 10), BLUE))
	testing.expect(t, near(lottie_px(&s, 25, 10), RED))
}

@(test)
test_lottie_trim :: proc(t: ^testing.T) {
	s: Lottie_Fx
	defer lottie_fx_close(&s)
	// A 40-unit line stroked; trimmed to its second quarter (offset by a
	// quarter turn = a quarter of the length), then wrapping.
	err := lottie_fx_open(&s, `{"v": "5.7.0", "fr": 30, "ip": 0, "op": 60, "w": 40, "h": 10, "layers": [
		{"ty": 4, "ind": 1, "ip": 0, "op": 60, "ks": {}, "shapes": [
			{"ty": "sh", "ks": {"a": 0, "k": {"c": false, "v": [[0, 5], [40, 5]], "i": [[0, 0], [0, 0]], "o": [[0, 0], [0, 0]]}}},
			{"ty": "st", "c": {"a": 0, "k": [1, 0, 0, 1]}, "o": {"a": 0, "k": 100}, "w": {"a": 0, "k": 4}, "lc": 1, "lj": 1},
			{"ty": "tm", "s": {"a": 1, "k": [{"t": 0, "s": [0], "h": 1}, {"t": 10, "s": [75]}]},
			             "e": {"a": 0, "k": 25}, "o": {"a": 0, "k": 90}, "m": 1}]}]}`)
	testing.expect_value(t, err, Lottie_Error.None)
	lottie_fx_draw(&s, 0)
	// [0, 25%] + 25% -> x in [10, 20].
	testing.expect(t, near(lottie_px(&s, 5, 5), PAPER))
	testing.expect(t, near(lottie_px(&s, 15, 5), RED))
	testing.expect(t, near(lottie_px(&s, 25, 5), PAPER))
	// [25%, 75%] + 25% -> [50%, 100%]: x in [20, 40].
	lottie_fx_draw(&s, 10)
	testing.expect(t, near(lottie_px(&s, 15, 5), PAPER))
	testing.expect(t, near(lottie_px(&s, 30, 5), RED))
	testing.expect(t, near(lottie_px(&s, 38, 5), RED))
}

@(test)
test_lottie_mattes_and_masks :: proc(t: ^testing.T) {
	// The matte layer (td) covers the left half; the next layer is red
	// everywhere, matted by it: alpha keeps the left, inverted the right.
	for tt in ([2]int{1, 2}) {
		s: Lottie_Fx
		defer lottie_fx_close(&s)
		json := fmt_lottie(tt)
		err := lottie_fx_open(&s, json)
		testing.expect_value(t, err, Lottie_Error.None)
		lottie_fx_draw(&s, 0)
		left, right := lottie_px(&s, 5, 10), lottie_px(&s, 35, 10)
		if tt == 1 {
			testing.expect(t, near(left, RED) && near(right, PAPER))
		} else {
			testing.expect(t, near(left, PAPER) && near(right, RED))
		}
	}
	// Luma matte: a white matte keeps, a black one hides.
	{
		s: Lottie_Fx
		defer lottie_fx_close(&s)
		err := lottie_fx_open(&s, `{"v": "5.7.0", "fr": 30, "ip": 0, "op": 60, "w": 40, "h": 20, "layers": [
			{"ty": 1, "ind": 1, "td": 1, "ip": 0, "op": 60, "sc": "#ffffff", "sw": 20, "sh": 20, "ks": {}},
			{"ty": 1, "ind": 2, "tt": 3, "ip": 0, "op": 60, "sc": "#ff0000", "sw": 40, "sh": 20, "ks": {}}]}`)
		testing.expect_value(t, err, Lottie_Error.None)
		lottie_fx_draw(&s, 0)
		testing.expect(t, near(lottie_px(&s, 5, 10), RED))
		testing.expect(t, near(lottie_px(&s, 35, 10), PAPER))
	}
	// Masks: add the left half, subtract its top; inverted intersect.
	{
		s: Lottie_Fx
		defer lottie_fx_close(&s)
		err := lottie_fx_open(&s, `{"v": "5.7.0", "fr": 30, "ip": 0, "op": 60, "w": 40, "h": 20, "layers": [
			{"ty": 1, "ind": 1, "ip": 0, "op": 60, "sc": "#ff0000", "sw": 40, "sh": 20, "ks": {}, "masksProperties": [
				{"mode": "a", "inv": false, "o": {"a": 0, "k": 100}, "pt": {"a": 0, "k": {"c": true,
					"v": [[0, 0], [20, 0], [20, 20], [0, 20]], "i": [[0,0],[0,0],[0,0],[0,0]], "o": [[0,0],[0,0],[0,0],[0,0]]}}},
				{"mode": "s", "inv": false, "o": {"a": 0, "k": 100}, "pt": {"a": 0, "k": {"c": true,
					"v": [[0, 0], [40, 0], [40, 10], [0, 10]], "i": [[0,0],[0,0],[0,0],[0,0]], "o": [[0,0],[0,0],[0,0],[0,0]]}}}]}]}`)
		testing.expect_value(t, err, Lottie_Error.None)
		lottie_fx_draw(&s, 0)
		testing.expect(t, near(lottie_px(&s, 5, 15), RED))
		testing.expect(t, near(lottie_px(&s, 5, 5), PAPER))
		testing.expect(t, near(lottie_px(&s, 35, 15), PAPER))
	}
}

@(private = "file")
fmt_lottie :: proc(tt: int) -> string {
	if tt == 1 {
		return `{"v": "5.7.0", "fr": 30, "ip": 0, "op": 60, "w": 40, "h": 20, "layers": [
			{"ty": 1, "ind": 1, "td": 1, "ip": 0, "op": 60, "sc": "#000000", "sw": 20, "sh": 20, "ks": {}},
			{"ty": 1, "ind": 2, "tt": 1, "ip": 0, "op": 60, "sc": "#ff0000", "sw": 40, "sh": 20, "ks": {}}]}`
	}
	return `{"v": "5.7.0", "fr": 30, "ip": 0, "op": 60, "w": 40, "h": 20, "layers": [
		{"ty": 1, "ind": 1, "td": 1, "ip": 0, "op": 60, "sc": "#000000", "sw": 20, "sh": 20, "ks": {}},
		{"ty": 1, "ind": 2, "tt": 2, "ip": 0, "op": 60, "sc": "#ff0000", "sw": 40, "sh": 20, "ks": {}}]}`
}

@(test)
test_lottie_precomp_time :: proc(t: ^testing.T) {
	s: Lottie_Fx
	defer lottie_fx_close(&s)
	// The precomp's solid shows from its frame 10: with start time 5, from
	// comp frame 15; time remapped to 1 s (frame 30), always.
	err := lottie_fx_open(&s, `{"v": "5.7.0", "fr": 30, "ip": 0, "op": 60, "w": 40, "h": 20,
		"assets": [{"id": "p", "layers": [{"ty": 1, "ind": 1, "ip": 10, "op": 60, "sc": "#ff0000", "sw": 20, "sh": 20, "ks": {}}]}],
		"layers": [
			{"ty": 0, "ind": 1, "refId": "p", "w": 20, "h": 20, "ip": 0, "op": 60, "st": 5, "ks": {}},
			{"ty": 0, "ind": 2, "refId": "p", "w": 20, "h": 20, "ip": 0, "op": 60, "ks": {"p": {"a": 0, "k": [20, 0]}},
			 "tm": {"a": 0, "k": 1}}]}`)
	testing.expect_value(t, err, Lottie_Error.None)
	lottie_fx_draw(&s, 12)
	testing.expect(t, near(lottie_px(&s, 10, 10), PAPER))
	testing.expect(t, near(lottie_px(&s, 30, 10), RED))
	lottie_fx_draw(&s, 16)
	testing.expect(t, near(lottie_px(&s, 10, 10), RED))
}

@(test)
test_lottie_no_allocation_when_warm :: proc(t: ^testing.T) {
	s: Lottie_Fx
	defer lottie_fx_close(&s)
	// Shapes, a trim, a gradient, a mask, a matte and box text with an
	// animator and an effect: once every buffer has grown, drawing more
	// frames allocates nothing.
	err := lottie_fx_open(&s, `{"v": "5.7.0", "fr": 30, "ip": 0, "op": 60, "w": 64, "h": 64, "layers": [
		{"ty": 1, "ind": 1, "td": 1, "ip": 0, "op": 60, "sc": "#ffffff", "sw": 40, "sh": 64, "ks": {}},
		{"ty": 4, "ind": 2, "tt": 1, "ip": 0, "op": 60, "ks": {"r": {"a": 1, "k": [{"t": 0, "s": [0]}, {"t": 60, "s": [90]}]}},
		 "masksProperties": [{"mode": "a", "o": {"a": 0, "k": 80}, "pt": {"a": 0, "k": {"c": true,
			"v": [[0, 0], [60, 0], [60, 60], [0, 60]], "i": [[0,0],[0,0],[0,0],[0,0]], "o": [[0,0],[0,0],[0,0],[0,0]]}}}],
		 "shapes": [
			{"ty": "gr", "it": [
				{"ty": "el", "p": {"a": 0, "k": [32, 32]}, "s": {"a": 1, "k": [{"t": 0, "s": [10, 10]}, {"t": 60, "s": [50, 40]}]}},
				{"ty": "sr", "sy": 1, "p": {"a": 0, "k": [20, 20]}, "pt": {"a": 0, "k": 5}, "or": {"a": 0, "k": 10}, "ir": {"a": 0, "k": 4}},
				{"ty": "gf", "o": {"a": 0, "k": 100}, "t": 1, "s": {"a": 0, "k": [0, 0]}, "e": {"a": 0, "k": [64, 0]},
				 "g": {"p": 2, "k": {"a": 0, "k": [0, 1, 0, 0, 1, 0, 0, 1, 0, 1, 1, 0.5]}}},
				{"ty": "st", "c": {"a": 0, "k": [0, 0, 0, 1]}, "o": {"a": 0, "k": 100}, "w": {"a": 0, "k": 2},
				 "d": [{"n": "d", "v": {"a": 0, "k": 3}}, {"n": "g", "v": {"a": 0, "k": 2}}]},
				{"ty": "tm", "s": {"a": 0, "k": 0}, "e": {"a": 1, "k": [{"t": 0, "s": [10]}, {"t": 60, "s": [100]}]}, "o": {"a": 0, "k": 30}, "m": 2},
				{"ty": "tr", "o": {"a": 0, "k": 80}}]}]},
		{"ty": 5, "ind": 3, "ip": 0, "op": 60, "ks": {"p": {"a": 0, "k": [4, 40]}},
		 "ef": [{"ty": 25, "ef": [{"v": {"a": 0, "k": [0, 0, 0, 1]}}, {"v": {"a": 0, "k": 128}}, {"v": {"a": 0, "k": 135}}, {"v": {"a": 0, "k": 3}}, {"v": {"a": 0, "k": 2}}]}],
		 "t": {"d": {"k": [{"t": 0, "s": {"t": "Text fx", "s": 12, "fc": [0, 0, 1], "lh": 14, "sz": [40, 30], "ps": [0, 0]}}]}, "m": {"g": 2},
		  "a": [{"s": {"t": 0, "b": 1, "sh": 4, "s": {"a": 1, "k": [{"t": 0, "s": [0]}, {"t": 60, "s": [100]}]}}, "a": {"r": {"a": 0, "k": 30}, "o": {"a": 0, "k": 50}}}]}}]}`)
	testing.expect_value(t, err, Lottie_Error.None)
	for f in 0 ..< 60 {
		lottie_fx_draw(&s, f32(f))
	}
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	{
		context.allocator = mem.tracking_allocator(&track)
		for f in 0 ..< 60 {
			lottie_fx_draw(&s, f32(f) + 0.5)
		}
	}
	testing.expect_value(t, track.total_allocation_count, 0)
}

@(test)
test_lottie_overrides :: proc(t: ^testing.T) {
	s: Lottie_Fx
	defer lottie_fx_close(&s)
	err := lottie_fx_open(&s, `{"v": "5.7.0", "fr": 30, "ip": 0, "op": 60, "w": 20, "h": 10, "layers": [
		{"ty": 4, "nm": "box", "ind": 1, "ip": 0, "op": 60, "ks": {}, "shapes": [
			{"ty": "rc", "p": {"a": 0, "k": [5, 5]}, "s": {"a": 0, "k": [10, 10]}, "r": {"a": 0, "k": 0}},
			{"ty": "fl", "c": {"a": 0, "k": [1, 0, 0, 1]}, "o": {"a": 0, "k": 100}}]},
		{"ty": 1, "nm": "ghost", "ind": 2, "hd": true, "ip": 0, "op": 60, "sc": "#0000ff", "sw": 20, "sh": 10, "ks": {}}]}`)
	testing.expect_value(t, err, Lottie_Error.None)
	testing.expect(t, lottie_has_layer(&s.doc, "box"))
	testing.expect(t, !lottie_has_layer(&s.doc, "nope"))

	lottie_fx_draw(&s, 0)
	testing.expect(t, near(lottie_px(&s, 5, 5), RED))
	testing.expect(t, near(lottie_px(&s, 15, 5), PAPER))

	lottie_fx_draw(&s, 0, {{name = "box", fill = Color{0, 0, 1, 1}}})
	testing.expect(t, near(lottie_px(&s, 5, 5), BLUE))

	lottie_fx_draw(&s, 0, {{name = "box", transform = Transform2D{1, 0, 0, 1, 10, 0}}})
	testing.expect(t, near(lottie_px(&s, 5, 5), PAPER))
	testing.expect(t, near(lottie_px(&s, 15, 5), RED))

	lottie_fx_draw(&s, 0, {{name = "box", opacity = 0.5}})
	testing.expect(t, near(lottie_px(&s, 5, 5), {255, 128, 128, 255}))

	lottie_fx_draw(&s, 0, {{name = "box", visible = false}})
	testing.expect(t, near(lottie_px(&s, 5, 5), PAPER))

	// A hidden layer shown, with its solid recolored.
	lottie_fx_draw(&s, 0, {{name = "ghost", visible = true, fill = Color{1, 0, 0, 1}}})
	testing.expect(t, near(lottie_px(&s, 15, 5), RED))
}

// A 40 x 40 composition with one 20 x 20 rect (centred, `color`) carrying
// the effects `ef`.
@(private = "file")
lottie_effect_doc :: proc(color, ef: string) -> string {
	return strings.concatenate({`{"v": "5.7.0", "fr": 30, "ip": 0, "op": 60, "w": 40, "h": 40, "layers": [
		{"ty": 4, "nm": "box", "ind": 1, "ip": 0, "op": 60, "ks": {}, "shapes": [
			{"ty": "rc", "p": {"a": 0, "k": [20, 20]}, "s": {"a": 0, "k": [20, 20]}, "r": {"a": 0, "k": 0}},
			{"ty": "fl", "c": {"a": 0, "k": `, color, `}, "o": {"a": 0, "k": 100}}],
		 "ef": [`, ef, `]}]}`}, context.temp_allocator)
}

@(test)
test_lottie_effects :: proc(t: ^testing.T) {
	Case :: struct {
		color, ef: string,
		// Pixels and what they should be.
		at:        [2][2]int,
		want:      [2][4]u8,
	}
	GREEN :: [4]u8{0, 255, 0, 255}
	cases := []Case {
		// Fill: the colour at the layer's alpha times the opacity.
		{`[0, 0, 0, 1]`, `{"ty": 21, "ef": [{"v": {"a": 0, "k": 0}}, {"v": {"a": 0, "k": 0}}, {"v": {"a": 0, "k": [1, 0, 0, 1]}},
			{"v": {"a": 0, "k": 0}}, {"v": {"a": 0, "k": 0}}, {"v": {"a": 0, "k": 0}}, {"v": {"a": 0, "k": 0.5}}]}`,
		 {{20, 20}, {35, 20}}, {{255, 128, 128, 255}, PAPER}},
		// Tint: white maps to the "white" colour.
		{`[1, 1, 1, 1]`, `{"ty": 20, "ef": [{"v": {"a": 0, "k": [0, 0, 0, 1]}}, {"v": {"a": 0, "k": [0, 0, 1, 1]}}, {"v": {"a": 0, "k": 100}}]}`,
		 {{20, 20}, {5, 5}}, {BLUE, PAPER}},
		// Tritone: white to the highlights, black to the shadows.
		{`[1, 1, 1, 1]`, `{"ty": 23, "ef": [{"v": {"a": 0, "k": [0, 1, 0, 1]}}, {"v": {"a": 0, "k": [0.5, 0.5, 0.5, 1]}}, {"v": {"a": 0, "k": [1, 0, 0, 1]}}]}`,
		 {{20, 20}, {5, 5}}, {GREEN, PAPER}},
		{`[0, 0, 0, 1]`, `{"ty": 23, "ef": [{"v": {"a": 0, "k": [0, 1, 0, 1]}}, {"v": {"a": 0, "k": [0.5, 0.5, 0.5, 1]}}, {"v": {"a": 0, "k": [1, 0, 0, 1]}}]}`,
		 {{20, 20}, {5, 5}}, {RED, PAPER}},
		// Drop shadow: direction 90 is to the right, softness 0 is sharp.
		{`[1, 0, 0, 1]`, `{"ty": 25, "ef": [{"v": {"a": 0, "k": [0, 0, 1, 1]}}, {"v": {"a": 0, "k": 255}}, {"v": {"a": 0, "k": 90}},
			{"v": {"a": 0, "k": 8}}, {"v": {"a": 0, "k": 0}}]}`,
		 {{20, 20}, {35, 20}}, {RED, BLUE}},
		// Gaussian blur, animated: sharp at frame 0.
		{`[1, 0, 0, 1]`, `{"ty": 29, "ef": [{"v": {"a": 1, "k": [{"t": 0, "s": [0]}, {"t": 60, "s": [20]}]}}, {"v": {"a": 0, "k": 1}}]}`,
		 {{20, 20}, {32, 20}}, {RED, PAPER}},
	}
	for c in cases {
		s: Lottie_Fx
		err := lottie_fx_open(&s, lottie_effect_doc(c.color, c.ef))
		testing.expect_value(t, err, Lottie_Error.None)
		testing.expect_value(t, len(s.doc.warnings), 0)
		lottie_fx_draw(&s, 0)
		for k in 0 ..< 2 {
			got := lottie_px(&s, c.at[k].x, c.at[k].y)
			testing.expectf(t, near(got, c.want[k], 4), "%s: (%d, %d) is %v, want %v", c.ef[:12], c.at[k].x, c.at[k].y, got, c.want[k])
		}
		lottie_fx_close(&s)
	}

	// The blur at frame 30 (blurriness 10, sigma 3) spreads past the edge.
	s: Lottie_Fx
	defer lottie_fx_close(&s)
	_ = lottie_fx_open(&s, lottie_effect_doc(`[1, 0, 0, 1]`, cases[5].ef))
	lottie_fx_draw(&s, 30)
	edge := lottie_px(&s, 31, 20)
	testing.expectf(t, !near(edge, PAPER, 8) && !near(edge, RED, 8), "blurred edge %v", edge)
	testing.expect(t, near(lottie_px(&s, 20, 20), RED, 8))

	// Unsupported effects warn; expression controls don't.
	u: Lottie_Fx
	defer lottie_fx_close(&u)
	_ = lottie_fx_open(&u, lottie_effect_doc(`[1, 0, 0, 1]`, `{"ty": 22, "nm": "Stroke", "ef": []}, {"ty": 5, "nm": "Slider Control", "ef": []}`))
	testing.expect_value(t, len(u.doc.warnings), 1)
	testing.expect_value(t, u.doc.layers[0].effects.count, 0)
}

@(test)
test_lottie_selector_mult :: proc(t: ^testing.T) {
	sel :: proc(shape: Lottie_Selector_Shape, s, e: f32) -> Lottie_Selector {
		return {shape = shape, start = s, end = e, amount = 1, smoothness = 100}
	}
	close :: proc(a, b: f32) -> bool {
		return abs(a - b) < 1e-3
	}
	sq := sel(.Square, 0, 2)
	testing.expect(t, close(lottie_selector_mult(sq, 0), 1))
	testing.expect(t, close(lottie_selector_mult(sq, 1), 1))
	testing.expect(t, close(lottie_selector_mult(sq, 2), 0))
	testing.expect(t, close(lottie_selector_mult(sel(.Square, 0, 1.5), 1), 0.5))
	testing.expect(t, close(lottie_selector_mult(sel(.Square, 0.25, 3), 0), 0.75))
	testing.expect(t, close(lottie_selector_mult(sel(.Square, 0.25, 3), 1), 1))
	up := sel(.Ramp_Up, 0, 4)
	testing.expect(t, close(lottie_selector_mult(up, 0), 0.125))
	testing.expect(t, close(lottie_selector_mult(up, 3), 0.875))
	testing.expect(t, close(lottie_selector_mult(up, 9), 1))
	testing.expect(t, close(lottie_selector_mult(sel(.Ramp_Down, 0, 4), 1), 0.625))
	tri := sel(.Triangle, 0, 4)
	testing.expect(t, close(lottie_selector_mult(tri, 1), 0.75))
	testing.expect(t, close(lottie_selector_mult(tri, 2), 0.75))
	testing.expect(t, close(lottie_selector_mult(sel(.Round, 0, 4), 1), math.sqrt(f32(1 - 0.0625))))
	testing.expect(t, close(lottie_selector_mult(sel(.Smooth, 0, 4), 1), (1 + math.cos(f32(1.75 * math.PI))) / 2))
	// Amount scales; smoothness narrows the range; ease low slows the start.
	half := sq
	half.amount = 0.5
	testing.expect(t, close(lottie_selector_mult(half, 0), 0.5))
	sm := sel(.Ramp_Up, 0, 4)
	sm.smoothness = 50
	testing.expect(t, close(lottie_selector_mult(sm, 0), 0))
	testing.expect(t, close(lottie_selector_mult(sm, 2), (0.625 - 0.25) / 0.5))
	eased := up
	eased.ease_low = 100
	testing.expect(t, lottie_selector_mult(eased, 1) < lottie_selector_mult(up, 1) - 0.05)
}

// A text layer named "T" at (x, 30) with document keyframes `docs`
// (frame 0 then 30) and animators `animators`.
@(private = "file")
lottie_text_doc :: proc(x: f32, docs: [2]string, animators: string, grouping := 1) -> string {
	return strings.concatenate({`{"v": "5.7.0", "fr": 30, "ip": 0, "op": 60, "w": 120, "h": 60,
		"fonts": {"list": [{"fName": "Vera", "fFamily": "Bitstream Vera Sans", "fStyle": "Roman", "ascent": 75}]},
		"layers": [{"ty": 5, "nm": "T", "ind": 1, "ip": 0, "op": 60, "ks": {"p": {"a": 0, "k": [`, fmt.tprint(x), `, 30]}},
		 "t": {"d": {"k": [{"t": 0, "s": `, docs[0], `}, {"t": 30, "s": `, docs[1], `}]}, "p": {}, "m": {"g": `, fmt.tprint(grouping), `, "a": {"a": 0, "k": [0, 0]}}, "a": [`, animators, `]}}]}`}, context.temp_allocator)
}

// The bounds of the non-white pixels.
@(private = "file")
lottie_ink :: proc(s: ^Lottie_Fx) -> (lo, hi: [2]int, found: bool) {
	lo, hi = {max(int), max(int)}, {-1, -1}
	for y in 0 ..< int(s.backend.height) {
		for x in 0 ..< int(s.backend.width) {
			if !near(lottie_px(s, x, y), PAPER, 40) {
				lo, hi = {min(lo.x, x), min(lo.y, y)}, {max(hi.x, x), max(hi.y, y)}
				found = true
			}
		}
	}
	return
}

@(test)
test_lottie_text_layout :: proc(t: ^testing.T) {
	s: Lottie_Fx
	defer lottie_fx_close(&s)
	red := `{"t": "Hello", "f": "Vera", "s": 20, "j": 2, "fc": [1, 0, 0], "lh": 24}`
	blue := `{"t": "Hello", "f": "Vera", "s": 20, "j": 2, "fc": [0, 0, 1], "lh": 24}`
	err := lottie_fx_open(&s, lottie_text_doc(60, {red, blue}, ""))
	testing.expect_value(t, err, Lottie_Error.None)
	testing.expect_value(t, len(s.doc.warnings), 0)
	testing.expect_value(t, s.doc.fonts[0].family, "Bitstream Vera Sans")
	testing.expect_value(t, s.doc.layers[0].kind, Lottie_Layer_Kind.Text)

	// Centred on the layer's x, sitting on its baseline.
	lottie_fx_draw(&s, 0)
	lo, hi, found := lottie_ink(&s)
	testing.expect(t, found)
	testing.expectf(t, abs((lo.x + hi.x) / 2 - 60) <= 2, "centre %d", (lo.x + hi.x) / 2)
	testing.expectf(t, hi.y <= 31 && lo.y >= 12, "rows %d..%d", lo.y, hi.y)
	testing.expect(t, near(lottie_px(&s, lo.x + 1, 28), RED, 60) || near(lottie_px(&s, lo.x + 2, 28), RED, 60))

	// The document keyframe at 30, and a replaced string.
	lottie_fx_draw(&s, 30)
	lo2, hi2, _ := lottie_ink(&s)
	any_blue := false
	for x in lo2.x ..= hi2.x {
		any_blue ||= near(lottie_px(&s, x, 26), BLUE, 60)
	}
	testing.expect(t, any_blue)
	lottie_fx_draw(&s, 0, {{name = "T", text = "Hello Hello"}})
	lo3, hi3, _ := lottie_ink(&s)
	testing.expect(t, hi3.x - lo3.x > hi.x - lo.x + 30)
	lottie_fx_draw(&s, 0, {{name = "T", text = ""}})
	_, _, found = lottie_ink(&s)
	testing.expect(t, !found)

	// Box text wraps at spaces into lines within the box.
	b: Lottie_Fx
	defer lottie_fx_close(&b)
	box := `{"t": "one two three four", "f": "Vera", "s": 10, "j": 0, "fc": [0, 0, 0], "lh": 12, "sz": [40, 50], "ps": [-20, -25]}`
	_ = lottie_fx_open(&b, lottie_text_doc(60, {box, box}, ""))
	lottie_fx_draw(&b, 0)
	lay := &b.r.text.layout
	testing.expectf(t, len(lay.lines) >= 3, "%d lines", len(lay.lines))
	for line in lay.lines {
		testing.expectf(t, line.width <= 40.5, "line width %v", line.width)
	}
	// The first baseline: the box top plus the font's ascent (75%).
	testing.expect(t, abs(lay.glyphs[0].y - (-25 + 7.5)) < 0.01)
	lo4, hi4, _ := lottie_ink(&b)
	testing.expect(t, lo4.x >= 39 && hi4.x <= 81)
}

@(test)
test_lottie_text_animators :: proc(t: ^testing.T) {
	s: Lottie_Fx
	defer lottie_fx_close(&s)
	doc := `{"t": "AB CD", "f": "Vera", "s": 20, "j": 0, "fc": [0, 0, 0], "lh": 24}`
	// Characters: the first 40% (two of five letters) move down 20, turn 90
	// degrees and turn red; words (b 3): the first of two words fades out.
	anims := `{"s": {"t": 0, "b": 1, "sh": 1, "r": 1, "s": {"a": 0, "k": 0}, "e": {"a": 0, "k": 40}, "o": {"a": 0, "k": 0}, "a": {"a": 0, "k": 100}},
		 "a": {"p": {"a": 0, "k": [0, 20, 0]}, "r": {"a": 0, "k": 90}, "fc": {"a": 0, "k": [1, 0, 0, 1]}}},
		{"s": {"t": 0, "b": 3, "sh": 1, "r": 1, "s": {"a": 0, "k": 0}, "e": {"a": 0, "k": 50}, "o": {"a": 0, "k": 0}, "a": {"a": 0, "k": 100}},
		 "a": {"o": {"a": 0, "k": 0}}}`
	err := lottie_fx_open(&s, lottie_text_doc(10, {doc, doc}, anims))
	testing.expect_value(t, err, Lottie_Error.None)
	testing.expect_value(t, len(s.doc.warnings), 0)
	testing.expect_value(t, s.doc.texts[0].animators.count, 2)
	lottie_fx_draw(&s, 0)
	letters := s.r.text.letters[:]
	testing.expect_value(t, len(letters), 5)
	// A: turned about its own middle and moved down 20.
	a := letters[0]
	testing.expect(t, abs(a.m[0]) < 1e-4 && abs(a.m[1] - 1) < 1e-4)
	pivot := Vec2{a.x + a.w / 2, 0}
	moved := transform_point(a.m, pivot.x, pivot.y)
	testing.expect(t, abs(moved.x - pivot.x) < 1e-3 && abs(moved.y - 20) < 1e-3)
	testing.expect_value(t, a.fill, Color{1, 0, 0, 1})
	// C: untouched by the first animator, shown (second word).
	c := letters[3]
	testing.expect_value(t, c.m, TRANSFORM_IDENTITY)
	testing.expect_value(t, c.fill, Color{0, 0, 0, 1})
	testing.expect(t, c.opacity == 1)
	// The first word (and its space) faded out.
	testing.expect(t, letters[0].opacity == 0 && letters[1].opacity == 0 && letters[2].opacity == 0)
	// Only the second word's ink shows, right of the first.
	lo, _, found := lottie_ink(&s)
	testing.expect(t, found)
	testing.expectf(t, f32(lo.x) >= 10 + c.x - 1, "ink from %d, C at %v", lo.x, 10 + c.x)
}

@(test)
test_lottie_text_emoji :: proc(t: ^testing.T) {
	s: Lottie_Fx
	defer lottie_fx_close(&s)
	fonts: Font_Collection
	font_collection_init(&fonts)
	defer font_collection_destroy(&fonts)
	testing.expect(t, font_collection_set_emoji(&fonts, EMOJI_FONT_DATA))
	doc := `{"t": "Hi ❤️", "f": "Vera", "s": 20, "j": 0, "fc": [0, 0, 0], "lh": 24}`
	_ = lottie_fx_open(&s, lottie_text_doc(10, {doc, doc}, ""))
	s.r.fonts = &fonts
	lottie_fx_draw(&s, 0)
	lay := &s.r.text.layout
	colour := false
	for run in lay.runs {
		colour ||= run.font == &fonts.emoji.font
	}
	testing.expect(t, colour)
	// The heart draws in its own red.
	reddish := false
	for y in 0 ..< 60 {
		for x in 0 ..< 120 {
			p := lottie_px(&s, x, y)
			reddish ||= p.r > 180 && p.g < 90 && p.b < 110
		}
	}
	testing.expect(t, reddish)
}

// lottie-web's behaviour in corners the suite's files miss.
@(test)
test_lottie_web_parity :: proc(t: ^testing.T) {
	check :: proc(t: ^testing.T, json: string, x, y: int, want: [4]u8, loc := #caller_location) {
		s: Lottie_Fx
		testing.expect_value(t, lottie_fx_open(&s, json), Lottie_Error.None, loc = loc)
		defer lottie_fx_close(&s)
		lottie_fx_draw(&s, 0)
		got := lottie_px(&s, x, y)
		testing.expectf(t, near(got, want), "(%d, %d): got %v, want %v", x, y, got, want, loc = loc)
	}
	// Masks of mode None (paths for effects) do not cut the layer.
	none_mask := `{"v":"5.7.0","fr":30,"ip":0,"op":60,"w":40,"h":40,"layers":[
		{"ty":1,"ind":1,"ip":0,"op":60,"sc":"#ff0000","sw":40,"sh":40,"ks":{},
		 "masksProperties":[{"mode":"n","o":{"a":0,"k":100},"pt":{"a":0,"k":{"c":true,"v":[[0,0],[10,0],[10,10],[0,10]],"i":[[0,0],[0,0],[0,0],[0,0]],"o":[[0,0],[0,0],[0,0],[0,0]]}}}]}]}`
	check(t, none_mask, 20, 20, RED)

	// A repeater's fractional offset scales linearly: 200% at offset 0.5 is
	// 1.5x, so the 40 px square spans 20..80.
	frac := `{"v":"5.7.0","fr":30,"ip":0,"op":60,"w":100,"h":100,"layers":[
		{"ty":4,"ind":1,"ip":0,"op":60,"ks":{},"shapes":[
		 {"ty":"rc","p":{"a":0,"k":[50,50]},"s":{"a":0,"k":[40,40]},"r":{"a":0,"k":0}},
		 {"ty":"fl","c":{"a":0,"k":[1,0,0,1]},"o":{"a":0,"k":100}},
		 {"ty":"rp","c":{"a":0,"k":1},"o":{"a":0,"k":0.5},"m":1,"tr":{"p":{"a":0,"k":[0,0]},"a":{"a":0,"k":[50,50]},"s":{"a":0,"k":[200,200]},"r":{"a":0,"k":0},"so":{"a":0,"k":100},"eo":{"a":0,"k":100}}}]}]}`
	check(t, frac, 21, 50, RED)
	check(t, frac, 18, 50, PAPER)

	// Copies turn, then scale (both about the anchor): a 20 x 4 bar turned
	// 90 degrees and scaled [200, 100] is 8 wide and 20 tall.
	rot_scale := `{"v":"5.7.0","fr":30,"ip":0,"op":60,"w":100,"h":100,"layers":[
		{"ty":4,"ind":1,"ip":0,"op":60,"ks":{},"shapes":[
		 {"ty":"rc","p":{"a":0,"k":[50,50]},"s":{"a":0,"k":[20,4]},"r":{"a":0,"k":0}},
		 {"ty":"fl","c":{"a":0,"k":[1,0,0,1]},"o":{"a":0,"k":100}},
		 {"ty":"rp","c":{"a":0,"k":2},"o":{"a":0,"k":0},"m":1,"tr":{"p":{"a":0,"k":[0,0]},"a":{"a":0,"k":[50,50]},"s":{"a":0,"k":[200,100]},"r":{"a":0,"k":90},"so":{"a":0,"k":100},"eo":{"a":0,"k":100}}}]}]}`
	check(t, rot_scale, 53, 42, RED)
	check(t, rot_scale, 50, 32, PAPER)

	// A paint below a repeater fills every copy (lottie-web clones the items
	// above the repeater into its group).
	below := `{"v":"5.7.0","fr":30,"ip":0,"op":60,"w":100,"h":20,"layers":[
		{"ty":4,"ind":1,"ip":0,"op":60,"ks":{},"shapes":[
		 {"ty":"rc","p":{"a":0,"k":[10,10]},"s":{"a":0,"k":[10,10]},"r":{"a":0,"k":0}},
		 {"ty":"rp","c":{"a":0,"k":3},"o":{"a":0,"k":0},"m":1,"tr":{"p":{"a":0,"k":[30,0]},"a":{"a":0,"k":[0,0]},"s":{"a":0,"k":[100,100]},"r":{"a":0,"k":0},"so":{"a":0,"k":100},"eo":{"a":0,"k":100}}},
		 {"ty":"fl","c":{"a":0,"k":[1,0,0,1]},"o":{"a":0,"k":100}}]}]}`
	check(t, below, 10, 10, RED)
	check(t, below, 40, 10, RED)
	check(t, below, 70, 10, RED)
	check(t, below, 90, 10, PAPER)

	// A group's opacity fades its own paints only: the parent's fill still
	// fills its paths.
	group_opacity := `{"v":"5.7.0","fr":30,"ip":0,"op":60,"w":40,"h":40,"layers":[
		{"ty":4,"ind":1,"ip":0,"op":60,"ks":{},"shapes":[
		 {"ty":"gr","it":[{"ty":"rc","p":{"a":0,"k":[20,20]},"s":{"a":0,"k":[20,20]},"r":{"a":0,"k":0}},{"ty":"tr","o":{"a":0,"k":0}}]},
		 {"ty":"fl","c":{"a":0,"k":[1,0,0,1]},"o":{"a":0,"k":100}}]}]}`
	check(t, group_opacity, 20, 20, RED)

	// An image layer draws at its asset's size: a 2 x 2 red bitmap with
	// w / h 20 covers 20 x 20.
	asset_size := `{"v":"5.7.0","fr":30,"ip":0,"op":60,"w":40,"h":40,
		"assets":[{"id":"im","w":20,"h":20,"u":"","p":"data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAEUlEQVR4nGP4z8DwH4QZYAwAR8oH+WdZbrcAAAAASUVORK5CYII=","e":1}],
		"layers":[{"ty":2,"ind":1,"refId":"im","ip":0,"op":60,"ks":{}}]}`
	check(t, asset_size, 10, 10, RED)
	check(t, asset_size, 30, 30, PAPER)
}

// The Lottie tables are complete: every effect kind reads at most
// LOTTIE_EFFECT_MAX_PARAMS controls and has a distinct type number; every
// animator property has a file key.
@(test)
test_lottie_tables :: proc(t: ^testing.T) {
	effects := LOTTIE_EFFECTS
	for info, kind in effects {
		testing.expectf(t, int(info.count) <= LOTTIE_EFFECT_MAX_PARAMS && info.type_id > 0, "%v: bad row", kind)
		for other, k2 in effects {
			testing.expectf(t, k2 == kind || other.type_id != info.type_id, "%v and %v share type %d", kind, k2, info.type_id)
		}
	}
	for info, prop in LOTTIE_ANIMATOR_PROPS {
		testing.expectf(t, info.key != "", "%v: no key", prop)
	}
}

// A text stroke colour with document width 0 still strokes once an
// animator gives it width (lottie-web strokes whenever `sc` is set).
@(test)
test_lottie_text_stroke_width_animated :: proc(t: ^testing.T) {
	s: Lottie_Fx
	err := lottie_fx_open(&s, `{"v":"5.7.0","fr":30,"ip":0,"op":60,"w":120,"h":60,"layers":[
		{"ty":5,"ind":1,"ip":0,"op":60,"st":0,"ks":{"p":{"a":0,"k":[8,44]}},
		 "t":{"d":{"k":[{"t":0,"s":{"t":"HH","s":40,"sc":[1,0,0],"sw":0,"lh":48}}]},"m":{"g":1},
		  "a":[{"s":{"t":0,"b":1,"sh":1,"s":{"a":0,"k":0},"e":{"a":0,"k":100}},"a":{"sw":{"a":0,"k":6}}}]}}]}`)
	testing.expect_value(t, err, Lottie_Error.None)
	defer lottie_fx_close(&s)
	lottie_fx_draw(&s, 0)
	red := 0
	for y in 0 ..< 60 {
		for x in 0 ..< 120 {
			if p := lottie_px(&s, x, y); p.r > 200 && p.g < 80 {
				red += 1
			}
		}
	}
	testing.expectf(t, red > 50, "stroked pixels: %d", red)
}

// Merge paths, each mode on two overlapping rects (A at x 0..20, B at
// 10..30), filled after the merge: Skottie's left fold over the geometry
// above, in file order. The operands' own paints draw nothing.
@(test)
test_lottie_merge_paths :: proc(t: ^testing.T) {
	Want :: struct {
		mode:    int,
		a, ab, b: bool,
	}
	wants := [?]Want{{1, true, true, true}, {2, true, true, true}, {3, true, false, false}, {4, false, true, false}, {5, true, false, true}}
	for w in wants {
		s: Lottie_Fx
		defer lottie_fx_close(&s)
		json := fmt.tprintf(`{{"v": "5.7.0", "fr": 30, "ip": 0, "op": 60, "w": 40, "h": 20, "layers": [
			{{"ty": 4, "ind": 1, "ip": 0, "op": 60, "ks": {{}}, "shapes": [
				{{"ty": "rc", "p": {{"a": 0, "k": [10, 10]}}, "s": {{"a": 0, "k": [20, 20]}}, "r": {{"a": 0, "k": 0}}}},
				{{"ty": "fl", "c": {{"a": 0, "k": [0, 0, 1, 1]}}, "o": {{"a": 0, "k": 100}}}},
				{{"ty": "gr", "it": [
					{{"ty": "rc", "p": {{"a": 0, "k": [0, 0]}}, "s": {{"a": 0, "k": [20, 20]}}, "r": {{"a": 0, "k": 0}}}},
					{{"ty": "tr", "p": {{"a": 0, "k": [20, 10]}}}}]}},
				{{"ty": "mm", "mm": %d}},
				{{"ty": "fl", "c": {{"a": 0, "k": [1, 0, 0, 1]}}, "o": {{"a": 0, "k": 100}}}}]}}]}}`, w.mode)
		testing.expect_value(t, lottie_fx_open(&s, json), Lottie_Error.None)
		lottie_fx_draw(&s, 0)
		for c in ([3]struct {
				x:    int,
				want: bool,
			}{{5, w.a}, {15, w.ab}, {25, w.b}}) {
			px := lottie_px(&s, c.x, 10)
			testing.expectf(t, near(px, RED if c.want else PAPER), "mode %d at x %d: %v", w.mode, c.x, px)
		}
		testing.expect_value(t, s.r.merge_fallbacks, 0)
		testing.expect_value(t, len(s.doc.warnings), 0)
	}
}
