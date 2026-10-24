package shape

import ft "../font"

// Applying lookups: the context of one table's pass, the iterator that
// steps over glyphs a lookup ignores, matching glyph sequences (input,
// backtrack, lookahead) and running the lookups a context rule names.
// Follows HarfBuzz's hb-ot-layout-gsubgpos.hh closely, since its choices
// (how ligatures track their marks, how nested lookups move the matched
// positions) decide what fonts are made to expect.

// Context rules match at most this many glyphs.
@(private)
MAX_CONTEXT :: 64

Apply_Context :: struct {
	s:                       ^Shaper,
	plan:                    ^Plan,
	layout:                  ^Layout,
	face:                    ^ft.Face,
	d:                       []u8,
	kind:                    Table_Kind,
	direction:               Direction,
	lookup_index:            int,
	lookup_mask:             u32,
	lookup_props:            u32,
	flags:                   Feature_Flags,
	nesting_left:            int,
	// GDEF has glyph classes: substituted glyphs take theirs.
	has_glyph_classes:       bool,
	// The base the last mark attached to, found searching back from
	// `last_base_until` (so marks after one base search it once).
	last_base, last_base_until: int,
	// The glyphs in the buffer (added to as GSUB substitutes): lookups
	// none of them can start are skipped whole.
	digest:                  Digest,
}

// How a rule's values match glyphs: glyph ids, classes of a class
// definition, or coverage tables (offsets from `base`).
Match_Kind :: enum u8 {
	None,
	Glyph,
	Class,
	Coverage,
}

Matcher :: struct {
	kind:    Match_Kind,
	// Where the rule's 16-bit values lie.
	values:  int,
	classes: Unpacked,
	base:    int,
}

@(private)
match_value :: proc(c: ^Apply_Context, m: ^Matcher, i: int, g: u16) -> bool {
	v := ft.read_u16(c.d, m.values + 2 * i)
	switch m.kind {
	case .None:
		return true
	case .Glyph:
		return g == v
	case .Class:
		return unpacked_class(c.layout, m.classes, g) == int(v)
	case .Coverage:
		return coverage_index(c.d, m.base + int(v), g) >= 0
	}
	return false
}

// Whether a lookup with `props` sees the glyph at all (ignore flags, mark
// filtering set, mark attachment type).
@(private)
check_glyph_property :: proc(c: ^Apply_Context, info: Glyph_Info, props: u32) -> bool {
	gp := u32(info.props)
	if gp & props & LOOKUP_IGNORE_FLAGS != 0 {
		return false
	}
	if gp & GLYPH_MARK != 0 {
		if props & LOOKUP_USE_MARK_FILTERING_SET != 0 {
			return mark_set_covers(c.layout, int(props >> 16), info.glyph)
		}
		if props & LOOKUP_MARK_ATTACHMENT_TYPE != 0 {
			return props & LOOKUP_MARK_ATTACHMENT_TYPE == gp & LOOKUP_MARK_ATTACHMENT_TYPE
		}
	}
	return true
}

// ---- skipping iterator --------------------------------------------------------------

@(private)
Skip :: enum u8 {
	No,
	Yes,
	Maybe,
}

@(private)
Step :: enum u8 {
	Match,
	Not_Match,
	Skip,
}

// Steps over the glyphs a lookup ignores, matching the rest against a
// rule's values in order.
Skippy :: struct {
	c:             ^Apply_Context,
	idx:           int,
	end:           int,
	lookup_props:  u32,
	mask:          u32,
	syllable:      u8,
	ignore_zwnj:   bool,
	ignore_zwj:    bool,
	ignore_hidden: bool,
	matcher:       Matcher,
	// The rule value the next match compares against.
	value:         int,
}

// An iterator over the input (`context_match` false: the lookup's mask,
// joiners per the lookup) or over context (any mask, joiners skipped).
// A per-syllable lookup matches within the current glyph's syllable.
@(private)
skippy_init :: proc(c: ^Apply_Context, start: int, context_match: bool) -> Skippy {
	it := Skippy {
		c             = c,
		idx           = start,
		end           = c.s.len,
		lookup_props  = c.lookup_props,
		mask          = 0xFFFFFFFF if context_match else c.lookup_mask,
		ignore_zwnj   = c.kind == .GPOS || (context_match && .Manual_ZWNJ not_in c.flags),
		ignore_zwj    = context_match || .Manual_ZWJ not_in c.flags,
		ignore_hidden = c.kind == .GPOS,
	}
	if c.kind == .GSUB && .Per_Syllable in c.flags && c.s.idx < c.s.len {
		it.syllable = c.s.info[c.s.idx].syllable
	}
	return it
}

