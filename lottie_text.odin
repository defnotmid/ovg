package ovg

import "core:math"
import "core:unicode"
import "core:unicode/utf8"

// Lottie text layers (lottie.odin parses them): the document keyframe at
// the frame is laid out with the renderer's font collection (shaping,
// fallback, colour emoji), wrapped greedily at spaces for box text, then
// drawn per letter when text animators move, scale, turn or recolour
// letters. Letters are codepoints (an emoji sequence is one), as
// lottie-web's; positions come from the shaped layout, so spacing follows
// the font's advances and kerning rather than a browser's.

// Per-draw text scratch of a `Lottie_Renderer`.
Lottie_Text_Scratch :: struct {
	layout:    Text_Layout,
	runes:     [dynamic]rune,
	wrap:      [dynamic]rune,
	wrap_adv:  [dynamic]f32,
	buf:       [dynamic]u8,
	// Per codepoint: its pen x and advance in the layout, and its letter.
	xs:        [dynamic]f32,
	adv:       [dynamic]f32,
	letter_of: [dynamic]i32,
	letters:   [dynamic]Lottie_Letter,
	// Per letter: the tracking shift; per letter and animator: the
	// selector's share.
	shift:     [dynamic]f32,
	mults:     [dynamic]f32,
	// Per animator: its properties at the frame.
	values:    [dynamic]Lottie_Animator_Values,
	// The collection used without `Lottie_Renderer.fonts`.
	own_fonts: Font_Collection,
}

// A letter's layout and, under animators, its look.
Lottie_Letter :: struct {
	x, w:         f32,
	line:         i32,
	newline:      bool,
	space:        bool,
	// The anchor grouping: the group's width and the letter's offset in it.
	group_w:      f32,
	group_off:    f32,
	m:            Transform2D,
	opacity:      f32,
	fill, stroke: Color,
	stroke_width: f32,
}

lottie_text_scratch_destroy :: proc(s: ^Lottie_Text_Scratch) {
	text_layout_destroy(&s.layout)
	delete(s.runes)
	delete(s.wrap)
	delete(s.wrap_adv)
	delete(s.buf)
	delete(s.xs)
	delete(s.adv)
	delete(s.letter_of)
	delete(s.letters)
	delete(s.shift)
	delete(s.mults)
	delete(s.values)
	if s.own_fonts.fallback.font.data != nil {
		font_collection_destroy(&s.own_fonts)
	}
	s^ = {}
}

// A range selector at one frame, start / end in letter indices.
Lottie_Selector :: struct {
	shape:      Lottie_Selector_Shape,
	start, end: f32,
	// 0..1 (may exceed).
	amount:     f32,
	// Percent, as the file's ease high / low and smoothness.
	ease_high:  f32,
	ease_low:   f32,
	smoothness: f32,
}

