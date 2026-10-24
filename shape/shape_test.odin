package shape

import "core:log"
import "core:math/rand"
import "core:os"
import "core:slice"
import "core:testing"
import ft "../font"

// Expected glyphs come from hb-shape (HarfBuzz 14.6) on the same fonts.
// Tests on system fonts skip when the font is absent.

@(private = "file")
vera := #load("../assets/Vera.ttf")
@(private = "file")
mono := #load("../demo/media/JetBrainsMono-Regular.ttf")
@(private = "file")
arabic := #load("../demo/media/NotoSansArabic-Bold.ttf")

@(test)
test_unicode :: proc(t: ^testing.T) {
	testing.expect_value(t, char_mirror('('), ')')
	testing.expect_value(t, char_mirror('>'), '<')
	testing.expect_value(t, char_mirror('a'), 0)
	testing.expect_value(t, char_props('A').gc, General_Category.Lu)
	testing.expect_value(t, char_props('A').script, Script.Latin)
	testing.expect_value(t, char_props(0x301).ccc, 230)
	testing.expect_value(t, char_props(0x627).joining, Joining.R)
	testing.expect_value(t, char_props(0x628).joining, Joining.D)
	testing.expect_value(t, MODIFIED_CCC[255], 255)
	testing.expect_value(t, MODIFIED_CCC[33], 27)
	a, b, ok := decompose(0xE9)
	testing.expect(t, ok && a == 'e' && b == 0x301)
	ab, composed := compose('e', 0x301)
	testing.expect(t, composed && ab == 0xE9)
	_, excluded := compose(0x915, 0x93C)
	testing.expect(t, !excluded)
	a, b, ok = decompose(0xAC00)
	testing.expect(t, ok && a == 0x1100 && b == 0x1161)
}

// Shapes `text` with Vera, LTR Latin.
@(private = "file")
shape_vera :: proc(text: string, out: ^[dynamic]Glyph) {
	f, _ := ft.load(vera)
	l: Layout
	layout_init(&l, &f)
	defer layout_destroy(&l)
	p: Plan
	plan_init(&p, &l, &f, .Latin, .LTR)
	defer plan_destroy(&p)
	s: Shaper
	shaper_init(&s)
	defer shaper_destroy(&s)
	runes: [dynamic]rune
	defer delete(runes)
	for r in text {
		append(&runes, r)
	}
	shape(&s, &p, &f, runes[:], nil, out)
}

@(test)
test_vera_kern :: proc(t: ^testing.T) {
	out: [dynamic]Glyph
	defer delete(out)
	shape_vera("AV", &out)
	testing.expect_value(t, len(out), 2)
	if len(out) == 2 {
		f, _ := ft.load(vera)
		a, v := ft.glyph_index(&f, 'A'), ft.glyph_index(&f, 'V')
		adv, _ := ft.h_metrics(&f, a)
		// V's ink starts the kerning after A's advance (split between the
		// two glyphs as HarfBuzz does).
		testing.expect_value(t, int(out[0].advance + out[1].offset[0]), adv + ft.kern(&f, a, v))
	}
}

// Shapes `text` with the font in `data` (false when it doesn't load).
@(private = "file")
shape_with :: proc(data: []u8, script: Script, dir: Direction, text: string, out: ^[dynamic]Glyph, variations: []ft.Variation = nil, features: []Feature = nil) -> bool {
	f, err := ft.load(data)
	if err != nil {
		return false
	}
	ft.set_variations(&f, variations)
	l: Layout
	layout_init(&l, &f)
	defer layout_destroy(&l)
	p: Plan
	plan_init(&p, &l, &f, script, dir, 0, features)
	defer plan_destroy(&p)
	s: Shaper
	shaper_init(&s)
	defer shaper_destroy(&s)
	runes: [dynamic]rune
	defer delete(runes)
	for r in text {
		append(&runes, r)
	}
	shape(&s, &p, &f, runes[:], features, out)
	return true
}

