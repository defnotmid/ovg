package ovg

import "core:log"
import "core:os"
import "core:mem"
import "core:slice"
import "core:testing"
import "core:unicode/utf8"

// Shaping tests use system fonts when present (Noto on most Linux systems)
// and skip otherwise; the bundled Vera covers the legacy `kern` path.

@(private = "file")
NOTO_DIRS := [?]string{"/usr/share/fonts/noto/", "/usr/share/fonts/truetype/noto/", "/usr/share/fonts/google-noto/"}

@(private = "file")
Shape_Fx :: struct {
	fonts:  Font_Collection,
	layout: Text_Layout,
	data:   [dynamic][]u8,
}

@(private = "file")
fx_open :: proc(s: ^Shape_Fx) {
	font_collection_init(&s.fonts)
}

@(private = "file")
fx_close :: proc(s: ^Shape_Fx) {
	text_layout_destroy(&s.layout)
	font_collection_destroy(&s.fonts)
	for d in s.data {
		delete(d)
	}
	delete(s.data)
}

// Adds a system Noto font by file name; false (and a log line) when absent.
@(private = "file")
fx_add_noto :: proc(t: ^testing.T, s: ^Shape_Fx, name: string) -> bool {
	for dir in NOTO_DIRS {
		path := concat(dir, name)
		defer delete(path)
		if data, err := os.read_entire_file(path, context.allocator); err == nil {
			append(&s.data, data)
			return font_collection_add(&s.fonts, data) > 0
		}
	}
	log.infof("%s not found: skipped", name)
	return false
}

@(private = "file")
concat :: proc(a, b: string) -> string {
	out := make([]u8, len(a) + len(b))
	copy(out, a)
	copy(out[len(a):], b)
	return string(out)
}

@(private = "file")
fx_layout :: proc(s: ^Shape_Fx, text: string, family: string, letter_spacing: f32 = 0) -> []Positioned_Glyph {
	piece := Text_Piece{text = text, style = {family = family, size = 100, letter_spacing = letter_spacing}}
	text_layout(&s.fonts, {piece}, {}, &s.layout)
	return s.layout.glyphs[:]
}

@(test)
test_shape_latin_ligatures :: proc(t: ^testing.T) {
	s: Shape_Fx
	fx_open(&s)
	defer fx_close(&s)
	if !fx_add_noto(t, &s, "NotoSerif-Regular.ttf") {
		return
	}
	// liga: "fi" and "ffl" become one glyph each.
	testing.expect_value(t, len(fx_layout(&s, "fi", "Noto Serif")), 1)
	testing.expect_value(t, len(fx_layout(&s, "ffl", "Noto Serif")), 1)
	testing.expect_value(t, len(fx_layout(&s, "office", "Noto Serif")), 4)
	font, _ := font_collection_find(&s.fonts, "Noto Serif", 400)
	testing.expect(t, fx_layout(&s, "fi", "Noto Serif")[0].glyph != font_glyph_index(font, 'f'))
	// Letter-spacing turns optional ligatures off (CSS).
	testing.expect_value(t, len(fx_layout(&s, "ffl", "Noto Serif", 2)), 3)
}

@(test)
test_shape_gpos_kerning :: proc(t: ^testing.T) {
	s: Shape_Fx
	fx_open(&s)
	defer fx_close(&s)
	if !fx_add_noto(t, &s, "NotoSans-Regular.ttf") {
		return
	}
	font, _ := font_collection_find(&s.fonts, "Noto Sans", 400)
	em := font_scale_for_em(font, 100)
	for pair in ([?]string{"AV", "To"}) {
		g := fx_layout(&s, pair, "Noto Sans")
		testing.expect_value(t, len(g), 2)
		adv, _ := font_glyph_advance(font, g[0].glyph)
		// GPOS pair kerning pulls the second glyph in.
		testing.expectf(t, g[1].x - g[0].x < f32(adv) * em - 1, "%s: %v vs advance %v", pair, g[1].x - g[0].x, f32(adv) * em)
	}
}

