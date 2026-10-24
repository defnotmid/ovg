package shape

import ft "../font"

// GSUB: glyph substitution lookups, applied to the buffer in order, each
// a pass over it (forward; reverse chained substitutions backward).

// Sets each glyph's GDEF properties before GSUB (from GDEF, else from its
// character: a nonspacing mark is a mark, all else a base).
@(private)
gsub_start :: proc(c: ^Apply_Context) {
	s := c.s
	for &info in s.info[:s.len] {
		info.lig = 0
		info.syllable = 0
		if c.plan.fallback_glyph_classes {
			info.props = GLYPH_MARK if gc_of(info) == .Mn && !is_ignorable(info) else GLYPH_BASE
		} else {
			info.props = glyph_props(c.layout, info.glyph)
		}
	}
}

// One lookup over the whole buffer: skipped when no glyph in it can be
// covered; else glyphs it can't apply to pass through in runs.
@(private)
apply_lookup_pass :: proc(c: ^Apply_Context, lookup: ^Lookup) {
	s := c.s
	if s.len == 0 || c.lookup_mask == 0 || !digests_intersect(&lookup.digest, &c.digest) {
		return
	}
	c.lookup_props = lookup.props
	c.last_base, c.last_base_until = -1, 0
	if c.kind == .GSUB && lookup.type == GSUB_REVERSE_CHAIN {
		// In place, last glyph to first.
		s.idx = s.len - 1
		for {
			if may_apply(c, lookup, s.info[s.idx]) {
				apply_at(c, lookup)
			}
			if s.idx == 0 {
				break
			}
			s.idx -= 1
		}
		return
	}
	if c.kind == .GSUB {
		clear_output(s)
	}
	s.idx = 0
	for s.idx < s.len && s.ok {
		start := s.idx
		for s.idx < s.len && !may_apply(c, lookup, s.info[s.idx]) {
			s.idx += 1
		}
		n := s.idx - start
		s.idx = start
		next_glyphs(s, n)
		if s.idx < s.len && !apply_at(c, lookup) {
			next_glyph(s)
		}
	}
	if c.kind == .GSUB {
		swap_buffers(s)
	}
}

// Whether the lookup may apply at a glyph: in its digest, its features'
// mask, not ignored by its flags.
@(private)
may_apply :: #force_inline proc(c: ^Apply_Context, lookup: ^Lookup, info: Glyph_Info) -> bool {
	return digest_may_have(&lookup.digest, info.glyph) && info.mask & c.lookup_mask != 0 && check_glyph_property(c, info, c.lookup_props)
}

// The glyph's new properties after substitution: substituted, ligated or
// multiplied, and its GDEF class (else `class_guess`, else unchanged).
@(private)
set_glyph_class :: proc(c: ^Apply_Context, g: u16, class_guess: u16 = 0, ligature := false, component := false) {
	info := &c.s.info[c.s.idx]
	props := info.props | GLYPH_SUBSTITUTED
	if ligature {
		// Only the last of ligating and multiplying counts.
		props |= GLYPH_LIGATED
		props &~= GLYPH_MULTIPLIED
	}
	if component {
		props |= GLYPH_MULTIPLIED
	}
	digest_add_range(&c.digest, g, g)
	PRESERVE :: GLYPH_SUBSTITUTED | GLYPH_LIGATED | GLYPH_MULTIPLIED
	if c.has_glyph_classes {
		props = props & PRESERVE | glyph_props(c.layout, g)
	} else if class_guess != 0 {
		props = props & PRESERVE | class_guess
	}
	info.props = props
}

@(private)
subst_replace :: proc(c: ^Apply_Context, g: u16) {
	set_glyph_class(c, g)
	replace_glyph(c.s, g)
}

