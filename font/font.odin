// Reads TrueType and OpenType fonts: a face's tables, the character to
// glyph map, metrics, kerning and glyph outlines. Core only: ovg's text
// (text.odin) uses it, and so can anything else that draws glyphs.
//
// `load` reads a face once: where each table it uses lies and the header
// facts (units per em, the metrics counts, the cmap subtable, CFF's
// indexes), so a lookup reads the font's own bytes with no further setup.
// Every read is bounds-checked: past the end of the data it gives 0, so a
// corrupt or truncated font gives wrong glyphs, never a read out of
// bounds, and `load` rejects a face whose required tables are missing.
//
// Outlines (`glyph_outline`) are TrueType's quadratic contours (glyf, with
// composite glyphs) or CFF's Type 2 charstrings (cubic), in font units, y
// up.
package font

import "core:slice"

Error :: enum u8 {
	None,
	// Neither a font nor a collection.
	Not_A_Font,
	// The collection has no face at that index.
	No_Face,
	// cmap, head, hhea or hmtx is missing, or both glyf (with loca) and CFF.
	Missing_Table,
	// No cmap subtable maps Unicode, or a table's header is cut short.
	Bad_Table,
	// CFF other than version 1 with Type 2 charstrings.
	Unsupported,
}

// The tables ovg reads.
Table :: enum u8 {
	cmap,
	head,
	hhea,
	hmtx,
	maxp,
	loca,
	glyf,
	CFF,
	kern,
	GPOS,
	GSUB,
	COLR,
	CPAL,
	sbix,
	CBDT,
	name,
	OS2,
}

@(private)
TAGS := [Table]string {
	.cmap = "cmap",
	.head = "head",
	.hhea = "hhea",
	.hmtx = "hmtx",
	.maxp = "maxp",
	.loca = "loca",
	.glyf = "glyf",
	.CFF  = "CFF ",
	.kern = "kern",
	.GPOS = "GPOS",
	.GSUB = "GSUB",
	.COLR = "COLR",
	.CPAL = "CPAL",
	.sbix = "sbix",
	.CBDT = "CBDT",
	.name = "name",
	.OS2  = "OS/2",
}

// The cmap subtables (platform, encoding) that map Unicode, most preferred
// first: the full repertoire (Windows, then Unicode's), then the BMP.
// Unicode's encoding 5 (variation sequences) maps no characters alone.
@(private, rodata)
CMAP_PREFERENCE := [?][2]u16{{3, 10}, {0, 6}, {0, 4}, {3, 1}, {0, 3}, {0, 2}, {0, 1}, {0, 0}}

// Where a table lies in the data (`at` is 0 when the face has none).
Span :: struct {
	at, size: int,
}

Glyph :: u16

Face :: struct {
	// The font's bytes (borrowed; must outlive the face).
	data:                      []u8,
	// The face's table directory (non-zero in a collection).
	start:                     int,
	tables:                    [Table]Span,
	glyph_count:               int,
	units_per_em:              int,
	// hhea's.
	ascent, descent, line_gap: int,
	// hmtx: advance and left side bearing pairs, then the side bearings of
	// the glyphs past them (which take the last pair's advance).
	metrics:                   []Long_Metric,
	bearings:                  []I16,
	// Each glyph's glyf offset (and one past the last): 16-bit and halved,
	// or 32-bit; neither for an unknown format.
	loca_short:                []U16,
	loca_long:                 []U32,
	cmap:                      Cmap,
	cff:                       Cff,
}

// The cmap subtable used: its format's arrays, slices of the data.
Cmap :: struct {
	format:    u16,
	// Where the subtable starts.
	at:        int,
	// Format 0: a glyph per code point below len.
	bytes:     []u8,
	// Format 4: segments, each a code point range (starts[i] ..= ends[i])
	// mapped by adding deltas[i], or by a glyph array ranges[i] bytes past
	// the entry's own place at ranges_at + 2 i.
	ends:      []U16,
	starts:    []U16,
	deltas:    []I16,
	ranges:    []U16,
	ranges_at: int,
	// Format 6: glyphs for first ..< first + len.
	first:     int,
	glyphs:    []U16,
	// Formats 12 and 13: code point ranges and their (first) glyph.
	groups:    []Group,
}

