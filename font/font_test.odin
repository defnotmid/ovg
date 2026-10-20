package font

import "core:math/rand"
import "core:testing"

@(private = "file")
vera := #load("../assets/Vera.ttf")

// Every query the reader answers, over every glyph and a spread of code
// points: what a corrupt font must survive.
@(private = "file")
read_all :: proc(f: ^Face, o: ^Outline) {
	for g in 0 ..< min(f.glyph_count, 4096) {
		glyph_outline(f, Glyph(g), o)
		glyph_box(f, Glyph(g))
		glyph_empty(f, Glyph(g))
		h_metrics(f, Glyph(g))
		kern(f, Glyph(g), Glyph(g + 1))
	}
	for cp := 0; cp < 0x30000; cp += 7 {
		glyph_index(f, rune(cp))
	}
}

@(test)
test_vera :: proc(t: ^testing.T) {
	f, err := load(vera)
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, f.units_per_em, 2048)
	g := glyph_index(&f, 'A')
	testing.expect(t, g != 0)
	o: Outline
	defer outline_destroy(&o)
	testing.expect(t, glyph_outline(&f, g, &o))
	testing.expect_value(t, o.verbs[0], Verb.Move)
	testing.expect(t, glyph_empty(&f, glyph_index(&f, ' ')))
	testing.expect(t, kern(&f, glyph_index(&f, 'A'), glyph_index(&f, 'V')) < 0)
}

@(test)
test_not_fonts :: proc(t: ^testing.T) {
	_, err := load(nil)
	testing.expect_value(t, err, Error.Not_A_Font)
	_, err = load(transmute([]u8)string("ttcf\x00\x01\x00\x00\x00\x00\x00\x00"))
	testing.expect_value(t, err, Error.No_Face)
	_, err = load(vera, 1)
	testing.expect_value(t, err, Error.No_Face)
}

// Truncated and corrupted copies of a font load with an error or read
// without going out of bounds (an out-of-bounds index panics the test).
@(test)
test_corrupt :: proc(t: ^testing.T) {
	o: Outline
	defer outline_destroy(&o)
	for size := 0; size < len(vera); size += 997 {
		if f, err := load(vera[:size]); err == nil {
			read_all(&f, &o)
		}
	}
	data := make([]u8, len(vera))
	defer delete(data)
	r := rand.create(1)
	for _ in 0 ..< 200 {
		copy(data, vera)
		for _ in 0 ..< 1 + rand.int_max(64, rand.default_random_generator(&r)) {
			data[rand.int_max(len(data), rand.default_random_generator(&r))] = u8(rand.uint32(rand.default_random_generator(&r)))
		}
		if f, err := load(data); err == nil {
			read_all(&f, &o)
		}
	}
}
