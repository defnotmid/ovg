package font

import "core:math"
import "core:slice"

// CFF (OpenType's PostScript outlines): Type 2 charstrings, run for each
// glyph. Hints are skipped; flex is drawn as its two curves.
//
// CFF2 (variable fonts) differs in its header and INDEX counts, has no
// endchar or return (charstrings and subroutines end where their data
// does), and adds blend: operands given as a default plus a delta per
// region of its variation store, summed at the face's instance.

// The face's CFF indexes, slices of the borrowed font data.
Cff :: struct {
	table:       []u8,
	charstrings: []u8,
	gsubrs:      []u8,
	// The top dict's local subroutines; CID-keyed fonts take each glyph's
	// from its font dict instead.
	subrs:       []u8,
	fontdicts:   []u8,
	fdselect:    []u8,
	// The string INDEX (SIDs from 391 on) and where the charset lies (0, 1
	// and 2 name the predefined ones): glyph names (names.odin).
	strings:     []u8,
	charset:     int,
	// CFF2: INDEX counts are 32-bit; blends read the variation store at
	// `vstore` in the table (0 for none).
	cff2:        bool,
	vstore:      int,
}

// A read position in a CFF structure; reads past the end give 0.
@(private)
Buf :: struct {
	d:   []u8,
	pos: int,
}

@(private)
get8 :: proc(b: ^Buf) -> int {
	if b.pos >= len(b.d) {
		return 0
	}
	b.pos += 1
	return int(b.d[b.pos - 1])
}

@(private)
get :: proc(b: ^Buf, n: int) -> int {
	v := 0
	for _ in 0 ..< n {
		v = v << 8 | get8(b)
	}
	return v
}

@(private)
seek :: proc(b: ^Buf, o: int) {
	b.pos = len(b.d) if o < 0 || o > len(b.d) else o
}

@(private)
sub :: proc(d: []u8, o, size: int) -> []u8 {
	if o < 0 || size < 0 || o > len(d) || size > len(d) - o {
		return nil
	}
	return d[o:][:size]
}

// The INDEX at the read position (skipping it). `wide`: CFF2's, whose
// count is 32-bit.
@(private)
index_at :: proc(b: ^Buf, wide := false) -> []u8 {
	start := b.pos
	if count := get(b, 4 if wide else 2); count > 0 {
		size := get8(b)
		if size < 1 || size > 4 {
			return nil
		}
		seek(b, b.pos + size * count)
		// The last offset: one past the data's end, counting from 1.
		end := get(b, size)
		seek(b, b.pos + end - 1)
	}
	return sub(b.d, start, b.pos - start)
}

@(private)
index_count :: proc(index: []u8, wide := false) -> int {
	return int(read_u32(index, 0)) if wide else int(read_u16(index, 0))
}

// Object `i` of an INDEX.
@(private)
index_get :: proc(index: []u8, i: int, wide := false) -> []u8 {
	count := index_count(index, wide)
	head := 4 if wide else 2
	size := int(read_u8(index, head))
	if i < 0 || i >= count || size < 1 || size > 4 {
		return nil
	}
	b := Buf{index, head + 1 + i * size}
	start := get(&b, size)
	end := get(&b, size)
	return sub(index, head + (count + 1) * size + start, end - start)
}

// A DICT or charstring integer operand.
@(private)
operand :: proc(b: ^Buf) -> i32 {
	b0 := get8(b)
	switch b0 {
	case 32 ..= 246:
		return i32(b0 - 139)
	case 247 ..= 250:
		return i32((b0 - 247) * 256 + get8(b) + 108)
	case 251 ..= 254:
		return i32(-(b0 - 251) * 256 - get8(b) - 108)
	case 28:
		return i32(get(b, 2))
	case 29:
		return i32(u32(get(b, 4)))
	}
	return 0
}

