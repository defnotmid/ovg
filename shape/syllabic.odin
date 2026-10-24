package shape

import ft "../font"

// What the syllable-based shapers (Indic, Khmer, Myanmar, USE) share: a
// state machine splits the text into syllables by the characters'
// categories (HarfBuzz's ragel machines, as tables in syllable_data.odin),
// broken syllables get a dotted circle to hang on, features apply within
// a syllable, and reordering asks whether a feature would substitute a
// sequence.

Machine_Op :: enum u8 {
	None,
	// te = p + 1.
	Te_Next,
	// A syllable ends after p, at p, or at te (the action's type).
	Emit_Next,
	Emit_Current,
	Emit_Te,
	// te = p + 1, remembering which pattern matched (act).
	Act,
	// A syllable ends at te, its type the remembered pattern's.
	Act_Switch,
}

Machine_Action :: struct {
	op:  Machine_Op,
	arg: u8,
}

// A ragel scanner's tables: per state its key range and transitions, the
// actions on each transition, and those taken entering and leaving states.
Machine :: struct {
	trans_keys:         []i16,
	key_spans:          []i16,
	index_offsets:      []i16,
	indicies:           []i16,
	trans_targs:        []i16,
	trans_actions:      []i16,
	to_state_actions:   []i16,
	from_state_actions: []i16,
	eof_trans:          []i16,
	actions:            []Machine_Action,
	act_types:          []i8,
	start:              int,
	// The state action values that set ts to p, and clear it.
	from_ts, to_ts:     int,
	// The broken cluster's syllable type.
	broken:             int,
}

Vowel_Constraint :: struct {
	script: Script,
	chars:  [3]rune,
}

// Runs a syllable machine over categories `cats`, writing each position's
// syllable (serial << 4 | type, serials 1 ..= 15 cycling) to `out`; true
// when a broken cluster was found.
@(private)
run_machine :: proc(m: ^Machine, cats: []u8, out: []u8) -> (broken: bool) {
	p, pe := 0, len(cats)
	ts, te, act := 0, 0, 0
	cs := m.start
	serial := 1
	found :: proc(m: ^Machine, out: []u8, ts, te, type: int, serial: ^int, broken: ^bool) {
		for i in max(ts, 0) ..< min(te, len(out)) {
			out[i] = u8(serial^ << 4 | type)
		}
		serial^ += 1
		if serial^ == 16 {
			serial^ = 1
		}
		if type == m.broken {
			broken^ = true
		}
	}
	for p <= pe {
		trans: int
		if p < pe {
			if int(m.from_state_actions[cs]) == m.from_ts {
				ts = p
			}
			keys := cs << 1
			span := int(m.key_spans[cs])
			c := int(cats[p])
			lo, hi := int(m.trans_keys[keys]), int(m.trans_keys[keys + 1])
			k := c - lo if span > 0 && lo <= c && c <= hi else span
			trans = int(m.indicies[int(m.index_offsets[cs]) + k])
		} else {
			// At the end: the state's end-of-input transition, if any.
			if m.eof_trans[cs] <= 0 {
				break
			}
			trans = int(m.eof_trans[cs]) - 1
		}
		cs = int(m.trans_targs[trans])
		if a := int(m.trans_actions[trans]); a != 0 && a < len(m.actions) {
			action := m.actions[a]
			switch action.op {
			case .None:
			case .Te_Next:
				te = p + 1
			case .Emit_Next:
				te = p + 1
				found(m, out, ts, te, int(action.arg), &serial, &broken)
			case .Emit_Current:
				te = p
				p -= 1
				found(m, out, ts, te, int(action.arg), &serial, &broken)
			case .Emit_Te:
				p = te - 1
				found(m, out, ts, te, int(action.arg), &serial, &broken)
			case .Act:
				te = p + 1
				act = int(action.arg)
			case .Act_Switch:
				if act < len(m.act_types) && m.act_types[act] >= 0 {
					p = te - 1
					found(m, out, ts, te, int(m.act_types[act]), &serial, &broken)
				}
			}
		}
		if int(m.to_state_actions[cs]) == m.to_ts {
			ts = 0
		}
		p += 1
	}
	return
}

// The end of the syllable starting at `start`.
@(private)
next_syllable :: #force_inline proc "contextless" (s: ^Shaper, start: int) -> int {
	end := start + 1
	for end < s.len && s.info[end].syllable == s.info[start].syllable {
		end += 1
	}
	return end
}

