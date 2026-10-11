package scenes

import vg "../.."

// The Lottie importer (lottie.odin) on both backends: a group transform,
// rounded rect, ellipse, polystar and path; linear and radial gradients
// with opacity stops; a dashed stroke, trim paths and a repeater; masks
// (add, subtract), a luma track matte and a multiply blend, at a frame
// between keyframes.
LOTTIE_SCENE :: `{"v": "5.7.0", "fr": 30, "ip": 0, "op": 60, "w": 256, "h": 192, "layers": [
 {"ty": 4, "ind": 1, "ip": 0, "op": 60, "bm": 1, "ks": {"p": {"a": 0, "k": [200, 140]}}, "shapes": [
  {"ty": "el", "p": {"a": 0, "k": [0, 0]}, "s": {"a": 0, "k": [70, 70]}},
  {"ty": "fl", "c": {"a": 0, "k": [0.2, 0.8, 1, 1]}, "o": {"a": 0, "k": 100}}]},
 {"ty": 4, "ind": 2, "ip": 0, "op": 60, "td": 1, "ks": {}, "shapes": [
  {"ty": "rc", "p": {"a": 0, "k": [60, 150]}, "s": {"a": 0, "k": [100, 60]}, "r": {"a": 0, "k": 0}},
  {"ty": "gf", "o": {"a": 0, "k": 100}, "t": 1, "s": {"a": 0, "k": [10, 0]}, "e": {"a": 0, "k": [110, 0]},
   "g": {"p": 2, "k": {"a": 0, "k": [0, 0, 0, 0, 1, 1, 1, 1]}}}]},
 {"ty": 1, "ind": 3, "ip": 0, "op": 60, "tt": 3, "sc": "#dc2626", "sw": 256, "sh": 192, "ks": {}},
 {"ty": 4, "ind": 4, "ip": 0, "op": 60, "ks": {}, "masksProperties": [
   {"mode": "a", "inv": false, "o": {"a": 0, "k": 100}, "pt": {"a": 0, "k": {"c": true,
    "v": [[130, 10], [250, 10], [250, 100], [130, 100]], "i": [[0,0],[0,0],[0,0],[0,0]], "o": [[0,0],[0,0],[0,0],[0,0]]}}},
   {"mode": "s", "inv": false, "o": {"a": 0, "k": 70}, "pt": {"a": 0, "k": {"c": true,
    "v": [[190, 20], [230, 55], [190, 90], [150, 55]], "i": [[0,0],[0,0],[0,0],[0,0]], "o": [[0,0],[0,0],[0,0],[0,0]]}}}],
  "shapes": [
  {"ty": "rc", "p": {"a": 0, "k": [190, 55]}, "s": {"a": 0, "k": [140, 110]}, "r": {"a": 0, "k": 0}},
  {"ty": "gf", "o": {"a": 0, "k": 100}, "t": 2, "s": {"a": 0, "k": [190, 55]}, "e": {"a": 0, "k": [250, 55]},
   "h": {"a": 0, "k": 40}, "a": {"a": 0, "k": 45},
   "g": {"p": 3, "k": {"a": 0, "k": [0, 1, 1, 1, 0.5, 0.98, 0.8, 0.1, 1, 0.1, 0.3, 0.9, 0, 1, 1, 0.6]}}}]},
 {"ty": 4, "ind": 5, "ip": 0, "op": 60, "ks": {}, "shapes": [
  {"ty": "gr", "it": [
   {"ty": "rc", "p": {"a": 0, "k": [0, 0]}, "s": {"a": 0, "k": [70, 50]}, "r": {"a": 0, "k": 10}},
   {"ty": "st", "c": {"a": 0, "k": [0.1, 0.1, 0.2, 1]}, "o": {"a": 0, "k": 100}, "w": {"a": 0, "k": 3}, "lc": 2, "lj": 2,
    "d": [{"n": "d", "v": {"a": 0, "k": 8}}, {"n": "g", "v": {"a": 0, "k": 5}}, {"n": "o", "v": {"a": 0, "k": 2}}]},
   {"ty": "fl", "c": {"a": 0, "k": [0.98, 0.45, 0.09, 1]}, "o": {"a": 0, "k": 90}},
   {"ty": "tr", "p": {"a": 0, "k": [55, 45]}, "r": {"a": 1, "k": [
     {"t": 0, "s": [0], "o": {"x": [0.42], "y": [0]}, "i": {"x": [0.58], "y": [1]}}, {"t": 30, "s": [30]}]},
    "s": {"a": 0, "k": [100, 100]}, "o": {"a": 0, "k": 100}}]},
  {"ty": "gr", "it": [
   {"ty": "sr", "sy": 1, "p": {"a": 0, "k": [0, 0]}, "pt": {"a": 0, "k": 5}, "or": {"a": 0, "k": 12}, "ir": {"a": 0, "k": 5},
    "os": {"a": 0, "k": 0}, "is": {"a": 0, "k": 0}, "r": {"a": 0, "k": 0}},
   {"ty": "fl", "c": {"a": 0, "k": [0.5, 0.2, 0.9, 1]}, "o": {"a": 0, "k": 100}},
   {"ty": "rp", "c": {"a": 0, "k": 5}, "o": {"a": 0, "k": 0}, "m": 1, "tr": {"p": {"a": 0, "k": [16, 4]},
    "a": {"a": 0, "k": [0, 0]}, "s": {"a": 0, "k": [90, 90]}, "r": {"a": 0, "k": 15},
    "so": {"a": 0, "k": 100}, "eo": {"a": 0, "k": 30}}},
   {"ty": "tr", "p": {"a": 0, "k": [130, 125]}}]},
  {"ty": "sh", "ks": {"a": 1, "k": [
    {"t": 0, "s": [{"c": false, "v": [[10, 110], [60, 100], [110, 120]], "i": [[0, 0], [-20, 0], [0, 0]], "o": [[0, 0], [20, 0], [0, 0]]}],
     "o": {"x": 0.3, "y": 0}, "i": {"x": 0.7, "y": 1}},
    {"t": 30, "s": [{"c": false, "v": [[10, 120], [60, 90], [110, 105]], "i": [[0, 0], [-25, 10], [0, 0]], "o": [[0, 0], [25, -10], [0, 0]]}]}]}},
  {"ty": "st", "c": {"a": 0, "k": [0.13, 0.55, 0.13, 1]}, "o": {"a": 0, "k": 100}, "w": {"a": 0, "k": 4}, "lc": 2, "lj": 1, "ml": 4},
  {"ty": "tm", "s": {"a": 0, "k": 10}, "e": {"a": 1, "k": [{"t": 0, "s": [20]}, {"t": 30, "s": [95]}]}, "o": {"a": 0, "k": 0}, "m": 1}]}]}`