// The operands of `key` in a DICT (a two-byte operator is 0x100 | its
// second byte).
@(private)
dict_get :: proc(dict: []u8, key: int) -> []u8 {
	b := Buf{dict, 0}
	for b.pos < len(b.d) {
		start := b.pos
		for b.pos < len(b.d) && b.d[b.pos] >= 28 {
			if b.d[b.pos] == 30 {
				// A real number: nibbles up to an end nibble.
				b.pos += 1
				for b.pos < len(b.d) {
					v := get8(&b)
					if v & 0xf == 0xf || v >> 4 == 0xf {
						break
					}
				}
			} else {
				operand(&b)
			}
		}
		end := b.pos
		op := get8(&b)
		if op == 12 {
			op = get8(&b) | 0x100
		}
		if op == key {
			return sub(b.d, start, end - start)
		}
	}
	return nil
}

@(private)
dict_ints :: proc(dict: []u8, key: int, out: []int) {
	b := Buf{dict_get(dict, key), 0}
	for &v in out {
		if b.pos >= len(b.d) {
			break
		}
		v = int(u32(operand(&b)))
	}
}

// The local subroutines of a font dict's private dict, and (CFF2) its
// default variation store data index.
@(private)
private_subrs :: proc(cff, dict: []u8, wide := false) -> (subrs: []u8, vsindex: int) {
	private := [2]int{} // size, offset
	dict_ints(dict, 18, private[:])
	if private[0] == 0 || private[1] == 0 {
		return nil, 0
	}
	pd := sub(cff, private[1], private[0])
	at := [1]int{}
	dict_ints(pd, 19, at[:])
	vs := [1]int{}
	dict_ints(pd, 22, vs[:])
	if at[0] == 0 {
		return nil, vs[0]
	}
	b := Buf{cff, 0}
	seek(&b, private[1] + at[0])
	return index_at(&b, wide), vs[0]
}

@(private)
cff_load :: proc(f: ^Face) -> Error {
	t := f.tables[.CFF]
	c := &f.cff
	c.table = f.data[t.at:][:t.size]
	if read_u8(c.table, 0) != 1 {
		// CFF2 (variable) and unknown versions.
		return .Unsupported
	}
	b := Buf{c.table, 2}
	seek(&b, get8(&b)) // the header's size
	index_at(&b) // names: the first font is used
	top := index_get(index_at(&b), 0)
	c.strings = index_at(&b)
	c.gsubrs = index_at(&b)
	kind := [1]int{2}
	charstrings, fdarray, fdselect, charset: [1]int
	dict_ints(top, 17, charstrings[:])
	dict_ints(top, 15, charset[:])
	c.charset = charset[0]
	dict_ints(top, 0x100 | 6, kind[:])
	dict_ints(top, 0x100 | 36, fdarray[:])
	dict_ints(top, 0x100 | 37, fdselect[:])
	c.subrs, _ = private_subrs(c.table, top)
	if kind[0] != 2 {
		return .Unsupported
	}
	if charstrings[0] == 0 {
		return .Bad_Table
	}
	if fdarray[0] != 0 {
		if fdselect[0] == 0 {
			return .Bad_Table
		}
		seek(&b, fdarray[0])
		c.fontdicts = index_at(&b)
		c.fdselect = sub(c.table, fdselect[0], len(c.table) - fdselect[0])
	}
	seek(&b, charstrings[0])
	c.charstrings = index_at(&b)
	return nil
}

