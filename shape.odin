package ovg

import "base:runtime"
import "core:math"
import "core:mem"
import "core:sync"
import "core:slice"
import stbtt "vendor:stb/truetype"

// Shapes drawn by per-pixel coverage, with Eric Lengyel's Slug algorithm
// (JCGT 2017; reference shaders MIT, patent dedicated to the public domain):
// a shape is quadratic Bézier curves split into horizontal and vertical
// bands. A pixel casts a ray along each axis through the curves of its two
// bands; each crossing counts by how much of the pixel lies before it, and
// the two rays' winding numbers blend by how near their nearest crossings
// are. No tessellation and no stencil: a shape is built once (from a glyph
// or a path) and drawn under any transform.
//
// A shape is one block of 32-bit words (`Shape.data`), the layout a GPU
// backend copies into its storage buffer as is:
//
//	[0] horizontal band count     [1] vertical band count
//	[2] band scale x (f32)        [3] band scale y (f32)
//	[4] band offset x (f32)       [5] band offset y (f32)
//	[6] word offset of the curves [7] reserved
//	[8..11] bounds min x, min y, max x, max y (f32)
//	[12..] each band, horizontal then vertical: curve count, word offset of
//	       its curve list; then the lists (curve indices, horizontal bands'
//	       by descending max x, vertical bands' by descending max y); then
//	       the curves, six f32 each (p1, p2, p3).
//
// Curves are in shape units: the source scaled so the shape's larger side
// is about 1, which keeps Slug's thresholds (1/65536) meaningful.
// `shape_coverage` is the per-pixel function; shaders/ovg.slang mirrors it
// step for step.

Shape :: struct {
	data:      []u32,
	// Unique for the process's life: GPU backends find their copy of the
	// shape by it, so a shape may be moved.
	id:        u64,
	// Shape units to the units the shape was built in (path units, or font
	// units with y down): `p = origin + q * extent`.
	origin:    Vec2,
	extent:    f32,
	allocator: mem.Allocator,
}

@(private)
SHAPE_HEADER :: 12
@(private)
SHAPE_MAX_BANDS :: 32

// Frees the shape and every GPU backend's copy of it.
shape_destroy :: proc(s: ^Shape) {
	if s.id != 0 {
		sync.mutex_lock(&shape_stores.lock)
		for st in shape_stores.list {
			st.forget(st.data, s.id)
		}
		sync.mutex_unlock(&shape_stores.lock)
	}
	delete(s.data, s.allocator)
	s^ = {}
}

// A backend that keeps copies of shapes (in GPU memory) registers here, so
// a shape's copies are freed with it: `forget` runs from `shape_destroy`,
// on whatever thread destroys the shape.
Shape_Store_Hook :: struct {
	data:   rawptr,
	forget: proc(data: rawptr, id: u64),
}

shape_store_register :: proc(h: Shape_Store_Hook) {
	sync.mutex_lock(&shape_stores.lock)
	defer sync.mutex_unlock(&shape_stores.lock)
	if shape_stores.list == nil {
		shape_stores.list = make([dynamic]Shape_Store_Hook, runtime.heap_allocator())
	}
	append(&shape_stores.list, h)
}

shape_store_unregister :: proc(data: rawptr) {
	sync.mutex_lock(&shape_stores.lock)
	defer sync.mutex_unlock(&shape_stores.lock)
	for h, i in shape_stores.list {
		if h.data == data {
			unordered_remove(&shape_stores.list, i)
			break
		}
	}
	if len(shape_stores.list) == 0 {
		delete(shape_stores.list)
		shape_stores.list = nil
	}
}

@(private = "file")
shape_stores: struct {
	lock: sync.Mutex,
	list: [dynamic]Shape_Store_Hook,
}

@(private = "file")
shape_next_id: u64

// Shape units to the shape's source units.
shape_local :: proc "contextless" (s: ^Shape) -> Transform2D {
	return {s.extent, 0, 0, s.extent, s.origin.x, s.origin.y}
}

// Bounds in shape units.
shape_bounds :: proc "contextless" (s: ^Shape) -> (minx, miny, maxx, maxy: f32) {
	d := s.data
	return transmute(f32)d[8], transmute(f32)d[9], transmute(f32)d[10], transmute(f32)d[11]
}

// ---- building -------------------------------------------------------------------

Shape_Curve :: struct {
	p1, p2, p3: Vec2,
}

