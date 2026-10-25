package ovg

import "base:runtime"
import "core:hash"
import "core:math"
import "core:mem"
import "core:sync"
import "core:unicode/utf8"

import cv "curves"
import ft "deps:oglyph/font"
import sh "deps:oglyph/shape"

// Fonts read by ovg/font (font/font.odin): metrics, kerning and glyph
// outlines; glyphs draw as shapes, and atlas bitmaps are the shapes'
// coverage. Shaped layout is `text_layout` over a Font_Collection
// (text_shape.odin); `layout_simple` places plain left-to-right text.

Font :: struct {
	face:           ft.Face,
	// Borrowed TTF/OTF bytes; must outlive the font.
	data:           []u8,
	// Face index in a collection file.
	index:          i32,
	// The face's layout tables prepared for shaping (text_shape.odin), made
	// by a Font_Collection on first use. Freed by `font_destroy`.
	shaping:        ^sh.Layout,
	// COLR / CPAL colour glyphs (colr.odin); nil without them. Freed by
	// `font_destroy`.
	colr:           ^Colr,
	// Has bitmap colour glyphs (sbix, CBDT), which are not drawn: glyphs
	// without an outline count as missing for fallback.
	bitmap_colour:  bool,
	// The glyphs' shapes (shape.odin), each built on first use and kept
	// for the font's life, and the outline glyphs are read into; made on
	// first use. Freed by `font_destroy`.
	shapes:         ^Font_Shapes,
	// What the font allocates with when it builds on first use (its
	// shapes), whatever allocator the drawing code runs under: the
	// context's at `font_load`; the heap for a font made otherwise.
	allocator:      mem.Allocator,
	// The variable font instance it draws, as a key: 0 for the default,
	// else a hash of the face's coordinates (glyph atlases tell instances
	// of one face apart by it).
	instance:       u64,
}

@(private)
Font_Shapes :: struct {
	lock:      sync.Mutex,
	// nil for glyphs without an outline.
	glyphs:    map[Glyph_Index]^Shape,
	// Where a glyph's outline is read and its shape built (under the lock).
	outline:   ft.Outline,
	builder:   Shape_Builder,
	allocator: mem.Allocator,
}

