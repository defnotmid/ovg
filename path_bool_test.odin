package ovg

import "core:math"
import "core:mem"
import "core:testing"

import cv "deps:ocurves"

// The winding of a path about q (open contours closed), with `on` set when
// q lies within `near` of an outline.
@(private = "file")
path_winding_at :: proc(p: ^Path, q: [2]f64, near: f64) -> (w: i32, on: bool) {
	stack: [dynamic][2]f64
	defer delete(stack)
	return cv.contours_winding(p, 0, len(p.contours), q, &stack, near)
}

@(private = "file")
path_area :: proc(p: ^Path) -> f64 {
	a: f64
	for _, i in p.contours {
		a += cv.contours_area(p, i)
	}
	return a
}

@(private = "file")
op_inside :: proc(op: Bool_Op, ins: []bool) -> bool {
	n := 0
	for x in ins {
		n += int(x)
	}
	switch op {
	case .Union:
		return n > 0
	case .Intersection:
		return n == len(ins)
	case .Difference:
		return ins[0] && n == 1
	case .Xor:
		return n & 1 == 1
	}
	return false
}

// Every op of a and b: membership on a grid away from the outlines, no
// overlapping output contours, and inclusion-exclusion of areas when both
// operands are simple and Solid-wound.
@(private = "file")
check_ops :: proc(t: ^testing.T, name: string, a, b: ^Path, rule_a, rule_b: Fill_Rule, lo, hi: [2]f64, simple: bool) {
	s: Bool_Scratch
	defer bool_scratch_destroy(&s)
	areas: [Bool_Op]f64
	near := (hi.x - lo.x) / 300
	for op in Bool_Op {
		out: Path
		defer path_destroy(&out)
		err := path_boolean(&out, {a, rule_a}, {b, rule_b}, op, &s)
		testing.expectf(t, err == nil, "%s %v: %v (%v)", name, op, err, s.core.stats)
		if err != nil {
			continue
		}
		areas[op] = path_area(&out)
		N :: 48
		bad := 0
		for i in 0 ..< N {
			for j in 0 ..< N {
				q := lo + (hi - lo) * [2]f64{(f64(i) + 0.37) / N, (f64(j) + 0.61) / N}
				wa, ona := path_winding_at(a, q, near)
				wb, onb := path_winding_at(b, q, near)
				wr, onr := path_winding_at(&out, q, near)
				if ona || onb || onr {
					continue
				}
				ins := [2]bool{cv.fill_inside(wa, rule_a), cv.fill_inside(wb, rule_b)}
				want := op_inside(op, ins[:])
				if (wr != 0) != want || abs(wr) > 1 {
					bad += 1
					if bad == 1 {
						testing.expectf(t, false, "%s %v at %v: result winding %d, operands %d %d", name, op, q, wr, wa, wb)
					}
				}
			}
		}
	}
	if simple {
		aa, ab := abs(path_area(a)), abs(path_area(b))
		tol := 1e-4 * (aa + ab) + 1e-6
		testing.expectf(t, abs(areas[.Union] + areas[.Intersection] - aa - ab) <= tol, "%s: union %v + intersection %v vs %v + %v", name, areas[.Union], areas[.Intersection], aa, ab)
		testing.expectf(t, abs(areas[.Difference] + areas[.Intersection] - aa) <= tol, "%s: difference %v + intersection %v vs %v", name, areas[.Difference], areas[.Intersection], aa)
		testing.expectf(t, abs(areas[.Xor] - (areas[.Union] - areas[.Intersection])) <= tol, "%s: xor %v", name, areas[.Xor])
		for op in Bool_Op {
			testing.expectf(t, areas[op] >= -tol, "%s %v: area %v not Solid", name, op, areas[op])
		}
	}
}