@(test)
test_shape_legacy_kern_table :: proc(t: ^testing.T) {
	s: Shape_Fx
	fx_open(&s)
	defer fx_close(&s)
	// Vera has a `kern` table and no GPOS.
	g := fx_layout(&s, "AV", "")
	testing.expect_value(t, len(g), 2)
	font := &s.fonts.fallback.font
	testing.expect(t, font.shaping != nil)
	em := font_scale_for_em(font, 100)
	adv, _ := font_glyph_advance(font, g[0].glyph)
	kern := font_glyph_kern(font, g[0].glyph, g[1].glyph)
	testing.expect(t, kern < 0)
	testing.expect(t, abs(g[1].x - g[0].x - f32(adv + kern) * em) < 0.01)
}

@(test)
test_shape_arabic_joining :: proc(t: ^testing.T) {
	s: Shape_Fx
	fx_open(&s)
	defer fx_close(&s)
	if !fx_add_noto(t, &s, "NotoSansArabic-Regular.ttf") {
		return
	}
	font, _ := font_collection_find(&s.fonts, "Noto Sans Arabic", 400)
	// "سلم": seen, lam, meem join (initial, medial, final forms).
	word := "سلم"
	g := fx_layout(&s, word, "Noto Sans Arabic")
	testing.expect_value(t, len(g), 3)
	if len(g) != 3 {
		return
	}
	// Visual order is left to right: the first letter (seen) is rightmost.
	testing.expect(t, g[0].x < g[1].x && g[1].x < g[2].x)
	isolated := [3]Glyph_Index{font_glyph_index(font, 0x645), font_glyph_index(font, 0x644), font_glyph_index(font, 0x633)}
	for i in 0 ..< 3 {
		testing.expectf(t, g[i].glyph != isolated[i], "glyph %d kept its isolated form", i)
	}
}

@(test)
test_shape_fallback_and_bidi :: proc(t: ^testing.T) {
	s: Shape_Fx
	fx_open(&s)
	defer fx_close(&s)
	if !fx_add_noto(t, &s, "NotoSansArabic-Regular.ttf") {
		return
	}
	arabic, _ := font_collection_find(&s.fonts, "Noto Sans Arabic", 400)
	// Vera (the fallback face) has no Arabic: those glyphs fall back to Noto
	// Sans Arabic, in their own run, placed right to left between the Latin.
	text := "ab سلم cd"
	g := fx_layout(&s, text, "Bitstream Vera Sans")
	l := &s.layout
	testing.expect_value(t, len(g), 9)
	testing.expect(t, len(l.runs) >= 3)
	found := false
	for run in l.runs {
		if run.font == arabic {
			found = true
			testing.expect_value(t, run.count, 3)
		}
	}
	testing.expect(t, found)
	// Monotonic left-to-right placement in visual order.
	for i in 1 ..< len(g) {
		testing.expectf(t, g[i].x >= g[i - 1].x, "glyph %d at %v before %v", i, g[i].x, g[i - 1].x)
	}
	// Numbers after Arabic letters keep their order but sit left of them.
	g = fx_layout(&s, "سلم 12", "Noto Sans Arabic")
	one := font_glyph_index(arabic, '1')
	two := font_glyph_index(arabic, '2')
	testing.expect_value(t, len(g), 6)
	if len(g) == 6 {
		testing.expect_value(t, g[0].glyph, one)
		testing.expect_value(t, g[1].glyph, two)
	}
}

