package ovg

import "core:math"

// Dashes `src` into `dst` (SVG stroke-dasharray / stroke-dashoffset /
// pathLength: when `total_length` > 0, dash lengths are fractions of it).
// Curves are flattened first (into `flat`, scratch reused across calls);
// the dash pattern runs on across segments and restarts at each subpath,
// as in SVG. A pattern that would make more than `max_dashes` dashes
// leaves the path undashed (as Skia; dashes that fine look solid) and
// returns false. Allocates nothing once `flat` and `dst` have grown.
path_dash :: proc(src: ^Path, dashes: []f32, offset: f32, total_length: f32, dst: ^Path, flat: ^Flat_Path, max_dashes := DEFAULT_LIMITS[.Dash_Segments]) -> bool {
	undashed :: proc(src, dst: ^Path) {
		path_reset(dst)
		append(&dst.verbs, ..src.verbs[:])
		append(&dst.coords, ..src.coords[:])
	}
	total: f32 = 0
	for d in dashes {
		total += max(d, 0)
	}
	if total <= 0 {
		undashed(src, dst)
		return true
	}
	// An odd count repeats the list (SVG): the pattern reads it modulo.
	n := len(dashes) * (2 if len(dashes) % 2 == 1 else 1)
	if n > len(dashes) {
		total *= 2
	}

	path_flatten(src, flat)
	length := flat_path_length(flat)
	scale: f32 = 1
	if total_length > 0 {
		scale = length / total_length
	}
	if period := total * scale; !(period > 0) || math.is_inf(period) {
		undashed(src, dst)
		return true
	}
	if f64(length) / f64(total * scale) * f64(n) + f64(len(flat.contours)) > f64(max_dashes) {
		undashed(src, dst)
		return false
	}
	// Bounds the loop below too, where f32 positions could stop advancing.
	budget := max_dashes
	dash :: #force_inline proc "contextless" (dashes: []f32, i: int) -> f32 {
		return dashes[i % len(dashes)]
	}

	for ct in flat.contours {
		pts := flat.points[ct.first:][:ct.count]
		// Where in the pattern the subpath starts.
		phase := math.mod(offset * scale, total * scale)
		if phase < 0 {
			phase += total * scale
		}
		idx := 0
		for phase >= dash(dashes, idx) * scale {
			phase -= dash(dashes, idx) * scale
			idx = (idx + 1) % n
		}
		remaining := dash(dashes, idx) * scale - phase
		on := idx % 2 == 0
		if on {
			path_move_to(dst, pts[0].x, pts[0].y)
		}
		for k in 1 ..< len(pts) {
			a, b := pts[k - 1], pts[k]
			seg := vec_len(b - a)
			pos: f32 = 0
			for seg - pos > remaining {
				if budget -= 1; budget < 0 {
					undashed(src, dst)
					return false
				}
				pos += remaining
				p := a + (b - a) * (pos / seg)
				if on {
					path_line_to(dst, p.x, p.y)
				} else {
					path_move_to(dst, p.x, p.y)
				}
				on = !on
				idx = (idx + 1) % n
				remaining = dash(dashes, idx) * scale
				if remaining <= 0 {
					remaining = 1e-6
				}
			}
			remaining -= seg - pos
			if on {
				path_line_to(dst, b.x, b.y)
			}
		}
	}
	return true
}

@(private = "file")
vec_len :: #force_inline proc "contextless" (v: Vec2) -> f32 {
	return math.sqrt(v.x * v.x + v.y * v.y)
}

// A path flattened to polylines: every contour's points in one array, each
// contour a range of it (closed ones end on their first point).
Flat_Path :: struct {
	points:   [dynamic]Vec2,
	contours: [dynamic]Flat_Contour,
}

Flat_Contour :: struct {
	first, count: u32,
	closed:       bool,
}

flat_path_destroy :: proc(f: ^Flat_Path) {
	delete(f.points)
	delete(f.contours)
	f^ = {}
}

// Flattens `p` into `out` (cleared first). Curves are split into segments
// of about 1.5 units; contours of fewer than two points are dropped.
path_flatten :: proc(p: ^Path, out: ^Flat_Path) {
	clear(&out.points)
	clear(&out.contours)
	open := false
	end :: proc(out: ^Flat_Path) {
		ct := &out.contours[len(out.contours) - 1]
		ct.count = u32(len(out.points)) - ct.first
		if ct.count < 2 {
			resize(&out.points, int(ct.first))
			pop(&out.contours)
		}
	}
	it := path_iter(p)
	for verb, coords in path_iter_next(&it) {
		switch verb {
		case .Move_To:
			if open {
				end(out)
			}
			append(&out.contours, Flat_Contour{first = u32(len(out.points))})
			append(&out.points, coords[0])
			open = true
		case .Line_To:
			if open {
				append(&out.points, coords[0])
			}
		case .Bezier_To:
			if !open {
				continue
			}
			p0 := out.points[len(out.points) - 1]
			c1, c2, p3 := coords[0], coords[1], coords[2]
			approx := vec_len(c1 - p0) + vec_len(c2 - c1) + vec_len(p3 - c2)
			n := clamp(int(approx / 1.5), 2, 256)
			for k in 1 ..= n {
				t := f32(k) / f32(n)
				u := 1 - t
				append(&out.points, p0 * (u * u * u) + c1 * (3 * u * u * t) + c2 * (3 * u * t * t) + p3 * (t * t * t))
			}
		case .Close:
			if open {
				ct := &out.contours[len(out.contours) - 1]
				ct.closed = true
				append(&out.points, out.points[ct.first])
			}
		case .Solid, .Hole:
		}
	}
	if open {
		end(out)
	}
}

// Total length of a flattened path's segments.
flat_path_length :: proc(f: ^Flat_Path) -> f32 {
	length: f32 = 0
	for ct in f.contours {
		pts := f.points[ct.first:][:ct.count]
		for k in 1 ..< len(pts) {
			length += vec_len(pts[k] - pts[k - 1])
		}
	}
	return length
}

// Total length of the path's segments (curves flattened into `scratch`).
path_length :: proc(p: ^Path, scratch: ^Flat_Path) -> f32 {
	path_flatten(p, scratch)
	return flat_path_length(scratch)
}
