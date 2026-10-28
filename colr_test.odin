package ovg

import "core:testing"

// Colour glyphs: assets/colr_test.ttf (tools/colr_test_font/build.py) and
// the bundled Noto Color Emoji. Glyphs draw at 0.1 px per unit: the square
// spans x 10..90, y 0..80 (baseline 80); the inner square x 30..70, y 20..60.

@(private = "file")
COLR_TEST_FONT :: #load("assets/colr_test.ttf")

@(private = "file")
Colr_Fx :: struct {
	backend: Software_Backend,
	canvas:  Canvas,
	font:    Font,
	path:    Path,
}

@(private = "file")
fx_open :: proc(s: ^Colr_Fx) {
	software_backend_init(&s.backend)
	canvas_init(&s.canvas, software_backend(&s.backend))
	s.font, _ = font_load(COLR_TEST_FONT)
}

@(private = "file")
fx_close :: proc(s: ^Colr_Fx) {
	path_destroy(&s.path)
	font_destroy(&s.font)
	canvas_destroy(&s.canvas)
	software_backend_destroy(&s.backend)
}

// Draws the glyph for `r` on white and returns the frame's pixels.
@(private = "file")
fx_draw :: proc(s: ^Colr_Fx, r: rune, fg: Paint) {
	set_size(&s.canvas, 100, 100)
	clear_rect(&s.canvas, 0, 0, 100, 100, WHITE)
	g := [1]Positioned_Glyph{{font_glyph_index(&s.font, r), 0, 80}}
	fill_glyph_outlines(&s.canvas, &s.font, g[:], 0.1, fg, &s.path)
	flush(&s.canvas)
}

@(private = "file")
at :: proc(s: ^Colr_Fx, x, y: u32) -> [4]i32 {
	i := (y * s.backend.width + x) * 4
	p := s.backend.pixels
	return {i32(p[i]), i32(p[i + 1]), i32(p[i + 2]), i32(p[i + 3])}
}

@(private = "file")
near :: proc(a, b: [4]i32, tol: i32 = 3) -> bool {
	for i in 0 ..< 4 {
		if abs(a[i] - b[i]) > tol {
			return false
		}
	}
	return true
}

@(test)
test_colr_v0_layers :: proc(t: ^testing.T) {
	s: Colr_Fx
	fx_open(&s)
	defer fx_close(&s)
	testing.expect(t, s.font.colr != nil)
	testing.expect(t, font_glyph_is_colour(&s.font, font_glyph_index(&s.font, 'A')))
	// Layer 1: palette red; layer 2: 0xFFFF, the text's colour.
	fx_draw(&s, 'A', paint_color(rgb(0, 0, 255)))
	testing.expect(t, near(at(&s, 15, 70), {255, 0, 0, 255}))
	testing.expect(t, near(at(&s, 50, 40), {0, 0, 255, 255}))
	testing.expect(t, near(at(&s, 95, 40), {255, 255, 255, 255}))
	// The text's alpha applies to palette colours too.
	fx_draw(&s, 'A', paint_color(rgba(0, 0, 255, 128)))
	testing.expect(t, near(at(&s, 15, 70), {255, 127, 127, 255}, 4))
}

@(test)
test_colr_foreground :: proc(t: ^testing.T) {
	s: Colr_Fx
	fx_open(&s)
	defer fx_close(&s)
	// Green square, then the inner square in the text colour at alpha 0.5,
	// moved 100 units (10 px) right.
	fx_draw(&s, 'D', paint_color(BLACK))
	testing.expect(t, near(at(&s, 15, 70), {0, 255, 0, 255}))
	testing.expect(t, near(at(&s, 35, 40), {0, 255, 0, 255}))
	testing.expect(t, near(at(&s, 75, 40), {0, 128, 0, 255}, 4))
	// A gradient text paint fills foreground layers as it is.
	fx_draw(&s, 'A', paint_linear_gradient(30, 0, 70, 0, rgb(0, 0, 0), rgb(255, 255, 255)))
	l, r := at(&s, 32, 40), at(&s, 68, 40)
	testing.expect(t, l.r < 40 && r.r > 215 && near(at(&s, 15, 70), {255, 0, 0, 255}))
}

@(test)
test_colr_v1_gradients :: proc(t: ^testing.T) {
	s: Colr_Fx
	fx_open(&s)
	defer fx_close(&s)
	fg := paint_color(BLACK)
	// Linear: red at x 10 to blue at x 90.
	fx_draw(&s, 'B', fg)
	l, m, r := at(&s, 11, 40), at(&s, 50, 40), at(&s, 89, 40)
	testing.expect(t, l.r > 240 && l.b < 15 && r.b > 240 && r.r < 15)
	testing.expect(t, abs(m.r - m.b) < 12 && m.r > 100)
	// Sweep from 3 o'clock, counter-clockwise (y up): red just above the
	// start, blue just below it.
	fx_draw(&s, 'C', fg)
	above, below := at(&s, 85, 37), at(&s, 85, 43)
	testing.expect(t, above.r > 230 && above.b < 25)
	testing.expect(t, below.b > 230 && below.r < 25)
	left := at(&s, 15, 40) // half way round
	testing.expect(t, abs(left.r - left.b) < 16)
	// Radial: red centre to blue at 40 px.
	fx_draw(&s, 'F', fg)
	cen, edge := at(&s, 50, 40), at(&s, 50, 78)
	testing.expect(t, cen.r > 240 && cen.b < 15 && edge.b > 220)
	// SRC_IN composite: the gradient inside the inner square only.
	fx_draw(&s, 'E', fg)
	testing.expect(t, near(at(&s, 15, 70), {255, 255, 255, 255}))
	in_l, in_r := at(&s, 32, 40), at(&s, 68, 40)
	testing.expect(t, in_l.r > in_l.b + 80 && in_r.b > in_r.r + 80)
}