// The share (times the amount) of letter index `ind` a range selector
// selects, as lottie-web's TextSelectorProp.getMult.
lottie_selector_mult :: proc "contextless" (sel: Lottie_Selector, ind: f32) -> f32 {
	x1, y1, x2, y2: f32 = 0, 0, 1, 1
	if sel.ease_low > 0 {
		x1 = sel.ease_low / 100
	} else {
		y1 = -sel.ease_low / 100
	}
	if sel.ease_high > 0 {
		x2 = 1 - sel.ease_high / 100
	} else {
		y2 = 1 + sel.ease_high / 100
	}
	s, e := sel.start, sel.end
	ind := ind
	ramp :: #force_inline proc "contextless" (s, e, ind: f32) -> f32 {
		return max(0, min(0.5 / (e - s) + (ind - s) / (e - s), 1))
	}
	mult: f32
	switch sel.shape {
	case .Ramp_Up:
		mult = (1 if ind >= e else 0) if e == s else ramp(s, e, ind)
	case .Ramp_Down:
		mult = (0 if ind >= e else 1) if e == s else 1 - ramp(s, e, ind)
	case .Triangle:
		if e != s {
			mult = ramp(s, e, ind)
			mult = mult * 2 if mult < 0.5 else 1 - 2 * (mult - 0.5)
		}
	case .Round:
		if e != s {
			tot := e - s
			ind = min(max(0, ind + 0.5 - s), tot)
			x := -tot / 2 + ind
			a := tot / 2
			mult = math.sqrt(max(0, 1 - x * x / (a * a)))
		}
	case .Smooth:
		if e != s {
			ind = min(max(0, ind + 0.5 - s), e - s)
			mult = (1 + math.cos(math.PI + math.PI * 2 * ind / (e - s))) / 2
		}
	case .Square:
		if ind >= math.floor(s) {
			if ind - s < 0 {
				mult = max(0, min(min(e, 1) - (s - ind), 1))
			} else {
				mult = max(0, min(e - ind, 1))
			}
		}
	}
	mult = lottie_ease(mult, x1, y1, x2, y2)
	if sel.smoothness != 100 {
		sm := sel.smoothness * 0.01
		if sm == 0 {
			sm = 1e-8
		}
		threshold := 0.5 - sm * 0.5
		mult = 0 if mult < threshold else min((mult - threshold) / sm, 1)
	}
	return mult * sel.amount
}

// Whether `r` continues the letter before it (emoji sequences, marks).
@(private)
lottie_rune_continues :: proc "contextless" (r, prev: rune) -> bool {
	switch r {
	case 0x200D, 0xFE0E, 0xFE0F, 0x20E3, 0x0300 ..= 0x036F, 0x1F3FB ..= 0x1F3FF, 0xE0020 ..= 0xE007F:
		return true
	}
	return prev == 0x200D
}

@(private)
lottie_text_fonts :: proc(r: ^Lottie_Renderer) -> ^Font_Collection {
	if r.fonts != nil {
		return r.fonts
	}
	if r.text.own_fonts.fallback.font.data == nil {
		font_collection_init(&r.text.own_fonts)
	}
	return &r.text.own_fonts
}

// Lays out the scratch codepoints and measures each one.
@(private)
lottie_text_layout :: proc(fonts: ^Font_Collection, s: ^Lottie_Text_Scratch, style: Text_Style, opts: Text_Options) {
	clear(&s.buf)
	for ch in s.runes {
		b, n := utf8.encode_rune(ch)
		append(&s.buf, ..b[:n])
	}
	pieces := [1]Text_Piece{{text = string(s.buf[:]), style = style}}
	l := &s.layout
	text_layout(fonts, pieces[:], opts, l)
	n := len(s.runes)
	resize(&s.xs, n)
	resize(&s.adv, n)
	for i in 0 ..< n {
		s.xs[i], s.adv[i] = max(f32), 0
	}
	for run in l.runs {
		font := font_collection_font(fonts, run.face)
		for k in run.first ..< run.first + run.count {
			c := l.clusters[k]
			if c < 0 || int(c) >= n {
				continue
			}
			g := l.glyphs[k]
			adv, _ := font_glyph_advance(font, g.glyph)
			s.adv[c] += f32(adv) * run.em
			s.xs[c] = min(s.xs[c], g.x)
		}
	}
	// Codepoints without a glyph (newlines, ligature tails) follow the one
	// before.
	x: f32 = opts.x
	for i in 0 ..< n {
		if s.xs[i] == max(f32) {
			s.xs[i] = x
		}
		x = s.xs[i] + s.adv[i]
	}
}

