// Scenes with known answers: each case builds a Scene and says how far a
// render of it is from exact truth (coverage as exact areas, composites
// and masks as their formulas), in 8-bit levels. tools/sdlgpu_parity runs
// every case on both backends; ovg's own tests check the software backend
// against the same truths.
package scene_truth

import vg "../.."

Case :: struct {
	name:  string,
	build: proc(s: ^vg.Scene),
	// The worst difference from the truth over the case's pixels (RGBA8,
	// premultiplied, `w` wide), in levels.
	worst: proc(px: []u8, w: int) -> f32,
}

CASES := [?]Case {
	{"coverage_rect", build_rect, worst_rect},
	{"coverage_triangle", build_triangle, worst_triangle},
	{"blend_over_half", build_over, worst_over},
	{"blend_multiply", build_multiply, worst_multiply},
	{"blend_screen", build_screen, worst_screen},
	{"opacity_zero", build_zero, worst_zero},
	{"mask_luminance", build_mask_709, worst_mask_709},
	{"mask_luminance_pdf", build_mask_pdf, worst_mask_pdf},
	{"mask_alpha", build_mask_alpha, worst_mask_alpha},
	{"mask_backdrop", build_mask_backdrop, worst_mask_backdrop},
	{"mask_transfer", build_mask_transfer, worst_mask_transfer},
	{"mask_isolated", build_mask_isolated, worst_mask_isolated},
	{"pattern_coloured", build_pattern_coloured, worst_pattern_coloured},
	{"pattern_uncoloured", build_pattern_uncoloured, worst_pattern_uncoloured},
	{"op_copy_layer", build_copy_layer, worst_copy},
	{"op_copy_run", build_copy_run, worst_copy},
	{"clips_nested", build_clips, worst_clips},
	{"run_union", build_run, worst_run},
}

// The cases draw in a SIZE x SIZE square at the top left.
SIZE :: 24

@(private = "file")
px_at :: proc(px: []u8, w, x, y: int) -> [4]f32 {
	i := (y * w + x) * 4
	return {f32(px[i]), f32(px[i + 1]), f32(px[i + 2]), f32(px[i + 3])} / 255
}

@(private = "file")
polygon :: proc(s: ^vg.Scene, pts: []vg.Vec2) -> vg.Path_Id {
	verbs := make([]vg.Path_Verb, len(pts) + 1, context.temp_allocator)
	verbs[0] = .Move
	for i in 1 ..< len(pts) {
		verbs[i] = .Line
	}
	verbs[len(pts)] = .Close
	return vg.scene_add_path(s, verbs, pts)
}

@(private = "file")
ground :: proc(s: ^vg.Scene, color: [4]f32) -> vg.Transform_Id {
	id := vg.scene_add_transform(s, vg.TRANSFORM_IDENTITY)
	vg.scene_draw(s, vg.Scene_Clear{{0, 0, 4096, 4096}, color})
	return id
}

// The area of convex polygon `poly` inside pixel (x, y): the polygon
// clipped to the pixel's square, then its shoelace area.
pixel_area :: proc(poly: []vg.Vec2, x, y: int) -> f32 {
	buf_a, buf_b: [32]vg.Vec2
	n := len(poly)
	copy(buf_a[:], poly)
	src, dst := buf_a[:], buf_b[:]
	edges := [4][3]f32{{1, 0, -f32(x)}, {-1, 0, f32(x + 1)}, {0, 1, -f32(y)}, {0, -1, f32(y + 1)}}
	for e in edges {
		m := 0
		for i in 0 ..< n {
			a, b := src[i], src[(i + 1) % n]
			da, db := e[0] * a.x + e[1] * a.y + e[2], e[0] * b.x + e[1] * b.y + e[2]
			if da >= 0 {
				dst[m] = a
				m += 1
			}
			if (da >= 0) != (db >= 0) {
				dst[m] = a + (b - a) * (da / (da - db))
				m += 1
			}
		}
		n = m
		src, dst = dst, src
	}
	area: f32
	for i in 0 ..< n {
		a, b := src[i], src[(i + 1) % n]
		area += a.x * b.y - b.x * a.y
	}
	return abs(area) * 0.5
}

@(private = "file")
RECT := [4]vg.Vec2{{2.25, 3.5}, {17.5, 3.5}, {17.5, 9.75}, {2.25, 9.75}}
@(private = "file")
TRI := [3]vg.Vec2{{3.1, 12.2}, {21.7, 14.9}, {8.4, 22.6}}

