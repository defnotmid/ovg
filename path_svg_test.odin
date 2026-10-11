package ovg

import "core:testing"

// ---- svg paths --------------------------------------------------------------------

@(test)
test_svg_path :: proc(t: ^testing.T) {
	p: Path
	defer path_destroy(&p)
	testing.expect(t, path_svg(&p, "M10,10 h20 v20 H10 z m 5 5 l1-1 1e1,2.5"))
	testing.expect_value(t, p.verbs[0], Verb.Move_To)
	testing.expect_value(t, p.coords[1], Vec2{30, 10})
	testing.expect_value(t, p.coords[2], Vec2{30, 30})
	// After `z` the relative move starts from the subpath start.
	testing.expect_value(t, p.coords[4], Vec2{15, 15})
	testing.expect_value(t, p.coords[6], Vec2{26, 16.5})

	path_reset(&p)
	testing.expect(t, path_svg(&p, "M0 0 A10 10 0 0 1 20 0"))
	end := p.coords[len(p.coords) - 1]
	testing.expect_value(t, end, Vec2{20, 0})
	// A half circle of radius 10 sweeping clockwise bulges up (negative y).
	mid := p.coords[3]
	testing.expect(t, abs(mid.x - 10) < 0.01 && abs(mid.y + 10) < 0.01)

	// A drawing command after `z` opens a new subpath at the start point.
	path_reset(&p)
	testing.expect(t, path_svg(&p, "M10 10 H50 V50 Z L90 10"))
	testing.expect_value(t, p.verbs[3], Verb.Close)
	testing.expect_value(t, p.verbs[4], Verb.Move_To)
	testing.expect_value(t, p.coords[3], Vec2{10, 10})
	testing.expect_value(t, p.verbs[5], Verb.Line_To)

	path_reset(&p)
	testing.expect(t, path_svg(&p, "M0 0 a5 5 0 1010 0"))
	testing.expect(t, !path_svg(&p, "M0 0 L 5"))
}


@(test)
test_transform_svg :: proc(t: ^testing.T) {
	near :: proc(a, b: Transform2D) -> bool {
		for i in 0 ..< 6 {
			if abs(a[i] - b[i]) > 1e-4 {
				return false
			}
		}
		return true
	}
	m, ok := transform_svg("matrix(1 2 3 4 5 6)")
	testing.expect(t, ok && m == Transform2D{1, 2, 3, 4, 5, 6})
	m, ok = transform_svg("  ")
	testing.expect(t, ok && m == TRANSFORM_IDENTITY)

	// Left to right: translate applies last, so the scaled point moves.
	m, ok = transform_svg("translate(10, 20) scale(2)")
	testing.expect(t, ok)
	testing.expect_value(t, transform_point(m, 1, 1), Vec2{12, 22})
	m, ok = transform_svg("scale(2,3)translate(10)")
	testing.expect(t, ok)
	testing.expect_value(t, transform_point(m, 1, 1), Vec2{22, 3})

	// rotate about a point keeps it fixed.
	m, ok = transform_svg("rotate(90 50 50)")
	testing.expect(t, ok)
	p := transform_point(m, 50, 50)
	testing.expect(t, abs(p.x - 50) < 1e-4 && abs(p.y - 50) < 1e-4)
	p = transform_point(m, 60, 50)
	testing.expect(t, abs(p.x - 50) < 1e-4 && abs(p.y - 60) < 1e-4)

	m, ok = transform_svg("skewX(45) skewY(0)")
	testing.expect(t, ok && near(m, {1, 0, 1, 1, 0, 0}))

	for bad in ([]string{"matrix(1 2 3)", "scale()", "foo(1)", "translate(1", "rotate(1 2)", "translate 1"}) {
		_, ok = transform_svg(bad)
		testing.expectf(t, !ok, "%q parsed", bad)
	}
}