@(private)
may_skip :: proc(it: ^Skippy, info: Glyph_Info) -> Skip {
	if !check_glyph_property(it.c, info, it.lookup_props) {
		return .Yes
	}
	if is_ignorable(info) && (it.ignore_zwnj || !is_zwnj(info)) && (it.ignore_zwj || !is_zwj(info)) && (it.ignore_hidden || !is_hidden(info)) {
		return .Maybe
	}
	return .No
}

@(private)
step :: proc(it: ^Skippy, info: Glyph_Info) -> Step {
	skip := may_skip(it, info)
	if skip == .Yes {
		return .Skip
	}
	// Mask and syllable must fit; then the value, when there is one.
	matched: Skip = .Maybe
	if info.mask & it.mask == 0 || (it.syllable != 0 && it.syllable != info.syllable) {
		matched = .No
	} else if it.matcher.kind != .None {
		matched = .Yes if match_value(it.c, &it.matcher, it.value, info.glyph) else .No
	}
	if matched == .Yes || (matched == .Maybe && skip == .No) {
		return .Match
	}
	if skip == .No {
		return .Not_Match
	}
	return .Skip
}

// Moves to the next glyph that matches; false at one that doesn't.
@(private)
skippy_next :: proc(it: ^Skippy) -> bool {
	s := it.c.s
	for it.idx < it.end - 1 {
		it.idx += 1
		switch step(it, s.info[it.idx]) {
		case .Match:
			it.value += 1
			return true
		case .Not_Match:
			return false
		case .Skip:
		}
	}
	return false
}

// Moves to the previous output glyph that matches.
@(private)
skippy_prev :: proc(it: ^Skippy) -> bool {
	out := out_rows(it.c.s)
	for it.idx > 0 {
		it.idx -= 1
		switch step(it, out[it.idx]) {
		case .Match:
			it.value += 1
			return true
		case .Not_Match:
			return false
		case .Skip:
		}
	}
	return false
}

// ---- matching sequences -------------------------------------------------------------

// The matched input: each glyph's position, one past the last, and the
// ligature components they hold.
Matched :: struct {
	positions:       [MAX_CONTEXT]int,
	end:             int,
	component_count: int,
}

// Matches `count` glyphs at the current one (the first already matched
// by coverage; `m` matches the rest). A sequence may not mix marks of
// different ligature components, unless the ligature is ignored.
@(private)
match_input :: proc(c: ^Apply_Context, count: int, m: Matcher, out: ^Matched) -> bool {
	if count > MAX_CONTEXT {
		return false
	}
	s := c.s
	it := skippy_init(c, s.idx, false)
	it.matcher = m
	Ligbase :: enum u8 {
		Not_Checked,
		May_Not_Skip,
		May_Skip,
	}
	ligbase := Ligbase.Not_Checked
	first := s.info[s.idx]
	first_id, first_comp := lig_id(first), lig_comp(first)
	total := 0
	out.positions[0] = s.idx
	for i in 1 ..< count {
		if !skippy_next(&it) {
			out.end = it.idx + 1
			return false
		}
		out.positions[i] = it.idx
		this := s.info[it.idx]
		this_id, this_comp := lig_id(this), lig_comp(this)
		if first_id != 0 && first_comp != 0 {
			// Attached to a component of an earlier ligature: the rest must
			// be attached to the same one, unless that ligature is ignored.
			if first_id != this_id || first_comp != this_comp {
				if ligbase == .Not_Checked {
					found := false
					o := out_rows(s)
					j := s.out_len
					for j > 0 && lig_id(o[j - 1]) == first_id {
						j -= 1
						if lig_comp(o[j]) == 0 {
							found = true
							break
						}
					}
					ligbase = .May_Skip if found && may_skip(&it, o[j]) == .Yes else .May_Not_Skip
				}
				if ligbase == .May_Not_Skip {
					return false
				}
			}
		} else if this_id != 0 && this_comp != 0 && this_id != first_id {
			// Else none may be attached to another ligature's component.
			return false
		}
		total += int(lig_num_comps_in_ligation(this))
	}
	out.end = it.idx + 1
	out.component_count = total + int(lig_num_comps(first))
	return true
}

