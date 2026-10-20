// Shapes as curves for exact per-pixel coverage. Core only: ovg's shapes
// (shape.odin) and other renderers share it, and shaders/curves.slang is its
// GPU twin.
//
// A shape is quadratic Bézier curves split so each is monotone in x and y,
// then cut at the vertical lines of a grid of cells, so every piece lies in
// one column. A cell lists the pieces crossing it and its backdrop: the
// winding number just right of its right edge, as it varies over the
// cell's rows (a value at the bottom and the steps where curves cross the
// edge; nothing else changes it).
//
// A pixel's coverage is the area of its footprint inside the shape: the
// parallelogram the pixel's sides span in shape units (an axis-aligned box
// under scales and translations: `coverage`; `coverage_affine` for the
// rest). By Green's theorem that area is the sum, over the curves crossing
// the footprint's rows, of the length of each row left of the crossing. In
// a row of cells the curves right of the footprint's last column add the
// backdrop times the rows' widths, a closed form; only the pieces in the
// cells the footprint covers are integrated (in closed form too), and only
// the few crossing the footprint need root finding. So a pixel's cost is
// the pieces near it, not the shape's size, and an interior pixel reads its
// cell and nothing more. Exact for any affine footprint (rotation, skew,
// the anisotropic footprints of 3D), up to the non-zero rule where contours
// overlap within the pixel: the signed area counts an overlap twice.
//
// A built shape is one block of 32-bit words, read as is from a storage
// buffer (std430: an array of uint; coordinates are float32 bit patterns);
// every offset is relative to the shape's first word, so one buffer holds
// many shapes:
//
//	[0] columns nx                [1] rows ny
//	[2] cell width (f32)          [3] cell height (f32)
//	[4] 0 (reserved)              [5] 0 (reserved)
//	[6] word offset of the curves [7] mean coverage (f32)
//	[8..11] bounds min x, min y, max x, max y (f32)
//	[12..] each cell, row by row: word offset of its piece list, piece
//	       count | step count << 16, backdrop at its bottom (i32), word
//	       offset of its steps; then the lists (piece indices), the steps
//	       (y f32, change i32: the backdrop is the bottom value plus the
//	       changes at or below y), and the pieces, six f32 each (p1, p2, p3;
//	       p2 within the box of p1 and p3).
//
// Cell (i, j) spans x in [i, i + 1] * width, y in [j, j + 1] * height;
// pieces are in shape units: the source scaled so the shape's larger side is
// 1 (bounds start at 0); `build` returns the scale and origin back to source
// units. A piece is listed in every row it crosses.
//
// The mean coverage is the fraction of the bounds the shape fills (exact,
// non-zero): what a pixel covering the whole shape sees (`fade`).
package curves

import "core:math"
import "core:slice"

Vec2 :: [2]f32

Curve :: struct {
	p1, p2, p3: Vec2,
}

HEADER :: 12
// Columns or rows at most.
MAX_CELLS :: 16

// ---- building -------------------------------------------------------------------

// Collects contours as quadratic curves: a line's control point is its
// midpoint (linear in t, so solving it needs no root), cubics split into
// quadratics within `tol`.
Builder :: struct {
	curves:      [dynamic]Curve,
	start, last: Vec2,
	open:        bool,
	// Where the current contour's curves start.
	contour:     int,
	// Cubic approximation tolerance in source units; 0 picks 1/4096 of the
	// cubic's size.
	tol:         f32,
}

// A contour's required orientation (`orient`).
Orientation :: enum u8 {
	// Positive area (with y down: counter-clockwise on screen, as
	// ovg's path_rect).
	Solid,
	Hole,
}

builder_destroy :: proc(b: ^Builder) {
	delete(b.curves)
	b^ = {}
}

builder_reset :: proc(b: ^Builder) {
	clear(&b.curves)
	b.open = false
	b.contour = 0
}

move_to :: proc(b: ^Builder, p: Vec2) {
	close(b)
	b.start, b.last, b.open = p, p, true
	b.contour = len(b.curves)
}

line_to :: proc(b: ^Builder, p: Vec2) {
	if p != b.last {
		append(&b.curves, Curve{b.last, (b.last + p) * 0.5, p})
	}
	b.last = p
}

quad_to :: proc(b: ^Builder, c, p: Vec2) {
	if c == b.last || c == p {
		line_to(b, p)
		return
	}
	append(&b.curves, Curve{b.last, c, p})
	b.last = p
}

cubic_to :: proc(b: ^Builder, c1, c2, p: Vec2) {
	p0 := b.last
	// A raised quadratic comes back exactly.
	q1 := (3 * c1 - p0) * 0.5
	q2 := (3 * c2 - p) * 0.5
	size := max(abs(p.x - p0.x), abs(p.y - p0.y), abs(c1.x - p0.x), abs(c1.y - p0.y), abs(c2.x - p0.x), abs(c2.y - p0.y))
	if abs(q1.x - q2.x) <= size * 1e-5 && abs(q1.y - q2.y) <= size * 1e-5 {
		quad_to(b, (q1 + q2) * 0.5, p)
		return
	}
	// n quadratics, each the midpoint approximation of its piece: error
	// below sqrt(3)/36 |p - 3 c2 + 3 c1 - p0| / n^3.
	tol := b.tol if b.tol > 0 else max(size, 1e-6) / 4096
	d := p - 3 * c2 + 3 * c1 - p0
	e := math.sqrt(f32(3)) / 36 * math.hypot(d.x, d.y)
	n := clamp(int(math.ceil(math.cbrt(e / tol))), 1, 64)
	for i in 0 ..< n {
		t0, t1 := f32(i) / f32(n), f32(i + 1) / f32(n)
		a0, a1, a2, a3 := cubic_piece(p0, c1, c2, p, t0, t1)
		quad_to(b, (3 * (a1 + a2) - a0 - a3) * 0.25, a3 if i < n - 1 else p)
	}
}