// Gives broken syllables (of type `broken`) a dotted circle to sit on,
// after a leading repha (`repha` category; -1 for none): a row with the
// dotted circle's glyph, `category` and `position` (-1 to leave 0). False
// when nothing was inserted.
@(private)
insert_dotted_circles :: proc(s: ^Shaper, f: ^ft.Face, broken: int, category: u8, repha: int, position: int) -> bool {
	if .Has_Broken_Syllable not_in s.flags {
		return false
	}
	g, ok := nominal_glyph(f, 0x25CC)
	if !ok {
		return false
	}
	circle := Glyph_Info{char = 0x25CC, glyph = g, category = category}
	if position >= 0 {
		circle.aux = u8(position)
	}
	clear_output(s)
	last: u8 = 0
	for s.idx < s.len && s.ok {
		syllable := s.info[s.idx].syllable
		if last != syllable && int(syllable & 0x0F) == broken {
			last = syllable
			row := circle
			row.cluster = s.info[s.idx].cluster
			row.mask = s.info[s.idx].mask
			row.syllable = syllable
			if repha >= 0 {
				for s.idx < s.len && s.ok && s.info[s.idx].syllable == last && int(s.info[s.idx].category) == repha {
					next_glyph(s)
				}
			}
			if !make_room_for(s, 0, 1) {
				break
			}
			out_rows(s)[s.out_len] = row
			s.out_len += 1
		} else {
			next_glyph(s)
		}
	}
	swap_buffers(s)
	return true
}

@(private)
clear_substitution_flags :: proc(s: ^Shaper) {
	for &info in s.info[:s.len] {
		info.props &~= GLYPH_SUBSTITUTED
	}
}

// Whether any of the plan's GSUB lookups in `stage` would substitute the
// glyph sequence (as a whole: no glyphs skipped; with zero context, rules
// needing backtrack or lookahead don't count).
@(private)
would_substitute :: proc(plan: ^Plan, stage: int, glyphs: []u16, zero_context: bool) -> bool {
	if stage < 0 || stage >= len(plan.stages[.GSUB]) || len(glyphs) == 0 {
		return false
	}
	l := plan.layout
	first := 0 if stage == 0 else int(plan.stages[.GSUB][stage - 1].end)
	end := int(plan.stages[.GSUB][stage].end)
	for pl in plan.lookups[.GSUB][first:end] {
		lookup := &l.tables[.GSUB].lookups[pl.index]
		if !digest_may_have(&lookup.digest, glyphs[0]) {
			continue
		}
		for sub in l.tables[.GSUB].subtables[lookup.first:][:lookup.count] {
			if subtable_would_apply(l.data, lookup.type, int(sub.at), glyphs, zero_context) {
				return true
			}
		}
	}
	return false
}

