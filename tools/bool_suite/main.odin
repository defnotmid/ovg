// Fuzzes the path booleans: random operands (polygons, self-crossing ones
// included, cubic blobs, circles, rects on a coarse grid so edges and
// corners coincide, tangent circles), every op under both fill rules,
// checked by membership on a grid away from the outlines (the result fills
// a point exactly when the op of the operands' fills does, with winding
// at most 1 so no output contours overlap).
//
//     odin run tools/bool_suite -collection:deps=.. -o:speed -- [-seed:1] [-cases:500] [-v]
package bool_suite

import "core:fmt"
import "core:math"
import "core:math/rand"
import "core:os"
import "core:strconv"
import "core:strings"

import vg "deps:ovg"
import cv "deps:ovg/curves"

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
	errors, wrong, overlapping, checked := 0, 0, 0, 0
	for n in 0 ..< cases {
		case_seed := seed * 1_000_003 + u64(n)
		gen := rand.create(case_seed)
		r := rand.default_random_generator(&gen)
		a, b: vg.Path
		defer vg.path_destroy(&a)
		defer vg.path_destroy(&b)
		kind := rand.int_max(6, r)
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
				checked += 1
				wrong += int(w > 0)
				overlapping += int(o > 0)
				if (w > 0 || o > 0) && verbose {
					fmt.printfln("seed %d kind %d %v %v: %d wrong, %d overlapping samples", case_seed, kind, op, rule, w, o)
				}
			}
		}
	}
	fmt.printfln("%d cases, %d results checked: %d errors, %d wrong, %d overlapping", cases, checked, errors, wrong, overlapping)
	if errors + wrong + overlapping > 0 {
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
	}
}

// Wrong and overlapping samples of `out` against `a op b`.
check :: proc(a, b, out: ^vg.Path, op: vg.Bool_Op, rule: vg.Fill_Rule) -> (wrong, overlapping: int) {
	ca, cb, co: cv.Contours
	defer cv.contours_destroy(&ca)
	defer cv.contours_destroy(&cb)
	defer cv.contours_destroy(&co)
	vg.contours_append_path(&ca, a)
	vg.contours_append_path(&cb, b)
	vg.contours_append_path(&co, out)
	stack: [dynamic][2]f64
	defer delete(stack)
	N :: 40
	near := 0.15
	for i in 0 ..< N {
		for j in 0 ..< N {
			q := [2]f64{(f64(i) + 0.37) * 100 / N, (f64(j) + 0.61) * 100 / N}
			wa, ona := winding(&ca, q, near, &stack)
			wb, onb := winding(&cb, q, near, &stack)
			wr, onr := winding(&co, q, near, &stack)
			if ona || onb || onr {
				continue
			}
			eo := rule == .Even_Odd
			ia, ib := cv.fill_inside(wa, eo), cv.fill_inside(wb, eo)
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

// The winding about q, with `on` when q lies within `near` of an outline:
// a sample that close is skipped (the result may round or merge there).
winding :: proc(c: ^cv.Contours, q: [2]f64, near: f64, stack: ^[dynamic][2]f64) -> (w: i32, on: bool) {
	f :: proc(v: [2]f32) -> [2]f64 {return {f64(v.x), f64(v.y)}}
	for ct in c.contours {
		pts := c.pts[ct.start:][:3 * ct.segs + 1]
		segs := [dynamic][4][2]f64{}
		defer delete(segs)
		for i in 0 ..< ct.segs {
			append(&segs, [4][2]f64{f(pts[3 * i]), f(pts[3 * i + 1]), f(pts[3 * i + 2]), f(pts[3 * i + 3])})
		}
		if l, s := pts[len(pts) - 1], pts[0]; l != s {
			append(&segs, [4][2]f64{f(l), f(l + (s - l) / 3), f(l + (s - l) * (2.0 / 3)), f(s)})
		}
		for g in segs {
			lo, hi := cv.box_of(g)
			if q.x < lo.x - near || q.x > hi.x + near || q.y < lo.y - near || q.y > hi.y + near {
				cw, _ := cv.curve_winding(g, q, 0, stack)
				w += cw
				continue
			}
			// Close to this segment's box: measure the distance.
			for k in 0 ..= 64 {
				d := cv.cubic_at(g, f64(k) / 64) - q
				if math.sqrt(d.x * d.x + d.y * d.y) < near {
					on = true
				}
			}
			cw, con := cv.curve_winding(g, q, 1e-9, stack)
			w += cw
			on ||= con
		}
	}
	return
}