// Collects contours as quadratic curves: lines become `{p1, p2, p2}` (as
// Slug's notes advise), cubics split into quadratics within `tol`.
Shape_Builder :: struct {
	curves:      [dynamic]Shape_Curve,
	start, last: Vec2,
	open:        bool,
	// Where the current contour's curves start.
	contour:     int,
	// Cubic approximation tolerance in source units; 0 picks 1/4096 of the
	// shape's size when built.
	tol:         f32,
}

shape_builder_destroy :: proc(b: ^Shape_Builder) {
	delete(b.curves)
	b^ = {}
}

shape_builder_reset :: proc(b: ^Shape_Builder) {
	clear(&b.curves)
	b.open = false
}

shape_move_to :: proc(b: ^Shape_Builder, p: Vec2) {
	shape_close(b)
	b.start, b.last, b.open = p, p, true
	b.contour = len(b.curves)
}

// Winds the current contour as `.Solid` (positive area, y down) or
// `.Hole`, reversing it if needed, as fill_path does (path_solidity).
shape_solidity :: proc(b: ^Shape_Builder, s: Solidity) {
	curves := b.curves[b.contour:]
	area: f32
	for c in curves {
		area += (c.p2.x - c.p1.x) * (c.p2.y + c.p1.y) + (c.p3.x - c.p2.x) * (c.p3.y + c.p2.y)
	}
	if (s == .Solid && area < 0) || (s == .Hole && area > 0) {
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

shape_line_to :: proc(b: ^Shape_Builder, p: Vec2) {
	if p != b.last {
		append(&b.curves, Shape_Curve{b.last, p, p})
	}
	b.last = p
}

shape_quad_to :: proc(b: ^Shape_Builder, c, p: Vec2) {
	if c == b.last || c == p {
		shape_line_to(b, p)
		return
	}
	append(&b.curves, Shape_Curve{b.last, c, p})
	b.last = p
}

shape_cubic_to :: proc(b: ^Shape_Builder, c1, c2, p: Vec2) {
	p0 := b.last
	// A raised quadratic (path_quad_to stores quadratics so) comes back
	// exactly.
	q1 := (3 * c1 - p0) * 0.5
	q2 := (3 * c2 - p) * 0.5
	size := max(abs(p.x - p0.x), abs(p.y - p0.y), abs(c1.x - p0.x), abs(c1.y - p0.y), abs(c2.x - p0.x), abs(c2.y - p0.y))
	if abs(q1.x - q2.x) <= size * 1e-5 && abs(q1.y - q2.y) <= size * 1e-5 {
		shape_quad_to(b, (q1 + q2) * 0.5, p)
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
		shape_quad_to(b, (3 * (a1 + a2) - a0 - a3) * 0.25, a3 if i < n - 1 else p)
	}
}

shape_close :: proc(b: ^Shape_Builder) {
	if b.open {
		shape_line_to(b, b.start)
		b.open = false
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

// Adds a path's contours. Every contour is closed, as filling does.
shape_add_path :: proc(b: ^Shape_Builder, p: ^Path) {
	it := path_iter(p)
	for verb, coords in path_iter_next(&it) {
		switch verb {
		case .Move_To:
			shape_move_to(b, coords[0])
		case .Line_To:
			shape_line_to(b, coords[0])
		case .Bezier_To:
			shape_cubic_to(b, coords[0], coords[1], coords[2])
		case .Close:
			shape_close(b)
		case .Solid:
			shape_solidity(b, .Solid)
		case .Hole:
			shape_solidity(b, .Hole)
		}
	}
	shape_close(b)
}

// Adds a glyph's outline in font units, y down (the pen at the origin);
// false when it has none.
shape_add_glyph :: proc(b: ^Shape_Builder, f: ^Font, g: Glyph_Index) -> bool {
	verts: [^]stbtt.vertex
	n := stbtt.GetGlyphShape(&f.info, i32(g), &verts)
	if n <= 0 {
		return false
	}
	defer stbtt.FreeShape(&f.info, verts)
	for v in verts[:n] {
		p := Vec2{f32(v.x), -f32(v.y)}
		#partial switch stbtt.vmove(v.type) {
		case .vmove:
			shape_move_to(b, p)
		case .vline:
			shape_line_to(b, p)
		case .vcurve:
			shape_quad_to(b, {f32(v.cx), -f32(v.cy)}, p)
		case .vcubic:
			shape_cubic_to(b, {f32(v.cx), -f32(v.cy)}, {f32(v.cx1), -f32(v.cy1)}, p)
		}
	}
	shape_close(b)
	return true
}

// Builds the shape from the builder's curves; false (and no shape) when
// there are none.
shape_build :: proc(b: ^Shape_Builder, allocator := context.allocator) -> (s: Shape, ok: bool) {
	shape_close(b)
	if len(b.curves) == 0 {
		return {}, false
	}
	lo, hi := b.curves[0].p1, b.curves[0].p1
	for c in b.curves {
		for p in ([3]Vec2{c.p1, c.p2, c.p3}) {
			lo = {min(lo.x, p.x), min(lo.y, p.y)}
			hi = {max(hi.x, p.x), max(hi.y, p.y)}
		}
	}
	extent := max(hi.x - lo.x, hi.y - lo.y)
	if extent <= 0 {
		return {}, false
	}
	s = {origin = lo, extent = extent, allocator = allocator, id = sync.atomic_add(&shape_next_id, 1) + 1}
	inv := 1 / extent
	curves := make([]Shape_Curve, len(b.curves), context.temp_allocator)
	for c, i in b.curves {
		curves[i] = {(c.p1 - lo) * inv, (c.p2 - lo) * inv, (c.p3 - lo) * inv}
	}
	size := (hi - lo) * inv

	// Band lists for each axis (0: horizontal bands, split along y, ordered
	// by max x; 1: vertical bands, split along x, ordered by max y).
	Axis :: struct {
		count:  int,
		scale:  f32,
		offset: f32,
		lists:  [dynamic][dynamic]u32,
	}
	axes: [2]Axis
	for &ax, a in axes {
		across := 1 - a // the coordinate the bands split
		along := a // the ray's direction
		ax.count = band_count(curves, size[across], across)
		ax.scale = f32(ax.count) / max(size[across], 1e-6)
		ax.offset = 0
		ax.lists = make([dynamic][dynamic]u32, ax.count, context.temp_allocator)
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
			ctx := Sort_Ctx{curves, along}
			context.user_ptr = &ctx
			slice.sort_by(l[:], proc(x, y: u32) -> bool {
				ctx := (^Sort_Ctx)(context.user_ptr)
				_, mx := curve_range(ctx.curves[x], ctx.along)
				_, my := curve_range(ctx.curves[y], ctx.along)
				return mx > my || (mx == my && x < y)
			})
		}
	}

	words := SHAPE_HEADER + 2 * (axes[0].count + axes[1].count) + 6 * len(curves)
	for ax in axes {
		for l in ax.lists {
			words += len(l)
		}
	}
	d := make([]u32, words, allocator)
	d[0], d[1] = u32(axes[0].count), u32(axes[1].count)
	d[2], d[3] = transmute(u32)axes[1].scale, transmute(u32)axes[0].scale
	d[4], d[5] = transmute(u32)axes[1].offset, transmute(u32)axes[0].offset
	d[8], d[9], d[10], d[11] = 0, 0, transmute(u32)size.x, transmute(u32)size.y
	at := SHAPE_HEADER + 2 * (axes[0].count + axes[1].count)
	band := SHAPE_HEADER
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
	s.data = d
	return s, true
}

@(private = "file")
Sort_Ctx :: struct {
	curves: []Shape_Curve,
	along:  int,
}

@(private = "file")
curve_range :: #force_inline proc "contextless" (c: Shape_Curve, axis: int) -> (lo, hi: f32) {
	return min(c.p1[axis], c.p2[axis], c.p3[axis]), max(c.p1[axis], c.p2[axis], c.p3[axis])
}

// The band count (1 to SHAPE_MAX_BANDS) that keeps the fullest band
// smallest; fewer bands on a tie.
@(private = "file")
band_count :: proc(curves: []Shape_Curve, size: f32, axis: int) -> int {
	best, best_max := 1, len(curves) + 1
	counts: [SHAPE_MAX_BANDS]int
	for n in 1 ..= min(SHAPE_MAX_BANDS, max(1, len(curves) / 2)) {
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

// Builds a path's shape.
shape_from_path :: proc(p: ^Path, allocator := context.allocator) -> (Shape, bool) {
	b: Shape_Builder
	b.curves.allocator = context.temp_allocator
	shape_add_path(&b, p)
	return shape_build(&b, allocator)
}

// Builds a glyph's shape (font units, y down, the pen at the origin);
// false for glyphs without an outline.
shape_from_glyph :: proc(f: ^Font, g: Glyph_Index, allocator := context.allocator) -> (Shape, bool) {
	b: Shape_Builder
	b.curves.allocator = context.temp_allocator
	if !shape_add_glyph(&b, f, g) {
		return {}, false
	}
	return shape_build(&b, allocator)
}

// ---- coverage (mirrored by shaders/ovg.slang) ------------------------------------------

// Which of a curve's two roots cross the ray, from the signs of the control
// points' coordinates across it: bit 0 the first root, bit 8 the second.
@(private)
shape_root_code :: #force_inline proc "contextless" (y1, y2, y3: f32) -> u32 {
	i1 := transmute(u32)y1 >> 31
	i2 := transmute(u32)y2 >> 30
	i3 := transmute(u32)y3 >> 29
	shift := (i2 & 2) | (i1 &~ 2)
	shift = (i3 & 4) | (shift &~ 4)
	return (0x2E74 >> shift) & 0x0101
}

// Where the curve (relative to the sample) crosses y = 0 (`axis` 1) or
// x = 0 (`axis` 0): the other coordinate at each root.
@(private)
shape_solve :: #force_inline proc "contextless" (p1, p2, p3: Vec2, axis: int) -> (r1, r2: f32) {
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
// spanning `ems_per_pixel` shape units along each axis (`shape_ems_per_pixel`).
// `s` is a shape's words (`Shape.data`), so any renderer holding them can
// call it.
shape_coverage :: proc "contextless" (s: []u32, rc: Vec2, ems_per_pixel: Vec2, even_odd: bool) -> f32 {
	ppe := 1 / ems_per_pixel
	h_count, v_count := i32(s[0]), i32(s[1])
	scale := Vec2{transmute(f32)s[2], transmute(f32)s[3]}
	offset := Vec2{transmute(f32)s[4], transmute(f32)s[5]}
	bx := clamp(i32(rc.x * scale.x + offset.x), 0, v_count - 1)
	by := clamp(i32(rc.y * scale.y + offset.y), 0, h_count - 1)
	curves := s[6]

	xcov, xwgt: f32
	hb := SHAPE_HEADER + 2 * u32(by)
	list := s[hb + 1]
	for k in 0 ..< s[hb] {
		c := curves + 6 * s[list + k]
		p1 := Vec2{transmute(f32)s[c], transmute(f32)s[c + 1]} - rc
		p2 := Vec2{transmute(f32)s[c + 2], transmute(f32)s[c + 3]} - rc
		p3 := Vec2{transmute(f32)s[c + 4], transmute(f32)s[c + 5]} - rc
		if max(p1.x, p2.x, p3.x) * ppe.x < -0.5 {
			break
		}
		code := shape_root_code(p1.y, p2.y, p3.y)
		if code != 0 {
			r1, r2 := shape_solve(p1, p2, p3, 1)
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
	vb := SHAPE_HEADER + 2 * u32(h_count + bx)
	list = s[vb + 1]
	for k in 0 ..< s[vb] {
		c := curves + 6 * s[list + k]
		p1 := Vec2{transmute(f32)s[c], transmute(f32)s[c + 1]} - rc
		p2 := Vec2{transmute(f32)s[c + 2], transmute(f32)s[c + 3]} - rc
		p3 := Vec2{transmute(f32)s[c + 4], transmute(f32)s[c + 5]} - rc
		if max(p1.y, p2.y, p3.y) * ppe.y < -0.5 {
			break
		}
		code := shape_root_code(p1.x, p2.x, p3.x)
		if code != 0 {
			r1, r2 := shape_solve(p1, p2, p3, 0)
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

	coverage := max(abs(xcov * xwgt + ycov * ywgt) / max(xwgt + ywgt, 1.0 / 65536), min(abs(xcov), abs(ycov)))
	if even_odd {
		return 1 - abs(1 - (coverage * 0.5 - math.floor(coverage * 0.5)) * 2)
	}
	return clamp(coverage, 0, 1)
}

// Shape units spanned by one pixel along each axis under `t` (shape units
// to device pixels): what `fwidth` of the shape coordinate gives a shader.
shape_ems_per_pixel :: proc "contextless" (t: Transform2D) -> Vec2 {
	inv := transform_inverse(t)
	return {abs(inv[0]) + abs(inv[2]), abs(inv[1]) + abs(inv[3])}
}