// The font's allocator (`Font.allocator`).
@(private)
font_allocator :: proc(f: ^Font) -> mem.Allocator {
	return f.allocator if f.allocator.procedure != nil else runtime.heap_allocator()
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

// Reads face `index` of a font or collection; .Font_Parse when it isn't
// one or lacks what drawing text needs (ft.load says which). A variable
// font draws the instance `variations` pick (user values per axis tag,
// `{{"wght", 700}}`; axes not named keep their default): outlines,
// advances, glyph boxes and shaping follow it, for the font's life.
font_load :: proc(data: []u8, index: i32 = 0, allocator := context.allocator, variations: []Font_Variation = nil) -> (font: Font, err: Error) {
	face, face_err := ft.load(data, int(index))
	if face_err != nil {
		return {}, .Font_Parse
	}
	if len(variations) > 0 {
		ft.set_variations(&face, variations)
		if ft.has_variation(&face) {
			font.instance = hash.fnv64a(mem.slice_to_bytes(face.coords[:face.axis_count])) | 1
		}
	}
	font.face = face
	font.data = data
	font.index = index
	font.allocator = allocator
	font.colr = colr_open(&font)
	if font.colr == nil {
		font.bitmap_colour = face.tables[.sbix].at != 0 || face.tables[.CBDT].at != 0
	}
	return font, nil
}

// Frees what a font owns beyond its borrowed data (colour glyph cache and
// shaping state).
font_destroy :: proc(f: ^Font) {
	colr_destroy(f.colr)
	f.colr = nil
	if fs := f.shapes; fs != nil {
		for _, s in fs.glyphs {
			if s != nil {
				shape_destroy(s)
				free(s, fs.allocator)
			}
		}
		delete(fs.glyphs)
		ft.outline_destroy(&fs.outline)
		shape_builder_destroy(&fs.builder)
		free(fs, fs.allocator)
		f.shapes = nil
	}
	font_shaping_destroy(f)
}

// The glyph's shape, built on first use (safe from several threads) and
// owned by the font until `font_destroy`; nil for glyphs without an outline. Shape units map to
// font units, y down, the pen at the origin (`shape_local`).
font_glyph_shape :: proc(f: ^Font, g: Glyph_Index) -> ^Shape {
	fs := font_shapes(f)
	sync.mutex_lock(&fs.lock)
	defer sync.mutex_unlock(&fs.lock)
	if s, ok := fs.glyphs[g]; ok {
		return s
	}
	context.allocator = fs.allocator
	shape, ok := shape_from_glyph(f, g, &fs.outline, builder = &fs.builder)
	s: ^Shape
	if ok {
		s = new_clone(shape)
	}
	fs.glyphs[g] = s
	return s
}

// The font's shapes, made on first use (safe from several threads).
@(private)
font_shapes :: proc(f: ^Font) -> ^Font_Shapes {
	fs := sync.atomic_load_explicit(&f.shapes, .Acquire)
	if fs != nil {
		return fs
	}
	allocator := font_allocator(f)
	fresh := new(Font_Shapes, allocator)
	fresh.glyphs = make(map[Glyph_Index]^Shape, allocator)
	fresh.outline = {
		verbs  = make([dynamic]ft.Verb, allocator),
		points = make([dynamic][2]f32, allocator),
		glyf   = make(#soa[dynamic]ft.Glyf_Point, allocator),
		ends   = make([dynamic]int, allocator),
	}
	fresh.builder.curves.allocator = allocator
	fresh.allocator = allocator
	if old, won := sync.atomic_compare_exchange_strong_explicit(&f.shapes, nil, fresh, .Acq_Rel, .Acquire); !won {
		delete(fresh.glyphs)
		ft.outline_destroy(&fresh.outline)
		free(fresh, allocator)
		return old
	}
	return fresh
}

// The glyph for `r`, or 0 when the face lacks it or has only a bitmap for it.
font_glyph_index_drawable :: proc(f: ^Font, r: rune) -> Glyph_Index {
	return glyph_drawable(f, font_glyph_index(f, r))
}

// `g`, or 0 when the face has only a bitmap for it.
@(private)
glyph_drawable :: #force_inline proc(f: ^Font, g: Glyph_Index) -> Glyph_Index {
	if g != 0 && f.bitmap_colour && ft.glyph_empty(&f.face, ft.Glyph(g)) {
		return 0
	}
	return g
}

// Scale from font units to pixels so ascent - descent == `height`.
font_scale_for_pixel_height :: proc(f: ^Font, height: f32) -> f32 {
	return ft.scale_for_pixel_height(&f.face, height)
}

// Scale from font units to pixels for a CSS-style font size (em size).
font_scale_for_em :: proc(f: ^Font, size: f32) -> f32 {
	return ft.scale_for_em(&f.face, size)
}

font_v_metrics :: proc(f: ^Font) -> Font_V_Metrics {
	return {i32(f.face.ascent), i32(f.face.descent), i32(f.face.line_gap)}
}

font_glyph_index :: proc(f: ^Font, r: rune) -> Glyph_Index {
	return Glyph_Index(ft.glyph_index(&f.face, r))
}

// The glyph's advance at the font's instance, and its left side bearing as
// hmtx stores it (the default instance's).
font_glyph_advance :: proc(f: ^Font, g: Glyph_Index) -> (advance, left_side_bearing: i32) {
	_, b := ft.h_metrics(&f.face, ft.Glyph(g))
	return i32(ft.advance(&f.face, ft.Glyph(g))), i32(b)
}

font_glyph_kern :: proc(f: ^Font, a, b: Glyph_Index) -> i32 {
	return i32(ft.kern(&f.face, ft.Glyph(a), ft.Glyph(b)))
}

// Appends the glyph outline to `p`, scaled to pixels with its origin at
// (x, y) and y pointing down.
font_glyph_path :: proc(f: ^Font, g: Glyph_Index, x, y, scale: f32, p: ^Path) -> bool {
	return font_glyph_path_transformed(f, g, {scale, 0, 0, -scale, x, y}, p)
}

// Appends the glyph outline to `p`, its font units (y up) mapped by `m`.
font_glyph_path_transformed :: proc(f: ^Font, g: Glyph_Index, m: Transform2D, p: ^Path) -> bool {
	fs := font_shapes(f)
	sync.mutex_lock(&fs.lock)
	defer sync.mutex_unlock(&fs.lock)
	o := &fs.outline
	if !ft.glyph_outline(&f.face, ft.Glyph(g), o) {
		return false
	}
	at :: proc(o: ^ft.Outline, i: int, m: Transform2D) -> (f32, f32) {
		q := transform_point(m, o.points[i].x, o.points[i].y)
		return q.x, q.y
	}
	i := 0
	for v, k in o.verbs {
		switch v {
		case .Move:
			if k > 0 {
				path_close(p)
			}
			path_move_to(p, at(o, i, m))
			i += 1
		case .Line:
			path_line_to(p, at(o, i, m))
			i += 1
		case .Quad:
			cx, cy := at(o, i, m)
			px, py := at(o, i + 1, m)
			path_quad_to(p, cx, cy, px, py)
			i += 2
		case .Cubic:
			c1x, c1y := at(o, i, m)
			c2x, c2y := at(o, i + 1, m)
			px, py := at(o, i + 2, m)
			path_bezier_to(p, c1x, c1y, c2x, c2y, px, py)
			i += 3
		}
	}
	path_close(p)
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

// A glyph at one scale in one face and instance. Faces are told apart by
// their data address, face index and instance, so fonts from a Font_Store
// or a Font_Collection (text_layout's runs) share an atlas; reset it when
// font data is freed, as new data may reuse the address.
Glyph_Key :: struct {
	data:       rawptr,
	index:      i32,
	glyph:      Glyph_Index,
	scale_bits: u32,
	instance:   u64,
}

glyph_key :: proc "contextless" (f: ^Font, g: Glyph_Index, scale: f32) -> Glyph_Key {
	return {raw_data(f.data), f.index, g, transmute(u32)scale, f.instance}
}

// Rasterized glyph coverage packed into one Gray8 bitmap, `pixels` (row-major,
// `width` bytes a row), so a run draws in a single call. The atlas is CPU
// only; whoever draws from it uploads the rows `glyph_atlas_take_dirty`
// reports into its own texture once per frame. Made with a canvas, it keeps
// that canvas's copy in `image_id`, which `fill_glyph_run` updates.
Glyph_Atlas :: struct {
	packer:             Atlas,
	width:              u32,
	height:             u32,
	pixels:             []u8,
	cache:              map[Glyph_Key]Cached_Glyph,
	// Rows [dirty_y0, dirty_y1) changed since the last take; empty when equal.
	dirty_y0, dirty_y1: u32,
	// The canvas image mirroring `pixels`; zero for a canvas-free atlas.
	image_id:           Image_Id,
}

// `c` is the canvas `fill_glyph_run` draws the atlas on, or nil for an atlas
// whose owner uploads `pixels` itself.
glyph_atlas_init :: proc(a: ^Glyph_Atlas, width, height: u32, c: ^Canvas = nil, allocator := context.allocator) -> Error {
	a^ = {}
	if c != nil {
		a.image_id = create_image_empty(c, width, height, .Gray8) or_return
	}
	a.pixels = make([]u8, int(width) * int(height), allocator)
	atlas_init(&a.packer, width, height, allocator)
	a.width = width
	a.height = height
	a.cache = make(map[Glyph_Key]Cached_Glyph, allocator)
	return nil
}

// `c` is the canvas the atlas was made with, if any.
glyph_atlas_destroy :: proc(a: ^Glyph_Atlas, c: ^Canvas = nil) {
	delete(a.cache)
	delete(a.pixels)
	atlas_destroy(&a.packer)
	if c != nil && image_id_valid(a.image_id) {
		delete_image(c, a.image_id)
	}
	a^ = {}
}

// Drops every cached glyph and clears the bitmap (all rows dirty).
glyph_atlas_reset :: proc(a: ^Glyph_Atlas) {
	clear(&a.cache)
	atlas_reset(&a.packer, a.width, a.height)
	mem.zero_slice(a.pixels)
	a.dirty_y0, a.dirty_y1 = 0, a.height
}

// Cached glyph for `(font, glyph, scale)`, rasterizing it into `pixels` on
// first use.
glyph_atlas_get :: proc(a: ^Glyph_Atlas, f: ^Font, g: Glyph_Index, scale: f32) -> (cached: Cached_Glyph, err: Error) {
	key := glyph_key(f, g, scale)
	if hit, ok := a.cache[key]; ok {
		return hit, nil
	}
	// The pixels the glyph's box touches (y down).
	x0, y0, x1, y1: i32
	if bx0, by0, bx1, by1, ok := glyph_box_at_instance(f, g); ok {
		x0, y0 = i32(math.floor(f32(bx0) * scale)), i32(math.floor(f32(-by1) * scale))
		x1, y1 = i32(math.ceil(f32(bx1) * scale)), i32(math.ceil(f32(-by0) * scale))
	}
	w, h := u32(max(x1 - x0, 0)), u32(max(y1 - y0, 0))
	if w == 0 || h == 0 {
		a.cache[key] = {}
		return {}, nil
	}
	// One pixel of padding, never written, keeps bilinear sampling from
	// bleeding neighbours.
	ax, ay, ok := atlas_add_rect(&a.packer, w + 1, h + 1)
	if !ok {
		return {}, .Atlas_Full
	}
	if s := font_glyph_shape(f, g); s != nil {
		// Each pixel's exact coverage: its box in the shape's units.
		unit := 1 / (scale * s.extent)
		for j in 0 ..< h {
			row := a.pixels[(ay + j) * a.width + ax:][:w]
			py := (f32(y0) + f32(j) + 0.5) / scale
			for &px, i in row {
				q := (Vec2{(f32(x0) + f32(i) + 0.5) / scale, py} - s.origin) / s.extent
				px = u8(cv.coverage(s.data, q, {unit, unit}, false) * 255 + 0.5)
			}
		}
	}
	if a.dirty_y0 == a.dirty_y1 {
		a.dirty_y0, a.dirty_y1 = ay, ay + h
	} else {
		a.dirty_y0, a.dirty_y1 = min(a.dirty_y0, ay), max(a.dirty_y1, ay + h)
	}
	cached = Cached_Glyph{ax, ay, w, h, x0, y0, true}
	a.cache[key] = cached
	return cached, nil
}

// The rows of `pixels` changed since the last take, [y0, y1), and marks them
// clean: upload `pixels[y0 * width:y1 * width]` at (0, y0). `ok` is false
// when nothing changed.
glyph_atlas_take_dirty :: proc "contextless" (a: ^Glyph_Atlas) -> (y0, y1: u32, ok: bool) {
	y0, y1 = a.dirty_y0, a.dirty_y1
	a.dirty_y0, a.dirty_y1 = 0, 0
	return y0, y1, y0 < y1
}

// Copies the changed rows into the atlas's canvas image.
glyph_atlas_upload :: proc(a: ^Glyph_Atlas, c: ^Canvas) -> Error {
	y0, y1, dirty := glyph_atlas_take_dirty(a)
	if !dirty {
		return nil
	}
	return update_image(c, a.image_id, image_source_gray(a.pixels[y0 * a.width:y1 * a.width], a.width, y1 - y0), 0, y0)
}

// ---- drawing ------------------------------------------------------------------------

// Draws glyph bitmaps from `atlas` as textured quads tinted by the paint's
// color; the atlas must have been made with `c`. The current transform moves
// the quads but the bitmaps are baked at `pixel_scale`, so prefer
// `fill_glyph_outlines` for scaled or animated text.
fill_glyph_run :: proc(c: ^Canvas, f: ^Font, atlas: ^Glyph_Atlas, glyphs: []Positioned_Glyph, pixel_scale: f32, paint: Paint) -> Error {
	if !image_id_valid(atlas.image_id) {
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
		cg, err := glyph_atlas_get(atlas, f, g.glyph, pixel_scale)
		if err != nil {
			resize(&c.verts, start)
			glyph_atlas_upload(atlas, c)
			return err
		}
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
	glyph_atlas_upload(atlas, c) or_return
	if len(c.verts) == start {
		return nil
	}
	add_paint(c, params)
	cmd := Command {
		glyph_texture       = glyph_tex,
		composite_operation = st.composite_operation,
		scissor_rect        = current_scissor_rect(c),
	}
	attach_paint_image(c, &cmd, &flavor)
	push_draw(c, cmd, paint_row, start)
	return nil
}

// Fills the glyph outlines: exact under any transform and any paint.
// `scale` converts font units to pixels. Each glyph is the font's shape
// (font_glyph_shape) drawn by coverage, all sharing one paint row, so a
// run costs no outline work; a feathered or aliased paint fills the
// outlines as one path instead (`scratch`, reset here). Colour glyphs
// (COLR) draw their own colours, `paint` standing for the text colour.
fill_glyph_outlines :: proc(c: ^Canvas, f: ^Font, glyphs: []Positioned_Glyph, scale: f32, paint: Paint, scratch: ^Path) {
	if paint.feather == 0 && paint.anti_alias {
		nz := paint
		nz.fill_rule = .Non_Zero
		cmd, row := shape_paint(c, nz)
		// Translucent text fills as one, as one outline path did: glyphs
		// in white, tinted by the paint.
		group: u32
		if !paint_opaque(c, paint) {
			group = row + 1
			row = solid_paint(c, {1, 1, 1, 1})
		}
		if f.colr != nil {
			sync.mutex_lock(&f.colr.lock)
		}
		for g in glyphs {
			if f.colr != nil && colr_draw_glyph(c, f, g, scale, paint) {
				continue
			}
			if s := font_glyph_shape(f, g.glyph); s != nil {
				push_shape_at(c, cmd, s, {scale, 0, 0, scale, g.x, g.y}, row, false, group)
			}
		}
		if f.colr != nil {
			sync.mutex_unlock(&f.colr.lock)
		}
		return
	}
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

// The glyph's bounding box in font units (y up) at the font's instance.
// False for empty glyphs.
font_glyph_box :: proc(f: ^Font, g: Glyph_Index, x0, y0, x1, y1: ^i32) -> bool {
	bx0, by0, bx1, by1, ok := glyph_box_at_instance(f, g)
	x0^, y0^, x1^, y1^ = i32(bx0), i32(by0), i32(bx1), i32(by1)
	return ok
}

// The glyph's box (font units, y up): the face's stored box at the default
// instance; at another, its varied outline's points' box (rounded out),
// read with the font's outline scratch.
@(private)
glyph_box_at_instance :: proc(f: ^Font, g: Glyph_Index) -> (x0, y0, x1, y1: int, ok: bool) {
	if f.instance == 0 {
		return ft.glyph_box(&f.face, ft.Glyph(g))
	}
	fs := font_shapes(f)
	sync.mutex_lock(&fs.lock)
	defer sync.mutex_unlock(&fs.lock)
	if !ft.glyph_outline(&f.face, ft.Glyph(g), &fs.outline) || len(fs.outline.points) == 0 {
		return
	}
	lo, hi := fs.outline.points[0], fs.outline.points[0]
	for p in fs.outline.points {
		lo, hi = {min(lo.x, p.x), min(lo.y, p.y)}, {max(hi.x, p.x), max(hi.y, p.y)}
	}
	return int(math.floor(lo.x)), int(math.floor(lo.y)), int(math.ceil(hi.x)), int(math.ceil(hi.y)), true
}
