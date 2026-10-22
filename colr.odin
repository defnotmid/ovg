package ovg

import "base:runtime"
import "core:math"
import "core:sync"

import ft "font"

// Colour glyphs from the COLR (v0 layers, v1 paint graphs) and CPAL tables,
// drawn as vector fills at the output resolution like plain outlines.
// Palette 0; palette index 0xFFFF is the text's own paint.
//
// Each colour glyph's paint graph is flattened once into fill rows (an
// outline, its transform, a solid or gradient paint) kept by the font; the
// outlines are the font's glyph shapes (font_glyph_shape), so a warm glyph
// draws without parsing or allocating.
// PaintComposite has no offscreen group here: source-over / destination-over
// draw in order, the `in` / `atop` modes fill one side's outlines with the
// other side's paint, and the remaining modes (blend modes, xor, out, plus)
// draw the backdrop alone. Nested PaintGlyph clips keep the innermost
// outline. Variations (VarIndex) are ignored: the default instance.
//
// Bitmap colour formats (sbix, CBDT / CBLC) and SVG glyphs are not drawn:
// such a face only serves glyphs that also have an outline.

@(private)
Colr_Kind :: enum u8 {
	Solid,
	Linear,
	Radial,
	Sweep,
}

// One flattened fill of a colour glyph (font units, y up).
@(private)
Colr_Fill :: struct {
	// Outline to fill; -1 fills the glyph's clip box.
	glyph:   i32,
	// Outline space to glyph space.
	shape:   Transform2D,
	// Paint space to outline space.
	paint:   Transform2D,
	kind:    Colr_Kind,
	extend:  Gradient_Spread,
	palette: u16, // Solid
	alpha:   f32,
	// Linear: p0, p1 (stops normalized to [0, 1]). Radial: c0, r0, c1, r1.
	// Sweep: center, start and end angle in degrees.
	geom:    [6]f32,
	stops:   [2]i32, // first, count into Colr.stops
}

@(private)
Colr_Stop :: struct {
	offset:  f32,
	palette: u16,
	alpha:   f32,
}

@(private)
Colr_Glyph :: struct {
	first, count: i32, // fills
	clip:         [4]f32, // x0, y0, x1, y1
	has_clip:     bool,
	colour:       bool,
}

// The colour tables of a face and its cache of flattened glyphs. Shared by
// copies of the Font; the lock guards the cache and the draw scratch.
Colr :: struct {
	data:                     []u8,
	version:                  int,
	v0_base, v0_layers:       int, // absolute offsets
	v0_base_count:            int,
	base_list, layer_list:    int, // v1, 0 when absent
	clip_list:                int,
	palette, palette_entries: int, // palette 0's first colour record
	lock:                     sync.Mutex,
	glyphs:                   map[Glyph_Index]Colr_Glyph,
	fills:                    [dynamic]Colr_Fill,
	stops:                    [dynamic]Colr_Stop,
	// Draw scratch.
	path:                     Path,
	ramp:                     [dynamic]Gradient_Stop,
	// The glyph being flattened: its first fill and its walk's budget
	// (Colr_Paints).
	glyph_first:              int,
	budget:                   Budget,
}

@(private = "file")
COLR_MAX_DEPTH :: 32

@(private = "file")
COLR_MAX_FILLS :: 4096

@(private = "file")
COLR_MAX_STOPS :: 256

