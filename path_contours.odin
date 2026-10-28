package ovg

import cv "deps:ocurves"

// Paths to contour tables and back: what reads and writes cv.Contours
// (the boolean) takes a Path in and gives one out.

// Appends the contours of `p` under `t` to `c`, as fill draws them
// (path_events): a closing line of non-zero length becomes a Line row, an
// open contour stays open, a contour with no segments is not stored, and
// Solid / Hole wind the current contour as cv.orient does (reversed when
// the sign of its exact area so far disagrees). With `verbs`, each
// segment's verb index in `p` is appended to it.
contours_append_path :: proc(c: ^cv.Contours, p: ^Path, t := TRANSFORM_IDENTITY, verbs: ^[dynamic]u32 = nil) {
	// Size, then fill.
	segs, contours := 0, 0
	it := path_events(p)
	for e in path_events_next(&it) {
		#partial switch e.kind {
		case .Begin:
			contours += 1
		case .Line, .Cubic, .Close:
			segs += 1
		}
	}
	reserve(&c.pts, len(c.pts) + contours + 3 * segs)
	reserve(&c.kinds, len(c.kinds) + segs)
	reserve(&c.contours, len(c.contours) + contours)
	if verbs != nil {
		reserve(verbs, len(verbs) + segs)
	}

	at :: proc(t: Transform2D, p: Vec2) -> Vec2 {
		return transform_point(t, p.x, p.y)
	}
	first := len(c.contours)
	// The current contour: begun once it has a segment (cur >= 0), open
	// until Close or the next Begin.
	cur, open := -1, false
	start: Vec2
	it = path_events(p)
	for e in path_events_next(&it) {
		switch e.kind {
		case .Begin:
			if open {
				cv.contours_end(c, false, false)
			}
			cur, open, start = -1, false, at(t, e.p[0])
		case .Line, .Cubic:
			if !open {
				cv.contours_begin(c, start)
				cur, open = len(c.contours) - 1, true
			}
			if e.kind == .Line {
				cv.contours_line(c, at(t, e.p[1]))
			} else {
				cv.contours_cubic(c, at(t, e.p[1]), at(t, e.p[2]), at(t, e.p[3]))
			}
			if verbs != nil {
				append(verbs, e.verb)
			}
		case .Close:
			if !open {
				continue
			}
			ct := c.contours[cur]
			if s := c.pts[ct.start]; c.pts[len(c.pts) - 1] != s {
				cv.contours_line(c, s)
				if verbs != nil {
					append(verbs, e.verb)
				}
			}
			cv.contours_end(c, true, false)
			open = false
		case .Solid, .Hole:
			if cur < first {
				continue
			}
			ct := &c.contours[cur]
			area: f64
			for s in 0 ..< ct.segs {
				q := c.pts[ct.start + 3 * s:][:4]
				area += cv.cubic_area([4][2]f64{to_f64(q[0]), to_f64(q[1]), to_f64(q[2]), to_f64(q[3])})
			}
			if (e.kind == .Solid && area < 0) || (e.kind == .Hole && area > 0) {
				cv.contours_reverse(c, cur)
			}
		}
	}
	if open {
		cv.contours_end(c, false, false)
	}
}

// Appends contours [first, first + count) of `c` to `p` under `t`: Line
// rows as Line_To, Cubic rows as Bezier_To, a closed contour's last Line
// row (back to its start) as the Close alone.
path_append_contours :: proc(p: ^Path, c: ^cv.Contours, first, count: u32, t := TRANSFORM_IDENTITY) {
	// Size, then fill.
	nv, nc := 0, 0
	for ct in c.contours[first:][:count] {
		nv, nc = nv + 1, nc + 1
		for s in 0 ..< ct.segs {
			if ct.closed && s == ct.segs - 1 && c.kinds[ct.seg + s] == .Line {
				continue
			}
			nv += 1
			nc += 1 if c.kinds[ct.seg + s] == .Line else 3
		}
		if ct.closed {
			nv += 1
		}
	}
	reserve(&p.verbs, len(p.verbs) + nv)
	reserve(&p.coords, len(p.coords) + nc)
	at :: proc(t: Transform2D, p: Vec2) -> Vec2 {
		return transform_point(t, p.x, p.y)
	}
	for ct in c.contours[first:][:count] {
		append(&p.verbs, Verb.Move_To)
		append(&p.coords, at(t, c.pts[ct.start]))
		for s in 0 ..< ct.segs {
			q := c.pts[ct.start + 3 * s:][:4]
			switch c.kinds[ct.seg + s] {
			case .Line:
				if ct.closed && s == ct.segs - 1 {
					continue
				}
				append(&p.verbs, Verb.Line_To)
				append(&p.coords, at(t, q[3]))
			case .Cubic:
				append(&p.verbs, Verb.Bezier_To)
				append(&p.coords, at(t, q[1]), at(t, q[2]), at(t, q[3]))
			}
		}
		if ct.closed {
			append(&p.verbs, Verb.Close)
		}
	}
	if len(p.coords) > 0 {
		p.last_pos = p.coords[len(p.coords) - 1]
	}
}

@(private = "file")
to_f64 :: #force_inline proc "contextless" (v: Vec2) -> [2]f64 {
	return {f64(v.x), f64(v.y)}
}
