package ovg

import "base:runtime"
import "core:sync"

import sh "deps:oglyph/shape"

// OpenType shaping for `text_layout` with ovg/shape: GSUB (ligatures,
// contextual forms, Arabic joining, Indic reordering) and GPOS (kerning,
// mark positioning) per segment of one font, size, script and direction.
//
// Font_Collection keeps the shared, read-only state: each face's layout
// tables prepared on first use (sh.Layout). Mutable state (the glyph
// buffer, plans, the per-codepoint and per-glyph tables of a layout)
// lives in a `Text_Shaper`; the collection pools them so concurrent
// layouts on one collection each take their own, and a warm shaper lays
// out without allocating.

// A plan of a shaper: for a face, script, direction and the feature
// settings of a segment (Text_Shaper.plan_features[first:][:count], their
// ranges dropped: a plan depends on tags, values and whether each is
// global).
@(private)
Shape_Plan :: struct {
	face:         Face_Id,
	script:       sh.Script,
	direction:    sh.Direction,
	first, count: i32,
	plan:         sh.Plan,
}

// A run of codepoints in one face, size, script and direction, and the
// glyphs it shaped into (visual order, left to right).
@(private)
Shape_Segment :: struct {
	first, count:             i32, // codepoints
	glyph_first, glyph_count: i32,
	face:                     Face_Id,
	font:                     ^Font, // the face's, for the layout's call
	em:                       f32,
	script:                   sh.Script,
	level:                    u8, // bidi embedding level: 0 LTR, 1 RTL, 2 numbers in RTL
}

// Shaping state for one layout at a time (pooled by Font_Collection).
Text_Shaper :: struct {
	shaper:         sh.Shaper,
	plans:          [dynamic]Shape_Plan,
	plan_features:  [dynamic]sh.Feature,
	// The segment being shaped: its feature settings.
	seg_features:   [dynamic]sh.Feature,
	// Per piece.
	piece_start:    [dynamic]i32, // first codepoint
	piece_size:     [dynamic]f32,
	// The piece's feature settings: features[first:][:count] (letter
	// spacing's, then Text_Style.features; the last of a tag wins).
	piece_features: [dynamic][2]i32,
	features:       [dynamic]sh.Feature,
	// Per codepoint of the text.
	runes:          [dynamic]rune,
	piece:          [dynamic]i32,
	face:           [dynamic]Face_Id, // after fallback
	script:         [dynamic]sh.Script,
	level:          [dynamic]u8, // bidi level (text_bidi.odin)
	bidi:           [dynamic]Bidi_Class, // scratch
	// Segments of the current line, and their visual order.
	segs:           [dynamic]Shape_Segment,
	order:          [dynamic]i32,
	// Shaped glyphs of the current line, clusters indexing `runes`. The
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
	s.plans.allocator = allocator
	s.plan_features.allocator = allocator
	s.seg_features.allocator = allocator
	s.piece_start.allocator = allocator
	s.piece_size.allocator = allocator
	s.piece_features.allocator = allocator
	s.features.allocator = allocator
	s.runes.allocator = allocator
	s.piece.allocator = allocator
	s.face.allocator = allocator
	s.script.allocator = allocator
	s.level.allocator = allocator
	s.bidi.allocator = allocator
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
	allocator := s.plans.allocator
	for &p in s.plans {
		sh.plan_destroy(&p.plan)
	}
	sh.shaper_destroy(&s.shaper)
	delete(s.plans)
	delete(s.plan_features)
	delete(s.seg_features)
	delete(s.piece_start)
	delete(s.piece_size)
	delete(s.piece_features)
	delete(s.features)
	delete(s.runes)
	delete(s.piece)
	delete(s.face)
	delete(s.script)
	delete(s.level)
	delete(s.bidi)
	delete(s.segs)
	delete(s.order)
	delete(s.glyphs)
	free(s, allocator)
}

// Sizes scratch to `n` rows, which the caller fills: its length set,
// growing (geometrically) only when it is short. Rows it gains keep
// whatever they held.
@(private)
scratch_size :: #force_inline proc(a: ^[dynamic]$T, n: int) {
	if n > cap(a) {
		reserve(a, max(n, 2 * cap(a)))
	}
	(^runtime.Raw_Dynamic_Array)(a).len = n
}

@(private)
collection_allocator :: proc(fonts: ^Font_Collection) -> runtime.Allocator {
	if fonts.faces.allocator.procedure != nil {
		return fonts.faces.allocator
	}
	return runtime.heap_allocator()
}