// Finds the COLR / CPAL tables of a face (nil when it has none).
@(private)
colr_open :: proc(f: ^Font) -> ^Colr {
	d := f.data
	colr_span, cpal_span := f.face.tables[.COLR], f.face.tables[.CPAL]
	if colr_span.size < 14 || cpal_span.size < 14 {
		return nil
	}
	colr, cpal := colr_span.at, cpal_span.at
	cl := new(Colr, runtime.heap_allocator())
	cl.data = d
	cl.version = int(ft.read_u16(d, colr))
	cl.v0_base_count = int(ft.read_u16(d, colr + 2))
	cl.v0_base = colr + int(ft.read_u32(d, colr + 4))
	cl.v0_layers = colr + int(ft.read_u32(d, colr + 8))
	if cl.version >= 1 && colr_span.size >= 34 {
		at :: proc(d: []u8, colr, field: int) -> int {
			off := int(ft.read_u32(d, colr + field))
			return colr + off if off != 0 else 0
		}
		cl.base_list = at(d, colr, 14)
		cl.layer_list = at(d, colr, 18)
		cl.clip_list = at(d, colr, 22)
	}
	cl.palette_entries = int(ft.read_u16(d, cpal + 2))
	if ft.read_u16(d, cpal + 4) > 0 {
		records := cpal + int(ft.read_u32(d, cpal + 8))
		cl.palette = records + int(ft.read_u16(d, cpal + 12)) * 4
	}
	heap := runtime.heap_allocator()
	cl.glyphs.allocator = heap
	cl.fills.allocator = heap
	cl.stops.allocator = heap
	cl.ramp.allocator = heap
	path_init(&cl.path, heap)
	return cl
}

@(private)
colr_destroy :: proc(cl: ^Colr) {
	if cl == nil {
		return
	}
	context.allocator = runtime.heap_allocator()
	delete(cl.glyphs)
	delete(cl.fills)
	delete(cl.stops)
	delete(cl.ramp)
	path_destroy(&cl.path)
	free(cl)
}

// Whether glyph `g` of `f` has a colour record (v1 paint or v0 layers).
font_glyph_is_colour :: proc(f: ^Font, g: Glyph_Index) -> bool {
	cl := f.colr
	if cl == nil {
		return false
	}
	sync.mutex_lock(&cl.lock)
	defer sync.mutex_unlock(&cl.lock)
	return colr_glyph(cl, g).colour
}

// ---- drawing ------------------------------------------------------------------------

// Draws glyph `g` in colour if it has a colour record. `em` converts font
// units to pixels; `fg` is the text's paint (palette index 0xFFFF). The
// caller holds `cl.lock`.
@(private)
colr_draw_glyph :: proc(c: ^Canvas, f: ^Font, g: Positioned_Glyph, em: f32, fg: Paint) -> bool {
	cl := f.colr
	info := colr_glyph(cl, g.glyph)
	if !info.colour {
		return false
	}
	// The shared scratch path's buffers live on the heap.
	context.allocator = runtime.heap_allocator()
	t0 := current_transform(c)
	place := Transform2D{em, 0, 0, -em, g.x, g.y}
	base := transform_multiply(place, t0)
	if info.has_clip {
		save(c)
		set_transform(c, base)
		b := info.clip
		intersect_scissor(c, b[0], b[1], b[2] - b[0], b[3] - b[1])
	}
	fg_color, fg_solid := fg.flavor.(Paint_Color)
	if !fg_solid {
		fg_color = BLACK
	}
	for &fill in cl.fills[info.first:][:info.count] {
		if fill.glyph < 0 && !info.has_clip {
			continue
		}
		set_transform(c, transform_multiply(fill.shape, base))
		paint: Paint
		if fill.kind == .Solid && fill.palette == 0xFFFF && !fg_solid {
			// A non-solid text paint fills foreground layers as it is.
			paint = fg
			user := fg.transform if fg.transform != {} else TRANSFORM_IDENTITY
			paint.transform = transform_multiply(user, transform_inverse(transform_multiply(fill.shape, place)))
			paint_mul_alpha(&paint, fill.alpha)
		} else {
			paint = colr_paint_for(cl, &fill, fg_color, fg_solid)
		}
		paint.fill_rule = .Non_Zero
		if fill.glyph >= 0 {
			if s := font_glyph_shape(f, Glyph_Index(fill.glyph)); s != nil {
				// Shape units are font units with y down; the layer's
				// transform is in font units with y up.
				fill_shape(c, s, paint, {1, 0, 0, -1, 0, 0})
			}
			continue
		}
		// The clip box, filled whole.
		p := &cl.path
		path_reset(p)
		b := info.clip
		path_rect(p, b[0], b[1], b[2] - b[0], b[3] - b[1])
		fill_path(c, p, paint)
	}
	if info.has_clip {
		restore(c)
	} else {
		set_transform(c, t0)
	}
	return true
}