@(private)
gsub_apply :: proc(c: ^Apply_Context, type: u8, sub: ^Subtable, covered: int) -> bool {
	d := c.d
	s := c.s
	at := int(sub.at)
	switch type {
	case GSUB_SINGLE:
		g := s.info[s.idx].glyph
		switch ft.read_u16(d, at) {
		case 1:
			// Glyph ids wrap at 16 bits.
			subst_replace(c, g + ft.read_u16(d, at + 4))
			return true
		case 2:
			if covered >= int(ft.read_u16(d, at + 4)) {
				return false
			}
			subst_replace(c, ft.read_u16(d, at + 6 + 2 * covered))
			return true
		}
	case GSUB_MULTIPLE:
		if ft.read_u16(d, at) != 1 || covered >= int(ft.read_u16(d, at + 4)) {
			return false
		}
		seq := offset16(d, at, at + 6 + 2 * covered)
		count := int(ft.read_u16(d, seq))
		switch count {
		case 0:
			// The spec forbids it; fonts rely on it deleting the glyph.
			delete_glyph(s)
		case 1:
			subst_replace(c, ft.read_u16(d, seq + 2))
		case:
			class: u16 = GLYPH_BASE if is_ligature(s.info[s.idx]) else 0
			id := lig_id(s.info[s.idx])
			for i in 0 ..< count {
				// Components of a glyph attached to a ligature stay as they are.
				if id == 0 {
					set_lig_for_mark(&s.info[s.idx], 0, u8(i))
				}
				g := ft.read_u16(d, seq + 2 + 2 * i)
				set_glyph_class(c, g, class, component = true)
				output_glyph(s, g)
			}
			skip_glyph(s)
		}
		return true
	case GSUB_ALTERNATE:
		if ft.read_u16(d, at) != 1 || covered >= int(ft.read_u16(d, at + 4)) {
			return false
		}
		set := offset16(d, at, at + 6 + 2 * covered)
		count := int(ft.read_u16(d, set))
		if count == 0 {
			return false
		}
		// The feature's value picks the alternate (rand: at random).
		mask := c.lookup_mask
		shift: u32 = 0
		for mask != 0 && mask & (1 << shift) == 0 {
			shift += 1
		}
		alt := (mask & s.info[s.idx].mask) >> shift
		if alt == FEATURE_MAX_VALUE && .Random in c.flags {
			s.random_state = s.random_state * 48271 % 2147483647
			alt = s.random_state % u32(count) + 1
		}
		if alt == 0 || int(alt) > count {
			return false
		}
		subst_replace(c, ft.read_u16(d, set + 2 * int(alt)))
		return true
	case GSUB_LIGATURE:
		if ft.read_u16(d, at) != 1 || covered >= int(ft.read_u16(d, at + 4)) {
			return false
		}
		set := offset16(d, at, at + 6 + 2 * covered)
		count := int(ft.read_u16(d, set))
		for i in 0 ..< count {
			lig := offset16(d, set, set + 2 + 2 * i)
			if lig == 0 {
				continue
			}
			lig_glyph := ft.read_u16(d, lig)
			comps := int(ft.read_u16(d, lig + 2))
			if comps == 0 {
				continue
			}
			if comps == 1 {
				// One component: in place, not a ligature.
				subst_replace(c, lig_glyph)
				return true
			}
			// Every field read is written by match_input.
			m: Matched = ---
			if match_input(c, comps, {.Glyph, lig + 4, {}, 0}, &m) {
				ligate(c, comps, &m, lig_glyph)
				return true
			}
		}
	case GSUB_CONTEXT:
		return apply_context(c, sub, covered, false)
	case GSUB_CHAIN_CONTEXT:
		return apply_context(c, sub, covered, true)
	case GSUB_REVERSE_CHAIN:
		// Never from within a context.
		if c.nesting_left != MAX_NESTING || ft.read_u16(d, at) != 1 {
			return false
		}
		backtrack := int(ft.read_u16(d, at + 4))
		ahead_at := at + 6 + 2 * backtrack
		lookahead := int(ft.read_u16(d, ahead_at))
		subst_at := ahead_at + 2 + 2 * lookahead
		if covered >= int(ft.read_u16(d, subst_at)) {
			return false
		}
		if _, ok := match_backtrack(c, backtrack, {.Coverage, at + 6, {}, at}); !ok {
			return false
		}
		if _, ok := match_lookahead(c, lookahead, {.Coverage, ahead_at + 2, {}, at}, s.idx + 1); !ok {
			return false
		}
		g := ft.read_u16(d, subst_at + 2 + 2 * covered)
		set_glyph_class(c, g)
		s.info[s.idx].glyph = g
		return true
	}
	return false
}

// Replaces matched glyphs with a ligature, keeping track of which of its
// components the marks among and after them belong to (for GPOS mark to
// ligature attachment). A base with marks ligates into a base, marks into
// a mark (keeping their ligature id).
@(private)
ligate :: proc(c: ^Apply_Context, count: int, m: ^Matched, lig_glyph: u16) {
	s := c.s
	merge_clusters(s, s.idx, m.end)
	is_base_ligature := is_base_glyph(s.info[m.positions[0]])
	is_mark_ligature := is_mark(s.info[m.positions[0]])
	for i in 1 ..< count {
		if !is_mark(s.info[m.positions[i]]) {
			is_base_ligature, is_mark_ligature = false, false
			break
		}
	}
	is_lig := !is_base_ligature && !is_mark_ligature
	class: u16 = GLYPH_LIGATURE if is_lig else 0
	id: u8 = allocate_lig_id(s) if is_lig else 0
	first := &s.info[s.idx]
	last_id := lig_id(first^)
	last_num_comps := lig_num_comps(first^)
	comps_so_far := last_num_comps
	if is_lig {
		set_lig_for_ligature(first, id, u8(m.component_count))
		if gc_of(first^) == .Mn {
			first.unicode = u16(General_Category.Lo) | first.unicode & (0xFF &~ UPROP_GC)
		}
	}
	set_glyph_class(c, lig_glyph, class, ligature = true)
	replace_glyph(s, lig_glyph)
	for i in 1 ..< count {
		for s.idx < m.positions[i] && s.ok {
			if is_lig {
				cur := &s.info[s.idx]
				this_comp := lig_comp(cur^)
				if this_comp == 0 {
					this_comp = last_num_comps
				}
				set_lig_for_mark(cur, id, comps_so_far - last_num_comps + min(this_comp, last_num_comps))
			}
			next_glyph(s)
		}
		last_id = lig_id(s.info[s.idx])
		last_num_comps = lig_num_comps_in_ligation(s.info[s.idx])
		comps_so_far += last_num_comps
		// Skip the component itself.
		s.idx += 1
	}
	if !is_mark_ligature && last_id != 0 {
		// Marks after the last component that belonged to it move to the
		// ligature's components.
		for i in s.idx ..< s.len {
			info := &s.info[i]
			if lig_id(info^) != last_id {
				break
			}
			this_comp := lig_comp(info^)
			if this_comp == 0 {
				break
			}
			set_lig_for_mark(info, id, comps_so_far - last_num_comps + min(this_comp, last_num_comps))
		}
	}
}
