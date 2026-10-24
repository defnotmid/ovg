package curves

import "core:math"
import "core:math/rand"
import "core:testing"

@(private = "file")
line_cubic :: proc(a, b: [2]f64) -> [4][2]f64 {
	return {a, a + (b - a) / 3, a + (b - a) * (2.0 / 3), b}
}

@(test)
test_snap_epsilon :: proc(t: ^testing.T) {
	eps, delta := snap_epsilon(1)
	testing.expect_value(t, eps, math.pow(2, f64(-20)))
	testing.expect_value(t, delta, eps / 4)
	// 1000-unit art: about 5e-4. Doubling M doubles eps exactly.
	e1000, _ := snap_epsilon(1000)
	testing.expect_value(t, e1000, math.pow(2, f64(-11)))
	e2, _ := snap_epsilon(2000)
	testing.expect_value(t, e2, 2 * e1000)
	z, _ := snap_epsilon(0)
	testing.expect_value(t, z, 0)
}

@(test)
test_monotone_pieces :: proc(t: ^testing.T) {
	pieces: [dynamic]Piece
	defer delete(pieces)
	// An S curve turning twice in y and once in x.
	q := [4][2]f64{{0, 0}, {3, 4}, {-1, -4}, {2, 0}}
	monotone_pieces(q, false, 7, 1, 1e-9, &pieces)
	testing.expect(t, len(pieces) >= 3)
	prev := 0.0
	for p in pieces {
		testing.expect_value(t, p.t0, prev)
		prev = p.t1
		// Monotone in x and y.
		dx, dy := p.p[3].x - p.p[0].x, p.p[3].y - p.p[0].y
		prev_pt := p.p[0]
		for k in 1 ..= 64 {
			c := cubic_at(p.p, f64(k) / 64)
			testing.expect(t, (c.x - prev_pt.x) * dx >= -1e-9 && (c.y - prev_pt.y) * dy >= -1e-9)
			prev_pt = c
		}
		// The piece is the source over its range.
		d := cubic_at(p.p, 0.5) - cubic_at(q, (p.t0 + p.t1) / 2)
		testing.expect(t, abs(d.x) < 1e-9 && abs(d.y) < 1e-9)
		testing.expect(t, p.row == 7 && p.operand == 1 && !p.line)
	}
	testing.expect_value(t, prev, 1)
	// Backtracking handles along a line become line pieces.
	clear(&pieces)
	monotone_pieces({{0, 0}, {3, 3}, {-1, -1}, {2, 2}}, false, 0, 0, 1e-9, &pieces)
	for p in pieces {
		testing.expect(t, p.line)
	}
}

@(test)
test_curve_winding :: proc(t: ^testing.T) {
	stack: [dynamic][2]f64
	defer delete(stack)
	// Chords against the ray from the origin, half-open in y.
	Case :: struct {
		a, b: [2]f64,
		w:    i32,
	}
	cases := [?]Case {
		{{1, -1}, {1, 1}, 1},
		{{1, 1}, {1, -1}, -1},
		{{-1, -1}, {-1, 1}, 0}, // left of the point
		{{1, 0}, {1, 1}, 1}, // starts on the ray's line, which counts as below
		{{1, -1}, {1, 0}, 0}, // ends on it: both below
		{{1, 1}, {2, 2}, 0},
		{{1, -1}, {2, -2}, 0},
		{{-1, -1}, {3, 1}, 1}, // crosses right of the point
	}
	for c in cases {
		w, on := curve_winding(line_cubic(c.a, c.b), {0, 0}, 1e-12, &stack)
		testing.expectf(t, w == c.w && !on, "%v -> %v: %d", c.a, c.b, w)
	}
	// A circle of four cubics: 1 inside, even with the ray through a joint,
	// 0 outside.
	K :: 0.5522847498
	r := 10.0
	circle := [4][4][2]f64 {
		{{r, 0}, {r, r * K}, {r * K, r}, {0, r}},
		{{0, r}, {-r * K, r}, {-r, r * K}, {-r, 0}},
		{{-r, 0}, {-r, -r * K}, {-r * K, -r}, {0, -r}},
		{{0, -r}, {r * K, -r}, {r, -r * K}, {r, 0}},
	}
	wind :: proc(circle: [4][4][2]f64, q: [2]f64, stack: ^[dynamic][2]f64) -> (w: i32, on: bool) {
		for c in circle {
			cw, con := curve_winding(c, q, 1e-9, stack)
			w += cw
			on ||= con
		}
		return
	}
	for q in ([?][2]f64{{0, 0}, {5, 0}, {-3, 7}, {9.9, 0}}) {
		w, on := wind(circle, q, &stack)
		testing.expectf(t, abs(w) == 1 && !on, "%v: %d", q, w)
	}
	for q in ([?][2]f64{{11, 0}, {-10.1, 0}, {8, 8}, {0, 20}}) {
		w, _ := wind(circle, q, &stack)
		testing.expectf(t, w == 0, "%v: %d", q, w)
	}
	_, on := wind(circle, {r, 0}, &stack)
	testing.expect(t, on)
}

