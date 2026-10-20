// Shapes as curves for per-pixel coverage, with Eric Lengyel's Slug
// algorithm (JCGT 2017; reference shaders MIT, patent dedicated to the
// public domain). Core only: ovg's shapes (shape.odin) and other renderers
// share it, and shaders/curves.slang is its GPU twin, step for step.
//
// A shape is quadratic Bézier curves split into horizontal and vertical
// bands. A pixel casts a ray along each axis (+x, +y) through the curves of
// its two bands; each crossing counts by how much of the pixel lies before
// it, and the two rays' winding numbers blend by how near their nearest
// crossings are. A shape is built once and drawn under any transform.
//
// A built shape is one block of 32-bit words, read as is from a storage
// buffer (std430: an array of uint; coordinates are float32 bit patterns);
// every offset is relative to the shape's first word, so one buffer holds
// many shapes:
//
//	[0] horizontal band count     [1] vertical band count
//	[2] band scale x (f32)        [3] band scale y (f32)
//	[4] band offset x (f32)       [5] band offset y (f32)
//	[6] word offset of the curves [7] mean coverage (f32)
//	[8..11] bounds min x, min y, max x, max y (f32)
//	[12..] each band, horizontal then vertical: curve count, word offset of
//	       its curve list; then the lists (curve indices, horizontal bands'
//	       by descending max x, vertical bands' by descending max y); then
//	       the curves, six f32 each (p1, p2, p3).
//
// A sample's horizontal band is `clamp(int(y * scale.y + offset.y), 0,
// h_count - 1)`, its vertical band likewise from x. Curves are in shape
// units: the source scaled so the shape's larger side is 1 (bounds start at
// 0), which keeps Slug's thresholds (1/65536) meaningful; `build` returns
// the scale and origin back to source units.
//
// The mean coverage is the fraction of the bounds the shape fills (non-zero
// rule, from a 32 x 32 grid of `winding` samples): what a pixel covering the
// whole shape sees, where the rays through its center alias (`fade`).
package curves

import "core:math"
import "core:slice"

Vec2 :: [2]f32

Curve :: struct {
	p1, p2, p3: Vec2,
}

HEADER :: 12
MAX_BANDS :: 32

// ---- building -------------------------------------------------------------------

// Collects contours as quadratic curves: lines become `{p1, p2, p2}` (as
// Slug's notes advise), cubics split into quadratics within `tol`.
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
		append(&b.curves, Curve{b.last, p, p})
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
	lo, hi := b.curves[0].p1, b.curves[0].p1
	for c in b.curves {
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
	curves := make([]Curve, len(b.curves), context.temp_allocator)
	for c, i in b.curves {
		curves[i] = {(c.p1 - lo) * inv, (c.p2 - lo) * inv, (c.p3 - lo) * inv}
	}
	size := (hi - lo) * inv

	// Band lists for each axis (0: horizontal bands, split along y, ordered
	// by max x; 1: vertical bands, split along x, ordered by max y).
	Axis :: struct {
		count: int,
		scale: f32,
		lists: [][dynamic]u32,
	}
	axes: [2]Axis
	for &ax, a in axes {
		across := 1 - a // the coordinate the bands split
		ax.count = band_count(curves, size[across], across)
		ax.scale = f32(ax.count) / max(size[across], 1e-6)
		ax.lists = make([][dynamic]u32, ax.count, context.temp_allocator)
		eps := size[across] / 1024
		for &l in ax.lists {
			l = make([dynamic]u32, context.temp_allocator)
		}
		for c, i in curves {
			c0, c1 := curve_range(c, across)
			if c0 == c1 {
				continue // parallel to the ray: never crosses it
			}
			for band in 0 ..< ax.count {
				b0 := f32(band) / ax.scale - eps
				b1 := f32(band + 1) / ax.scale + eps
				if c1 >= b0 && c0 <= b1 {
					append(&ax.lists[band], u32(i))
				}
			}
		}
		for l in ax.lists {
			ctx := Sort_Ctx{curves, a}
			context.user_ptr = &ctx
			slice.sort_by(l[:], proc(x, y: u32) -> bool {
				ctx := (^Sort_Ctx)(context.user_ptr)
				_, mx := curve_range(ctx.curves[x], ctx.along)
				_, my := curve_range(ctx.curves[y], ctx.along)
				return mx > my || (mx == my && x < y)
			})
		}
	}

	n := HEADER + 2 * (axes[0].count + axes[1].count) + 6 * len(curves)
	for ax in axes {
		for l in ax.lists {
			n += len(l)
		}
	}
	d := make([]u32, n, allocator)
	d[0], d[1] = u32(axes[0].count), u32(axes[1].count)
	d[2], d[3] = transmute(u32)axes[1].scale, transmute(u32)axes[0].scale
	d[4], d[5] = 0, 0
	d[8], d[9], d[10], d[11] = 0, 0, transmute(u32)size.x, transmute(u32)size.y
	at := HEADER + 2 * (axes[0].count + axes[1].count)
	band := HEADER
	for ax in axes {
		for l in ax.lists {
			d[band], d[band + 1] = u32(len(l)), u32(at)
			band += 2
			copy(d[at:], l[:])
			at += len(l)
		}
	}
	d[6] = u32(at)
	for c in curves {
		w := transmute([6]u32)[6]f32{c.p1.x, c.p1.y, c.p2.x, c.p2.y, c.p3.x, c.p3.y}
		copy(d[at:][:6], w[:])
		at += 6
	}

	// The mean coverage, from the grid's cell centers.
	GRID :: 32
	inside := 0
	for gy in 0 ..< GRID {
		for gx in 0 ..< GRID {
			p := Vec2{(f32(gx) + 0.5) / GRID * size.x, (f32(gy) + 0.5) / GRID * size.y}
			inside += int(winding(d, p) != 0)
		}
	}
	d[7] = transmute(u32)(f32(inside) / (GRID * GRID))
	return d, origin, extent, true
}