// Breaks lines wider than `width` at their last space (or before the
// letter that overflows), as lottie-web's box text.
@(private)
lottie_text_wrap :: proc(s: ^Lottie_Text_Scratch, width, tracking: f32) {
	clear(&s.wrap)
	clear(&s.wrap_adv)
	line_w: f32
	last_space := -1
	for ch, i in s.runes {
		w := s.adv[i]
		if ch == '\n' {
			line_w, last_space = 0, -1
			append(&s.wrap, ch)
			append(&s.wrap_adv, 0)
			continue
		}
		if line_w + w > width && ch != ' ' && line_w > 0 {
			line_w = 0
			if last_space >= 0 {
				s.wrap[last_space] = '\n'
				for k in last_space + 1 ..< len(s.wrap) {
					line_w += s.wrap_adv[k] + tracking
				}
			} else {
				append(&s.wrap, '\n')
				append(&s.wrap_adv, 0)
			}
			last_space = -1
		}
		if ch == ' ' {
			last_space = len(s.wrap)
		}
		append(&s.wrap, ch)
		append(&s.wrap_adv, w)
		line_w += w + tracking
	}
	clear(&s.runes)
	append(&s.runes, ..s.wrap[:])
}

// Groups the codepoints into letters with their anchor groups.
@(private)
lottie_text_letters :: proc(s: ^Lottie_Text_Scratch, grouping: u8) {
	clear(&s.letters)
	resize(&s.letter_of, len(s.runes))
	line: i32
	for ch, i in s.runes {
		if i > 0 && lottie_rune_continues(ch, s.runes[i - 1]) && !s.letters[len(s.letters) - 1].newline {
			s.letter_of[i] = i32(len(s.letters) - 1)
			s.letters[len(s.letters) - 1].w += s.adv[i]
			continue
		}
		if ch == '\n' {
			line += 1
		}
		s.letter_of[i] = i32(len(s.letters))
		append(&s.letters, Lottie_Letter{x = s.xs[i], w = s.adv[i], line = line, newline = ch == '\n', space = ch == ' '})
	}
	// Words (2) or lines (3) share an anchor: the group's middle.
	first := 0
	size: f32
	for &lt, i in s.letters {
		w := 0 if lt.newline else lt.w
		lt.group_off = size if grouping == 2 || grouping == 3 else 0
		lt.group_w = w
		if grouping != 2 && grouping != 3 {
			continue
		}
		size += w
		last := i == len(s.letters) - 1
		ends := lt.newline || last || (grouping == 2 && lt.space)
		if !ends {
			continue
		}
		if lt.newline || lt.space {
			size -= w
		}
		for k in first ..= i {
			s.letters[k].group_w = size
		}
		first, size = i + 1, 0
	}
}