// Glyph, cluster, advance and offset, as hb-shape prints them.
@(private = "file")
Expect :: struct {
	id:      u16,
	cluster: i32,
	advance: i32,
	offset:  [2]i32,
}

@(private = "file")
expect_glyphs :: proc(t: ^testing.T, got: []Glyph, want: []Expect, loc := #caller_location) {
	testing.expect_value(t, len(got), len(want), loc)
	for w, i in want[:min(len(got), len(want))] {
		g := got[i]
		testing.expectf(t, g.id == w.id && g.cluster == w.cluster && g.advance == w.advance && g.offset == w.offset, "glyph %d: got %v, want %v", i, g, w, loc = loc)
	}
}

@(private = "file")
read_system_font :: proc(path: string) -> []u8 {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		log.infof("%s not found: skipped", path)
		return nil
	}
	return data
}

// Joining forms, right to left, a mark on its base (cluster merged).
@(test)
test_arabic :: proc(t: ^testing.T) {
	out: [dynamic]Glyph
	defer delete(out)
	testing.expect(t, shape_with(arabic, .Arabic, .RTL, "سلامٌ", &out))
	expect_glyphs(t, out[:], {{375, 3, 0, {80, -14}}, {74, 3, 548, {}}, {11, 2, 417, {}}, {71, 1, 264, {}}, {37, 0, 950, {}}})
}

// Contextual alternates (calt) replace "->" and "!=", and turn off.
@(test)
test_calt :: proc(t: ^testing.T) {
	out: [dynamic]Glyph
	defer delete(out)
	testing.expect(t, shape_with(mono, .Latin, .LTR, "a->b != c", &out))
	want := [?]u16{180, 1167, 621, 205, 680, 1167, 646, 680, 206}
	testing.expect_value(t, len(out), len(want))
	for w, i in want[:min(len(out), len(want))] {
		testing.expect_value(t, out[i].id, w)
		testing.expect_value(t, out[i].cluster, i32(i))
	}
	clear(&out)
	off := [?]Feature{{tag = tag("calt"), value = 0}}
	testing.expect(t, shape_with(mono, .Latin, .LTR, "->", &out, nil, off[:]))
	testing.expect(t, len(out) == 2 && out[0].id != 1167)
}

// Reph, pre-base matra and a conjunct (the Indic shaper).
@(test)
test_devanagari :: proc(t: ^testing.T) {
	data := read_system_font("/usr/share/fonts/noto/NotoSansDevanagari-Regular.ttf")
	if data == nil {
		return
	}
	defer delete(data)
	out: [dynamic]Glyph
	defer delete(out)
	testing.expect(t, shape_with(data, .Devanagari, .LTR, "र्कि क्ष", &out))
	expect_glyphs(t, out[:], {{590, 0, 259, {}}, {56, 0, 768, {}}, {785, 0, 0, {}}, {3, 4, 260, {}}, {90, 5, 717, {}}})
}

// Advances and kerning follow the variation instance.
@(test)
test_variations :: proc(t: ^testing.T) {
	data := read_system_font("/usr/share/fonts/Adwaita/AdwaitaSans-Regular.ttf")
	if data == nil {
		return
	}
	defer delete(data)
	out: [dynamic]Glyph
	defer delete(out)
	testing.expect(t, shape_with(data, .Latin, .LTR, "AVo", &out))
	expect_glyphs(t, out[:], {{2, 0, 1273, {}}, {456, 1, 1309, {}}, {790, 2, 1228, {}}})
	clear(&out)
	bold := [?]ft.Variation{{"wght", 800}}
	testing.expect(t, shape_with(data, .Latin, .LTR, "AVo", &out, bold[:]))
	expect_glyphs(t, out[:], {{2, 0, 1406, {}}, {456, 1, 1443, {}}, {790, 2, 1268, {}}})
}