@(test)
test_shape_pieces_and_lines :: proc(t: ^testing.T) {
	s: Shape_Fx
	fx_open(&s)
	defer fx_close(&s)
	// dx / dy of a piece move the pen before it; "\n" starts a line.
	pieces := [?]Text_Piece{{text = "AB", style = {size = 20}}, {text = "C\nD", style = {size = 20, paint = 1}, dx = 5, dy = 2}}
	text_layout(&s.fonts, pieces[:], {}, &s.layout)
	l := &s.layout
	testing.expect_value(t, len(l.glyphs), 4)
	testing.expect_value(t, len(l.lines), 2)
	testing.expect_value(t, len(l.runs), 2)
	font := &s.fonts.fallback.font
	em := font_scale_for_em(font, 20)
	// Kerning continues across pieces of one face and size.
	adv_b, _ := font_glyph_advance(font, l.glyphs[1].glyph)
	kern := font_glyph_kern(font, l.glyphs[1].glyph, l.glyphs[2].glyph)
	testing.expect(t, abs(l.glyphs[2].x - (l.glyphs[1].x + f32(adv_b + kern) * em + 5)) < 0.01)
	testing.expect_value(t, l.glyphs[2].y, 2)
	testing.expect_value(t, l.glyphs[3].x, 0)
	testing.expect(t, abs(l.glyphs[3].y - (2 + 24)) < 0.01)
}

// Bidi levels in a left-to-right paragraph, without fonts: Arabic letters
// take their script from the test, as kb's itemization gives them.
@(test)
test_bidi_levels :: proc(t: ^testing.T) {
	levels :: proc(text: string) -> string {
		runes := utf8.string_to_runes(text, context.temp_allocator)
		cls := make([]Bidi_Class, len(runes), context.temp_allocator)
		lv := make([]u8, len(runes), context.temp_allocator)
		for r, i in runes {
			cls[i] = bidi_class(r, .ARABIC if r >= 0x600 && r < 0x700 else .LATIN)
		}
		bidi_resolve(cls, lv)
		out := make([]u8, len(lv), context.temp_allocator)
		for l, i in lv {
			out[i] = '0' + l
		}
		return string(out)
	}
	cases := [?]struct {
		text, want: string,
	} {
		{"abc", "000"},
		// Trailing neutrals after R take the paragraph's direction.
		{"ab سلم!", "0001110"},
		// Neutrals between R take R; a space before L text does not.
		{"ab سلم سلم cd", "0001111111000"},
		// Numbers after R: level 2, with the separator joining them.
		{"سلم 12.5", "11112222"},
		{"سلم-12", "111122"},
		// Arabic-Indic digits are AN, after R or L.
		{"ab ١٢", "00022"},
		// Numbers after L text are L, with their terminator.
		{"ab 12%", "000000"},
		// Brackets around R text inside L text keep the paragraph's direction.
		{"a (سلم) b", "000111000"},
		// An emoji after R text at the end of the line goes right.
		{"سلم 👍", "11100"},
	}
	for c in cases {
		testing.expectf(t, levels(c.text) == c.want, "%q: got %s, want %s", c.text, levels(c.text), c.want)
	}
}

// Once warm, laying out text allocates nothing: shaped segments come from
// the cache, fallback and bidi included.
@(test)
test_text_layout_no_allocation_when_warm :: proc(t: ^testing.T) {
	s: Shape_Fx
	fx_open(&s)
	defer fx_close(&s)
	fx_add_noto(t, &s, "NotoSansArabic-Regular.ttf")
	lines := [?]string{"The quick brown fox, 1234.", "office affinity AVAT", "abc مرحبا 42 def"}
	// Letter spacing places glyph configs (feature overrides) per segment.
	for _ in 0 ..< 3 {
		for line in lines {
			fx_layout(&s, line, "Bitstream Vera Sans")
			fx_layout(&s, line, "Bitstream Vera Sans", 2)
		}
	}
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	{
		context.allocator = mem.tracking_allocator(&track)
		for _ in 0 ..< 10 {
			for line in lines {
				fx_layout(&s, line, "Bitstream Vera Sans")
				fx_layout(&s, line, "Bitstream Vera Sans", 2)
			}
		}
	}
	testing.expect_value(t, track.total_allocation_count, 0)
}

