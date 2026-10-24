package shape

import ft "../font"

// Arabic (and Syriac): each letter takes its joining form (isol, fina,
// fin2, fin3, medi, med2, init) from its joining type and its neighbours'
// (a state machine over the text, transparent marks skipped), each form a
// feature applied in its own stage. Then rlig, calt and the rest; marks
// that modify a letter (hamza above...) move before the other marks.

// The joining forms, by the action the joining state machine gives a
// glyph (Glyph_Info.aux; ARABIC_NONE takes none).
@(private, rodata)
ARABIC_FEATURES := [7]string{"isol", "fina", "fin2", "fin3", "medi", "med2", "init"}

@(private)
ARABIC_ISOL :: 0
@(private)
ARABIC_FINA :: 1
@(private)
ARABIC_FIN2 :: 2
@(private)
ARABIC_FIN3 :: 3
@(private)
ARABIC_MEDI :: 4
@(private)
ARABIC_MED2 :: 5
@(private)
ARABIC_INIT :: 6
@(private)
ARABIC_NONE :: 7
// stch: a multiplied glyph's pieces, tiled to fill the space after
// positioning (fixed pieces once, repeating pieces as often as needed).
@(private)
ARABIC_STCH_FIXED :: 8
@(private)
ARABIC_STCH_REPEATING :: 9
// A stretch makes at most this many glyphs (HarfBuzz's limit).
@(private)
ARABIC_STCH_MAX_GLYPHS :: 256

// The joining state machine: per state and joining class (U, L, R, D,
// Alaph, Dalath-Rish), the action for the previous glyph, the action for
// this one, and the next state.
@(private)
Arabic_Entry :: struct {
	prev, this, next: u8,
}

@(private, rodata)
ARABIC_STATES := [7][6]Arabic_Entry {
	// 0: initial state, nothing before.
	{{ARABIC_NONE, ARABIC_NONE, 0}, {ARABIC_NONE, ARABIC_ISOL, 2}, {ARABIC_NONE, ARABIC_ISOL, 1}, {ARABIC_NONE, ARABIC_ISOL, 2}, {ARABIC_NONE, ARABIC_ISOL, 1}, {ARABIC_NONE, ARABIC_ISOL, 6}},
	// 1: after an R (or Alaph) that can't join forward.
	{{ARABIC_NONE, ARABIC_NONE, 0}, {ARABIC_NONE, ARABIC_ISOL, 2}, {ARABIC_NONE, ARABIC_ISOL, 1}, {ARABIC_NONE, ARABIC_ISOL, 2}, {ARABIC_NONE, ARABIC_FIN2, 5}, {ARABIC_NONE, ARABIC_ISOL, 6}},
	// 2: after a D or L that can join forward.
	{{ARABIC_NONE, ARABIC_NONE, 0}, {ARABIC_NONE, ARABIC_ISOL, 2}, {ARABIC_INIT, ARABIC_FINA, 1}, {ARABIC_INIT, ARABIC_FINA, 3}, {ARABIC_INIT, ARABIC_FINA, 4}, {ARABIC_INIT, ARABIC_FINA, 6}},
	// 3: after a D in the middle of a word.
	{{ARABIC_NONE, ARABIC_NONE, 0}, {ARABIC_NONE, ARABIC_ISOL, 2}, {ARABIC_MEDI, ARABIC_FINA, 1}, {ARABIC_MEDI, ARABIC_FINA, 3}, {ARABIC_MEDI, ARABIC_FINA, 4}, {ARABIC_MEDI, ARABIC_FINA, 6}},
	// 4: after a joined Alaph.
	{{ARABIC_NONE, ARABIC_NONE, 0}, {ARABIC_NONE, ARABIC_ISOL, 2}, {ARABIC_MED2, ARABIC_ISOL, 1}, {ARABIC_MED2, ARABIC_ISOL, 2}, {ARABIC_MED2, ARABIC_FIN2, 5}, {ARABIC_MED2, ARABIC_ISOL, 6}},
	// 5: after a non-joining Alaph.
	{{ARABIC_NONE, ARABIC_NONE, 0}, {ARABIC_NONE, ARABIC_ISOL, 2}, {ARABIC_ISOL, ARABIC_ISOL, 1}, {ARABIC_ISOL, ARABIC_ISOL, 2}, {ARABIC_ISOL, ARABIC_FIN2, 5}, {ARABIC_ISOL, ARABIC_ISOL, 6}},
	// 6: after a Dalath-Rish.
	{{ARABIC_NONE, ARABIC_NONE, 0}, {ARABIC_NONE, ARABIC_ISOL, 2}, {ARABIC_NONE, ARABIC_ISOL, 1}, {ARABIC_NONE, ARABIC_ISOL, 2}, {ARABIC_NONE, ARABIC_FIN3, 5}, {ARABIC_NONE, ARABIC_ISOL, 6}},
}