// OpenType's records as stored: big-endian and unaligned, so #packed.
U16 :: struct #packed {
	v: u16be,
}

I16 :: struct #packed {
	v: i16be,
}

U32 :: struct #packed {
	v: u32be,
}

Long_Metric :: struct #packed {
	advance: u16be,
	lsb:     i16be,
}

Group :: struct #packed {
	first, last, glyph: u32be,
}

// A coverage range (first, last, the first's coverage index) or a class
// range (first, last, class).
@(private)
Range :: struct #packed {
	first, last, value: u16be,
}

// A pair set's record when the values are an x advance on the first glyph.
@(private)
Pair :: struct #packed {
	second:    u16be,
	x_advance: i16be,
}

// A legacy kern pair: the glyphs (left << 16 | right) and the value.
@(private)
Kern_Pair :: struct #packed {
	pair:  u32be,
	value: i16be,
}

// ---- reading ----------------------------------------------------------------------

// Big-endian reads, 0 past either end of the data.
read_u8 :: #force_inline proc "contextless" (d: []u8, at: int) -> u8 {
	if at < 0 || at >= len(d) {
		return 0
	}
	#no_bounds_check return d[at]
}

read_u16 :: #force_inline proc "contextless" (d: []u8, at: int) -> u16 {
	if at < 0 || at + 2 > len(d) {
		return 0
	}
	#no_bounds_check return u16(d[at]) << 8 | u16(d[at + 1])
}

read_i16 :: #force_inline proc "contextless" (d: []u8, at: int) -> i16 {
	return i16(read_u16(d, at))
}

read_u24 :: #force_inline proc "contextless" (d: []u8, at: int) -> u32 {
	if at < 0 || at + 3 > len(d) {
		return 0
	}
	#no_bounds_check return u32(d[at]) << 16 | u32(d[at + 1]) << 8 | u32(d[at + 2])
}

read_u32 :: #force_inline proc "contextless" (d: []u8, at: int) -> u32 {
	return u32(read_u16(d, at)) << 16 | u32(read_u16(d, at + 2))
}

// `count` records of type T at `at`; nil unless they all lie in the data.
@(private)
records :: proc "contextless" (d: []u8, at, count: int, $T: typeid) -> []T {
	if at < 0 || count < 0 || at + count * size_of(T) > len(d) {
		return nil
	}
	#no_bounds_check return ([^]T)(raw_data(d[at:]))[:count]
}

// `count` records at `at`, or as many as lie in the data.
@(private)
records_clamped :: proc "contextless" (d: []u8, at, count: int, $T: typeid) -> []T {
	if at < 0 || at > len(d) {
		return nil
	}
	return records(d, at, min(count, (len(d) - at) / size_of(T)), T)
}

@(private)
tag_is :: proc "contextless" (d: []u8, at: int, tag: string) -> bool {
	return at >= 0 && at + 4 <= len(d) && string(d[at:at + 4]) == tag
}

// ---- faces ------------------------------------------------------------------------

// Where face `index` starts: 0 for a font file's only face, or the
// collection's (ttcf) offset for it.
face_offset :: proc(data: []u8, index: int) -> (start: int, err: Error) {
	if tag_is(data, 0, "\x00\x01\x00\x00") || tag_is(data, 0, "OTTO") || tag_is(data, 0, "true") || tag_is(data, 0, "1\x00\x00\x00") || tag_is(data, 0, "typ1") {
		return 0, nil if index == 0 else .No_Face
	}
	if !tag_is(data, 0, "ttcf") {
		return 0, .Not_A_Font
	}
	if v := read_u32(data, 4); v != 0x10000 && v != 0x20000 {
		return 0, .Not_A_Font
	}
	if index < 0 || index >= int(read_u32(data, 8)) {
		return 0, .No_Face
	}
	return int(read_u32(data, 12 + index * 4)), nil
}

