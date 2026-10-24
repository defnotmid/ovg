package shape

import ft "../font"

// The Universal Shaping Engine (Microsoft's USE, as HarfBuzz implements
// it) for the many scripts with no shaper of their own: syllables by USE
// category, a repha moved after the base, pre-base vowels moved before
// it, joining forms per syllable (or Arabic joining, for the scripts that
// join like Arabic).
// https://docs.microsoft.com/en-us/typography/script-development/use

// Where the plan keeps USE's masks (shaper_masks; Arabic's joining forms
// take 0 ..= 7).
@(private)
USE_RPHF_MASK :: 8
@(private)
USE_TOPOGRAPHICAL_MASKS :: 9

// The topographical features, by joining form.
@(private, rodata)
USE_TOPOGRAPHICAL := [4]string{"isol", "init", "medi", "fina"}

@(private)
USE_ISOL :: 0
@(private)
USE_INIT :: 1
@(private)
USE_MEDI :: 2
@(private)
USE_FINA :: 3
@(private)
USE_NO_FORM :: 4

// Scripts USE joins as Arabic (those with joining data).
@(private)
has_arabic_joining :: proc(script: Script) -> bool {
	#partial switch script {
	case .Adlam, .Arabic, .Chorasmian, .Hanifi_Rohingya, .Mandaic, .Manichaean, .Mongolian, .Nko, .Old_Uyghur, .Phags_Pa, .Psalter_Pahlavi, .Sogdian, .Syriac:
		return true
	}
	return false
}

@(private)
use_collect_features :: proc(p: ^Planner) {
	// Before any lookup, syllables.
	add_pause(p, .GSUB, .Use_Setup_Syllables)
	// Default glyph pre-processing.
	enable_feature(p, "locl", {.Per_Syllable})
	enable_feature(p, "ccmp", {.Per_Syllable})
	enable_feature(p, "nukt", {.Per_Syllable})
	enable_feature(p, "akhn", {.Manual_ZWJ, .Per_Syllable})
	// Reordering.
	add_pause(p, .GSUB, .Clear_Substitution_Flags)
	add_feature(p, "rphf", {.Manual_ZWJ, .Per_Syllable})
	add_pause(p, .GSUB, .Use_Record_Rphf)
	add_pause(p, .GSUB, .Clear_Substitution_Flags)
	enable_feature(p, "pref", {.Manual_ZWJ, .Per_Syllable})
	add_pause(p, .GSUB, .Use_Record_Pref)
	// Orthographic unit shaping.
	for name in ([?]string{"rkrf", "abvf", "blwf", "half", "pstf", "vatu", "cjct"}) {
		enable_feature(p, name, {.Manual_ZWJ, .Per_Syllable})
	}
	add_pause(p, .GSUB, .Use_Reorder)
	add_pause(p, .GSUB)
	// Topographical features.
	for name in USE_TOPOGRAPHICAL {
		add_feature(p, name)
	}
	add_pause(p, .GSUB)
	// Standard typographic presentation.
	for name in ([?]string{"abvs", "blws", "haln", "pres", "psts"}) {
		enable_feature(p, name, {.Manual_ZWJ})
	}
}

@(private)
use_plan :: proc(p: ^Plan) {
	if has_arabic_joining(p.script) {
		for name, i in ARABIC_FEATURES {
			p.shaper_masks[i] = one_mask(p, name)
		}
	}
	p.shaper_masks[USE_RPHF_MASK] = one_mask(p, "rphf")
	for name, i in USE_TOPOGRAPHICAL {
		mask := one_mask(p, name)
		p.shaper_masks[USE_TOPOGRAPHICAL_MASKS + i] = 0 if mask == p.global_mask else mask
	}
}

// Each glyph's USE category (Glyph_Info.category), after Arabic joining
// for the scripts that join.
@(private)
use_setup_masks :: proc(s: ^Shaper, plan: ^Plan) {
	if has_arabic_joining(plan.script) {
		arabic_joining(s, plan)
		for &info in s.info[:s.len] {
			info.mask |= plan.shaper_masks[info.aux]
		}
	}
	for &info in s.info[:s.len] {
		info.category = char_props(info.char).use
	}
}

// Syllables, over the glyphs that aren't CGJ (nor a ZWNJ before a mark);
// those take the syllable of what precedes them.
@(private)
use_setup_syllables :: proc(s: ^Shaper, plan: ^Plan) {
	info := s.info[:s.len]
	clear(&s.scratch_cats)
	clear(&s.scratch_index)
	for row, i in info {
		if row.category == USE_CGJ {
			continue
		}
		if row.category == USE_ZWNJ {
			// A ZWNJ before a mark (CGJs skipped) is left out.
			next_mark := false
			for k in i + 1 ..< len(info) {
				if info[k].category != USE_CGJ {
					next_mark = is_unicode_mark(info[k])
					break
				}
			}
			if next_mark {
				continue
			}
		}
		append(&s.scratch_cats, row.category)
		append(&s.scratch_index, i32(i))
	}
	resize(&s.scratch_syllables, len(s.scratch_cats))
	if run_machine(&USE_MACHINE, s.scratch_cats[:], s.scratch_syllables[:]) {
		s.flags += {.Has_Broken_Syllable}
	}
	k := 0
	last: u8 = 0
	for &row, i in info {
		if k < len(s.scratch_index) && int(s.scratch_index[k]) == i {
			last = s.scratch_syllables[k]
			k += 1
		}
		row.syllable = last
	}
	use_rphf_mask(s, plan)
	use_topographical_masks(s, plan)
}

