package ovg

import "core:mem"
import "core:slice"
import "core:strings"
import "core:sync"

import ft "font"

// A set of font faces found by family, weight and style (CSS font
// matching), with per-glyph fallback through every face. Face data is
// borrowed and must outlive the collection.

Font_Face :: struct {
	family: string, // owned
	weight: int,
	italic: bool,
	font:   Font,
}

Font_Collection :: struct {
	// Its allocator is the collection's: faces, their family names and their
	// fonts' shapes (collection_allocator).
	faces:    [dynamic]Font_Face,
	// Used when nothing matches, and as the last fallback for glyphs.
	fallback:   Font_Face,
	// Colour emoji face tried after `faces` (font_collection_set_emoji);
	// never matched by family. `emoji.font.data == nil` when unset.
	emoji:      Font_Face,
	// The family text that names none is drawn in (borrowed); empty, or
	// a family no face has: every face competes by weight and style.
	default_family: string,
	// Guards the shaping state below and each face's layout tables
	// (prepared on first use), so layouts may run concurrently on one
	// collection.
	shape_lock: sync.Mutex,
	// Idle shapers (text_shape.odin), one per concurrent layout.
	shapers:    [dynamic]^Text_Shaper,
}

font_collection_init :: proc(c: ^Font_Collection, fallback_data: []u8 = nil, allocator := context.allocator) {
	c.faces = make([dynamic]Font_Face, allocator)
	data := fallback_data if fallback_data != nil else DEFAULT_FONT_DATA
	font, _ := font_load(data, 0, allocator)
	family, weight, italic := font_identity(data, &font, allocator)
	c.fallback = {family, weight, italic, font}
}

font_collection_destroy :: proc(c: ^Font_Collection) {
	allocator := collection_allocator(c)
	for s in c.shapers {
		shaper_destroy(s)
	}
	delete(c.shapers)
	for &f in c.faces {
		delete(f.family, allocator)
		font_destroy(&f.font)
	}
	delete(c.faces)
	delete(c.fallback.family, allocator)
	font_destroy(&c.fallback.font)
	delete(c.emoji.family, allocator)
	font_destroy(&c.emoji.font)
	c^ = {}
}

// The bundled default face (Bitstream Vera Sans).
DEFAULT_FONT_DATA :: #load("assets/Vera.ttf")

// Noto Color Emoji, COLRv1 build (vector, SIL OFL 1.1; ~5 MB). Linked only
// into programs that use it: `font_collection_set_emoji(&fonts, EMOJI_FONT_DATA)`.
EMOJI_FONT_DATA :: #load("assets/Noto-COLRv1.ttf")

// Sets the colour emoji face, tried for glyphs no face has and preferred for
// emoji presentation sequences (U+FE0F). The data is borrowed. Not while
// layouts run on the collection.
font_collection_set_emoji :: proc(c: ^Font_Collection, data: []u8) -> bool {
	allocator := collection_allocator(c)
	font, err := font_load(data, 0, allocator)
	if err != nil {
		return false
	}
	drop_shapers(c)
	delete(c.emoji.family, allocator)
	font_destroy(&c.emoji.font)
	family, weight, italic := font_identity(data, &font, allocator)
	c.emoji = {family, weight, italic, font}
	return true
}

// Adds every face of a TTF/OTF/TTC, in order before face `before` (at the
// end when past the last). Family, weight and style come from the font's
// tables. Returns the number of faces added. Not while layouts run on the
// collection (faces move).
font_collection_add :: proc(c: ^Font_Collection, data: []u8, before := max(int)) -> int {
	allocator := collection_allocator(c)
	// A collection never initialized takes its allocator here, not from
	// the first append.
	c.faces.allocator = allocator
	added := 0
	for index in 0 ..< 64 {
		font, err := font_load(data, i32(index), allocator)
		if err != nil {
			break
		}
		family, weight, italic := font_identity(data, &font, allocator)
		append(&c.faces, Font_Face{family, weight, italic, font})
		added += 1
	}
	if at := len(c.faces) - added; before < at {
		slice.rotate_right(c.faces[max(before, 0):], added)
	}
	return added
}

// Removes and frees face `i`; a `default_family` that is its name becomes
// empty. Not while layouts run on the collection.
font_collection_remove :: proc(c: ^Font_Collection, i: int) {
	drop_shapers(c)
	face := &c.faces[i]
	if raw_data(c.default_family) == raw_data(face.family) {
		c.default_family = ""
	}
	delete(face.family, collection_allocator(c))
	font_destroy(&face.font)
	ordered_remove(&c.faces, i)
}

// Pooled shapers hold plans made for faces (keyed by the font's address,
// which a new face may reuse): a face going takes them with it.
@(private = "file")
drop_shapers :: proc(c: ^Font_Collection) {
	sync.mutex_lock(&c.shape_lock)
	for s in c.shapers {
		shaper_destroy(s)
	}
	clear(&c.shapers)
	sync.mutex_unlock(&c.shape_lock)
}

