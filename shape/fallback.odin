package shape

import ft "../font"

// Mark positioning for fonts without GPOS (HarfBuzz's fallback): each
// mark is placed by its combining class against the box of its base (or
// ligature component) and the marks already stacked there.

// Canonical combining classes the placement distinguishes.
@(private)
CCC_ATTACHED_BELOW_LEFT :: 200
@(private)
CCC_ATTACHED_BELOW :: 202
@(private)
CCC_ATTACHED_ABOVE :: 214
@(private)
CCC_ATTACHED_ABOVE_RIGHT :: 216
@(private)
CCC_BELOW_LEFT :: 218
@(private)
CCC_BELOW :: 220
@(private)
CCC_BELOW_RIGHT :: 222
@(private)
CCC_ABOVE_LEFT :: 228
@(private)
CCC_ABOVE :: 230
@(private)
CCC_ABOVE_RIGHT :: 232
@(private)
CCC_DOUBLE_BELOW :: 233
@(private)
CCC_DOUBLE_ABOVE :: 234

// A glyph's box as HarfBuzz gives it: left edge (the side bearing), top,
// width, and height (negative, downward).
@(private)
Extents :: struct {
	x_bearing, y_bearing, width, height: i32,
}

@(private)
glyph_extents :: proc(f: ^ft.Face, g: u16) -> (e: Extents, ok: bool) {
	if int(g) >= f.glyph_count {
		return {}, false
	}
	x0, y0, x1, y1, has := ft.glyph_box(f, ft.Glyph(g))
	if !has {
		return {}, true
	}
	return {i32(x0), i32(y1), i32(x1 - x0), i32(y0 - y1)}, true
}

// Before positioning, the classes of marks in scripts whose fixed-position
// classes say little about placement become above or below.
@(private)
recategorize_marks :: proc(s: ^Shaper) {
	for &info in s.info[:s.len] {
		if gc_of(info) != .Mn {
			continue
		}
		class := recategorize_class(info.char, u8(info.unicode >> 8))
		info.unicode = info.unicode & 0xFF | u16(class) << 8
	}
}

@(private)
recategorize_class :: proc(r: rune, class: u8) -> u8 {
	if class >= 200 {
		return class
	}
	class := class
	// Thai and Lao marks with class 0 (or Thai's phinthu).
	if r & ~rune(0xFF) == 0x0E00 {
		if class == 0 {
			switch r {
			case 0x0E31, 0x0E34, 0x0E35, 0x0E36, 0x0E37, 0x0E47, 0x0E4C, 0x0E4D, 0x0E4E:
				class = CCC_ABOVE_RIGHT
			case 0x0EB1, 0x0EB4, 0x0EB5, 0x0EB6, 0x0EB7, 0x0EBB, 0x0ECC, 0x0ECD:
				class = CCC_ABOVE
			case 0x0EBC:
				class = CCC_BELOW
			}
		} else if r == 0x0E3A {
			class = CCC_BELOW_RIGHT
		}
	}
	switch class {
	// Hebrew points (modified classes).
	case 22, 15, 16, 17, 23, 18, 19, 20, 21, 24, 25:
		return CCC_BELOW
	case 13:
		return CCC_ATTACHED_ABOVE
	case 10:
		return CCC_ABOVE_RIGHT
	case 11, 14:
		return CCC_ABOVE_LEFT
	case 26:
		return CCC_ABOVE
	// Arabic and Syriac.
	case 28, 29, 31, 32, 27, 34, 35, 36:
		return CCC_ABOVE
	case 30, 33:
		return CCC_BELOW
	// Thai, Lao, Tibetan.
	case 3:
		return CCC_BELOW_RIGHT
	case 107:
		return CCC_ABOVE_RIGHT
	case 118:
		return CCC_BELOW
	case 122:
		return CCC_ABOVE
	case 129:
		return CCC_BELOW
	case 132:
		return CCC_ABOVE
	case 131:
		return CCC_BELOW
	}
	return class
}

// Places each base's marks. Clusters start at glyphs that are neither
// marks nor default ignorables (an invisible SHY or ZWSP between a letter
// and its marks doesn't take them, as in HarfBuzz); a cluster's base is
// its first glyph that isn't a mark.
@(private)
position_marks_fallback :: proc(s: ^Shaper, plan: ^Plan, f: ^ft.Face, adjust: bool) {
	start := 0
	for i in 1 ..= s.len {
		if i < s.len && (is_unicode_mark(s.info[i]) || is_ignorable(s.info[i])) {
			continue
		}
		base := start
		for base < i && is_unicode_mark(s.info[base]) {
			base += 1
		}
		if i - base > 1 {
			position_around_base(s, plan, f, base, i, adjust)
		}
		start = i
	}
}