// Matches `count` glyphs before the current one (in the output); where
// the first of them lies.
@(private)
match_backtrack :: proc(c: ^Apply_Context, count: int, m: Matcher) -> (start: int, ok: bool) {
	s := c.s
	it := skippy_init(c, s.out_len if s.have_output else s.idx, true)
	it.matcher = m
	for _ in 0 ..< count {
		if !skippy_prev(&it) {
			return 0, false
		}
	}
	return it.idx, true
}

// Matches `count` glyphs from `start` on; one past the last.
@(private)
match_lookahead :: proc(c: ^Apply_Context, count: int, m: Matcher, start: int) -> (end: int, ok: bool) {
	it := skippy_init(c, start - 1, true)
	it.matcher = m
	for _ in 0 ..< count {
		if !skippy_next(&it) {
			return 0, false
		}
	}
	return it.idx + 1, true
}

// ---- context rules ------------------------------------------------------------------

// A rule: its input (count glyphs including the first, the rest matched
// by `input`), optional backtrack and lookahead, and the lookups to apply
// (`records` sequence index / lookup index pairs).
@(private)
Rule :: struct {
	input_count:     int,
	input:           Matcher,
	backtrack_count: int,
	backtrack:       Matcher,
	lookahead_count: int,
	lookahead:       Matcher,
	records:         int,
	record_count:    int,
}

// Applies a rule at the current glyph: matches it, then its lookups.
@(private)
apply_rule :: proc(c: ^Apply_Context, r: ^Rule) -> bool {
	// Every field read is written by match_input.
	m: Matched = ---
	if !match_input(c, r.input_count, r.input, &m) {
		return false
	}
	if r.lookahead_count > 0 {
		if _, ok := match_lookahead(c, r.lookahead_count, r.lookahead, m.end); !ok {
			return false
		}
	}
	if r.backtrack_count > 0 {
		if _, ok := match_backtrack(c, r.backtrack_count, r.backtrack); !ok {
			return false
		}
	}
	apply_records(c, r.input_count, &m, r.records, r.record_count)
	return true
}

// Runs a rule's lookups at their matched positions, keeping the positions
// right as nested lookups add or remove glyphs.
@(private)
apply_records :: proc(c: ^Apply_Context, input_count: int, m: ^Matched, records, record_count: int) {
	s := c.s
	count := input_count
	pos := &m.positions
	// Positions count from the start of the output.
	bl := s.out_len if s.have_output else s.idx
	end := bl + m.end - s.idx
	for j in 0 ..< count {
		pos[j] += bl - s.idx
	}
	for i in 0 ..< record_count {
		if !s.ok {
			break
		}
		rec := records + 4 * i
		idx := int(ft.read_u16(c.d, rec))
		lookup := int(ft.read_u16(c.d, rec + 2))
		if idx >= count {
			continue
		}
		orig_len := (s.out_len if s.have_output else s.idx) + s.len - s.idx
		if pos[idx] >= orig_len {
			continue
		}
		if !move_to(s, pos[idx]) {
			break
		}
		if s.max_ops <= 0 {
			break
		}
		if !recurse(c, lookup) {
			continue
		}
		new_len := (s.out_len if s.have_output else s.idx) + s.len - s.idx
		delta := new_len - orig_len
		if delta == 0 {
			continue
		}
		// The nested lookup changed the length: glyphs added are taken to
		// follow the current position, glyphs removed the positions after it.
		end += delta
		if end < pos[idx] {
			delta += pos[idx] - end
			end = pos[idx]
		}
		next := idx + 1
		if delta > 0 {
			if delta + count > MAX_CONTEXT {
				break
			}
		} else {
			delta = max(delta, next - count)
			next -= delta
		}
		copy(pos[next + delta:count + delta], pos[next:count])
		next += delta
		count += delta
		for j in idx + 1 ..< next {
			pos[j] = pos[j - 1] + 1
		}
		for ; next < count; next += 1 {
			pos[next] += delta
		}
	}
	move_to(s, end)
}

// Applies lookup `index` at the current glyph from within a rule.
@(private)
recurse :: proc(c: ^Apply_Context, index: int) -> bool {
	s := c.s
	t := &c.layout.tables[c.kind]
	if c.nesting_left == 0 || index >= len(t.lookups) {
		return false
	}
	s.max_ops -= 1
	if s.max_ops < 0 {
		return false
	}
	saved_props, saved_index := c.lookup_props, c.lookup_index
	lookup := &t.lookups[index]
	c.lookup_props = lookup.props
	c.lookup_index = index
	c.nesting_left -= 1
	applied := apply_at(c, lookup)
	c.nesting_left += 1
	c.lookup_props, c.lookup_index = saved_props, saved_index
	return applied
}

