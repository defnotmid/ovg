package curves

import "core:math"
import "core:testing"

@(private = "file")
square :: proc(b: ^Builder, x, y, w, h: f32) {
	move_to(b, {x, y})
	line_to(b, {x + w, y})
	line_to(b, {x + w, y + h})
	line_to(b, {x, y + h})
	close(b)
}

@(private = "file")
built :: proc(t: ^testing.T, b: ^Builder) -> (words: []u32, origin: Vec2, extent: f32) {
	ok: bool
	words, origin, extent, ok = build(b)
	testing.expect(t, ok)
	return
}

@(test)
test_winding :: proc(t: ^testing.T) {
	// Three nested squares drawn the same way round, oriented solid, hole,
	// solid.
	b: Builder
	defer builder_destroy(&b)
	square(&b, 0, 0, 30, 30)
	orient(&b, .Solid)
	square(&b, 10, 10, 10, 10)
	orient(&b, .Hole)
	square(&b, 13, 13, 4, 4)
	orient(&b, .Solid)
	words, origin, extent := built(t, &b)
	defer delete(words)
	at :: proc(words: []u32, origin: Vec2, extent: f32, x, y: f32) -> i32 {
		return winding(words, (Vec2{x, y} - origin) / extent)
	}
	outer := at(words, origin, extent, 5, 15)
	testing.expect(t, outer != 0)
	testing.expect_value(t, at(words, origin, extent, 11, 15), 0)
	testing.expect_value(t, at(words, origin, extent, 15, 15), outer)
	testing.expect_value(t, at(words, origin, extent, 40, 15), 0)
	testing.expect_value(t, at(words, origin, extent, 15, -5), 0)
}

@(test)
test_mean_coverage :: proc(t: ^testing.T) {
	b: Builder
	defer builder_destroy(&b)
	square(&b, 0, 0, 10, 10)
	words, _, _ := built(t, &b)
	testing.expect_value(t, mean_coverage(words), 1)
	delete(words)

	// A disc: pi / 4 of its bounds, to the grid's resolution.
	builder_reset(&b)
	k :: 0.5522848
	r: f32 = 10
	move_to(&b, {r, 0})
	cubic_to(&b, {r, r * k}, {r * k, r}, {0, r})
	cubic_to(&b, {-r * k, r}, {-r, r * k}, {-r, 0})
	cubic_to(&b, {-r, -r * k}, {-r * k, -r}, {0, -r})
	cubic_to(&b, {r * k, -r}, {r, -r * k}, {r, 0})
	words, _, _ = built(t, &b)
	defer delete(words)
	testing.expectf(t, abs(mean_coverage(words) - math.PI / 4) < 0.02, "disc mean %v", mean_coverage(words))
}

@(test)
test_footprint :: proc(t: ^testing.T) {
	b: Builder
	defer builder_destroy(&b)
	square(&b, 0, 0, 100, 100)
	words, _, extent := built(t, &b)
	defer delete(words)
	// One pixel = 1 source unit: the Jacobian of shape units by pixels.
	s := 1 / extent
	j := matrix[2, 2]f32{s, 0, 0, s}
	testing.expect_value(t, footprint_of(j), Vec2{s, s})
	// A pixel center 0.2 px inside the left edge.
	rc := Vec2{0.2 * s, 0.5}
	testing.expect(t, abs(coverage_jacobian(words, rc, j, false) - 0.7) < 1e-3)
	testing.expect_value(t, coverage_jacobian(words, rc, j, false), coverage(words, rc, {s, s}, false))
	// Rotated 45 degrees, the footprint box grows by sqrt 2.
	c := math.cos(f32(math.PI / 4)) * s
	rot := matrix[2, 2]f32{c, -c, c, c}
	testing.expect(t, abs(footprint_of(rot).x - math.SQRT_TWO * s) < 1e-6)
	// Minified past two bands, coverage is the shape's mean.
	far := Vec2{1, 1} * 2.5 / transmute(f32)words[2]
	testing.expect_value(t, fade(words, 0.25, far), mean_coverage(words))
	testing.expect_value(t, fade(words, 0.25, {s, s}), 0.25)
}

@(test)
test_cubics_within_tolerance :: proc(t: ^testing.T) {
	// A tighter tolerance makes more quadratics; raised quadratics stay one.
	count :: proc(tol: f32) -> int {
		b: Builder
		defer builder_destroy(&b)
		b.tol = tol
		move_to(&b, {0, 0})
		cubic_to(&b, {0, 100}, {100, 100}, {100, 0})
		return len(b.curves)
	}
	testing.expect(t, count(0.001) > count(1))
	b: Builder
	defer builder_destroy(&b)
	move_to(&b, {0, 0})
	q := Vec2{10, 20}
	cubic_to(&b, q * 2 / 3, Vec2{20, 0} + (q - Vec2{20, 0}) * 2 / 3, {20, 0})
	testing.expect_value(t, len(b.curves), 1)
}
