package ovg

import "core:log"
import "core:os"
import "core:mem"
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
	for _ in 0 ..< 3 {
		for line in lines {
			fx_layout(&s, line, "Bitstream Vera Sans")
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
			}
		}
	}
	testing.expect_value(t, track.total_allocation_count, 0)
}
