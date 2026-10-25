package ovg

import "core:mem"
import "core:testing"

import cv "curves"

// Path morphs, text as a path and SVG geometry as a path.

// The fill of `p` at (x, y) under `rule`.
@(private = "file")
filled :: proc(p: ^Path, x, y: f32, rule: Fill_Rule) -> bool {
	s, ok := shape_from_path(p)
	if !ok {
		return false
	}
	defer shape_destroy(&s)
	w := cv.winding(s.data, (Vec2{x, y} - s.origin) / s.extent)
	return w & 1 != 0 if rule == .Even_Odd else w != 0
}

// Total |area| of the polylines of `p` and its contour count.
@(private = "file")
flat_area :: proc(p: ^Path) -> (area: f32, contours: int) {
	f: Flat_Path
	defer flat_path_destroy(&f)
	path_flatten(p, &f)
	for ct in f.contours {
		pts := f.points[ct.first:][:ct.count]
		s: f32 = 0
		for k in 0 ..< len(pts) {
			p0, p1 := pts[k], pts[(k + 1) % len(pts)]
			s += (p1.x - p0.x) * (p1.y + p0.y)
		}
		area += abs(s) * 0.5
	}
	return area, len(f.contours)
}

// A square with square holes (each `{x, y, size}`), the holes wound like
// the outline unless `opposite`.
@(private = "file")
square_with_holes :: proc(p: ^Path, x, y, size: f32, holes: [][3]f32, opposite := true) {
	path_rect(p, x, y, size, size)
	for h in holes {
		if opposite {
			path_append(p, {.Move_To, .Line_To, .Line_To, .Line_To, .Close}, {{h.x, h.y}, {h.x + h.z, h.y}, {h.x + h.z, h.y + h.z}, {h.x, h.y + h.z}})
		} else {
			path_rect(p, h.x, h.y, h.z, h.z)
		}
	}
}

// At t = 0 and t = 1 the morph is its ends: every flattened point of each
// end is in it, and the areas match.
@(test)
test_path_morph_ends :: proc(t: ^testing.T) {
	a, b, out: Path
	defer path_destroy(&a)
	defer path_destroy(&b)
	defer path_destroy(&out)
	m: Path_Morph
	defer path_morph_destroy(&m)
	path_rounded_rect(&a, 10, 10, 80, 60, 12)
	path_circle(&b, 200, 120, 40)
	path_morph_prepare(&m, &a, &b)

	ends := [2]^Path{&a, &b}
	for end, k in ends {
		path_reset(&out)
		path_morph_eval(&m, f32(k), &out)
		want, n := flat_area(end)
		got, gn := flat_area(&out)
		testing.expect_value(t, gn, n)
		testing.expect(t, abs(got - want) < want * 1e-4)
		f: Flat_Path
		defer flat_path_destroy(&f)
		path_flatten(end, &f)
		for q in f.points {
			found := false
			for c in out.coords {
				found ||= abs(c.x - q.x) < 1e-3 && abs(c.y - q.y) < 1e-3
			}
			testing.expect(t, found)
		}
	}
	// Halfway it sits between the two.
	path_reset(&out)
	path_morph_eval(&m, 0.5, &out)
	testing.expect(t, filled(&out, (50 + 200) / 2, (40 + 120) / 2, .Non_Zero))
	testing.expect(t, !filled(&out, 50, 40, .Non_Zero))
}

// Holes stay holes through the morph under both rules, whichever way the
// ends wind them.
@(test)
test_path_morph_holes :: proc(t: ^testing.T) {
	a, b, out: Path
	defer path_destroy(&a)
	defer path_destroy(&b)
	defer path_destroy(&out)
	m: Path_Morph
	defer path_morph_destroy(&m)
	square_with_holes(&a, 0, 0, 100, {{30, 30, 40}})
	// b winds its outline the other way and its hole like the outline:
	// drawn even-odd.
	path_append(&b, {.Move_To, .Line_To, .Line_To, .Line_To, .Close}, {{200, 0}, {300, 0}, {300, 100}, {200, 100}})
	path_append(&b, {.Move_To, .Line_To, .Line_To, .Line_To, .Close}, {{220, 20}, {280, 20}, {280, 80}, {220, 80}})
	path_morph_prepare(&m, &a, &b, .Non_Zero, .Even_Odd)
	testing.expect_value(t, len(m.contours), 2)
	for k in 0 ..= 4 {
		tt := f32(k) / 4
		path_reset(&out)
		path_morph_eval(&m, tt, &out)
		x := 200 * tt
		for rule in Fill_Rule {
			testing.expect(t, !filled(&out, x + 50, 50, rule))
			testing.expect(t, filled(&out, x + 50, 5, rule))
		}
	}

	// The same nested squares wound alike: a hole when drawn even-odd, a
	// solid on a solid (no hole) when drawn non-zero.
	path_reset(&a)
	square_with_holes(&a, 0, 0, 100, {{30, 30, 40}}, opposite = false)
	path_reset(&b)
	path_circle(&b, 50, 50, 50)
	path_morph_prepare(&m, &a, &b, .Even_Odd)
	path_reset(&out)
	path_morph_eval(&m, 0, &out)
	testing.expect(t, !filled(&out, 50, 50, .Non_Zero))
	path_morph_prepare(&m, &a, &b, .Non_Zero)
	path_reset(&out)
	path_morph_eval(&m, 0, &out)
	testing.expect(t, filled(&out, 50, 50, .Non_Zero))
}