@(test)
test_path_boolean_shapes :: proc(t: ^testing.T) {
	a, b: Path
	defer path_destroy(&a)
	defer path_destroy(&b)

	path_rect(&a, 0, 0, 40, 30)
	path_rect(&b, 20, 10, 40, 30)
	check_ops(t, "rects", &a, &b, .Non_Zero, .Non_Zero, {-5, -5}, {65, 45}, true)

	path_reset(&a)
	path_reset(&b)
	path_circle(&a, 30, 30, 20)
	path_rect(&b, 30, 20, 40, 40)
	check_ops(t, "circle-square", &a, &b, .Non_Zero, .Non_Zero, {5, 5}, {75, 65}, true)

	// Identical: union and intersection are the shape, difference and xor
	// nothing.
	path_reset(&b)
	path_circle(&b, 30, 30, 20)
	check_ops(t, "same-circles", &a, &b, .Non_Zero, .Non_Zero, {5, 5}, {55, 55}, true)

	// Sharing an edge.
	path_reset(&a)
	path_reset(&b)
	path_rect(&a, 0, 0, 20, 20)
	path_rect(&b, 20, 5, 20, 10)
	check_ops(t, "abutting", &a, &b, .Non_Zero, .Non_Zero, {-5, -5}, {45, 25}, true)

	// Tangent from outside.
	path_reset(&a)
	path_reset(&b)
	path_circle(&a, 20, 20, 10)
	path_circle(&b, 40, 20, 10)
	check_ops(t, "tangent", &a, &b, .Non_Zero, .Non_Zero, {5, 5}, {55, 35}, true)

	// A ring (a hole by winding, or by even-odd) against a bar.
	path_reset(&a)
	path_reset(&b)
	path_circle(&a, 30, 30, 25)
	path_circle(&a, 30, 30, 12)
	path_solidity(&a, .Hole)
	path_rect(&b, 0, 25, 60, 10)
	check_ops(t, "ring-nonzero", &a, &b, .Non_Zero, .Non_Zero, {0, 0}, {60, 60}, false)
	check_ops(t, "ring-evenodd", &a, &b, .Even_Odd, .Non_Zero, {0, 0}, {60, 60}, false)
}

@(test)
test_path_simplify :: proc(t: ^testing.T) {
	s: Bool_Scratch
	defer bool_scratch_destroy(&s)
	// A figure eight crossing itself: one lobe winds each way, so both
	// rules keep both lobes.
	p: Path
	defer path_destroy(&p)
	path_move_to(&p, 0, 0)
	path_bezier_to(&p, 40, 0, 0, 40, 40, 40)
	path_bezier_to(&p, 40, 0, 0, 40, 0, 0)
	path_close(&p)
	for rule in Fill_Rule {
		out: Path
		defer path_destroy(&out)
		testing.expect_value(t, path_simplify(&out, {&p, rule}, &s), nil)
		for i in 0 ..< 32 {
			for j in 0 ..< 32 {
				q := [2]f64{(f64(i) + 0.4) * 40 / 32, (f64(j) + 0.6) * 40 / 32}
				wp, onp := path_winding_at(&p, q, 0.1)
				wr, onr := path_winding_at(&out, q, 0.1)
				if onp || onr {
					continue
				}
				testing.expectf(t, (wr != 0) == cv.fill_inside(wp, rule) && abs(wr) <= 1, "%v at %v: %d vs %d", rule, q, wr, wp)
			}
		}
	}
}

// Disjoint shapes come back as their own curves, bit for bit.
@(test)
test_path_boolean_keeps_curves :: proc(t: ^testing.T) {
	s: Bool_Scratch
	defer bool_scratch_destroy(&s)
	a, b, out: Path
	defer path_destroy(&a)
	defer path_destroy(&b)
	defer path_destroy(&out)
	path_circle(&a, 20, 20, 10)
	path_circle(&b, 60, 20, 10)
	testing.expect_value(t, path_boolean(&out, {&a, .Non_Zero}, {&b, .Non_Zero}, .Union, &s), nil)
	beziers := 0
	for k in out.kinds {
		beziers += int(k == .Cubic)
	}
	testing.expect_value(t, beziers, 8)
	// Every output point is one of the inputs' points.
	for q in out.pts {
		found := false
		for c in a.pts {
			found ||= c == q
		}
		for c in b.pts {
			found ||= c == q
		}
		testing.expectf(t, found, "point %v is not an input point", q)
	}
	_ = math.PI
}