// CFF2 (version 2): its top dict, global subroutines, charstrings, font
// dicts (always) with their selector, and variation store.
@(private)
cff2_load :: proc(f: ^Face) -> Error {
	t := f.tables[.CFF2]
	c := &f.cff
	c.table = f.data[t.at:][:t.size]
	c.cff2 = true
	if read_u8(c.table, 0) != 2 {
		return .Unsupported
	}
	header := int(read_u8(c.table, 2))
	top := sub(c.table, header, int(read_u16(c.table, 3)))
	b := Buf{c.table, 0}
	seek(&b, header + len(top))
	c.gsubrs = index_at(&b, true)
	charstrings, fdarray, fdselect, vstore: [1]int
	dict_ints(top, 17, charstrings[:])
	dict_ints(top, 0x100 | 36, fdarray[:])
	dict_ints(top, 0x100 | 37, fdselect[:])
	dict_ints(top, 24, vstore[:])
	if charstrings[0] == 0 || fdarray[0] == 0 {
		return .Bad_Table
	}
	seek(&b, fdarray[0])
	c.fontdicts = index_at(&b, true)
	if fdselect[0] != 0 {
		c.fdselect = sub(c.table, fdselect[0], len(c.table) - fdselect[0])
	}
	if vstore[0] != 0 {
		// After its 16-bit length.
		c.vstore = vstore[0] + 2
	}
	seek(&b, charstrings[0])
	c.charstrings = index_at(&b, true)
	return nil
}

// FDSelect format 3's ranges: the first glyph each font dict serves from
// (a 16-bit sentinel after them ends the last).
@(private)
Fd_Range :: struct #packed {
	first: u16be,
	fd:    u8,
}

// A CID-keyed font's (or CFF2's) local subroutines for glyph `g`, and its
// font dict's default variation store data index.
@(private)
glyph_subrs :: proc(c: ^Cff, g: Glyph) -> (subrs: []u8, vsindex: int) {
	// CFF2 without a selector has one font dict.
	fd := 0 if c.cff2 && len(c.fdselect) == 0 else -1
	switch read_u8(c.fdselect, 0) {
	case 0:
		if int(g) + 1 < len(c.fdselect) {
			fd = int(c.fdselect[int(g) + 1])
		}
	case 3:
		count := int(read_u16(c.fdselect, 1))
		ranges := records(c.fdselect, 3, count, Fd_Range)
		// The last range starting at or before g, if g is before the end.
		i, found := slice.binary_search_by(ranges, g, proc(r: Fd_Range, g: Glyph) -> slice.Ordering {
			return slice.cmp(u16(r.first), g)
		})
		if found {
			i += 1
		}
		if i > 0 && g < read_u16(c.fdselect, 3 + 3 * count) {
			fd = int(ranges[i - 1].fd)
		}
	case 4:
		// CFF2: 32-bit ranges (first glyph, font dict), then a sentinel.
		count := int(read_u32(c.fdselect, 1))
		lo, hi := 0, min(count, max(len(c.fdselect) - 5, 0) / 6)
		for lo < hi {
			mid := (lo + hi) / 2
			if read_u32(c.fdselect, 5 + 6 * mid) <= u32(g) {
				lo = mid + 1
			} else {
				hi = mid
			}
		}
		if lo > 0 && u32(g) < read_u32(c.fdselect, 5 + 6 * count) {
			fd = int(read_u16(c.fdselect, 5 + 6 * (lo - 1) + 4))
		}
	}
	return private_subrs(c.table, index_get(c.fontdicts, fd, c.cff2), c.cff2)
}

@(private)
subr :: proc(index: []u8, n: int, wide := false) -> []u8 {
	count := index_count(index, wide)
	bias := 107
	if count >= 33900 {
		bias = 32768
	} else if count >= 1240 {
		bias = 1131
	}
	return index_get(index, n + bias, wide)
}

// ---- charstrings ------------------------------------------------------------------

// A charstring's pen: the points go to `out` (when not nil) and grow `box`.
// Positions add up relative moves, in f64 so a contour's blended moves
// come back exactly to its start (as HarfBuzz's doubles do).
@(private)
Pen :: struct {
	out:      ^Outline,
	started:  bool,
	first, p: [2]f64,
	box:      [4]f32, // min x, min y, max x, max y
	count:    int,
}

