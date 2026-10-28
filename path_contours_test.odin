package ovg

import "core:slice"
import "core:testing"

import cv "deps:ocurves"

// The path calls keep the table the way fill reads it.
@(test)
test_path_contours_rules :: proc(t: ^testing.T) {
	p: Path
	defer path_destroy(&p)

	// Drawing before the first move goes nowhere; a lone move is a contour
	// without segments; a close at the start adds no line but closes.
	path_line_to(&p, 5, 5)
	testing.expect(t, path_is_empty(&p))
	path_move_to(&p, 0, 0)
	path_move_to(&p, 1, 1)
	path_line_to(&p, 4, 1)
	path_line_to(&p, 1, 1)
	path_close(&p)
	testing.expect_value(t, len(p.contours), 2)
	testing.expect_value(t, p.contours[0].segs, 0)
	testing.expect(t, p.contours[1].segs == 2 && p.contours[1].closed)
	testing.expect_value(t, path_pen(&p), Vec2{1, 1})

	// Drawing after a close starts a new contour where the closed one
	// started, and the close's line of non-zero length is a segment.
	path_reset(&p)
	path_move_to(&p, 0, 0)
	path_line_to(&p, 4, 0)
	path_line_to(&p, 4, 4)
	path_close(&p)
	path_line_to(&p, -3, 2)
	testing.expect_value(t, len(p.contours), 2)
	testing.expect(t, p.contours[0].segs == 3 && p.contours[0].closed)
	testing.expect_value(t, p.pts[3], Vec2{0, 0})
	testing.expect_value(t, p.pts[p.contours[1].start], Vec2{0, 0})
	testing.expect_value(t, path_pen(&p), Vec2{-3, 2})
	// A quadratic is the cubic it is.
	path_quad_to(&p, 0, 6, 3, 2)
	testing.expect_value(t, p.kinds[len(p.kinds) - 1], cv.Seg_Kind.Cubic)
	testing.expect_value(t, path_pen(&p), Vec2{3, 2})
	// A second close does nothing.
	path_close(&p)
	n := len(p.pts)
	path_close(&p)
	testing.expect_value(t, len(p.pts), n)
}

// Appending copies contours, the whole path or a range, under a transform;
// a path may take its own contours. Truncating keeps the first ones.
@(test)
test_path_append :: proc(t: ^testing.T) {
	p, q: Path
	defer path_destroy(&p)
	defer path_destroy(&q)
	path_move_to(&p, 1, 2)
	path_line_to(&p, 10, 2)
	path_bezier_to(&p, 12, 4, 12, 8, 10, 10)
	path_close(&p)
	path_move_to(&p, 20, 20)
	path_line_to(&p, 30, 25)
	path_append(&q, &p)
	testing.expect(t, slice.equal(q.pts[:], p.pts[:]) && slice.equal(q.kinds[:], p.kinds[:]))
	testing.expect(t, slice.equal(q.contours[:], p.contours[:]))
	path_append_contours(&q, &p, 1, 1, transform_translation(10, 0))
	testing.expect_value(t, len(q.contours), 3)
	testing.expect_value(t, q.pts[q.contours[2].start], Vec2{30, 20})
	testing.expect_value(t, path_pen(&q), Vec2{40, 25})
	path_append(&q, &q)
	testing.expect_value(t, len(q.contours), 6)
	testing.expect(t, slice.equal(q.pts[q.contours[3].start:], q.pts[:q.contours[3].start]))
	path_truncate(&q, 2)
	testing.expect(t, slice.equal(q.pts[:], p.pts[:]) && slice.equal(q.contours[:], p.contours[:]))
}

// Solid and Hole wind the current contour as it stands, open or closed.
@(test)
test_path_solidity :: proc(t: ^testing.T) {
	p: Path
	defer path_destroy(&p)
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
				a := cv.contours_area(&p, 0)
				testing.expectf(t, (a > 0) == (solidity == .Solid), "%v after_close=%v flip=%v: area %v", solidity, after_close, flip, a)
				testing.expect(t, p.contours[0].closed && p.pts[len(p.pts) - 1] == p.pts[0])
			}
		}
	}
}