// Contours without a partner grow from or shrink to a point: a square with
// one hole -> a disc -> a square with two holes.
@(test)
test_path_morph_contour_counts :: proc(t: ^testing.T) {
	one, disc, two, out: Path
	defer path_destroy(&one)
	defer path_destroy(&disc)
	defer path_destroy(&two)
	defer path_destroy(&out)
	m: Path_Morph
	defer path_morph_destroy(&m)
	square_with_holes(&one, 0, 0, 100, {{35, 35, 30}})
	path_circle(&disc, 50, 50, 50)
	square_with_holes(&two, 0, 0, 100, {{10, 35, 30}, {60, 35, 30}})

	contours :: proc(m: ^Path_Morph, tt: f32, out: ^Path) -> int {
		path_reset(out)
		path_morph_eval(m, tt, out)
		_, n := flat_area(out)
		return n
	}

	path_morph_prepare(&m, &one, &disc)
	testing.expect_value(t, contours(&m, 0, &out), 2)
	testing.expect_value(t, contours(&m, 0.5, &out), 2)
	testing.expect_value(t, contours(&m, 1, &out), 1)
	// The shrinking hole stays in the middle, and is gone at the end.
	path_reset(&out)
	path_morph_eval(&m, 0.5, &out)
	testing.expect(t, !filled(&out, 50, 50, .Non_Zero))
	path_reset(&out)
	path_morph_eval(&m, 1, &out)
	testing.expect(t, filled(&out, 50, 50, .Non_Zero))

	path_morph_prepare(&m, &disc, &two)
	testing.expect_value(t, contours(&m, 0, &out), 1)
	testing.expect_value(t, contours(&m, 0.5, &out), 3)
	testing.expect_value(t, contours(&m, 1, &out), 3)
	area, _ := flat_area(&out)
	want, _ := flat_area(&two)
	testing.expect(t, abs(area - want) < 1)

	// One hole to two: the hole pairs with one of them, the other grows.
	path_morph_prepare(&m, &one, &two)
	pairs, grows := 0, 0
	for ct in m.contours {
		pairs += int(ct.kind == .Pair)
		grows += int(ct.kind == .Grow)
	}
	testing.expect_value(t, pairs, 2)
	testing.expect_value(t, grows, 1)
	path_reset(&out)
	path_morph_eval(&m, 0.75, &out)
	testing.expect(t, filled(&out, 5, 50, .Non_Zero))
	testing.expect(t, !filled(&out, 25, 50, .Non_Zero) || !filled(&out, 75, 50, .Non_Zero))

	// To or from nothing.
	empty: Path
	path_morph_prepare(&m, &empty, &disc)
	testing.expect_value(t, contours(&m, 0, &out), 0)
	testing.expect_value(t, contours(&m, 1, &out), 1)
	path_morph_prepare(&m, &empty, &empty)
	testing.expect_value(t, contours(&m, 0.5, &out), 0)
}

// The start offset that moves the points least: a square morphing into
// itself rotated a quarter turn in its list of points stays put.
@(test)
test_path_morph_no_twist :: proc(t: ^testing.T) {
	a, b, out: Path
	defer path_destroy(&a)
	defer path_destroy(&b)
	defer path_destroy(&out)
	m: Path_Morph
	defer path_morph_destroy(&m)
	path_append(&a, {.Move_To, .Line_To, .Line_To, .Line_To, .Close}, {{0, 0}, {100, 0}, {100, 100}, {0, 100}})
	path_append(&b, {.Move_To, .Line_To, .Line_To, .Line_To, .Close}, {{100, 100}, {0, 100}, {0, 0}, {100, 0}})
	path_morph_prepare(&m, &a, &b)
	for k in 0 ..< len(m.from) {
		testing.expect(t, mag2(m.from[k] - m.to[k]) < 1e-6)
	}
}