// Applies a lookup's first subtable that applies at the current glyph.
@(private)
apply_at :: proc(c: ^Apply_Context, lookup: ^Lookup) -> bool {
	t := &c.layout.tables[c.kind]
	g := c.s.info[c.s.idx].glyph
	for &sub in t.subtables[lookup.first:][:lookup.count] {
		if !digest_may_have(&sub.digest, g) {
			continue
		}
		covered := unpacked_coverage(c.layout, sub.coverage, g)
		if covered < 0 {
			continue
		}
		applied: bool
		if c.kind == .GSUB {
			applied = gsub_apply(c, lookup.type, &sub, covered)
		} else {
			applied = gpos_apply(c, lookup.type, &sub, covered)
		}
		if applied {
			return true
		}
	}
	return false
}

// Context subtables (GSUB 5, GPOS 7) and chained ones (GSUB 6, GPOS 8);
// `covered` is the first glyph's coverage index.
@(private)
apply_context :: proc(c: ^Apply_Context, sub: ^Subtable, covered: int, chain: bool) -> bool {
	d := c.d
	s := c.s
	g := s.info[s.idx].glyph
	at := int(sub.at)
	switch ft.read_u16(d, at) {
	case 1, 2:
		format2 := ft.read_u16(d, at) == 2
		// Format 1 rule sets by coverage index, glyph values; format 2 by
		// the first glyph's class, class values.
		set_index := covered
		backtrack_classes, input_classes, lookahead_classes: Unpacked
		sets := at + 4
		if format2 {
			backtrack_classes, input_classes, lookahead_classes = sub.classes[0], sub.classes[1], sub.classes[2]
			sets = at + (10 if chain else 6)
			set_index = unpacked_class(c.layout, input_classes, g)
		}
		if set_index >= int(ft.read_u16(d, sets)) {
			return false
		}
		set := offset16(d, at, sets + 2 + 2 * set_index)
		if set == 0 {
			return false
		}
		kind: Match_Kind = .Class if format2 else .Glyph
		rule_count := int(ft.read_u16(d, set))
		for i in 0 ..< rule_count {
			rule := offset16(d, set, set + 2 + 2 * i)
			if rule == 0 {
				continue
			}
			r: Rule
			if chain {
				p := rule
				r.backtrack_count = int(ft.read_u16(d, p))
				r.backtrack = {kind, p + 2, backtrack_classes, 0}
				p += 2 + 2 * r.backtrack_count
				r.input_count = int(ft.read_u16(d, p))
				r.input = {kind, p + 2, input_classes, 0}
				p += 2 * max(r.input_count, 1)
				r.lookahead_count = int(ft.read_u16(d, p))
				r.lookahead = {kind, p + 2, lookahead_classes, 0}
				p += 2 + 2 * r.lookahead_count
				r.record_count = int(ft.read_u16(d, p))
				r.records = p + 2
			} else {
				r.input_count = int(ft.read_u16(d, rule))
				r.record_count = int(ft.read_u16(d, rule + 2))
				r.input = {kind, rule + 4, input_classes, 0}
				r.records = rule + 4 + 2 * max(r.input_count - 1, 0)
			}
			if r.input_count == 0 {
				continue
			}
			if apply_rule(c, &r) {
				return true
			}
		}
	case 3:
		r: Rule
		if chain {
			p := at + 2
			r.backtrack_count = int(ft.read_u16(d, p))
			r.backtrack = {.Coverage, p + 2, {}, at}
			p += 2 + 2 * r.backtrack_count
			r.input_count = int(ft.read_u16(d, p))
			// The first input coverage matched already.
			r.input = {.Coverage, p + 4, {}, at}
			p += 2 + 2 * r.input_count
			r.lookahead_count = int(ft.read_u16(d, p))
			r.lookahead = {.Coverage, p + 2, {}, at}
			p += 2 + 2 * r.lookahead_count
			r.record_count = int(ft.read_u16(d, p))
			r.records = p + 2
		} else {
			r.input_count = int(ft.read_u16(d, at + 2))
			r.record_count = int(ft.read_u16(d, at + 4))
			r.input = {.Coverage, at + 8, {}, at}
			r.records = at + 6 + 2 * r.input_count
		}
		if r.input_count == 0 {
			return false
		}
		return apply_rule(c, &r)
	}
	return false
}
