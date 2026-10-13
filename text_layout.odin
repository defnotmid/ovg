package ovg

import "core:unicode"

// Text layout over a Font_Collection: styled pieces (SVG text + tspans),
// lines, baselines, alignment and per-glyph font fallback. The result is a
// list of positioned glyphs grouped into runs of one font, size and paint
// tag, ready for `fill_glyph_outlines` / `stroke_glyph_outlines`. Each line
// is split into segments of one font, size, script and direction, shaped
// with kb_text_shape (text_shape.odin) and placed in bidi visual order.

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
}

// Consecutive glyphs of one font, size and paint.
Text_Run :: struct {
	font:         ^Font,
	em:           f32, // font units to pixels
	paint:        u32,
	first, count: int, // into Text_Layout.glyphs
}

Text_Line :: struct {
	first, count: int, // glyphs
	width:        f32,
}

Text_Layout :: struct {
	glyphs:   [dynamic]Positioned_Glyph,
	// Per glyph: the index of its first codepoint in the text (all pieces'
	// codepoints in order, newlines included).
	clusters: [dynamic]i32,
	runs:     [dynamic]Text_Run,
	lines:    [dynamic]Text_Line,
	// Families not in the collection (drawn with the fallback face).
	missing:  [dynamic]string,
	// Extent of the laid-out text (ascent to descent of each line).
	min, max: Vec2,
}

text_layout_destroy :: proc(l: ^Text_Layout) {
	delete(l.glyphs)
	delete(l.clusters)
	delete(l.runs)
	delete(l.lines)
	delete(l.missing)
	l^ = {}
}