close :: proc(b: ^Builder) {
	if b.open {
		line_to(b, b.start)
		b.open = false
	}
}

// Winds the current contour as `o` requires, reversing it if needed.
orient :: proc(b: ^Builder, o: Orientation) {
	curves := b.curves[b.contour:]
	area: f32
	for c in curves {
		area += (c.p2.x - c.p1.x) * (c.p2.y + c.p1.y) + (c.p3.x - c.p2.x) * (c.p3.y + c.p2.y)
	}
	if (o == .Solid && area < 0) || (o == .Hole && area > 0) {
		slice.reverse(curves)
		for &c in curves {
			c.p1, c.p3 = c.p3, c.p1
		}
		if b.open {
			// The contour now starts where it ended.
			b.start, b.last = b.last, b.start
		}
	}
}

// The control points of the cubic restricted to [t0, t1].
@(private = "file")
cubic_piece :: proc "contextless" (p0, p1, p2, p3: Vec2, t0, t1: f32) -> (a, b, c, d: Vec2) {
	at :: proc "contextless" (p0, p1, p2, p3: Vec2, t: f32) -> Vec2 {
		u := 1 - t
		return u * u * u * p0 + 3 * u * u * t * p1 + 3 * u * t * t * p2 + t * t * t * p3
	}
	tangent :: proc "contextless" (p0, p1, p2, p3: Vec2, t: f32) -> Vec2 {
		u := 1 - t
		return 3 * (u * u * (p1 - p0) + 2 * u * t * (p2 - p1) + t * t * (p3 - p2))
	}
	h := (t1 - t0) / 3
	a = at(p0, p1, p2, p3, t0)
	d = at(p0, p1, p2, p3, t1)
	b = a + tangent(p0, p1, p2, p3, t0) * h
	c = d - tangent(p0, p1, p2, p3, t1) * h
	return
}