@(private = "file")
Sort_Ctx :: struct {
	curves: []Curve,
	along:  int,
}

@(private = "file")
curve_range :: #force_inline proc "contextless" (c: Curve, axis: int) -> (lo, hi: f32) {
	return min(c.p1[axis], c.p2[axis], c.p3[axis]), max(c.p1[axis], c.p2[axis], c.p3[axis])
}

// The band count (1 to MAX_BANDS) that keeps the fullest band smallest;
// fewer bands on a tie.
@(private = "file")
band_count :: proc(curves: []Curve, size: f32, axis: int) -> int {
	best, best_max := 1, len(curves) + 1
	counts: [MAX_BANDS]int
	for n in 1 ..= min(MAX_BANDS, max(1, len(curves) / 2)) {
		scale := f32(n) / max(size, 1e-6)
		eps := size / 1024
		counts = {}
		for c in curves {
			lo, hi := curve_range(c, axis)
			b0 := clamp(int(math.floor((lo - eps) * scale)), 0, n - 1)
			b1 := clamp(int(math.floor((hi + eps) * scale)), 0, n - 1)
			for b in b0 ..= b1 {
				counts[b] += 1
			}
		}
		m := slice.max(counts[:n])
		if m < best_max {
			best, best_max = n, m
		}
	}
	return best
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

// Which of a curve's two roots cross the ray, from the signs of the control
// points' coordinates across it: bit 0 the first root, bit 8 the second.
root_code :: #force_inline proc "contextless" (y1, y2, y3: f32) -> u32 {
	i1 := transmute(u32)y1 >> 31
	i2 := transmute(u32)y2 >> 30
	i3 := transmute(u32)y3 >> 29
	shift := (i2 & 2) | (i1 &~ 2)
	shift = (i3 & 4) | (shift &~ 4)
	return (0x2E74 >> shift) & 0x0101
}

// Where the curve (relative to the sample) crosses y = 0 (`axis` 1) or
// x = 0 (`axis` 0): the other coordinate at each root.
solve :: #force_inline proc "contextless" (p1, p2, p3: Vec2, axis: int) -> (r1, r2: f32) {
	other := 1 - axis
	a := p1 - p2 * 2 + p3
	b := p1 - p2
	ra := 1 / a[axis]
	rb := 0.5 / b[axis]
	d := math.sqrt(max(b[axis] * b[axis] - a[axis] * p1[axis], 0))
	t1 := (b[axis] - d) * ra
	t2 := (b[axis] + d) * ra
	if abs(a[axis]) < 1.0 / 65536 {
		t1 = p1[axis] * rb
		t2 = t1
	}
	return (a[other] * t1 - b[other] * 2) * t1 + p1[other], (a[other] * t2 - b[other] * 2) * t2 + p1[other]
}