// Truncated fonts and fonts with corrupted layout tables shape without
// reading out of bounds (an out-of-bounds index panics the test).
@(test)
test_corrupt :: proc(t: ^testing.T) {
	Case :: struct {
		data:   []u8,
		script: Script,
		dir:    Direction,
		text:   string,
	}
	cases := [?]Case{{mono, .Latin, .LTR, "a->b != c ffi www"}, {arabic, .Arabic, .RTL, "سلامٌ بِسْمِ لا ١٢"}}
	out: [dynamic]Glyph
	defer delete(out)
	data: [dynamic]u8
	defer delete(data)
	r := rand.create(1)
	gen := rand.default_random_generator(&r)
	for c in cases {
		for size := 0; size < len(c.data); size += 1999 {
			clear(&out)
			shape_with(c.data[:size], c.script, c.dir, c.text, &out)
		}
		f, _ := ft.load(c.data)
		for name in ([?]string{"GSUB", "GPOS", "GDEF"}) {
			at, size := find_table(&f, name)
			if size == 0 {
				continue
			}
			for _ in 0 ..< 300 {
				resize(&data, len(c.data))
				copy(data[:], c.data)
				for _ in 0 ..< 1 + rand.int_max(16, gen) {
					data[at + rand.int_max(size, gen)] = u8(rand.uint32(gen))
				}
				clear(&out)
				shape_with(data[:], c.script, c.dir, c.text, &out)
			}
		}
	}
}

// A variable font with corrupted variation and layout tables shapes and
// draws at an instance without reading out of bounds; gvar and HVAR
// varying over another number of axes than fvar's are ignored.
@(test)
test_corrupt_variable :: proc(t: ^testing.T) {
	font := read_system_font("/usr/share/fonts/Adwaita/AdwaitaSans-Regular.ttf")
	if font == nil {
		return
	}
	defer delete(font)
	bold := [?]ft.Variation{{"wght", 800}}
	out: [dynamic]Glyph
	defer delete(out)
	o: ft.Outline
	defer ft.outline_destroy(&o)
	data := slice.clone(font)
	defer delete(data)
	draw :: proc(data: []u8, variations: []ft.Variation, o: ^ft.Outline) -> (points: [dynamic][2]f32, advance: int) {
		f, err := ft.load(data)
		if err != nil {
			return
		}
		ft.set_variations(&f, variations)
		g := ft.glyph_index(&f, 'A')
		ft.glyph_outline(&f, g, o)
		append(&points, ..o.points[:])
		return points, ft.advance(&f, g)
	}
	r := rand.create(2)
	gen := rand.default_random_generator(&r)
	f, _ := ft.load(font)
	for name in ([?]string{"gvar", "HVAR", "avar", "fvar", "GDEF", "GPOS"}) {
		at, size := find_table(&f, name)
		testing.expect(t, size != 0, name)
		for _ in 0 ..< 200 {
			copy(data, font)
			for _ in 0 ..< 1 + rand.int_max(16, gen) {
				data[at + rand.int_max(min(size, 4096), gen)] = u8(rand.uint32(gen))
			}
			clear(&out)
			shape_with(data, .Latin, .LTR, "AVo ffi", &out, bold[:])
			points, _ := draw(data, bold[:], &o)
			delete(points)
		}
	}
	// gvar and HVAR (its region list) said to vary over three axes.
	plain, plain_advance := draw(font, nil, &o)
	defer delete(plain)
	heavy, heavy_advance := draw(font, bold[:], &o)
	defer delete(heavy)
	testing.expect(t, !slice.equal(plain[:], heavy[:]) && heavy_advance != plain_advance)
	copy(data, font)
	gvar, _ := find_table(&f, "gvar")
	data[gvar + 4], data[gvar + 5] = 0, 3
	hvar, _ := find_table(&f, "HVAR")
	store := hvar + int(ft.read_u32(font, hvar + 4))
	regions := store + int(ft.read_u32(font, store + 2))
	data[regions], data[regions + 1] = 0, 3
	varied, varied_advance := draw(data, bold[:], &o)
	defer delete(varied)
	testing.expect(t, len(plain) > 0 && slice.equal(plain[:], varied[:]))
	testing.expect_value(t, varied_advance, plain_advance)
}