scene_lottie :: proc(c: ^vg.Canvas, r: ^Resources) {
	if !r.lottie_ready {
		r.lottie_doc, _ = vg.lottie_parse(transmute([]u8)string(LOTTIE_SCENE))
		r.lottie_ready = true
	}
	vg.layer_stack_begin(&r.layers, c, W, H, nil, r.lottie_doc.uses_blend)
	vg.lottie_draw(c, &r.layers, &r.lottie, &r.lottie_doc, 17.5)
	vg.layer_stack_end(&r.layers, c)
}

// Lottie text layers and effects: point text with a stroke, box text,
// a character animator (scale, rotation, fill, position), colour emoji;
// gaussian blur, drop shadow, fill, tint and tritone on shape layers.
LOTTIE_TEXT_FX_SCENE :: `{"v": "5.7.0", "fr": 30, "ip": 0, "op": 60, "w": 256, "h": 192,
 "fonts": {"list": [{"fName": "Vera", "fFamily": "Bitstream Vera Sans", "fStyle": "Roman", "ascent": 75}]}, "layers": [
 {"ty": 5, "ind": 1, "ip": 0, "op": 60, "ks": {"p": {"a": 0, "k": [128, 40]}},
  "t": {"d": {"k": [{"t": 0, "s": {"t": "Wavy \u2764\ufe0f text", "f": "Vera", "s": 26, "j": 2, "fc": [0.1, 0.3, 0.8], "sc": [1, 1, 1], "sw": 1.5, "of": true, "lh": 30}}]},
   "m": {"g": 1, "a": {"a": 0, "k": [0, -40]}},
   "a": [{"s": {"t": 0, "b": 1, "sh": 4, "r": 1, "s": {"a": 0, "k": 10}, "e": {"a": 0, "k": 70}, "o": {"a": 0, "k": 0}, "a": {"a": 0, "k": 100}},
     "a": {"s": {"a": 0, "k": [150, 150, 100]}, "r": {"a": 0, "k": 20}, "p": {"a": 0, "k": [0, -6, 0]}, "fc": {"a": 0, "k": [0.9, 0.1, 0.3, 1]}}}]}},
 {"ty": 5, "ind": 2, "ip": 0, "op": 60, "ks": {},
  "ef": [{"ty": 25, "ef": [{"v": {"a": 0, "k": [0, 0, 0, 1]}}, {"v": {"a": 0, "k": 140}}, {"v": {"a": 0, "k": 135}}, {"v": {"a": 0, "k": 3}}, {"v": {"a": 0, "k": 4}}]}],
  "t": {"d": {"k": [{"t": 0, "s": {"t": "Box text wraps inside its box", "f": "Vera", "s": 13, "j": 0, "fc": [0.95, 0.6, 0.1], "lh": 16, "sz": [110, 60], "ps": [10, 70]}}]}, "a": []}},
 {"ty": 4, "ind": 3, "ip": 0, "op": 60, "ks": {"p": {"a": 0, "k": [170, 95]}},
  "ef": [{"ty": 29, "ef": [{"v": {"a": 0, "k": 12}}, {"v": {"a": 0, "k": 1}}]}],
  "shapes": [{"ty": "rc", "p": {"a": 0, "k": [0, 0]}, "s": {"a": 0, "k": [50, 30]}, "r": {"a": 0, "k": 4}},
   {"ty": "fl", "c": {"a": 0, "k": [0.2, 0.7, 0.3, 1]}, "o": {"a": 0, "k": 100}}]},
 {"ty": 4, "ind": 4, "ip": 0, "op": 60, "ks": {"p": {"a": 0, "k": [40, 160]}},
  "ef": [{"ty": 21, "ef": [{"v": {"a": 0, "k": 0}}, {"v": {"a": 0, "k": 0}}, {"v": {"a": 0, "k": [0.6, 0.1, 0.8, 1]}}, {"v": {"a": 0, "k": 0}}, {"v": {"a": 0, "k": 0}}, {"v": {"a": 0, "k": 0}}, {"v": {"a": 0, "k": 0.8}}]}],
  "shapes": [{"ty": "el", "p": {"a": 0, "k": [0, 0]}, "s": {"a": 0, "k": [40, 40]}}, {"ty": "fl", "c": {"a": 0, "k": [0, 0, 0, 1]}, "o": {"a": 0, "k": 100}}]},
 {"ty": 4, "ind": 5, "ip": 0, "op": 60, "ks": {"p": {"a": 0, "k": [120, 160]}},
  "ef": [{"ty": 20, "ef": [{"v": {"a": 0, "k": [0.1, 0, 0.3, 1]}}, {"v": {"a": 0, "k": [1, 0.9, 0.5, 1]}}, {"v": {"a": 0, "k": 80}}]}],
  "shapes": [{"ty": "rc", "p": {"a": 0, "k": [0, 0]}, "s": {"a": 0, "k": [60, 36]}, "r": {"a": 0, "k": 0}},
   {"ty": "gf", "o": {"a": 0, "k": 100}, "t": 1, "s": {"a": 0, "k": [-30, 0]}, "e": {"a": 0, "k": [30, 0]}, "g": {"p": 2, "k": {"a": 0, "k": [0, 1, 0, 0, 1, 0, 0, 1]}}}]},
 {"ty": 4, "ind": 6, "ip": 0, "op": 60, "ks": {"p": {"a": 0, "k": [205, 160]}},
  "ef": [{"ty": 23, "ef": [{"v": {"a": 0, "k": [1, 0.95, 0.6, 1]}}, {"v": {"a": 0, "k": [0.9, 0.2, 0.3, 1]}}, {"v": {"a": 0, "k": [0.05, 0.05, 0.3, 1]}}]}],
  "shapes": [{"ty": "rc", "p": {"a": 0, "k": [0, 0]}, "s": {"a": 0, "k": [70, 36]}, "r": {"a": 0, "k": 0}},
   {"ty": "gf", "o": {"a": 0, "k": 100}, "t": 1, "s": {"a": 0, "k": [-35, 0]}, "e": {"a": 0, "k": [35, 0]}, "g": {"p": 2, "k": {"a": 0, "k": [0, 0, 0, 0, 1, 1, 1, 1]}}}]}]}`

scene_lottie_text_fx :: proc(c: ^vg.Canvas, r: ^Resources) {
	if !r.lottie_fx_ready {
		r.lottie_fx_doc, _ = vg.lottie_parse(transmute([]u8)string(LOTTIE_TEXT_FX_SCENE))
		r.lottie_fx_ready = true
	}
	r.lottie.fonts = &r.emoji_fonts
	vg.layer_stack_begin(&r.layers, c, W, H, nil, r.lottie_fx_doc.uses_blend)
	vg.lottie_draw(c, &r.layers, &r.lottie, &r.lottie_fx_doc, 10)
	vg.layer_stack_end(&r.layers, c)
}
