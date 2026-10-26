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
test_format :: proc(t: ^testing.T) {
	// One shape's words, built from multiples of 1/16 in an 8 x 8 box on a
	// 4 x 4 grid, so building rounds nothing on any machine. When they
	// change, either the layout did (bump FORMAT if a reader of the old one
	// would misread them) or only what build chooses (update the hash).
	b: Builder
	defer builder_destroy(&b)
	square(&b, 0, 0, 8, 0.5)
	square(&b, 0, 0, 0.5, 8)
	for k in 0 ..< 8 {
		square(&b, 0.5 + 0.5 * f32(k), 1 + 0.75 * f32(k), 1.5, 0.5)
	}
	words, _, extent, ok := build(&b, search = false)
	testing.expect(t, ok && extent == 8)
	defer delete(words)
	testing.expect_value(t, words[0], 4)
	testing.expect_value(t, words[1], 4)
	steps: u32
	for k in 0 ..< 16 {
		steps += words[HEADER + 4 * k + 3]
	}
	testing.expect(t, steps > 0)
	h: u64 = 0xcbf29ce484222325
	for w in words {
		h = (h ~ u64(w)) * 0x100000001b3
	}
	testing.expect_value(t, FORMAT, 1)
	testing.expectf(t, h == 0x7484eba48dbad64e, "words hash %x (%d words)", h, len(words))
}

@(test)
test_full_cell :: proc(t: ^testing.T) {
	// 66,000 thin rectangles across the first column line, at distinct
	// heights in the first row, from the bottom up (their steps in reverse
	// order): the first cell lists their left sides and steps where each
	// crosses the line, 66,000 pieces and 132,000 steps. A tall square at
	// the right keeps the grid at its coarsest (cells 1000 / 64 a side).
	b: Builder
	defer builder_destroy(&b)
	N :: 66_000
	for k := N - 1; k >= 0; k -= 1 {
		square(&b, 0, 1 + f32(k) * (14.0 / N), 20, 0.0001)
	}
	square(&b, 990, 0, 10, 1000)
	words, origin, extent, ok := build(&b, search = false)
	testing.expect(t, ok)
	defer delete(words)
	testing.expect_value(t, words[0], MAX_CELLS)
	testing.expect_value(t, words[HEADER + 1], N)
	testing.expect_value(t, words[HEADER + 3], 2 * N)
	for k in ([3]int{0, N / 2, N - 1}) {
		p := Vec2{12, 1 + f32(k) * (14.0 / N) + 0.00005}
		testing.expect_value(t, abs(winding(words, (p - origin) / extent)), 1)
		testing.expect_value(t, winding(words, (p + {0, 0.0001} - origin) / extent), 0)
	}
}

@(test)
test_small_box_coverage :: proc(t: ^testing.T) {
	// A box 1/10,000 of the shape's size centered on a sloped edge covers
	// half of itself: its area must not drown in the edge's own size.
	b: Builder
	defer builder_destroy(&b)
	move_to(&b, {0, 0})
	line_to(&b, {1, 0.5})
	line_to(&b, {0, 1})
	words, origin, extent := built(t, &b)
	defer delete(words)
	testing.expect(t, origin == {} && extent == 1)
	for x in ([4]f32{0.1, 0.37, 0.7, 0.93}) {
		cov := coverage(words, {x, 0.5 * x}, {1e-4, 1e-4}, false)
		testing.expectf(t, abs(cov - 0.5) < 2e-3, "at x = %v: %v", x, cov)
	}
}