@(private)
arabic_collect_features :: proc(p: ^Planner) {
	// stch first (its own stage, so its multiplied glyphs can be marked),
	// then ccmp and locl with joiners seen, then each joining form in a
	// stage of its own (fallback-capable for Arabic, not Syriac's 2 and 3).
	enable_feature(p, "stch")
	add_pause(p, .GSUB, .Arabic_Stch)
	enable_feature(p, "ccmp", {.Manual_ZWJ})
	enable_feature(p, "locl", {.Manual_ZWJ})
	add_pause(p, .GSUB)
	for name in ARABIC_FEATURES {
		flags: Feature_Flags = {.Manual_ZWJ}
		if p.plan.script == .Arabic && name[3] != '2' && name[3] != '3' {
			flags += {.Has_Fallback}
		}
		add_feature(p, name, flags)
		add_pause(p, .GSUB)
	}
	add_pause(p, .GSUB)
	// In Arabic a ZWJ also means "don't ligate", so the ligating features
	// see joiners.
	enable_feature(p, "rlig", {.Manual_ZWJ, .Has_Fallback})
	if p.plan.script == .Arabic {
		add_pause(p, .GSUB)
	}
	enable_feature(p, "calt", {.Manual_ZWJ})
	if !has_feature(p, "rclt") {
		add_pause(p, .GSUB)
	}
	enable_feature(p, "liga", {.Manual_ZWJ})
	enable_feature(p, "clig", {.Manual_ZWJ})
	enable_feature(p, "mset", {.Manual_ZWJ})
}

// The joining class of a character: its column in ARABIC_STATES, -1 for
// transparent (marks and format characters skipped by joining).
@(private)
joining_class :: proc(r: rune) -> int {
	switch char_props(r).joining {
	case .U:
		return 0
	case .L:
		return 1
	case .R:
		return 2
	case .D, .C:
		return 3
	case .Alaph:
		return 4
	case .Dalath_Rish:
		return 5
	case .T:
		return -1
	}
	return 0
}

// Each glyph's joining action (Glyph_Info.aux).
@(private)
arabic_joining :: proc(s: ^Shaper, plan: ^Plan) {
	info := s.info[:s.len]
	prev := -1
	state := 0
	for &row, i in info {
		class := joining_class(row.char)
		if class < 0 {
			row.aux = ARABIC_NONE
			continue
		}
		entry := ARABIC_STATES[state][class]
		if entry.prev != ARABIC_NONE && prev >= 0 {
			info[prev].aux = entry.prev
		}
		row.aux = entry.this
		prev = i
		state = int(entry.next)
	}
	if plan.script == .Mongolian {
		// Free variation selectors take the action of what they follow.
		for i in 1 ..< len(info) {
			if (info[i].char >= 0x180B && info[i].char <= 0x180D) || info[i].char == 0x180F {
				info[i].aux = info[i - 1].aux
			}
		}
	}
}

// Marks that modify the letter they follow rather than sit on it (hamza
// above, small high seen...): moved before the other marks of their class.
@(private, rodata)
ARABIC_MODIFIER_MARKS := [?]rune{0x0654, 0x0655, 0x0658, 0x06DC, 0x06E3, 0x06E7, 0x06E8, 0x08CA, 0x08CB, 0x08CD, 0x08CE, 0x08CF, 0x08D3, 0x08F3}

@(private)
is_modifier_mark :: proc(r: rune) -> bool {
	for m in ARABIC_MODIFIER_MARKS {
		if m == r {
			return true
		}
	}
	return false
}

@(private)
arabic_reorder_marks :: proc(s: ^Shaper, start, end: int) {
	info := s.info[:]
	start := start
	i := start
	for cc in ([2]u8{220, 230}) {
		for i < end && mcc_of(info[i]) < cc {
			i += 1
		}
		if i == end {
			break
		}
		if mcc_of(info[i]) > cc {
			continue
		}
		j := i
		for j < end && mcc_of(info[j]) == cc && is_modifier_mark(info[j].char) {
			j += 1
		}
		if i == j {
			continue
		}
		// Move i ..< j to the start of the run; they take classes before
		// the other marks' (22 below, 26 above).
		n := j - i
		if n > MAX_COMBINING_MARKS {
			break
		}
		merge_clusters(s, start, j)
		moved: [MAX_COMBINING_MARKS]Glyph_Info
		copy(moved[:n], info[i:j])
		copy(info[start + n:j], info[start:i])
		copy(info[start:start + n], moved[:n])
		new_cc: u16 = 22 if cc == 220 else 26
		for k in start ..< start + n {
			info[k].unicode = info[k].unicode & 0xFF | new_cc << 8
		}
		start += n
		i = j
	}
}

