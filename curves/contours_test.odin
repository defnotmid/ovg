package curves

import "core:math"
import "core:testing"

// A circle of four quarter cubics has area pi r^2 within the cubic
// approximation's error, positive when it winds as Solid; reversing a
// contour flips its area and the order of its kinds.
@(test)
test_contours_area_and_reverse :: proc(t: ^testing.T) {
	c: Contours
	defer contours_destroy(&c)
	K :: 0.5522848
	r: f32 = 10
	contours_begin(&c, {r, 0})
	contours_cubic(&c, {r, r * K}, {r * K, r}, {0, r})
	contours_cubic(&c, {-r * K, r}, {-r, r * K}, {-r, 0})
	contours_line(&c, {0, -r})
	contours_line(&c, {r, 0})
	contours_end(&c, true, false)
	area :: proc(c: ^Contours) -> f64 {
		a: f64
		ct := c.contours[0]
		for s in 0 ..< ct.segs {
			q := c.pts[ct.start + 3 * s:][:4]
			a += cubic_area([4][2]f64{{f64(q[0].x), f64(q[0].y)}, {f64(q[1].x), f64(q[1].y)}, {f64(q[2].x), f64(q[2].y)}, {f64(q[3].x), f64(q[3].y)}})
		}
		return a
	}
	// Half a circle plus the triangle under the two lines.
	want := f64(math.PI) * 100 / 2 + 100
	a := area(&c)
	testing.expectf(t, abs(abs(a) - want) < 0.05, "area %v, want %v", a, want)
	contours_reverse(&c, 0)
	testing.expect(t, abs(area(&c) + a) < 1e-9)
	testing.expect_value(t, c.kinds[0], Seg_Kind.Line)
	testing.expect_value(t, c.kinds[3], Seg_Kind.Cubic)
	testing.expect_value(t, c.pts[0], Vec2{r, 0})
}
