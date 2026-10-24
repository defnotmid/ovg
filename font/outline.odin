package font

Verb :: enum u8 {
	// One point each: where the contour starts, a line's end.
	Move,
	Line,
	// The control point, then the end.
	Quad,
	// Two control points, then the end.
	Cubic,
}

// A glyph's contours (font units, y up), and the working arrays reading one
// takes. Each contour starts with a move and ends back at its start.
// Kept by the caller and reused: reading a glyph clears it.
Outline :: struct {
	verbs:  [dynamic]Verb,
	points: [dynamic][2]f32,
	// A TrueType glyph's points as stored, before contours are made from
	// them (columns: each pass reads the flags and fills x or y), and each
	// contour's last point.
	glyf:   #soa[dynamic]Glyf_Point,
	ends:   [dynamic]int,
	// A variable font's deltas (gvar.odin): per point of each glyph being
	// read (a composite's, then its components' after them), and one
	// tuple's at a time.
	deltas:         [dynamic][2]f32,
	tuple_dx:       [dynamic]f32,
	tuple_dy:       [dynamic]f32,
	touched:        [dynamic]bool,
	listed_x:       [dynamic]f32,
	listed_y:       [dynamic]f32,
	shared_points:  [dynamic]u16,
	private_points: [dynamic]u16,
}

Glyf_Point :: struct {
	x, y:  f32,
	flags: Glyf_Flags,
}

// A point's flags as glyf stores them.
Glyf_Flag :: enum u8 {
	On_Curve,
	X_Byte,
	Y_Byte,
	Repeat,
	// With X_Byte the byte is positive; without, x repeats the last.
	X_Same,
	Y_Same,
}

Glyf_Flags :: bit_set[Glyf_Flag;u8]

outline_destroy :: proc(o: ^Outline) {
	delete(o.verbs)
	delete(o.points)
	delete(o.glyf)
	delete(o.ends)
	delete(o.deltas)
	delete(o.tuple_dx)
	delete(o.tuple_dy)
	delete(o.touched)
	delete(o.listed_x)
	delete(o.listed_y)
	delete(o.shared_points)
	delete(o.private_points)
	o^ = {}
}

// Reads glyph `g`'s contours into `o`; false (and `o` empty) when it has
// none or they can't be read.
glyph_outline :: proc(f: ^Face, g: Glyph, o: ^Outline) -> bool {
	clear(&o.verbs)
	clear(&o.points)
	ok: bool
	if f.tables[.glyf].at != 0 {
		// Placed by the (varied) left phantom point.
		left: f32
		ok, left = glyf_outline(f, g, o, 0, 0)
		if shift := -left; ok && shift != 0 {
			for &p in o.points {
				p.x += shift
			}
		}
	} else {
		_, ok = cff_outline(f, g, o)
	}
	if !ok {
		clear(&o.verbs)
		clear(&o.points)
	}
	return ok && len(o.verbs) > 0
}

// The glyph's bounding box (font units, y up): glyf's stored box, or the
// box of a CFF glyph's points. False when it has no outline.
glyph_box :: proc(f: ^Face, g: Glyph) -> (x0, y0, x1, y1: int, ok: bool) {
	if f.tables[.glyf].at == 0 {
		box: [4]int
		box, ok = cff_outline(f, g, nil)
		return box[0], box[1], box[2], box[3], ok
	}
	at, _ := glyf_range(f, g)
	if at < 0 {
		return
	}
	d := f.data
	shift := int(glyf_shift(f, g))
	return int(read_i16(d, at + 2)) + shift, int(read_i16(d, at + 4)), int(read_i16(d, at + 6)) + shift, int(read_i16(d, at + 8)), true
}

// Whether the glyph has no outline (a space, or a glyph only a bitmap
// draws).
glyph_empty :: proc(f: ^Face, g: Glyph) -> bool {
	if f.tables[.glyf].at == 0 {
		_, ok := cff_outline(f, g, nil)
		return !ok
	}
	at, _ := glyf_range(f, g)
	return at < 0 || read_i16(f.data, at) == 0
}

