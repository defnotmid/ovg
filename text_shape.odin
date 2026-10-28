package ovg

import "base:runtime"
import "core:sync"

import fc "deps:oglyph/collection"
import ft "deps:oglyph/font"
import sh "deps:oglyph/shape"

// OpenType shaping for `text_layout` with ovg/shape: GSUB (ligatures,
// contextual forms, Arabic joining, Indic reordering) and GPOS (kerning,
// mark positioning) per segment of one font, size, script and direction.
//
// The shared, read-only state is the font files' (oglyph's Files): each
// file's layout tables (sh.Layout) and plans, made on first use. Mutable
// state (the glyph buffer, the per-codepoint and per-glyph tables of a
// layout) lives in a `Text_Shaper`; the collection pools them so
// concurrent layouts on one collection each take their own, and a warm
// shaper lays out without allocating.

// A run of codepoints in one face, size, script and direction, and the
// glyphs it shaped into (visual order, left to right).
@(private)
Shape_Segment :: struct {
	first, count:             i32, // codepoints
	glyph_first, glyph_count: i32,
	face:                     Face_Id,
	font:                     ^Font_Face, // the face's, for the layout's call
	em:                       f32,
	script:                   sh.Script,
	level:                    u8, // bidi embedding level: 0 LTR, 1 RTL, 2 numbers in RTL
}

// A codepoint of the text and what layout finds out about it; loops read
// a few columns each.
@(private)
Shape_Char :: struct {
	char:   rune,
	piece:  i32,
	face:   Face_Id, // after fallback
	script: sh.Script,
	level:  u8, // bidi level (oglyph's bidi_levels)
	bidi:   sh.Bidi_Class, // scratch
	// Wrapping (text_layout.odin): the break after it, and its share of
	// the line's width (its glyphs' advances).
	brk:     sh.Line_Break,
	advance: f32,
}

// A piece of the text: its first codepoint, size and feature settings
// (features[first:][:count]: letter spacing's, then Text_Style.features;
// the last of a tag wins).
@(private)
Shape_Piece :: struct {
	start:    i32,
	size:     f32,
	features: [2]i32,
}

// Shaping state for one layout at a time (pooled by Font_Collection).
Text_Shaper :: struct {
	shaper:         sh.Shaper,
	// The segment being shaped: its feature settings.
	seg_features:   [dynamic]sh.Feature,
	pieces:         [dynamic]Shape_Piece,
	features:       [dynamic]sh.Feature,
	chars:          #soa[dynamic]Shape_Char,
	// Segments of the current line, and their visual order.
	segs:           [dynamic]Shape_Segment,
	order:          [dynamic]i32,
	// Shaped glyphs of the current line, clusters indexing `chars`. The
	// layout reads every field per glyph, so these are rows.
	glyphs:         [dynamic]sh.Glyph,
}

@(private)
shaper_acquire :: proc(fonts: ^Font_Collection) -> ^Text_Shaper {
	sync.mutex_lock(&fonts.shape_lock)
	defer sync.mutex_unlock(&fonts.shape_lock)
	if n := len(fonts.shapers); n > 0 {
		s := fonts.shapers[n - 1]
		resize(&fonts.shapers, n - 1)
		return s
	}
	allocator := collection_allocator(fonts)
	s := new(Text_Shaper, allocator)
	sh.shaper_init(&s.shaper, allocator)
	s.seg_features.allocator = allocator
	s.pieces.allocator = allocator
	s.features.allocator = allocator
	s.chars = make(#soa[dynamic]Shape_Char, allocator)
	s.segs.allocator = allocator
	s.order.allocator = allocator
	s.glyphs.allocator = allocator
	return s
}

@(private)
shaper_release :: proc(fonts: ^Font_Collection, s: ^Text_Shaper) {
	sync.mutex_lock(&fonts.shape_lock)
	defer sync.mutex_unlock(&fonts.shape_lock)
	if fonts.shapers.allocator.procedure == nil {
		fonts.shapers.allocator = collection_allocator(fonts)
	}
	append(&fonts.shapers, s)
}

@(private)
shaper_destroy :: proc(s: ^Text_Shaper) {
	allocator := s.glyphs.allocator
	sh.shaper_destroy(&s.shaper)
	delete(s.seg_features)
	delete(s.pieces)
	delete(s.features)
	delete(s.chars)
	delete(s.segs)
	delete(s.order)
	delete(s.glyphs)
	free(s, allocator)
}

// Sizes scratch to `n` rows, which the caller fills: its length set,
// growing (geometrically) only when it is short. Rows it gains keep
// whatever they held.
@(private)
scratch_size :: proc {
	scratch_size_rows,
	scratch_size_soa,
}

@(private)
scratch_size_rows :: #force_inline proc(a: ^[dynamic]$T, n: int) {
	if n > cap(a) {
		reserve(a, max(n, 2 * cap(a)))
	}
	(^runtime.Raw_Dynamic_Array)(a).len = n
}

@(private)
scratch_size_soa :: #force_inline proc(a: ^#soa[dynamic]$T, n: int) {
	if n > cap(a) {
		reserve(a, max(n, 2 * cap(a)))
	}
	runtime.raw_soa_footer(a).len = n
}