// Faces in the file: 1 for a font, the count for a collection, 0 for
// neither.
face_count :: proc(data: []u8) -> int {
	if _, err := face_offset(data, 0); err == .Not_A_Font {
		return 0
	}
	if tag_is(data, 0, "ttcf") {
		return int(read_u32(data, 8))
	}
	return 1
}

// Reads face `index` of a font or collection.
load :: proc(data: []u8, index := 0) -> (f: Face, err: Error) {
	f.data = data
	f.start = face_offset(data, index) or_return
	for i in 0 ..< int(read_u16(data, f.start + 4)) {
		rec := f.start + 12 + i * 16
		at, size := int(read_u32(data, rec + 8)), int(read_u32(data, rec + 12))
		if at == 0 || at >= len(data) {
			continue
		}
		for tag, t in TAGS {
			if f.tables[t].at == 0 && tag_is(data, rec, tag) {
				f.tables[t] = {at, min(size, len(data) - at)}
			}
		}
	}
	t := &f.tables
	if t[.cmap].at == 0 || t[.head].at == 0 || t[.hhea].at == 0 || t[.hmtx].at == 0 {
		return {}, .Missing_Table
	}
	if t[.head].size < 54 || t[.hhea].size < 36 {
		return {}, .Bad_Table
	}
	if t[.glyf].at != 0 {
		if t[.loca].at == 0 {
			return {}, .Missing_Table
		}
	} else if t[.CFF].at == 0 {
		return {}, .Missing_Table
	} else {
		cff_load(&f) or_return
	}
	f.glyph_count = int(read_u16(data, t[.maxp].at + 4)) if t[.maxp].at != 0 else 0xffff
	head, hhea := t[.head].at, t[.hhea].at
	f.units_per_em = int(read_u16(data, head + 18))
	f.ascent = int(read_i16(data, hhea + 4))
	f.descent = int(read_i16(data, hhea + 6))
	f.line_gap = int(read_i16(data, hhea + 8))
	hmtx := t[.hmtx]
	hmtx_data := data[hmtx.at:][:hmtx.size]
	long := int(read_u16(data, hhea + 34))
	f.metrics = records_clamped(hmtx_data, 0, long, Long_Metric)
	f.bearings = records_clamped(hmtx_data, 4 * long, f.glyph_count - long, I16)
	if loca := t[.loca]; loca.at != 0 {
		switch read_u16(data, head + 50) {
		case 0:
			f.loca_short = records_clamped(data[loca.at:][:loca.size], 0, f.glyph_count + 1, U16)
		case 1:
			f.loca_long = records_clamped(data[loca.at:][:loca.size], 0, f.glyph_count + 1, U32)
		}
	}
	// The most preferred Unicode subtable the face has.
	cmap := t[.cmap].at
	m, best := 0, len(CMAP_PREFERENCE)
	for i in 0 ..< int(read_u16(data, cmap + 2)) {
		rec := cmap + 4 + 8 * i
		if k, found := slice.linear_search(CMAP_PREFERENCE[:], [2]u16{read_u16(data, rec), read_u16(data, rec + 2)}); found && k < best {
			m, best = cmap + int(read_u32(data, rec + 4)), k
		}
	}
	if m == 0 {
		return {}, .Bad_Table
	}
	c := &f.cmap
	c.at = m
	c.format = read_u16(data, m)
	switch c.format {
	case 0:
		c.bytes = records_clamped(data, m + 6, int(read_u16(data, m + 2)) - 6, u8)
	case 4:
		segs := int(read_u16(data, m + 6)) / 2
		c.ends = records(data, m + 14, segs, U16)
		c.starts = records(data, m + 16 + 2 * segs, segs, U16)
		c.deltas = records(data, m + 16 + 4 * segs, segs, I16)
		c.ranges_at = m + 16 + 6 * segs
		c.ranges = records(data, c.ranges_at, segs, U16)
		if c.ranges == nil && segs > 0 {
			return {}, .Bad_Table
		}
	case 6:
		c.first = int(read_u16(data, m + 6))
		c.glyphs = records(data, m + 10, int(read_u16(data, m + 8)), U16)
	case 12, 13:
		c.groups = records(data, m + 16, int(read_u32(data, m + 12)), Group)
	}
	return f, nil
}