@(private)
lottie_draw_text :: proc(d: ^Lottie_Draw, l: ^Lottie_Layer, li: i32, t: f32) {
	doc, c, r := d.doc, d.c, d.r
	if l.ref < 0 {
		return
	}
	txt := &doc.texts[l.ref]
	if txt.keys.count == 0 {
		return
	}
	keys := doc.text_keys[txt.keys.start:][:txt.keys.count]
	ki := 0
	for k, i in keys {
		if k.t <= t {
			ki = i
		}
	}
	td := &doc.text_docs[keys[ki].doc]
	if td.size <= 0 {
		return
	}
	text := td.text
	if ov := lottie_override(d, li); ov != nil {
		if s, ok := ov.text.?; ok {
			text = s
		}
	}
	s := &r.text
	clear(&s.runes)
	for ch in text {
		ch := ch
		if ch == '\r' || ch == 3 {
			ch = '\n'
		}
		append(&s.runes, unicode.to_upper(ch) if td.all_caps else ch)
	}
	fonts := lottie_text_fonts(r)
	style := Text_Style {
		size           = td.size,
		letter_spacing = td.tracking / 1000 * td.size,
	}
	ascent_pct: f32
	if td.font >= 0 {
		f := &doc.fonts[td.font]
		style.family, style.weight, style.italic, ascent_pct = f.family, f.weight, f.italic, f.ascent
	}
	opts := Text_Options {
		line_height = td.line_height / td.size,
	}
	switch td.justify {
	case .Left:
		opts.align = .Left
	case .Right:
		opts.align = .Right
	case .Center:
		opts.align = .Center
	}
	if td.has_box {
		lottie_text_layout(fonts, s, style, {line_height = opts.line_height})
		lottie_text_wrap(s, td.box_size.x, style.letter_spacing)
		asc := ascent_pct * td.size / 100
		if asc == 0 {
			face, _ := font_collection_find(fonts, style.family, style.weight, style.italic)
			f := font_collection_font(fonts, face)
			asc, _ = font_extent(f, font_scale_for_em(f, td.size))
		}
		opts.y = td.box_pos.y + asc
		switch td.justify {
		case .Left:
			opts.x = td.box_pos.x
		case .Center:
			opts.x = td.box_pos.x + td.box_size.x / 2
		case .Right:
			opts.x = td.box_pos.x + td.box_size.x
		}
	}
	lottie_text_layout(fonts, s, style, opts)
	lay := &s.layout
	for family in lay.missing {
		lottie_note_missing(r, family)
	}
	if len(lay.glyphs) == 0 {
		return
	}

	fill_col, has_fill := td.fill, td.has_fill
	stroke_col, has_stroke := td.stroke, td.has_stroke
	if f, ok := d.fill.?; ok {
		fill_col, has_fill = f, true
	}
	if st, ok := d.stroke.?; ok {
		stroke_col = st
	}
	animated := txt.animators.count > 0
	if animated {
		lottie_text_letters(s, txt.grouping)
		lottie_text_animate(d, txt, td, s, t, fill_col, stroke_col)
	}
	if !animated && td.baseline_shift != 0 {
		translate(c, 0, -td.baseline_shift)
	}
	alpha := state(c).alpha
	path := &r.path
	paints := [2]bool{false, true} if td.stroke_over else [2]bool{true, false}
	for run in lay.runs {
		font := font_collection_font(fonts, run.face)
		glyphs := lay.glyphs[run.first:][:run.count]
		if !animated {
			for stroke in paints {
				if stroke && has_stroke && td.stroke_width > 0 {
					p := paint_color(stroke_col)
					p.stroke.line_width = td.stroke_width
					p.stroke.line_join = .Round
					p.stroke.line_cap_start, p.stroke.line_cap_end = .Butt, .Butt
					stroke_glyph_outlines(c, font, glyphs, run.em, p, path)
				} else if !stroke && has_fill {
					fill_glyph_outlines(c, font, glyphs, run.em, paint_color(fill_col), path)
				}
			}
			continue
		}
		for g, k in glyphs {
			ci := lay.clusters[run.first + k]
			lt := &s.letters[s.letter_of[ci]]
			if lt.opacity <= 0 {
				continue
			}
			save(c)
			apply_transform(c, lt.m)
			set_global_alpha(c, alpha * min(lt.opacity, 1))
			one := [1]Positioned_Glyph{g}
			for stroke in paints {
				if stroke && has_stroke && lt.stroke_width > 0 {
					p := paint_color(lt.stroke)
					p.stroke.line_width = lt.stroke_width
					p.stroke.line_join = .Round
					p.stroke.line_cap_start, p.stroke.line_cap_end = .Butt, .Butt
					stroke_glyph_outlines(c, font, one[:], run.em, p, path)
				} else if !stroke && has_fill {
					fill_glyph_outlines(c, font, one[:], run.em, paint_color(lt.fill), path)
				}
			}
			restore(c)
		}
	}
}

@(private)
lottie_note_missing :: proc(r: ^Lottie_Renderer, family: string) {
	if family == "" {
		return
	}
	for m in r.missing {
		if m == family {
			return
		}
	}
	append(&r.missing, family)
}

// An animator's properties evaluated at one frame (they don't vary by
// letter): each value as many floats as its property has (`dims`, 0 when
// absent: the table's default).
@(private)
Lottie_Animator_Values :: struct {
	v:    [Lottie_Animator_Prop][4]f32,
	dims: [Lottie_Animator_Prop]u8,
}

