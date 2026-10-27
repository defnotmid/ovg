package ovg

import fc "deps:oglyph/collection"
import ft "deps:oglyph/font"
import sh "deps:oglyph/shape"

// Text layout over a Font_Collection: styled pieces (SVG text + tspans),
// lines, baselines, alignment and per-glyph font fallback. The result is a
// list of positioned glyphs grouped into runs of one font, size and paint
// tag, ready for `fill_glyph_outlines` / `stroke_glyph_outlines`. Each line
// is split into segments of one font, size, script and direction, shaped
// with ovg/shape (text_shape.odin) and placed in bidi visual order.

Text_Align :: enum u8 {
	Left,
	Center,
	Right,
}

// Where the layout's `y` sits on the first line (SVG dominant-baseline).
Text_Baseline :: enum u8 {
	Alphabetic,
	// Halfway up the x-height (SVG `middle`).
	Middle,
	// The middle of the em box (SVG `central`).
	Central,
	Hanging,
	// The top / bottom of the em box (`text-before-edge`, `text-after-edge`).
	Top,
	Bottom,
	// The top of the first line's box, the lines stacking as CSS line
	// boxes (as Inkscape lays out SVG 2 text): each as high as its tallest
	// inline box, the first piece's face and size and each run's, every box
	// a line height high with its face's em box (font_em_box) centred in
	// it, so a baseline sits half the leading and the ascent below its top.
	Line_Top,
}

Text_Style :: struct {
	family:         string,
	// Em size in pixels (CSS font-size); 0 means 16.
	size:           f32,
	// 0 means 400.
	weight:         int,
	italic:         bool,
	letter_spacing: f32,
	// The caller's paint for these glyphs, carried into the runs.
	paint:          u32,
	// OpenType features turned on or off over the shaper's defaults, the
	// last of a tag winning (CSS font-feature-settings). Letter spacing
	// turns liga, clig and dlig off unless these set them.
	features:       []Font_Feature,
	// The variable font instance to draw (CSS font-variation-settings):
	// the family's face whose instance these settings pick (added with
	// them, font_collection_add), else the face weight and style pick.
	variations:     []Font_Variation,
}

// A variable font axis's four-character tag ("wght", "wdth", "opsz") and
// value in the axis's own units.
Font_Variation :: ft.Variation

// A feature's four-character tag ("smcp", "ss01"; shorter tags are padded
// with spaces) and value: 0 off, 1 on, n > 1 the nth alternate (salt, cv01).
Font_Feature :: struct {
	tag:   string,
	value: u32,
}

// Text in one style; "\n" starts a new line. `dx`/`dy` move the pen before
// the piece (SVG tspan dx / dy).
Text_Piece :: struct {
	text:   string,
	style:  Text_Style,
	dx, dy: f32,
}

Text_Options :: struct {
	x, y:        f32,
	align:       Text_Align,
	baseline:    Text_Baseline,
	// Line advance in ems of the first piece's size; 0 means 1.2.
	line_height: f32,
	// Lines wider than this break at their line break opportunities
	// (oglyph's line_breaks, UAX #14) into lines that fit, where they can:
	// a word wider than it has a line of its own. Spaces a line breaks
	// after hang past its end, outside its width. 0: lines end only at
	// "\n".
	width:       f32,
}

// Consecutive glyphs of one face, size and paint. The face is named by its
// id in the collection laid out with (text_layout_font), so the layout
// stays valid as faces are added to it.
Text_Run :: struct {
	face:         Face_Id,
	em:           f32, // font units to pixels
	paint:        u32,
	first, count: int, // into Text_Layout.glyphs
}

Text_Line :: struct {
	first, count:         int, // glyphs
	width:                f32,
	// The codepoints it holds, in `clusters`' indices: up to the next
	// line's first (its newline, or the spaces it breaks after, are its).
	text_start, text_end: i32,
	// Its baseline (before the pieces' dy), and how far its box reaches
	// above and below it (Line_Top: as stacked; else the first piece's
	// face's ascent and descent).
	y:                    f32,
	above, below:         f32,
}