// The shape's words from the builder's curves (closing the open contour),
// with the map back to source units: `p = origin + q * extent`. False (no
// words) when there are no curves or they span nothing.
build :: proc(b: ^Builder, allocator := context.allocator) -> (words: []u32, origin: Vec2, extent: f32, ok: bool) {
	close(b)
	if len(b.curves) == 0 {
		return
	}
	mono := make([dynamic]Curve, 0, len(b.curves) * 2, context.temp_allocator)
	for c in b.curves {
		split_monotone(c, &mono)
	}
	lo, hi := mono[0].p1, mono[0].p1
	for c in mono {
		for p in ([3]Vec2{c.p1, c.p2, c.p3}) {
			lo = {min(lo.x, p.x), min(lo.y, p.y)}
			hi = {max(hi.x, p.x), max(hi.y, p.y)}
		}
	}
	extent = max(hi.x - lo.x, hi.y - lo.y)
	if extent <= 0 {
		return
	}
	origin = lo
	inv := 1 / extent
	for &c in mono {
		c = {(c.p1 - lo) * inv, (c.p2 - lo) * inv, (c.p3 - lo) * inv}
	}
	size := (hi - lo) * inv

	// The grid: the cell size (of n per unit) keeping the fullest cell
	// smallest, fewer cells on a tie.
	nx, ny: int
	cw, ch: f32
	pieces: [dynamic]Curve
	best := max(int)
	for n in 1 ..= MAX_CELLS {
		cx, cy := max(1, int(math.ceil(size.x * f32(n) - 1e-4))), max(1, int(math.ceil(size.y * f32(n) - 1e-4)))
		w, h := size.x / f32(cx), size.y / f32(cy)
		split := make([dynamic]Curve, context.temp_allocator)
		for c in mono {
			split_columns(c, w, cx, &split)
		}
		counts := make([]int, cx * cy, context.temp_allocator)
		for c in split {
			i, j0, j1, crosses := piece_cells(c, w, h, cx, cy)
			if !crosses {
				continue
			}
			for j in j0 ..= j1 {
				counts[j * cx + i] += 1
			}
		}
		fullest := slice.max(counts)
		if fullest < best {
			best, nx, ny, cw, ch, pieces = fullest, cx, cy, w, h, split
		}
		if fullest <= 6 {
			break
		}
	}

	cells := nx * ny
	lists := make([][dynamic]u32, cells, context.temp_allocator)
	for &l in lists {
		l = make([dynamic]u32, context.temp_allocator)
	}
	for c, k in pieces {
		i, j0, j1, crosses := piece_cells(c, cw, ch, nx, ny)
		if !crosses {
			continue
		}
		for j in j0 ..= j1 {
			append(&lists[j * nx + i], u32(k))
		}
	}
	// Backdrops: per row, the pieces in the columns right of each cell,
	// as a bottom value and the steps at their ends inside the row (the
	// steps of joined ends cancel, so only edge crossings remain).
	Step :: struct {
		y:     f32,
		delta: i32,
	}
	backdrop := make([]i32, cells, context.temp_allocator)
	steps := make([][dynamic]Step, cells, context.temp_allocator)
	for j in 0 ..< ny {
		y0, y1 := f32(j) * ch, f32(j + 1) * ch
		bottom: i32
		ends := make([dynamic]Step, context.temp_allocator)
		for i := nx - 1; i >= 0; i -= 1 {
			k := j * nx + i
			backdrop[k] = bottom
			slice.sort_by(ends[:], proc(a, b: Step) -> bool {return a.y < b.y})
			steps[k] = make([dynamic]Step, context.temp_allocator)
			for e in ends {
				if n := len(steps[k]); n > 0 && steps[k][n - 1].y == e.y {
					steps[k][n - 1].delta += e.delta
				} else {
					append(&steps[k], e)
				}
			}
			for n := 0; n < len(steps[k]); {
				if steps[k][n].delta == 0 {
					ordered_remove(&steps[k], n)
				} else {
					n += 1
				}
			}
			// Then this column's pieces join the ones right of the next cell.
			for p in lists[k] {
				c := pieces[p]
				clo, chi := min(c.p1.y, c.p3.y), max(c.p1.y, c.p3.y)
				dir: i32 = 1 if c.p3.y > c.p1.y else -1
				if clo <= y0 && y0 < chi {
					bottom += dir
				}
				if clo > y0 && clo < y1 {
					append(&ends, Step{clo, dir})
				}
				if chi > y0 && chi < y1 {
					append(&ends, Step{chi, -dir})
				}
			}
		}
	}

	n := HEADER + 4 * cells + 6 * len(pieces)
	for k in 0 ..< cells {
		n += len(lists[k]) + 2 * len(steps[k])
	}
	d := make([]u32, n, allocator)
	d[0], d[1] = u32(nx), u32(ny)
	d[2], d[3] = transmute(u32)cw, transmute(u32)ch
	d[8], d[9], d[10], d[11] = 0, 0, transmute(u32)size.x, transmute(u32)size.y
	at := HEADER + 4 * cells
	for k in 0 ..< cells {
		cell := d[HEADER + 4 * k:][:4]
		cell[0] = u32(at)
		cell[1] = u32(len(lists[k])) | u32(len(steps[k])) << 16
		cell[2] = u32(backdrop[k])
		copy(d[at:], lists[k][:])
		at += len(lists[k])
		cell[3] = u32(at)
		for e in steps[k] {
			d[at], d[at + 1] = transmute(u32)e.y, u32(e.delta)
			at += 2
		}
	}
	d[6] = u32(at)
	for c in pieces {
		w := transmute([6]u32)[6]f32{c.p1.x, c.p1.y, c.p2.x, c.p2.y, c.p3.x, c.p3.y}
		copy(d[at:][:6], w[:])
		at += 6
	}
	// The whole bounds as one footprint: the fraction the shape fills.
	d[7] = transmute(u32)coverage(d, size * 0.5, size, false)
	return d, origin, extent, true
}

// Appends `c` split at its x and y extrema into pieces monotone in both,
// each control point pinned inside its endpoints' box (rounding aside, the
// split puts it there).
@(private = "file")
split_monotone :: proc(c: Curve, out: ^[dynamic]Curve) {
	ts: [2]f32
	n := 0
	for axis in 0 ..< 2 {
		den := c.p1[axis] - 2 * c.p2[axis] + c.p3[axis]
		if den != 0 {
			t := (c.p1[axis] - c.p2[axis]) / den
			if t > 1e-6 && t < 1 - 1e-6 {
				ts[n] = t
				n += 1
			}
		}
	}
	if n == 2 && ts[0] > ts[1] {
		ts[0], ts[1] = ts[1], ts[0]
	}
	rest := c
	done: f32 = 0
	for i in 0 ..= n {
		piece := rest
		if i < n {
			piece, rest = split_at(rest, (ts[i] - done) / (1 - done))
			done = ts[i]
		}
		append(out, pin(piece))
	}
}

// Appends a monotone `c` cut where it crosses the lines x = k * w, the cut
// points put exactly on the lines.
@(private = "file")
split_columns :: proc(c: Curve, w: f32, nx: int, out: ^[dynamic]Curve) {
	forward := c.p3.x >= c.p1.x
	lo, hi := min(c.p1.x, c.p3.x), max(c.p1.x, c.p3.x)
	q := quadratic(c.p1, c.p2, c.p3)
	rest := c
	done: f32 = 0
	k0, k1 := int(math.floor(lo / w)) + 1, min(int(math.ceil(hi / w)) - 1, nx - 1)
	for m in 0 ..= k1 - k0 {
		k := k0 + m if forward else k1 - m
		xv := f32(k) * w
		if xv <= lo || xv >= hi {
			continue
		}
		t := solve_monotone(q.A, q.B, q.C, xv)
		if t <= done || t >= 1 {
			continue
		}
		piece: Curve
		piece, rest = split_at(rest, (t - done) / (1 - done))
		piece.p3.x, rest.p1.x = xv, xv
		append(out, pin(piece))
		done = t
	}
	append(out, pin(rest))
}