@(private = "file")
piece_of :: proc(q: [4][2]f64, line: bool) -> Piece {
	return {p = q, t0 = 0, t1 = 1, line = line}
}

@(test)
test_near_runs_fixtures :: proc(t: ^testing.T) {
	s: Kernel_Scratch
	defer kernel_scratch_destroy(&s)
	runs: [dynamic]Run
	defer delete(runs)
	tol := 1e-6
	budget := max(int)
	// A raised quadratic bulge peaking at y = 1 touches the bar at y = 1
	// (one run around x = 1) and misses the bar at y = 1.5.
	bulge := piece_of({{0, 0}, {2.0 / 3, 4.0 / 3}, {4.0 / 3, 4.0 / 3}, {2, 0}}, false)
	bar := piece_of(line_cubic({0, 1}, {2, 1}), true)
	testing.expect(t, near_runs(&bulge, &bar, tol, tol / 4, &s, &runs, &budget))
	testing.expect_value(t, len(runs), 1)
	testing.expect(t, runs[0].s0 < 0.5 && runs[0].s1 > 0.5 && runs[0].t0 < 0.5 && runs[0].t1 > 0.5)
	clear(&runs)
	high := piece_of(line_cubic({0, 1.5}, {2, 1.5}), true)
	near_runs(&bulge, &high, tol, tol / 4, &s, &runs, &budget)
	testing.expect_value(t, len(runs), 0)
	// A crossing: one point run where the lines meet.
	clear(&runs)
	a := piece_of(line_cubic({0, 0}, {4, 4}), true)
	b := piece_of(line_cubic({0, 3}, {4, -1}), true)
	near_runs(&a, &b, tol, tol / 4, &s, &runs, &budget)
	testing.expect_value(t, len(runs), 1)
	testing.expect(t, runs[0].point && abs((runs[0].s0 + runs[0].s1) / 2 - 0.375) < 1e-6)
	// Collinear partial overlaps, either way round: one overlap run over
	// the shared stretch.
	for flip in ([2]bool{false, true}) {
		clear(&runs)
		c := piece_of(line_cubic({0, 0}, {10, 0}), true)
		d := piece_of(line_cubic({4, 0}, {14, 0}) if !flip else line_cubic({14, 0}, {4, 0}), true)
		near_runs(&c, &d, tol, tol / 4, &s, &runs, &budget)
		testing.expect_value(t, len(runs), 1)
		testing.expect(t, !runs[0].point)
		testing.expect(t, abs(runs[0].s0 - 0.4) < 1e-6 && abs(runs[0].s1 - 1) < 1e-6)
		testing.expect(t, abs(runs[0].t0 - 0) < 1e-6 && abs(runs[0].t1 - 0.6) < 1e-6 if !flip else abs(runs[0].t0 - 0.4) < 1e-6 && abs(runs[0].t1 - 1) < 1e-6)
	}
}

