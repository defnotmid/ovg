package shape

import "core:math"
import ft "../font"

// GPOS: glyph positioning lookups, in place over the positions. Marks and
// cursive glyphs record what they attach to; `position_finish` then adds
// the offsets of what they hang from.

@(private)
gpos_apply :: proc(c: ^Apply_Context, type: u8, sub: ^Subtable, covered: int) -> bool {
	d := c.d
	s := c.s
	at := int(sub.at)
	switch type {
	case GPOS_SINGLE:
		format := ft.read_u16(d, at)
		value_format := ft.read_u16(d, at + 4)
		switch format {
		case 1:
			apply_value(c, at, at + 6, value_format, s.idx)
		case 2:
			if covered >= int(ft.read_u16(d, at + 6)) {
				return false
			}
			apply_value(c, at, at + 8 + covered * value_size(value_format), value_format, s.idx)
		case:
			return false
		}
		s.idx += 1
		return true
	case GPOS_PAIR:
		return apply_pair(c, sub, covered)
	case GPOS_CURSIVE:
		return apply_cursive(c, sub, covered)
	case GPOS_MARK_BASE, GPOS_MARK_LIGATURE:
		return apply_mark_base(c, at, covered, type == GPOS_MARK_LIGATURE)
	case GPOS_MARK_MARK:
		return apply_mark_mark(c, at, covered)
	case GPOS_CONTEXT:
		return apply_context(c, sub, covered, false)
	case GPOS_CHAIN_CONTEXT:
		return apply_context(c, sub, covered, true)
	}
	return false
}

// The bytes of a value record of `format`.
@(private)
value_size :: #force_inline proc "contextless" (format: u16) -> int {
	n := 0
	for f := format & 0xFF; f != 0; f >>= 1 {
		n += int(f & 1)
	}
	return 2 * n
}

// Adds the value record at `v` (device offsets from `base`) to glyph `i`'s
// position. Horizontal text takes no y advance; device tables count only
// as variation deltas.
@(private)
apply_value :: proc(c: ^Apply_Context, base, v: int, format: u16, i: int) {
	d := c.d
	p := &c.s.pos[i]
	v := v
	if format & 0x01 != 0 {
		p.x_offset += i32(ft.read_i16(d, v))
		v += 2
	}
	if format & 0x02 != 0 {
		p.y_offset += i32(ft.read_i16(d, v))
		v += 2
	}
	if format & 0x04 != 0 {
		p.x_advance += i32(ft.read_i16(d, v))
		v += 2
	}
	if format & 0x08 != 0 {
		v += 2
	}
	if format & 0xF0 == 0 || !has_coords(c) {
		return
	}
	if format & 0x10 != 0 {
		p.x_offset += device_delta(c, offset16(d, base, v))
		v += 2
	}
	if format & 0x20 != 0 {
		p.y_offset += device_delta(c, offset16(d, base, v))
		v += 2
	}
	if format & 0x40 != 0 {
		p.x_advance += device_delta(c, offset16(d, base, v))
	}
}

@(private)
has_coords :: proc(c: ^Apply_Context) -> bool {
	for v in c.face.coords[:c.face.axis_count] {
		if v != 0 {
			return true
		}
	}
	return false
}

// A device table's delta: only variation indexes (format 0x8000) count,
// rounded.
@(private)
device_delta :: proc(c: ^Apply_Context, at: int) -> i32 {
	d := c.d
	if at == 0 || ft.read_u16(d, at + 4) != 0x8000 {
		return 0
	}
	delta := ft.item_variation_delta(d, c.layout.var_store, int(ft.read_u16(d, at)), int(ft.read_u16(d, at + 2)), c.face.coords[:c.face.axis_count])
	return i32(math.floor(delta + 0.5))
}

// An anchor's point (font units, with variation deltas).
@(private)
anchor :: proc(c: ^Apply_Context, at: int) -> (x, y: i32) {
	d := c.d
	x, y = i32(ft.read_i16(d, at + 2)), i32(ft.read_i16(d, at + 4))
	if ft.read_u16(d, at) == 3 && has_coords(c) {
		x += device_delta(c, offset16(d, at, at + 6))
		y += device_delta(c, offset16(d, at, at + 8))
	}
	return
}

