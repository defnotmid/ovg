package ovg

import "core:math"

import cv "curves"

// Dashes `src` into `dst` (SVG stroke-dasharray / stroke-dashoffset /
// pathLength: when `total_length` > 0, dash lengths are fractions of it).
// Curves stay curves: a cubic is cut at the dash ends, found along it by
// arc length (`flat`, scratch reused across calls, measures the path, and
// each cubic's lengths come from its samples there). The
// dash pattern runs on across segments and restarts at each subpath, as in
// SVG. A pattern that would make more than `max_dashes` dashes leaves the
// path undashed (as Skia; dashes that fine look solid) and returns false.
// Allocates nothing once `flat` and `dst` have grown.
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

	length := path_length(src, flat)
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
	// Bounds the walk too, where f32 positions could stop advancing.
	d := Dasher {
		dst    = dst,
		dashes = dashes,
		n      = n,
		scale  = scale,
		budget = max_dashes,
	}
	start, pen: Vec2
	open := false
	// The flattened samples of each drawing segment, in the same order.
	seg := 0
	samples :: proc(flat: ^Flat_Path, seg: ^int) -> []Vec2 {
		fs := flat.segs[seg^]
		seg^ += 1
		return flat.points[fs.first:][:fs.count]
	}
	it := path_iter(src)
	for verb, coords in path_iter_next(&it) {
		ok := true
		switch verb {
		case .Move_To:
			start, pen, open = coords[0], coords[0], true
			// Where in the pattern the subpath starts.
			phase := math.mod(offset * scale, total * scale)
			if phase < 0 {
				phase += total * scale
			}
			d.idx = 0
			for phase >= dash_length(&d) {
				phase -= dash_length(&d)
				d.idx = (d.idx + 1) % n
			}
			d.remaining = dash_length(&d) - phase
			d.on = d.idx % 2 == 0
			if d.on {
				path_move_to(dst, pen.x, pen.y)
			}
		case .Line_To:
			if open {
				ok = dash_segment(&d, {pen, pen, coords[0], coords[0]}, samples(flat, &seg))
				pen = coords[0]
			}
		case .Bezier_To:
			if open {
				ok = dash_segment(&d, {pen, coords[0], coords[1], coords[2]}, samples(flat, &seg), true)
				pen = coords[2]
			}
		case .Close:
			if open {
				ok = dash_segment(&d, {pen, pen, start, start}, samples(flat, &seg))
				pen = start
			}
		case .Solid, .Hole:
		}
		if !ok {
			undashed(src, dst)
			return false
		}
	}
	return true
}

@(private = "file")
Dasher :: struct {
	dst:       ^Path,
	dashes:    []f32,
	n:         int,
	scale:     f32,
	// The pattern: its entry, what is left of it, whether it draws.
	idx:       int,
	remaining: f32,
	on:        bool,
	budget:    int,
}

@(private = "file")
dash_length :: #force_inline proc "contextless" (d: ^Dasher) -> f32 {
	return d.dashes[d.idx % len(d.dashes)] * d.scale
}

// Walks the pattern along one segment (a line from c[0] to c[3], or a
// cubic whose flattened `samples` at t = k / len(samples) measure it): the
// parts that draw go to the path as lines or cubics.
@(private = "file")
dash_segment :: proc(d: ^Dasher, c: [4]Vec2, samples: []Vec2, cubic := false) -> bool {
	seg := vec_len(c[3] - c[0])
	// Arc length and t at each sample (at most 256 a cubic).
	lengths: [257]Vec2
	steps := 1
	if cubic {
		steps = len(samples)
		seg = 0
		prev := c[0]
		for q, k in samples {
			seg += vec_len(q - prev)
			lengths[k + 1] = {seg, f32(k + 1) / f32(steps)}
			prev = q
		}
	}
	// t at arc length s, reading the table forward.
	at := 0
	t_at :: proc(l: []Vec2, s, seg: f32, cubic: bool, at: ^int) -> f32 {
		if !cubic {
			return s / seg if seg > 0 else 1
		}
		for at^ < len(l) - 2 && l[at^ + 1].x < s {
			at^ += 1
		}
		a, b := l[at^], l[at^ + 1]
		return a.y + (b.y - a.y) * ((s - a.x) / (b.x - a.x) if b.x > a.x else 0)
	}
	draw :: proc(d: ^Dasher, c: [4]Vec2, cubic: bool, t0, t1: f32) {
		if !cubic {
			p := c[0] + (c[3] - c[0]) * t1
			path_line_to(d.dst, p.x, p.y)
			return
		}
		q := cv.cubic_range(c, t0, t1)
		path_bezier_to(d.dst, q[1].x, q[1].y, q[2].x, q[2].y, q[3].x, q[3].y)
	}
	pos, from: f32 = 0, 0
	for seg - pos > d.remaining {
		if d.budget -= 1; d.budget < 0 {
			return false
		}
		pos += d.remaining
		t := t_at(lengths[:steps + 1], pos, seg, cubic, &at)
		if d.on {
			draw(d, c, cubic, from, t)
		} else {
			p := cv.cubic_at(c, t) if cubic else c[0] + (c[3] - c[0]) * t
			path_move_to(d.dst, p.x, p.y)
		}
		from = t
		d.on = !d.on
		d.idx = (d.idx + 1) % d.n
		d.remaining = dash_length(d)
		if d.remaining <= 0 {
			d.remaining = 1e-6
		}
	}
	d.remaining -= seg - pos
	if d.on {
		draw(d, c, cubic, from, 1)
	}
	return true
}