// Random pairs of monotone pieces against dense samples: every pair of
// points closer than tol - delta lies in a run, and each run's middle pair
// is close.
@(test)
test_near_runs_fuzz :: proc(t: ^testing.T) {
	s: Kernel_Scratch
	defer kernel_scratch_destroy(&s)
	runs: [dynamic]Run
	defer delete(runs)
	pieces: [dynamic]Piece
	defer delete(pieces)
	gen := rand.create(7)
	r := rand.default_random_generator(&gen)
	tol := 0.02
	delta := tol / 4
	budget := max(int)
	N :: 96
	for _ in 0 ..< 300 {
		pair: [2]Piece
		for k in 0 ..< 2 {
			clear(&pieces)
			q: [4][2]f64
			for &p in q {
				p = {rand.float64(r) * 2, rand.float64(r) * 2}
			}
			line := rand.float64(r) < 0.3
			if line {
				q = line_cubic(q[0], q[3])
			}
			monotone_pieces(q, line, 0, 0, 1e-12, &pieces)
			pair[k] = pieces[0]
		}
		clear(&runs)
		near_runs(&pair[0], &pair[1], tol, delta, &s, &runs, &budget)
		for i in 0 ..= N {
			for j in 0 ..= N {
				u, v := f64(i) / N, f64(j) / N
				d := piece_at(&pair[0], u) - piece_at(&pair[1], v)
				if math.sqrt(d.x * d.x + d.y * d.y) > tol - delta {
					continue
				}
				inside := false
				for run in runs {
					if u >= run.s0 - 1e-9 && u <= run.s1 + 1e-9 && v >= run.t0 - 1e-9 && v <= run.t1 + 1e-9 {
						inside = true
					}
				}
				testing.expectf(t, inside, "pair %v near at %v, %v not in a run %v", pair, u, v, runs[:])
				if !inside {
					return
				}
			}
		}
		for run in runs {
			d := piece_at(&pair[0], (run.s0 + run.s1) / 2) - piece_at(&pair[1], (run.t0 + run.t1) / 2)
			if run.point {
				testing.expectf(t, math.sqrt(d.x * d.x + d.y * d.y) <= 2 * tol, "point run %v middle far", run)
			}
		}
	}
}

// Scaling the input by 2^k scales tol with it and leaves every run's
// parameters bitwise unchanged.
@(test)
test_near_runs_scale :: proc(t: ^testing.T) {
	s: Kernel_Scratch
	defer kernel_scratch_destroy(&s)
	base, scaled: [dynamic]Run
	defer delete(base)
	defer delete(scaled)
	budget := max(int)
	q := [4][2]f64{{0, 0}, {1, 3}, {2, -2}, {3, 1}}
	l := [4][2]f64{{0, 1}, {1, 0.5}, {2, 0}, {3, -0.5}}
	for k in ([?]f64{-20, -7, 3, 15}) {
		f := math.pow(2, k)
		a := piece_of(q, false)
		b := piece_of(l, true)
		clear(&base)
		near_runs(&a, &b, 1e-3, 1e-3 / 4, &s, &base, &budget)
		for i in 0 ..< 4 {
			a.p[i] *= f
			b.p[i] *= f
		}
		clear(&scaled)
		near_runs(&a, &b, 1e-3 * f, 1e-3 * f / 4, &s, &scaled, &budget)
		testing.expect_value(t, len(scaled), len(base))
		for r, i in base {
			if i < len(scaled) {
				testing.expectf(t, scaled[i] == r, "2^%v: %v vs %v", k, scaled[i], r)
			}
		}
	}
	testing.expect(t, len(base) > 0)
}

// A point exactly on the curve with no tolerance: the halving stops where
// f64 can't split a cell and reports it on the curve.
@(test)
test_curve_winding_on_curve :: proc(t: ^testing.T) {
	stack: [dynamic][2]f64
	defer delete(stack)
	_, on := curve_winding(line_cubic({0, 0}, {2, 2}), {1, 1}, 0, &stack)
	testing.expect(t, on)
	_, on = curve_winding({{0, 0}, {1, 2}, {3, 2}, {4, 0}}, {2, 1.5}, 0, &stack)
	testing.expect(t, on)
}
