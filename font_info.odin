package ovg

import "core:slice"

import ft "font"

// What a font says about itself, for a font picker or a glyph browser.
// `font_info` reads it once (name, GSUB and GPOS are walked).
Font_Info :: struct {
	// The typographic family and subfamily (name IDs 16 and 17), else the
	// legacy ones (1 and 2): "Noto Sans" and "Condensed Bold".
	family, subfamily: string,
	full_name:         string,
	postscript_name:   string,
	glyph_count:       int,
	// The GSUB and GPOS feature tags present, sorted, each once (slices of
	// the font data): what Text_Style.features can set.
	features:          []string,
}

font_info :: proc(f: ^Font, allocator := context.allocator) -> (info: Font_Info) {
	d := f.data
	if name := f.face.tables[.name].at; name != 0 {
		either :: proc(d: []u8, name: int, id, fallback: u16, allocator := context.allocator) -> string {
			if s := read_name(d, name, id, allocator); s != "" {
				return s
			}
			return read_name(d, name, fallback, allocator)
		}
		info.family = either(d, name, 16, 1, allocator)
		info.subfamily = either(d, name, 17, 2, allocator)
		info.full_name = read_name(d, name, 4, allocator)
		info.postscript_name = read_name(d, name, 6, allocator)
	}
	info.glyph_count = f.face.glyph_count

	// FeatureList records: a tag and an offset each.
	lists: [2][2]int // first record, count
	n := 0
	for table, i in ([2]ft.Table{.GSUB, .GPOS}) {
		span := f.face.tables[table]
		if span.at == 0 {
			continue
		}
		list := span.at + int(ft.read_u16(d, span.at + 6))
		count := int(ft.read_u16(d, list))
		count = clamp((span.at + span.size - list - 2) / 6, 0, count)
		lists[i] = {list + 2, count}
		n += count
	}
	tags := make([]string, n, allocator)
	at := 0
	for l in lists {
		for r in 0 ..< l[1] {
			tags[at] = string(d[l[0] + 6 * r:][:4])
			at += 1
		}
	}
	slice.sort(tags)
	info.features = slice.unique(tags)
	if len(info.features) < n {
		info.features = slice.clone(info.features, allocator)
		delete(tags, allocator)
	}
	return info
}

font_info_destroy :: proc(info: ^Font_Info, allocator := context.allocator) {
	delete(info.family, allocator)
	delete(info.subfamily, allocator)
	delete(info.full_name, allocator)
	delete(info.postscript_name, allocator)
	delete(info.features, allocator)
	info^ = {}
}

// Each glyph's name (post's, or the CFF charset's; "" when the font names
// none, as CID-keyed CJK fonts), slices of the font data or static strings:
// for a glyph browser. Free the slice; the strings are borrowed.
font_glyph_names :: proc(f: ^Font, allocator := context.allocator) -> []string {
	names := make([]string, f.face.glyph_count, allocator)
	ft.glyph_names(&f.face, names)
	return names
}
