package font

import "core:math"

// gvar: TrueType outline variations. Each glyph's variation data is a set
// of tuples, each with a region of the design space (a peak, and an
// intermediate start and end) and deltas for some or all of the glyph's
// points: its outline points (a composite glyph's are its components'
// offsets) then four phantom points, whose first two set the side bearing
// and advance. At an instance every tuple adds its deltas scaled by how
// far inside its region the instance lies; points a tuple leaves out take
// deltas interpolated from their contour's neighbours (IUP).

// The phantom points a glyph's variation deltas move: left, right, top,
// bottom.
@(private)
PHANTOM_COUNT :: 4

// gvar's header facts.
@(private)
Gvar :: struct {
	axes:          int,
	shared:        int,
	shared_count:  int,
	glyph_count:   int,
	long_offsets:  bool,
	offsets:       int,
	data:          int,
}

// gvar's header: ok when it varies over fvar's axes and its shared tuples
// lie within the data.
@(private)
gvar_header :: proc(f: ^Face) -> (h: Gvar, ok: bool) {
	d, at := f.data, f.tables[.gvar].at
	if at == 0 || read_u16(d, at) != 1 {
		return
	}
	h.axes = int(read_u16(d, at + 4))
	h.shared_count = int(read_u16(d, at + 6))
	h.shared = at + int(read_u32(d, at + 8))
	h.glyph_count = int(read_u16(d, at + 12))
	h.long_offsets = read_u16(d, at + 14) & 1 != 0
	h.data = at + int(read_u32(d, at + 16))
	h.offsets = at + 20
	return h, h.axes == f.axis_count && h.axes > 0 && h.shared + 2 * h.axes * h.shared_count <= len(d)
}

// Where glyph `g`'s variation data lies (0 for none).
@(private)
gvar_glyph :: proc(f: ^Face, h: ^Gvar, g: Glyph) -> (at, end: int) {
	d := f.data
	i := int(g)
	if i >= h.glyph_count {
		return 0, 0
	}
	a, b: int
	if h.long_offsets {
		a, b = int(read_u32(d, h.offsets + 4 * i)), int(read_u32(d, h.offsets + 4 * i + 4))
	} else {
		a, b = 2 * int(read_u16(d, h.offsets + 2 * i)), 2 * int(read_u16(d, h.offsets + 2 * i + 2))
	}
	if a >= b || h.data + b > len(d) {
		return 0, 0
	}
	return h.data + a, h.data + b
}

// A tuple's scalar at the face's instance: 0 outside its region.
@(private)
tuple_scalar :: proc(f: ^Face, h: ^Gvar, peak, start, end: int, intermediate: bool) -> f32 {
	d := f.data
	scalar: f32 = 1
	for i in 0 ..< h.axes {
		v := int(f.coords[i]) if i < f.axis_count else 0
		p := int(read_i16(d, peak + 2 * i))
		if p == 0 || v == p {
			continue
		}
		if intermediate {
			s, e := int(read_i16(d, start + 2 * i)), int(read_i16(d, end + 2 * i))
			if s > p || p > e || (s < 0 && e > 0) {
				continue
			}
			if v < s || v > e {
				return 0
			}
			if v < p {
				if p != s {
					scalar *= f32(v - s) / f32(p - s)
				}
			} else if p != e {
				scalar *= f32(e - v) / f32(e - p)
			}
		} else {
			if v == 0 || v < min(0, p) || v > max(0, p) {
				return 0
			}
			scalar *= f32(v) / f32(p)
		}
	}
	return scalar
}

// A tuple's header, its region and where its data lies.
@(private)
Tuple :: struct {
	size:         int,
	peak:         int,
	start, end:   int,
	intermediate: bool,
	// Its own point numbers come first in its data.
	private:      bool,
}

// Reads the tuple header at `at` (headers end at `limit`, where the
// glyph's serialized data starts); the next header's place.
@(private)
read_tuple :: proc(f: ^Face, h: ^Gvar, at, limit: int) -> (t: Tuple, next: int, ok: bool) {
	d := f.data
	t.size = int(read_u16(d, at))
	index := read_u16(d, at + 2)
	next = at + 4
	if index & 0x8000 != 0 {
		t.peak = next
		next += 2 * h.axes
	} else {
		k := int(index & 0x0FFF)
		if k >= h.shared_count {
			return t, next, false
		}
		t.peak = h.shared + 2 * h.axes * k
	}
	if index & 0x4000 != 0 {
		t.intermediate = true
		t.start = next
		t.end = next + 2 * h.axes
		next += 4 * h.axes
	}
	t.private = index & 0x2000 != 0
	return t, next, next <= limit
}