Text_Layout :: struct {
	// The collection laid out with (borrowed), whose faces the runs name.
	fonts:    ^Font_Collection,
	glyphs:   [dynamic]Positioned_Glyph,
	// Per glyph: the index of its first codepoint in the text (all pieces'
	// codepoints in order, newlines included).
	clusters: [dynamic]i32,
	// Per glyph: how far the pen steps past it, in pixels (its advance,
	// plus letter spacing after a base). A line's pen starts at its left
	// end and moves by the advances, and by the dx of the pieces it
	// meets, so a glyph ends at its pen plus its advance.
	advances: [dynamic]f32,
	runs:     [dynamic]Text_Run,
	lines:    [dynamic]Text_Line,
	// Families not in the collection (drawn with the fallback face).
	missing:  [dynamic]string,
	// Extent of the laid-out text (ascent to descent of each line).
	min, max: Vec2,
	// Per glyph, once placed on a path (text_layout_on_path): its direction
	// (cos, sin), {0, 0} when off the path. Empty for straight text.
	turns:    [dynamic]Vec2,
}

// A layout allocating from `allocator`.
text_layout_init :: proc(l: ^Text_Layout, allocator := context.allocator) {
	l^ = {}
	l.glyphs.allocator, l.clusters.allocator, l.advances.allocator = allocator, allocator, allocator
	l.runs.allocator = allocator
	l.lines.allocator, l.missing.allocator, l.turns.allocator = allocator, allocator, allocator
}

text_layout_destroy :: proc(l: ^Text_Layout) {
	delete(l.glyphs)
	delete(l.clusters)
	delete(l.advances)
	delete(l.runs)
	delete(l.lines)
	delete(l.missing)
	delete(l.turns)
	l^ = {}
}

// Lays out `pieces` into `l` (cleared). Glyph positions are absolute.
text_layout :: proc(fonts: ^Font_Collection, pieces: []Text_Piece, opts: Text_Options, l: ^Text_Layout) {
	l.fonts = fonts
	clear(&l.glyphs)
	clear(&l.clusters)
	clear(&l.advances)
	clear(&l.runs)
	clear(&l.lines)
	clear(&l.missing)
	clear(&l.turns)
	l.min, l.max = {}, {}
	if len(pieces) == 0 {
		return
	}

	s := shaper_acquire(fonts)
	defer shaper_release(fonts, s)
	clear(&s.features)

	// Codepoints with their piece and face: the piece's face, else the one
	// fallback picks (oglyph's collection_fallback). Sized for one per byte,
	// filled, then cut to the count.
	bytes := 0
	for piece in pieces {
		bytes += len(piece.text)
	}
	scratch_size(&s.pieces, len(pieces))
	scratch_size(&s.chars, bytes)
	n: i32
	first: Face_Id
	for piece, pi in pieces {
		face, size := resolve_face(fonts, l, piece.style)
		if pi == 0 {
			first = face
		}
		s.pieces[pi] = {n, size, shaper_add_piece_features(s, piece.style)}
		for r in piece.text {
			// The other columns are written before they're read.
			s.chars.char[n], s.chars.piece[n], s.chars.face[n] = r, i32(pi), face
			n += 1
		}
	}
	scratch_size(&s.chars, int(n))
	fc.collection_fallback(&fonts.collection, s.chars.char[:n], s.chars.piece[:n], s.chars.face[:n])

	first_font, first_size := font_collection_font(fonts, first), s.pieces[0].size
	first_em := font_scale_for_em(first_font, first_size)
	line_height := (opts.line_height if opts.line_height > 0 else 1.2) * first_size

	pen: Vec2
	line_start := 0
	// Pieces whose dx / dy has moved the pen.
	next_piece := 0
	for a: i32 = 0; a <= n; {
		b := a
		for b < n && s.chars[b].char != '\n' {
			b += 1
		}
		next := b + 1 if b < n else n
		layout_paragraph(fonts, s, pieces, l, a, b, next, opts.width, line_height, &pen, &next_piece, &line_start)
		if b >= n {
			break
		}
		pen.x = 0
		pen.y += line_height
		a = next
	}

	shift := baseline_shift(first_font, first_em, first_size, opts.baseline, line_height)
	asc, desc := font_extent(first_font, first_em)
	if opts.baseline == .Line_Top {
		stack_line_boxes(l, first_font, first_size, line_height)
		shift = 0
	} else {
		for &line in l.lines {
			line.above, line.below = asc, desc
		}
	}
	l.min = {1e9, 1e9}
	l.max = {-1e9, -1e9}
	for &line in l.lines {
		line.y += opts.y + shift
		dx: f32
		switch opts.align {
		case .Left:
		case .Center:
			dx = -line.width * 0.5
		case .Right:
			dx = -line.width
		}
		for &g in l.glyphs[line.first:][:line.count] {
			g.x += opts.x + dx
			g.y += opts.y + shift
		}
		if line.count > 0 {
			y := l.glyphs[line.first].y
			l.min = {min(l.min.x, opts.x + dx), min(l.min.y, y - asc)}
			l.max = {max(l.max.x, opts.x + dx + line.width), max(l.max.y, y + desc)}
		}
	}
	if len(l.glyphs) == 0 {
		l.min, l.max = {opts.x, opts.y}, {opts.x, opts.y}
	}
}