@(test)
test_colr_emoji_fallback :: proc(t: ^testing.T) {
	fonts: Font_Collection
	font_collection_init(&fonts)
	defer font_collection_destroy(&fonts)
	testing.expect(t, font_collection_set_emoji(&fonts, EMOJI_FONT_DATA))
	l: Text_Layout
	defer text_layout_destroy(&l)

	// Vera lacks the emoji: they come from the emoji face, in colour; a ZWJ
	// sequence and a flag shape into one glyph each.
	text_layout(&fonts, {{text = "a\U0001F525 \U0001F469‍\U0001F4BB\U0001F1EF\U0001F1F5", style = {size = 100}}}, {x = 10, y = 100}, &l)
	testing.expect_value(t, len(l.runs), 4) // a, fire, space, the rest
	testing.expect(t, l.runs[0].face == fonts.fallback.id && l.runs[1].face == fonts.emoji.id)
	testing.expect_value(t, len(l.glyphs), 5) // a, fire, space, technologist, flag
	for g in l.glyphs[1:] {
		testing.expect(t, g.glyph == l.glyphs[2].glyph || font_glyph_is_colour(font_collection_font(&fonts, fonts.emoji.id), g.glyph))
	}
	// A keycap: Vera has "1", but U+FE0F asks for the emoji face (and,
	// missing from it, leaves no glyph).
	text_layout(&fonts, {{text = "1️⃣", style = {size = 100}}}, {}, &l)
	testing.expect_value(t, len(l.glyphs), 1)
	testing.expect(t, l.runs[0].face == fonts.emoji.id)

	// Drawn: the fire is orange, not the text colour.
	sw: Software_Backend
	software_backend_init(&sw)
	defer software_backend_destroy(&sw)
	c: Canvas
	canvas_init(&c, software_backend(&sw))
	defer canvas_destroy(&c)
	set_size(&c, 140, 140)
	clear_rect(&c, 0, 0, 140, 140, WHITE)
	text_layout(&fonts, {{text = "\U0001F525", style = {size = 128}}}, {x = 6, y = 115}, &l)
	path: Path
	defer path_destroy(&path)
	for run in l.runs {
		fill_glyph_outlines(&c, text_layout_font(&l, run), l.glyphs[run.first:][:run.count], run.em, paint_color(BLACK), &path)
	}
	flush(&c)
	orange := 0
	for i := 0; i < len(sw.pixels); i += 4 {
		r, g, b := sw.pixels[i], sw.pixels[i + 1], sw.pixels[i + 2]
		if r > 200 && g > 60 && g < 200 && b < 80 {
			orange += 1
		}
	}
	testing.expect(t, orange > 1000)
}

// Setting the emoji face again from the same data finds its file: the new
// face shapes with the layout tables and plans the old one made, which
// stay with the file.
@(test)
test_colr_emoji_reset :: proc(t: ^testing.T) {
	fonts: Font_Collection
	font_collection_init(&fonts)
	defer font_collection_destroy(&fonts)
	l: Text_Layout
	defer text_layout_destroy(&l)
	// One buffer for both calls (each use of the constant may be a copy).
	emoji := EMOJI_FONT_DATA
	testing.expect(t, font_collection_set_emoji(&fonts, emoji))
	text_layout(&fonts, {{text = "a\U0001F525", style = {size = 100}}}, {}, &l)
	file := fonts.emoji.file
	plans := file.plans
	testing.expect(t, plans != nil)
	testing.expect(t, font_collection_set_emoji(&fonts, emoji))
	testing.expect(t, fonts.emoji.file == file)
	testing.expect_value(t, len(fonts.files.rows), 2)
	text_layout(&fonts, {{text = "a\U0001F600\U0001F44D\U0001F3FD", style = {size = 100}}}, {}, &l)
	testing.expect_value(t, len(l.glyphs), 3)
	testing.expect(t, file.plans == plans)
}

// The fill cap is per glyph: a face keeps drawing colour glyphs after
// thousands of fills are cached for earlier ones.
@(test)
test_colr_many_glyphs :: proc(t: ^testing.T) {
	f, err := font_load(EMOJI_FONT_DATA)
	testing.expect_value(t, err, nil)
	defer font_destroy(&f)
	cl := f.colr
	testing.expect(t, cl != nil)
	last := Colr_Glyph{}
	colour := 0
	for g in Glyph_Index(1) ..< 1000 {
		if font_glyph_is_colour(&f, g) {
			colour += 1
			last = colr_glyph(cl, g)
		}
	}
	testing.expect(t, colour > 500)
	testing.expect(t, len(cl.fills) > 4096)
	testing.expect(t, last.count > 0)
}