// rphf may apply to a syllable's first glyph when it's a repha, else to
// its first three.
@(private)
use_rphf_mask :: proc(s: ^Shaper, plan: ^Plan) {
	mask := plan.shaper_masks[USE_RPHF_MASK]
	if mask == 0 {
		return
	}
	info := s.info[:s.len]
	for start := 0; start < s.len; {
		end := next_syllable(s, start)
		limit := 1 if info[start].category == USE_R else min(3, end - start)
		for i in start ..< start + limit {
			info[i].mask |= mask
		}
		start = end
	}
}

// Joining forms by syllable: a syllable joins the one before unless one
// of them doesn't join at all.
@(private)
use_topographical_masks :: proc(s: ^Shaper, plan: ^Plan) {
	if has_arabic_joining(plan.script) {
		return
	}
	masks := plan.shaper_masks[USE_TOPOGRAPHICAL_MASKS:][:4]
	all := masks[0] | masks[1] | masks[2] | masks[3]
	if all == 0 {
		return
	}
	others := ~all
	info := s.info[:s.len]
	last_start := 0
	last_form := USE_NO_FORM
	for start := 0; start < s.len; {
		end := next_syllable(s, start)
		switch int(info[start].syllable & 0x0F) {
		case USE_HIEROGLYPH_CLUSTER, USE_NON_CLUSTER:
			// These don't join.
			last_form = USE_NO_FORM
		case USE_VIRAMA_TERMINATED_CLUSTER, USE_SAKOT_TERMINATED_CLUSTER, USE_STANDARD_CLUSTER, USE_NUMBER_JOINER_TERMINATED_CLUSTER, USE_NUMERAL_CLUSTER, USE_SYMBOL_CLUSTER, USE_BROKEN_CLUSTER:
			join := last_form == USE_FINA || last_form == USE_ISOL
			if join {
				// The previous syllable's form becomes joining forward.
				last_form = USE_MEDI if last_form == USE_FINA else USE_INIT
				for i in last_start ..< start {
					info[i].mask = info[i].mask & others | masks[last_form]
				}
			}
			last_form = USE_FINA if join else USE_ISOL
			for i in start ..< end {
				info[i].mask = info[i].mask & others | masks[last_form]
			}
		}
		last_start = start
		start = end
	}
}

// A substituted repha becomes a repha (category R).
@(private)
use_record_rphf :: proc(s: ^Shaper, plan: ^Plan) {
	mask := plan.shaper_masks[USE_RPHF_MASK]
	if mask == 0 {
		return
	}
	info := s.info[:s.len]
	for start := 0; start < s.len; {
		end := next_syllable(s, start)
		for i := start; i < end && info[i].mask & mask != 0; i += 1 {
			if info[i].props & GLYPH_SUBSTITUTED != 0 {
				info[i].category = USE_R
				break
			}
		}
		start = end
	}
}

// A substituted pre-base form behaves as a pre-base vowel.
@(private)
use_record_pref :: proc(s: ^Shaper) {
	info := s.info[:s.len]
	for start := 0; start < s.len; {
		end := next_syllable(s, start)
		for i in start ..< end {
			if info[i].props & GLYPH_SUBSTITUTED != 0 {
				info[i].category = USE_VPre
				break
			}
		}
		start = end
	}
}

@(private)
is_halant_use :: #force_inline proc "contextless" (info: Glyph_Info) -> bool {
	return (info.category == USE_H || info.category == USE_HVM || info.category == USE_IS) && info.props & GLYPH_LIGATED == 0
}

// The categories that follow the base (a repha moves before them).
@(private)
is_post_base_use :: #force_inline proc "contextless" (c: u8) -> bool {
	switch c {
	case USE_FAbv, USE_FBlw, USE_FPst, USE_FMAbv, USE_FMBlw, USE_FMPst, USE_MAbv, USE_MBlw, USE_MPst, USE_MPre, USE_VAbv, USE_VBlw, USE_VPst, USE_VPre, USE_VMAbv, USE_VMBlw, USE_VMPst, USE_VMPre:
		return true
	}
	return false
}

@(private)
use_reorder :: proc(s: ^Shaper, f: ^ft.Face) {
	insert_dotted_circles(s, f, USE_BROKEN_CLUSTER, USE_B, USE_R, -1)
	for start := 0; start < s.len; {
		end := next_syllable(s, start)
		use_reorder_syllable(s, start, end)
		start = end
	}
}

@(private)
use_reorder_syllable :: proc(s: ^Shaper, start, end: int) {
	switch int(s.info[start].syllable & 0x0F) {
	case USE_VIRAMA_TERMINATED_CLUSTER, USE_SAKOT_TERMINATED_CLUSTER, USE_STANDARD_CLUSTER, USE_SYMBOL_CLUSTER, USE_BROKEN_CLUSTER:
	case:
		return
	}
	info := s.info[:]
	// A repha moves towards the end, before the first post-base glyph.
	if info[start].category == USE_R && end - start > 1 {
		for i := start + 1; i < end; i += 1 {
			post_base := is_post_base_use(info[i].category) || is_halant_use(info[i])
			if post_base || i == end - 1 {
				i := i
				if post_base {
					i -= 1
				}
				merge_clusters(s, start, i + 1)
				t := info[start]
				copy(info[start:i], info[start + 1:i + 1])
				info[i] = t
				break
			}
		}
	}
	// Pre-base vowels move back, after the last halant.
	j := start
	for i in start ..< end {
		c := info[i].category
		if is_halant_use(info[i]) {
			j = i + 1
		} else if (c == USE_VPre || c == USE_VMPre) && lig_comp(info[i]) == 0 && j < i {
			// (Only the first piece of a multiple substitution moves.)
			merge_clusters(s, j, i + 1)
			t := info[i]
			copy(info[j + 1:i + 1], info[j:i])
			info[j] = t
		}
	}
}