@(private)
collection_allocator :: proc(fonts: ^Font_Collection) -> runtime.Allocator {
	if fonts.rows.allocator.procedure != nil {
		return fonts.rows.allocator
	}
	return runtime.heap_allocator()
}

// Script and bidi level of each codepoint of the line [a, b) (script runs,
// levels for a left-to-right paragraph: oglyph's bidi_levels).
@(private)
shaper_itemize :: proc(s: ^Text_Shaper, a, b: i32) {
	// Fast path: Latin with common punctuation, symbols and digits is one
	// left-to-right Latin run.
	latin := true
	for r in s.chars.char[a:b] {
		if r >= 0x370 && (r < 0x2000 || r > 0x20cf) {
			latin = false
			break
		}
	}
	if latin {
		for i in a ..< b {
			s.chars[i].script = .Latin
			s.chars[i].level = 0
		}
		return
	}
	sh.script_runs(s.chars.char[a:b], s.chars.script[a:b])
	for i in a ..< b {
		s.chars[i].bidi = sh.char_bidi_class(s.chars[i].char)
	}
	sh.bidi_levels(s.chars.bidi[a:b], s.chars.level[a:b])
}

// Shapes one segment, appending its glyphs to the shaper's line glyphs.
@(private)
shaper_shape :: proc(fonts: ^Font_Collection, s: ^Text_Shaper, seg: ^Shape_Segment) {
	first := len(s.glyphs)
	seg.glyph_first = i32(first)
	defer seg.glyph_count = i32(len(s.glyphs) - first)

	direction: sh.Direction = .RTL if seg.level & 1 == 1 else .LTR
	shaper_segment_features(s, seg)
	plan := fc.file_plan(fonts.files, seg.font, seg.script, direction, s.seg_features[:])
	sh.shape(&s.shaper, plan, &seg.font.face, s.chars.char[seg.first:seg.first + seg.count], s.seg_features[:], &s.glyphs)
	if !s.shaper.ok {
		// Past the shaper's limits: one glyph per codepoint.
		resize(&s.glyphs, first)
		for i in seg.first ..< seg.first + seg.count {
			g := ft.glyph_index(&seg.font.face, s.chars[i].char)
			append(&s.glyphs, sh.Glyph{id = g, cluster = i, advance = i32(ft.advance(&seg.font.face, g))})
		}
		return
	}
	for &g in s.glyphs[first:] {
		g.cluster += seg.first
	}
}

// The segment's feature settings (Text_Shaper.seg_features): its pieces',
// over all of it when they all have the same, else each over its piece.
@(private)
shaper_segment_features :: proc(s: ^Text_Shaper, seg: ^Shape_Segment) {
	clear(&s.seg_features)
	p0, p1 := s.chars[seg.first].piece, s.chars[seg.first + seg.count - 1].piece
	same := true
	for p in p0 + 1 ..= p1 {
		a, b := s.pieces[p0].features, s.pieces[p].features
		if a[1] != b[1] || !features_equal(s.features[a[0]:][:a[1]], s.features[b[0]:][:b[1]]) {
			same = false
			break
		}
	}
	for p in p0 ..= p1 {
		pf := s.pieces[p].features
		start, end := 0, 0
		if !same {
			start = int(max(s.pieces[p].start, seg.first) - seg.first)
			end = int(min(s.pieces[p + 1].start if int(p) + 1 < len(s.pieces) else max(i32), seg.first + seg.count) - seg.first)
		}
		for f in s.features[pf[0]:][:pf[1]] {
			append(&s.seg_features, sh.Feature{f.tag, f.value, start, end})
		}
		if same {
			break
		}
	}
}

@(private)
features_equal :: proc(a, b: []sh.Feature) -> bool {
	for f, i in a {
		if f.tag != b[i].tag || f.value != b[i].value {
			return false
		}
	}
	return true
}

// Adds a piece's feature settings, returning where they lie in
// `features`: liga, clig and dlig off when letter-spaced (CSS), then its
// style's (the last of a tag wins).
@(private)
shaper_add_piece_features :: proc(s: ^Text_Shaper, st: Text_Style) -> [2]i32 {
	first := i32(len(s.features))
	if st.letter_spacing != 0 {
		append(&s.features, sh.Feature{tag = sh.tag("liga")}, sh.Feature{tag = sh.tag("clig")}, sh.Feature{tag = sh.tag("dlig")})
	}
	for f in st.features {
		tag := [4]u8{' ', ' ', ' ', ' '}
		copy(tag[:], f.tag)
		append(&s.features, sh.Feature{tag = sh.tag(string(tag[:])), value = f.value})
	}
	return {first, i32(len(s.features)) - first}
}

// Visual order of the line's segments (UAX #9 rule L2 over their levels).
@(private)
shaper_reorder :: proc(s: ^Text_Shaper) {
	clear(&s.order)
	top: u8
	for seg, i in s.segs {
		append(&s.order, i32(i))
		top = max(top, seg.level)
	}
	for level := top; level >= 1; level -= 1 {
		i := 0
		for i < len(s.order) {
			if s.segs[s.order[i]].level < level {
				i += 1
				continue
			}
			j := i
			for j < len(s.order) && s.segs[s.order[j]].level >= level {
				j += 1
			}
			for x, y := i, j - 1; x < y; x, y = x + 1, y - 1 {
				s.order[x], s.order[y] = s.order[y], s.order[x]
			}
			i = j
		}
	}
}