// Letters as paths morph into each other: "A" (2 contours) into "B" (3).
@(test)
test_path_morph_text :: proc(t: ^testing.T) {
	fonts: Font_Collection
	font_collection_init(&fonts)
	defer font_collection_destroy(&fonts)
	l: Text_Layout
	defer text_layout_destroy(&l)
	a, b, out: Path
	defer path_destroy(&a)
	defer path_destroy(&b)
	defer path_destroy(&out)
	text_layout(&fonts, {{text = "A", style = {size = 200}}}, {x = 20, y = 200}, &l)
	text_layout_path(&l, &a)
	text_layout(&fonts, {{text = "B", style = {size = 200}}}, {x = 20, y = 200}, &l)
	text_layout_path(&l, &b)
	m: Path_Morph
	defer path_morph_destroy(&m)
	path_morph_prepare(&m, &a, &b)
	for tt in ([?]f32{0, 0.5, 1}) {
		path_reset(&out)
		path_morph_eval(&m, tt, &out)
		_, n := flat_area(&out)
		testing.expect_value(t, n, 2 if tt == 0 else 3)
	}
	want, _ := flat_area(&b)
	got, _ := flat_area(&out)
	testing.expect(t, abs(got - want) < want * 1e-4)

	// Evaluating allocates nothing once the output path is warm.
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	{
		context.allocator = mem.tracking_allocator(&track)
		for k in 0 ..= 20 {
			path_reset(&out)
			path_morph_eval(&m, f32(k) / 20, &out)
		}
	}
	testing.expect_value(t, track.total_allocation_count, 0)
}

// Text as a path fills the pixels drawing the layout fills.
@(test)
test_text_layout_path :: proc(t: ^testing.T) {
	sw: Software_Backend
	software_backend_init(&sw)
	defer software_backend_destroy(&sw)
	c: Canvas
	canvas_init(&c, software_backend(&sw))
	defer canvas_destroy(&c)
	fonts: Font_Collection
	font_collection_init(&fonts)
	defer font_collection_destroy(&fonts)
	l: Text_Layout
	defer text_layout_destroy(&l)
	p, scratch: Path
	defer path_destroy(&p)
	defer path_destroy(&scratch)
	pieces := [?]Text_Piece{{text = "Ag", style = {size = 40, letter_spacing = 3}}, {text = "\nfi", style = {size = 30}}}
	text_layout(&fonts, pieces[:], {x = 60, y = 50, align = .Center, baseline = .Middle}, &l)
	text_layout_path(&l, &p)
	testing.expect(t, !path_is_empty(&p))

	draw :: proc(c: ^Canvas, sw: ^Software_Backend) -> []u8 {
		flush(c)
		return slice_clone(sw.pixels)
	}
	set_size(&c, 120, 100)
	clear_rect(&c, 0, 0, 120, 100, WHITE)
	for run in l.runs {
		fill_glyph_outlines(&c, text_layout_font(&l, run), l.glyphs[run.first:][:run.count], run.em, paint_color(BLACK), &scratch)
	}
	drawn := draw(&c, &sw)
	defer delete(drawn)
	// The glyphs draw as shapes: the path as one shape covers the same
	// pixels (up to rounding: its shape units differ).
	clear_rect(&c, 0, 0, 120, 100, WHITE)
	whole, built := shape_from_path(&p)
	testing.expect(t, built)
	defer shape_destroy(&whole)
	fill_shape(&c, &whole, paint_color(BLACK))
	as_path := draw(&c, &sw)
	defer delete(as_path)
	worst := 0
	for v, k in drawn {
		worst = max(worst, abs(int(v) - int(as_path[k])))
	}
	testing.expectf(t, worst <= 2, "glyphs and their path differ by %v", worst)
	dark := 0
	for k := 0; k < len(drawn); k += 4 {
		dark += int(drawn[k] < 128)
	}
	testing.expect(t, dark > 100)
}

@(private = "file")
slice_clone :: proc(b: []u8) -> []u8 {
	out := make([]u8, len(b))
	copy(out, b)
	return out
}