@(private = "file")
split_at :: #force_inline proc "contextless" (c: Curve, t: f32) -> (a, b: Curve) {
	m1 := c.p1 + (c.p2 - c.p1) * t
	m2 := c.p2 + (c.p3 - c.p2) * t
	m := m1 + (m2 - m1) * t
	return {c.p1, m1, m}, {m, m2, c.p3}
}

// `c` with its control point inside its endpoints' box.
@(private = "file")
pin :: #force_inline proc "contextless" (c: Curve) -> Curve {
	c := c
	for axis in 0 ..< 2 {
		lo, hi := min(c.p1[axis], c.p3[axis]), max(c.p1[axis], c.p3[axis])
		c.p2[axis] = clamp(c.p2[axis], lo, hi)
	}
	return c
}

// A piece's column and the rows it crosses; false for a horizontal piece
// (it crosses no row).
@(private = "file")
piece_cells :: proc "contextless" (c: Curve, w, h: f32, nx, ny: int) -> (i, j0, j1: int, crosses: bool) {
	lo, hi := min(c.p1.y, c.p3.y), max(c.p1.y, c.p3.y)
	if lo == hi {
		return
	}
	i = clamp(int(math.floor(0.5 * (c.p1.x + c.p3.x) / w)), 0, nx - 1)
	j0 = clamp(int(math.floor(lo / h)), 0, ny - 1)
	j1 = clamp(int(math.ceil(hi / h)) - 1, j0, ny - 1)
	return i, j0, j1, true
}

// ---- reading (mirrored by shaders/curves.slang) ------------------------------------

// Bounds in shape units.
bounds :: proc "contextless" (s: []u32) -> (minx, miny, maxx, maxy: f32) {
	return transmute(f32)s[8], transmute(f32)s[9], transmute(f32)s[10], transmute(f32)s[11]
}

// The fraction of the bounds the shape fills (non-zero rule).
mean_coverage :: proc "contextless" (s: []u32) -> f32 {
	return transmute(f32)s[7]
}

// The integral over rows [a, b] (relative to `ry`, within the cell's rows)
// of the cell's backdrop, weighted by `w(y)`: the footprint's slice width
// (`width_below` differences), or a box's constant width.
@(private)
backdrop_integral :: #force_inline proc "contextless" (s: []u32, cell: u32, ry, a, b: f32, fp: ^Footprint, box_width: f32) -> f32 {
	if a >= b {
		return 0
	}
	v := i32(s[cell + 2])
	n := s[cell + 1] >> 16
	at := s[cell + 3]
	k: u32
	for k < n && transmute(f32)s[at + 2 * k] - ry <= a {
		v += i32(s[at + 2 * k + 1])
		k += 1
	}
	area: f32
	pos := a
	for k < n {
		y := transmute(f32)s[at + 2 * k] - ry
		if y >= b {
			break
		}
		area += f32(v) * span_width(fp, box_width, pos, y)
		v += i32(s[at + 2 * k + 1])
		pos = y
		k += 1
	}
	return area + f32(v) * span_width(fp, box_width, pos, b)
}

// The footprint's area between rows a and b: a box's width times b - a,
// or the parallelogram's slices.
@(private)
span_width :: #force_inline proc "contextless" (fp: ^Footprint, box_width, a, b: f32) -> f32 {
	if fp == nil {
		return box_width * (b - a)
	}
	return width_below(fp^, b) - width_below(fp^, a)
}

// t in [0, 1] where q(t) = a t^2 + b t + c equals v, for a coordinate
// monotone on [0, 1] (v within its endpoints).
solve_monotone :: #force_inline proc "contextless" (a, b, c, v: f32) -> f32 {
	cc := c - v
	if abs(a) <= 1e-7 * abs(b) {
		return clamp(-cc / b, 0, 1)
	}
	d := math.sqrt(max(b * b - 4 * a * cc, 0))
	q := -0.5 * (b + (d if b >= 0 else -d))
	t1 := q / a
	t2 := cc / q if q != 0 else t1
	// The root in [0, 1], or the nearer one when rounding pushes both out.
	e1 := max(-t1, t1 - 1, 0)
	e2 := max(-t2, t2 - 1, 0)
	return clamp(t1 if e1 <= e2 else t2, 0, 1)
}

// The integral over [t0, t1] of g(t) y'(t), g(t) = gp t^2 + gq t + gr and
// y(t) = yd t^2 + ye t + yf: a quartic in t.
@(private)
area_term :: #force_inline proc "contextless" (gp, gq, gr, yd, ye, t0, t1: f32) -> f32 {
	k3 := gp * yd * 0.5
	k2 := (gp * ye + 2 * gq * yd) / 3
	k1 := (gq * ye + 2 * gr * yd) * 0.5
	k0 := gr * ye
	g1 := ((k3 * t1 + k2) * t1 + k1) * t1 * t1 + k0 * t1
	g0 := ((k3 * t0 + k2) * t0 + k1) * t0 * t0 + k0 * t0
	return g1 - g0
}

