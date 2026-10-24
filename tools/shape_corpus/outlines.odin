package shape_corpus

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:slice"
import ft "../../font"

foreign import hb "system:harfbuzz"

// -outlines: compares ovg/font's glyph outlines (at the instance set with
// -var or -var-random) with HarfBuzz's drawing of the same glyphs: the
// points each emits, sorted (start points and contour order may differ),
// within 1/64 unit, and the advances.

HB_Draw_Funcs :: struct {}
HB_Draw_State :: struct {}

@(default_calling_convention = "c")
foreign hb {
	hb_draw_funcs_create :: proc() -> ^HB_Draw_Funcs ---
	hb_draw_funcs_destroy :: proc(funcs: ^HB_Draw_Funcs) ---
	hb_draw_funcs_set_move_to_func :: proc(funcs: ^HB_Draw_Funcs, f: proc "c" (^HB_Draw_Funcs, rawptr, ^HB_Draw_State, f32, f32, rawptr), user: rawptr, destroy: rawptr) ---
	hb_draw_funcs_set_line_to_func :: proc(funcs: ^HB_Draw_Funcs, f: proc "c" (^HB_Draw_Funcs, rawptr, ^HB_Draw_State, f32, f32, rawptr), user: rawptr, destroy: rawptr) ---
	hb_draw_funcs_set_quadratic_to_func :: proc(funcs: ^HB_Draw_Funcs, f: proc "c" (^HB_Draw_Funcs, rawptr, ^HB_Draw_State, f32, f32, f32, f32, rawptr), user: rawptr, destroy: rawptr) ---
	hb_draw_funcs_set_cubic_to_func :: proc(funcs: ^HB_Draw_Funcs, f: proc "c" (^HB_Draw_Funcs, rawptr, ^HB_Draw_State, f32, f32, f32, f32, f32, f32, rawptr), user: rawptr, destroy: rawptr) ---
	hb_font_draw_glyph :: proc(font: ^HB_Font, glyph: u32, funcs: ^HB_Draw_Funcs, draw_data: rawptr) ---
	hb_font_get_glyph_h_advance :: proc(font: ^HB_Font, glyph: u32) -> i32 ---
}

hb_move :: proc "c" (_: ^HB_Draw_Funcs, data: rawptr, _: ^HB_Draw_State, x, y: f32, _: rawptr) {
	pts := (^[dynamic][2]f32)(data)
	context = runtime.default_context()
	append(pts, [2]f32{x, y})
}

hb_quad :: proc "c" (_: ^HB_Draw_Funcs, data: rawptr, _: ^HB_Draw_State, cx, cy, x, y: f32, _: rawptr) {
	pts := (^[dynamic][2]f32)(data)
	context = runtime.default_context()
	append(pts, [2]f32{cx, cy}, [2]f32{x, y})
}

hb_cubic :: proc "c" (_: ^HB_Draw_Funcs, data: rawptr, _: ^HB_Draw_State, c1x, c1y, c2x, c2y, x, y: f32, _: rawptr) {
	pts := (^[dynamic][2]f32)(data)
	context = runtime.default_context()
	append(pts, [2]f32{c1x, c1y}, [2]f32{c2x, c2y}, [2]f32{x, y})
}

// Points this close count as the same (font units).
TOLERANCE :: 1.0 / 64

Outline_Counts :: struct {
	glyphs, outline_diffs, advance_diffs: int,
	max_error:                            f32,
}

compare_outlines :: proc(name: string, face: ^ft.Face, hfont: ^HB_Font, shown: ^int) -> (c: Outline_Counts) {
	funcs := hb_draw_funcs_create()
	defer hb_draw_funcs_destroy(funcs)
	hb_draw_funcs_set_move_to_func(funcs, hb_move, nil, nil)
	hb_draw_funcs_set_line_to_func(funcs, hb_move, nil, nil)
	hb_draw_funcs_set_quadratic_to_func(funcs, hb_quad, nil, nil)
	hb_draw_funcs_set_cubic_to_func(funcs, hb_cubic, nil, nil)
	o: ft.Outline
	defer ft.outline_destroy(&o)
	theirs := make([dynamic][2]f32)
	ours := make([dynamic][2]f32)
	defer delete(theirs)
	defer delete(ours)
	less :: proc(a, b: [2]f32) -> bool {
		return a.x < b.x || (a.x == b.x && a.y < b.y)
	}
	for g in 0 ..< face.glyph_count {
		c.glyphs += 1
		clear(&theirs)
		hb_font_draw_glyph(hfont, u32(g), funcs, &theirs)
		clear(&ours)
		if ft.glyph_outline(face, ft.Glyph(g), &o) {
			append(&ours, ..o.points[:])
		}
		slice.sort_by(theirs[:], less)
		slice.sort_by(ours[:], less)
		// Each of our points must have a point of theirs within the
		// tolerance (both sorted by x, so the search is a window).
		bad := len(theirs) != len(ours)
		if !bad {
			used := make([]bool, len(theirs), context.temp_allocator)
			lo := 0
			for p in ours {
				for lo < len(theirs) && theirs[lo].x < p.x - TOLERANCE {
					lo += 1
				}
				found := false
				for k := lo; k < len(theirs) && theirs[k].x <= p.x + TOLERANCE; k += 1 {
					if !used[k] && math.abs(theirs[k].y - p.y) <= TOLERANCE {
						used[k] = true
						found = true
						c.max_error = max(c.max_error, math.abs(theirs[k].x - p.x), math.abs(theirs[k].y - p.y))
						break
					}
				}
				if !found {
					bad = true
					break
				}
			}
		}
		if bad {
			c.outline_diffs += 1
			if shown^ < opts.show {
				shown^ += 1
				fmt.printfln("== %s glyph %d: ovg %d points, hb %d", name, g, len(ours), len(theirs))
				first := 0
				for first < min(len(ours), len(theirs)) && max(math.abs(ours[first].x - theirs[first].x), math.abs(ours[first].y - theirs[first].y)) <= 1.0 / 64 {
					first += 1
				}
				for i in max(first - 2, 0) ..< min(max(len(ours), len(theirs)), first + 6) {
					a := ours[i] if i < len(ours) else {}
					b := theirs[i] if i < len(theirs) else {}
					fmt.printfln("   %d: %v  %v", i, a, b)
				}
			}
		}
		if a, b := i32(ft.advance(face, ft.Glyph(g))), hb_font_get_glyph_h_advance(hfont, u32(g)); a != b {
			c.advance_diffs += 1
			if shown^ < opts.show {
				shown^ += 1
				fmt.printfln("== %s glyph %d: advance ovg %d, hb %d", name, g, a, b)
			}
		}
	}
	return
}