@(private)
subtable_would_apply :: proc(d: []u8, type: u8, at: int, glyphs: []u16, zero_context: bool) -> bool {
	n := len(glyphs)
	format := ft.read_u16(d, at)
	switch type {
	case GSUB_SINGLE, GSUB_MULTIPLE, GSUB_ALTERNATE, GSUB_REVERSE_CHAIN:
		return n == 1 && coverage_index(d, offset16(d, at, at + 2), glyphs[0]) >= 0
	case GSUB_LIGATURE:
		covered := coverage_index(d, offset16(d, at, at + 2), glyphs[0])
		if covered < 0 || covered >= int(ft.read_u16(d, at + 4)) {
			return false
		}
		set := offset16(d, at, at + 6 + 2 * covered)
		count := int(ft.read_u16(d, set))
		for i in 0 ..< count {
			lig := offset16(d, set, set + 2 + 2 * i)
			if int(ft.read_u16(d, lig + 2)) != n {
				continue
			}
			same := true
			for k in 1 ..< n {
				if ft.read_u16(d, lig + 4 + 2 * (k - 1)) != glyphs[k] {
					same = false
					break
				}
			}
			if same {
				return true
			}
		}
	case GSUB_CONTEXT, GSUB_CHAIN_CONTEXT:
		chain := type == GSUB_CHAIN_CONTEXT
		switch format {
		case 1, 2:
			set_index: int
			input_classes := 0
			sets := at + 4
			if format == 1 {
				set_index = coverage_index(d, offset16(d, at, at + 2), glyphs[0])
				if set_index < 0 {
					return false
				}
			} else {
				input_classes = offset16(d, at, at + (6 if chain else 4))
				sets = at + (10 if chain else 6)
				set_index = class_of(d, input_classes, glyphs[0])
			}
			if set_index >= int(ft.read_u16(d, sets)) {
				return false
			}
			set := offset16(d, at, sets + 2 + 2 * set_index)
			if set == 0 {
				return false
			}
			rules := int(ft.read_u16(d, set))
			for i in 0 ..< rules {
				rule := offset16(d, set, set + 2 + 2 * i)
				if rule == 0 {
					continue
				}
				p := rule
				backtrack, lookahead := 0, 0
				if chain {
					backtrack = int(ft.read_u16(d, p))
					p += 2 + 2 * backtrack
				}
				count := int(ft.read_u16(d, p))
				input := p + (2 if chain else 4)
				if chain {
					lookahead = int(ft.read_u16(d, input + 2 * max(count - 1, 0)))
				}
				if zero_context && (backtrack > 0 || lookahead > 0) {
					continue
				}
				if would_match(d, count, input, int(format), input_classes, at, glyphs) {
					return true
				}
			}
		case 3:
			backtrack, lookahead := 0, 0
			count: int
			input: int
			if chain {
				backtrack = int(ft.read_u16(d, at + 2))
				p := at + 4 + 2 * backtrack
				count = int(ft.read_u16(d, p))
				input = p + 4
				lookahead = int(ft.read_u16(d, p + 2 + 2 * count))
			} else {
				count = int(ft.read_u16(d, at + 2))
				input = at + 8
			}
			if zero_context && (backtrack > 0 || lookahead > 0) {
				return false
			}
			return would_match(d, count, input, 3, 0, at, glyphs)
		}
	}
	return false
}

// Whether glyphs[1:] match a rule's input values (glyphs, classes or
// coverages from `base`), the rule being exactly as long.
@(private)
would_match :: proc(d: []u8, count, values, format, classes, base: int, glyphs: []u16) -> bool {
	if count != len(glyphs) {
		return false
	}
	for k in 1 ..< count {
		v := ft.read_u16(d, values + 2 * (k - 1))
		g := glyphs[k]
		switch format {
		case 1:
			if g != v {
				return false
			}
		case 2:
			if class_of(d, classes, g) != int(v) {
				return false
			}
		case 3:
			if coverage_index(d, base + int(v), g) < 0 {
				return false
			}
		}
	}
	return true
}

// The GSUB stage a feature's lookups are in (-1 when it has none).
@(private)
feature_stage :: proc(plan: ^Plan, name: string) -> int {
	t := tag(name)
	for f in plan.features {
		if f.tag == t {
			return int(f.gsub_stage)
		}
	}
	return -1
}

// Dotted circles in vowel sequences that would look like another vowel
// (the script's sequences in VOWEL_CONSTRAINTS): before the sequence's
// last character.
@(private)
vowel_constraints :: proc(s: ^Shaper, script: Script) {
	first, end := -1, -1
	for c, i in VOWEL_CONSTRAINTS {
		if c.script == script {
			if first < 0 {
				first = i
			}
			end = i + 1
		}
	}
	if first < 0 {
		return
	}
	table := VOWEL_CONSTRAINTS[first:end]
	count := s.len
	clear_output(s)
	for s.idx + 1 < count && s.ok {
		r := s.info[s.idx].char
		matched := false
		for c in table {
			if c.chars[0] != r || c.chars[1] != s.info[s.idx + 1].char {
				continue
			}
			if c.chars[2] == 0 {
				matched = true
				break
			}
			if s.idx + 2 < count && c.chars[2] == s.info[s.idx + 2].char {
				next_glyph(s)
				matched = true
				break
			}
		}
		next_glyph(s)
		if matched && s.idx < s.len {
			// A copy of the next character's row, as a dotted circle.
			if !make_room_for(s, 0, 1) {
				break
			}
			out := out_rows(s)
			out[s.out_len] = s.info[s.idx]
			out[s.out_len].char = 0x25CC
			out[s.out_len].unicode &~= UPROP_CONTINUATION
			s.out_len += 1
			next_glyph(s)
		}
	}
	swap_buffers(s)
}