// The fill rule applied to `area`, the footprint's signed covered fraction.
@(private)
fill :: #force_inline proc "contextless" (area: f32, even_odd: bool) -> f32 {
	cov := abs(area)
	if even_odd {
		return 1 - abs(1 - (cov * 0.5 - math.floor(cov * 0.5)) * 2)
	}
	return min(cov, 1)
}

// Exact coverage of the axis-aligned box `footprint` (shape units) centered
// at `rc`: a pixel under a transform without rotation or skew
// (`coverage_affine` for the others).
coverage :: proc "contextless" (s: []u32, rc: Vec2, footprint: Vec2, even_odd: bool) -> f32 {
	fx, fy := footprint.x, footprint.y
	if fx <= 0 || fy <= 0 {
		return 0
	}
	x0, x1 := -0.5 * fx, 0.5 * fx
	g := grid_span(s, rc, x0, x1, -0.5 * fy, 0.5 * fy)
	area: f32
	for j in g.j0 ..= g.j1 {
		ylo, yhi, rlo, rhi := grid_rows(s, g, j, rc.y)
		if ylo >= yhi {
			continue
		}
		for i in g.i0 ..= g.i1 {
			cell := HEADER + 4 * u32(j * g.nx + i)
			list := s[cell]
			for k in 0 ..< s[cell + 1] & 0xffff {
				area += box_curve(s, s[6] + 6 * s[list + k], rc, ylo, yhi, x0, x1)
			}
		}
		area += backdrop_integral(s, HEADER + 4 * u32(j * g.nx + g.i1), rc.y, max(ylo, rlo), min(yhi, rhi), nil, fx)
	}
	return fill(area / (fx * fy), even_odd)
}

// The cells a footprint covers: columns i0..i1 and rows j0..j1, clamped to
// the grid.
@(private)
Grid_Span :: struct {
	nx, ny, i0, i1, j0, j1: i32,
	y0, y1:                 f32,
}

@(private)
grid_span :: #force_inline proc "contextless" (s: []u32, rc: Vec2, x0, x1, y0, y1: f32) -> Grid_Span {
	nx, ny := i32(s[0]), i32(s[1])
	cw, ch := transmute(f32)s[2], transmute(f32)s[3]
	return {
		nx, ny,
		clamp(i32(math.floor((rc.x + x0) / cw)), 0, nx - 1),
		clamp(i32(math.floor((rc.x + x1) / cw)), 0, nx - 1),
		clamp(i32(math.floor((rc.y + y0) / ch)), 0, ny - 1),
		clamp(i32(math.floor((rc.y + y1) / ch)), 0, ny - 1),
		y0, y1,
	}
}

// Row j's part of the footprint's rows, [ylo, yhi] (the first and last rows
// reach out), and the row's own extent [rlo, rhi], relative to `ry`.
@(private)
grid_rows :: #force_inline proc "contextless" (s: []u32, g: Grid_Span, j: i32, ry: f32) -> (ylo, yhi, rlo, rhi: f32) {
	ch := transmute(f32)s[3]
	rlo, rhi = f32(j) * ch - ry, f32(j + 1) * ch - ry
	ylo = g.y0 if j == 0 else max(g.y0, rlo)
	yhi = g.y1 if j == g.ny - 1 else min(g.y1, rhi)
	return
}

// The area the piece at word `c` adds to the box [x0, x1] over rows
// [ylo, yhi] (relative to `rc`).
@(private)
box_curve :: proc "contextless" (s: []u32, c: u32, rc: Vec2, ylo, yhi, x0, x1: f32) -> f32 {
	p1 := Vec2{transmute(f32)s[c], transmute(f32)s[c + 1]} - rc
	p3 := Vec2{transmute(f32)s[c + 4], transmute(f32)s[c + 5]} - rc
	ca, cb := max(ylo, min(p1.y, p3.y)), min(yhi, max(p1.y, p3.y))
	if ca >= cb || max(p1.x, p3.x) <= x0 {
		return 0
	}
	full := ((x1 - x0) if p3.y > p1.y else (x0 - x1)) * (cb - ca)
	if min(p1.x, p3.x) >= x1 {
		return full
	}
	p2 := Vec2{transmute(f32)s[c + 2], transmute(f32)s[c + 3]} - rc
	q := quadratic(p1, p2, p3)
	ta := solve_monotone(q.D, q.E, q.F, ca)
	tb := solve_monotone(q.D, q.E, q.F, cb)
	ta, tb = min(ta, tb), max(ta, tb)
	// Within its rows the curve spans x from x(ta) to x(tb).
	xa, xb := (q.A * ta + q.B) * ta + q.C, (q.A * tb + q.B) * tb + q.C
	xlo, xhi := min(xa, xb), max(xa, xb)
	if xhi <= x0 {
		return 0
	}
	if xlo >= x1 {
		return full
	}
	// Where x crosses the box's sides split the rows into pieces.
	s1, s2 := tb, tb
	if x0 > xlo && x0 < xhi {
		s1 = clamp(solve_monotone(q.A, q.B, q.C, x0), ta, tb)
	}
	if x1 > xlo && x1 < xhi {
		s2 = clamp(solve_monotone(q.A, q.B, q.C, x1), ta, tb)
	}
	lo, hi := min(s1, s2), max(s1, s2)
	return box_piece(q, x0, x1, ta, lo) + box_piece(q, x0, x1, lo, hi) + box_piece(q, x0, x1, hi, tb)
}

