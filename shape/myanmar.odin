package shape

import ft "../font"

// Myanmar: syllables; a kinzi (Ra, asat, halant) moves after the base,
// medial ra and pre-base vowels before it, and the rest falls into place
// by position; the basic features apply one per stage, per syllable.

@(private, rodata)
MYANMAR_BASIC_FEATURES := [4]string{"rphf", "pref", "blwf", "pstf"}

@(private, rodata)
MYANMAR_OTHER_FEATURES := [4]string{"pres", "abvs", "blws", "psts"}

@(private)
myanmar_collect_features :: proc(p: ^Planner) {
	add_pause(p, .GSUB, .Myanmar_Setup_Syllables)
	enable_feature(p, "locl", {.Per_Syllable})
	enable_feature(p, "ccmp", {.Per_Syllable})
	add_pause(p, .GSUB, .Myanmar_Reorder)
	for name in MYANMAR_BASIC_FEATURES {
		enable_feature(p, name, {.Manual_ZWJ, .Per_Syllable})
		add_pause(p, .GSUB)
	}
	add_pause(p, .GSUB)
	for name in MYANMAR_OTHER_FEATURES {
		enable_feature(p, name, {.Manual_ZWJ})
	}
}

@(private)
myanmar_setup_syllables :: proc(s: ^Shaper) {
	syllables_by_category(s, &MYANMAR_MACHINE)
}

@(private)
is_consonant_myanmar :: #force_inline proc "contextless" (info: Glyph_Info) -> bool {
	if info.props & GLYPH_LIGATED != 0 {
		return false
	}
	switch info.category {
	case INDIC_C, INDIC_CS, INDIC_Ra, INDIC_IV, INDIC_GB, INDIC_DOTTEDCIRCLE:
		return true
	}
	return false
}

@(private)
myanmar_reorder :: proc(s: ^Shaper, f: ^ft.Face) {
	insert_dotted_circles(s, f, MYANMAR_BROKEN_CLUSTER, INDIC_DOTTEDCIRCLE, -1, -1)
	for start := 0; start < s.len; {
		end := next_syllable(s, start)
		switch int(s.info[start].syllable & 0x0F) {
		case MYANMAR_BROKEN_CLUSTER, MYANMAR_CONSONANT_SYLLABLE:
			myanmar_reorder_syllable(s, start, end)
		}
		start = end
	}
}

@(private)
myanmar_reorder_syllable :: proc(s: ^Shaper, start, end: int) {
	info := s.info[:]
	base := end
	has_reph := false
	limit := start
	if start + 3 <= end && info[start].category == INDIC_Ra && info[start + 1].category == INDIC_As && info[start + 2].category == INDIC_H {
		limit += 3
		base = start
		has_reph = true
	}
	if !has_reph {
		base = limit
	}
	for i in limit ..< end {
		if is_consonant_myanmar(info[i]) {
			base = i
			break
		}
	}
	// Positions.
	i := start
	for ; i < start + (3 if has_reph else 0); i += 1 {
		info[i].aux = POS_AFTER_MAIN
	}
	for ; i < base; i += 1 {
		info[i].aux = POS_PRE_C
	}
	if i < end {
		info[i].aux = POS_BASE_C
		i += 1
	}
	pos: u8 = POS_AFTER_MAIN
	for ; i < end; i += 1 {
		c := info[i].category
		switch {
		case c == INDIC_MR:
			// Pre-base reordering.
			info[i].aux = POS_PRE_C
		case c == INDIC_VPre:
			// Left matra.
			info[i].aux = POS_PRE_M
		case c == INDIC_VS:
			info[i].aux = info[i - 1].aux
		case pos == POS_AFTER_MAIN && c == INDIC_VBlw:
			pos = POS_BELOW_C
			info[i].aux = pos
		case pos == POS_BELOW_C && c == INDIC_A:
			info[i].aux = POS_BEFORE_SUB
		case pos == POS_BELOW_C && c == INDIC_VBlw:
			info[i].aux = pos
		case pos == POS_BELOW_C && c != INDIC_A:
			pos = POS_AFTER_SUB
			info[i].aux = pos
		case:
			info[i].aux = pos
		}
	}
	sort_by_position(s, start, end)
	// A run of left matras keeps its order (sorted, it flipped).
	first_left, last_left := end, end
	for k in start ..< end {
		if info[k].aux == POS_PRE_M {
			if first_left == end {
				first_left = k
			}
			last_left = k
		}
	}
	if first_left < last_left {
		reverse_range(s, first_left, last_left + 1)
		k := first_left
		for j in first_left ..= last_left {
			if info[j].category == INDIC_VPre {
				reverse_range(s, k, j + 1)
				k = j + 1
			}
		}
	}
}

// Sorts rows start ..< end by position (Glyph_Info.aux), stably, merging
// the clusters of what moves (HarfBuzz's buffer sort).
@(private)
sort_by_position :: proc(s: ^Shaper, start, end: int) {
	info := s.info[:]
	for i in start + 1 ..< end {
		j := i
		for j > start && info[j - 1].aux > info[i].aux {
			j -= 1
		}
		if i == j {
			continue
		}
		merge_clusters(s, j, i + 1)
		t := info[i]
		copy(info[j + 1:i + 1], info[j:i])
		info[j] = t
	}
}