@(test)
test_mean_coverage :: proc(t: ^testing.T) {
	b: Builder
	defer builder_destroy(&b)
	square(&b, 0, 0, 10, 10)
	words, _, _ := built(t, &b)
	testing.expect_value(t, mean_coverage(words), 1)
	delete(words)

	// A disc: pi / 4 of its bounds.
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
	// Four cubics slightly overshoot a circle (by about 0.03% of its area).
	testing.expectf(t, abs(mean_coverage(words) - math.PI / 4) < 1e-3, "disc mean %v", mean_coverage(words))
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
	// A pixel the size of the whole shape sees its mean; below half the
	// shape's size coverage is left alone, however fine the bands.
	testing.expect_value(t, fade(words, 0.25, {1, 1}), mean_coverage(words))
	testing.expect_value(t, fade(words, 0.25, {0.4, 0.4}), 0.25)
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

@(test)
test_exact_area :: proc(t: ^testing.T) {
	// A square: an edge pixel covers its inside part, a corner pixel the
	// product, exactly.
	b: Builder
	defer builder_destroy(&b)
	square(&b, 10.3, 10.3, 10.4, 10.4)
	orient(&b, .Solid)
	words, origin, extent := built(t, &b)
	defer delete(words)
	at :: proc(words: []u32, origin: Vec2, extent: f32, x, y: f32) -> f32 {
		return coverage(words, (Vec2{x, y} - origin) / extent, {1, 1} / extent, false)
	}
	near :: proc(a, b: f32) -> bool {return abs(a - b) < 1e-4}
	testing.expect(t, near(at(words, origin, extent, 10.5, 15.5), 0.7))
	testing.expect(t, near(at(words, origin, extent, 10.5, 10.5), 0.49))
	testing.expect(t, near(at(words, origin, extent, 20.5, 20.5), 0.49))
	testing.expect(t, near(at(words, origin, extent, 15.5, 15.5), 1))
	testing.expect(t, near(at(words, origin, extent, 9.5, 15.5), 0))
}

@(test)
test_affine_footprints :: proc(t: ^testing.T) {
	// A disc and an S of quadratics under rotated, skewed and stretched
	// footprints (and one with a horizontal side): coverage against the area
	// 64 x 64 winding samples of the parallelogram find.
	b: Builder
	defer builder_destroy(&b)
	k :: 0.5522848
	r: f32 = 10
	move_to(&b, {r, 0})
	cubic_to(&b, {r, r * k}, {r * k, r}, {0, r})
	cubic_to(&b, {-r * k, r}, {-r, r * k}, {-r, 0})
	cubic_to(&b, {-r, -r * k}, {-r * k, -r}, {0, -r})
	cubic_to(&b, {r * k, -r}, {r, -r * k}, {r, 0})
	move_to(&b, {14, -10})
	quad_to(&b, {30, -14}, {22, 0})
	quad_to(&b, {14, 14}, {30, 10})
	line_to(&b, {30, 12})
	quad_to(&b, {10, 16}, {18, 0})
	quad_to(&b, {26, -12}, {14, -8})
	words, _, extent := built(t, &b)
	defer delete(words)
	feet := [?][2]Vec2{{{1, 0}, {0, 1}}, {{0.96, 0.28}, {-0.28, 0.96}}, {{0.7, 0.7}, {-0.7, 0.7}}, {{1.2, 0.3}, {0.1, 0.8}}, {{3, 0.5}, {-0.2, 0.4}}, {{1, 0}, {0.6, 1}}, {{0.3, -1.4}, {0.9, 0.2}}}
	worst: f32
	for foot in feet {
		u, v := foot[0] * 0.6 / extent, foot[1] * 0.6 / extent
		for gy in 0 ..< 40 {
			for gx in 0 ..< 60 {
				rc := Vec2{(f32(gx) + 0.37) / 60 * 1.05 - 0.02, (f32(gy) + 0.61) / 40 * 0.75 - 0.02}
				got := coverage_affine(words, rc, u, v, false)
				inside := 0
				N :: 64
				for sy in 0 ..< N {
					for sx in 0 ..< N {
						a, bb := (f32(sx) + 0.5) / N - 0.5, (f32(sy) + 0.5) / N - 0.5
						inside += int(winding(words, rc + a * u + bb * v) != 0)
					}
				}
				worst = max(worst, abs(got - f32(inside) / (N * N)))
			}
		}
	}
	// 64 x 64 samples resolve area to about 1/64 along an edge.
	testing.expectf(t, worst < 0.025, "worst %v", worst)
}

@(test)
test_backdrops :: proc(t: ^testing.T) {
	// Polygons in the unit square (so the cell lines are j / n exactly)
	// with corners on the lines and a rounding either side of them: the
	// winding from the cells must match a ray cast against the edges.
	state: u32 = 1
	next :: proc(s: ^u32, n: u32) -> u32 {
		s^ = s^ * 1664525 + 1013904223
		return (s^ >> 8) % n
	}
	near_line :: proc(s: ^u32) -> f32 {
		n := 1 + next(s, MAX_CELLS)
		v := f32(next(s, n + 1)) * (1 / f32(n))
		switch next(s, 3) {
		case 0:
			v = math.nextafter(v, f32(-1))
		case 1:
			v = math.nextafter(v, f32(2))
		}
		return clamp(v, 0, 1)
	}
	wrong := 0
	for _ in 0 ..< 2000 {
		b: Builder
		defer builder_destroy(&b)
		corners: [dynamic]Vec2
		defer delete(corners)
		// A sliver from corner to corner pins the bounds to the unit square.
		for p in ([3]Vec2{{0, 0}, {1, 1}, {0.5, 0.52}}) {
			append(&corners, p)
		}
		append(&corners, Vec2{-1, -1})
		move_to(&b, {0, 0})
		line_to(&b, {1, 1})
		line_to(&b, {0.5, 0.52})
		close(&b)
		for _ in 0 ..< 1 + next(&state, 3) {
			for k in 0 ..< 3 + next(&state, 6) {
				p := Vec2{f32(next(&state, 1000)) / 999, near_line(&state)}
				if next(&state, 4) == 0 {
					p = p.yx
				}
				append(&corners, p)
				if k == 0 {
					move_to(&b, p)
				} else {
					line_to(&b, p)
				}
			}
			close(&b)
			append(&corners, Vec2{-1, -1}) // contour break
		}
		words, origin, extent, ok := build(&b)
		testing.expect(t, ok && origin == {} && extent == 1)
		defer delete(words)
		for yi in 0 ..< 32 {
			for xi in 0 ..< 32 {
				p := Vec2{(f32(xi) + 0.3713) / 32, (f32(yi) + 0.5927) / 32}
				ray: i32
				start := 0
				near := false
				for k in 0 ..< len(corners) {
					if corners[k].x < 0 {
						start = k + 1
						continue
					}
					a, c := corners[k], corners[k + 1] if corners[k + 1].x >= 0 else corners[start]
					if (a.y <= p.y) != (c.y <= p.y) {
						x := a.x + (p.y - a.y) / (c.y - a.y) * (c.x - a.x)
						near ||= abs(x - p.x) < 1e-4
						if x > p.x {
							ray += 1 if c.y > a.y else -1
						}
					}
				}
				// Rounding decides samples on an edge.
				if !near && winding(words, p) != ray {
					wrong += 1

				}
			}
		}
	}
	testing.expect_value(t, wrong, 0)
}

@(test)
test_affine_near_upright :: proc(t: ^testing.T) {
	// A pixel turned a hair off upright over a straight edge: its
	// footprint's top and bottom triangles are thin with steep sides, and
	// their area must not be lost to rounding.
	b: Builder
	defer builder_destroy(&b)
	square(&b, 0, 0, 220, 250)
	words, origin, extent := built(t, &b)
	defer delete(words)
	worst: f32
	for ang in ([3]f32{0.03, -0.01, 0.002}) {
		u := Vec2{math.cos(ang), math.sin(ang)} * 0.8
		v := Vec2{-math.sin(ang), math.cos(ang)} * 0.8
		for k in 0 ..< 40 {
			// Centers across the left edge x = 0, where the area right of
			// it is (x + 0.4) / 0.8 of the pixel, nearly.
			q := Vec2{f32(k) * 0.02 - 0.4, 100}
			got := coverage_affine(words, (q - origin) / extent, u / extent, v / extent, false)
			worst = max(worst, abs(got - clamp((q.x + 0.4) / 0.8, 0, 1)))
		}
	}
	testing.expectf(t, worst < 0.03, "worst %v", worst)
}

@(test)
test_build_rejects_non_finite :: proc(t: ^testing.T) {
	nan := math.nan_f32()
	for bad in ([3]Vec2{{nan, 1}, {1, nan}, {math.inf_f32(1), 0}}) {
		b: Builder
		defer builder_destroy(&b)
		square(&b, 0, 0, 10, 10)
		move_to(&b, {0, 0})
		line_to(&b, bad)
		line_to(&b, {5, 5})
		words, _, _, ok := build(&b)
		testing.expect(t, !ok)
		delete(words)
	}
}

@(test)
test_build_flat_shapes :: proc(t: ^testing.T) {
	// No width or no height: built (nothing covered), never a division by 0.
	for end in ([2]Vec2{{0, 10}, {10, 0}}) {
		for search in ([2]bool{true, false}) {
			b: Builder
			defer builder_destroy(&b)
			move_to(&b, {0, 0})
			line_to(&b, end)
			close(&b)
			words, origin, extent, ok := build(&b, context.allocator, search)
			testing.expect(t, ok)
			testing.expect_value(t, winding(words, (end * 0.5 - origin) / extent + {0.1, 0.1}), 0)
			delete(words)
		}
	}
}