// A curve as polynomials: x(t) = A t^2 + B t + C, y(t) = D t^2 + E t + F.
@(private)
Quadratic :: struct {
	A, B, C, D, E, F: f32,
}

@(private)
quadratic :: #force_inline proc "contextless" (p1, p2, p3: Vec2) -> Quadratic {
	return {p1.x - 2 * p2.x + p3.x, 2 * (p2.x - p1.x), p1.x, p1.y - 2 * p2.y + p3.y, 2 * (p2.y - p1.y), p1.y}
}

// The area a piece [t0, t1] of a curve adds to the box [x0, x1]: none left
// of it, the full width right of it, the part left of the curve inside.
@(private)
box_piece :: #force_inline proc "contextless" (q: Quadratic, x0, x1, t0, t1: f32) -> f32 {
	if t1 <= t0 {
		return 0
	}
	tm := (t0 + t1) * 0.5
	xm := (q.A * tm + q.B) * tm + q.C
	if xm <= x0 {
		return 0
	}
	if xm >= x1 {
		return (x1 - x0) * (((q.D * t1 + q.E) * t1 + q.F) - ((q.D * t0 + q.E) * t0 + q.F))
	}
	return area_term(q.A, q.B, q.C - x0, q.D, q.E, t0, t1)
}

// Exact coverage of the parallelogram `rc + a u + b v`, a, b in [-1/2, 1/2]:
// a pixel whose sides map to `u` and `v` in shape units (the shape
// coordinate's derivatives along the pixel's x and y), under any affine
// transform or a 3D one's local Jacobian.
coverage_affine :: proc "contextless" (s: []u32, rc: Vec2, u, v: Vec2, even_odd: bool) -> f32 {
	if u.y == 0 && v.x == 0 {
		return coverage(s, rc, {abs(u.x), abs(v.y)}, even_odd)
	}
	fp, ok := footprint_parallelogram(u, v)
	if !ok {
		return 0
	}
	g := grid_span(s, rc, fp.xmin, fp.xmax, -fp.h0, fp.h0)
	area: f32
	for j in g.j0 ..= g.j1 {
		ylo, yhi, rlo, rhi := grid_rows(s, g, j, rc.y)
		if ylo >= yhi {
			continue
		}
		for i in g.i0 ..= g.i1 {
			cell := HEADER + 4 * u32(j * g.nx + i)
			list := s[cell]
			for k in 0 ..< s[cell + 1] & 0xffff {
				area += affine_curve(s, s[6] + 6 * s[list + k], rc, &fp, ylo, yhi)
			}
		}
		area += backdrop_integral(s, HEADER + 4 * u32(j * g.nx + g.i1), rc.y, max(ylo, rlo), min(yhi, rhi), &fp, 0)
	}
	return fill(area / (fp.width * (fp.h0 + fp.h1)), even_odd)
}

// The area the piece at word `c` adds to the footprint over rows [ylo,
// yhi] (relative to `rc`): its parameters at the rows' ends and where they
// cross the footprint's pieces' boundaries (no solve where those coincide),
// then each piece.
@(private)
affine_curve :: proc "contextless" (s: []u32, c: u32, rc: Vec2, fp: ^Footprint, ylo, yhi: f32) -> f32 {
	p1 := Vec2{transmute(f32)s[c], transmute(f32)s[c + 1]} - rc
	p3 := Vec2{transmute(f32)s[c + 4], transmute(f32)s[c + 5]} - rc
	ca, cb := max(ylo, min(p1.y, p3.y)), min(yhi, max(p1.y, p3.y))
	if ca >= cb || max(p1.x, p3.x) <= fp.xmin {
		return 0
	}
	if min(p1.x, p3.x) >= fp.xmax {
		return (1 if p3.y > p1.y else -1) * (width_below(fp^, cb) - width_below(fp^, ca))
	}
	p2 := Vec2{transmute(f32)s[c + 2], transmute(f32)s[c + 3]} - rc
	q := quadratic(p1, p2, p3)
	ta := solve_monotone(q.D, q.E, q.F, ca)
	tb := solve_monotone(q.D, q.E, q.F, cb)
	y1, y2 := clamp(-fp.h1, ca, cb), clamp(fp.h1, ca, cb)
	t1 := ta if y1 == ca else (tb if y1 == cb else solve_monotone(q.D, q.E, q.F, y1))
	t2 := ta if y2 == ca else (tb if y2 == cb else solve_monotone(q.D, q.E, q.F, y2))
	return footprint_piece(fp^, 0, q, ta, t1) + footprint_piece(fp^, 1, q, t1, t2) + footprint_piece(fp^, 2, q, t2, tb)
}

// A pixel's parallelogram footprint, centered on the origin. Its lowest
// corner B is at -h0, the next P at -h1, then Q = -P at h1 and T = -B at
// h0. The long sides BQ and PT have slope s1 (dx / dy), the short sides BP
// and QT slope s2; as lines x = c + s y their intercepts are c1 (BQ), c2
// (PT), c3 (BP) and c4 (QT). Cut at -h1 and h1 it is three pieces: a
// triangle between BQ and BP, a band of constant `width` between BQ and PT,
// and a triangle between PT and QT.
@(private)
Footprint :: struct {
	h0, h1, s1, s2:     f32,
	c1, c2, c3, c4:     f32,
	width, xmin, xmax: f32,
}