// ---- glyf ----------------------------------------------------------------------

// Composite glyphs nest this deep at most.
@(private)
GLYF_MAX_DEPTH :: 8

// A glyph's points at most, its components' included.
@(private)
GLYF_MAX_POINTS :: 1 << 20

// How far the glyph's outline moves in x so its left edge lies at hmtx's
// side bearing (the phantom point a TrueType glyph is placed by): 0 unless
// the font's glyf box and hmtx disagree.
@(private)
glyf_shift :: proc(f: ^Face, g: Glyph) -> f32 {
	at, _ := glyf_range(f, g)
	if at < 0 {
		return 0
	}
	_, lsb := h_metrics(f, g)
	return f32(lsb - int(read_i16(f.data, at + 2)))
}

// Where the glyph's data lies; -1 when it has none.
@(private)
glyf_range :: proc(f: ^Face, g: Glyph) -> (at, end: int) {
	i := int(g)
	if i >= f.glyph_count {
		return -1, -1
	}
	a, b: int
	if i + 1 < len(f.loca_short) {
		a, b = 2 * int(f.loca_short[i].v), 2 * int(f.loca_short[i + 1].v)
	} else if i + 1 < len(f.loca_long) {
		a, b = int(f.loca_long[i].v), int(f.loca_long[i + 1].v)
	} else {
		return -1, -1
	}
	glyf := f.tables[.glyf]
	if a >= b || b > glyf.size {
		return -1, -1
	}
	return glyf.at + a, glyf.at + b
}

// Reads glyph `g` into `o`. At a variable instance its points take their
// gvar deltas, kept from o.deltas[first] on (a composite's components put
// theirs after its own). `left` is its left phantom point, which the
// outline is placed by (x 0): where hmtx's side bearing puts it, varied,
// or a component's with USE_MY_METRICS.
@(private)
glyf_outline :: proc(f: ^Face, g: Glyph, o: ^Outline, depth, first: int) -> (ok: bool, left: f32) {
	at, end := glyf_range(f, g)
	if at < 0 {
		return true, 0
	}
	d := f.data
	vary := has_variation(f) && f.tables[.gvar].at != 0
	left = -glyf_shift(f, g)
	contours := int(read_i16(d, at))
	if contours > 0 {
		if !glyf_points(f, at, end, contours, o) {
			return false, 0
		}
		if vary {
			n := len(o.glyf)
			if glyph_deltas(f, g, o, first, n + PHANTOM_COUNT, true) {
				xs, ys := o.glyf.x[:n], o.glyf.y[:n]
				deltas := o.deltas[first:][:n + PHANTOM_COUNT]
				for k in 0 ..< n {
					xs[k] += deltas[k].x
					ys[k] += deltas[k].y
				}
				left += deltas[n].x
			}
		}
		return glyf_contours(o), left
	}
	if contours == 0 || depth >= GLYF_MAX_DEPTH {
		return contours == 0, left
	}
	// Components: each glyph under a transform, its offset varied.
	count := 0
	child_first := first
	if vary {
		n, _ := glyf_point_count(f, g)
		if glyph_deltas(f, g, o, first, n + PHANTOM_COUNT, false) {
			count = n
			left += o.deltas[first + n].x
		}
		child_first = first + n + PHANTOM_COUNT
	}
	c := at + 10
	for component := 0; ; component += 1 {
		if c + 4 > end {
			return false, 0
		}
		flags := transmute(Component_Flags)read_u16(d, c)
		child := Glyph(read_u16(d, c + 2))
		c += 4
		m := [6]f32{1, 0, 0, 1, 0, 0}
		if .Args_Are_Words in flags {
			if .Args_Are_XY in flags {
				m[4], m[5] = f32(read_i16(d, c)), f32(read_i16(d, c + 2))
			}
			c += 4
		} else {
			if .Args_Are_XY in flags {
				m[4], m[5] = f32(i8(read_u8(d, c))), f32(i8(read_u8(d, c + 1)))
			}
			c += 2
		}
		if component < count && .Args_Are_XY in flags {
			m[4] += o.deltas[first + component].x
			m[5] += o.deltas[first + component].y
		}
		if .Scale in flags {
			m[0] = f2dot14(d, c)
			m[3] = m[0]
			c += 2
		} else if .XY_Scale in flags {
			m[0], m[3] = f2dot14(d, c), f2dot14(d, c + 2)
			c += 4
		} else if .Two_By_Two in flags {
			m[0], m[1], m[2], m[3] = f2dot14(d, c), f2dot14(d, c + 2), f2dot14(d, c + 4), f2dot14(d, c + 6)
			c += 8
		}
		// The offset is in the parent's units unless the font asks for it
		// to be transformed too (Apple's convention).
		if .Scaled_Component_Offset in flags && .Unscaled_Component_Offset not_in flags {
			m[4], m[5] = m[0] * m[4] + m[2] * m[5], m[1] * m[4] + m[3] * m[5]
		}
		first_point := len(o.points)
		child_ok, child_left := glyf_outline(f, child, o, depth + 1, child_first)
		if !child_ok || len(o.points) > GLYF_MAX_POINTS {
			return false, 0
		}
		if .Use_My_Metrics in flags {
			left = child_left
		}
		for &p in o.points[first_point:] {
			p = {m[0] * p.x + m[2] * p.y + m[4], m[1] * p.x + m[3] * p.y + m[5]}
		}
		if .More not_in flags {
			return true, left
		}
	}
}