// After stch's stage: its multiplied glyphs' pieces, odd components
// repeating, even ones fixed.
@(private)
arabic_record_stch :: proc(s: ^Shaper, plan: ^Plan) {
	if !plan.has_stch {
		return
	}
	for &info in s.info[:s.len] {
		if is_multiplied(info) {
			info.aux = ARABIC_STCH_REPEATING if lig_comp(info) % 2 != 0 else ARABIC_STCH_FIXED
			s.flags += {.Has_Stch}
		}
	}
}

@(private)
is_stch :: #force_inline proc "contextless" (info: Glyph_Info) -> bool {
	return info.aux == ARABIC_STCH_FIXED || info.aux == ARABIC_STCH_REPEATING
}

// Whether a glyph belongs to the word a stretch fills.
@(private)
is_word_category :: proc(gc: General_Category) -> bool {
	#partial switch gc {
	case .Cn, .Co, .Lm, .Lo, .Mc, .Me, .Mn, .Nd, .Nl, .No, .Sc, .Sk, .Sm, .So:
		return true
	}
	return false
}

// Tiles each stretched sequence over the width of the word before it (in
// visual order, right to left): measured, then cut, the repeating pieces
// copied as often as needed and overlapped to fit exactly.
@(private)
arabic_apply_stch :: proc(s: ^Shaper, f: ^ft.Face) {
	if .Has_Stch not_in s.flags {
		return
	}
	extra := 0
	for step in 0 ..< 2 {
		cut := step == 1
		new_len := s.len + extra
		i := s.len
		j := new_len
		for i > 0 {
			if !is_stch(s.info[i - 1]) {
				if cut {
					j -= 1
					s.info[j], s.pos[j] = s.info[i - 1], s.pos[i - 1]
				}
				i -= 1
				continue
			}
			w_total, w_fixed, w_repeating: i32
			n_fixed, n_repeating: i32
			end := i
			for i > 0 && is_stch(s.info[i - 1]) {
				i -= 1
				width := i32(ft.advance(f, ft.Glyph(s.info[i].glyph)))
				if s.info[i].aux == ARABIC_STCH_FIXED {
					w_fixed += width
					n_fixed += 1
				} else {
					w_repeating += width
					n_repeating += 1
				}
			}
			start := i
			context_at := i
			for context_at > 0 && !is_stch(s.info[context_at - 1]) && (is_ignorable(s.info[context_at - 1]) || is_word_category(gc_of(s.info[context_at - 1]))) {
				context_at -= 1
				w_total += s.pos[context_at].x_advance
			}
			i += 1
			n_copies: i32
			w_remaining := w_total - w_fixed
			if w_remaining > w_repeating && w_repeating > 0 {
				n_copies = w_remaining / w_repeating - 1
			}
			overlap: i32
			shortfall := w_remaining - w_repeating * (n_copies + 1)
			if shortfall > 0 && n_repeating > 0 {
				n_copies += 1
				excess := (n_copies + 1) * w_repeating - w_remaining
				if excess > 0 {
					overlap = excess / (n_copies * n_repeating)
					w_remaining = 0
				}
			}
			if n_repeating > 0 {
				n_copies = min(n_copies, max(ARABIC_STCH_MAX_GLYPHS - n_fixed - n_repeating, 0) / n_repeating)
			}
			if !cut {
				extra += int(n_copies * n_repeating)
			} else {
				// The pieces take no room of their own: centred in what they
				// don't fill, else overlapped to fit.
				x_offset := w_remaining / 2
				for k := end; k > start; k -= 1 {
					width := i32(ft.advance(f, ft.Glyph(s.info[k - 1].glyph)))
					repeat: i32 = 1
					if s.info[k - 1].aux == ARABIC_STCH_REPEATING {
						repeat += n_copies
					}
					s.pos[k - 1].x_advance = 0
					for n in 0 ..< repeat {
						x_offset -= width
						if n > 0 {
							x_offset += overlap
						}
						s.pos[k - 1].x_offset = x_offset
						j -= 1
						s.info[j], s.pos[j] = s.info[k - 1], s.pos[k - 1]
					}
				}
			}
			i -= 1
		}
		if !cut {
			if !ensure(s, s.len + extra) {
				return
			}
		} else {
			s.len = new_len
		}
	}
}
