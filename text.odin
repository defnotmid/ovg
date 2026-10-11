package ovg

import "core:sync"
import "core:unicode/utf8"
import kb "vendor:kb_text_shape"
import stbtt "vendor:stb/truetype"

// Fonts via stb_truetype: metrics, kerning, glyph outlines and coverage
// bitmaps. Shaped layout is `text_layout` over a Font_Collection
// (text_shape.odin); `layout_simple` places plain left-to-right text.

Font :: struct {
	info:           stbtt.fontinfo,
	// Borrowed TTF/OTF bytes; must outlive the font.
	data:           []u8,
	// Face index in a collection file.
	index:          i32,
	// kb_text_shape's parse of the face, made by a Font_Collection on first
	// shaping use and owned by it.
	shaping:        ^kb.font,
	shaping_failed: bool,
	// COLR / CPAL colour glyphs (colr.odin); nil without them. Freed by
	// `font_destroy`.
	colr:           ^Colr,
	// Has bitmap colour glyphs (sbix, CBDT), which are not drawn: glyphs
	// without an outline count as missing for fallback.
	bitmap_colour:  bool,
}

Font_Id :: struct {
	key: Key,
}

font_id_valid :: #force_inline proc "contextless" (id: Font_Id) -> bool {
	return id.key.gen != 0
}

Glyph_Index :: distinct i32

Font_V_Metrics :: struct {
	ascent, descent, line_gap: i32,
}

font_load :: proc(data: []u8, index: i32 = 0) -> (font: Font, err: Error) {
	offset := stbtt.GetFontOffsetForIndex(raw_data(data), index)
	if offset < 0 || !stbtt.InitFont(&font.info, raw_data(data), offset) {
		return {}, .Font_Parse
	}
	font.data = data
	font.index = index
	font.colr = colr_open(&font)
	if font.colr == nil {
		base := int(font.info.fontstart)
		_, _, sbix := find_table_range(data, base, "sbix")
		_, _, cbdt := find_table_range(data, base, "CBDT")
		font.bitmap_colour = sbix || cbdt
	}
	return font, nil
}

// Frees what a font owns beyond its borrowed data (colour glyph cache and
// shaping state).
font_destroy :: proc(f: ^Font) {
	colr_destroy(f.colr)
	f.colr = nil
	font_kb_destroy(f)
}

// The glyph for `r`, or 0 when the face lacks it or has only a bitmap for it.
font_glyph_index_drawable :: proc(f: ^Font, r: rune) -> Glyph_Index {
	g := font_glyph_index(f, r)
	if g != 0 && f.bitmap_colour && stbtt.IsGlyphEmpty(&f.info, i32(g)) {
		return 0
	}
	return g
}

// Scale from font units to pixels so ascent - descent == `height`.
font_scale_for_pixel_height :: proc(f: ^Font, height: f32) -> f32 {
	return stbtt.ScaleForPixelHeight(&f.info, height)
}

// Scale from font units to pixels for a CSS-style font size (em size).
font_scale_for_em :: proc(f: ^Font, size: f32) -> f32 {
	return stbtt.ScaleForMappingEmToPixels(&f.info, size)
}

font_v_metrics :: proc(f: ^Font) -> (m: Font_V_Metrics) {
	stbtt.GetFontVMetrics(&f.info, &m.ascent, &m.descent, &m.line_gap)
	return
}

font_glyph_index :: proc(f: ^Font, r: rune) -> Glyph_Index {
	return Glyph_Index(stbtt.FindGlyphIndex(&f.info, r))
}

font_glyph_advance :: proc(f: ^Font, g: Glyph_Index) -> (advance, left_side_bearing: i32) {
	stbtt.GetGlyphHMetrics(&f.info, i32(g), &advance, &left_side_bearing)
	return
}

font_glyph_kern :: proc(f: ^Font, a, b: Glyph_Index) -> i32 {
	return stbtt.GetGlyphKernAdvance(&f.info, i32(a), i32(b))
}

// Appends the glyph outline to `p`, scaled to pixels with its origin at
// (x, y) and y pointing down.
font_glyph_path :: proc(f: ^Font, g: Glyph_Index, x, y, scale: f32, p: ^Path) -> bool {
	verts: [^]stbtt.vertex
	n := stbtt.GetGlyphShape(&f.info, i32(g), &verts)
	if n <= 0 {
		return false
	}
	defer stbtt.FreeShape(&f.info, verts)
	open := false
	for v in verts[:n] {
		px := x + f32(v.x) * scale
		py := y - f32(v.y) * scale
		#partial switch stbtt.vmove(v.type) {
		case .vmove:
			if open {
				path_close(p)
			}
			path_move_to(p, px, py)
			open = true
		case .vline:
			path_line_to(p, px, py)
		case .vcurve:
			path_quad_to(p, x + f32(v.cx) * scale, y - f32(v.cy) * scale, px, py)
		case .vcubic:
			path_bezier_to(p, x + f32(v.cx) * scale, y - f32(v.cy) * scale, x + f32(v.cx1) * scale, y - f32(v.cy1) * scale, px, py)
		}
	}
	if open {
		path_close(p)
	}
	return true
}

