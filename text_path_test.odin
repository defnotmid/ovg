package ovg

import "core:testing"

@(private = "file")
near :: proc(a, b: Vec2) -> bool {
	return abs(a.x - b.x) < 1e-3 && abs(a.y - b.y) < 1e-3
}

@(test)
test_text_on_path :: proc(t: ^testing.T) {
	fonts: Font_Collection
	font_collection_init(&fonts)
	defer font_collection_destroy(&fonts)
	l: Text_Layout
	text_layout_init(&l)
	defer text_layout_destroy(&l)
	tp: Text_Path
	text_path_init(&tp)
	defer text_path_destroy(&tp)
	path: Path
	path_init(&path)
	defer path_destroy(&path)

	pieces := [?]Text_Piece{{text = "AVA", style = {size = 20}}}
	text_layout(&fonts, pieces[:], {}, &l)
	straight := [3]Vec2{l.glyphs[0].x, l.glyphs[1].x, l.glyphs[2].x}

	// Along a horizontal line from (10, 50): moved by the line's start, not
	// turned.
	path_move_to(&path, 10, 50)
	path_line_to(&path, 200, 50)
	text_path_set(&tp, &path)
	testing.expect_value(t, text_path_length(&tp), 190)
	text_layout_on_path(&l, &tp, {})
	for g, i in l.glyphs {
		testing.expect(t, near({g.x, g.y}, {10 + straight[i].x, 50}))
		testing.expect(t, near(l.turns[i], {1, 0}))
	}
	testing.expect(t, l.min.y < 50 && l.max.y > 50)

	// Down a vertical line: turned a quarter, x along it becoming y.
	text_layout(&fonts, pieces[:], {}, &l)
	path_reset(&path)
	path_move_to(&path, 30, 0)
	path_line_to(&path, 30, 300)
	text_path_set(&tp, &path)
	text_layout_on_path(&l, &tp, {start = 5})
	for g, i in l.glyphs {
		testing.expect(t, near({g.x, g.y}, {30, 5 + straight[i].x}))
		testing.expect(t, near(l.turns[i], {0, 1}))
	}

	// Off the end: a glyph whose middle falls past it is hidden. Two
	// contours: the move between them adds no distance.
	text_layout(&fonts, pieces[:], {}, &l)
	path_reset(&path)
	path_move_to(&path, 0, 0)
	path_line_to(&path, 10, 0)
	path_move_to(&path, 100, 100)
	path_line_to(&path, 100, 110)
	text_path_set(&tp, &path)
	testing.expect_value(t, text_path_length(&tp), 20)
	p, dir, ok := text_path_at(&tp, 15)
	testing.expect(t, ok && near(p, {100, 105}) && near(dir, {0, 1}))
	_, _, ok = text_path_at(&tp, 21)
	testing.expect(t, !ok)
	text_layout_on_path(&l, &tp, {})
	testing.expect(t, l.turns[2] == {})

	// side = right runs from the path's end, turned around.
	text_layout(&fonts, pieces[:], {}, &l)
	path_reset(&path)
	path_move_to(&path, 0, 50)
	path_line_to(&path, 200, 50)
	text_path_set(&tp, &path)
	text_layout_on_path(&l, &tp, {side = .Right})
	testing.expect(t, near({l.glyphs[0].x, l.glyphs[0].y}, {200 - straight[0].x, 50}))
	testing.expect(t, near(l.turns[0], {-1, 0}))

	// The outlines turn with the glyphs: upside down below the line.
	out: Path
	path_init(&out)
	defer path_destroy(&out)
	text_layout_path(&l, &out)
	box := svg_path_bbox(out.verbs[:], out.coords[:])
	testing.expect(t, box.y >= 50 - 1e-3 && box.y + box.h > 60)
}
