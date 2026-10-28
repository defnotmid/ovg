package ovg

import "core:sync"

import fc "deps:oglyph/collection"

// A set of font faces found by family, weight and style, with per-glyph
// fallback through every face: oglyph's collection (deps:oglyph/collection:
// the faces, their files' shaping tables and plans, family matching and
// fallback), with what drawing makes of each face and the layouts'
// scratch. Face data is borrowed and must outlive the collection.

// A face of a Font_Collection (oglyph's Face_Id). Its face and font never
// move: the pointers font_collection_face and font_collection_font give
// hold until the face is removed, while other threads add faces.
Face_Id :: fc.Face_Id

// A face as shaping and matching read it (oglyph's): its ft.Face at its
// instance, family, weight, style and file.
Font_Face :: fc.Face

// The font files collections share (font_collection_init's `files`), each
// face of one with its shaping tables and plans (oglyph's).
Font_Files :: fc.Files

font_files_init :: fc.files_init
font_files_destroy :: fc.files_destroy

Font_Collection :: struct {
	// The faces, their files, family index and fallback: `faces`,
	// `fallback`, `emoji` and `default_family` read through.
	using collection: fc.Collection,
	// Per face id (Face_Id.index), the face as drawing reads it: its glyphs'
	// shapes and its COLR paint, made with the face; a removed face's is
	// zero. Rows never move, as the faces' don't.
	fonts:            fc.Rows(Font),
	// Guards the shaper pool, so layouts may run concurrently on one
	// collection.
	shape_lock:       sync.Mutex,
	// Idle shapers (text_shape.odin), one per concurrent layout.
	shapers:          [dynamic]^Text_Shaper,
}

// A collection whose faces' files are `files` (shared with the other
// collections given it), else a table of its own. It falls back to
// `fallback_data`'s face (DEFAULT_FONT_DATA when nil), and counts a glyph
// a face has only as a bitmap as missing: ovg draws outlines.
font_collection_init :: proc(c: ^Font_Collection, fallback_data: []u8 = nil, allocator := context.allocator, files: ^Font_Files = nil) {
	data := fallback_data if fallback_data != nil else DEFAULT_FONT_DATA
	fc.collection_init(&c.collection, data, allocator, files, outlines_only = true)
	fc.rows_init(&c.fonts, allocator)
	collection_fonts(c)
}

font_collection_destroy :: proc(c: ^Font_Collection) {
	for s in c.shapers {
		shaper_destroy(s)
	}
	delete(c.shapers)
	for i in 0 ..< c.fonts.len {
		font_destroy(fc.rows_at(&c.fonts, i))
	}
	fc.rows_destroy(&c.fonts)
	fc.collection_destroy(&c.collection)
	c^ = {}
}

// The bundled default face (Bitstream Vera Sans).
DEFAULT_FONT_DATA :: #load("assets/Vera.ttf")

// Noto Color Emoji, COLRv1 build (vector, SIL OFL 1.1; ~5 MB). Linked only
// into programs that use it: `font_collection_set_emoji(&fonts, EMOJI_FONT_DATA)`.
EMOJI_FONT_DATA :: #load("assets/Noto-COLRv1.ttf")

// Sets the colour emoji face, tried for glyphs no face has and preferred for
// emoji presentation sequences (U+FE0F); a face it replaces is gone. The
// data is borrowed. Not while layouts run on the collection.
font_collection_set_emoji :: proc(c: ^Font_Collection, data: []u8) -> bool {
	old := c.emoji.id if c.emoji != nil else {}
	if _, ok := fc.collection_set_emoji(&c.collection, data); !ok {
		return false
	}
	if old != {} {
		font_destroy(fc.rows_at(&c.fonts, int(old.index)))
	}
	collection_fonts(c)
	return true
}