Font_Store :: struct {
	fonts: Slot_Map(Font),
}

font_store_init :: proc(s: ^Font_Store, allocator := context.allocator) {
	slot_map_init(&s.fonts, allocator)
}

font_store_destroy :: proc(s: ^Font_Store) {
	slot_map_destroy(&s.fonts)
}

font_store_add :: proc(s: ^Font_Store, font: Font) -> Font_Id {
	return {slot_map_insert(&s.fonts, font)}
}

font_store_get :: proc(s: ^Font_Store, id: Font_Id) -> ^Font {
	return slot_map_get(&s.fonts, id.key)
}

font_store_remove :: proc(s: ^Font_Store, id: Font_Id) {
	slot_map_remove(&s.fonts, id.key)
}

// A glyph placed on the baseline at (x, y), in pixels.
Positioned_Glyph :: struct {
	glyph: Glyph_Index,
	x, y:  f32,
}

// Plain left-to-right layout using advances and kerning; no shaping,
// ligatures or bidi. Appends to `out` and returns the pen x after the text.
layout_simple :: proc(f: ^Font, text: string, x, y, scale: f32, out: ^[dynamic]Positioned_Glyph, letter_spacing: f32 = 0) -> f32 {
	pen := x
	prev: Glyph_Index = -1
	for r in text {
		if r == utf8.RUNE_ERROR {
			continue
		}
		g := font_glyph_index(f, r)
		if prev >= 0 {
			pen += f32(font_glyph_kern(f, prev, g)) * scale
		}
		append(out, Positioned_Glyph{g, pen, y})
		adv, _ := font_glyph_advance(f, g)
		pen += f32(adv) * scale + letter_spacing
		prev = g
	}
	return pen
}

// ---- glyph atlas ------------------------------------------------------------------

Cached_Glyph :: struct {
	atlas_x, atlas_y: u32,
	width, height:    u32,
	// Offset from the pen position to the bitmap's top-left.
	bearing_x:        i32,
	bearing_y:        i32,
	// `false` for glyphs without pixels (spaces).
	visible:          bool,
}

Glyph_Key :: struct {
	font:       Key,
	glyph:      Glyph_Index,
	scale_bits: u32,
}

// Rasterized glyph coverage packed into one Gray8 image, so a run draws in a
// single call.
Glyph_Atlas :: struct {
	packer:   Atlas,
	image_id: Image_Id,
	width:    u32,
	height:   u32,
	cache:    map[Glyph_Key]Cached_Glyph,
	scratch:  [dynamic]u8,
}

glyph_atlas_init :: proc(a: ^Glyph_Atlas, c: ^Canvas, width, height: u32, allocator := context.allocator) -> Error {
	a.image_id = create_image_empty(c, width, height, .Gray8) or_return
	atlas_init(&a.packer, width, height, allocator)
	a.width = width
	a.height = height
	a.cache = make(map[Glyph_Key]Cached_Glyph, allocator)
	a.scratch = make([dynamic]u8, allocator)
	return nil
}

glyph_atlas_destroy :: proc(a: ^Glyph_Atlas, c: ^Canvas) {
	delete(a.cache)
	delete(a.scratch)
	atlas_destroy(&a.packer)
	delete_image(c, a.image_id)
	a^ = {}
}

// Drops every cached glyph; the image is reused as glyphs rebake.
glyph_atlas_reset :: proc(a: ^Glyph_Atlas) {
	clear(&a.cache)
	atlas_reset(&a.packer, a.width, a.height)
}

// Cached glyph for `(font, glyph, scale)`, rasterizing it on first use.
glyph_atlas_get :: proc(a: ^Glyph_Atlas, c: ^Canvas, font_id: Font_Id, f: ^Font, g: Glyph_Index, scale: f32) -> (cached: Cached_Glyph, err: Error) {
	scale := scale
	key := Glyph_Key{font_id.key, g, transmute(u32)scale}
	if hit, ok := a.cache[key]; ok {
		return hit, nil
	}
	x0, y0, x1, y1: i32
	stbtt.GetGlyphBitmapBox(&f.info, i32(g), scale, scale, &x0, &y0, &x1, &y1)
	w, h := u32(max(x1 - x0, 0)), u32(max(y1 - y0, 0))
	if w == 0 || h == 0 {
		a.cache[key] = {}
		return {}, nil
	}
	// One pixel of padding keeps bilinear sampling from bleeding neighbours.
	ax, ay, ok := atlas_add_rect(&a.packer, w + 1, h + 1)
	if !ok {
		return {}, .Atlas_Full
	}
	resize(&a.scratch, int(w * h))
	stbtt.MakeGlyphBitmap(&f.info, raw_data(a.scratch), i32(w), i32(h), i32(w), scale, scale, i32(g))
	update_image(c, a.image_id, image_source_gray(a.scratch[:], w, h), ax, ay) or_return
	cached = Cached_Glyph{ax, ay, w, h, x0, y0, true}
	a.cache[key] = cached
	return cached, nil
}