// Packed point numbers at `p` into `out` (cleared; empty for "all
// points"); where they end.
@(private)
read_points :: proc(d: []u8, p: int, end: int, out: ^[dynamic]u16) -> (next: int, all: bool) {
	clear(out)
	p := p
	count := int(read_u8(d, p))
	p += 1
	if count == 0 {
		return p, true
	}
	if count & 0x80 != 0 {
		count = (count & 0x7F) << 8 | int(read_u8(d, p))
		p += 1
	}
	v := 0
	for len(out) < count && p < end {
		control := int(read_u8(d, p))
		p += 1
		run := control & 0x7F + 1
		words := control & 0x80 != 0
		for _ in 0 ..< run {
			if len(out) >= count {
				break
			}
			if words {
				v += int(read_u16(d, p))
				p += 2
			} else {
				v += int(read_u8(d, p))
				p += 1
			}
			append(out, u16(v))
		}
	}
	return p, false
}

// Packed deltas at `p`: `count` of them, each passed to `out` by index.
// Where they end.
@(private)
read_deltas :: proc(d: []u8, p, end, count: int, out: []f32) -> int {
	p := p
	n := 0
	for n < count && p < end {
		control := int(read_u8(d, p))
		p += 1
		run := control & 0x3F + 1
		switch control & 0xC0 {
		case 0x80:
			// Zeros.
			for _ in 0 ..< run {
				if n < count {
					out[n] = 0
					n += 1
				}
			}
		case 0x40:
			for _ in 0 ..< run {
				if n < count {
					out[n] = f32(read_i16(d, p))
					n += 1
				}
				p += 2
			}
		case 0xC0:
			for _ in 0 ..< run {
				if n < count {
					out[n] = f32(i32(read_u32(d, p)))
					n += 1
				}
				p += 4
			}
		case:
			for _ in 0 ..< run {
				if n < count {
					out[n] = f32(i8(read_u8(d, p)))
					n += 1
				}
				p += 1
			}
		}
	}
	for ; n < count; n += 1 {
		out[n] = 0
	}
	return p
}

// Glyph `g`'s deltas at the face's instance for its `count` points
// (phantom points included) into o.deltas[first:][:count]. `orig` are a
// simple glyph's points as stored and `ends` its contours' last points,
// for interpolating the points a tuple leaves out; composites have none.
// False when the glyph has no variation data (deltas zero).
@(private)
glyph_deltas :: proc(f: ^Face, g: Glyph, o: ^Outline, first, count: int, simple: bool) -> bool {
	h, ok := gvar_header(f)
	if !ok {
		return false
	}
	at, end := gvar_glyph(f, &h, g)
	if at == 0 {
		return false
	}
	d := f.data
	header := int(read_u16(d, at))
	tuples := header & 0x0FFF
	data := at + int(read_u16(d, at + 2))
	headers_end := data
	if len(o.deltas) < first + count {
		resize(&o.deltas, first + count)
	}
	for &v in o.deltas[first:][:count] {
		v = {}
	}
	resize(&o.tuple_dx, count)
	resize(&o.tuple_dy, count)
	resize(&o.touched, count)
	if header & 0x8000 != 0 {
		// Point numbers all tuples share.
		data, _ = read_points(d, data, end, &o.shared_points)
	} else {
		clear(&o.shared_points)
	}
	shared_all := header & 0x8000 != 0 && len(o.shared_points) == 0
	rec := at + 4
	for _ in 0 ..< tuples {
		t, next, tok := read_tuple(f, &h, rec, headers_end)
		if !tok {
			break
		}
		rec = next
		tuple_data := data
		data += t.size
		if data > end {
			break
		}
		scalar := tuple_scalar(f, &h, t.peak, t.start, t.end, t.intermediate)
		if scalar == 0 {
			continue
		}
		p := tuple_data
		all := shared_all
		points := &o.shared_points
		if t.private {
			p, all = read_points(d, p, data, &o.private_points)
			points = &o.private_points
		} else if header & 0x8000 == 0 {
			all = true
		}
		dx, dy := o.tuple_dx[:count], o.tuple_dy[:count]
		deltas := o.deltas[first:][:count]
		if all {
			p = read_deltas(d, p, data, count, dx)
			read_deltas(d, p, data, count, dy)
			for k in 0 ..< count {
				deltas[k] += {dx[k], dy[k]} * scalar
			}
			continue
		}
		// Deltas for the listed points (read into the front of the
		// scratch, then spread to their points; those past the glyph's
		// points are dropped).
		n := len(points)
		listed_x, listed_y := o.listed_x[:], o.listed_y[:]
		if len(listed_x) < n {
			resize(&o.listed_x, n)
			resize(&o.listed_y, n)
			listed_x, listed_y = o.listed_x[:], o.listed_y[:]
		}
		p = read_deltas(d, p, data, n, listed_x[:n])
		read_deltas(d, p, data, n, listed_y[:n])
		touched := o.touched[:count]
		for k in 0 ..< count {
			dx[k], dy[k] = 0, 0
			touched[k] = false
		}
		for k in 0 ..< n {
			i := int(points[k])
			if i < count {
				dx[i], dy[i] = listed_x[k], listed_y[k]
				touched[i] = true
			}
		}
		if simple {
			interpolate_untouched(o, count - PHANTOM_COUNT, dx, dy, touched)
		}
		for k in 0 ..< count {
			deltas[k] += {dx[k], dy[k]} * scalar
		}
	}
	return true
}