// Pair adjustment: the next glyph the lookup sees decides the values of
// both; a second value moves past the second glyph.
@(private)
apply_pair :: proc(c: ^Apply_Context, sub: ^Subtable, covered: int) -> bool {
	at := int(sub.at)
	d := c.d
	s := c.s
	it := skippy_init(c, s.idx, false)
	if !skippy_next(&it) {
		return false
	}
	second := s.info[it.idx].glyph
	format1, format2 := ft.read_u16(d, at + 4), ft.read_u16(d, at + 6)
	len1, len2 := value_size(format1), value_size(format2)
	values: int
	switch ft.read_u16(d, at) {
	case 1:
		if covered >= int(ft.read_u16(d, at + 8)) {
			return false
		}
		set := offset16(d, at, at + 10 + 2 * covered)
		record := 2 + len1 + len2
		lo, hi := 0, min(int(ft.read_u16(d, set)), (len(d) - set - 2) / record)
		for lo < hi {
			mid := (lo + hi) / 2
			r := set + 2 + mid * record
			g := ft.read_u16(d, r)
			if g < second {
				lo = mid + 1
			} else if g > second {
				hi = mid
			} else {
				values = r + 2
				break
			}
		}
		if values == 0 {
			return false
		}
		// Device offsets in a pair set count from the set.
		apply_value(c, set, values, format1, s.idx)
		apply_value(c, set, values + len1, format2, it.idx)
	case 2:
		c1 := unpacked_class(c.layout, sub.classes[0], s.info[s.idx].glyph)
		c2 := unpacked_class(c.layout, sub.classes[1], second)
		n1, n2 := int(ft.read_u16(d, at + 12)), int(ft.read_u16(d, at + 14))
		if c1 >= n1 || c2 >= n2 {
			return false
		}
		values = at + 16 + (c1 * n2 + c2) * (len1 + len2)
		apply_value(c, at, values, format1, s.idx)
		apply_value(c, at, values + len1, format2, it.idx)
	case:
		return false
	}
	s.idx = it.idx + 1 if len2 != 0 else it.idx
	return true
}

// Cursive attachment: the previous glyph's exit anchor meets this one's
// entry. The advance is set in the main direction; across it the glyph
// that is the child (by the lookup's right-to-left flag) hangs off its
// parent.
@(private)
apply_cursive :: proc(c: ^Apply_Context, sub: ^Subtable, covered: int) -> bool {
	at := int(sub.at)
	d := c.d
	s := c.s
	count := int(ft.read_u16(d, at + 4))
	if covered >= count {
		return false
	}
	entry := offset16(d, at, at + 6 + 4 * covered)
	if entry == 0 {
		return false
	}
	it := skippy_init(c, s.idx, false)
	if !skippy_prev(&it) {
		return false
	}
	prev := unpacked_coverage(c.layout, sub.coverage, s.info[it.idx].glyph)
	if prev < 0 || prev >= count {
		return false
	}
	exit := offset16(d, at, at + 6 + 4 * prev + 2)
	if exit == 0 {
		return false
	}
	i, j := it.idx, s.idx
	exit_x, exit_y := anchor(c, exit)
	entry_x, entry_y := anchor(c, entry)
	pos := s.pos[:]
	switch c.direction {
	case .LTR:
		pos[i].x_advance = exit_x + pos[i].x_offset
		dx := entry_x + pos[j].x_offset
		pos[j].x_advance -= dx
		pos[j].x_offset -= dx
	case .RTL:
		dx := exit_x + pos[i].x_offset
		pos[i].x_advance -= dx
		pos[i].x_offset -= dx
		pos[j].x_advance = entry_x + pos[j].x_offset
	}
	child, parent := i, j
	y_offset := entry_y - exit_y
	if c.lookup_props & LOOKUP_RIGHT_TO_LEFT == 0 {
		child, parent = parent, child
		y_offset = -y_offset
	}
	// A child attached elsewhere already: its old chain turns around to
	// hang from the new parent.
	reverse_cursive_minor_offset(pos, child, parent)
	pos[child].attach_type = ATTACH_CURSIVE
	pos[child].attach_chain = i16(parent - child)
	s.flags += {.Has_GPOS_Attachment}
	pos[child].y_offset = y_offset
	// A parent attached to the child comes loose.
	if pos[parent].attach_chain == -pos[child].attach_chain {
		pos[parent].attach_chain = 0
		pos[parent].y_offset = 0
	}
	s.idx += 1
	return true
}