@(private)
pen_emit :: proc(pen: ^Pen, v: Verb, pts: ..[2]f64) {
	pen.count += 1
	for q in pts {
		p := [2]f32{f32(q.x), f32(q.y)}
		if !pen.started {
			pen.box = {p.x, p.y, p.x, p.y}
			pen.started = true
		}
		pen.box = {min(pen.box[0], p.x), min(pen.box[1], p.y), max(pen.box[2], p.x), max(pen.box[3], p.y)}
		if pen.out != nil {
			append(&pen.out.points, p)
		}
	}
	if pen.out != nil {
		append(&pen.out.verbs, v)
	}
}

@(private)
pen_close :: proc(pen: ^Pen) {
	if pen.first != pen.p {
		pen_emit(pen, .Line, pen.first)
	}
}

@(private)
pen_move :: proc(pen: ^Pen, dx, dy: f64) {
	pen_close(pen)
	pen.p += {dx, dy}
	pen.first = pen.p
	pen_emit(pen, .Move, pen.p)
}

@(private)
pen_line :: proc(pen: ^Pen, dx, dy: f64) {
	pen.p += {dx, dy}
	pen_emit(pen, .Line, pen.p)
}

@(private)
pen_curve :: proc(pen: ^Pen, dx1, dy1, dx2, dy2, dx3, dy3: f64) {
	c1 := pen.p + {dx1, dy1}
	c2 := c1 + {dx2, dy2}
	pen.p = c2 + {dx3, dy3}
	pen_emit(pen, .Cubic, c1, c2, pen.p)
}

// Runs glyph `g`'s charstring into `out` (nil: the box only); false when
// it can't be run (and nothing is added).
@(private)
cff_outline :: proc(f: ^Face, g: Glyph, out: ^Outline) -> (box: [4]int, ok: bool) {
	pen := Pen{out = out}
	verbs, points: int
	if out != nil {
		verbs, points = len(out.verbs), len(out.points)
	}
	if !charstring(f, g, &pen) {
		if out != nil {
			resize(&out.verbs, verbs)
			resize(&out.points, points)
		}
		return
	}
	b := pen.box
	return {int(math.floor(b[0])), int(math.floor(b[1])), int(math.ceil(b[2])), int(math.ceil(b[3]))}, pen.count > 0
}

// CFF2's operand stack holds 513 operands at most (CFF's 48).
@(private)
CFF_MAX_STACK :: 513