// IUP: in each contour, points without deltas take them from the touched
// points around them: a shift when one is touched, else interpolated
// between the two neighbours per coordinate (clamped outside them).
@(private)
interpolate_untouched :: proc(o: ^Outline, n: int, dx, dy: []f32, touched: []bool) {
	xs, ys := o.glyf.x[:n], o.glyf.y[:n]
	start := 0
	for e in o.ends {
		end := min(e + 1, n)
		if end <= start {
			break
		}
		first_touched := -1
		for k in start ..< end {
			if touched[k] {
				first_touched = k
				break
			}
		}
		if first_touched >= 0 {
			// Each untouched run between touched points k and the next.
			k := first_touched
			for {
				next := k + 1 if k + 1 < end else start
				for next != k && !touched[next] {
					next = next + 1 if next + 1 < end else start
				}
				if next == k {
					// One touched point: everything shifts with it.
					for i in start ..< end {
						if i != k {
							dx[i], dy[i] = dx[k], dy[k]
						}
					}
					break
				}
				for i := k + 1 if k + 1 < end else start; i != next; i = i + 1 if i + 1 < end else start {
					dx[i] = iup(xs[i], xs[k], xs[next], dx[k], dx[next])
					dy[i] = iup(ys[i], ys[k], ys[next], dy[k], dy[next])
				}
				if next <= k {
					break
				}
				k = next
			}
		}
		start = end
	}
}

// The delta of a point at `v` between touched points at `prev` and
// `next` (HarfBuzz's arithmetic, for the same rounding).
@(private)
iup :: #force_inline proc(v, prev, next, d_prev, d_next: f32) -> f32 {
	if prev == next {
		return d_prev if d_prev == d_next else 0
	}
	if v <= min(prev, next) {
		return d_prev if prev < next else d_next
	}
	if v >= max(prev, next) {
		return d_prev if prev > next else d_next
	}
	r := (v - prev) / (next - prev)
	return d_prev + r * (d_next - d_prev)
}

// The glyph's points (outline and components) before phantom points.
@(private)
glyf_point_count :: proc(f: ^Face, g: Glyph) -> (n: int, ok: bool) {
	at, end := glyf_range(f, g)
	if at < 0 {
		return 0, true
	}
	d := f.data
	contours := int(read_i16(d, at))
	if contours >= 0 {
		if contours == 0 {
			return 0, true
		}
		return int(read_u16(d, at + 10 + 2 * (contours - 1))) + 1, true
	}
	// A composite's points are its components.
	c := at + 10
	for c + 4 <= end {
		flags := transmute(Component_Flags)read_u16(d, c)
		n += 1
		c += 4 + (4 if .Args_Are_Words in flags else 2)
		if .Scale in flags {
			c += 2
		} else if .XY_Scale in flags {
			c += 4
		} else if .Two_By_Two in flags {
			c += 8
		}
		if .More not_in flags {
			return n, true
		}
	}
	return n, false
}