// Adds every face of a TTF/OTF/TTC, in order before face `before` (at the
// end when past the last), variable ones at the instance `variations` pick
// (font_load). Family, weight and style come from the font's tables, the
// weight from a wght setting and the style from ital or slnt when given.
// Faces of data added before (to this collection or one sharing its
// files) share its file's tables and plans: another instance costs about
// its glyphs. Returns the number of faces added. Other threads may draw
// with faces they hold the ids of meanwhile (no face or font moves:
// font_collection_face, font_collection_font, text_layout_font), but not
// lay text out on the collection.
font_collection_add :: proc(c: ^Font_Collection, data: []u8, before := max(int), variations: []Font_Variation = nil) -> int {
	added := fc.collection_add(&c.collection, data, before, variations)
	collection_fonts(c)
	return added
}

// Removes and frees face `i` (of `faces`), whose id names no face after
// it (its file stays in the collection's files). Not while layouts run on
// the collection.
font_collection_remove :: proc(c: ^Font_Collection, i: int) {
	id := c.faces[i].id
	fc.collection_remove(&c.collection, i)
	f := fc.rows_at(&c.fonts, int(id.index))
	font_destroy(f)
	f^ = {}
}

// Face `id`, where it stays until it is removed; nil once the face is
// removed (or, for an emoji face, replaced), for Face_Id{}, for an id of
// another collection and without a collection.
font_collection_face :: proc(c: ^Font_Collection, id: Face_Id) -> ^Font_Face {
	if c == nil {
		return nil
	}
	return fc.collection_face(&c.collection, id)
}

// The font of face `id`, to draw with, where it stays until the face is
// removed; nil where font_collection_face is.
font_collection_font :: proc(c: ^Font_Collection, id: Face_Id) -> ^Font {
	if font_collection_face(c, id) == nil {
		return nil
	}
	return fc.rows_at(&c.fonts, int(id.index))
}

// Family name (typographic family, else family), OS/2 weight class and
// italic bit of the face `font` was loaded from (oglyph's face_identity).
font_identity :: proc(font: ^Font, allocator := context.allocator) -> (family: string, weight: int, italic: bool) {
	return fc.face_identity(&font.face, allocator)
}

// The best face for `family` (case-insensitive): with `variations`, one
// whose instance they pick first; matching style next, then the nearest
// weight (0 means 400). An empty family is `default_family`
// when the collection has it, else every face competes (earlier faces win
// ties). `found = false` gives the fallback face, which is also found by
// its own family (so `default_family` may name it).
font_collection_find :: proc(c: ^Font_Collection, family: string, weight: int, italic := false, variations: []Font_Variation = nil) -> (face: Face_Id, found: bool) {
	return fc.collection_find(&c.collection, family, weight, italic, variations)
}

// The face with a glyph for `r`: `primary`, else the first of `faces`,
// then the emoji face, then the fallback; `primary` and 0 when none has
// one.
font_collection_glyph :: proc(c: ^Font_Collection, r: rune, primary: Face_Id) -> (Face_Id, Glyph_Index) {
	face, g := fc.collection_glyph(&c.collection, r, primary)
	return face, Glyph_Index(g)
}

// The first colour (COLR) face with a glyph for `r`: added faces, then the
// emoji face; Face_Id{} and 0 when none has one.
font_collection_emoji_glyph :: proc(c: ^Font_Collection, r: rune) -> (Face_Id, Glyph_Index) {
	face, g := fc.collection_emoji_glyph(&c.collection, r)
	return face, Glyph_Index(g)
}

// The drawing fonts of the face ids made since the last call.
@(private = "file")
collection_fonts :: proc(c: ^Font_Collection) {
	allocator := fc.collection_allocator(&c.collection)
	c.fonts.allocator = allocator
	for i := c.fonts.len; i < c.rows.len; i += 1 {
		f: Font
		if face := fc.collection_face(&c.collection, {c.serial, u32(i)}); face != nil {
			f = font_from_face(face, allocator)
		}
		fc.rows_append(&c.fonts, f)
	}
}
