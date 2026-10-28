// Fuzzes the path booleans: random operands (polygons, self-crossing ones
// included, cubic blobs, circles, rects on a coarse grid so edges and
// corners coincide, tangent circles, and rects and polygons on that grid
// with each corner moved by a few half-eps steps, so edges nearly coincide
// at the scale the boolean resolves), every op under both fill rules,
// checked by membership on a grid away from the outlines (the result fills
// a point exactly when the op of the operands' fills does, with winding
// at most 1 so no output contours overlap), and its regions
// (core.faces): they tile its contours, each its one Solid contour then
// its holes, and a point inside the result lies in exactly one.
//
// path_divide is checked too: a point inside the union lies in exactly one
// face, which says it lies inside the operands that hold the point; any
// other point lies in none.
//
//     odin run tools/bool_suite -collection:deps=.. -o:speed -- [-seed:1] [-cases:500] [-v]
package bool_suite

import "core:fmt"
import "core:math/rand"
import "core:os"
import "core:strconv"
import "core:strings"

import vg "deps:ovg"
import cv "deps:ocurves"

main :: proc() {
	seed, cases := u64(1), 500
	verbose := false
	for a in os.args[1:] {
		switch {
		case strings.has_prefix(a, "-seed:"):
			v, _ := strconv.parse_u64(a[6:])
			seed = v
		case strings.has_prefix(a, "-cases:"):
			cases, _ = strconv.parse_int(a[7:])
		case a == "-v":
			verbose = true
		}
	}
	s: vg.Bool_Scratch
	errors, wrong, overlapping, regions, checked, divided := 0, 0, 0, 0, 0, 0
	for n in 0 ..< cases {
		case_seed := seed * 1_000_003 + u64(n)
		gen := rand.create(case_seed)
		r := rand.default_random_generator(&gen)
		a, b: vg.Path
		defer vg.path_destroy(&a)
		defer vg.path_destroy(&b)
		kind := rand.int_max(7, r)
		operand(&a, kind, r)
		operand(&b, kind, r)
		for op in vg.Bool_Op {
			for rule in vg.Fill_Rule {
				out: vg.Path
				defer vg.path_destroy(&out)
				err := vg.path_boolean(&out, {&a, rule}, {&b, rule}, op, &s)
				if err != nil {
					errors += 1
					if verbose {
						fmt.printfln("seed %d kind %d %v %v: %v %v", case_seed, kind, op, rule, err, s.core.stats)
					}
					continue
				}
				w, o := check(&a, &b, &out, op, rule)
				g := check_regions(&s.core)
				checked += 1
				wrong += int(w > 0)
				overlapping += int(o > 0)
				regions += int(g > 0)
				if (w > 0 || o > 0 || g > 0) && verbose {
					fmt.printfln("seed %d kind %d %v %v: %d wrong, %d overlapping samples, %d region faults", case_seed, kind, op, rule, w, o, g)
				}
			}
		}
		// Divide under non-zero.
		{
			out: vg.Path
			defer vg.path_destroy(&out)
			faces: [dynamic]vg.Range
			defer delete(faces)
			ops := [2]vg.Bool_Operand{{&a, .Non_Zero}, {&b, .Non_Zero}}
			if err := vg.path_divide(&out, &faces, ops[:], &s); err != nil {
				errors += 1
				if verbose {
					fmt.printfln("seed %d kind %d divide: %v", case_seed, kind, err)
				}
			} else {
				w := check_divide(&a, &b, &out, faces[:], s.core.faces_in[:])
				divided += 1
				wrong += int(w > 0)
				if w > 0 && verbose {
					fmt.printfln("seed %d kind %d divide: %d wrong samples", case_seed, kind, w)
				}
			}
		}
	}
	fmt.printfln("%d cases, %d results and %d divides checked: %d errors, %d wrong, %d overlapping, %d with bad regions", cases, checked, divided, errors, wrong, overlapping, regions)
	if errors + wrong + overlapping + regions > 0 {
		os.exit(1)
	}
}