// The glyph's advance at the face's instance from its varied phantom
// points (right minus left), with no outline read: only the phantom
// points' deltas are summed.
@(private)
gvar_advance :: proc(f: ^Face, g: Glyph, depth := 0) -> (advance: int, ok: bool) {
	h, hok := gvar_header(f)
	if !hok {
		return
	}
	// A composite with USE_MY_METRICS has its component's.
	if child, found := metrics_component(f, g); found && depth < GLYF_MAX_DEPTH {
		return gvar_advance(f, child, depth + 1)
	}
	adv, _ := h_metrics(f, g)
	at, end := gvar_glyph(f, &h, g)
	if at == 0 {
		return adv, true
	}
	n, nok := glyf_point_count(f, g)
	if !nok {
		return
	}
	left, right := n, n + 1
	d := f.data
	header := int(read_u16(d, at))
	data := at + int(read_u16(d, at + 2))
	headers_end := data
	shared_at, shared_all := 0, false
	if header & 0x8000 != 0 {
		shared_at = data
		data = skip_points(d, data, end, &shared_all)
	}
	// Summed in double precision: single precision lands a unit off near
	// half-unit ties.
	delta: f64
	rec := at + 4
	for _ in 0 ..< header & 0x0FFF {
		t, next, tok := read_tuple(f, &h, rec, headers_end)
		if !tok {
			break
		}
		rec = next
		p := data
		data += t.size
		if data > end {
			break
		}
		scalar := tuple_scalar(f, &h, t.peak, t.start, t.end, t.intermediate)
		if scalar == 0 {
			continue
		}
		// Which of the tuple's deltas are the two phantom points'.
		points_at, all := shared_at, shared_all
		if t.private {
			points_at = p
			p = skip_points(d, p, data, &all)
		} else if header & 0x8000 == 0 {
			all = true
		}
		count := n + PHANTOM_COUNT
		il, ir := left, right
		if !all {
			il, ir, count = find_points(d, points_at, data, left, right)
		}
		dl := delta_at(d, p, data, count, il)
		dr := delta_at(d, p, data, count, ir)
		delta += f64(dr - dl) * f64(scalar)
	}
	return int(math.clamp(math.floor(f64(adv) + delta + 0.5), 0, f64(max(i32)))), true
}

// Skips packed point numbers; `all` when they mean every point.
@(private)
skip_points :: proc(d: []u8, p, end: int, all: ^bool) -> int {
	p := p
	count := int(read_u8(d, p))
	p += 1
	all^ = count == 0
	if count & 0x80 != 0 {
		count = (count & 0x7F) << 8 | int(read_u8(d, p))
		p += 1
	}
	n := 0
	for n < count && p < end {
		control := int(read_u8(d, p))
		p += 1
		run := control & 0x7F + 1
		p += run * (2 if control & 0x80 != 0 else 1)
		n += run
	}
	return p
}

// The positions of points `a` and `b` in the packed point numbers at `p`
// (-1 when absent), and how many numbers there are.
@(private)
find_points :: proc(d: []u8, p, end, a, b: int) -> (ia, ib, count: int) {
	ia, ib = -1, -1
	p := p
	count = int(read_u8(d, p))
	p += 1
	if count & 0x80 != 0 {
		count = (count & 0x7F) << 8 | int(read_u8(d, p))
		p += 1
	}
	v, n := 0, 0
	for n < count && p < end {
		control := int(read_u8(d, p))
		p += 1
		run := control & 0x7F + 1
		for _ in 0 ..< run {
			if n >= count {
				break
			}
			if control & 0x80 != 0 {
				v += int(read_u16(d, p))
				p += 2
			} else {
				v += int(read_u8(d, p))
				p += 1
			}
			if v == a {
				ia = n
			}
			if v == b {
				ib = n
			}
			n += 1
		}
	}
	return
}

// Delta `i` (-1 for none) of the x deltas at `p` (`count` of them).
@(private)
delta_at :: proc(d: []u8, p, end, count, i: int) -> f32 {
	if i < 0 {
		return 0
	}
	p := p
	n := 0
	for n < count && p < end {
		control := int(read_u8(d, p))
		p += 1
		run := control & 0x3F + 1
		size: int
		switch control & 0xC0 {
		case 0x80:
			size = 0
		case 0x40:
			size = 2
		case 0xC0:
			size = 4
		case:
			size = 1
		}
		if i < n + run {
			k := p + (i - n) * size
			switch size {
			case 0:
				return 0
			case 2:
				return f32(read_i16(d, k))
			case 4:
				return f32(i32(read_u32(d, k)))
			case:
				return f32(i8(read_u8(d, k)))
			}
		}
		n += run
		p += run * size
	}
	return 0
}

// The component of composite glyph `g` with USE_MY_METRICS, if any.
@(private)
metrics_component :: proc(f: ^Face, g: Glyph) -> (child: Glyph, found: bool) {
	at, end := glyf_range(f, g)
	if at < 0 || read_i16(f.data, at) >= 0 {
		return
	}
	d := f.data
	c := at + 10
	for c + 4 <= end {
		flags := transmute(Component_Flags)read_u16(d, c)
		if .Use_My_Metrics in flags {
			return Glyph(read_u16(d, c + 2)), true
		}
		c += 4 + (4 if .Args_Are_Words in flags else 2)
		if .Scale in flags {
			c += 2
		} else if .XY_Scale in flags {
			c += 4
		} else if .Two_By_Two in flags {
			c += 8
		}
		if .More not_in flags {
			break
		}
	}
	return
}