// Lays out `pieces` into `l` (cleared). Glyph positions are absolute.
text_layout :: proc(fonts: ^Font_Collection, pieces: []Text_Piece, opts: Text_Options, l: ^Text_Layout) {
	clear(&l.glyphs)
	clear(&l.clusters)
	clear(&l.runs)
	clear(&l.lines)
	clear(&l.missing)
	l.min, l.max = {}, {}
	if len(pieces) == 0 {
		return
	}

	s := shaper_acquire(fonts)
	defer shaper_release(fonts, s)
	clear(&s.piece_start)
	clear(&s.piece_font)
	clear(&s.piece_size)
	clear(&s.runes)
	clear(&s.piece)
	clear(&s.font)

	// Codepoints with their piece and font: the piece's face, else the first
	// face covering them (per-glyph fallback).
	for piece, pi in pieces {
		font, size := resolve_face(fonts, l, piece.style)
		append(&s.piece_start, i32(len(s.runes)))
		append(&s.piece_font, font)
		append(&s.piece_size, size)
		for r in piece.text {
			f := font
			if r != '\n' && r != ' ' && r != '\t' && font_glyph_index_drawable(font, r) == 0 {
				f, _ = font_collection_glyph(fonts, r, font)
			}
			append(&s.runes, r)
			append(&s.piece, i32(pi))
			append(&s.font, f)
		}
	}
	n := i32(len(s.runes))
	emoji_fallback(fonts, s.runes[:], s.font[:])
	mark_fallback(s)
	resize(&s.script, int(n))
	resize(&s.level, int(n))
	resize(&s.bidi, int(n))

	first_font, first_size := s.piece_font[0], s.piece_size[0]
	first_em := font_scale_for_em(first_font, first_size)
	line_height := (opts.line_height if opts.line_height > 0 else 1.2) * first_size

	pen: Vec2
	line_start := 0
	// Pieces whose dx / dy has moved the pen.
	next_piece := 0
	for a: i32 = 0; a <= n; {
		b := a
		for b < n && s.runes[b] != '\n' {
			b += 1
		}
		// Letter spacing follows every glyph but the last of a line (as usvg
		// lays it out), so it doesn't widen the line or shift alignment.
		trailing: f32
		layout_line(fonts, s, pieces, l, a, b, &pen, &next_piece, &trailing)
		// Offsets of pieces starting at the line end (or with the newline).
		for next_piece < len(pieces) && s.piece_start[next_piece] <= b {
			pen += {pieces[next_piece].dx, pieces[next_piece].dy}
			next_piece += 1
		}
		layout_end_line(l, &line_start, pen.x - trailing)
		if b >= n {
			break
		}
		pen.x = 0
		pen.y += line_height
		a = b + 1
	}

	shift := baseline_shift(first_font, first_em, first_size, opts.baseline)
	asc, desc := font_extent(first_font, first_em)
	l.min = {1e9, 1e9}
	l.max = {-1e9, -1e9}
	for line in l.lines {
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

// Keeps emoji sequences in one face so they shape into one glyph: a rune
// asking for emoji presentation (U+FE0F after it, or after a joiner in a
// colour face) takes a colour face, and joiners, variation selectors,
// skin-tone modifiers, keycaps and tags stay in the face of the rune before.
@(private = "file")
emoji_fallback :: proc(fonts: ^Font_Collection, runes: []rune, font: []^Font) {
	continues :: proc(r: rune) -> bool {
		return r == 0x200D || r == 0xFE0E || r == 0xFE0F || r == 0x20E3 || (r >= 0x1F3FB && r <= 0x1F3FF) || (r >= 0xE0020 && r <= 0xE007F)
	}
	for i in 0 ..< len(runes) {
		r := runes[i]
		if i > 0 && runes[i - 1] != '\n' && continues(r) {
			font[i] = font[i - 1]
			continue
		}
		wants := i + 1 < len(runes) && runes[i + 1] == 0xFE0F
		wants ||= i > 0 && runes[i - 1] == 0x200D && font[i - 1].colr != nil
		if wants && font[i].colr == nil {
			if f, g := font_collection_emoji_glyph(fonts, r); g != 0 {
				font[i] = f
			}
		}
	}
}

// Invisible format characters (Unicode Default_Ignorable_Code_Point, the
// ones met in text): they steer shaping and draw nothing.
rune_is_default_ignorable :: proc "contextless" (r: rune) -> bool {
	switch r {
	case 0x00AD, 0x034F, 0x180B ..= 0x180F, 0x200B ..= 0x200F, 0x202A ..= 0x202E, 0x2060 ..= 0x2064, 0xFE00 ..= 0xFE0F, 0xFEFF, 0xE0000 ..= 0xE0FFF:
		return true
	}
	return false
}

// Width of the widest line.
text_layout_width :: proc(l: ^Text_Layout) -> f32 {
	w: f32
	for line in l.lines {
		w = max(w, line.width)
	}
	return w
}

@(private = "file")
resolve_face :: proc(fonts: ^Font_Collection, l: ^Text_Layout, st: Text_Style) -> (font: ^Font, size: f32) {
	found: bool
	font, found = font_collection_find(fonts, st.family, st.weight, st.italic)
	if !found {
		append(&l.missing, st.family)
	}
	size = st.size if st.size > 0 else 16
	return font, size
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
		f, size, script, level := s.font[i], s.piece_size[s.piece[i]], s.script[i], s.level[i]
		j := i + 1
		for j < b && s.font[j] == f && s.piece_size[s.piece[j]] == size && s.script[j] == script && s.level[j] == level {
			j += 1
		}
		append(&s.segs, Shape_Segment{first = i, count = j - i, font = f, em = font_scale_for_em(f, size), script = script, level = level})
		i = j
	}
	for &seg in s.segs {
		shaper_shape(fonts, s, &seg, pieces)
	}
	shaper_reorder(s)
	for si in s.order {
		seg := &s.segs[si]
		em := seg.em
		for g in s.glyphs[seg.glyph_first:][:seg.glyph_count] {
			if rune_is_default_ignorable(s.runes[g.cluster]) {
				// Joiners and variation selectors left over by shaping.
				continue
			}
			for next_piece^ < len(pieces) && s.piece_start[next_piece^] <= g.cluster {
				pen^ += {pieces[next_piece^].dx, pieces[next_piece^].dy}
				next_piece^ += 1
			}
			style := &pieces[s.piece[g.cluster]].style
			layout_add_glyph(l, seg.font, em, style.paint, {g.id, pen.x + f32(g.offset.x) * em, pen.y - f32(g.offset.y) * em}, g.cluster)
			pen.x += f32(g.advance) * em
			if !g.mark {
				pen.x += style.letter_spacing
				trailing^ = style.letter_spacing
			}
		}
	}
}

@(private = "file")
layout_add_glyph :: proc(l: ^Text_Layout, font: ^Font, em: f32, paint: u32, g: Positioned_Glyph, cluster: i32) {
	n := len(l.runs)
	if n == 0 || l.runs[n - 1].font != font || l.runs[n - 1].em != em || l.runs[n - 1].paint != paint {
		append(&l.runs, Text_Run{font, em, paint, len(l.glyphs), 0})
	}
	append(&l.glyphs, g)
	append(&l.clusters, cluster)
	l.runs[len(l.runs) - 1].count += 1
}

@(private = "file")
layout_end_line :: proc(l: ^Text_Layout, line_start: ^int, width: f32) {
	append(&l.lines, Text_Line{line_start^, len(l.glyphs) - line_start^, width})
	line_start^ = len(l.glyphs)
}

// Ascent and descent of a face in pixels, both positive.
font_extent :: proc(font: ^Font, em: f32) -> (ascent, descent: f32) {
	vm := font_v_metrics(font)
	return f32(vm.ascent) * em, -f32(vm.descent) * em
}

// How far below `y` the first baseline sits for an SVG dominant-baseline.
baseline_shift :: proc(font: ^Font, em, size: f32, b: Text_Baseline) -> f32 {
	asc, desc := font_extent(font, em)
	switch b {
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


// A combining mark that fell back to another face than its base's takes
// the cluster (base and its marks) to the first such face that has them
// all: marks attach to their base only when shaped with it. Runes that kept
// their neighbour's face cost one comparison.
@(private = "file")
mark_fallback :: proc(s: ^Text_Shaper) {
	is_mark :: proc(r: rune) -> bool {
		return unicode.is_nonspacing_mark(r) || unicode.is_enclosing_mark(r) || unicode.is_spacing_mark(r)
	}
	n := len(s.runes)
	for i := 1; i < n; i += 1 {
		if s.font[i] == s.font[i - 1] || !is_mark(s.runes[i]) {
			continue
		}
		// The cluster: back to its base, on to its last mark (one piece).
		base := i - 1
		for base > 0 && is_mark(s.runes[base]) && s.piece[base - 1] == s.piece[i] {
			base -= 1
		}
		end := i + 1
		for end < n && is_mark(s.runes[end]) && s.piece[end] == s.piece[i] {
			end += 1
		}
		if s.piece[base] != s.piece[i] {
			i = end - 1
			continue
		}
		for k in base ..< end {
			f := s.font[k]
			has_all := true
			for j in base ..< end {
				if font_glyph_index_drawable(f, s.runes[j]) == 0 {
					has_all = false
					break
				}
			}
			if has_all {
				for j in base ..< end {
					s.font[j] = f
				}
				break
			}
		}
		i = end - 1
	}
}