// ---- drawing ------------------------------------------------------------------------

// Draws glyph bitmaps from `atlas` as textured quads tinted by the paint's
// color. The current transform moves the quads but the bitmaps are baked at
// `pixel_scale`, so prefer `fill_glyph_outlines` for scaled or animated text.
fill_glyph_run :: proc(c: ^Canvas, fonts: ^Font_Store, font_id: Font_Id, atlas: ^Glyph_Atlas, glyphs: []Positioned_Glyph, pixel_scale: f32, paint: Paint) -> Error {
	f := font_store_get(fonts, font_id)
	if f == nil {
		return .Unsupported_Operation
	}
	st := state(c)
	xform := st.transform
	aw, ah := f32(atlas.width), f32(atlas.height)
	flavor := paint.flavor
	flavor_mul_alpha(&flavor, st.alpha)
	glyph_tex := Glyph_Texture{.Alpha_Mask, atlas.image_id}
	params := params_from_paint(&c.images, paint_space(paint, xform), &flavor, glyph_tex, st.scissor, 1, c.fringe_width, -1)
	params.spread = f32(paint.spread)
	// The paint row the quads name; added once there is a quad.
	paint_row := u32(len(c.paints))
	start := len(c.verts)
	for g in glyphs {
		cg := glyph_atlas_get(atlas, c, font_id, f, g.glyph, pixel_scale) or_return
		if !cg.visible {
			continue
		}
		x0 := g.x + f32(cg.bearing_x)
		y0 := g.y + f32(cg.bearing_y)
		x1 := x0 + f32(cg.width)
		y1 := y0 + f32(cg.height)
		u0 := f32(cg.atlas_x) / aw
		v0 := f32(cg.atlas_y) / ah
		u1 := f32(cg.atlas_x + cg.width) / aw
		v1 := f32(cg.atlas_y + cg.height) / ah
		p00 := transform_point(xform, x0, y0)
		p10 := transform_point(xform, x1, y0)
		p11 := transform_point(xform, x1, y1)
		p01 := transform_point(xform, x0, y1)
		append(
			&c.verts,
			vertex(p00.x, p00.y, u0, v0, paint_row),
			vertex(p10.x, p10.y, u1, v0, paint_row),
			vertex(p11.x, p11.y, u1, v1, paint_row),
			vertex(p00.x, p00.y, u0, v0, paint_row),
			vertex(p11.x, p11.y, u1, v1, paint_row),
			vertex(p01.x, p01.y, u0, v1, paint_row),
		)
	}
	if len(c.verts) == start {
		return nil
	}
	add_paint(c, params)
	append(&c.pieces, Piece{{u32(start), u32(len(c.verts) - start)}, false})
	cmd := Command {
		glyph_texture       = glyph_tex,
		composite_operation = st.composite_operation,
		scissor_rect        = current_scissor_rect(c),
	}
	attach_paint_image(c, &cmd, &flavor)
	push_draw(c, cmd, .None, paint_row, len(c.pieces) - 1)
	return nil
}

// Fills the glyph outlines as vector paths: exact under any transform and
// any paint. `scale` converts font units to pixels. `scratch` is reused
// between calls to avoid allocations (it is reset here). Colour glyphs
// (COLR) draw their own colours, `paint` standing for the text colour.
fill_glyph_outlines :: proc(c: ^Canvas, f: ^Font, glyphs: []Positioned_Glyph, scale: f32, paint: Paint, scratch: ^Path) {
	path_reset(scratch)
	if f.colr != nil {
		sync.mutex_lock(&f.colr.lock)
		for g in glyphs {
			if !colr_draw_glyph(c, f, g, scale, paint) {
				font_glyph_path(f, g.glyph, g.x, g.y, scale, scratch)
			}
		}
		sync.mutex_unlock(&f.colr.lock)
	} else {
		for g in glyphs {
			font_glyph_path(f, g.glyph, g.x, g.y, scale, scratch)
		}
	}
	if path_is_empty(scratch) {
		return
	}
	paint := paint
	paint.fill_rule = .Non_Zero
	fill_path(c, scratch, paint)
}

// Strokes the glyph outlines.
stroke_glyph_outlines :: proc(c: ^Canvas, f: ^Font, glyphs: []Positioned_Glyph, scale: f32, paint: Paint, scratch: ^Path) {
	path_reset(scratch)
	for g in glyphs {
		font_glyph_path(f, g.glyph, g.x, g.y, scale, scratch)
	}
	if path_is_empty(scratch) {
		return
	}
	stroke_path(c, scratch, paint)
}

// The glyph's bounding box in font units (y up). False for empty glyphs.
font_glyph_box :: proc(f: ^Font, g: Glyph_Index, x0, y0, x1, y1: ^i32) -> bool {
	return stbtt.GetGlyphBox(&f.info, i32(g), x0, y0, x1, y1) != 0
}