// A path flattened to polylines: every contour's points in one array, each
// contour a range of it (closed ones end on their first point), and each
// drawing segment (line, cubic, closing line) the range of samples it added.
Flat_Path :: struct {
	points:   [dynamic]Vec2,
	contours: [dynamic]Flat_Contour,
	segs:     [dynamic]Flat_Segment,
}

Flat_Segment :: struct {
	first, count: u32,
}

Flat_Contour :: struct {
	first, count: u32,
	closed:       bool,
}

// A flattened path allocating from `allocator`.
flat_path_init :: proc(f: ^Flat_Path, allocator := context.allocator) {
	f^ = {}
	f.points.allocator, f.contours.allocator, f.segs.allocator = allocator, allocator, allocator
}

flat_path_destroy :: proc(f: ^Flat_Path) {
	delete(f.points)
	delete(f.contours)
	delete(f.segs)
	f^ = {}
}

// Flattens `p` into `out` (cleared first). Curves are split into segments
// of about `segment` units (at most 256 a curve); contours of fewer than two
// points are dropped.
path_flatten :: proc(p: ^Path, out: ^Flat_Path, segment: f32 = 1.5) {
	path_flatten_verbs(p.verbs[:], p.coords[:], out, segment)
}

// `path_flatten` of a path held as its verbs and coordinates.
path_flatten_verbs :: proc(verbs: []Verb, coords: []Vec2, out: ^Flat_Path, segment: f32 = 1.5) {
	clear(&out.points)
	clear(&out.contours)
	clear(&out.segs)
	open := false
	end :: proc(out: ^Flat_Path) {
		ct := &out.contours[len(out.contours) - 1]
		ct.count = u32(len(out.points)) - ct.first
		if ct.count < 2 {
			resize(&out.points, int(ct.first))
			pop(&out.contours)
		}
	}
	at := 0
	for verb in verbs {
		c := coords[at:][:verb_num_coords(verb)]
		at += len(c)
		switch verb {
		case .Move_To:
			if open {
				end(out)
			}
			append(&out.contours, Flat_Contour{first = u32(len(out.points))})
			append(&out.points, c[0])
			open = true
		case .Line_To:
			if open {
				append(&out.segs, Flat_Segment{u32(len(out.points)), 1})
				append(&out.points, c[0])
			}
		case .Bezier_To:
			if !open {
				continue
			}
			p0 := out.points[len(out.points) - 1]
			c1, c2, p3 := c[0], c[1], c[2]
			approx := vec_len(c1 - p0) + vec_len(c2 - c1) + vec_len(p3 - c2)
			n := clamp(int(approx / segment), 2, 256)
			append(&out.segs, Flat_Segment{u32(len(out.points)), u32(n)})
			for k in 1 ..= n {
				append(&out.points, cv.cubic_at([4]Vec2{p0, c1, c2, p3}, f32(k) / f32(n)))
			}
		case .Close:
			if open {
				ct := &out.contours[len(out.contours) - 1]
				ct.closed = true
				append(&out.segs, Flat_Segment{u32(len(out.points)), 1})
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