// A warm scratch allocates nothing, from either allocator.
@(test)
test_path_boolean_warm_no_alloc :: proc(t: ^testing.T) {
	s: Bool_Scratch
	defer bool_scratch_destroy(&s)
	a, b, out: Path
	defer path_destroy(&a)
	defer path_destroy(&b)
	defer path_destroy(&out)
	path_rect(&a, 0, 0, 120, 60)
	for i in 0 ..< 6 {
		path_circle(&b, 10 + f32(i) * 18, 30, 9)
	}
	for op in Bool_Op {
		path_reset(&out)
		testing.expect_value(t, path_boolean(&out, {&a, .Non_Zero}, {&b, .Non_Zero}, op, &s), nil)
	}
	track, temp: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	mem.tracking_allocator_init(&temp, context.temp_allocator)
	defer mem.tracking_allocator_destroy(&temp)
	{
		context.allocator = mem.tracking_allocator(&track)
		context.temp_allocator = mem.tracking_allocator(&temp)
		for op in Bool_Op {
			path_reset(&out)
			path_boolean(&out, {&a, .Non_Zero}, {&b, .Non_Zero}, op, &s)
		}
	}
	testing.expect_value(t, track.total_allocation_count, 0)
	testing.expect_value(t, temp.total_allocation_count, 0)
}

// Divide: two crossing circles make three faces (each alone, and the
// lens); a ring with a disc inside its hole makes two (the ring keeps its
// hole); the faces' areas sum to the union's.
@(test)
test_path_divide :: proc(t: ^testing.T) {
	s: Bool_Scratch
	defer bool_scratch_destroy(&s)
	a, b, out, face, union_: Path
	defer path_destroy(&a)
	defer path_destroy(&b)
	defer path_destroy(&out)
	defer path_destroy(&face)
	defer path_destroy(&union_)
	faces: [dynamic]Range
	defer delete(faces)
	// want: how many regions lie inside a only, b only, and both.
	check :: proc(t: ^testing.T, s: ^Bool_Scratch, a, b, out, face, union_: ^Path, faces: ^[dynamic]Range, want: [3]int) {
		path_reset(out)
		path_reset(union_)
		clear(faces)
		ops := [2]Bool_Operand{{a, .Non_Zero}, {b, .Non_Zero}}
		testing.expect_value(t, path_divide(out, faces, ops[:], s), nil)
		got: [3]int
		for i in 0 ..< len(faces) {
			ia, ib := s.core.faces_in[2 * i], s.core.faces_in[2 * i + 1]
			got[0 if !ib else 1 if !ia else 2] += 1
		}
		testing.expect_value(t, got, want)
		testing.expect_value(t, path_boolean(union_, ops[0], ops[1], .Union, s), nil)
		sum: f64
		for f in faces {
			path_reset(face)
			path_append_contours(face, out, int(f.start), int(f.count))
			fa := path_area(face)
			testing.expectf(t, fa > 0, "face %v area %v not Solid", f, fa)
			sum += fa
		}
		u := path_area(union_)
		testing.expectf(t, abs(sum - u) <= 1e-4 * u, "faces %v vs union %v", sum, u)
	}
	path_circle(&a, 30, 30, 20)
	path_circle(&b, 50, 30, 20)
	check(t, &s, &a, &b, &out, &face, &union_, &faces, {1, 1, 1})
	path_reset(&a)
	path_reset(&b)
	path_circle(&a, 30, 30, 25)
	path_circle(&a, 30, 30, 15)
	path_solidity(&a, .Hole)
	path_circle(&b, 30, 30, 8)
	check(t, &s, &a, &b, &out, &face, &union_, &faces, {1, 1, 0})
}