@(private)
reverse_cursive_minor_offset :: proc(pos: []Glyph_Pos, i, new_parent: int) {
	for k, depth := i, 0; depth < MAX_NESTING; depth += 1 {
		chain := pos[k].attach_chain
		type := pos[k].attach_type
		if chain == 0 || type & ATTACH_CURSIVE == 0 {
			return
		}
		pos[k].attach_chain = 0
		j := k + int(chain)
		if j == new_parent || j < 0 || j >= len(pos) {
			return
		}
		// The rest of the chain first, then this link turned around.
		reverse_cursive_minor_offset(pos, j, new_parent)
		pos[j].y_offset = -pos[k].y_offset
		pos[j].attach_chain = -chain
		pos[j].attach_type = type
		return
	}
}

// Mark to base (or to ligature): the closest preceding glyph that isn't a
// mark is the base; only the first of a multiple substitution's glyphs
// takes marks.
@(private)
apply_mark_base :: proc(c: ^Apply_Context, at, mark_index: int, ligature: bool) -> bool {
	d := c.d
	s := c.s
	base_coverage := offset16(d, at, at + 4)
	it := skippy_init(c, s.idx, false)
	it.lookup_props = LOOKUP_IGNORE_MARKS
	if c.last_base_until > s.idx {
		c.last_base, c.last_base_until = -1, 0
	}
	for j := s.idx; j > c.last_base_until; j -= 1 {
		if step(&it, s.info[j - 1]) != .Match {
			continue
		}
		if !ligature && !accepts_marks(s, j - 1) && coverage_index(d, base_coverage, s.info[j - 1].glyph) < 0 {
			continue
		}
		c.last_base = j - 1
		break
	}
	c.last_base_until = s.idx
	if c.last_base < 0 {
		return false
	}
	base := c.last_base
	base_index := coverage_index(d, base_coverage, s.info[base].glyph)
	if base_index < 0 {
		return false
	}
	class_count := int(ft.read_u16(d, at + 6))
	marks := offset16(d, at, at + 8)
	array := offset16(d, at, at + 10)
	if !ligature {
		return attach_mark(c, marks, mark_index, array, base_index, class_count, base)
	}
	// The ligature's component the mark belongs to, else its last.
	if base_index >= int(ft.read_u16(d, array)) {
		return false
	}
	attach := offset16(d, array, array + 2 + 2 * base_index)
	comp_count := int(ft.read_u16(d, attach))
	if comp_count == 0 {
		return false
	}
	lig, mark := s.info[base], s.info[s.idx]
	comp := comp_count - 1
	if lig_id(lig) != 0 && lig_id(lig) == lig_id(mark) && lig_comp(mark) > 0 {
		comp = min(comp_count, int(lig_comp(mark))) - 1
	}
	return attach_mark(c, marks, mark_index, attach, comp, class_count, base)
}

// Whether glyph `i` takes marks: not a later glyph of a multiple
// substitution's sequence.
@(private)
accepts_marks :: proc(s: ^Shaper, i: int) -> bool {
	info := s.info[i]
	if !is_multiplied(info) || lig_comp(info) == 0 || i == 0 {
		return true
	}
	prev := s.info[i - 1]
	return is_mark(prev) || !is_multiplied(prev) || lig_id(info) != lig_id(prev) || lig_comp(info) != lig_comp(prev) + 1
}

// Mark to mark: the preceding mark (per the lookup's filtering) of the same
// base or ligature component.
@(private)
apply_mark_mark :: proc(c: ^Apply_Context, at, mark_index: int) -> bool {
	d := c.d
	s := c.s
	it := skippy_init(c, s.idx, false)
	it.lookup_props = c.lookup_props &~ LOOKUP_IGNORE_FLAGS
	if !skippy_prev(&it) {
		return false
	}
	j := it.idx
	if !is_mark(s.info[j]) {
		return false
	}
	cur, prev := s.info[s.idx], s.info[j]
	id1, id2 := lig_id(cur), lig_id(prev)
	comp1, comp2 := lig_comp(cur), lig_comp(prev)
	good := false
	if id1 == id2 {
		good = id1 == 0 || comp1 == comp2
	} else {
		// One of them may itself be a ligature of marks.
		good = (id1 > 0 && comp1 == 0) || (id2 > 0 && comp2 == 0)
	}
	if !good {
		return false
	}
	mark2_index := coverage_index(d, offset16(d, at, at + 4), prev.glyph)
	if mark2_index < 0 {
		return false
	}
	class_count := int(ft.read_u16(d, at + 6))
	return attach_mark(c, offset16(d, at, at + 8), mark_index, offset16(d, at, at + 10), mark2_index, class_count, j)
}