// A composite glyph's component flags (point matching is not read: such a
// component is placed at the origin).
@(private)
Component_Flag :: enum u16 {
	Args_Are_Words,
	Args_Are_XY,
	Round_XY,
	Scale,
	More = 5,
	XY_Scale,
	Two_By_Two,
	Have_Instructions,
	Use_My_Metrics,
	Scaled_Component_Offset = 11,
	Unscaled_Component_Offset,
}

@(private)
Component_Flags :: bit_set[Component_Flag;u16]

@(private)
f2dot14 :: #force_inline proc "contextless" (d: []u8, at: int) -> f32 {
	return f32(read_i16(d, at)) / 16384
}

// A simple glyph's points into `o.glyf` and `o.ends`.
@(private)
glyf_points :: proc(f: ^Face, at, end, contours: int, o: ^Outline) -> bool {
	d := f.data
	clear(&o.glyf)
	clear(&o.ends)
	ends := at + 10
	for i in 0 ..< contours {
		append(&o.ends, int(read_u16(d, ends + 2 * i)))
	}
	n := o.ends[contours - 1] + 1
	p := ends + 2 * contours
	p += 2 + int(read_u16(d, p))
	resize(&o.glyf, n)
	flags, xs, ys := o.glyf.flags[:n], o.glyf.x[:n], o.glyf.y[:n]
	// The flags, and the sizes of the x and y streams they imply; then the
	// streams, read without further checks once they are known to fit.
	f: Glyf_Flags
	repeat := 0
	x_size, y_size := 0, 0
	for &fl in flags {
		if repeat > 0 {
			repeat -= 1
		} else {
			f = transmute(Glyf_Flags)read_u8(d, p)
			p += 1
			if .Repeat in f {
				repeat = int(read_u8(d, p))
				p += 1
			}
		}
		fl = f
		x_size += 1 if .X_Byte in f else (0 if .X_Same in f else 2)
		y_size += 1 if .Y_Byte in f else (0 if .Y_Same in f else 2)
	}
	if p + x_size + y_size > end {
		return false
	}
	read_coords(flags, xs, d[p:][:x_size], .X_Byte, .X_Same)
	read_coords(flags, ys, d[p + x_size:][:y_size], .Y_Byte, .Y_Same)
	return true
}