@(private = "file")
colr_color :: proc(cl: ^Colr, index: u16, alpha: f32, fg: Color, fg_solid: bool) -> Color {
	col: Color
	if index == 0xFFFF {
		col = fg
	} else if int(index) < cl.palette_entries && cl.palette != 0 {
		at := cl.palette + int(index) * 4
		d := cl.data
		if at + 4 <= len(d) {
			col = rgba(d[at + 2], d[at + 1], d[at], d[at + 3])
		}
		if fg_solid {
			// The text's alpha (fill-opacity, fades) applies to its colours.
			col.a *= fg.a
		}
	} else {
		col = BLACK
	}
	col.a *= alpha
	return col
}

// The ovg paint of a flattened fill.
@(private = "file")
colr_paint_for :: proc(cl: ^Colr, fill: ^Colr_Fill, fg: Color, fg_solid: bool) -> Paint {
	if fill.kind == .Solid {
		return paint_color(colr_color(cl, fill.palette, fill.alpha, fg, fg_solid))
	}
	clear(&cl.ramp)
	stops := cl.stops[fill.stops[0]:][:fill.stops[1]]
	g := fill.geom
	paint: Paint
	switch fill.kind {
	case .Solid:
	case .Linear, .Radial:
		for s in stops {
			append(&cl.ramp, Gradient_Stop{s.offset, colr_color(cl, s.palette, s.alpha, fg, fg_solid)})
		}
		if fill.kind == .Linear {
			paint = paint_linear_gradient_stops(g[0], g[1], g[2], g[3], cl.ramp[:])
		} else {
			paint = paint_from_flavor(
				Paint_Radial_Gradient {
					center = {g[3], g[4]},
					in_radius = g[2],
					out_radius = g[5],
					colors = gradient_colors_from_stops(cl.ramp[:]),
					focal = {g[0] - g[3], g[1] - g[4]},
				},
			)
		}
		paint.spread = fill.extend
		paint.transform = fill.paint
	case .Sweep:
		// A conic gradient turned so offset 0 sits at the start angle; the
		// colour line covers (end - start) / 360 of the turn.
		start, end := g[2], g[3]
		span := (end - start) / 360
		if len(stops) == 0 || abs(span) < 1e-4 {
			last := stops[len(stops) - 1] if len(stops) > 0 else Colr_Stop{}
			return paint_color(colr_color(cl, last.palette, last.alpha, fg, fg_solid))
		}
		reversed := span < 0
		if reversed {
			start, span = end, -span
		}
		at :: proc(stops: []Colr_Stop, i: int, rev: bool) -> Colr_Stop {
			s := stops[len(stops) - 1 - i] if rev else stops[i]
			if rev {
				s.offset = 1 - s.offset
			}
			return s
		}
		first := colr_color(cl, at(stops, 0, reversed).palette, at(stops, 0, reversed).alpha, fg, fg_solid)
		last_s := at(stops, len(stops) - 1, reversed)
		last := colr_color(cl, last_s.palette, last_s.alpha, fg, fg_solid)
		if fill.extend == .Pad || span >= 1 {
			for i in 0 ..< len(stops) {
				s := at(stops, i, reversed)
				append(&cl.ramp, Gradient_Stop{min(s.offset * span, 1), colr_color(cl, s.palette, s.alpha, fg, fg_solid)})
			}
			if span < 1 {
				// Past the end: the end colour, then the start colour from
				// angle 0 (as Skia pads sweeps).
				wrap := clamp((360 - start) / 360, span, 1)
				append(&cl.ramp, Gradient_Stop{wrap, last}, Gradient_Stop{wrap, first}, Gradient_Stop{1, first})
			}
		} else {
			for k := 0; f32(k) * span < 1 && len(cl.ramp) < COLR_MAX_STOPS; k += 1 {
				flip := fill.extend == .Reflect && k % 2 == 1
				for i in 0 ..< len(stops) {
					s := at(stops, i, reversed != flip)
					append(&cl.ramp, Gradient_Stop{min((f32(k) + s.offset) * span, 1), colr_color(cl, s.palette, s.alpha, fg, fg_solid)})
				}
			}
		}
		paint = paint_from_flavor(Paint_Conic_Gradient{{}, gradient_colors_from_stops(cl.ramp[:])})
		turn := transform_multiply(transform_rotation((start + 90) * math.RAD_PER_DEG), transform_translation(g[0], g[1]))
		paint.transform = transform_multiply(turn, fill.paint)
	}
	return paint
}

