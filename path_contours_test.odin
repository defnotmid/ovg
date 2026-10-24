package ovg

import "core:slice"
import "core:testing"

import cv "curves"

@(private = "file")
to_contours :: proc(p: ^Path, c: ^cv.Contours, verbs: ^[dynamic]u32 = nil) {
	cv.contours_clear(c)
	contours_append_path(c, p, verbs = verbs)
}

@(test)
test_path_contours_round_trip :: proc(t: ^testing.T) {
	p, q: Path
	defer path_destroy(&p)
	defer path_destroy(&q)
	c: cv.Contours
	defer cv.contours_destroy(&c)
	// Normalized: every contour moves first, closed ones end with Close.
	path_move_to(&p, 1, 2)
	path_line_to(&p, 10, 2)
	path_bezier_to(&p, 12, 4, 12, 8, 10, 10)
	path_close(&p)
	path_move_to(&p, 20, 20)
	path_line_to(&p, 30, 25)
	path_bezier_to(&p, 31, 26, 32, 27, 33, 20)
	to_contours(&p, &c)
	testing.expect_value(t, len(c.contours), 2)
	testing.expect(t, c.contours[0].closed && !c.contours[1].closed)
	testing.expect(t, slice.equal(c.kinds[:], []cv.Seg_Kind{.Line, .Cubic, .Line, .Line, .Cubic}))
	path_append_contours(&q, &c, 0, 2)
	testing.expect(t, slice.equal(q.verbs[:], p.verbs[:]))
	testing.expect(t, slice.equal(q.coords[:], p.coords[:]))
	testing.expect_value(t, q.last_pos, Vec2{33, 20})
}

@(test)
test_path_contours_rules :: proc(t: ^testing.T) {
	p: Path
	defer path_destroy(&p)
	c: cv.Contours
	defer cv.contours_destroy(&c)
	verbs: [dynamic]u32
	defer delete(verbs)

	// Drawing before the first Move_To is skipped; a lone Move_To stores
	// nothing; a zero-length close adds no row.
	path_line_to(&p, 5, 5)
	path_move_to(&p, 0, 0)
	path_move_to(&p, 1, 1)
	path_line_to(&p, 4, 1)
	path_line_to(&p, 1, 1)
	path_close(&p)
	to_contours(&p, &c, &verbs)
	testing.expect_value(t, len(c.contours), 1)
	testing.expect_value(t, c.contours[0].segs, 2)
	testing.expect(t, c.contours[0].closed)
	testing.expect(t, slice.equal(verbs[:], []u32{3, 4}))

	// Drawing after Close starts a new contour at the last start, and the
	// closing line of non-zero length is a row.
	path_reset(&p)
	clear(&verbs)
	path_move_to(&p, 0, 0)
	path_line_to(&p, 4, 0)
	path_line_to(&p, 4, 4)
	path_close(&p)
	path_line_to(&p, -3, 2)
	to_contours(&p, &c, &verbs)
	testing.expect_value(t, len(c.contours), 2)
	testing.expect_value(t, c.contours[0].segs, 3)
	testing.expect_value(t, c.pts[c.contours[1].start], Vec2{0, 0})
	testing.expect_value(t, c.pts[len(c.pts) - 1], Vec2{-3, 2})
	testing.expect(t, slice.equal(verbs[:], []u32{1, 2, 3, 4}))

	// A transform applies to every point.
	contours_append_path(&c, &p, transform_translation(10, 0))
	testing.expect_value(t, c.pts[c.contours[2].start], Vec2{10, 0})
}

// Solid and Hole wind the contour as fill does, open or closed.
@(test)
test_path_contours_solidity :: proc(t: ^testing.T) {
	p: Path
	defer path_destroy(&p)
	c: cv.Contours
	defer cv.contours_destroy(&c)
	area :: proc(c: ^cv.Contours, i: int) -> f32 {
		ct := c.contours[i]
		a: f32
		for s in 0 ..< ct.segs {
			q := c.pts[ct.start + 3 * s:][:4]
			a += cv.cubic_area([4][2]f32{q[0], q[1], q[2], q[3]})
		}
		return a
	}
	for solidity in ([2]Solidity{.Solid, .Hole}) {
		for after_close in ([2]bool{false, true}) {
			for flip in ([2]bool{false, true}) {
				path_reset(&p)
				path_move_to(&p, 0, 0)
				if flip {
					path_line_to(&p, 0, 5)
					path_line_to(&p, 5, 5)
					path_line_to(&p, 5, 0)
				} else {
					path_line_to(&p, 5, 0)
					path_line_to(&p, 5, 5)
					path_line_to(&p, 0, 5)
				}
				if after_close {
					path_close(&p)
					path_solidity(&p, solidity)
				} else {
					path_solidity(&p, solidity)
					path_close(&p)
				}
				to_contours(&p, &c)
				a := area(&c, 0)
				testing.expectf(t, (a > 0) == (solidity == .Solid), "%v after_close=%v flip=%v: area %v", solidity, after_close, flip, a)
			}
		}
	}
}

// Filling a path and filling it through the table give the same shape:
// byte for byte where no contour is reversed; a reversed one (Hole) is cut
// into quadratics from its other end, so its words differ in last bits and
// only its winding is compared.
@(test)
test_path_contours_fill_unchanged :: proc(t: ^testing.T) {
	c: cv.Contours
	defer cv.contours_destroy(&c)
	for k in 0 ..< 2 {
		p, q: Path
		defer path_destroy(&p)
		defer path_destroy(&q)
		path_rect(&p, 0, 0, 40, 30)
		path_rounded_rect(&p, 50, 0, 30, 30, 8)
		path_ellipse(&p, 100, 15, 12, 6)
		path_move_to(&p, 0, 50)
		path_bezier_to(&p, 30, 20, 60, 90, 90, 50)
		path_line_to(&p, 45, 80)
		if k == 1 {
			path_circle(&p, 20, 15, 10)
			path_solidity(&p, .Hole)
		}
		to_contours(&p, &c)
		path_append_contours(&q, &c, 0, u32(len(c.contours)))
		a, aok := shape_from_path(&p)
		defer shape_destroy(&a)
		b, bok := shape_from_path(&q)
		defer shape_destroy(&b)
		testing.expect(t, aok && bok)
		if k == 0 {
			testing.expect(t, slice.equal(a.data, b.data))
			continue
		}
		for y := f32(-4.37); y < 95; y += 1.3 {
			for x := f32(-4.37); x < 120; x += 1.3 {
				wa := cv.winding(a.data, (Vec2{x, y} - a.origin) / a.extent)
				wb := cv.winding(b.data, (Vec2{x, y} - b.origin) / b.extent)
				testing.expectf(t, wa == wb, "winding at %v, %v: %d vs %d", x, y, wa, wb)
			}
		}
	}
}
