// OpenType text shaping: turns a run of characters in one font, script
// and direction into positioned glyphs with GSUB and GPOS, the way
// HarfBuzz does (it is the reference this is tested against).
//
// Three owners, three lifetimes:
//
// - `Layout` (layout.odin): a face's GSUB, GPOS and GDEF prepared once,
//   read-only while shaping.
// - `Plan` (plan.odin): the lookups to apply for a script, direction,
//   language and set of features; made once per such setting.
// - `Shaper`: the glyph buffer and scratch of one shaping call at a time,
//   kept warm by its owner: a warm shaper shapes without allocating.
//
// `shape` runs the stages over the buffer: Unicode properties, clusters,
// mirroring, normalization, feature masks, GSUB, advances, GPOS (or the
// kern table), mark and attachment fix-ups, then glyphs out in visual
// order.
package shape

import ft "../font"

Shaper :: struct {
	// Rows and positions (the arrays' lengths are their room; `len` rows
	// are in use).
	info:         [dynamic]Glyph_Info,
	out:          [dynamic]Glyph_Info,
	pos:          [dynamic]Glyph_Pos,
	len:          int,
	idx:          int,
	out_len:      int,
	have_output:  bool,
	separate:     bool,
	// False once the buffer would outgrow its limit.
	ok:           bool,
	max_len:      int,
	max_ops:      int,
	serial:       u32,
	random_state: u32,
	flags:        bit_set[Scratch_Flag],
	direction:    Direction,
	// Syllabic shapers' scratch: the categories a machine runs over, their
	// glyphs, the syllables found.
	scratch_cats:      [dynamic]u8,
	scratch_index:     [dynamic]i32,
	scratch_syllables: [dynamic]u8,
	// Indic: the font's virama glyph for the script (0 for none).
	virama:            u16,
}

// A shaped glyph, in font units (y up), in visual order.
Glyph :: struct {
	id:      u16,
	// The index in the text of the first character it shows.
	cluster: i32,
	advance: i32,
	offset:  [2]i32,
	// A mark (GDEF class or Unicode), attached to what precedes it.
	mark:    bool,
}

shaper_init :: proc(s: ^Shaper, allocator := context.allocator) {
	s^ = {}
	s.info = make([dynamic]Glyph_Info, allocator)
	s.out = make([dynamic]Glyph_Info, allocator)
	s.pos = make([dynamic]Glyph_Pos, allocator)
	s.scratch_cats = make([dynamic]u8, allocator)
	s.scratch_index = make([dynamic]i32, allocator)
	s.scratch_syllables = make([dynamic]u8, allocator)
}

shaper_destroy :: proc(s: ^Shaper) {
	delete(s.info)
	delete(s.out)
	delete(s.pos)
	delete(s.scratch_cats)
	delete(s.scratch_index)
	delete(s.scratch_syllables)
	s^ = {}
}

// Shapes `text` (all in the plan's script and direction) with face `f`,
// whose layout made the plan; `features` are the settings the plan was
// made with, their ranges applied now. Appends the glyphs to `out` in
// visual (left to right) order.
shape :: proc(s: ^Shaper, plan: ^Plan, f: ^ft.Face, text: []rune, features: []Feature, out: ^[dynamic]Glyph) {
	n := len(text)
	if n == 0 {
		return
	}
	s.len, s.idx, s.out_len = 0, 0, 0
	s.have_output, s.separate = false, false
	s.ok = true
	s.flags = {}
	s.serial = 0
	s.random_state = 1
	s.direction = plan.direction
	s.max_len = max(n * MAX_LEN_FACTOR, MAX_LEN_MIN)
	s.max_ops = max(n * MAX_OPS_FACTOR, MAX_OPS_MIN)
	if !ensure(s, n) {
		return
	}
	for r, i in text {
		s.info[i] = {char = r, cluster = i32(i), mask = plan.global_mask}
		init_unicode(s, &s.info[i])
	}
	s.len = n

	set_continuations(s)
	form_clusters(s)
	native_direction(s, plan)
	shaper_preprocess(s, plan, f)
	if plan.direction == .RTL {
		mirror_chars(s, plan, f)
	}
	normalize(s, plan, f)
	setup_masks(s, plan, features)
	if plan.fallback_marks {
		recategorize_marks(s)
	}

	c := Apply_Context {
		s                 = s,
		plan              = plan,
		layout            = plan.layout,
		face              = f,
		d                 = plan.layout.data,
		direction         = s.direction,
		nesting_left      = MAX_NESTING,
		has_glyph_classes = plan.layout.glyph_classes.table != 0,
	}
	gsub_start(&c)
	apply_table(&c, .GSUB)
	position(&c, f)
	if s.direction == .RTL {
		reverse_range(s, 0, s.len)
	}
	hide_default_ignorables(s, f)
	shaper_postprocess(s, plan, f)

	start := len(out)
	resize(out, start + s.len)
	rows := out[start:]
	for i in 0 ..< s.len {
		info, p := s.info[i], s.pos[i]
		rows[i] = {info.glyph, info.cluster, p.x_advance, {p.x_offset, p.y_offset}, is_mark(info)}
	}
}