// ---- characters and metrics -----------------------------------------------------------

// The glyph for code point `r`; 0 (the missing glyph) when the face has
// none.
glyph_index :: proc(f: ^Face, r: rune) -> Glyph {
	c := &f.cmap
	cp := int(r)
	switch c.format {
	case 0:
		if cp < len(c.bytes) {
			return Glyph(c.bytes[cp])
		}
	case 4:
		// The first segment ending at or after cp.
		i, _ := slice.binary_search_by(c.ends, cp, proc(e: U16, cp: int) -> slice.Ordering {
			return slice.cmp(int(e.v), cp)
		})
		if i == len(c.ends) || cp < int(c.starts[i].v) {
			return 0
		}
		if c.ranges[i].v == 0 {
			return Glyph(cp + int(c.deltas[i].v))
		}
		g := read_u16(f.data, c.ranges_at + 2 * i + int(c.ranges[i].v) + 2 * (cp - int(c.starts[i].v)))
		return Glyph(int(g) + int(c.deltas[i].v)) if g != 0 else 0
	case 6:
		if cp >= c.first && cp - c.first < len(c.glyphs) {
			return Glyph(c.glyphs[cp - c.first].v)
		}
	case 12, 13:
		i, found := slice.binary_search_by(c.groups, u32(cp), proc(g: Group, cp: u32) -> slice.Ordering {
			return .Less if u32(g.last) < cp else (.Greater if u32(g.first) > cp else .Equal)
		})
		if found {
			g := c.groups[i]
			return Glyph(g.glyph) if c.format == 13 else Glyph(u32(g.glyph) + u32(cp) - u32(g.first))
		}
	}
	return 0
}

// The glyph's advance width and left side bearing (font units).
h_metrics :: proc(f: ^Face, g: Glyph) -> (advance, left_side_bearing: int) {
	i := int(g)
	if i < len(f.metrics) {
		m := f.metrics[i]
		return int(m.advance), int(m.lsb)
	}
	if len(f.metrics) > 0 {
		advance = int(f.metrics[len(f.metrics) - 1].advance)
	}
	if j := i - len(f.metrics); j < len(f.bearings) {
		left_side_bearing = int(f.bearings[j].v)
	}
	return
}

// Scale from font units to pixels so ascent - descent is `height`.
scale_for_pixel_height :: proc(f: ^Face, height: f32) -> f32 {
	return height / f32(f.ascent - f.descent)
}

// Scale from font units to pixels for an em of `size` pixels.
scale_for_em :: proc(f: ^Face, size: f32) -> f32 {
	return size / f32(f.units_per_em)
}

// ---- kerning ----------------------------------------------------------------------

// The advance adjustment between `a` and `b` (font units): GPOS pair
// adjustments of the x advance when the face has GPOS, else the first
// subtable of the legacy kern table.
kern :: proc(f: ^Face, a, b: Glyph) -> int {
	if f.tables[.GPOS].at != 0 {
		return gpos_kern(f, a, b)
	}
	if f.tables[.kern].at != 0 {
		return kern_table(f, a, b)
	}
	return 0
}

@(private)
kern_table :: proc(f: ^Face, a, b: Glyph) -> int {
	d, k := f.data, f.tables[.kern].at
	// One table at least, and the first horizontal format 0.
	if read_u16(d, k + 2) < 1 || read_u16(d, k + 8) != 1 {
		return 0
	}
	pairs := records(d, k + 18, int(read_u16(d, k + 10)), Kern_Pair)
	i, found := slice.binary_search_by(pairs, u32(a) << 16 | u32(b), proc(p: Kern_Pair, key: u32) -> slice.Ordering {
		return slice.cmp(u32(p.pair), key)
	})
	return int(pairs[i].value) if found else 0
}

