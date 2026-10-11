package ovg

import "core:strings"
import "core:sync"

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
	faces:    [dynamic]Font_Face,
	// Used when nothing matches, and as the last fallback for glyphs.
	fallback:   Font_Face,
	// Colour emoji face tried after `faces` (font_collection_set_emoji);
	// never matched by family. `emoji.font.data == nil` when unset.
	emoji:      Font_Face,
	// Guards the shaping state below and each face's lazily parsed kb font,
	// so layouts may run concurrently on one collection.
	shape_lock: sync.Mutex,
	// Idle shapers (text_shape.odin), one per concurrent layout.
	shapers:    [dynamic]^Text_Shaper,
}

font_collection_init :: proc(c: ^Font_Collection, fallback_data: []u8 = nil, allocator := context.allocator) {
	c.faces = make([dynamic]Font_Face, allocator)
	data := fallback_data if fallback_data != nil else DEFAULT_FONT_DATA
	font, _ := font_load(data)
	family, weight, italic := font_identity(data, &font)
	c.fallback = {family, weight, italic, font}
}

font_collection_destroy :: proc(c: ^Font_Collection) {
	for s in c.shapers {
		shaper_destroy(s)
	}
	delete(c.shapers)
	for &f in c.faces {
		delete(f.family)
		font_destroy(&f.font)
	}
	delete(c.faces)
	delete(c.fallback.family)
	font_destroy(&c.fallback.font)
	delete(c.emoji.family)
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
	font, err := font_load(data)
	if err != nil {
		return false
	}
	// Pooled shapers hold the old face's kb font (configs) and glyphs
	// shaped with it (cache, keyed by the data address, which new data may
	// reuse): they go with it.
	sync.mutex_lock(&c.shape_lock)
	for s in c.shapers {
		shaper_destroy(s)
	}
	clear(&c.shapers)
	sync.mutex_unlock(&c.shape_lock)
	delete(c.emoji.family)
	font_destroy(&c.emoji.font)
	family, weight, italic := font_identity(data, &font)
	c.emoji = {family, weight, italic, font}
	return true
}

// Adds every face of a TTF/OTF/TTC. Family, weight and style come from the
// font's tables. Returns the number of faces added.
font_collection_add :: proc(c: ^Font_Collection, data: []u8) -> int {
	added := 0
	for index in 0 ..< 64 {
		font, err := font_load(data, i32(index))
		if err != nil {
			break
		}
		family, weight, italic := font_identity(data, &font)
		append(&c.faces, Font_Face{family, weight, italic, font})
		added += 1
	}
	return added
}

// The best face for `family` (case-insensitive): matching style first, then
// the nearest weight (0 means 400). An empty family takes the first face.
// `found = false` returns the fallback face.
font_collection_find :: proc(c: ^Font_Collection, family: string, weight: int, italic := false) -> (font: ^Font, found: bool) {
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
font_identity :: proc(data: []u8, font: ^Font) -> (family: string, weight: int, italic: bool) {
	weight = 400
	base := int(font.info.fontstart)
	if name, ok := find_table(data, base, "name"); ok {
		family = read_name(data, name, 16)
		if family == "" {
			family = read_name(data, name, 1)
		}
	}
	if os2, ok := find_table(data, base, "OS/2"); ok && os2 + 64 <= len(data) {
		weight = int(be16(data, os2 + 4))
		italic = be16(data, os2 + 62) & 1 != 0
	}
	if family == "" {
		family = strings.clone("Unknown")
	}
	return
}

@(private)
be16 :: proc(d: []u8, at: int) -> u16 {
	return u16(d[at]) << 8 | u16(d[at + 1])
}

@(private)
be32 :: proc(d: []u8, at: int) -> u32 {
	return u32(be16(d, at)) << 16 | u32(be16(d, at + 2))
}

@(private)
find_table :: proc(d: []u8, base: int, tag: string) -> (int, bool) {
	off, _, ok := find_table_range(d, base, tag)
	return off, ok
}

// Offset and length of a table, clamped to the data.
@(private)
find_table_range :: proc(d: []u8, base: int, tag: string) -> (offset, length: int, ok: bool) {
	if base + 12 > len(d) {
		return
	}
	n := int(be16(d, base + 4))
	for i in 0 ..< n {
		rec := base + 12 + i * 16
		if rec + 16 > len(d) {
			break
		}
		if string(d[rec:rec + 4]) == tag {
			off := int(be32(d, rec + 8))
			if off >= len(d) {
				return
			}
			return off, min(int(be32(d, rec + 12)), len(d) - off), true
		}
	}
	return
}

// Whether the GSUB / GPOS tables of a face hold together: kb_text_shape
// trusts them, and lists pointing past a table's end (a header-only GSUB, as
// in some color-font subsets) make it read and write out of bounds.
font_layout_tables_ok :: proc(f: ^Font) -> bool {
	d := f.data
	for tag in ([2]string{"GSUB", "GPOS"}) {
		at, length, found := find_table_range(d, int(f.info.fontstart), tag)
		if !found {
			continue
		}
		t := d[at:][:length]
		if length < 10 {
			return false
		}
		// ScriptList and FeatureList: a count of 6-byte records past the
		// header (a null offset is read as the header itself).
		for field in ([2]int{4, 6}) {
			list := int(be16(t, field))
			if list < 10 || list + 2 > length || list + 2 + int(be16(t, list)) * 6 > length {
				return false
			}
		}
		// LookupList: offsets to lookups, each with its subtable offsets.
		list := int(be16(t, 8))
		if list < 10 || list + 2 > length {
			return false
		}
		count := int(be16(t, list))
		if list + 2 + count * 2 > length {
			return false
		}
		for i in 0 ..< count {
			lookup := list + int(be16(t, list + 2 + i * 2))
			if lookup + 6 > length || lookup + 6 + int(be16(t, lookup + 4)) * 2 > length {
				return false
			}
		}
	}
	return true
}

// A `name` table string, preferring Windows Unicode English, as UTF-8.
@(private = "file")
read_name :: proc(d: []u8, table: int, name_id: u16) -> string {
	if table + 6 > len(d) {
		return ""
	}
	count := int(be16(d, table + 2))
	strings_at := table + int(be16(d, table + 4))
	mac := ""
	for i in 0 ..< count {
		rec := table + 6 + i * 12
		if rec + 12 > len(d) {
			break
		}
		platform, encoding, language := be16(d, rec), be16(d, rec + 2), be16(d, rec + 4)
		if be16(d, rec + 6) != name_id {
			continue
		}
		length := int(be16(d, rec + 8))
		at := strings_at + int(be16(d, rec + 10))
		if at + length > len(d) {
			continue
		}
		raw := d[at:at + length]
		if platform == 3 && (encoding == 1 || encoding == 10) && (language == 0x409 || language & 0xff == 0x09) {
			b := strings.builder_make()
			for j := 0; j + 1 < len(raw); j += 2 {
				strings.write_rune(&b, rune(u16(raw[j]) << 8 | u16(raw[j + 1])))
			}
			return strings.to_string(b)
		}
		if platform == 1 && mac == "" {
			mac = string(raw)
		}
	}
	return strings.clone(mac) if mac != "" else ""
}