// Applies one table's lookups, stage by stage.
@(private)
apply_table :: proc(c: ^Apply_Context, kind: Table_Kind) {
	plan := c.plan
	c.kind = kind
	c.digest = {}
	for info in c.s.info[:c.s.len] {
		digest_add_range(&c.digest, info.glyph, info.glyph)
	}
	lookups := plan.layout.tables[kind].lookups
	first := 0
	for stage in plan.stages[kind] {
		for pl in plan.lookups[kind][first:stage.end] {
			c.lookup_index = int(pl.index)
			c.lookup_mask = pl.mask
			c.flags = pl.flags
			apply_lookup_pass(c, &lookups[pl.index])
		}
		first = int(stage.end)
		if kind == .GSUB && stage.pause != .None {
			shaper_pause(c, stage.pause)
			// It may have added glyphs (dotted circles).
			c.digest = {}
			for info in c.s.info[:c.s.len] {
				digest_add_range(&c.digest, info.glyph, info.glyph)
			}
		}
	}
}

// Marks grapheme continuations: marks (set by init_unicode), emoji
// modifiers, the second of a regional indicator pair, ZWJ and the
// pictograph after it, tags and halfwidth kana sound marks.
@(private)
set_continuations :: proc(s: ^Shaper) {
	info := s.info[:s.len]
	for i := 0; i < len(info); i += 1 {
		r := info[i].char
		switch {
		case gc_of(info[i]) == .Sk && r >= 0x1F3FB && r <= 0x1F3FF:
			info[i].unicode |= UPROP_CONTINUATION
		case i > 0 && is_regional_indicator(r):
			if is_regional_indicator(info[i - 1].char) && !is_continuation(info[i - 1]) {
				info[i].unicode |= UPROP_CONTINUATION
			}
		case is_zwj(info[i]):
			info[i].unicode |= UPROP_CONTINUATION
			if i + 1 < len(info) && is_extended_pictographic(info[i + 1].char) {
				i += 1
				info[i].unicode |= UPROP_CONTINUATION
			}
		case (r >= 0xFF9E && r <= 0xFF9F) || (r >= 0xE0020 && r <= 0xE007F):
			info[i].unicode |= UPROP_CONTINUATION
		}
	}
}

// Each grapheme becomes one cluster (its first character's).
@(private)
form_clusters :: proc(s: ^Shaper) {
	if .Has_Non_ASCII not_in s.flags {
		return
	}
	for start := 0; start < s.len; {
		end := next_grapheme(s, start)
		merge_clusters(s, start, end)
		start = end
	}
}

// Text whose script runs the other way than asked is shaped in the
// script's direction, graphemes kept in order (HarfBuzz's native
// direction): digits alone in a right-to-left script stay left to right.
@(private)
native_direction :: proc(s: ^Shaper, plan: ^Plan) {
	#partial switch plan.script {
	case .Old_Hungarian, .Old_Italic, .Runic, .Tifinagh:
		// Written either way.
		return
	}
	native := script_direction(plan.script)
	if native == .RTL && plan.direction == .LTR {
		// Digits or regional indicators (bidi L, script Common) without
		// letters.
		found := false
		for info in s.info[:s.len] {
			gc := gc_of(info)
			if gc_is_letter(gc) {
				found = false
				break
			}
			found ||= gc == .Nd || is_regional_indicator(info.char)
		}
		if found {
			native = .LTR
		}
	}
	if native == plan.direction {
		return
	}
	for start := 0; start < s.len; {
		end := next_grapheme(s, start)
		reverse_range(s, start, end)
		start = end
	}
	reverse_range(s, 0, s.len)
	s.direction = native
}

// Right-to-left characters with a mirrored form use it when the font has
// it; the others get the rtlm feature.
@(private)
mirror_chars :: proc(s: ^Shaper, plan: ^Plan, f: ^ft.Face) {
	for &info in s.info[:s.len] {
		if m := char_mirror(info.char); m != 0 {
			if _, ok := nominal_glyph(f, m); ok {
				info.char = m
				continue
			}
		}
		info.mask |= plan.rtlm_mask
	}
}