@(private)
footprint_parallelogram :: proc "contextless" (u, v: Vec2) -> (fp: Footprint, ok: bool) {
	// The corner pairs are +-(u + v) / 2 and +-(u - v) / 2.
	d1, d2 := 0.5 * (u + v), 0.5 * (u - v)
	if abs(d1.y) < abs(d2.y) {
		d1, d2 = d2, d1
	}
	b := d1 if d1.y <= 0 else -d1
	p := d2 if d2.y <= 0 else -d2
	fp.h0, fp.h1 = -b.y, -p.y
	if fp.h0 <= 0 {
		return
	}
	fp.s1 = (-p.x - b.x) / (fp.h1 + fp.h0)
	if fp.h0 > fp.h1 {
		fp.s2 = (p.x - b.x) / (fp.h0 - fp.h1)
	}
	fp.c1 = b.x + fp.h0 * fp.s1
	fp.c2 = p.x + fp.h1 * fp.s1
	fp.c3 = b.x + fp.h0 * fp.s2
	fp.c4 = -p.x - fp.h1 * fp.s2
	fp.width = abs(fp.c2 - fp.c1)
	fp.xmin = min(b.x, p.x, -b.x, -p.x)
	fp.xmax = max(b.x, p.x, -b.x, -p.x)
	return fp, fp.width > 0
}

// The footprint's area below row y.
@(private)
width_below :: #force_inline proc "contextless" (fp: Footprint, y: f32) -> f32 {
	if y <= -fp.h0 {
		return 0
	}
	total := fp.width * (fp.h0 + fp.h1)
	if y >= fp.h0 {
		return total
	}
	if y < -fp.h1 {
		d := y + fp.h0
		return 0.5 * fp.width * d * d / (fp.h0 - fp.h1)
	}
	if y <= fp.h1 {
		return 0.5 * fp.width * (fp.h0 - fp.h1) + fp.width * (y + fp.h1)
	}
	d := fp.h0 - y
	return total - 0.5 * fp.width * d * d / (fp.h0 - fp.h1)
}

// The area the curve's stretch [ta, tb] adds within piece `k` (0 bottom,
// 1 middle, 2 top) of the footprint: the slice's full width where the
// curve is right of it, the part left of the curve where it crosses it,
// split where it crosses the slice's ends.
@(private)
footprint_piece :: #force_inline proc "contextless" (fp: Footprint, k: int, q: Quadratic, ta, tb: f32) -> f32 {
	t0, t1 := min(ta, tb), max(ta, tb)
	if t1 <= t0 {
		return 0
	}
	// The piece's ends as lines x = c + s y, whichever is left.
	ac, as, bc, bs: f32
	switch k {
	case 0:
		ac, as, bc, bs = fp.c1, fp.s1, fp.c3, fp.s2
	case 1:
		ac, as, bc, bs = fp.c1, fp.s1, fp.c2, fp.s1
	case:
		ac, as, bc, bs = fp.c2, fp.s1, fp.c4, fp.s2
	}
	y0 := (q.D * t0 + q.E) * t0 + q.F
	y1 := (q.D * t1 + q.E) * t1 + q.F
	ym := 0.5 * (y0 + y1)
	if ac + as * ym > bc + bs * ym {
		ac, as, bc, bs = bc, bs, ac, as
	}
	xa := (q.A * t0 + q.B) * t0 + q.C
	xb := (q.A * t1 + q.B) * t1 + q.C
	if max(xa, xb) <= min(ac + as * y0, ac + as * y1) {
		return 0
	}
	if min(xa, xb) >= max(bc + bs * y0, bc + bs * y1) {
		return width_below(fp, y1) - width_below(fp, y0)
	}
	// x - l(y) and x - r(y) are quadratics in t.
	l1, l2 := roots_between(q.A - as * q.D, q.B - as * q.E, q.C - ac - as * q.F, t0, t1)
	r1, r2 := roots_between(q.A - bs * q.D, q.B - bs * q.E, q.C - bc - bs * q.F, t0, t1)
	s0, s1, s2, s3 := sort4(l1, l2, r1, r2)
	area := footprint_span(fp, q, ac, as, bc, bs, t0, s0)
	area += footprint_span(fp, q, ac, as, bc, bs, s0, s1)
	area += footprint_span(fp, q, ac, as, bc, bs, s1, s2)
	area += footprint_span(fp, q, ac, as, bc, bs, s2, s3)
	area += footprint_span(fp, q, ac, as, bc, bs, s3, t1)
	return area
}

@(private)
footprint_span :: #force_inline proc "contextless" (fp: Footprint, q: Quadratic, ac, as, bc, bs, t0, t1: f32) -> f32 {
	if t1 <= t0 {
		return 0
	}
	tm := (t0 + t1) * 0.5
	xm := (q.A * tm + q.B) * tm + q.C
	ym := (q.D * tm + q.E) * tm + q.F
	if xm <= ac + as * ym {
		return 0
	}
	if xm >= bc + bs * ym {
		return width_below(fp, (q.D * t1 + q.E) * t1 + q.F) - width_below(fp, (q.D * t0 + q.E) * t0 + q.F)
	}
	return area_term(q.A - as * q.D, q.B - as * q.E, q.C - ac - as * q.F, q.D, q.E, t0, t1)
}