// An SVG's filled geometry as one path, under its transforms, skipping what
// draws nothing; an element's subtree by id.
@(test)
test_svg_element_path :: proc(t: ^testing.T) {
	markup := `<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="200" height="100" viewBox="0 0 100 50">
	<defs><rect id="tile" width="4" height="4"/></defs>
	<g id="mark" transform="translate(10 5)">
		<rect width="20" height="10"/>
		<circle cx="40" cy="5" r="5" fill-rule="evenodd"/>
		<use xlink:href="#tile" x="60"/>
	</g>
	<rect x="0" y="40" width="5" height="5" display="none"/>
	<rect x="10" y="40" width="5" height="5" visibility="hidden"/>
	<rect x="20" y="40" width="5" height="5" fill="none" stroke="black"/>
	<rect x="30" y="40" width="5" height="5" opacity="0"/>
	<g id="shown"><rect x="90" y="40" width="5" height="5"/></g>
	<g id="spare" display="none"><rect x="40" y="40" width="5" height="5"/><rect x="50" y="40" width="5" height="5" display="none"/></g>
</svg>`
	doc, err := svg_parse(transmute([]u8)string(markup))
	defer svg_destroy(&doc)
	testing.expect_value(t, err, Svg_Error.None)
	p: Path
	defer path_destroy(&p)

	rule, mixed, found := svg_element_path(&doc, &p)
	testing.expect(t, found && mixed)
	_, n := flat_area(&p)
	testing.expect_value(t, n, 4) // the mark's three shapes and the shown rect
	// Document coordinates: the viewBox scales by 2.
	testing.expect(t, filled(&p, 2 * (10 + 10), 2 * (5 + 5), .Non_Zero)) // rect
	testing.expect(t, filled(&p, 2 * (10 + 40), 2 * (5 + 5), .Non_Zero)) // circle
	testing.expect(t, filled(&p, 2 * (10 + 62), 2 * (5 + 2), .Non_Zero)) // use
	testing.expect(t, filled(&p, 2 * 92, 2 * 42, .Non_Zero))
	for x in ([?]f32{2, 12, 22, 32}) {
		testing.expect(t, !filled(&p, 2 * x, 2 * 42, .Non_Zero))
	}

	path_reset(&p)
	rule, mixed, found = svg_element_path(&doc, &p, "shown")
	testing.expect(t, found && !mixed && rule == .Non_Zero)
	_, n = flat_area(&p)
	testing.expect_value(t, n, 1)

	path_reset(&p)
	_, _, found = svg_element_path(&doc, &p, "mark")
	_, n = flat_area(&p)
	testing.expect(t, found)
	testing.expect_value(t, n, 3)
	testing.expect(t, filled(&p, 2 * (10 + 10), 2 * (5 + 5), .Non_Zero))

	// Asked for by id, a display="none" element gives its geometry (not
	// that of its own hidden children).
	path_reset(&p)
	_, _, found = svg_element_path(&doc, &p, "spare")
	_, n = flat_area(&p)
	testing.expect(t, found)
	testing.expect_value(t, n, 1)

	_, _, found = svg_element_path(&doc, &p, "nope")
	testing.expect(t, !found)
}

// SVG text joins the path when the document's layout is given.
@(test)
test_svg_element_path_text :: proc(t: ^testing.T) {
	fonts: Font_Collection
	font_collection_init(&fonts)
	defer font_collection_destroy(&fonts)
	markup := `<svg xmlns="http://www.w3.org/2000/svg" width="200" height="100"><g transform="translate(100 0)"><text id="t" x="10" y="60" font-size="40">Hi</text></g></svg>`
	doc, _ := svg_parse(transmute([]u8)string(markup), {fonts = &fonts})
	defer svg_destroy(&doc)
	text: Svg_Layout
	defer svg_layout_destroy(&text)
	svg_layout(&doc, &fonts, &text)
	p: Path
	defer path_destroy(&p)
	svg_element_path(&doc, &p)
	testing.expect(t, path_is_empty(&p)) // no layout, no text
	rule, mixed, found := svg_element_path(&doc, &p, "t", &text)
	testing.expect(t, found && !mixed && rule == .Non_Zero)
	_, n := flat_area(&p)
	testing.expect(t, n >= 2)
	f: Flat_Path
	defer flat_path_destroy(&f)
	path_flatten(&p, &f)
	for q in f.points {
		testing.expect(t, q.x >= 110 && q.x < 200 && q.y > 20 && q.y <= 60.5)
	}
}

// `segment` sets how finely curves split: a 30-unit cubic is 20 segments at
// the default 1.5 units, 10 at 3, and at least 2 however long they may be.
@(test)
test_path_flatten_segment :: proc(t: ^testing.T) {
	p: Path
	defer path_destroy(&p)
	path_move_to(&p, 0, 0)
	path_bezier_to(&p, 10, 0, 20, 0, 30, 0)
	f: Flat_Path
	defer flat_path_destroy(&f)
	path_flatten(&p, &f)
	testing.expect_value(t, len(f.points), 21)
	path_flatten(&p, &f, 3)
	testing.expect_value(t, len(f.points), 11)
	path_flatten(&p, &f, 100)
	testing.expect_value(t, len(f.points), 3)
}