@(private)
charstring :: proc(f: ^Face, g: Glyph, pen: ^Pen) -> bool {
	c := &f.cff
	s: [CFF_MAX_STACK]f64
	sp := 0
	calls: [10]Buf
	depth := 0
	in_header := true
	mask_bits := 0
	subrs := c.subrs
	have_subrs := false
	// CFF2: the variation store data blends use (the font dict's default
	// until vsindex), and its regions' scalars at the instance, found at
	// the first blend.
	vsindex := 0
	if c.cff2 {
		subrs, vsindex = glyph_subrs(c, g)
		have_subrs = true
	}
	scalars: [CFF_MAX_STACK]f32
	regions := -1
	b := Buf{index_get(c.charstrings, int(g), c.cff2), 0}
	for {
		if b.pos >= len(b.d) {
			// CFF2's charstrings and subroutines end with their data.
			if !c.cff2 {
				return false
			}
			if depth == 0 {
				pen_close(pen)
				return true
			}
			depth -= 1
			b = calls[depth]
			continue
		}
		i := 0
		clear_stack := true
		b0 := get8(&b)
		switch b0 {
		case 0x0f:
			// vsindex
			if !c.cff2 || sp < 1 {
				return false
			}
			vsindex = int(s[sp - 1])
			regions = -1
		case 0x10:
			// blend: n values, each a default and a delta per region.
			if !c.cff2 || sp < 1 {
				return false
			}
			if regions < 0 {
				regions = blend_scalars(f, vsindex, scalars[:])
				if regions < 0 {
					return false
				}
			}
			n := int(s[sp - 1])
			sp -= 1
			if n < 0 || n * (regions + 1) > sp {
				return false
			}
			base := sp - n * (regions + 1)
			for k in 0 ..< n {
				v := s[base + k]
				for r in 0 ..< regions {
					v += s[base + n + k * regions + r] * f64(scalars[r])
				}
				s[base + k] = v
			}
			sp = base + n
			clear_stack = false
		case 0x13, 0x14:
			// hintmask, cntrmask: the stems before them are implied vstems.
			if in_header {
				mask_bits += sp / 2
			}
			in_header = false
			seek(&b, b.pos + (mask_bits + 7) / 8)
		case 0x01, 0x03, 0x12, 0x17:
			// hstem, vstem, hstemhm, vstemhm
			mask_bits += sp / 2
		case 0x15:
			// rmoveto
			in_header = false
			if sp < 2 {
				return false
			}
			pen_move(pen, s[sp - 2], s[sp - 1])
		case 0x04:
			// vmoveto
			in_header = false
			if sp < 1 {
				return false
			}
			pen_move(pen, 0, s[sp - 1])
		case 0x16:
			// hmoveto
			in_header = false
			if sp < 1 {
				return false
			}
			pen_move(pen, s[sp - 1], 0)
		case 0x05:
			// rlineto
			if sp < 2 {
				return false
			}
			for ; i + 1 < sp; i += 2 {
				pen_line(pen, s[i], s[i + 1])
			}
		case 0x06, 0x07:
			// hlineto, vlineto: lines alternating horizontal and vertical
			if sp < 1 {
				return false
			}
			horizontal := b0 == 0x06
			for ; i < sp; i += 1 {
				if horizontal {
					pen_line(pen, s[i], 0)
				} else {
					pen_line(pen, 0, s[i])
				}
				horizontal = !horizontal
			}
		case 0x1e, 0x1f:
			// vhcurveto, hvcurveto: curves alternately starting vertical
			// and horizontal; a fifth operand ends the last one off-axis.
			if sp < 4 {
				return false
			}
			horizontal := b0 == 0x1f
			for ; i + 3 < sp; i += 4 {
				last := s[i + 4] if sp - i == 5 else 0
				if horizontal {
					pen_curve(pen, s[i], 0, s[i + 1], s[i + 2], last, s[i + 3])
				} else {
					pen_curve(pen, 0, s[i], s[i + 1], s[i + 2], s[i + 3], last)
				}
				horizontal = !horizontal
			}
		case 0x08:
			// rrcurveto
			if sp < 6 {
				return false
			}
			for ; i + 5 < sp; i += 6 {
				pen_curve(pen, s[i], s[i + 1], s[i + 2], s[i + 3], s[i + 4], s[i + 5])
			}
		case 0x18:
			// rcurveline
			if sp < 8 {
				return false
			}
			for ; i + 5 < sp - 2; i += 6 {
				pen_curve(pen, s[i], s[i + 1], s[i + 2], s[i + 3], s[i + 4], s[i + 5])
			}
			if i + 1 >= sp {
				return false
			}
			pen_line(pen, s[i], s[i + 1])
		case 0x19:
			// rlinecurve
			if sp < 8 {
				return false
			}
			for ; i + 1 < sp - 6; i += 2 {
				pen_line(pen, s[i], s[i + 1])
			}
			if i + 5 >= sp {
				return false
			}
			pen_curve(pen, s[i], s[i + 1], s[i + 2], s[i + 3], s[i + 4], s[i + 5])
		case 0x1a, 0x1b:
			// vvcurveto, hhcurveto; an odd operand first starts the first
			// curve off-axis.
			if sp < 4 {
				return false
			}
			off: f64
			if sp & 1 != 0 {
				off = s[i]
				i += 1
			}
			for ; i + 3 < sp; i += 4 {
				if b0 == 0x1b {
					pen_curve(pen, s[i], off, s[i + 1], s[i + 2], s[i + 3], 0)
				} else {
					pen_curve(pen, off, s[i], s[i + 1], s[i + 2], 0, s[i + 3])
				}
				off = 0
			}
		case 0x0a, 0x1d:
			// callsubr, callgsubr
			if b0 == 0x0a && !have_subrs {
				if len(c.fdselect) > 0 {
					subrs, _ = glyph_subrs(c, g)
				}
				have_subrs = true
			}
			if sp < 1 || depth >= len(calls) {
				return false
			}
			sp -= 1
			v := int(s[sp])
			calls[depth] = b
			depth += 1
			b = {subr(subrs if b0 == 0x0a else c.gsubrs, v, c.cff2), 0}
			if len(b.d) == 0 {
				return false
			}
			clear_stack = false
		case 0x0b:
			// return
			if depth == 0 {
				return false
			}
			depth -= 1
			b = calls[depth]
			clear_stack = false
		case 0x0e:
			// endchar
			pen_close(pen)
			return true
		case 0x0c:
			flex(pen, get8(&b), s[:sp]) or_return
		case:
			if b0 != 255 && b0 != 28 && b0 < 32 {
				return false
			}
			v: f64
			if b0 == 255 {
				v = f64(i32(u32(get(&b, 4)))) / 0x10000
			} else {
				b.pos -= 1
				v = f64(i16(operand(&b)))
			}
			if sp >= len(s) {
				return false
			}
			s[sp] = v
			sp += 1
			clear_stack = false
		}
		if clear_stack {
			sp = 0
		}
	}
}