// ---- cache --------------------------------------------------------------------------

// The flattened colour glyph, compiled on first use. Caller holds the lock.
@(private)
colr_glyph :: proc(cl: ^Colr, g: Glyph_Index) -> Colr_Glyph {
	if hit, ok := cl.glyphs[g]; ok {
		return hit
	}
	context.allocator = runtime.heap_allocator()
	out := Colr_Glyph {
		first = i32(len(cl.fills)),
	}
	if p := colr_base_paint(cl, g); p != 0 {
		out.colour = true
		cl.glyph_first = len(cl.fills)
		budget_init(&cl.budget)
		colr_walk(cl, p, TRANSFORM_IDENTITY, {glyph = -1, m = TRANSFORM_IDENTITY}, nil, 0)
		out.clip, out.has_clip = colr_clip_box(cl, g)
	} else if first, count, ok := colr_v0_layers(cl, g); ok {
		out.colour = true
		for i in first ..< first + count {
			rec := cl.v0_layers + i * 4
			append(&cl.fills, Colr_Fill{glyph = i32(ft.read_u16(cl.data, rec)), shape = TRANSFORM_IDENTITY, paint = TRANSFORM_IDENTITY, palette = ft.read_u16(cl.data, rec + 2), alpha = 1})
		}
	}
	out.count = i32(len(cl.fills)) - out.first
	cl.glyphs[g] = out
	return out
}

// ---- table reading ------------------------------------------------------------------

@(private = "file")
fword :: #force_inline proc "contextless" (d: []u8, at: int) -> f32 {
	return f32(i16(ft.read_u16(d, at)))
}

@(private = "file")
f2dot14 :: #force_inline proc "contextless" (d: []u8, at: int) -> f32 {
	return f32(i16(ft.read_u16(d, at))) / 16384
}

@(private = "file")
fixed :: #force_inline proc "contextless" (d: []u8, at: int) -> f32 {
	return f32(i32(ft.read_u32(d, at))) / 65536
}

// The v1 root paint of a base glyph (absolute offset), or 0.
@(private = "file")
colr_base_paint :: proc(cl: ^Colr, g: Glyph_Index) -> int {
	if cl.base_list == 0 {
		return 0
	}
	d := cl.data
	lo, hi := 0, int(ft.read_u32(d, cl.base_list)) - 1
	for lo <= hi {
		mid := (lo + hi) / 2
		rec := cl.base_list + 4 + mid * 6
		id := Glyph_Index(ft.read_u16(d, rec))
		switch {
		case id < g:
			lo = mid + 1
		case id > g:
			hi = mid - 1
		case:
			off := int(ft.read_u32(d, rec + 2))
			return cl.base_list + off if off != 0 else 0
		}
	}
	return 0
}

@(private = "file")
colr_v0_layers :: proc(cl: ^Colr, g: Glyph_Index) -> (first, count: int, ok: bool) {
	d := cl.data
	lo, hi := 0, cl.v0_base_count - 1
	for lo <= hi {
		mid := (lo + hi) / 2
		rec := cl.v0_base + mid * 6
		id := Glyph_Index(ft.read_u16(d, rec))
		switch {
		case id < g:
			lo = mid + 1
		case id > g:
			hi = mid - 1
		case:
			return int(ft.read_u16(d, rec + 2)), int(ft.read_u16(d, rec + 4)), true
		}
	}
	return
}

