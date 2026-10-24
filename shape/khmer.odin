package shape

import ft "../font"

// Khmer: syllables; a coeng + ro moves before the base (with pref, and
// what follows takes cfar), a pre-base vowel to the syllable's start. The
// basic features apply per syllable, all in one stage (Uniscribe doesn't
// pause between them).

// Khmer's features, in order; where the plan keeps their masks
// (shaper_masks, 0 for the global ones).
@(private, rodata)
KHMER_FEATURES := [9]string{"pref", "blwf", "abvf", "pstf", "cfar", "pres", "abvs", "blws", "psts"}

@(private)
KHMER_PREF :: 0
@(private)
KHMER_BLWF :: 1
@(private)
KHMER_ABVF :: 2
@(private)
KHMER_PSTF :: 3
@(private)
KHMER_CFAR :: 4
@(private)
KHMER_BASIC_FEATURES :: 5

@(private)
khmer_collect_features :: proc(p: ^Planner) {
	// Before any lookup, syllables, then reordering.
	add_pause(p, .GSUB, .Khmer_Setup_Syllables)
	add_pause(p, .GSUB, .Khmer_Reorder)
	enable_feature(p, "locl", {.Per_Syllable})
	enable_feature(p, "ccmp", {.Per_Syllable})
	for name in KHMER_FEATURES[:KHMER_BASIC_FEATURES] {
		add_feature(p, name, {.Manual_ZWNJ, .Manual_ZWJ, .Per_Syllable})
	}
	add_pause(p, .GSUB)
	for name in KHMER_FEATURES[KHMER_BASIC_FEATURES:] {
		add_feature(p, name, {.Global, .Manual_ZWNJ, .Manual_ZWJ})
	}
}

@(private)
khmer_override_features :: proc(p: ^Planner) {
	// The Khmer spec has clig among the required features; liga is off.
	enable_feature(p, "clig")
	add_feature(p, "liga", {.Global}, 0)
}

@(private)
khmer_plan :: proc(p: ^Plan) {
	for name, i in KHMER_FEATURES[:KHMER_BASIC_FEATURES] {
		p.shaper_masks[i] = one_mask(p, name)
	}
}

// Split vowels Unicode doesn't decompose.
@(private)
khmer_decompose :: proc(r: rune) -> (a, b: rune, ok: bool) {
	switch r {
	case 0x17BE, 0x17BF, 0x17C0, 0x17C4, 0x17C5:
		return 0x17C1, r, true
	}
	return decompose(r)
}

@(private)
khmer_setup_syllables :: proc(s: ^Shaper) {
	syllables_by_category(s, &KHMER_MACHINE)
}

@(private)
khmer_reorder :: proc(s: ^Shaper, plan: ^Plan, f: ^ft.Face) {
	insert_dotted_circles(s, f, KHMER_BROKEN_CLUSTER, INDIC_DOTTEDCIRCLE, -1, -1)
	for start := 0; start < s.len; {
		end := next_syllable(s, start)
		switch int(s.info[start].syllable & 0x0F) {
		case KHMER_BROKEN_CLUSTER, KHMER_CONSONANT_SYLLABLE:
			khmer_reorder_syllable(s, plan, start, end)
		}
		start = end
	}
}

@(private)
khmer_reorder_syllable :: proc(s: ^Shaper, plan: ^Plan, start, end: int) {
	info := s.info[:]
	masks := plan.shaper_masks[:]
	post := masks[KHMER_BLWF] | masks[KHMER_ABVF] | masks[KHMER_PSTF]
	for i in start + 1 ..< end {
		info[i].mask |= post
	}
	coengs := 0
	for i in start + 1 ..< end {
		if info[i].category == INDIC_H && coengs <= 2 && i + 1 < end {
			coengs += 1
			if info[i + 1].category == INDIC_Ra {
				// Coeng, ro: pref, moved to the start; what follows cfar.
				info[i].mask |= masks[KHMER_PREF]
				info[i + 1].mask |= masks[KHMER_PREF]
				merge_clusters(s, start, i + 2)
				t0, t1 := info[i], info[i + 1]
				copy(info[start + 2:i + 2], info[start:i])
				info[start], info[start + 1] = t0, t1
				if masks[KHMER_CFAR] != 0 {
					for j in i + 2 ..< end {
						info[j].mask |= masks[KHMER_CFAR]
					}
				}
				coengs = 2
			}
		} else if info[i].category == INDIC_VPre {
			// A left vowel piece goes first.
			merge_clusters(s, start, i + 1)
			t := info[i]
			copy(info[start + 1:i + 1], info[start:i])
			info[start] = t
		}
	}
}

// Syllables found by `m` over the glyphs' categories.
@(private)
syllables_by_category :: proc(s: ^Shaper, m: ^Machine) {
	clear(&s.scratch_cats)
	for info in s.info[:s.len] {
		append(&s.scratch_cats, info.category)
	}
	resize(&s.scratch_syllables, s.len)
	if run_machine(m, s.scratch_cats[:], s.scratch_syllables[:]) {
		s.flags += {.Has_Broken_Syllable}
	}
	for &info, i in s.info[:s.len] {
		info.syllable = s.scratch_syllables[i]
	}
}