@(private)
lottie_animator_values :: proc(doc: ^Lottie_Document, a: ^Lottie_Text_Animator, t: f32) -> (out: Lottie_Animator_Values) {
	for info, k in LOTTIE_ANIMATOR_PROPS {
		out.v[k] = info.default
		out.dims[k] = u8(lottie_eval(doc, a.props[k], t, out.v[k][:]))
	}
	return
}

// Each letter's matrix, opacity and colours under the layer's animators
// (lottie-web's TextAnimatorProperty.getMeasures without a path).
@(private)
lottie_text_animate :: proc(d: ^Lottie_Draw, txt: ^Lottie_Text, td: ^Lottie_Text_Doc, s: ^Lottie_Text_Scratch, t: f32, fill, stroke: Color) {
	doc := d.doc
	animators := doc.animators[txt.animators.start:][:txt.animators.count]
	letters := s.letters[:]
	align := lottie_eval2(doc, txt.alignment, t, {})
	y_off := td.size * 1.2 * 0.714
	for &lt in letters {
		lt.m = TRANSFORM_IDENTITY
		lt.opacity = 1
		lt.fill, lt.stroke, lt.stroke_width = fill, stroke, td.stroke_width
	}
	resize(&s.values, len(animators))
	values := s.values[:]
	for &a, j in animators {
		values[j] = lottie_animator_values(doc, &a, t)
	}
	// Per letter: the summed tracking shift, then the animators' changes.
	resize(&s.shift, len(letters))
	resize(&s.mults, len(letters) * len(animators))
	shift, mults := s.shift[:], s.mults[:]
	for &v in shift {
		v = 0
	}
	for &a, j in animators {
		// Letter indices as the selector counts them.
		ind: f32
		for &lt, i in letters {
			mults[i * len(animators) + j] = ind
			last := i == len(letters) - 1
			counts: bool
			switch a.based_on {
			case 1:
				counts = !lt.newline
			case 2:
				counts = !lt.newline && !lt.space
			case 3:
				counts = lt.newline || lt.space || last
			case 4:
				counts = lt.newline || last
			}
			if counts {
				ind += 1
			}
		}
		total := ind
		div: f32 = 1 if a.index_units else 100 / max(total, 1)
		v := &values[j].v
		o := v[.Offset].x / div
		sel := Lottie_Selector {
			shape      = a.shape,
			start      = v[.Start].x / div + o,
			end        = v[.End].x / div + o,
			amount     = v[.Amount].x / 100,
			ease_high  = v[.Ease_High].x,
			ease_low   = v[.Ease_Low].x,
			smoothness = v[.Smoothness].x,
		}
		if sel.start > sel.end {
			sel.start, sel.end = sel.end, sel.start
		}
		for i in 0 ..< len(letters) {
			k := i * len(animators) + j
			mults[k] = lottie_selector_mult(sel, mults[k])
		}
	}
	// Tracking moves the letters after (left text: not a line's first);
	// centred / right lines move back by their total (lottie-web adds half
	// the tracking per line so far to centred lines, kept for parity).
	acc, first_off: f32
	line_start := 0
	end_line :: proc(shift: []f32, from, to: int, acc, first_off: f32, j: Lottie_Justify) {
		if acc == 0 || j == .Left {
			return
		}
		off := -acc if j == .Right else -acc * 0.5 + first_off
		for k in from ..< to {
			shift[k] += off
		}
	}
	for &lt, i in letters {
		if lt.newline {
			end_line(shift, line_start, i, acc, first_off, td.justify)
			acc, line_start = 0, i + 1
			continue
		}
		if i > line_start || td.justify != .Left {
			for &a, j in animators {
				if a.props[.Tracking] >= 0 {
					tv := values[j].v[.Tracking].x
					if i == line_start && td.justify == .Center {
						first_off -= tv * 0.5
					}
					acc += tv * mults[i * len(animators) + j]
				}
			}
		}
		shift[i] = acc
	}
	end_line(shift, line_start, len(letters), acc, first_off, td.justify)

	// A colour animated over the letter's: the channels the property has.
	toward :: proc(cur: Color, v: [4]f32, dims: u8, mult: f32) -> Color {
		c := transmute([4]f32)cur
		for k in 0 ..< min(int(dims), 3) {
			c[k] += (v[k] - c[k]) * mult
		}
		return transmute(Color)c
	}
	for &lt, i in letters {
		if lt.newline {
			continue
		}
		mult := mults[i * len(animators):][:len(animators)]
		pivot := Vec2{lt.x - lt.group_off + lt.group_w / 2 + align.x * lt.group_w * 0.005, 0}
		if len(s.layout.glyphs) > 0 {
			pivot.y = lottie_letter_baseline(s, i)
		}
		pivot.y += align.y * y_off * 0.01
		m := transform_translation(-pivot.x, -pivot.y)
		for &a, j in animators {
			if a.props[.Anchor] >= 0 {
				v := values[j].v[.Anchor]
				m = transform_multiply(m, transform_translation(-v.x * mult[j], -v.y * mult[j]))
			}
		}
		for &a, j in animators {
			if a.props[.Scale] >= 0 {
				v := values[j].v[.Scale].xy / 100
				m = transform_multiply(m, transform_scaling(1 + (v.x - 1) * mult[j], 1 + (v.y - 1) * mult[j]))
			}
		}
		for &a, j in animators {
			v := &values[j]
			if a.props[.Skew] >= 0 {
				sk := v.v[.Skew].x * math.RAD_PER_DEG * mult[j]
				sa := v.v[.Skew_Axis].x * math.RAD_PER_DEG * mult[j]
				m = transform_multiply(m, transform_rotation(sa))
				m = transform_multiply(m, transform_skew_x(-sk))
				m = transform_multiply(m, transform_rotation(-sa))
			}
			if a.props[.Rotation] >= 0 {
				m = transform_multiply(m, transform_rotation(v.v[.Rotation].x * math.RAD_PER_DEG * mult[j]))
			}
			if a.props[.Opacity] >= 0 {
				o := v.v[.Opacity].x / 100
				lt.opacity += (o * mult[j] - lt.opacity) * mult[j]
			}
			if a.props[.Stroke_Width] >= 0 {
				lt.stroke_width += v.v[.Stroke_Width].x * mult[j]
			}
			if a.props[.Stroke] >= 0 {
				lt.stroke = toward(lt.stroke, v.v[.Stroke], v.dims[.Stroke], mult[j])
			}
			if a.props[.Fill] >= 0 {
				lt.fill = toward(lt.fill, v.v[.Fill], v.dims[.Fill], mult[j])
			}
		}
		for &a, j in animators {
			if a.props[.Position] >= 0 {
				v := values[j].v[.Position]
				m = transform_multiply(m, transform_translation(v.x * mult[j], v.y * mult[j]))
			}
		}
		lt.stroke_width = max(lt.stroke_width, 0)
		lt.fill = {clamp(lt.fill.r, 0, 1), clamp(lt.fill.g, 0, 1), clamp(lt.fill.b, 0, 1), lt.fill.a}
		lt.stroke = {clamp(lt.stroke.r, 0, 1), clamp(lt.stroke.g, 0, 1), clamp(lt.stroke.b, 0, 1), lt.stroke.a}
		m = transform_multiply(m, transform_translation(pivot.x + shift[i], pivot.y - td.baseline_shift))
		lt.m = m
	}
}

// The baseline y of letter `li` (its line's first glyph).
@(private)
lottie_letter_baseline :: proc(s: ^Lottie_Text_Scratch, li: int) -> f32 {
	line := s.letters[li].line
	lay := &s.layout
	if int(line) < len(lay.lines) {
		ln := lay.lines[line]
		if ln.count > 0 {
			return lay.glyphs[ln.first].y
		}
	}
	return lay.glyphs[0].y
}