// Feature masks per glyph: automatic fractions, then settings over part
// of the text.
@(private)
setup_masks :: proc(s: ^Shaper, plan: ^Plan, features: []Feature) {
	info := s.info[:s.len]
	// Plans keep numr and dnom only with frac, or both without it.
	if (plan.frac_mask != 0 || plan.numr_mask != 0) && .Has_Non_ASCII in s.flags {
		pre := plan.numr_mask | plan.frac_mask
		post := plan.frac_mask | plan.dnom_mask
		if s.direction == .RTL {
			pre, post = post, pre
		}
		for i := 0; i < len(info); {
			if info[i].char != 0x2044 {
				i += 1
				continue
			}
			start, end := i, i + 1
			for start > 0 && gc_of(info[start - 1]) == .Nd {
				start -= 1
			}
			for end < len(info) && gc_of(info[end]) == .Nd {
				end += 1
			}
			if start == i || end == i + 1 {
				// Digits on both sides, or no fraction.
				i += 1
				continue
			}
			for k in start ..< i {
				info[k].mask |= pre
			}
			info[i].mask |= plan.frac_mask
			for k in i + 1 ..< end {
				info[k].mask |= post
			}
			i = end
		}
	}
	shaper_setup_masks(s, plan)
	for feat in features {
		if feature_is_global(feat) {
			continue
		}
		mask, shift := plan_feature_mask(plan, feat.tag)
		if mask == 0 {
			continue
		}
		value := (feat.value << shift) & mask
		end := feat.end if feat.end != 0 else max(int)
		for &row in info {
			if int(row.cluster) >= feat.start && int(row.cluster) < end {
				row.mask = row.mask &~ mask | value
			}
		}
	}
}

// Advances from the font, then GPOS or the kern table, then marks zeroed
// and attachments resolved.
@(private)
position :: proc(c: ^Apply_Context, f: ^ft.Face) {
	s := c.s
	plan := c.plan
	s.have_output = false
	for i in 0 ..< s.len {
		s.pos[i] = {x_advance = i32(ft.advance(f, ft.Glyph(s.info[i].glyph)))}
	}
	if .Has_Space_Fallback in s.flags {
		adjust_spaces(s, f)
	}
	adjust := plan.adjust_mark_positioning && s.direction == .LTR
	if plan.zero_marks == .Early {
		zero_mark_widths(s, adjust)
	}
	if plan.apply_gpos {
		apply_table(c, .GPOS)
	}
	if plan.apply_kern {
		kern_table(c)
	}
	if plan.zero_marks == .Late {
		zero_mark_widths(s, adjust)
	}
	if .Has_Default_Ignorables in s.flags {
		for i in 0 ..< s.len {
			if is_ignorable(s.info[i]) {
				// Only across the line: its vertical offset and what it
				// attaches to still move it (HarfBuzz's choice).
				s.pos[i].x_advance, s.pos[i].x_offset = 0, 0
			}
		}
	}
	position_finish(s)
	if plan.fallback_marks {
		position_marks_fallback(s, plan, f, adjust)
	}
}

@(private)
zero_mark_widths :: proc(s: ^Shaper, adjust: bool) {
	for i in 0 ..< s.len {
		if is_mark(s.info[i]) {
			if adjust {
				s.pos[i].x_offset -= s.pos[i].x_advance
			}
			s.pos[i].x_advance = 0
		}
	}
}

// Spaces drawn with the space glyph take their own widths.
@(private)
adjust_spaces :: proc(s: ^Shaper, f: ^ft.Face) {
	upem := i32(f.units_per_em)
	for i in 0 ..< s.len {
		info := s.info[i]
		if gc_of(info) != .Zs || info.props & GLYPH_LIGATED != 0 {
			continue
		}
		p := &s.pos[i]
		kind := Space_Kind(info.unicode >> 8)
		switch kind {
		case .None, .Space:
		case .Em, .Em_2, .Em_3, .Em_4, .Em_5, .Em_6, .Em_16:
			k := i32(kind)
			p.x_advance = (upem + k / 2) / k
		case .Em_4_18:
			p.x_advance = upem * 4 / 18
		case .Figure:
			for ch in '0' ..= '9' {
				if g, ok := nominal_glyph(f, ch); ok {
					p.x_advance = i32(ft.advance(f, ft.Glyph(g)))
					break
				}
			}
		case .Punctuation:
			for ch in ([?]rune{'.', ','}) {
				if g, ok := nominal_glyph(f, ch); ok {
					p.x_advance = i32(ft.advance(f, ft.Glyph(g)))
					break
				}
			}
		case .Narrow:
			// Half a space (HarfBuzz's choice; Unicode says about a fifth
			// of an em, which is many fonts' space).
			p.x_advance /= 2
		}
	}
}