@(private = "file")
build_white :: proc(s: ^vg.Scene, poly: []vg.Vec2) {
	id := ground(s, {0, 0, 0, 1})
	vg.scene_draw(s, vg.Scene_Fill{path = polygon(s, poly), transform = id, look = vg.scene_look(vg.scene_add_paint(s, vg.Scene_Solid{{1, 1, 1, 1}}))})
}

@(private = "file")
worst_area :: proc(px: []u8, w: int, poly: []vg.Vec2) -> f32 {
	worst: f32
	for y in 0 ..< SIZE {
		for x in 0 ..< SIZE {
			worst = max(worst, abs(px_at(px, w, x, y)[0] - pixel_area(poly, x, y)))
		}
	}
	return worst * 255
}

@(private = "file")
build_rect :: proc(s: ^vg.Scene) {build_white(s, RECT[:])}
@(private = "file")
worst_rect :: proc(px: []u8, w: int) -> f32 {return worst_area(px, w, RECT[:])}
@(private = "file")
build_triangle :: proc(s: ^vg.Scene) {build_white(s, TRI[:])}
@(private = "file")
worst_triangle :: proc(px: []u8, w: int) -> f32 {return worst_area(px, w, TRI[:])}

@(private = "file")
BACK := [4]f32{0.2, 0.6, 0.9, 1}
@(private = "file")
SRC := [3]f32{0.9, 0.3, 0.5}

@(private = "file")
build_blend :: proc(s: ^vg.Scene, mode: vg.Blend_Mode, opacity: f32) {
	id := ground(s, BACK)
	look := vg.scene_look(vg.scene_add_paint(s, vg.Scene_Solid{{SRC.r, SRC.g, SRC.b, 1}}))
	look.opacity = opacity
	look.blend.mode = mode
	vg.scene_draw(s, vg.Scene_Fill{path = polygon(s, {{0, 0}, {SIZE, 0}, {SIZE, SIZE}, {0, SIZE}}), transform = id, look = look})
}

@(private = "file")
worst_color :: proc(px: []u8, w: int, want: [3]f32) -> f32 {
	worst: f32
	for y in 0 ..< SIZE {
		for x in 0 ..< SIZE {
			got := px_at(px, w, x, y)
			worst = max(worst, abs(got.r - want.r), abs(got.g - want.g), abs(got.b - want.b))
		}
	}
	return worst * 255
}

@(private = "file")
build_over :: proc(s: ^vg.Scene) {build_blend(s, .Normal, 0.5)}
@(private = "file")
worst_over :: proc(px: []u8, w: int) -> f32 {return worst_color(px, w, BACK.rgb * 0.5 + SRC * 0.5)}
@(private = "file")
build_multiply :: proc(s: ^vg.Scene) {build_blend(s, .Multiply, 1)}
@(private = "file")
worst_multiply :: proc(px: []u8, w: int) -> f32 {return worst_color(px, w, SRC * BACK.rgb)}
@(private = "file")
build_screen :: proc(s: ^vg.Scene) {build_blend(s, .Screen, 1)}
@(private = "file")
worst_screen :: proc(px: []u8, w: int) -> f32 {return worst_color(px, w, SRC + BACK.rgb - SRC * BACK.rgb)}
@(private = "file")
build_zero :: proc(s: ^vg.Scene) {build_blend(s, .Normal, 0)}
@(private = "file")
worst_zero :: proc(px: []u8, w: int) -> f32 {return worst_color(px, w, BACK.rgb)}

@(private = "file")
MASK_STRAIGHT := [3]f32{0.2, 0.7, 0.4}
@(private = "file")
MASK_ALPHA: f32 = 0.6

@(private = "file")
build_mask :: proc(s: ^vg.Scene, read: vg.Scene_Mask_Read) {
	id := vg.scene_add_transform(s, vg.TRANSFORM_IDENTITY)
	square := polygon(s, {{0, 0}, {SIZE, 0}, {SIZE, SIZE}, {0, SIZE}})
	at := u32(len(s.draws))
	a := MASK_ALPHA
	append(&s.draws, vg.Scene_Fill{path = square, transform = id, look = vg.scene_look(vg.scene_add_paint(s, vg.Scene_Solid{{MASK_STRAIGHT.r * a, MASK_STRAIGHT.g * a, MASK_STRAIGHT.b * a, a}}))})
	append(&s.masks, vg.Scene_Mask{draws = {at, 1}, read = read})
	look := vg.scene_look(vg.scene_add_paint(s, vg.Scene_Solid{{1, 1, 1, 1}}))
	look.mask = vg.Mask_Id(len(s.masks))
	vg.scene_draw(s, vg.Scene_Clear{{0, 0, 4096, 4096}, {0, 0, 0, 1}})
	vg.scene_draw(s, vg.Scene_Fill{path = square, transform = id, look = look})
}