@(private = "file")
colr_clip_box :: proc(cl: ^Colr, g: Glyph_Index) -> (box: [4]f32, ok: bool) {
	if cl.clip_list == 0 {
		return
	}
	d := cl.data
	n := int(ft.read_u32(d, cl.clip_list + 1))
	lo, hi := 0, n - 1
	for lo <= hi {
		mid := (lo + hi) / 2
		rec := cl.clip_list + 5 + mid * 7
		start, end := Glyph_Index(ft.read_u16(d, rec)), Glyph_Index(ft.read_u16(d, rec + 2))
		switch {
		case end < g:
			lo = mid + 1
		case start > g:
			hi = mid - 1
		case:
			at := cl.clip_list + int(ft.read_u24(d, rec + 4))
			return {fword(d, at + 1), fword(d, at + 3), fword(d, at + 5), fword(d, at + 7)}, true
		}
	}
	return
}

// ---- flattening ---------------------------------------------------------------------

// The outline a subgraph's paints fill, and its transform.
@(private = "file")
Colr_Shape :: struct {
	glyph: i32,
	m:     Transform2D,
}

// A subgraph that is a single paint under transforms (no outlines).
@(private = "file")
Colr_Leaf :: struct {
	at: int,
	m:  Transform2D,
}

// The transform of a PaintTransform-family table (formats 12-31), mapping
// its child's space to its own.
@(private = "file")
colr_transform :: proc(d: []u8, p: int, format: u8) -> Transform2D {
	around :: proc(t: Transform2D, cx, cy: f32) -> Transform2D {
		return transform_multiply(transform_multiply(transform_translation(-cx, -cy), t), transform_translation(cx, cy))
	}
	switch format {
	case 12, 13:
		x := p + int(ft.read_u24(d, p + 4))
		return {fixed(d, x), fixed(d, x + 4), fixed(d, x + 8), fixed(d, x + 12), fixed(d, x + 16), fixed(d, x + 20)}
	case 14, 15:
		return transform_translation(fword(d, p + 4), fword(d, p + 6))
	case 16, 17:
		return transform_scaling(f2dot14(d, p + 4), f2dot14(d, p + 6))
	case 18, 19:
		return around(transform_scaling(f2dot14(d, p + 4), f2dot14(d, p + 6)), fword(d, p + 8), fword(d, p + 10))
	case 20, 21:
		s := f2dot14(d, p + 4)
		return transform_scaling(s, s)
	case 22, 23:
		s := f2dot14(d, p + 4)
		return around(transform_scaling(s, s), fword(d, p + 6), fword(d, p + 8))
	case 24, 25:
		return transform_rotation(f2dot14(d, p + 4) * math.PI)
	case 26, 27:
		return around(transform_rotation(f2dot14(d, p + 4) * math.PI), fword(d, p + 6), fword(d, p + 8))
	case 28, 29, 30, 31:
		// Positive angles turn the axes counter-clockwise (y up).
		t := Transform2D{1, math.tan(f2dot14(d, p + 6) * math.PI), -math.tan(f2dot14(d, p + 4) * math.PI), 1, 0, 0}
		if format >= 30 {
			t = around(t, fword(d, p + 8), fword(d, p + 10))
		}
		return t
	}
	return TRANSFORM_IDENTITY
}

// Follows transforms (and PaintColrGlyph) down to a single paint.
@(private = "file")
colr_leaf :: proc(cl: ^Colr, p: int, m: Transform2D, depth: int) -> (Colr_Leaf, bool) {
	if depth > COLR_MAX_DEPTH || p <= 0 || p >= len(cl.data) {
		return {}, false
	}
	d := cl.data
	format := d[p]
	switch format {
	case 2 ..= 9:
		return {p, m}, true
	case 11:
		if q := colr_base_paint(cl, Glyph_Index(ft.read_u16(d, p + 1))); q != 0 {
			return colr_leaf(cl, q, m, depth + 1)
		}
	case 12 ..= 31:
		return colr_leaf(cl, p + int(ft.read_u24(d, p + 1)), transform_multiply(colr_transform(d, p, format), m), depth + 1)
	}
	return {}, false
}