// Invisible format characters (Unicode Default_Ignorable_Code_Point, the
// ones met in text): they steer shaping and draw nothing.
rune_is_default_ignorable :: proc "contextless" (r: rune) -> bool {
	if r < 0x00AD {
		return false
	}
	switch r {
	case 0x00AD, 0x034F, 0x180B ..= 0x180F, 0x200B ..= 0x200F, 0x202A ..= 0x202E, 0x2060 ..= 0x2064, 0xFE00 ..= 0xFE0F, 0xFEFF, 0xE0000 ..= 0xE0FFF:
		return true
	}
	return false
}

// The font of a run's face, to draw it with (for immediate use, as
// font_collection_font's); nil once the face is removed.
text_layout_font :: proc(l: ^Text_Layout, run: Text_Run) -> ^Font {
	return font_collection_font(l.fonts, run.face)
}

// Width of the widest line.
text_layout_width :: proc(l: ^Text_Layout) -> f32 {
	w: f32
	for line in l.lines {
		w = max(w, line.width)
	}
	return w
}

// Appends the outlines of the laid-out glyphs to `out`, where drawing the
// layout puts them (positions, alignment, baseline, letter spacing and
// fallback faces as laid out). Fill them with the non-zero rule. A colour
// glyph (COLR emoji) adds its base glyph's plain outline, which is often
// empty: emoji mostly add nothing. Glyphs placed on a path turn with it.
text_layout_path :: proc(l: ^Text_Layout, out: ^Path) {
	for run in l.runs {
		font := text_layout_font(l, run)
		for g, k in l.glyphs[run.first:][:run.count] {
			if len(l.turns) == 0 {
				font_glyph_path(font, g.glyph, g.x, g.y, run.em, out)
			} else if turn := l.turns[run.first + k] * run.em; turn != {} {
				font_glyph_path_transformed(font, g.glyph, {turn.x, turn.y, turn.y, -turn.x, g.x, g.y}, out)
			}
		}
	}
}

@(private = "file")
resolve_face :: proc(fonts: ^Font_Collection, l: ^Text_Layout, st: Text_Style) -> (face: Face_Id, size: f32) {
	found: bool
	face, found = font_collection_find(fonts, st.family, st.weight, st.italic, st.variations)
	if !found {
		append(&l.missing, st.family)
	}
	size = st.size if st.size > 0 else 16
	return face, size
}

// Lays out the paragraph [a, b) (the text up to a newline) from the pen:
// one line, or with a `width` the lines it breaks into, the pen at the start
// of each next one. `next` is where the next paragraph starts: the last
// line holds the codepoints up to it.
@(private = "file")
layout_paragraph :: proc(fonts: ^Font_Collection, s: ^Text_Shaper, pieces: []Text_Piece, l: ^Text_Layout, a, b, next: i32, width, line_height: f32, pen: ^Vec2, next_piece, line_start: ^int) {
	glyphs, runs := len(l.glyphs), len(l.runs)
	run_count := l.runs[runs - 1].count if runs > 0 else 0
	start_pen, start_piece := pen^, next_piece^
	// Letter spacing follows every glyph but the last of a line (as usvg
	// lays it out), so it doesn't widen the line or shift alignment.
	trailing: f32
	layout_line(fonts, s, pieces, l, a, b, pen, next_piece, &trailing)
	if width <= 0 || pen.x - trailing <= width {
		layout_end_paragraph(s, pieces, b, pen, next_piece)
		layout_end_line(l, line_start, pen.x - trailing, a, next, start_pen.y)
		return
	}
	// Too wide: each codepoint's share of the line from the glyphs just
	// placed (a piece's dx at its first), where it may break; then the
	// glyphs go and the lines are laid out one by one.
	for k in a ..< b {
		s.chars[k].advance = 0
	}
	for g in glyphs ..< len(l.glyphs) {
		s.chars[l.clusters[g]].advance += l.advances[g]
	}
	for p := start_piece; p < len(pieces) && s.pieces[p].start < b; p += 1 {
		s.chars[max(s.pieces[p].start, a)].advance += pieces[p].dx
	}
	sh.line_breaks(s.chars.char[a:b], s.chars.brk[a:b])
	scratch_size(&l.glyphs, glyphs)
	scratch_size(&l.clusters, glyphs)
	scratch_size(&l.advances, glyphs)
	resize(&l.runs, runs)
	if runs > 0 {
		l.runs[runs - 1].count = run_count
	}
	pen^, next_piece^ = start_pen, start_piece
	for start := a; start < b; {
		end, hang := line_end(s, start, b, width)
		y := pen.y
		first := len(l.glyphs)
		trailing = 0
		layout_line(fonts, s, pieces, l, start, end, pen, next_piece, &trailing)
		w := pen.x - trailing
		if hang < end {
			// The spaces it ends with hang, their letter spacing with them;
			// the last word's goes instead.
			for g in first ..< len(l.glyphs) {
				if l.clusters[g] >= hang {
					w -= l.advances[g]
				}
			}
			if hang > start {
				w += trailing - pieces[s.chars[hang - 1].piece].style.letter_spacing
			}
		}
		if end < b {
			layout_end_line(l, line_start, w, start, end, y)
			pen.x = 0
			pen.y += line_height
		} else {
			layout_end_paragraph(s, pieces, b, pen, next_piece)
			layout_end_line(l, line_start, w, start, next, y)
		}
		start = end
	}
}