// One coordinate stream: a byte (signed by `same`), nothing (the last
// value again, `same` set) or a 16-bit delta, per point.
@(private)
read_coords :: proc(flags: []Glyf_Flags, out: []f32, stream: []u8, byte, same: Glyf_Flag) {
	v: i32
	i := 0
	#no_bounds_check for fl, k in flags {
		if byte in fl {
			b := i32(stream[i])
			i += 1
			v += b if same in fl else -b
		} else if same not_in fl {
			v += i32(i16(u16(stream[i]) << 8 | u16(stream[i + 1])))
			i += 2
		}
		out[k] = f32(i16(v))
	}
}

// Contours from the points in `o.glyf`: consecutive off-curve points
// imply an on-curve point midway; a contour starting off the curve starts
// at the next point (midway, when that one is off too).
@(private)
glyf_contours :: proc(o: ^Outline) -> bool {
	n := len(o.glyf)
	flags, xs, ys := o.glyf.flags[:n], o.glyf.x[:n], o.glyf.y[:n]
	// Each point adds a verb at most (a move takes its contour's first),
	// each contour two more when it closes, each verb two points at most:
	// sized once, filled by index, cut to what was written.
	v, p := len(o.verbs), len(o.points)
	resize(&o.verbs, v + n + 2 * len(o.ends))
	resize(&o.points, p + 2 * (n + 2 * len(o.ends)))
	verbs, points := o.verbs[:], o.points[:]
	line :: #force_inline proc(verbs: []Verb, points: [][2]f32, v, p: ^int, verb: Verb, a: [2]f32) {
		#no_bounds_check {
			verbs[v^], points[p^] = verb, a
		}
		v^, p^ = v^ + 1, p^ + 1
	}
	quad :: #force_inline proc(verbs: []Verb, points: [][2]f32, v, p: ^int, c, a: [2]f32) {
		#no_bounds_check {
			verbs[v^], points[p^], points[p^ + 1] = .Quad, c, a
		}
		v^, p^ = v^ + 1, p^ + 2
	}
	mid :: #force_inline proc(a, b: [2]f32) -> [2]f32 {
		return (a + b) * 0.5
	}
	close :: #force_inline proc(verbs: []Verb, points: [][2]f32, v, p: ^int, was_off, start_off: bool, start, start_c, c: [2]f32) {
		if start_off {
			if was_off {
				quad(verbs, points, v, p, c, mid(c, start_c))
			}
			quad(verbs, points, v, p, start_c, start)
		} else if was_off {
			quad(verbs, points, v, p, c, start)
		} else {
			line(verbs, points, v, p, .Line, start)
		}
	}
	start, start_c, c: [2]f32
	start_off, was_off := false, false
	contour := 0
	next := 0
	for i := 0; i < n; i += 1 {
		pt, on := [2]f32{xs[i], ys[i]}, .On_Curve in flags[i]
		if i == next {
			if i != 0 {
				close(verbs, points, &v, &p, was_off, start_off, start, start_c, c)
			}
			start_off = !on
			if start_off {
				start_c = pt
				k := min(i + 1, n - 1)
				after := [2]f32{xs[k], ys[k]}
				if .On_Curve not_in flags[k] {
					start = mid(pt, after)
				} else {
					start = after
					i += 1
				}
			} else {
				start = pt
			}
			line(verbs, points, &v, &p, .Move, start)
			was_off = false
			next = o.ends[contour] + 1 if contour < len(o.ends) else n + 1
			contour += 1
		} else if !on {
			if was_off {
				quad(verbs, points, &v, &p, c, mid(c, pt))
			}
			c = pt
			was_off = true
		} else {
			if was_off {
				quad(verbs, points, &v, &p, c, pt)
			} else {
				line(verbs, points, &v, &p, .Line, pt)
			}
			was_off = false
		}
	}
	close(verbs, points, &v, &p, was_off, start_off, start, start_c, c)
	resize(&o.verbs, v)
	resize(&o.points, p)
	return true
}
