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
//	       count, backdrop at its bottom (i32), step count; then each
//	       cell's list (piece indices) and right after it its steps (y f32,
//	       change i32: the backdrop is the bottom value plus the changes at
//	       or below y), and the pieces, six f32 each (p1, p2, p3; p2 within
//	       the box of p1 and p3).
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
MAX_CELLS :: 64

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
	// `build`'s working arrays, kept for the next build (with `curves`'
	// allocator).
	scratch:     Scratch,
}

@(private)
Scratch :: struct {
	mono, split, pieces:            [dynamic]Curve,
	at, places:                     [dynamic]Place,
	counts, starts, fill, step_ats: [dynamic]int,
	lists:                          [dynamic]u32,
	junctions:                      [dynamic]Junction,
	steps:                          [dynamic]Step,
	backdrop:                       [dynamic]i32,
}

@(private)
Step :: struct {
	y:     f32,
	delta: i32,
}

@(private)
Junction :: struct {
	cell: int,
	step: Step,
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
	s := &b.scratch
	delete(s.mono)
	delete(s.split)
	delete(s.pieces)
	delete(s.at)
	delete(s.places)
	delete(s.counts)
	delete(s.starts)
	delete(s.fill)
	delete(s.step_ats)
	delete(s.lists)
	delete(s.junctions)
	delete(s.steps)
	delete(s.backdrop)
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
	// n quadratics, each the midpoint approximation of its piece.
	tol := b.tol if b.tol > 0 else max(size, 1e-6) / 4096
	cubic := [4]Vec2{p0, c1, c2, p}
	n := cubic_quad_count(cubic, tol)
	for i in 0 ..< n {
		c, end := cubic_quad(cubic, i, n)
		quad_to(b, c, end)
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

// The shape's words from the builder's curves (closing the open contour),
// with the map back to source units: `p = origin + q * extent`. False (no
// words) when there are no curves or they span nothing. `search` tries grid
// sizes for the one keeping the fullest cell smallest (for shapes kept and
// drawn often); without it the grid is sized from the piece count alone
// (for shapes built every frame).
build :: proc(b: ^Builder, allocator := context.allocator, search := true) -> (words: []u32, origin: Vec2, extent: f32, ok: bool) {
	out := make([dynamic]u32, allocator)
	origin, extent, ok = build_append(b, &out, search)
	if !ok {
		delete(out)
		return
	}
	return out[:], origin, extent, true
}

// `build`, appending the words to `out` (reserved exactly when empty).
build_append :: proc(b: ^Builder, out: ^[dynamic]u32, search := true) -> (origin: Vec2, extent: f32, ok: bool) {
	close(b)
	if len(b.curves) == 0 {
		return
	}
	s := &b.scratch
	if s.mono.allocator.procedure == nil {
		alloc := b.curves.allocator
		s.mono.allocator, s.split.allocator, s.pieces.allocator = alloc, alloc, alloc
		s.at.allocator, s.places.allocator = alloc, alloc
		s.counts.allocator, s.starts.allocator, s.fill.allocator, s.step_ats.allocator = alloc, alloc, alloc, alloc
		s.lists.allocator, s.junctions.allocator, s.steps.allocator, s.backdrop.allocator = alloc, alloc, alloc, alloc
	}
	clear(&s.mono)
	for c in b.curves {
		split_monotone(c, &s.mono)
	}
	mono := s.mono[:]
	lo, hi := mono[0].p1, mono[0].p1
	// NaN and infinity reach the sum (min and max may drop them).
	sum: f32
	for c in mono {
		for p in ([3]Vec2{c.p1, c.p2, c.p3}) {
			lo = {min(lo.x, p.x), min(lo.y, p.y)}
			hi = {max(hi.x, p.x), max(hi.y, p.y)}
			sum += p.x + p.y
		}
	}
	extent = max(hi.x - lo.x, hi.y - lo.y)
	if !(extent > 0) || math.is_nan(sum) || math.is_inf(sum) {
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
	best := max(int)
	// The search stops at 16 a unit: past that a shape too dense to reach
	// a few pieces a cell would keep a huge grid for little gain.
	first, last := 1, 16
	if !search {
		// About four pieces a cell; one cell for a few.
		first = 1 if len(mono) <= 16 else clamp(int(math.ceil(math.sqrt(f32(len(mono)) / 4))), 1, MAX_CELLS)
		last = first
	}
	for n in first ..= last {
		cx, cy := max(1, int(math.ceil(size.x * f32(n) - 1e-4))), max(1, int(math.ceil(size.y * f32(n) - 1e-4)))
		w, h := size.x / f32(cx), size.y / f32(cy)
		// A shape of no width (or height) has one column (row): any size.
		w = w if w > 0 else 1
		h = h if h > 0 else 1
		clear(&s.split)
		if cx == 1 {
			append(&s.split, ..mono)
		} else {
			for c in mono {
				split_columns(c, w, cx, &s.split)
			}
		}
		resize(&s.at, len(s.split))
		resize(&s.counts, cx * cy)
		slice.zero(s.counts[:])
		for c, k in s.split {
			s.at[k] = place(c, w, h, cx, cy)
			for j in s.at[k].j0 ..= s.at[k].j1 {
				s.counts[j * cx + s.at[k].i] += 1
			}
		}
		fullest := slice.max(s.counts[:])
		if fullest < best {
			best, nx, ny, cw, ch = fullest, cx, cy, w, h
			s.split, s.pieces = s.pieces, s.split
			s.at, s.places = s.places, s.at
		}
		if fullest <= 6 {
			break
		}
	}
	pieces, places := s.pieces[:], s.places[:]

	cells := nx * ny
	// Each cell's piece list: counted, then filled, in one flat array.
	resize(&s.starts, cells + 1)
	starts := s.starts[:]
	slice.zero(starts)
	for at in places {
		for j in at.j0 ..= at.j1 {
			starts[j * nx + at.i + 1] += 1
		}
	}
	for k in 0 ..< cells {
		starts[k + 1] += starts[k]
	}
	resize(&s.lists, starts[cells])
	resize(&s.fill, cells)
	lists, fill := s.lists[:], s.fill[:]
	copy(fill, starts[:cells])
	for at, p in places {
		for j in at.j0 ..= at.j1 {
			lists[fill[j * nx + at.i]] = u32(p)
			fill[j * nx + at.i] += 1
		}
	}
	// Backdrops: the winding right of each cell, as its value at the bottom
	// of the row and the steps where it changes inside the row. A piece
	// starting at height y adds 1 to the winding above y against below, one
	// ending there -1, so a cell's step at y sums the ends there of the
	// pieces right of it. Joined ends cancel, leaving the junctions whose
	// two pieces are in different columns: the end in the right column
	// steps the cells between. The pieces keep contour order, so each
	// junction is a piece's end and the next one's start.
	clear(&s.junctions)
	contour := 0
	// One column has no junctions between columns, and nothing right of it.
	for c, k in pieces[:len(pieces) if nx > 1 else 0] {
		next := k + 1
		if next == len(pieces) || pieces[next].p1 != c.p3 {
			next, contour = contour, k + 1
		}
		// Ends on a row line are in the next row's bottom value.
		y := c.p3.y
		j := row(y, ch, ny)
		if y == f32(j) * ch {
			continue
		}
		i0, i1 := places[k].i, places[next].i
		for i in min(i0, i1) ..< max(i0, i1) {
			append(&s.junctions, Junction{j * nx + i, {y, 1 if i1 > i0 else -1}})
		}
	}
	// Per cell, by height: ends at one height combine, the ones that cancel
	// drop.
	resize(&s.step_ats, cells + 1)
	step_ats := s.step_ats[:]
	slice.zero(step_ats)
	for e in s.junctions {
		step_ats[e.cell + 1] += 1
	}
	for k in 0 ..< cells {
		step_ats[k + 1] += step_ats[k]
	}
	resize(&s.steps, len(s.junctions))
	steps := s.steps[:]
	copy(fill, step_ats[:cells])
	for e in s.junctions {
		steps[fill[e.cell]] = e.step
		fill[e.cell] += 1
	}
	kept := 0
	for k in 0 ..< cells {
		mine := steps[step_ats[k]:step_ats[k + 1]]
		// A few sort fastest in place; a crowded cell (a huge path's) in
		// n log n.
		if len(mine) > 32 {
			slice.sort_by(mine, proc(a, b: Step) -> bool {return a.y < b.y})
		} else {
			for m in 1 ..< len(mine) {
				for n := m; n > 0 && mine[n].y < mine[n - 1].y; n -= 1 {
					mine[n], mine[n - 1] = mine[n - 1], mine[n]
				}
			}
		}
		step_ats[k] = kept
		for e in mine {
			if kept > step_ats[k] && steps[kept - 1].y == e.y {
				steps[kept - 1].delta += e.delta
			} else {
				steps[kept] = e
				kept += 1
			}
			if steps[kept - 1].delta == 0 {
				kept -= 1
			}
		}
	}
	step_ats[cells] = kept
	// The bottom values, a running sum from the right of the pieces
	// crossing the row's bottom line.
	resize(&s.backdrop, cells)
	backdrop := s.backdrop[:]
	slice.zero(backdrop)
	for j in 0 ..< (ny if nx > 1 else 0) {
		y0 := f32(j) * ch
		bottom: i32
		for i := nx - 1; i >= 0; i -= 1 {
			k := j * nx + i
			backdrop[k] = bottom
			for p in lists[starts[k]:starts[k + 1]] {
				c := pieces[p]
				if min(c.p1.y, c.p3.y) <= y0 && y0 < max(c.p1.y, c.p3.y) {
					bottom += 1 if c.p3.y > c.p1.y else -1
				}
			}
		}
	}

	n := HEADER + 4 * cells + len(lists) + 2 * kept + 6 * len(pieces)
	base := len(out)
	if base == 0 {
		reserve(out, n)
	}
	resize(out, base + n)
	d := out[base:]
	d[0], d[1] = u32(nx), u32(ny)
	d[2], d[3] = transmute(u32)cw, transmute(u32)ch
	d[4], d[5] = 0, 0
	d[8], d[9], d[10], d[11] = 0, 0, transmute(u32)size.x, transmute(u32)size.y
	at := HEADER + 4 * cells
	for k in 0 ..< cells {
		cell := d[HEADER + 4 * k:][:4]
		list := lists[starts[k]:starts[k + 1]]
		cell[0] = u32(at)
		mine := steps[step_ats[k]:step_ats[k + 1]]
		cell[1] = u32(len(list))
		cell[2] = u32(backdrop[k])
		cell[3] = u32(len(mine))
		copy(d[at:], list)
		at += len(list)
		for e in mine {
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
	// The fraction of the bounds the shape fills: its signed area (Green's
	// theorem over each quadratic in closed form) over the bounds'.
	area: f32
	for c in mono {
		cross :: proc "contextless" (a, b: Vec2) -> f32 {return a.x * b.y - a.y * b.x}
		area += 2 * cross(c.p1, c.p2) + 2 * cross(c.p2, c.p3) + cross(c.p1, c.p3)
	}
	d[7] = transmute(u32)min(abs(area) / 6 / (size.x * size.y), 1)
	return origin, extent, true
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
	k0, k1 := int(lo / w) + 1, min(ceil(hi / w) - 1, nx - 1)
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

// A piece's column and the rows it crosses (none for a horizontal piece).
@(private)
Place :: struct {
	i, j0, j1: int,
}

// Coordinates are non-negative here, so truncation floors.
@(private = "file")
place :: proc "contextless" (c: Curve, w, h: f32, nx, ny: int) -> Place {
	i := min(int(0.5 * (c.p1.x + c.p3.x) / w), nx - 1)
	lo, hi := min(c.p1.y, c.p3.y), max(c.p1.y, c.p3.y)
	if lo == hi {
		return {i, 1, 0}
	}
	j0, j1 := row(lo, h, ny), row(hi, h, ny)
	if hi == f32(j1) * h {
		j1 -= 1
	}
	return {i, j0, max(j0, j1)}
}

// The row whose lines `j h <= y < (j + 1) h` hold `y` (clamped): exact
// against the lines the backdrops use, where `y / h` may round across one.
@(private = "file")
row :: proc "contextless" (y, h: f32, ny: int) -> int {
	j := min(int(y / h), ny - 1)
	if j > 0 && y < f32(j) * h {
		j -= 1
	} else if j < ny - 1 && y >= f32(j + 1) * h {
		j += 1
	}
	return j
}

@(private = "file")
ceil :: #force_inline proc "contextless" (x: f32) -> int {
	i := int(x)
	return i + 1 if f32(i) < x else i
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
	n := s[cell + 3]
	at := s[cell] + s[cell + 1]
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
			for k in 0 ..< s[cell + 1] {
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
// of it, the full width right of it, the part left of the curve inside (in
// a parameter starting at t0, as affine_curve's: a box small beside the
// curve would lose its area to rounding in t far from 0).
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
	r := from(q, t0)
	return area_term(r.A, r.B, r.C - x0, r.D, r.E, 0, t1 - t0)
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
			for k in 0 ..< s[cell + 1] {
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
	// Each piece in a parameter starting at its stretch: the footprint's
	// thin triangles have steep sides, and their area from coefficients in
	// t far from 0 would be lost to rounding.
	return footprint_piece(fp^, 0, from(q, ta), 0, t1 - ta) + footprint_piece(fp^, 1, from(q, t1), 0, t2 - t1) + footprint_piece(fp^, 2, from(q, t2), 0, tb - t2)
}

// `q` as a polynomial in s = t - t0.
@(private = "file")
from :: #force_inline proc "contextless" (q: Quadratic, t0: f32) -> Quadratic {
	return {q.A, 2 * q.A * t0 + q.B, (q.A * t0 + q.B) * t0 + q.C, q.D, 2 * q.D * t0 + q.E, (q.D * t0 + q.E) * t0 + q.F}
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
roots_between :: proc "contextless" (a, b, c, lo, hi: $T) -> (r1, r2: T) {
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
	at := s[cell] + s[cell + 1]
	for k in 0 ..< s[cell + 3] {
		if transmute(f32)s[at + 2 * k] <= p.y {
			w += i32(s[at + 2 * k + 1])
		}
	}
	list := s[cell]
	for k in 0 ..< s[cell + 1] {
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