// Where the line starting at codepoint `start` ends: at its last break
// opportunity where it fits `width`, at a mandatory break, or where its
// first word ends when not even that fits. `hang`: where the spaces it
// ends with start (`end` for none), which don't count toward the width.
@(private = "file")
line_end :: proc(s: ^Text_Shaper, start, b: i32, width: f32) -> (end, hang: i32) {
	// Spaces that hang past the end of a line (CSS white-space: normal):
	// Zs but the no-break ones, and tabs.
	hangs :: proc "contextless" (r: rune) -> bool {
		switch r {
		case ' ', '\t', 0x1680, 0x2000 ..= 0x2006, 0x2008 ..= 0x200A, 0x205F, 0x3000:
			return true
		}
		return false
	}
	w, spaces: f32
	fit, fit_hang: i32 = -1, -1
	run := start
	for k in start ..< b {
		w += s.chars[k].advance
		if hangs(s.chars[k].char) {
			spaces += s.chars[k].advance
		} else {
			spaces = 0
			run = k + 1
		}
		brk := s.chars[k].brk
		if brk == .None {
			continue
		}
		if w - spaces > width {
			if fit >= 0 {
				return fit, fit_hang
			}
			return k + 1, run
		}
		fit, fit_hang = k + 1, run
		if brk == .Mandatory {
			break
		}
	}
	return fit, fit_hang
}

// Offsets of pieces starting at the paragraph's end (or with its newline).
@(private = "file")
layout_end_paragraph :: proc(s: ^Text_Shaper, pieces: []Text_Piece, b: i32, pen: ^Vec2, next_piece: ^int) {
	for next_piece^ < len(pieces) && s.pieces[next_piece^].start <= b {
		pen^ += {pieces[next_piece^].dx, pieces[next_piece^].dy}
		next_piece^ += 1
	}
}

// Shapes the codepoints [a, b) of one line and places their glyphs from the
// pen: segments of one font, size, script and direction, shaped, then laid
// out in visual order.
@(private = "file")
layout_line :: proc(fonts: ^Font_Collection, s: ^Text_Shaper, pieces: []Text_Piece, l: ^Text_Layout, a, b: i32, pen: ^Vec2, next_piece: ^int, trailing: ^f32) {
	clear(&s.segs)
	clear(&s.glyphs)
	if a >= b {
		return
	}
	shaper_itemize(s, a, b)
	for i := a; i < b; {
		c := s.chars[i]
		size := s.pieces[c.piece].size
		j := i + 1
		for j < b && s.chars[j].face == c.face && s.pieces[s.chars[j].piece].size == size && s.chars[j].script == c.script && s.chars[j].level == c.level {
			j += 1
		}
		ff := font_collection_face(fonts, c.face)
		append(&s.segs, Shape_Segment{first = i, count = j - i, face = c.face, font = ff, em = ft.scale_for_em(&ff.face, size), script = c.script, level = c.level})
		i = j
	}
	for &seg in s.segs {
		shaper_shape(fonts, s, &seg)
	}
	shaper_reorder(s)
	// The line's glyphs, at most one per shaped glyph: placed, then cut to
	// those drawn.
	k := len(l.glyphs)
	scratch_size(&l.glyphs, k + len(s.glyphs))
	scratch_size(&l.clusters, k + len(s.glyphs))
	scratch_size(&l.advances, k + len(s.glyphs))
	for si in s.order {
		seg := &s.segs[si]
		em := seg.em
		for g in s.glyphs[seg.glyph_first:][:seg.glyph_count] {
			if rune_is_default_ignorable(s.chars[g.cluster].char) {
				// Joiners and variation selectors left over by shaping.
				continue
			}
			for next_piece^ < len(pieces) && s.pieces[next_piece^].start <= g.cluster {
				pen^ += {pieces[next_piece^].dx, pieces[next_piece^].dy}
				next_piece^ += 1
			}
			style := &pieces[s.chars[g.cluster].piece].style
			if n := len(l.runs); n == 0 || l.runs[n - 1].face != seg.face || l.runs[n - 1].em != em || l.runs[n - 1].paint != style.paint {
				append(&l.runs, Text_Run{seg.face, em, style.paint, k, 0})
			}
			l.runs[len(l.runs) - 1].count += 1
			l.glyphs[k] = {Glyph_Index(g.id), pen.x + f32(g.offset.x) * em, pen.y - f32(g.offset.y) * em}
			l.clusters[k] = g.cluster
			step := f32(g.advance) * em
			pen.x += step
			if !g.mark {
				pen.x += style.letter_spacing
				step += style.letter_spacing
				trailing^ = style.letter_spacing
			}
			l.advances[k] = step
			k += 1
		}
	}
	scratch_size(&l.glyphs, k)
	scratch_size(&l.clusters, k)
	scratch_size(&l.advances, k)
}