@(private = "file")
worst_grey :: proc(px: []u8, w: int, want: f32) -> f32 {
	return worst_color(px, w, {want, want, want})
}

@(private = "file")
build_mask_709 :: proc(s: ^vg.Scene) {build_mask(s, .Luminance)}
@(private = "file")
worst_mask_709 :: proc(px: []u8, w: int) -> f32 {
	return worst_grey(px, w, (0.2125 * MASK_STRAIGHT.r + 0.7154 * MASK_STRAIGHT.g + 0.0721 * MASK_STRAIGHT.b) * MASK_ALPHA)
}
@(private = "file")
build_mask_pdf :: proc(s: ^vg.Scene) {build_mask(s, .Luminance_Pdf)}
@(private = "file")
worst_mask_pdf :: proc(px: []u8, w: int) -> f32 {
	return worst_grey(px, w, (0.3 * MASK_STRAIGHT.r + 0.59 * MASK_STRAIGHT.g + 0.11 * MASK_STRAIGHT.b) * MASK_ALPHA)
}
@(private = "file")
build_mask_alpha :: proc(s: ^vg.Scene) {build_mask(s, .Alpha)}
@(private = "file")
worst_mask_alpha :: proc(px: []u8, w: int) -> f32 {return worst_grey(px, w, MASK_ALPHA)}

@(private = "file")
CLIP_TRI := [3]vg.Vec2{{2.6, 1.3}, {22.4, 6.8}, {9.1, 21.5}}
@(private = "file")
CLIP_RECT := vg.Clip_Rect{5, 4, 18, 20}

@(private = "file")
build_clips :: proc(s: ^vg.Scene) {
	id := ground(s, {0, 0, 0, 1})
	vg.scene_draw(s, vg.Clip_Push{CLIP_RECT})
	vg.scene_draw(s, vg.Clip_Push{vg.Clip_Path{polygon(s, CLIP_TRI[:]), id, .Non_Zero}})
	vg.scene_draw(s, vg.Scene_Fill{path = polygon(s, {{0, 0}, {SIZE, 0}, {SIZE, SIZE}, {0, SIZE}}), transform = id, look = vg.scene_look(vg.scene_add_paint(s, vg.Scene_Solid{{1, 1, 1, 1}}))})
	vg.scene_draw(s, vg.Clip_Pop{})
	vg.scene_draw(s, vg.Clip_Pop{})
}

@(private = "file")
worst_clips :: proc(px: []u8, w: int) -> f32 {
	worst: f32
	for y in 0 ..< SIZE {
		for x in 0 ..< SIZE {
			r := CLIP_RECT
			in_rect: f32 = 1 if x >= int(r[0]) && x < int(r[2]) && y >= int(r[1]) && y < int(r[3]) else 0
			worst = max(worst, abs(px_at(px, w, x, y)[0] - in_rect * pixel_area(CLIP_TRI[:], x, y)))
		}
	}
	return worst * 255
}

@(private = "file")
build_run :: proc(s: ^vg.Scene) {
	id := ground(s, {0, 0, 0, 1})
	square := polygon(s, {{0, 0}, {8, 0}, {8, 8}, {0, 8}})
	shift := vg.scene_add_transform(s, vg.transform_translation(4, 0))
	g0 := u32(len(s.glyphs))
	append(&s.glyphs, vg.Scene_Glyph{square, id}, vg.Scene_Glyph{square, shift})
	append(&s.runs, vg.Scene_Run{{g0, 2}, id})
	vg.scene_draw(s, vg.Scene_Glyphs{run = vg.Run_Id(len(s.runs)), look = vg.scene_look(vg.scene_add_paint(s, vg.Scene_Solid{{0.5, 0.5, 0.5, 0.5}}))})
}

@(private = "file")
worst_run :: proc(px: []u8, w: int) -> f32 {
	// The union, x 0..12, rows 0..8: 0.5 over black; outside it black.
	worst: f32
	for y in 0 ..< SIZE {
		for x in 0 ..< SIZE {
			want: f32 = 0.5 if x < 12 && y < 8 else 0
			worst = max(worst, abs(px_at(px, w, x, y)[0] - want))
		}
	}
	return worst * 255
}