// A combining mark the primary face lacks takes its base along to the face
// that has both, so the mark attaches (Vera has no U+0301; JetBrains Mono
// has it and GPOS mark positioning).
@(test)
test_shape_mark_cluster_fallback :: proc(t: ^testing.T) {
	s: Shape_Fx
	fx_open(&s)
	defer fx_close(&s)
	testing.expect(t, font_collection_add(&s.fonts, #load("demo/media/JetBrainsMono-Regular.ttf")) > 0)
	g := fx_layout(&s, "xéx", "Bitstream Vera Sans")
	l := &s.layout
	// x (Vera), e + mark (JetBrains, shaped together), x (Vera): the middle
	// run starts at the base (codepoint 1), not at a lone mark (2).
	testing.expect_value(t, len(l.runs), 3)
	if len(l.runs) == 3 {
		testing.expect(t, l.runs[0].font != l.runs[1].font)
		testing.expect_value(t, l.runs[0].count, 1)
		testing.expect_value(t, l.clusters[l.runs[1].first], 1)
	}
	_ = g
}

// Text that names no family is drawn in `default_family` when the
// collection has it, whatever other faces match its weight; without one
// (or with one the collection lacks) every face competes, the first
// winning ties.
@(test)
test_font_default_family :: proc(t: ^testing.T) {
	s: Shape_Fx
	fx_open(&s)
	defer fx_close(&s)
	testing.expect(t, font_collection_add(&s.fonts, #load("demo/media/BebasNeue-Regular.ttf")) > 0)
	testing.expect(t, font_collection_add(&s.fonts, #load("demo/media/JetBrainsMono-Regular.ttf")) > 0)
	bebas, _ := font_collection_find(&s.fonts, "Bebas Neue", 400)
	mono, _ := font_collection_find(&s.fonts, "JetBrains Mono", 400)
	f, ok := font_collection_find(&s.fonts, "", 400)
	testing.expect(t, ok && f == bebas)
	s.fonts.default_family = "JetBrains Mono"
	f, ok = font_collection_find(&s.fonts, "", 700)
	testing.expect(t, ok && f == mono)
	s.fonts.default_family = "No Such Family"
	f, ok = font_collection_find(&s.fonts, "", 400)
	testing.expect(t, ok && f == bebas)
}

// A font collection allocates from its own allocator: faces, family names
// and glyph shapes, whatever the context's is when faces are added, shapes
// built or the collection destroyed.
@(test)
test_font_collection_uses_its_allocator :: proc(t: ^testing.T) {
	own, other: mem.Tracking_Allocator
	mem.tracking_allocator_init(&own, context.allocator)
	defer mem.tracking_allocator_destroy(&own)
	mem.tracking_allocator_init(&other, context.allocator)
	defer mem.tracking_allocator_destroy(&other)
	{
		fonts: Font_Collection
		font_collection_init(&fonts, nil, mem.tracking_allocator(&own))
		context.allocator = mem.tracking_allocator(&other)
		testing.expect(t, font_collection_add(&fonts, #load("demo/media/JetBrainsMono-Regular.ttf")) > 0)
		f := &fonts.faces[0].font
		testing.expect(t, font_glyph_shape(f, font_glyph_index(f, 'A')) != nil)
		testing.expect(t, font_glyph_shape(&fonts.fallback.font, font_glyph_index(&fonts.fallback.font, 'A')) != nil)
		font_collection_destroy(&fonts)
	}
	testing.expect_value(t, other.total_allocation_count, 0)
	testing.expect_value(t, len(own.allocation_map), 0)
}

// Faces go where `before` puts them; a removed face frees its name and
// font, and a default family naming it is cleared.
@(test)
test_font_collection_place_and_remove :: proc(t: ^testing.T) {
	own: mem.Tracking_Allocator
	mem.tracking_allocator_init(&own, context.allocator)
	defer mem.tracking_allocator_destroy(&own)
	{
		fonts: Font_Collection
		font_collection_init(&fonts, nil, mem.tracking_allocator(&own))
		mono := #load("demo/media/JetBrainsMono-Regular.ttf")
		testing.expect_value(t, font_collection_add(&fonts, DEFAULT_FONT_DATA), 1)
		testing.expect_value(t, font_collection_add(&fonts, mono, before = 0), 1)
		testing.expect_value(t, len(fonts.faces), 2)
		testing.expect_value(t, fonts.faces[0].family, "JetBrains Mono")
		testing.expect_value(t, fonts.faces[1].family, "Bitstream Vera Sans")
		fonts.default_family = fonts.faces[0].family
		l: Text_Layout
		text_layout_init(&l, mem.tracking_allocator(&own))
		text_layout(&fonts, {{text = "office", style = {size = 20}}}, {}, &l)
		font_collection_remove(&fonts, 0)
		testing.expect_value(t, fonts.default_family, "")
		testing.expect_value(t, len(fonts.faces), 1)
		testing.expect_value(t, fonts.faces[0].family, "Bitstream Vera Sans")
		text_layout(&fonts, {{text = "office", style = {size = 20}}}, {}, &l)
		testing.expect(t, len(l.glyphs) > 0)
		text_layout_destroy(&l)
		font_collection_destroy(&fonts)
	}
	testing.expect_value(t, len(own.allocation_map), 0)
}

// Paths, flattened paths, layouts and morphs made with an init allocate
// from its allocator, whatever the context's is.
@(test)
test_inits_use_their_allocator :: proc(t: ^testing.T) {
	own, other: mem.Tracking_Allocator
	mem.tracking_allocator_init(&own, context.allocator)
	defer mem.tracking_allocator_destroy(&own)
	mem.tracking_allocator_init(&other, context.allocator)
	defer mem.tracking_allocator_destroy(&other)
	{
		alloc := mem.tracking_allocator(&own)
		fonts: Font_Collection
		font_collection_init(&fonts, nil, alloc)
		a, b, out: Path
		path_init(&a, alloc)
		path_init(&b, alloc)
		path_init(&out, alloc)
		flat: Flat_Path
		flat_path_init(&flat, alloc)
		l: Text_Layout
		text_layout_init(&l, alloc)
		m: Path_Morph
		path_morph_init(&m, alloc)
		context.allocator = mem.tracking_allocator(&other)
		path_circle(&a, 0, 0, 10)
		path_rect(&b, 0, 0, 10, 20)
		path_rect(&b, 30, 0, 10, 20)
		path_flatten(&a, &flat)
		text_layout(&fonts, {{text = "Hi", style = {family = "Nope", size = 20}}}, {}, &l)
		path_morph_prepare(&m, &a, &b)
		path_morph_eval(&m, 0.5, &out)
		testing.expect_value(t, other.total_allocation_count, 0)
		testing.expect(t, len(l.missing) == 1 && len(out.verbs) > 0)
		path_destroy(&a)
		path_destroy(&b)
		path_destroy(&out)
		flat_path_destroy(&flat)
		text_layout_destroy(&l)
		path_morph_destroy(&m)
		font_collection_destroy(&fonts)
	}
	testing.expect_value(t, len(own.allocation_map), 0)
}

@(test)
test_shape_features :: proc(t: ^testing.T) {
	s: Shape_Fx
	fx_open(&s)
	defer fx_close(&s)
	if !fx_add_noto(t, &s, "NotoSans-Regular.ttf") {
		return
	}
	layout :: proc(s: ^Shape_Fx, text: string, features: []Font_Feature, letter_spacing: f32 = 0) -> []Positioned_Glyph {
		piece := Text_Piece{text = text, style = {family = "Noto Sans", size = 100, letter_spacing = letter_spacing, features = features}}
		text_layout(&s.fonts, {piece}, {}, &s.layout)
		return s.layout.glyphs[:]
	}
	// Glyph ids from fontTools: a.sc, zero.slash, and aalt's alternates of I
	// (i.sc, I.salt).
	smcp := [?]Font_Feature{{"smcp", 1}}
	testing.expect_value(t, layout(&s, "a", smcp[:])[0].glyph, 1868)
	zero := [?]Font_Feature{{"zero", 1}}
	testing.expect_value(t, layout(&s, "0", zero[:])[0].glyph, 2251)
	aalt1, aalt2 := [?]Font_Feature{{"aalt", 1}}, [?]Font_Feature{{"aalt", 2}}
	testing.expect_value(t, layout(&s, "I", aalt1[:])[0].glyph, 1911)
	testing.expect_value(t, layout(&s, "I", aalt2[:])[0].glyph, 1738)
	// Off by default, on by default turned off, and a style's own setting
	// over letter spacing's.
	testing.expect_value(t, layout(&s, "a", nil)[0].glyph, 68)
	no_liga, liga := [?]Font_Feature{{"liga", 0}}, [?]Font_Feature{{"liga", 1}}
	testing.expect_value(t, len(layout(&s, "fi", nil)), 1)
	testing.expect_value(t, len(layout(&s, "fi", no_liga[:])), 2)
	testing.expect_value(t, len(layout(&s, "fi", liga[:], 2)), 1)
	// kern off: the pair keeps its advance.
	font, _ := font_collection_find(&s.fonts, "Noto Sans", 400)
	em := font_scale_for_em(font, 100)
	no_kern := [?]Font_Feature{{"kern", 0}}
	g := layout(&s, "AV", no_kern[:])
	adv, _ := font_glyph_advance(font, g[0].glyph)
	testing.expect(t, abs(g[1].x - g[0].x - f32(adv) * em) < 0.01)
	// Features stay with their piece within one shaped segment.
	pieces := [?]Text_Piece{{text = "aa", style = {family = "Noto Sans", size = 100, features = smcp[:]}}, {text = "aa", style = {family = "Noto Sans", size = 100}}}
	text_layout(&s.fonts, pieces[:], {}, &s.layout)
	ids: [4]Glyph_Index
	for gl, i in s.layout.glyphs {
		ids[i] = gl.glyph
	}
	testing.expect_value(t, ids, [4]Glyph_Index{1868, 1868, 68, 68})
}

@(test)
test_font_info :: proc(t: ^testing.T) {
	// Expected values from fontTools.
	f, err := font_load(#load("demo/media/JetBrainsMono-Regular.ttf"))
	testing.expect_value(t, err, nil)
	defer font_destroy(&f)
	info := font_info(&f)
	defer font_info_destroy(&info)
	testing.expect_value(t, info.family, "JetBrains Mono")
	testing.expect_value(t, info.subfamily, "Regular")
	testing.expect_value(t, info.full_name, "JetBrains Mono Regular")
	testing.expect_value(t, info.postscript_name, "JetBrainsMono-Regular")
	testing.expect_value(t, info.glyph_count, 1168)
	features := [?]string{"aalt", "calt", "case", "ccmp", "frac", "locl", "mark", "ordn", "sinf", "subs", "sups", "zero"}
	testing.expect(t, slice.equal(info.features, features[:]))
	names := font_glyph_names(&f)
	defer delete(names)
	testing.expect_value(t, len(names), 1168)
	testing.expect_value(t, names[0], ".notdef")
	testing.expect_value(t, names[536], "zero")
	testing.expect_value(t, names[546], "zero.zero")

	// The feature the info lists, set on a style.
	s: Shape_Fx
	fx_open(&s)
	defer fx_close(&s)
	testing.expect(t, font_collection_add(&s.fonts, #load("demo/media/JetBrainsMono-Regular.ttf")) > 0)
	zero := [?]Font_Feature{{"zero", 1}}
	pieces := [?]Text_Piece{{text = "0", style = {family = "JetBrains Mono", size = 10}}, {text = "0", style = {family = "JetBrains Mono", size = 10, features = zero[:]}}}
	text_layout(&s.fonts, pieces[:], {}, &s.layout)
	testing.expect_value(t, s.layout.glyphs[0].glyph, 536)
	testing.expect_value(t, s.layout.glyphs[1].glyph, 546)
}
