package ovg

import "core:testing"

// A small scene using every table the check reads: a square path, a solid
// paint, a mask drawn from a fill, main drawing a clipped fill and a masked
// layer.
@(private = "file")
scene_sample :: proc(s: ^Scene) -> (square: Path_Id, t: Transform_Id, paint: Paint_Id, mask: Mask_Id) {
	scene_init(s)
	t = scene_add_transform(s, TRANSFORM_IDENTITY)
	square = scene_add_path(s, {.Move, .Line, .Line, .Line, .Close}, {{0, 0}, {10, 0}, {10, 10}, {0, 10}})
	paint = scene_add_paint(s, Scene_Solid{{1, 0, 0, 1}})
	// The mask's draws first, outside main.
	at := u32(len(s.draws))
	append(&s.draws, Scene_Fill{path = square, transform = t, look = scene_look(paint)})
	append(&s.masks, Scene_Mask{draws = {at, 1}, read = .Luminance})
	mask = Mask_Id(len(s.masks))
	scene_draw(s, Clip_Push{Clip_Rect{0, 0, 8, 8}})
	scene_draw(s, Scene_Fill{path = square, transform = t, look = scene_look(paint)})
	scene_draw(s, Clip_Pop{})
	scene_draw(s, Layer_Push{opacity = 0.5, mask = mask})
	scene_draw(s, Clip_Push{Clip_Path{square, t, .Even_Odd}})
	scene_draw(s, Scene_Fill{path = square, transform = t, look = scene_look(paint)})
	scene_draw(s, Clip_Pop{})
	scene_draw(s, Layer_Pop{})
	return
}

@(test)
test_scene_check_accepts :: proc(t: ^testing.T) {
	s: Scene
	scene_sample(&s)
	defer scene_destroy(&s)
	p := scene_check(&s)
	testing.expectf(t, p.error == .None, "a well-formed scene: %v", p)
	testing.expect_value(t, s.main, Range{1, 8})
	testing.expect_value(t, s.paths[0].bounds, Bounds{0, 0, 10, 10})
}

// Zero is never a row: a draw left at its zero value names no path, so the
// check rejects it rather than drawing row 0; an optional handle at zero is
// none. A look's zero opacity is transparent; scene_look's is 1.
@(test)
test_scene_zero_handles :: proc(t: ^testing.T) {
	s: Scene
	_, _, paint, _ := scene_sample(&s)
	defer scene_destroy(&s)
	scene_draw(&s, Scene_Fill{})
	p := scene_check(&s)
	testing.expect_value(t, p, Scene_Problem{.Missing_Handle, .Draws, len(s.draws) - 1})
	look := scene_look(paint)
	testing.expect(t, look.mask == 0 && look.motion == 0 && look.opacity == 1)
	testing.expect_value(t, Scene_Look{}.opacity, 0)
}

@(test)
test_scene_check_rejects :: proc(t: ^testing.T) {
	Case :: enum {
		Handle_Past_Table,
		Path_Points,
		Mask_Range,
		Pop_Without_Push,
		Crossed_Nesting,
		Unclosed_In_Mask,
		Image_Handle,
	}
	for c in Case {
		s: Scene
		square, tr, paint, _ := scene_sample(&s)
		want: Scene_Problem
		switch c {
		case .Handle_Past_Table:
			scene_draw(&s, Scene_Fill{path = square, transform = tr, look = scene_look(paint + 5)})
			want = {.Handle_Out_Of_Range, .Draws, len(s.draws) - 1}
		case .Path_Points:
			append(&s.verbs, Path_Verb.Quad)
			append(&s.paths, Scene_Path{verbs = {u32(len(s.verbs) - 1), 1}, points = {0, 1}})
			want = {.Path_Points_Mismatch, .Paths, len(s.paths) - 1}
		case .Mask_Range:
			append(&s.masks, Scene_Mask{draws = {0, 100}})
			want = {.Range_Out_Of_Bounds, .Masks, len(s.masks) - 1}
		case .Pop_Without_Push:
			scene_draw(&s, Clip_Pop{})
			want = {.Unbalanced, .Draws, len(s.draws) - 1}
		case .Crossed_Nesting:
			scene_draw(&s, Clip_Push{Clip_Rect{0, 0, 4, 4}})
			scene_draw(&s, Layer_Push{opacity = 1})
			scene_draw(&s, Clip_Pop{})
			scene_draw(&s, Layer_Pop{})
			want = {.Unbalanced, .Draws, len(s.draws) - 2}
		case .Unclosed_In_Mask:
			// Balanced in main is not enough: each range on its own.
			at := u32(len(s.draws))
			append(&s.draws, Clip_Push{Clip_Rect{0, 0, 2, 2}})
			append(&s.masks, Scene_Mask{draws = {at, 1}})
			s.main = {1, 8}
			want = {.Unbalanced, .Draws, int(at)}
		case .Image_Handle:
			scene_add_paint(&s, Scene_Image_Paint{image = 0, transform = tr})
			want = {.Missing_Handle, .Paints, len(s.paints) - 1}
		}
		testing.expectf(t, scene_check(&s) == want, "%v: %v, wanted %v", c, scene_check(&s), want)
		scene_destroy(&s)
	}
}

