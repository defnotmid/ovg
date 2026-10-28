package ovg

import "base:runtime"
import "core:log"
import "core:os"
import "core:mem"
import "core:slice"
import "core:testing"
import "core:thread"

import ft "deps:oglyph/font"

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

// The font of the face font_collection_find gives for `family`.
@(private = "file")
fx_find :: proc(s: ^Shape_Fx, family: string) -> ^Font {
	face, _ := font_collection_find(&s.fonts, family, 400)
	return font_collection_font(&s.fonts, face)
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
	font := fx_find(&s, "Noto Serif")
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
	font := fx_find(&s, "Noto Sans")
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
	font := font_collection_font(&s.fonts, s.fonts.fallback.id)
	testing.expect(t, s.fonts.fallback.file.shaping != nil)
	em := font_scale_for_em(font, 100)
	adv, _ := font_glyph_advance(font, g[0].glyph)
	// Vera's kern table: A V -131 (fontTools).
	testing.expect(t, abs(g[1].x - g[0].x - f32(adv - 131) * em) < 0.01)
}

@(test)
test_shape_arabic_joining :: proc(t: ^testing.T) {
	s: Shape_Fx
	fx_open(&s)
	defer fx_close(&s)
	if !fx_add_noto(t, &s, "NotoSansArabic-Regular.ttf") {
		return
	}
	font := fx_find(&s, "Noto Sans Arabic")
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
	arabic := fx_find(&s, "Noto Sans Arabic")
	// Vera (the fallback face) has no Arabic: those glyphs fall back to Noto
	// Sans Arabic, in their own run, placed right to left between the Latin.
	text := "ab سلم cd"
	g := fx_layout(&s, text, "Bitstream Vera Sans")
	l := &s.layout
	testing.expect_value(t, len(g), 9)
	testing.expect(t, len(l.runs) >= 3)
	found := false
	for run in l.runs {
		if text_layout_font(l, run) == arabic {
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
	font := font_collection_font(&s.fonts, s.fonts.fallback.id)
	em := font_scale_for_em(font, 20)
	// Kerning continues across pieces of one face and size.
	// Vera's kern table: B C -36 (fontTools).
	adv_b, _ := font_glyph_advance(font, l.glyphs[1].glyph)
	testing.expect(t, abs(l.glyphs[2].x - (l.glyphs[1].x + f32(adv_b - 36) * em + 5)) < 0.01)
	testing.expect_value(t, l.glyphs[2].y, 2)
	testing.expect_value(t, l.glyphs[3].x, 0)
	testing.expect(t, abs(l.glyphs[3].y - (2 + 24)) < 0.01)
}

// Wrapping: a line breaks after the last space where it fits, the space
// hanging outside its width; a word wider than the width has a line of its
// own; newlines still end lines. Line ranges tile the text, baselines step
// by the line height, and with Line_Top the first sits half the leading and
// the em box's ascent below y.
@(test)
test_text_layout_wrap :: proc(t: ^testing.T) {
	s: Shape_Fx
	fx_open(&s)
	defer fx_close(&s)
	l := &s.layout
	width_of :: proc(s: ^Shape_Fx, text: string) -> f32 {
		text_layout(&s.fonts, {{text = text, style = {size = 20}}}, {}, &s.layout)
		return s.layout.lines[0].width
	}
	ranges :: proc(l: ^Text_Layout) -> [dynamic][2]i32 {
		out := make([dynamic][2]i32, context.temp_allocator)
		for line in l.lines {
			append(&out, [2]i32{line.text_start, line.text_end})
		}
		return out
	}
	expect_ranges :: proc(t: ^testing.T, l: ^Text_Layout, want: [][2]i32, loc := #caller_location) {
		got := ranges(l)
		testing.expectf(t, len(got) == len(want), "%v lines, want %v", got, want, loc = loc)
		for r, i in want {
			if i < len(got) {
				testing.expectf(t, got[i] == r, "line %d: %v, want %v", i, got[i], r, loc = loc)
			}
		}
	}
	text :: "aaa bbb ccc"
	w2 := width_of(&s, "aaa bbb")
	w3 := width_of(&s, text)
	text_layout(&s.fonts, {{text = text, style = {size = 20}}}, {width = w2 + 1}, l)
	expect_ranges(t, l, {{0, 8}, {8, 11}})
	testing.expect(t, abs(l.lines[0].width - w2) < 0.01)
	testing.expect(t, abs(l.lines[1].y - l.lines[0].y - 24) < 0.01)
	testing.expect_value(t, l.glyphs[l.lines[1].first].x, 0)
	// Exactly as wide: one line.
	text_layout(&s.fonts, {{text = text, style = {size = 20}}}, {width = w3}, l)
	expect_ranges(t, l, {{0, 11}})
	// A word wider than the width, and newlines.
	text_layout(&s.fonts, {{text = "aaaaaaaa bb", style = {size = 20}}}, {width = 10}, l)
	expect_ranges(t, l, {{0, 9}, {9, 11}})
	text_layout(&s.fonts, {{text = "aa bb\ncc", style = {size = 20}}}, {width = width_of(&s, "aa") + 1}, l)
	expect_ranges(t, l, {{0, 3}, {3, 6}, {6, 8}})
	// Centred lines, each by its own width.
	text_layout(&s.fonts, {{text = text, style = {size = 20}}}, {x = 100, width = w2 + 1, align = .Center}, l)
	testing.expect(t, abs(l.glyphs[l.lines[1].first].x - (100 - l.lines[1].width / 2)) < 0.01)
	// Line_Top: half the leading and the em box's ascent below y, and the
	// next line a line height below (one face and size).
	font := font_collection_font(&s.fonts, s.fonts.fallback.id)
	a, d := font_em_box(font)
	testing.expect(t, abs(a + d - 1) < 0.0001)
	text_layout(&s.fonts, {{text = "aa\nbb", style = {size = 20}}}, {y = 10, baseline = .Line_Top, line_height = 1.5}, l)
	testing.expect(t, abs(l.lines[0].y - (10 + 5 + a * 20)) < 0.01)
	testing.expect(t, abs(l.lines[1].y - l.lines[0].y - 30) < 0.01)
	testing.expect(t, abs(l.lines[0].above + l.lines[0].below - 30) < 0.01)
	testing.expect(t, abs(l.glyphs[0].y - l.lines[0].y) < 0.01)
}

// Each glyph's advance is the pen's step past it: kerned by Vera's kern
// table (the pair's value on the left glyph's advance), each glyph starts
// where the one before it ends and the advances add up to the line's
// width and its trailing letter spacing; a mark (U+0301 on x in JetBrains
// Mono) steps by nothing, letter spacing included.
@(test)
test_text_layout_advances :: proc(t: ^testing.T) {
	s: Shape_Fx
	fx_open(&s)
	defer fx_close(&s)
	g := fx_layout(&s, "AVAy.", "Bitstream Vera Sans", 3)
	l := &s.layout
	testing.expect_value(t, len(l.advances), len(g))
	sum: f32
	for k in 0 ..< len(g) {
		if k > 0 {
			testing.expect(t, abs(g[k].x - (g[k - 1].x + l.advances[k - 1])) < 0.001)
		}
		sum += l.advances[k]
	}
	testing.expect(t, abs(sum - (l.lines[0].width + 3)) < 0.001)
	testing.expect(t, font_collection_add(&s.fonts, #load("demo/media/JetBrainsMono-Regular.ttf")) > 0)
	g = fx_layout(&s, "x\u0301x", "JetBrains Mono", 3)
	testing.expect_value(t, len(g), 3)
	if len(g) == 3 {
		font := text_layout_font(l, l.runs[0])
		adv, _ := font_glyph_advance(font, g[0].glyph)
		testing.expect(t, abs(l.advances[0] - (f32(adv) * l.runs[0].em + 3)) < 0.001)
		testing.expect_value(t, l.advances[1], 0)
		testing.expect(t, abs(g[2].x - (g[0].x + l.advances[0])) < 0.001)
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
		testing.expect(t, l.runs[0].face != l.runs[1].face)
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
		f := font_collection_font(&fonts, fonts.faces[0].id)
		testing.expect(t, font_glyph_shape(f, font_glyph_index(f, 'A')) != nil)
		testing.expect(t, font_glyph_shape(font_collection_font(&fonts, fonts.fallback.id), font_glyph_index(font_collection_font(&fonts, fonts.fallback.id), 'A')) != nil)
		font_collection_destroy(&fonts)
	}
	testing.expect_value(t, other.total_allocation_count, 0)
	testing.expect_value(t, len(own.allocation_map), 0)
}

// Faces go where `before` puts them; a removed face frees its font, and
// its family's name, its file's, stays (a default family naming it still
// names it, now no face's: every face competes).
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
		testing.expect_value(t, fonts.default_family, "JetBrains Mono")
		testing.expect_value(t, len(fonts.faces), 1)
		testing.expect_value(t, fonts.faces[0].family, "Bitstream Vera Sans")
		text_layout(&fonts, {{text = "office", style = {size = 20}}}, {}, &l)
		testing.expect(t, len(l.glyphs) > 0)
		text_layout_destroy(&l)
		font_collection_destroy(&fonts)
	}
	testing.expect_value(t, len(own.allocation_map), 0)
}

// Layouts name faces by id: a face added before another moves it but
// keeps its id, so a layout made earlier still draws with it, and each
// face shapes with its own plans. A removed face's id names none, nor does
// a replaced emoji face's, Face_Id{} or another collection's id.
@(test)
test_font_collection_face_ids :: proc(t: ^testing.T) {
	mono := #load("demo/media/JetBrainsMono-Regular.ttf")
	bebas := #load("demo/media/BebasNeue-Regular.ttf")
	fonts, alone: Font_Collection
	font_collection_init(&fonts)
	defer font_collection_destroy(&fonts)
	font_collection_init(&alone)
	defer font_collection_destroy(&alone)
	l, again: Text_Layout
	defer text_layout_destroy(&l)
	defer text_layout_destroy(&again)
	testing.expect_value(t, font_collection_add(&fonts, mono), 1)
	text_layout(&fonts, {{text = "office", style = {family = "JetBrains Mono", size = 20}}}, {}, &l)
	testing.expect_value(t, len(l.runs), 1)
	id := l.runs[0].face
	testing.expect(t, id == fonts.faces[0].id && id != fonts.fallback.id)

	testing.expect_value(t, font_collection_add(&fonts, bebas, before = 0), 1)
	testing.expect_value(t, fonts.faces[1].family, "JetBrains Mono")
	testing.expect(t, font_collection_font(&fonts, id) == font_collection_font(&fonts, fonts.faces[1].id))
	text_layout(&fonts, {{text = "office", style = {family = "JetBrains Mono", size = 20}}}, {}, &again)
	testing.expect(t, again.runs[0].face == id && slice.equal(again.glyphs[:], l.glyphs[:]))
	// Bebas Neue, where JetBrains Mono was, shapes as it does alone.
	text_layout(&fonts, {{text = "office", style = {family = "Bebas Neue", size = 20}}}, {}, &again)
	testing.expect_value(t, font_collection_add(&alone, bebas), 1)
	text_layout(&alone, {{text = "office", style = {family = "Bebas Neue", size = 20}}}, {}, &l)
	testing.expect(t, again.runs[0].face == fonts.faces[0].id && slice.equal(again.glyphs[:], l.glyphs[:]))
	// Each layout resolves its runs in the collection it was laid out with.
	testing.expect(t, text_layout_font(&l, l.runs[0]) == font_collection_font(&alone, alone.faces[0].id))
	testing.expect(t, text_layout_font(&again, again.runs[0]) == font_collection_font(&fonts, fonts.faces[0].id))

	font_collection_remove(&fonts, 1)
	testing.expect(t, font_collection_font(&fonts, id) == nil)
	testing.expect(t, font_collection_font(&fonts, fonts.faces[0].id) == font_collection_font(&fonts, fonts.faces[0].id))
	testing.expect(t, font_collection_font(&fonts, fonts.fallback.id) == font_collection_font(&fonts, fonts.fallback.id))
	testing.expect(t, font_collection_font(&fonts, {}) == nil)
	testing.expect(t, font_collection_font(&fonts, alone.faces[0].id) == nil)
	testing.expect(t, font_collection_font(&alone, fonts.fallback.id) == nil)

	testing.expect(t, fonts.emoji == nil)
	testing.expect(t, font_collection_set_emoji(&fonts, EMOJI_FONT_DATA))
	first := fonts.emoji.?.id
	testing.expect(t, font_collection_font(&fonts, first) == font_collection_font(&fonts, fonts.emoji.?.id))
	testing.expect(t, font_collection_set_emoji(&fonts, EMOJI_FONT_DATA))
	testing.expect(t, font_collection_font(&fonts, first) == nil && fonts.emoji.?.id != first)
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
		testing.expect(t, len(l.missing) == 1 && !path_is_empty(&out))
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
	// By glyph name (fontTools' and HarfBuzz's): their ids differ between
	// Noto Sans builds.
	font := fx_find(&s, "Noto Sans")
	names := font_glyph_names(font)
	defer delete(names)
	named :: proc(names: []string, g: []Positioned_Glyph) -> (out: [4]string) {
		for gl, i in g[:min(len(g), 4)] {
			out[i] = names[gl.glyph]
		}
		return
	}
	smcp := [?]Font_Feature{{"smcp", 1}}
	testing.expect_value(t, named(names, layout(&s, "a", smcp[:])), [4]string{"a.sc", "", "", ""})
	zero := [?]Font_Feature{{"zero", 1}}
	testing.expect_value(t, named(names, layout(&s, "0", zero[:])), [4]string{"zero.slash", "", "", ""})
	// aalt's two alternates of I, by value (builds list them in either
	// order).
	aalt1, aalt2 := [?]Font_Feature{{"aalt", 1}}, [?]Font_Feature{{"aalt", 2}}
	alt1, alt2 := named(names, layout(&s, "I", aalt1[:]))[0], named(names, layout(&s, "I", aalt2[:]))[0]
	testing.expectf(t, (alt1 == "i.sc" && alt2 == "I.salt") || (alt1 == "I.salt" && alt2 == "i.sc"), "aalt 1, 2: %s, %s", alt1, alt2)
	// Fraction features apply to all the piece's glyphs, as in HarfBuzz.
	frac, numr, dnom := [?]Font_Feature{{"frac", 1}}, [?]Font_Feature{{"numr", 1}}, [?]Font_Feature{{"dnom", 1}}
	testing.expect_value(t, named(names, layout(&s, "1/2", frac[:])), [4]string{"one.numr", "fraction", "two.dnom", ""})
	testing.expect_value(t, named(names, layout(&s, "1/2", numr[:])), [4]string{"one.numr", "slash", "two.numr", ""})
	testing.expect_value(t, named(names, layout(&s, "1/2", dnom[:])), [4]string{"one.dnom", "slash", "two.dnom", ""})
	// Off by default, on by default turned off, and a style's own setting
	// over letter spacing's.
	testing.expect_value(t, named(names, layout(&s, "a", nil)), [4]string{"a", "", "", ""})
	no_liga, liga := [?]Font_Feature{{"liga", 0}}, [?]Font_Feature{{"liga", 1}}
	testing.expect_value(t, len(layout(&s, "fi", nil)), 1)
	testing.expect_value(t, len(layout(&s, "fi", no_liga[:])), 2)
	testing.expect_value(t, len(layout(&s, "fi", liga[:], 2)), 1)
	// kern off: the pair keeps its advance.
	em := font_scale_for_em(font, 100)
	no_kern := [?]Font_Feature{{"kern", 0}}
	g := layout(&s, "AV", no_kern[:])
	adv, _ := font_glyph_advance(font, g[0].glyph)
	testing.expect(t, abs(g[1].x - g[0].x - f32(adv) * em) < 0.01)
	// Features stay with their piece within one shaped segment.
	pieces := [?]Text_Piece{{text = "aa", style = {family = "Noto Sans", size = 100, features = smcp[:]}}, {text = "aa", style = {family = "Noto Sans", size = 100}}}
	text_layout(&s.fonts, pieces[:], {}, &s.layout)
	testing.expect_value(t, named(names, s.layout.glyphs[:]), [4]string{"a.sc", "a.sc", "a", "a"})
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
	runes := font_codepoints(&f)
	defer delete(runes)
	testing.expect_value(t, len(runes), 976)
	testing.expect_value(t, runes[0], 13)
	testing.expect_value(t, runes[975], 0xFEFF)

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
	// frac forms the font's ½ (HarfBuzz: 568).
	frac := [?]Font_Feature{{"frac", 1}}
	half := [?]Text_Piece{{text = "1/2", style = {family = "JetBrains Mono", size = 10, features = frac[:]}}}
	text_layout(&s.fonts, half[:], {}, &s.layout)
	testing.expect_value(t, len(s.layout.glyphs), 1)
	testing.expect_value(t, s.layout.glyphs[0].glyph, 568)
}

// The fallback face answers to its own family, so naming it (or setting
// default_family to it) is not a missing family, and empty-family text
// stays on it as faces are added.
@(test)
test_fallback_family :: proc(t: ^testing.T) {
	s: Shape_Fx
	fx_open(&s)
	defer fx_close(&s)
	vera := s.fonts.fallback.family
	f, found := font_collection_find(&s.fonts, vera, 400)
	testing.expect(t, found && f == s.fonts.fallback.id)
	testing.expect(t, font_collection_add(&s.fonts, #load("demo/media/JetBrainsMono-Regular.ttf")) > 0)
	f, found = font_collection_find(&s.fonts, "", 400)
	testing.expect(t, found && f != s.fonts.fallback.id)
	s.fonts.default_family = vera
	f, found = font_collection_find(&s.fonts, "", 400)
	testing.expect(t, found && f == s.fonts.fallback.id)
	text_layout(&s.fonts, {{text = "a", style = {family = vera}}}, {}, &s.layout)
	testing.expect_value(t, len(s.layout.missing), 0)
	s.fonts.default_family = ""
}

// A variable font drawn at an instance: advances, glyph boxes and layout
// follow it, and a collection gives the face the instance's weight.
@(test)
test_font_variation :: proc(t: ^testing.T) {
	data, err := os.read_entire_file("/usr/share/fonts/Adwaita/AdwaitaSans-Regular.ttf", context.allocator)
	if err != nil {
		log.info("AdwaitaSans-Regular.ttf not found: skipped")
		return
	}
	defer delete(data)
	heavy := [?]ft.Variation{{"wght", 800}}
	plain, _ := font_load(data)
	defer font_destroy(&plain)
	bold, _ := font_load(data, 0, context.allocator, heavy[:])
	defer font_destroy(&bold)
	testing.expect(t, plain.instance == 0 && bold.instance != 0)
	g := font_glyph_index(&bold, 'W')
	plain_advance, _ := font_glyph_advance(&plain, g)
	bold_advance, _ := font_glyph_advance(&bold, g)
	testing.expect(t, bold_advance > plain_advance)
	px0, py0, px1, py1, bx0, by0, bx1, by1: i32
	testing.expect(t, font_glyph_box(&plain, g, &px0, &py0, &px1, &py1) && font_glyph_box(&bold, g, &bx0, &by0, &bx1, &by1))
	testing.expect(t, bx1 - bx0 > px1 - px0)
	// The box holds the varied outline.
	o: ft.Outline
	defer ft.outline_destroy(&o)
	testing.expect(t, ft.glyph_outline(&bold.face, ft.Glyph(g), &o))
	for p in o.points {
		testing.expect(t, p.x >= f32(bx0) && p.x <= f32(bx1) && p.y >= f32(by0) && p.y <= f32(by1))
	}

	fonts: Font_Collection
	font_collection_init(&fonts)
	defer font_collection_destroy(&fonts)
	testing.expect_value(t, font_collection_add(&fonts, data), 1)
	testing.expect_value(t, font_collection_add(&fonts, data, variations = heavy[:]), 1)
	testing.expect_value(t, fonts.faces[0].weight, 400)
	testing.expect_value(t, fonts.faces[1].weight, 800)
	l: Text_Layout
	defer text_layout_destroy(&l)
	width :: proc(fonts: ^Font_Collection, l: ^Text_Layout, weight: int) -> f32 {
		text_layout(fonts, {{text = "Wave", style = {family = "Adwaita Sans", size = 100, weight = weight}}}, {}, l)
		return l.max.x - l.min.x
	}
	testing.expect(t, width(&fonts, &l, 800) > width(&fonts, &l, 400))

	// Two instances apart only in optical size: text picks each by its
	// variations (weight and style can't tell them apart).
	opsz: ft.Axis
	for i in 0 ..< plain.face.axis_count {
		if a, ok := ft.axis(&plain.face, i); ok && a.tag == "opsz" {
			opsz = a
		}
	}
	testing.expect_value(t, opsz.tag, "opsz")
	small, large := [?]Font_Variation{{"opsz", opsz.min}}, [?]Font_Variation{{"opsz", opsz.max}}
	testing.expect_value(t, font_collection_add(&fonts, data, variations = small[:]), 1)
	testing.expect_value(t, font_collection_add(&fonts, data, variations = large[:]), 1)
	pick :: proc(fonts: ^Font_Collection, l: ^Text_Layout, v: []Font_Variation) -> ^Font {
		text_layout(fonts, {{text = "a", style = {family = "Adwaita Sans", size = 50, variations = v}}}, {}, l)
		return text_layout_font(l, l.runs[0])
	}
	// The smallest size is the default instance's or the third face.
	testing.expect(t, pick(&fonts, &l, small[:]) == (font_collection_font(&fonts, fonts.faces[0].id) if opsz.min == opsz.default else font_collection_font(&fonts, fonts.faces[2].id)))
	testing.expect(t, pick(&fonts, &l, large[:]) == font_collection_font(&fonts, fonts.faces[3].id))
}

// Collections sharing font files share each file's row (its family, layout
// tables and plans), made once for every face of the file in any of them,
// from any thread, and lay out as collections of their own do; a removed
// face's file keeps its plans.
@(test)
test_font_files :: proc(t: ^testing.T) {
	mono := #load("demo/media/JetBrainsMono-Regular.ttf")
	files: Font_Files
	font_files_init(&files)
	defer font_files_destroy(&files)
	a, b, alone: Font_Collection
	font_collection_init(&a, files = &files)
	defer font_collection_destroy(&a)
	font_collection_init(&b, files = &files)
	defer font_collection_destroy(&b)
	font_collection_init(&alone)
	defer font_collection_destroy(&alone)
	for c in ([?]^Font_Collection{&a, &b, &alone}) {
		testing.expect_value(t, font_collection_add(c, mono), 1)
	}
	file := a.faces[0].file
	testing.expect(t, b.faces[0].file == file && alone.faces[0].file != file)
	testing.expect(t, a.fallback.file == b.fallback.file)
	testing.expect_value(t, len(files.rows), 2)
	l, la: Text_Layout
	defer text_layout_destroy(&l)
	defer text_layout_destroy(&la)
	pieces := []Text_Piece{{text = "office -> ffi", style = {family = "JetBrains Mono", size = 20}}}
	text_layout(&a, pieces, {}, &l)
	text_layout(&alone, pieces, {}, &la)
	testing.expect(t, slice.equal(l.glyphs[:], la.glyphs[:]))
	plans := file.plans
	testing.expect(t, plans != nil && file.shaping != nil)
	text_layout(&b, pieces, {}, &l)
	testing.expect(t, file.plans == plans)
	font_collection_remove(&a, 0)
	text_layout(&b, pieces, {}, &l)
	testing.expect(t, file.plans == plans && slice.equal(l.glyphs[:], la.glyphs[:]))

	// Threads making instances at once, each in a collection of its own
	// sharing the files, against each instance laid out alone.
	data := mono
	adwaita, err := os.read_entire_file("/usr/share/fonts/Adwaita/AdwaitaSans-Regular.ttf", context.allocator)
	defer delete(adwaita)
	if err == nil {
		data = adwaita
	}
	INSTANCES :: 8
	Worker :: struct {
		files:  ^Font_Files,
		data:   []u8,
		glyphs: [INSTANCES]u64,
	}
	instance_glyphs :: proc(files: ^Font_Files, data: []u8, k: int) -> (sum: u64) {
		vars := []Font_Variation{{"wght", f32(100 + 100 * k)}}
		c: Font_Collection
		font_collection_init(&c, allocator = runtime.heap_allocator(), files = files)
		defer font_collection_destroy(&c)
		font_collection_add(&c, data, variations = vars)
		l: Text_Layout
		text_layout_init(&l, runtime.heap_allocator())
		defer text_layout_destroy(&l)
		text_layout(&c, {{text = "Variable fonts", style = {size = 30, variations = vars}}}, {}, &l)
		for g in l.glyphs {
			sum = sum * 31 + u64(g.glyph) + u64(transmute(u32)g.x) << 16
		}
		return
	}
	shared: Font_Files
	font_files_init(&shared, runtime.heap_allocator())
	defer font_files_destroy(&shared)
	workers: [4]Worker
	threads: [4]^thread.Thread
	for &w, i in workers {
		w = {files = &shared, data = data}
		threads[i] = thread.create_and_start_with_poly_data(&w, proc(w: ^Worker) {
			for k in 0 ..< INSTANCES {
				w.glyphs[k] = instance_glyphs(w.files, w.data, k)
			}
		})
	}
	for th in threads {
		thread.join(th)
		thread.destroy(th)
	}
	for k in 0 ..< INSTANCES {
		own: Font_Files
		font_files_init(&own, runtime.heap_allocator())
		want := instance_glyphs(&own, data, k)
		font_files_destroy(&own)
		for w in workers {
			testing.expect_value(t, w.glyphs[k], want)
		}
	}
	testing.expect_value(t, len(shared.rows), 2)
}