// The best face for `family` (case-insensitive): matching style first, then
// the nearest weight (0 means 400). An empty family is `default_family`
// when the collection has it, else every face competes (earlier faces win
// ties). `found = false` returns the fallback face.
font_collection_find :: proc(c: ^Font_Collection, family: string, weight: int, italic := false) -> (font: ^Font, found: bool) {
	if family == "" && c.default_family != "" {
		if f, ok := font_collection_find(c, c.default_family, weight, italic); ok {
			return f, true
		}
	}
	want := weight if weight > 0 else 400
	best := -1
	best_score := max(int)
	for f, i in c.faces {
		if family != "" && !strings.equal_fold(f.family, family) {
			continue
		}
		score := abs(f.weight - want) * 2 + (0 if f.italic == italic else 10000)
		if family == "" {
			// No family asked for: the first face of the right style.
			score += i
		}
		if score < best_score {
			best, best_score = i, score
		}
	}
	if best < 0 {
		return &c.fallback.font, family == ""
	}
	return &c.faces[best].font, true
}

// The first face (then the emoji face, then the fallback) with a glyph for
// `r`, trying `primary` first.
font_collection_glyph :: proc(c: ^Font_Collection, r: rune, primary: ^Font) -> (^Font, Glyph_Index) {
	if g := font_glyph_index_drawable(primary, r); g != 0 {
		return primary, g
	}
	for &f in c.faces {
		if &f.font != primary {
			if g := font_glyph_index_drawable(&f.font, r); g != 0 {
				return &f.font, g
			}
		}
	}
	if c.emoji.font.data != nil {
		if g := font_glyph_index(&c.emoji.font, r); g != 0 {
			return &c.emoji.font, g
		}
	}
	if g := font_glyph_index(&c.fallback.font, r); g != 0 {
		return &c.fallback.font, g
	}
	return primary, 0
}

// The first colour (COLR) face with a glyph for `r`: added faces, then the
// emoji face.
font_collection_emoji_glyph :: proc(c: ^Font_Collection, r: rune) -> (^Font, Glyph_Index) {
	for &f in c.faces {
		if f.font.colr != nil {
			if g := font_glyph_index(&f.font, r); g != 0 {
				return &f.font, g
			}
		}
	}
	if c.emoji.font.colr != nil {
		if g := font_glyph_index(&c.emoji.font, r); g != 0 {
			return &c.emoji.font, g
		}
	}
	return nil, 0
}

// ---- font tables --------------------------------------------------------------------

// Family name (typographic family, else family), OS/2 weight class and
// italic bit of the face `font` was loaded from.
font_identity :: proc(data: []u8, font: ^Font, allocator := context.allocator) -> (family: string, weight: int, italic: bool) {
	weight = 400
	if name := font.face.tables[.name].at; name != 0 {
		family = read_name(data, name, 16, allocator)
		if family == "" {
			family = read_name(data, name, 1, allocator)
		}
	}
	if os2 := font.face.tables[.OS2]; os2.size >= 64 {
		weight = int(ft.read_u16(data, os2.at + 4))
		italic = ft.read_u16(data, os2.at + 62) & 1 != 0
	}
	if family == "" {
		family = strings.clone("Unknown", allocator)
	}
	return
}

// A `name` table string, preferring Windows Unicode English, as UTF-8.
@(private)
read_name :: proc(d: []u8, table: int, name_id: u16, allocator: mem.Allocator) -> string {
	if table + 6 > len(d) {
		return ""
	}
	count := int(ft.read_u16(d, table + 2))
	strings_at := table + int(ft.read_u16(d, table + 4))
	mac := ""
	for i in 0 ..< count {
		rec := table + 6 + i * 12
		if rec + 12 > len(d) {
			break
		}
		platform, encoding, language := ft.read_u16(d, rec), ft.read_u16(d, rec + 2), ft.read_u16(d, rec + 4)
		if ft.read_u16(d, rec + 6) != name_id {
			continue
		}
		length := int(ft.read_u16(d, rec + 8))
		at := strings_at + int(ft.read_u16(d, rec + 10))
		if at + length > len(d) {
			continue
		}
		raw := d[at:at + length]
		if platform == 3 && (encoding == 1 || encoding == 10) && (language == 0x409 || language & 0xff == 0x09) {
			b := strings.builder_make(allocator)
			for j := 0; j + 1 < len(raw); j += 2 {
				r := rune(u16(raw[j]) << 8 | u16(raw[j + 1]))
				// A surrogate pair is one code point.
				if r >= 0xd800 && r < 0xdc00 && j + 3 < len(raw) {
					if lo := rune(u16(raw[j + 2]) << 8 | u16(raw[j + 3])); lo >= 0xdc00 && lo < 0xe000 {
						r = 0x10000 + (r - 0xd800) << 10 + (lo - 0xdc00)
						j += 2
					}
				}
				strings.write_rune(&b, r)
			}
			return strings.to_string(b)
		}
		if platform == 1 && mac == "" {
			mac = string(raw)
		}
	}
	return strings.clone(mac, allocator) if mac != "" else ""
}