// The face's layout tables, prepared on first use.
@(private)
font_shaping :: proc(fonts: ^Font_Collection, f: ^Font) -> ^sh.Layout {
	sync.mutex_lock(&fonts.shape_lock)
	defer sync.mutex_unlock(&fonts.shape_lock)
	if f.shaping == nil {
		allocator := font_allocator(f)
		f.shaping = new(sh.Layout, allocator)
		sh.layout_init(f.shaping, &f.face, allocator)
	}
	return f.shaping
}

// Frees the face's layout tables.
@(private)
font_shaping_destroy :: proc(f: ^Font) {
	if f.shaping != nil {
		sh.layout_destroy(f.shaping)
		free(f.shaping, font_allocator(f))
		f.shaping = nil
	}
}

// Script and bidi level of each codepoint of the line [a, b) (script runs,
// levels for a left-to-right paragraph: text_bidi.odin).
@(private)
shaper_itemize :: proc(s: ^Text_Shaper, a, b: i32) {
	// Fast path: Latin with common punctuation, symbols and digits is one
	// left-to-right Latin run.
	latin := true
	for r in s.runes[a:b] {
		if r >= 0x370 && (r < 0x2000 || r > 0x20cf) {
			latin = false
			break
		}
	}
	if latin {
		for i in a ..< b {
			s.script[i] = .Latin
			s.level[i] = 0
		}
		return
	}
	sh.script_runs(s.runes[a:b], s.script[a:b])
	for i in a ..< b {
		s.bidi[i] = bidi_class(s.runes[i], s.script[i])
	}
	bidi_resolve(s.bidi[a:b], s.level[a:b])
}

// Shapes one segment, appending its glyphs to the shaper's line glyphs.
@(private)
shaper_shape :: proc(fonts: ^Font_Collection, s: ^Text_Shaper, seg: ^Shape_Segment) {
	first := len(s.glyphs)
	seg.glyph_first = i32(first)
	defer seg.glyph_count = i32(len(s.glyphs) - first)

	direction: sh.Direction = .RTL if seg.level & 1 == 1 else .LTR
	shaper_segment_features(s, seg)
	plan := shaper_plan(fonts, s, seg, direction)
	sh.shape(&s.shaper, plan, &seg.font.face, s.runes[seg.first:][:seg.count], s.seg_features[:], &s.glyphs)
	if !s.shaper.ok {
		// Past the shaper's limits: one glyph per codepoint.
		resize(&s.glyphs, first)
		for i in seg.first ..< seg.first + seg.count {
			g := font_glyph_index(seg.font, s.runes[i])
			adv, _ := font_glyph_advance(seg.font, g)
			append(&s.glyphs, sh.Glyph{id = u16(g), cluster = i, advance = adv})
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
	p0, p1 := s.piece[seg.first], s.piece[seg.first + seg.count - 1]
	same := true
	for p in p0 + 1 ..= p1 {
		a, b := s.piece_features[p0], s.piece_features[p]
		if a[1] != b[1] || !features_equal(s.features[a[0]:][:a[1]], s.features[b[0]:][:b[1]]) {
			same = false
			break
		}
	}
	for p in p0 ..= p1 {
		pf := s.piece_features[p]
		start, end := 0, 0
		if !same {
			start = int(max(s.piece_start[p], seg.first) - seg.first)
			end = int(min(s.piece_start[p + 1] if int(p) + 1 < len(s.piece_start) else max(i32), seg.first + seg.count) - seg.first)
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

// The shaper's plan for the segment's face, script and feature settings
// and `direction`, made on first use.
@(private)
shaper_plan :: proc(fonts: ^Font_Collection, s: ^Text_Shaper, seg: ^Shape_Segment, direction: sh.Direction) -> ^sh.Plan {
	feats := s.seg_features[:]
	script := seg.script
	search: for &p in s.plans {
		if p.face != seg.face || p.script != script || p.direction != direction || int(p.count) != len(feats) {
			continue
		}
		for k, i in s.plan_features[p.first:][:p.count] {
			if k.tag != feats[i].tag || k.value != feats[i].value || sh.feature_is_global(k) != sh.feature_is_global(feats[i]) {
				continue search
			}
		}
		return &p.plan
	}
	p := Shape_Plan{face = seg.face, script = script, direction = direction, first = i32(len(s.plan_features)), count = i32(len(feats))}
	for k in feats {
		// Ranged settings are kept as covering one codepoint.
		append(&s.plan_features, sh.Feature{k.tag, k.value, 0, 0 if sh.feature_is_global(k) else 1})
	}
	f := seg.font
	sh.plan_init(&p.plan, font_shaping(fonts, f), &f.face, script, direction, 0, feats, s.plans.allocator)
	append(&s.plans, p)
	return &s.plans[len(s.plans) - 1].plan
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