// A luminance mask over a grey backdrop (PDF's /BC): its group fills the
// left half with opaque red; the right half is the backdrop's luminance.
@(private = "file")
build_mask_backdrop :: proc(s: ^vg.Scene) {
	id := vg.scene_add_transform(s, vg.TRANSFORM_IDENTITY)
	at := u32(len(s.draws))
	append(&s.draws, vg.Scene_Fill{path = polygon(s, {{0, 0}, {SIZE / 2, 0}, {SIZE / 2, SIZE}, {0, SIZE}}), transform = id, look = vg.scene_look(vg.scene_add_paint(s, vg.Scene_Solid{{1, 0, 0, 1}}))})
	append(&s.masks, vg.Scene_Mask{draws = {at, 1}, read = .Luminance, backdrop = {0.5, 0.5, 0.5, 1}})
	look := vg.scene_look(vg.scene_add_paint(s, vg.Scene_Solid{{1, 1, 1, 1}}))
	look.mask = vg.Mask_Id(len(s.masks))
	vg.scene_draw(s, vg.Scene_Clear{{0, 0, 4096, 4096}, {0, 0, 0, 1}})
	vg.scene_draw(s, vg.Scene_Fill{path = polygon(s, {{0, 0}, {SIZE, 0}, {SIZE, SIZE}, {0, SIZE}}), transform = id, look = look})
}

@(private = "file")
worst_mask_backdrop :: proc(px: []u8, w: int) -> f32 {
	worst: f32
	for y in 0 ..< SIZE {
		for x in 0 ..< SIZE {
			want: f32 = 0.2125 if x < SIZE / 2 else 0.5
			worst = max(worst, abs(px_at(px, w, x, y)[0] - want))
		}
	}
	return worst * 255
}

// A transfer table (PDF's /TR) on a luminance mask: the inverting table
// (255 - v) on the translucent colour's PDF luminance.
@(private = "file")
build_mask_transfer :: proc(s: ^vg.Scene) {
	build_mask(s, .Luminance_Pdf)
	table: [256]u8
	for i in 0 ..< 256 {
		table[i] = u8(255 - i)
	}
	append(&s.luts, table)
	s.masks[len(s.masks) - 1].lut = vg.Lut_Id(len(s.luts))
}

@(private = "file")
worst_mask_transfer :: proc(px: []u8, w: int) -> f32 {
	v := (0.3 * MASK_STRAIGHT.r + 0.59 * MASK_STRAIGHT.g + 0.11 * MASK_STRAIGHT.b) * MASK_ALPHA
	// The table is indexed by the 8-bit value.
	return worst_grey(px, w, f32(255 - int(v * 255 + 0.5)) / 255)
}

// A soft mask's group is isolated, then composited over its backdrop (PDF
// 11.6.5.2): its opaque red drawn with Multiply stays red (Multiply over
// the group's own transparent backdrop), not red times the grey backdrop.
@(private = "file")
build_mask_isolated :: proc(s: ^vg.Scene) {
	id := vg.scene_add_transform(s, vg.TRANSFORM_IDENTITY)
	square := polygon(s, {{0, 0}, {SIZE, 0}, {SIZE, SIZE}, {0, SIZE}})
	at := u32(len(s.draws))
	look := vg.scene_look(vg.scene_add_paint(s, vg.Scene_Solid{{1, 0, 0, 1}}))
	look.blend.mode = .Multiply
	append(&s.draws, vg.Scene_Fill{path = square, transform = id, look = look})
	append(&s.masks, vg.Scene_Mask{draws = {at, 1}, read = .Luminance, backdrop = {0.5, 0.5, 0.5, 1}})
	reader := vg.scene_look(vg.scene_add_paint(s, vg.Scene_Solid{{1, 1, 1, 1}}))
	reader.mask = vg.Mask_Id(len(s.masks))
	vg.scene_draw(s, vg.Scene_Clear{{0, 0, 4096, 4096}, {0, 0, 0, 1}})
	vg.scene_draw(s, vg.Scene_Fill{path = square, transform = id, look = reader})
}

@(private = "file")
worst_mask_isolated :: proc(px: []u8, w: int) -> f32 {return worst_grey(px, w, 0.2125)}