// Four values in ascending order (a sorting network).
@(private = "file")
sort4 :: #force_inline proc "contextless" (w, x, y, z: f32) -> (f32, f32, f32, f32) {
	a, b := min(w, x), max(w, x)
	c, d := min(y, z), max(y, z)
	a, c = min(a, c), max(a, c)
	b, d = min(b, d), max(b, d)
	b, c = min(b, c), max(b, c)
	return a, b, c, d
}

// The real roots of a t^2 + b t + c in (lo, hi); `hi` stands for each one
// missing.
@(private)
roots_between :: proc "contextless" (a, b, c, lo, hi: f32) -> (r1, r2: f32) {
	r1, r2 = hi, hi
	// No sign change between the ends and no turn between them: no root.
	glo := (a * lo + b) * lo + c
	ghi := (a * hi + b) * hi + c
	vertex := -b / (2 * a) if a != 0 else lo
	if (glo > 0) == (ghi > 0) && !(vertex > lo && vertex < hi) {
		return
	}
	if abs(a) <= 1e-9 * (abs(b) + abs(c)) {
		if b != 0 {
			if t := -c / b; t > lo && t < hi {
				r1 = t
			}
		}
		return
	}
	disc := b * b - 4 * a * c
	if disc < 0 {
		return
	}
	d := math.sqrt(disc)
	q := -0.5 * (b + (d if b >= 0 else -d))
	if t := q / a; t > lo && t < hi {
		r1 = t
	}
	if q != 0 {
		if t := c / q; t > lo && t < hi {
			r2 = t
		}
	}
	return
}

// The per-axis extent of a pixel's footprint from `j`, the Jacobian of
// shape units by pixel coordinates: the box enclosing its parallelogram, as
// `fwidth` gives (for bounds, `coverage` of that box, and `fade`).
footprint_of :: proc "contextless" (j: matrix[2, 2]f32) -> Vec2 {
	return {abs(j[0, 0]) + abs(j[0, 1]), abs(j[1, 0]) + abs(j[1, 1])}
}

// `coverage_affine` with the footprint from `j`, the Jacobian of shape units
// by pixel coordinates (`j[0, 1]` = d shape.x / d pixel.y).
coverage_jacobian :: proc "contextless" (s: []u32, rc: Vec2, j: matrix[2, 2]f32, even_odd: bool) -> f32 {
	return coverage_affine(s, rc, {j[0, 0], j[1, 0]}, {j[0, 1], j[1, 1]}, even_odd)
}

// `cov` blended toward the shape's mean coverage as the footprint grows
// from half the shape's size to all of it (along either axis).
fade :: proc "contextless" (s: []u32, cov: f32, footprint: Vec2) -> f32 {
	size := Vec2{transmute(f32)s[10], transmute(f32)s[11]}
	k := max(footprint.x / max(size.x, 1e-6), footprint.y / max(size.y, 1e-6))
	t := clamp(2 * k - 1, 0, 1)
	return cov + (mean_coverage(s) - cov) * t
}

// The winding number at `p` (shape units): the signed count of the curves
// crossing the ray toward +x (non-zero is `!= 0`, even-odd is odd), with
// the sign `coverage`'s area has. A curve counts at its rows [lower end,
// upper end), so a contour's joints count once.
winding :: proc "contextless" (s: []u32, p: Vec2) -> i32 {
	_, _, sx, sy := bounds(s)
	if p.x >= sx || p.y < 0 || p.y >= sy {
		return 0
	}
	g := grid_span(s, p, 0, 0, 0, 0)
	cell := HEADER + 4 * u32(g.j0 * g.nx + g.i0)
	// The backdrop at p.y, then the cell's pieces right of p.
	w := i32(s[cell + 2])
	at := s[cell + 3]
	for k in 0 ..< s[cell + 1] >> 16 {
		if transmute(f32)s[at + 2 * k] <= p.y {
			w += i32(s[at + 2 * k + 1])
		}
	}
	list := s[cell]
	for k in 0 ..< s[cell + 1] & 0xffff {
		c := s[6] + 6 * s[list + k]
		p1 := Vec2{transmute(f32)s[c], transmute(f32)s[c + 1]} - p
		p2 := Vec2{transmute(f32)s[c + 2], transmute(f32)s[c + 3]} - p
		p3 := Vec2{transmute(f32)s[c + 4], transmute(f32)s[c + 5]} - p
		lo, hi := min(p1.y, p3.y), max(p1.y, p3.y)
		if 0 < lo || 0 >= hi || max(p1.x, p3.x) <= 0 {
			continue
		}
		t := solve_monotone(p1.y - 2 * p2.y + p3.y, 2 * (p2.y - p1.y), p1.y, 0)
		if ((p1.x - 2 * p2.x + p3.x) * t + 2 * (p2.x - p1.x)) * t + p1.x > 0 {
			w += 1 if p3.y > p1.y else -1
		}
	}
	return w
}