// Coverage of the pixel whose center is at `rc` (shape units), the pixel
// spanning `footprint` shape units along each axis (what `fwidth` of the
// shape coordinate gives a shader; `footprint_of`). `s` is a shape's words.
coverage :: proc "contextless" (s: []u32, rc: Vec2, footprint: Vec2, even_odd: bool) -> f32 {
	ppe := 1 / footprint
	h_count, v_count := i32(s[0]), i32(s[1])
	scale := Vec2{transmute(f32)s[2], transmute(f32)s[3]}
	offset := Vec2{transmute(f32)s[4], transmute(f32)s[5]}
	bx := clamp(i32(rc.x * scale.x + offset.x), 0, v_count - 1)
	by := clamp(i32(rc.y * scale.y + offset.y), 0, h_count - 1)
	curves := s[6]

	xcov, xwgt: f32
	hb := HEADER + 2 * u32(by)
	list := s[hb + 1]
	for k in 0 ..< s[hb] {
		c := curves + 6 * s[list + k]
		p1 := Vec2{transmute(f32)s[c], transmute(f32)s[c + 1]} - rc
		p2 := Vec2{transmute(f32)s[c + 2], transmute(f32)s[c + 3]} - rc
		p3 := Vec2{transmute(f32)s[c + 4], transmute(f32)s[c + 5]} - rc
		if max(p1.x, p2.x, p3.x) * ppe.x < -0.5 {
			break
		}
		code := root_code(p1.y, p2.y, p3.y)
		if code != 0 {
			r1, r2 := solve(p1, p2, p3, 1)
			r1 *= ppe.x
			r2 *= ppe.x
			if code & 1 != 0 {
				xcov += clamp(r1 + 0.5, 0, 1)
				xwgt = max(xwgt, clamp(1 - abs(r1) * 2, 0, 1))
			}
			if code > 1 {
				xcov -= clamp(r2 + 0.5, 0, 1)
				xwgt = max(xwgt, clamp(1 - abs(r2) * 2, 0, 1))
			}
		}
	}

	ycov, ywgt: f32
	vb := HEADER + 2 * u32(h_count + bx)
	list = s[vb + 1]
	for k in 0 ..< s[vb] {
		c := curves + 6 * s[list + k]
		p1 := Vec2{transmute(f32)s[c], transmute(f32)s[c + 1]} - rc
		p2 := Vec2{transmute(f32)s[c + 2], transmute(f32)s[c + 3]} - rc
		p3 := Vec2{transmute(f32)s[c + 4], transmute(f32)s[c + 5]} - rc
		if max(p1.y, p2.y, p3.y) * ppe.y < -0.5 {
			break
		}
		code := root_code(p1.x, p2.x, p3.x)
		if code != 0 {
			r1, r2 := solve(p1, p2, p3, 0)
			r1 *= ppe.y
			r2 *= ppe.y
			if code & 1 != 0 {
				ycov -= clamp(r1 + 0.5, 0, 1)
				ywgt = max(ywgt, clamp(1 - abs(r1) * 2, 0, 1))
			}
			if code > 1 {
				ycov += clamp(r2 + 0.5, 0, 1)
				ywgt = max(ywgt, clamp(1 - abs(r2) * 2, 0, 1))
			}
		}
	}

	cov := max(abs(xcov * xwgt + ycov * ywgt) / max(xwgt + ywgt, 1.0 / 65536), min(abs(xcov), abs(ycov)))
	if even_odd {
		return 1 - abs(1 - (cov * 0.5 - math.floor(cov * 0.5)) * 2)
	}
	return clamp(cov, 0, 1)
}

// The per-axis footprint of a pixel from `j`, the Jacobian of shape units
// by pixel coordinates (`j[0, 1]` = d shape.x / d pixel.y): the box that
// encloses the pixel's parallelogram, as `fwidth` gives. The rays run along
// the shape's axes, so this is exact for scales and translations; under a
// rotation the box is wider than the pixel (up to sqrt 2 at 45 degrees:
// slightly softer edges), and at grazing angles in 3D one axis grows long,
// softening edges along it. Band size does not matter (a ray meets every
// curve on its line however fine the bands); a footprint near the shape's
// own size aliases: then `fade` to the mean.
footprint_of :: proc "contextless" (j: matrix[2, 2]f32) -> Vec2 {
	return {abs(j[0, 0]) + abs(j[0, 1]), abs(j[1, 0]) + abs(j[1, 1])}
}

// `coverage` with the footprint from the Jacobian `j` (`footprint_of`).
coverage_jacobian :: proc "contextless" (s: []u32, rc: Vec2, j: matrix[2, 2]f32, even_odd: bool) -> f32 {
	return coverage(s, rc, footprint_of(j), even_odd)
}

// `cov` blended toward the shape's mean coverage as the footprint grows
// from half the shape's size to all of it (along either axis): there one
// sample's rays alias the whole shape.
fade :: proc "contextless" (s: []u32, cov: f32, footprint: Vec2) -> f32 {
	size := Vec2{transmute(f32)s[10], transmute(f32)s[11]}
	k := max(footprint.x / max(size.x, 1e-6), footprint.y / max(size.y, 1e-6))
	t := clamp(2 * k - 1, 0, 1)
	return cov + (mean_coverage(s) - cov) * t
}

// The winding number at `p` (shape units): the signed count of crossings of
// the ray toward +x, the same crossings `coverage` counts (its sign as
// `coverage`'s, so non-zero is `!= 0` and even-odd is odd).
winding :: proc "contextless" (s: []u32, p: Vec2) -> i32 {
	h_count := i32(s[0])
	by := clamp(i32(p.y * transmute(f32)s[3] + transmute(f32)s[5]), 0, h_count - 1)
	curves := s[6]
	hb := HEADER + 2 * u32(by)
	list := s[hb + 1]
	w: i32
	for k in 0 ..< s[hb] {
		c := curves + 6 * s[list + k]
		p1 := Vec2{transmute(f32)s[c], transmute(f32)s[c + 1]} - p
		p2 := Vec2{transmute(f32)s[c + 2], transmute(f32)s[c + 3]} - p
		p3 := Vec2{transmute(f32)s[c + 4], transmute(f32)s[c + 5]} - p
		if max(p1.x, p2.x, p3.x) < 0 {
			break
		}
		code := root_code(p1.y, p2.y, p3.y)
		if code != 0 {
			r1, r2 := solve(p1, p2, p3, 1)
			if code & 1 != 0 && r1 > 0 {
				w += 1
			}
			if code > 1 && r2 > 0 {
				w -= 1
			}
		}
	}
	return w
}