@(private)
position_around_base :: proc(s: ^Shaper, plan: ^Plan, f: ^ft.Face, base, end: int, adjust: bool) {
	base_info, base_pos := s.info[base], s.pos[base]
	base_extents, ok := glyph_extents(f, base_info.glyph)
	if !ok {
		// Unknown base: marks only lose their advance.
		for k in base + 1 ..< end {
			if gc_of(s.info[k]) == .Mn {
				if adjust {
					s.pos[k].x_offset -= s.pos[k].x_advance
				}
				s.pos[k].x_advance = 0
			}
		}
		return
	}
	base_extents.y_bearing += base_pos.y_offset
	base_extents.x_bearing = 0
	base_extents.width = i32(ft.advance(f, ft.Glyph(base_info.glyph)))
	id := lig_id(base_info)
	num_comps := i32(lig_num_comps(base_info))
	x_offset, y_offset: i32
	forward := s.direction == .LTR
	if forward {
		x_offset -= base_pos.x_advance
	}
	last_comp: i32 = -1
	last_class: u8 = 255
	component_extents := base_extents
	cluster_extents := base_extents
	for k in base + 1 ..< end {
		info := s.info[k]
		p := &s.pos[k]
		class := mcc_of(info)
		if class == 0 {
			if forward {
				x_offset -= p.x_advance
			} else {
				x_offset += p.x_advance
			}
			continue
		}
		if num_comps > 1 {
			comp := i32(lig_comp(info)) - 1
			if id == 0 || id != lig_id(info) || comp >= num_comps {
				comp = num_comps - 1
			}
			if last_comp != comp {
				last_comp = comp
				last_class = 255
				component_extents = base_extents
				index := comp if plan.direction == .LTR else num_comps - 1 - comp
				component_extents.x_bearing += index * component_extents.width / num_comps
				component_extents.width /= num_comps
			}
		}
		if last_class != class {
			last_class = class
			cluster_extents = component_extents
		}
		position_mark(f, s.direction, info.glyph, p, &cluster_extents, class)
		p.x_advance = 0
		p.x_offset += x_offset
		p.y_offset += y_offset
	}
}

@(private)
position_mark :: proc(f: ^ft.Face, direction: Direction, g: u16, p: ^Glyph_Pos, base: ^Extents, class: u8) {
	mark, ok := glyph_extents(f, g)
	if !ok {
		return
	}
	y_gap := i32(f.units_per_em) / 16
	p.x_offset, p.y_offset = 0, 0
	switch class {
	case CCC_DOUBLE_BELOW, CCC_DOUBLE_ABOVE:
		p.x_offset += base.x_bearing + (base.width if direction == .LTR else 0) - mark.width / 2 - mark.x_bearing
	case CCC_ATTACHED_BELOW_LEFT, CCC_BELOW_LEFT, CCC_ABOVE_LEFT:
		p.x_offset += base.x_bearing - mark.x_bearing
	case CCC_ATTACHED_ABOVE_RIGHT, CCC_BELOW_RIGHT, CCC_ABOVE_RIGHT:
		p.x_offset += base.x_bearing + base.width - mark.width - mark.x_bearing
	case:
		p.x_offset += base.x_bearing + (base.width - mark.width) / 2 - mark.x_bearing
	}
	attached := class == CCC_ATTACHED_BELOW_LEFT || class == CCC_ATTACHED_BELOW || class == CCC_ATTACHED_ABOVE || class == CCC_ATTACHED_ABOVE_RIGHT
	switch class {
	case CCC_DOUBLE_BELOW, CCC_BELOW_LEFT, CCC_BELOW, CCC_BELOW_RIGHT, CCC_ATTACHED_BELOW_LEFT, CCC_ATTACHED_BELOW:
		if !attached {
			base.height -= y_gap
		}
		p.y_offset = base.y_bearing + base.height - mark.y_bearing
		// Never move the mark up from where it is drawn.
		if (y_gap > 0) == (p.y_offset > 0) {
			base.height -= p.y_offset
			p.y_offset = 0
		}
		base.height += mark.height
	case CCC_DOUBLE_ABOVE, CCC_ABOVE_LEFT, CCC_ABOVE, CCC_ABOVE_RIGHT, CCC_ATTACHED_ABOVE, CCC_ATTACHED_ABOVE_RIGHT:
		if !attached {
			base.y_bearing += y_gap
			base.height -= y_gap
		}
		p.y_offset = base.y_bearing - (mark.y_bearing + mark.height)
		// Don't shift down by more than half the distance.
		if (y_gap > 0) != (p.y_offset > 0) {
			correction := -p.y_offset / 2
			base.y_bearing += correction
			base.height -= correction
			p.y_offset += correction
		}
		base.y_bearing -= mark.height
		base.height += mark.height
	}
}