// Pair adjustment lookups (type 2) whose values are an x advance on the
// first glyph only (value formats 4 and 0); the first subtable covering `a`
// decides.
@(private)
gpos_kern :: proc(f: ^Face, a, b: Glyph) -> int {
	d, gpos := f.data, f.tables[.GPOS].at
	if read_u16(d, gpos) != 1 || read_u16(d, gpos + 2) != 0 {
		return 0
	}
	list := gpos + int(read_u16(d, gpos + 8))
	for at in records(d, list + 2, int(read_u16(d, list)), U16) {
		// A lookup: its type, flags, then its subtables' offsets.
		lookup := list + int(at.v)
		head := records(d, lookup, 3, U16)
		if head == nil || head[0].v != 2 {
			continue
		}
		for sub in records(d, lookup + 6, int(head[2].v), U16) {
			t := lookup + int(sub.v)
			covered := coverage_index(d, t + int(read_u16(d, t + 2)), a)
			if covered < 0 {
				continue
			}
			if read_u16(d, t + 4) != 4 || read_u16(d, t + 6) != 0 {
				return 0
			}
			switch read_u16(d, t) {
			case 1:
				if covered >= int(read_u16(d, t + 8)) {
					return 0
				}
				// The pair set: second glyphs and their x advances.
				set := t + int(read_u16(d, t + 10 + 2 * covered))
				pairs := records(d, set + 2, int(read_u16(d, set)), Pair)
				k, found := slice.binary_search_by(pairs, b, proc(p: Pair, b: Glyph) -> slice.Ordering {
					return slice.cmp(u16(p.second), b)
				})
				if found {
					return int(pairs[k].x_advance)
				}
			case 2:
				c1 := class_of(d, t + int(read_u16(d, t + 8)), a)
				c2 := class_of(d, t + int(read_u16(d, t + 10)), b)
				n1, n2 := int(read_u16(d, t + 12)), int(read_u16(d, t + 14))
				if c1 < 0 || c1 >= n1 || c2 < 0 || c2 >= n2 {
					return 0
				}
				return int(read_i16(d, t + 16 + 2 * (c1 * n2 + c2)))
			case:
				return 0
			}
		}
	}
	return 0
}

// The glyph's index in an OpenType coverage table; -1 when not covered.
@(private)
coverage_index :: proc(d: []u8, t: int, g: Glyph) -> int {
	count := int(read_u16(d, t + 2))
	switch read_u16(d, t) {
	case 1:
		glyphs := records(d, t + 4, count, U16)
		i, found := slice.binary_search_by(glyphs, g, proc(id: U16, g: Glyph) -> slice.Ordering {
			return slice.cmp(u16(id.v), g)
		})
		if found {
			return i
		}
	case 2:
		ranges := records(d, t + 4, count, Range)
		if i, found := slice.binary_search_by(ranges, g, in_range); found {
			return int(ranges[i].value) + int(g) - int(ranges[i].first)
		}
	}
	return -1
}

// The glyph's class in an OpenType class definition table: 0 when listed
// nowhere, -1 for an unknown format.
@(private)
class_of :: proc(d: []u8, t: int, g: Glyph) -> int {
	switch read_u16(d, t) {
	case 1:
		first := read_u16(d, t + 2)
		classes := records(d, t + 6, int(read_u16(d, t + 4)), U16)
		if g >= first && int(g - first) < len(classes) {
			return int(classes[g - first].v)
		}
	case 2:
		ranges := records(d, t + 4, int(read_u16(d, t + 2)), Range)
		if i, found := slice.binary_search_by(ranges, g, in_range); found {
			return int(ranges[i].value)
		}
	case:
		return -1
	}
	return 0
}

// Orders a range against a glyph: Equal when it holds the glyph.
@(private)
in_range :: proc(r: Range, g: Glyph) -> slice.Ordering {
	return .Less if u16(r.last) < g else (.Greater if u16(r.first) > g else .Equal)
}