// A mask's draws may name only masks and patterns whose draws come before
// its own in `draws`: itself, a later one, or a cycle through a pattern is
// rejected; main may name any.
@(test)
test_scene_dependency_order :: proc(t: ^testing.T) {
	{
		// A mask whose draw names itself.
		s: Scene
		square, tr, paint, _ := scene_sample(&s)
		at := u32(len(s.draws))
		self := Mask_Id(len(s.masks) + 1)
		look := scene_look(paint)
		look.mask = self
		append(&s.draws, Scene_Fill{path = square, transform = tr, look = look})
		append(&s.masks, Scene_Mask{draws = {at, 1}})
		s.main = {1, 8}
		testing.expect_value(t, scene_check(&s), Scene_Problem{.Dependency_Order, .Draws, int(at)})
		scene_destroy(&s)
	}
	{
		// A pattern cell under a mask whose draws paint with that pattern:
		// a cycle through both tables.
		s: Scene
		square, tr, paint, _ := scene_sample(&s)
		cell_at := u32(len(s.draws))
		mask := Mask_Id(len(s.masks) + 1)
		look := scene_look(paint)
		look.mask = mask
		append(&s.draws, Scene_Fill{path = square, transform = tr, look = look})
		append(&s.patterns, Pattern_Cell{draws = {cell_at, 1}, transform = tr, step = {10, 10}})
		pattern_paint := scene_add_paint(&s, Scene_Pattern_Paint{pattern = Pattern_Id(len(s.patterns))})
		mask_at := u32(len(s.draws))
		append(&s.draws, Scene_Fill{path = square, transform = tr, look = scene_look(pattern_paint)})
		append(&s.masks, Scene_Mask{draws = {mask_at, 1}})
		s.main = {1, 8}
		testing.expect_value(t, scene_check(&s), Scene_Problem{.Dependency_Order, .Draws, int(cell_at)})
		scene_destroy(&s)
	}
	{
		// The same pattern without the mask: its draws come before the
		// draw that paints with it, so it's accepted, and main may name a
		// mask defined after it.
		s: Scene
		square, tr, paint, _ := scene_sample(&s)
		cell_at := u32(len(s.draws))
		append(&s.draws, Scene_Fill{path = square, transform = tr, look = scene_look(paint)})
		append(&s.patterns, Pattern_Cell{draws = {cell_at, 1}, transform = tr, step = {10, 10}})
		pattern_paint := scene_add_paint(&s, Scene_Pattern_Paint{pattern = Pattern_Id(len(s.patterns))})
		mask_at := u32(len(s.draws))
		append(&s.draws, Scene_Fill{path = square, transform = tr, look = scene_look(pattern_paint)})
		append(&s.masks, Scene_Mask{draws = {mask_at, 1}})
		s.main = {1, 8}
		testing.expect_value(t, scene_check(&s), Scene_Problem{})
		scene_destroy(&s)
	}
}

// Clearing keeps the tables' room, so a scene rebuilt each frame allocates
// nothing once warm.
@(test)
test_scene_clear_keeps_room :: proc(t: ^testing.T) {
	s: Scene
	scene_sample(&s)
	defer scene_destroy(&s)
	room := cap(s.draws)
	scene_clear(&s)
	testing.expect_value(t, len(s.draws), 0)
	testing.expect_value(t, cap(s.draws), room)
	testing.expect_value(t, s.main, Range{})
}