// The scalars at the face's instance of the regions variation store data
// `vsindex` blends over (into `out`); how many, -1 when it can't be read.
@(private)
blend_scalars :: proc(f: ^Face, vsindex: int, out: []f32) -> int {
	c := &f.cff
	d, store := c.table, c.vstore
	if store == 0 || read_u16(d, store) != 1 || vsindex < 0 || vsindex >= int(read_u16(d, store + 6)) {
		return -1
	}
	regions := store + int(read_u32(d, store + 2))
	data := store + int(read_u32(d, store + 8 + 4 * vsindex))
	count := int(read_u16(d, data + 4))
	if count > len(out) {
		return -1
	}
	// Regions that can't be read blend as the default instance.
	coords := f.coords[:f.axis_count]
	axes, list_count, ok := region_list(d, regions, coords)
	for k in 0 ..< count {
		r := int(read_u16(d, data + 6 + 2 * k))
		out[k] = region_scalar(d, regions + 4 + r * axes * 6, axes, coords) if ok && r < list_count else 0
	}
	return count
}

// The two-byte operators: the flexes, each drawn as two curves (their
// depth is ignored).
@(private)
flex :: proc(pen: ^Pen, op: int, s: []f64) -> bool {
	switch op {
	case 0x22:
		// hflex
		if len(s) < 7 {
			return false
		}
		pen_curve(pen, s[0], 0, s[1], s[2], s[3], 0)
		pen_curve(pen, s[4], 0, s[5], -s[2], s[6], 0)
	case 0x23:
		// flex
		if len(s) < 13 {
			return false
		}
		pen_curve(pen, s[0], s[1], s[2], s[3], s[4], s[5])
		pen_curve(pen, s[6], s[7], s[8], s[9], s[10], s[11])
	case 0x24:
		// hflex1
		if len(s) < 9 {
			return false
		}
		pen_curve(pen, s[0], s[1], s[2], s[3], s[4], 0)
		pen_curve(pen, s[5], 0, s[6], s[7], s[8], -(s[1] + s[3] + s[7]))
	case 0x25:
		// flex1: the last point returns to the start's x or y, whichever
		// moved less.
		if len(s) < 11 {
			return false
		}
		dx := s[0] + s[2] + s[4] + s[6] + s[8]
		dy := s[1] + s[3] + s[5] + s[7] + s[9]
		dx6, dy6 := s[10], s[10]
		if math.abs(dx) > math.abs(dy) {
			dy6 = -dy
		} else {
			dx6 = -dx
		}
		pen_curve(pen, s[0], s[1], s[2], s[3], s[4], s[5])
		pen_curve(pen, s[6], s[7], s[8], s[9], dx6, dy6)
	case:
		return false
	}
	return true
}