// Attaches the current mark to glyph `base`: the anchor of row `row` of
// the anchor anchors at `anchors` for the mark's class meets the mark's
// own. False when the row has no anchor for the class (a later subtable
// may).
@(private)
attach_mark :: proc(c: ^Apply_Context, marks, mark_index, anchors, row, class_count, base: int) -> bool {
	d := c.d
	s := c.s
	if mark_index >= int(ft.read_u16(d, marks)) || row >= int(ft.read_u16(d, anchors)) {
		return false
	}
	record := marks + 2 + 4 * mark_index
	class := int(ft.read_u16(d, record))
	if class >= class_count {
		return false
	}
	base_anchor := offset16(d, anchors, anchors + 2 + 2 * (row * class_count + class))
	if base_anchor == 0 {
		return false
	}
	mark_x, mark_y := anchor(c, offset16(d, marks, record + 2))
	base_x, base_y := anchor(c, base_anchor)
	p := &s.pos[s.idx]
	p.x_offset = base_x - mark_x
	// Across the direction, where the base is now (with the cursive chain
	// it hangs from): a later lookup moving the base doesn't carry the
	// mark (lookup order, as DirectWrite and Core Text do).
	p.y_offset = base_y - mark_y + cross_offset(s.pos[:s.len], base)
	p.attach_type = ATTACH_MARK
	p.attach_chain = i16(base - s.idx)
	s.flags += {.Has_GPOS_Attachment}
	s.idx += 1
	return true
}

// A glyph's y offset plus those of the cursive chain it hangs from.
@(private)
cross_offset :: proc(pos: []Glyph_Pos, i: int) -> i32 {
	i := i
	offset := pos[i].y_offset
	for depth := 0; pos[i].attach_type & ATTACH_CURSIVE != 0 && depth < len(pos); depth += 1 {
		chain := int(pos[i].attach_chain)
		if chain == 0 || i + chain < 0 || i + chain >= len(pos) {
			break
		}
		i += chain
		offset += pos[i].y_offset
	}
	return offset
}

// Adds to each attached glyph the offsets of what it attaches to: a
// cursive glyph its parent's y offset, a mark its base's x offset less
// the advances between (its y was set when it attached).
@(private)
position_finish :: proc(s: ^Shaper) {
	if .Has_GPOS_Attachment not_in s.flags {
		return
	}
	pos := s.pos[:s.len]
	if s.direction == .LTR {
		for i in 0 ..< len(pos) {
			if pos[i].attach_chain != 0 {
				propagate_attachment(pos, i, s.direction, MAX_NESTING)
			}
		}
	} else {
		for i := len(pos) - 1; i >= 0; i -= 1 {
			if pos[i].attach_chain != 0 {
				propagate_attachment(pos, i, s.direction, MAX_NESTING)
			}
		}
	}
}

@(private)
propagate_attachment :: proc(pos: []Glyph_Pos, i: int, direction: Direction, nesting: int) {
	chain := int(pos[i].attach_chain)
	type := pos[i].attach_type
	if chain == 0 {
		return
	}
	pos[i].attach_chain = 0
	j := i + chain
	if j < 0 || j >= len(pos) || nesting == 0 {
		return
	}
	if pos[j].attach_chain != 0 {
		propagate_attachment(pos, j, direction, nesting - 1)
	}
	if type & ATTACH_CURSIVE != 0 {
		pos[i].y_offset += pos[j].y_offset
		return
	}
	pos[i].x_offset += pos[j].x_offset
	if j < i {
		if direction == .LTR {
			for k in j ..< i {
				pos[i].x_offset -= pos[k].x_advance
			}
		} else {
			for k in j + 1 ..= i {
				pos[i].x_offset += pos[k].x_advance
			}
		}
	} else if direction == .LTR {
		for k in i ..< j {
			pos[i].x_offset += pos[k].x_advance
		}
	} else {
		for k in i + 1 ..= j {
			pos[i].x_offset -= pos[k].x_advance
		}
	}
}
