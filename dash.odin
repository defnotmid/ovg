package ovg

import "core:math"

// Dashes `src` into `dst` (SVG stroke-dasharray / stroke-dashoffset /
// pathLength: when `total_length` > 0, dash lengths are fractions of it).
// Curves are flattened first; the dash pattern runs on across
// segments and restarts at each subpath, as in SVG. A pattern that would
// make more than `max_dashes` dashes leaves the path undashed (as Skia;
// dashes that fine look solid) and returns false.
path_dash :: proc(src: ^Path, dashes: []f32, offset: f32, total_length: f32, dst: ^Path, max_dashes := DEFAULT_LIMITS[.Dash_Segments]) -> bool {
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
	// An odd count repeats the list (SVG).
	pattern := make([dynamic]f32, context.temp_allocator)
	append(&pattern, ..dashes)
	if len(dashes) % 2 == 1 {
		append(&pattern, ..dashes)
		total *= 2
	}

	polylines := path_flatten(src)
	length: f32 = 0
	for pl in polylines {
		for k in 1 ..< len(pl.points) {
			length += vec_len(pl.points[k] - pl.points[k - 1])
		}
	}
	scale: f32 = 1
	if total_length > 0 {
		scale = length / total_length
	}
	if period := total * scale; !(period > 0) || math.is_inf(period) {
		undashed(src, dst)
		return true
	}
	if f64(length) / f64(total * scale) * f64(len(pattern)) + f64(len(polylines)) > f64(max_dashes) {
		undashed(src, dst)
		return false
	}
	// Bounds the loop below too, where f32 positions could stop advancing.
	budget := max_dashes

	for pl in polylines {
		// Where in the pattern the subpath starts.
		phase := math.mod(offset * scale, total * scale)
		if phase < 0 {
			phase += total * scale
		}
		idx := 0
		for phase >= pattern[idx] * scale {
			phase -= pattern[idx] * scale
			idx = (idx + 1) % len(pattern)
		}
		remaining := pattern[idx] * scale - phase
		on := idx % 2 == 0
		if on {
			path_move_to(dst, pl.points[0].x, pl.points[0].y)
		}
		for k in 1 ..< len(pl.points) {
			a, b := pl.points[k - 1], pl.points[k]
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
				idx = (idx + 1) % len(pattern)
				remaining = pattern[idx] * scale
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

Polyline :: struct {
	points: [dynamic]Vec2,
	closed: bool,
}

// The path as polylines (closed ones end on their first point). Curves are
// split into segments of about 1.5 units.
path_flatten :: proc(p: ^Path) -> []Polyline {
	out := make([dynamic]Polyline, context.temp_allocator)
	cur: ^Polyline
	it := path_iter(p)
	for verb, coords in path_iter_next(&it) {
		switch verb {
		case .Move_To:
			append(&out, Polyline{points = make([dynamic]Vec2, context.temp_allocator)})
			cur = &out[len(out) - 1]
			append(&cur.points, coords[0])
		case .Line_To:
			if cur == nil {continue}
			append(&cur.points, coords[0])
		case .Bezier_To:
			if cur == nil {continue}
			p0 := cur.points[len(cur.points) - 1]
			c1, c2, p3 := coords[0], coords[1], coords[2]
			approx := vec_len(c1 - p0) + vec_len(c2 - c1) + vec_len(p3 - c2)
			n := clamp(int(approx / 1.5), 2, 256)
			for k in 1 ..= n {
				t := f32(k) / f32(n)
				u := 1 - t
				append(&cur.points, p0 * (u * u * u) + c1 * (3 * u * u * t) + c2 * (3 * u * t * t) + p3 * (t * t * t))
			}
		case .Close:
			if cur == nil {continue}
			cur.closed = true
			append(&cur.points, cur.points[0])
		case .Solid, .Hole:
		}
	}
	result := make([dynamic]Polyline, context.temp_allocator)
	for pl in out {
		if len(pl.points) >= 2 {
			append(&result, pl)
		}
	}
	return result[:]
}

// Total length of the path's segments (curves flattened).
path_length :: proc(p: ^Path) -> f32 {
	length: f32 = 0
	for pl in path_flatten(p) {
		for k in 1 ..< len(pl.points) {
			length += vec_len(pl.points[k] - pl.points[k - 1])
		}
	}
	return length
}
