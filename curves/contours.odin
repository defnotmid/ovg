package curves

import "core:slice"

// Contours of lines and cubics in one flat table: every contour's points in
// `pts` (its start point, then three per segment: two controls and the
// end), each segment's kind in `kinds`, a row per contour. Segment s of
// contour c is pts[c.start + 3 * s:][:4]; neighbours share their end point
// by index, so continuity is exact. A line segment keeps its thirds as
// controls so readers that treat every segment as a cubic stay right;
// readers that care about kinds use only its ends.

Seg_Kind :: enum u8 {
	Line,
	Cubic,
}

Contour :: struct {
	start:  u32, // index of its start point in pts
	seg:    u32, // index of its first segment in kinds
	segs:   u32,
	closed: bool,
}

Contours :: struct {
	pts:      [dynamic]Vec2,
	kinds:    [dynamic]Seg_Kind,
	contours: [dynamic]Contour,
}

contours_init :: proc(c: ^Contours, allocator := context.allocator) {
	c^ = {}
	c.pts.allocator, c.kinds.allocator, c.contours.allocator = allocator, allocator, allocator
}

contours_destroy :: proc(c: ^Contours) {
	delete(c.pts)
	delete(c.kinds)
	delete(c.contours)
	c^ = {}
}

contours_clear :: proc(c: ^Contours) {
	clear(&c.pts)
	clear(&c.kinds)
	clear(&c.contours)
}

// Starts a contour at p.
contours_begin :: proc(c: ^Contours, p: Vec2) {
	append(&c.contours, Contour{start = u32(len(c.pts)), seg = u32(len(c.kinds))})
	append(&c.pts, p)
}

// Appends a segment of `kind` to the open contour.
contours_segment :: proc(c: ^Contours, kind: Seg_Kind, c1, c2, p: Vec2) {
	append(&c.pts, c1, c2, p)
	append(&c.kinds, kind)
	c.contours[len(c.contours) - 1].segs += 1
}

contours_cubic :: proc(c: ^Contours, c1, c2, p: Vec2) {
	contours_segment(c, .Cubic, c1, c2, p)
}

contours_line :: proc(c: ^Contours, p: Vec2) {
	a := c.pts[len(c.pts) - 1]
	contours_segment(c, .Line, a + (p - a) / 3, a + (p - a) * (2.0 / 3), p)
}

// Ends the open contour, reversing it if asked.
contours_end :: proc(c: ^Contours, closed, reversed: bool) {
	c.contours[len(c.contours) - 1].closed = closed
	if reversed {
		contours_reverse(c, len(c.contours) - 1)
	}
}

// The winding of q about contours [first, first + count), an open contour
// closed by a line (as fills close it): exact, by curve_winding. `on`
// reports q on an outline.
contours_winding :: proc(c: ^Contours, first, count: int, q: [2]f64, stack: ^[dynamic][2]f64) -> (w: i32, on: bool) {
	f :: #force_inline proc "contextless" (v: Vec2) -> [2]f64 {
		return {f64(v.x), f64(v.y)}
	}
	for ct in c.contours[first:][:count] {
		pts := c.pts[ct.start:][:3 * ct.segs + 1]
		for i in 0 ..< ct.segs {
			s := pts[3 * i:][:4]
			cw, con := curve_winding({f(s[0]), f(s[1]), f(s[2]), f(s[3])}, q, 0, stack)
			w += cw
			on ||= con
		}
		if a, b := pts[len(pts) - 1], pts[0]; a != b {
			cw, con := curve_winding({f(a), f(a + (b - a) / 3), f(a + (b - a) * (2.0 / 3)), f(b)}, q, 0, stack)
			w += cw
			on ||= con
		}
	}
	return
}

// Reverses contour i in place: its points and its segments' kinds.
contours_reverse :: proc(c: ^Contours, i: int) {
	ct := c.contours[i]
	slice.reverse(c.pts[ct.start:][:ct.segs * 3 + 1])
	slice.reverse(c.kinds[ct.seg:][:ct.segs])
}