operand :: proc(p: ^vg.Path, kind: int, r: rand.Generator) {
	f :: proc(r: rand.Generator, lo, hi: f32) -> f32 {return lo + rand.float32(r) * (hi - lo)}
	grid :: proc(r: rand.Generator) -> f32 {return f32(rand.int_max(9, r)) * 10}
	switch kind {
	case 0:
		// A polygon, maybe crossing itself.
		n := 3 + rand.int_max(6, r)
		for i in 0 ..< n {
			x, y := f(r, 0, 100), f(r, 0, 100)
			if i == 0 {
				vg.path_move_to(p, x, y)
			} else {
				vg.path_line_to(p, x, y)
			}
		}
		vg.path_close(p)
	case 1:
		// A closed blob of cubics.
		n := 2 + rand.int_max(4, r)
		x0, y0 := f(r, 0, 100), f(r, 0, 100)
		vg.path_move_to(p, x0, y0)
		for i in 0 ..< n {
			x, y := f(r, 0, 100), f(r, 0, 100)
			if i == n - 1 {
				x, y = x0, y0
			}
			vg.path_bezier_to(p, f(r, 0, 100), f(r, 0, 100), f(r, 0, 100), f(r, 0, 100), x, y)
		}
		vg.path_close(p)
	case 2:
		vg.path_circle(p, f(r, 20, 80), f(r, 20, 80), f(r, 5, 40))
	case 3:
		// Rects on a coarse grid: shared edges and corners.
		for _ in 0 ..< 1 + rand.int_max(3, r) {
			x, y := grid(r), grid(r)
			vg.path_rect(p, x, y, 10 + grid(r) / 2, 10 + grid(r) / 2)
		}
	case 4:
		// Circles on a grid of radius 10: tangent and identical ones.
		for _ in 0 ..< 1 + rand.int_max(2, r) {
			vg.path_circle(p, 10 + 20 * f32(rand.int_max(4, r)), 10 + 20 * f32(rand.int_max(4, r)), 10)
		}
	case 5:
		// A mix: a polygon and a circle.
		operand(p, 0, r)
		operand(p, 2, r)
	case 6:
		// Nearly coincident: rects and a polygon on the grid, each corner
		// moved by up to 3 steps of 2^-15 (eps is 2^-14 below 128).
		j :: proc(r: rand.Generator) -> f32 {return f32(rand.int_max(7, r) - 3) / 32768}
		for _ in 0 ..< 1 + rand.int_max(3, r) {
			x, y := grid(r), grid(r)
			w, h := 10 + grid(r) / 2, 10 + grid(r) / 2
			vg.path_move_to(p, x + j(r), y + j(r))
			vg.path_line_to(p, x + w + j(r), y + j(r))
			vg.path_line_to(p, x + w + j(r), y + h + j(r))
			vg.path_line_to(p, x + j(r), y + h + j(r))
			vg.path_close(p)
		}
		for i in 0 ..< 3 + rand.int_max(4, r) {
			x, y := grid(r) + j(r), grid(r) + j(r)
			if i == 0 {
				vg.path_move_to(p, x, y)
			} else {
				vg.path_line_to(p, x, y)
			}
		}
		vg.path_close(p)
	}
}

// Wrong and overlapping samples of `out` against `a op b`.
check :: proc(a, b, out: ^vg.Path, op: vg.Bool_Op, rule: vg.Fill_Rule) -> (wrong, overlapping: int) {
	stack: [dynamic][2]f64
	defer delete(stack)
	N :: 40
	near := 0.15
	for i in 0 ..< N {
		for j in 0 ..< N {
			q := [2]f64{(f64(i) + 0.37) * 100 / N, (f64(j) + 0.61) * 100 / N}
			wa, ona := winding(a, q, near, &stack)
			wb, onb := winding(b, q, near, &stack)
			wr, onr := winding(out, q, near, &stack)
			if ona || onb || onr {
				continue
			}
			ia, ib := cv.fill_inside(wa, rule), cv.fill_inside(wb, rule)
			want: bool
			switch op {
			case .Union:
				want = ia || ib
			case .Intersection:
				want = ia && ib
			case .Difference:
				want = ia && !ib
			case .Xor:
				want = ia != ib
			}
			wrong += int((wr != 0) != want)
			overlapping += int(abs(wr) > 1)
		}
	}
	return
}

// Faults in a result's regions (s.faces): ranges that don't tile its
// contours, a region whose first contour isn't its one Solid contour, and
// samples where the count of regions holding the point isn't 1 inside the
// result and 0 outside it.
check_regions :: proc(s: ^cv.Bool_Scratch) -> (faults: int) {
	c := &s.out
	at := u32(0)
	for r in s.faces {
		faults += int(r.x != at || r.y == 0)
		at = r.x + r.y
		for i in 0 ..< r.y {
			faults += int((cv.contours_area(c, int(r.x + i)) > 0) != (i == 0))
		}
	}
	faults += int(at != u32(len(c.contours)))
	stack: [dynamic][2]f64
	defer delete(stack)
	N :: 40
	near := 0.15
	for i in 0 ..< N {
		for j in 0 ..< N {
			q := [2]f64{(f64(i) + 0.37) * 100 / N, (f64(j) + 0.61) * 100 / N}
			wr, onr := winding(c, q, near, &stack)
			if onr {
				continue
			}
			holding := 0
			for r in s.faces {
				if w, _ := cv.contours_winding(c, int(r.x), int(r.y), q, &stack); w != 0 {
					holding += 1
				}
			}
			faults += int(holding != (1 if wr != 0 else 0))
		}
	}
	return
}

// Samples of a divide where the count of faces holding the point isn't 1
// inside the union and 0 outside it.
check_divide :: proc(a, b, out: ^vg.Path, faces: []vg.Range, inside: []bool) -> (wrong: int) {
	stack: [dynamic][2]f64
	defer delete(stack)
	N :: 40
	near := 0.15
	for i in 0 ..< N {
		for j in 0 ..< N {
			q := [2]f64{(f64(i) + 0.37) * 100 / N, (f64(j) + 0.61) * 100 / N}
			wa, ona := winding(a, q, near, &stack)
			wb, onb := winding(b, q, near, &stack)
			_, ono := winding(out, q, near, &stack)
			if ona || onb || ono {
				continue
			}
			// In exactly one face (a range of out's contours) when inside
			// either operand, and that face says which.
			holding := 0
			for f, fi in faces {
				if w, _ := cv.contours_winding(out, int(f.start), int(f.count), q, &stack); w != 0 {
					holding += 1
					wrong += int(inside[2 * fi] != (wa != 0) || inside[2 * fi + 1] != (wb != 0))
				}
			}
			want := 1 if wa != 0 || wb != 0 else 0
			wrong += int(holding != want)
		}
	}
	return
}

// The winding about q, with `on` when q lies within `near` of an outline:
// a sample that close is skipped (the result may round or merge there).
winding :: proc(c: ^cv.Contours, q: [2]f64, near: f64, stack: ^[dynamic][2]f64) -> (w: i32, on: bool) {
	return cv.contours_winding(c, 0, len(c.contours), q, stack, near)
}