// Flattens the paint at `p` (absolute offset) under transform `m` into
// fills. `over` replaces the subgraph's paints (composite `in` / `atop`).
@(private = "file")
colr_walk :: proc(cl: ^Colr, p: int, m: Transform2D, shape: Colr_Shape, over: ^Colr_Leaf, depth: int) {
	// Composites walk both sides: depth alone leaves 2^depth walks.
	if depth > COLR_MAX_DEPTH || p <= 0 || p >= len(cl.data) || len(cl.fills) - cl.glyph_first > COLR_MAX_FILLS || !budget_take(&cl.budget, .Colr_Paints) {
		return
	}
	d := cl.data
	format := d[p]
	switch format {
	case 1:
		if cl.layer_list == 0 {
			return
		}
		n, first := int(d[p + 1]) if p + 1 < len(d) else 0, int(ft.read_u32(d, p + 2))
		for i in first ..< first + n {
			colr_walk(cl, cl.layer_list + int(ft.read_u32(d, cl.layer_list + 4 + i * 4)), m, shape, over, depth + 1)
		}
	case 2 ..= 9:
		colr_emit(cl, over^ if over != nil else Colr_Leaf{p, m}, shape)
	case 10:
		colr_walk(cl, p + int(ft.read_u24(d, p + 1)), m, {i32(ft.read_u16(d, p + 4)), m}, over, depth + 1)
	case 11:
		if q := colr_base_paint(cl, Glyph_Index(ft.read_u16(d, p + 1))); q != 0 {
			colr_walk(cl, q, m, shape, over, depth + 1)
		}
	case 12 ..= 31:
		colr_walk(cl, p + int(ft.read_u24(d, p + 1)), transform_multiply(colr_transform(d, p, format), m), shape, over, depth + 1)
	case 32:
		src, mode, bd := p + int(ft.read_u24(d, p + 1)), ft.read_u8(d, p + 4), p + int(ft.read_u24(d, p + 5))
		switch mode {
		case 0: // clear
		case 1: // src
			colr_walk(cl, src, m, shape, over, depth + 1)
		case 2: // dest
			colr_walk(cl, bd, m, shape, over, depth + 1)
		case 3: // src over
			colr_walk(cl, bd, m, shape, over, depth + 1)
			colr_walk(cl, src, m, shape, over, depth + 1)
		case 4: // dest over
			colr_walk(cl, src, m, shape, over, depth + 1)
			colr_walk(cl, bd, m, shape, over, depth + 1)
		case 5, 9: // src in, src atop: the backdrop's outlines in the source's paint
			if mode == 9 {
				colr_walk(cl, bd, m, shape, over, depth + 1)
			}
			if leaf, ok := colr_leaf(cl, src, m, depth + 1); ok {
				colr_walk(cl, bd, m, shape, over if over != nil else &leaf, depth + 1)
			} else if mode == 5 {
				colr_walk(cl, src, m, shape, over, depth + 1)
			}
		case 6, 10: // dest in, dest atop
			if mode == 10 {
				colr_walk(cl, src, m, shape, over, depth + 1)
			}
			if leaf, ok := colr_leaf(cl, bd, m, depth + 1); ok {
				colr_walk(cl, src, m, shape, over if over != nil else &leaf, depth + 1)
			} else if mode == 6 {
				colr_walk(cl, bd, m, shape, over, depth + 1)
			}
		case:
			// Out, xor, plus and the blend modes need an isolated group:
			// the backdrop alone.
			colr_walk(cl, bd, m, shape, over, depth + 1)
		}
	}
}