// The legacy kern table's horizontal format 0 subtables, over the visual
// order (pairs are left and right glyphs).
@(private)
kern_table :: proc(c: ^Apply_Context) {
	s := c.s
	d := c.d
	k := c.layout.kern
	if c.plan.kern_mask == 0 {
		return
	}
	if s.direction == .RTL {
		reverse_range(s, 0, s.len)
	}
	defer if s.direction == .RTL {
		reverse_range(s, 0, s.len)
	}
	c.lookup_mask = c.plan.kern_mask
	c.lookup_props = LOOKUP_IGNORE_MARKS
	c.kind = .GPOS
	count := int(ft.read_u16(d, k + 2))
	at := k + 4
	for _ in 0 ..< count {
		length := int(ft.read_u16(d, at + 2))
		coverage := ft.read_u16(d, at + 4)
		sub := at
		at += length
		if length < 6 {
			break
		}
		// Horizontal (bit 0), format 0 (high byte), not cross-stream or
		// minimum values.
		if coverage & 0x1 == 0 || coverage & 0x6 != 0 || coverage >> 8 != 0 {
			continue
		}
		pairs := int(ft.read_u16(d, sub + 6))
		for i in 0 ..< s.len {
			if s.info[i].mask & c.plan.kern_mask == 0 {
				continue
			}
			it := skippy_init(c, i, false)
			if !skippy_next(&it) {
				continue
			}
			key := u32(s.info[i].glyph) << 16 | u32(s.info[it.idx].glyph)
			lo, hi := 0, min(pairs, (len(d) - sub - 14) / 6)
			for lo < hi {
				mid := (lo + hi) / 2
				r := sub + 14 + 6 * mid
				v := ft.read_u32(d, r)
				if v < key {
					lo = mid + 1
				} else if v > key {
					hi = mid
				} else {
					// Split as HarfBuzz does: half on the left glyph's advance,
					// the rest on the right one's advance and offset.
					kern := i32(ft.read_i16(d, r + 4))
					left := kern >> 1
					s.pos[i].x_advance += left
					s.pos[it.idx].x_advance += kern - left
					s.pos[it.idx].x_offset += kern - left
					break
				}
			}
		}
	}
}

// Whether the legacy kern table has a state machine subtable (format 1,
// which ovg doesn't apply; with it HarfBuzz doesn't zero marks).
@(private)
kern_has_state_machine :: proc(l: ^Layout) -> bool {
	d, k := l.data, l.kern
	if k == 0 || ft.read_u16(d, k) != 0 {
		return false
	}
	count := int(ft.read_u16(d, k + 2))
	at := k + 4
	for _ in 0 ..< count {
		length := int(ft.read_u16(d, at + 2))
		if ft.read_u16(d, at + 4) >> 8 == 1 {
			return true
		}
		if length < 6 {
			break
		}
		at += length
	}
	return false
}

// Default ignorables show as the space glyph with no advance, or go when
// the font has no space.
@(private)
hide_default_ignorables :: proc(s: ^Shaper, f: ^ft.Face) {
	if .Has_Default_Ignorables not_in s.flags {
		return
	}
	if space, ok := nominal_glyph(f, ' '); ok {
		for &info in s.info[:s.len] {
			if is_ignorable(info) {
				info.glyph = space
			}
		}
		return
	}
	// Delete them, merging clusters into neighbours.
	j := 0
	for i in 0 ..< s.len {
		if is_ignorable(s.info[i]) {
			cluster := s.info[i].cluster
			if i + 1 < s.len && cluster == s.info[i + 1].cluster {
				continue
			}
			if j > 0 {
				if cluster < s.info[j - 1].cluster {
					old := s.info[j - 1].cluster
					for k := j; k > 0 && s.info[k - 1].cluster == old; k -= 1 {
						s.info[k - 1].cluster = cluster
					}
				}
				continue
			}
			if i + 1 < s.len {
				merge_clusters(s, i, i + 2)
			}
			continue
		}
		s.info[j], s.pos[j] = s.info[i], s.pos[i]
		j += 1
	}
	s.len = j
}

// The direction a script is written in horizontally.
script_direction :: proc(script: Script) -> Direction {
	return .RTL if script_is_rtl(script) else .LTR
}

script_is_rtl :: proc(script: Script) -> bool {
	#partial switch script {
	case .Arabic, .Hebrew, .Syriac, .Thaana, .Cypriot, .Kharoshthi, .Phoenician, .Nko, .Lydian, .Avestan, .Imperial_Aramaic, .Inscriptional_Pahlavi, .Inscriptional_Parthian, .Old_South_Arabian, .Old_Turkic, .Samaritan, .Mandaic, .Meroitic_Cursive, .Meroitic_Hieroglyphs, .Manichaean, .Mende_Kikakui, .Nabataean, .Old_North_Arabian, .Palmyrene, .Psalter_Pahlavi, .Hatran, .Adlam, .Hanifi_Rohingya, .Old_Sogdian, .Sogdian, .Elymaic, .Chorasmian, .Yezidi, .Old_Uyghur, .Garay, .Sidetic:
		return true
	}
	return false
}