// Places the lines as CSS line boxes from the first one's top (Line_Top):
// each as high as its tallest inline box, the strut's (the first piece's
// face and size) and each run's.
@(private = "file")
stack_line_boxes :: proc(l: ^Text_Layout, strut: ^Font, strut_size, line_height: f32) {
	inline_box :: proc(f: ^Font, size, line_height: f32) -> (above, below: f32) {
		a, d := font_em_box(f)
		half := (line_height - size) * 0.5
		return half + a * size, half + d * size
	}
	strut_above, strut_below := inline_box(strut, strut_size, line_height)
	baseline, below: f32
	r := 0
	for &line, i in l.lines {
		above_line, below_line := strut_above, strut_below
		end := line.first + line.count
		for r < len(l.runs) && l.runs[r].first + l.runs[r].count <= line.first {
			r += 1
		}
		for k := r; k < len(l.runs) && l.runs[k].first < end; k += 1 {
			f := font_collection_font(l.fonts, l.runs[k].face)
			a, b := inline_box(f, l.runs[k].em * f32(f.face.units_per_em), line_height)
			above_line, below_line = max(above_line, a), max(below_line, b)
		}
		baseline = above_line if i == 0 else baseline + below + above_line
		below = below_line
		for &g in l.glyphs[line.first:][:line.count] {
			g.y += baseline - line.y
		}
		line.y, line.above, line.below = baseline, above_line, below_line
	}
}

@(private = "file")
layout_end_line :: proc(l: ^Text_Layout, line_start: ^int, width: f32, text_start, text_end: i32, y: f32) {
	append(&l.lines, Text_Line{line_start^, len(l.glyphs) - line_start^, width, text_start, text_end, y, 0, 0})
	line_start^ = len(l.glyphs)
}

// Ascent and descent of a face in pixels, both positive.
font_extent :: proc(font: ^Font, em: f32) -> (ascent, descent: f32) {
	vm := font_v_metrics(font)
	return f32(vm.ascent) * em, -f32(vm.descent) * em
}

// How far below `y` the first baseline sits for an SVG dominant-baseline
// (Line_Top: in a line `line_height` pixels high).
baseline_shift :: proc(font: ^Font, em, size: f32, b: Text_Baseline, line_height: f32 = 0) -> f32 {
	asc, desc := font_extent(font, em)
	switch b {
	case .Line_Top:
		a, _ := font_em_box(font)
		return (line_height - size) * 0.5 + a * size
	case .Alphabetic:
		return 0
	case .Top:
		return asc
	case .Bottom:
		return -desc
	case .Central:
		return (asc - desc) * 0.5
	case .Hanging:
		return asc * 0.8
	case .Middle:
		return font_x_height(font, em, size) * 0.5
	}
	return 0
}

// The height of a lowercase x in pixels (from its outline), else half the
// em size.
font_x_height :: proc(font: ^Font, em, size: f32) -> f32 {
	x0, y0, x1, y1: i32
	g := font_glyph_index(font, 'x')
	if g != 0 && font_glyph_box(font, g, &x0, &y0, &x1, &y1) && y1 > 0 {
		return f32(y1) * em
	}
	return size * 0.5
}