// Appends the fill of one paint (Solid or a gradient) in `shape`.
@(private = "file")
colr_emit :: proc(cl: ^Colr, leaf: Colr_Leaf, shape: Colr_Shape) {
	d := cl.data
	p := leaf.at
	format := d[p]
	fill := Colr_Fill {
		glyph = shape.glyph,
		shape = shape.m,
		paint = transform_multiply(leaf.m, transform_inverse(shape.m)),
		alpha = 1,
	}
	switch format {
	case 2, 3:
		fill.kind = .Solid
		fill.palette = ft.read_u16(d, p + 1)
		fill.alpha = f2dot14(d, p + 3)
		append(&cl.fills, fill)
		return
	case 4, 5:
		fill.kind = .Linear
	case 6, 7:
		fill.kind = .Radial
	case 8, 9:
		fill.kind = .Sweep
	case:
		return
	}
	// Colour line: extend, then stops (VarColorStop rows carry a VarIndex).
	line := p + int(ft.read_u24(d, p + 1))
	fill.extend = Gradient_Spread(min(d[line] if line < len(d) else 0, 2))
	stride := 10 if format & 1 == 1 else 6
	n := min(int(ft.read_u16(d, line + 1)), COLR_MAX_STOPS)
	first := len(cl.stops)
	lo, hi := f32(1e9), f32(-1e9)
	for i in 0 ..< n {
		s := line + 3 + i * stride
		st := Colr_Stop{f2dot14(d, s), ft.read_u16(d, s + 2), f2dot14(d, s + 4)}
		// Keep stops sorted by offset (insertion; lines are short).
		j := len(cl.stops)
		append(&cl.stops, st)
		for j > first && cl.stops[j - 1].offset > st.offset {
			cl.stops[j] = cl.stops[j - 1]
			j -= 1
		}
		cl.stops[j] = st
		lo, hi = min(lo, st.offset), max(hi, st.offset)
	}
	if n == 0 {
		return
	}
	if fill.kind == .Sweep {
		// Offsets are angles in the start-end range, used as they are.
		lo, hi = 0, 1
	} else if hi - lo < 1e-6 {
		// One offset: the last colour.
		last := cl.stops[len(cl.stops) - 1]
		resize(&cl.stops, first)
		fill.kind, fill.palette, fill.alpha = .Solid, last.palette, last.alpha
		append(&cl.fills, fill)
		return
	}
	for &s in cl.stops[first:] {
		s.offset = (s.offset - lo) / (hi - lo)
	}
	fill.stops = {i32(first), i32(n)}
	switch fill.kind {
	case .Solid:
	case .Linear:
		// The gradient runs from p0 along p0p1 projected onto the normal of
		// p0p2; its offsets are rescaled to the stops' range.
		p0 := Vec2{fword(d, p + 4), fword(d, p + 6)}
		p1 := Vec2{fword(d, p + 8), fword(d, p + 10)}
		p2 := Vec2{fword(d, p + 12), fword(d, p + 14)}
		perp := Vec2{p2.y - p0.y, -(p2.x - p0.x)}
		p3 := p1
		if l2 := perp.x * perp.x + perp.y * perp.y; l2 > 0 {
			p3 = p0 + perp * (((p1.x - p0.x) * perp.x + (p1.y - p0.y) * perp.y) / l2)
		}
		a, b := p0 + (p3 - p0) * lo, p0 + (p3 - p0) * hi
		fill.geom = {a.x, a.y, b.x, b.y, 0, 0}
	case .Radial:
		c0 := Vec2{fword(d, p + 4), fword(d, p + 6)}
		r0 := f32(ft.read_u16(d, p + 8))
		c1 := Vec2{fword(d, p + 10), fword(d, p + 12)}
		r1 := f32(ft.read_u16(d, p + 14))
		a, b := c0 + (c1 - c0) * lo, c0 + (c1 - c0) * hi
		ra, rb := max(r0 + (r1 - r0) * lo, 0), max(r0 + (r1 - r0) * hi, 0)
		if ra > rb {
			// ovg's gradient grows outwards: swap the circles and reverse
			// the stops.
			a, b, ra, rb = b, a, rb, ra
			stops := cl.stops[first:]
			for i, j := 0, len(stops) - 1; i < j; i, j = i + 1, j - 1 {
				stops[i], stops[j] = stops[j], stops[i]
			}
			for &s in stops {
				s.offset = 1 - s.offset
			}
		}
		fill.geom = {a.x, a.y, ra, b.x, b.y, rb}
	case .Sweep:
		// Angles carry a bias of 180 degrees (so +360 fits in F2DOT14).
		fill.geom = {fword(d, p + 4), fword(d, p + 6), f2dot14(d, p + 8) * 180 + 180, f2dot14(d, p + 10) * 180 + 180, 0, 0}
	}
	append(&cl.fills, fill)
}