// A pattern cell clipped to (1, 1)..(5, 5) in cell space, stepping 4, put
// at (2, 3) on the device: its 2 x 2 square at the cell's (1, 1) lands on
// device (3 + 4i, 4 + 4j). Uncoloured, the cell's blue is ignored and the
// use site's red tints its coverage.
@(private = "file")
build_pattern :: proc(s: ^vg.Scene, uncoloured: bool) {
	// The cell first: a scene is built dependencies first.
	cell_space := vg.scene_add_transform(s, vg.TRANSFORM_IDENTITY)
	cell_t := vg.scene_add_transform(s, vg.transform_translation(2, 3))
	draws := vg.scene_add_draws(s, {vg.Scene_Fill{path = polygon(s, {{1, 1}, {3, 1}, {3, 3}, {1, 3}}), transform = cell_space, look = vg.scene_look(vg.scene_add_paint(s, vg.Scene_Solid{{0, 0, 1, 1}}))}})
	append(&s.patterns, vg.Pattern_Cell{draws = draws, transform = cell_t, step = {4, 4}, clip = {1, 1, 5, 5}, uncoloured = uncoloured})
	id := ground(s, {0, 0, 0, 1})
	paint := vg.scene_add_paint(s, vg.Scene_Pattern_Paint{pattern = vg.Pattern_Id(len(s.patterns)), color = {1, 0, 0, 1}})
	vg.scene_draw(s, vg.Scene_Fill{path = polygon(s, {{0, 0}, {SIZE, 0}, {SIZE, SIZE}, {0, SIZE}}), transform = id, look = vg.scene_look(paint)})
}

@(private = "file")
worst_pattern :: proc(px: []u8, w: int, color: [3]f32) -> f32 {
	worst: f32
	for y in 0 ..< SIZE {
		for x in 0 ..< SIZE {
			on := (x - 3 + 400) % 4 < 2 && (y - 4 + 400) % 4 < 2
			want := color if on else {0, 0, 0}
			got := px_at(px, w, x, y)
			worst = max(worst, abs(got.r - want.r), abs(got.g - want.g), abs(got.b - want.b))
		}
	}
	return worst * 255
}

@(private = "file")
build_pattern_coloured :: proc(s: ^vg.Scene) {build_pattern(s, false)}
@(private = "file")
worst_pattern_coloured :: proc(px: []u8, w: int) -> f32 {return worst_pattern(px, w, {0, 0, 1})}
@(private = "file")
build_pattern_uncoloured :: proc(s: ^vg.Scene) {build_pattern(s, true)}
@(private = "file")
worst_pattern_uncoloured :: proc(px: []u8, w: int) -> f32 {return worst_pattern(px, w, {1, 0, 0})}

// A Porter-Duff operation on a layer or a run is bounded: Copy of a
// translucent blue rectangle (4.5, 4)..(14, 14) over red replaces the
// red where the content covers, edges included, and leaves the red
// everywhere else, whatever window the backend gave the layer.
@(private = "file")
COPY_RECT :: [4]vg.Vec2{{4.5, 4}, {14, 4}, {14, 14}, {4.5, 14}}
@(private = "file")
COPY_BLUE :: [4]f32{0, 0, 0.5, 0.5}

@(private = "file")
build_copy_layer :: proc(s: ^vg.Scene) {
	id := ground(s, {1, 0, 0, 1})
	rect := COPY_RECT
	vg.scene_draw(s, vg.Layer_Push{opacity = 1, isolated = true, blend = {op = .Copy}})
	vg.scene_draw(s, vg.Scene_Fill{path = polygon(s, rect[:]), transform = id, look = vg.scene_look(vg.scene_add_paint(s, vg.Scene_Solid{COPY_BLUE}))})
	vg.scene_draw(s, vg.Layer_Pop{})
}

// The same rectangle as a run of two overlapping glyphs (painted once
// where they overlap; their overlap has whole-pixel edges, as a union of
// antialiased masks is approximate where edges cross), copied.
@(private = "file")
build_copy_run :: proc(s: ^vg.Scene) {
	id := ground(s, {1, 0, 0, 1})
	left := polygon(s, {{4.5, 4}, {10, 4}, {10, 14}, {4.5, 14}})
	shift := vg.scene_add_transform(s, vg.transform_translation(4, 0))
	g0 := u32(len(s.glyphs))
	append(&s.glyphs, vg.Scene_Glyph{left, id}, vg.Scene_Glyph{left, shift})
	append(&s.runs, vg.Scene_Run{{g0, 2}, id})
	look := vg.scene_look(vg.scene_add_paint(s, vg.Scene_Solid{COPY_BLUE}))
	look.blend.op = .Copy
	vg.scene_draw(s, vg.Scene_Glyphs{run = vg.Run_Id(len(s.runs)), look = look})
}

@(private = "file")
worst_copy :: proc(px: []u8, w: int) -> f32 {
	rect := COPY_RECT
	worst: f32
	for y in 0 ..< SIZE {
		for x in 0 ..< SIZE {
			f := pixel_area(rect[:], x, y)
			want := COPY_BLUE * f if COPY_BLUE[3] * f * 255 >= 0.5 else [4]f32{1, 0, 0, 1}
			d := px_at(px, w, x, y) - want
			worst = max(worst, abs(d[0]), abs(d[1]), abs(d[2]), abs(d[3]))
		}
	}
	return worst * 255
}
