package ovg

import "base:runtime"
import "core:hash"
import "core:math"
import "core:mem"
import "core:sync"

import ft "deps:oglyph/font"
import sh "deps:oglyph/shape"

// Fonts read by ovg/font (font/font.odin): metrics, kerning and glyph
// outlines; glyphs draw as shapes. Shaped layout is `text_layout` over a Font_Collection
// (text_shape.odin).

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
	// else a hash of the face's coordinates.
	instance:       u64,
}

// The next of the process's font collection serials, from 1.
@(private)
serial_next :: proc "contextless" () -> u32 {
	return sync.atomic_add(&serials, 1) + 1
}

@(private = "file")
serials: u32

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

// A glyph placed on the baseline at (x, y), in pixels.
Positioned_Glyph :: struct {
	glyph: Glyph_Index,
	x, y:  f32,
}

// ---- drawing ------------------------------------------------------------------------

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
