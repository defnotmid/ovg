package shape

import ft "../font"

// Indic scripts (Devanagari, Bengali, Gurmukhi, Gujarati, Oriya, Tamil,
// Telugu, Kannada, Malayalam) with their version 2 or original tags (fonts
// with version 3 tags take USE): syllables; the base consonant found;
// reph, pre-base matras and consonants with below and post forms moved
// into visual order before the basic features, reph and pre-base matras
// adjusted after them by what the font formed. HarfBuzz's port of
// Microsoft's Indic shaping (its rules, and its Uniscribe compatibility).
// https://docs.microsoft.com/en-us/typography/script-development/devanagari

@(private)
Reph_Position :: enum u8 {
	After_Main  = POS_AFTER_MAIN,
	Before_Sub  = POS_BEFORE_SUB,
	After_Sub   = POS_AFTER_SUB,
	Before_Post = POS_BEFORE_POST,
	After_Post  = POS_AFTER_POST,
}

@(private)
Reph_Mode :: enum u8 {
	// Reph formed out of an initial Ra, halant.
	Implicit,
	// Out of Ra, halant, ZWJ.
	Explicit,
	// An encoded repha, needing reordering.
	Log_Repha,
}

@(private)
Blwf_Mode :: enum u8 {
	// Below-base forms before and after the base.
	Pre_And_Post,
	Post_Only,
}

@(private)
Indic_Config :: struct {
	script:       Script,
	has_old_spec: bool,
	virama:       rune,
	reph_pos:     Reph_Position,
	reph_mode:    Reph_Mode,
	blwf_mode:    Blwf_Mode,
}

@(private, rodata)
INDIC_CONFIGS := [?]Indic_Config {
	// The default, first.
	{.Unknown, false, 0, .Before_Post, .Implicit, .Pre_And_Post},
	{.Devanagari, true, 0x094D, .Before_Post, .Implicit, .Pre_And_Post},
	{.Bengali, true, 0x09CD, .After_Sub, .Implicit, .Pre_And_Post},
	{.Gurmukhi, true, 0x0A4D, .Before_Sub, .Implicit, .Pre_And_Post},
	{.Gujarati, true, 0x0ACD, .Before_Post, .Implicit, .Pre_And_Post},
	{.Oriya, true, 0x0B4D, .After_Main, .Implicit, .Pre_And_Post},
	{.Tamil, true, 0x0BCD, .After_Post, .Implicit, .Pre_And_Post},
	{.Telugu, true, 0x0C4D, .After_Post, .Explicit, .Post_Only},
	{.Kannada, true, 0x0CCD, .After_Post, .Implicit, .Post_Only},
	{.Malayalam, true, 0x0D4D, .After_Main, .Log_Repha, .Pre_And_Post},
}

@(private)
indic_config :: proc(script: Script) -> ^Indic_Config {
	for &c in INDIC_CONFIGS[1:] {
		if c.script == script {
			return &c
		}
	}
	return &INDIC_CONFIGS[0]
}

// Indic's features, in order (where the plan keeps their masks), and
// whether each is on everywhere: the basic ones one stage each, then the
// rest together.
@(private, rodata)
INDIC_FEATURES := [17]string{"nukt", "akhn", "rphf", "rkrf", "pref", "blwf", "abvf", "half", "pstf", "vatu", "cjct", "init", "pres", "abvs", "blws", "psts", "haln"}

@(private, rodata)
INDIC_GLOBAL := [17]bool{true, true, false, true, false, false, false, false, false, true, true, false, true, true, true, true, true}

@(private)
INDIC_RPHF :: 2
@(private)
INDIC_PREF :: 4
@(private)
INDIC_BLWF :: 5
@(private)
INDIC_ABVF :: 6
@(private)
INDIC_HALF :: 7
@(private)
INDIC_PSTF :: 8
@(private)
INDIC_INIT :: 11
@(private)
INDIC_BASIC_FEATURES :: INDIC_INIT

@(private)
indic_collect_features :: proc(p: ^Planner) {
	// Before any lookup, syllables.
	add_pause(p, .GSUB, .Indic_Setup_Syllables)
	enable_feature(p, "locl", {.Per_Syllable})
	// The specs don't ask for ccmp; it goes early where fonts use it.
	enable_feature(p, "ccmp", {.Per_Syllable})
	add_pause(p, .GSUB, .Indic_Initial_Reorder)
	for i in 0 ..< INDIC_BASIC_FEATURES {
		indic_add_feature(p, i)
		add_pause(p, .GSUB)
	}
	add_pause(p, .GSUB, .Indic_Final_Reorder)
	for i in INDIC_BASIC_FEATURES ..< len(INDIC_FEATURES) {
		indic_add_feature(p, i)
	}
}

@(private)
indic_add_feature :: proc(p: ^Planner, i: int) {
	flags: Feature_Flags = {.Manual_ZWNJ, .Manual_ZWJ, .Per_Syllable}
	if INDIC_GLOBAL[i] {
		flags += {.Global}
	}
	add_feature(p, INDIC_FEATURES[i], flags)
}

@(private)
indic_override_features :: proc(p: ^Planner) {
	add_feature(p, "liga", {.Global}, 0)
	add_pause(p, .GSUB)
}

@(private)
indic_plan :: proc(p: ^Plan) {
	config := indic_config(p.script)
	p.indic_old_spec = config.has_old_spec && p.chosen_script[.GSUB] & 0xFF != '2'
	for name, i in INDIC_FEATURES {
		p.shaper_masks[i] = 0 if INDIC_GLOBAL[i] else one_mask(p, name)
	}
	for name, form in INDIC_FORMS {
		p.indic_form_stages[form] = i8(feature_stage(p, name))
	}
}

// The forms whose substitution decides a consonant's position or a reph:
// their GSUB stages are found once per plan (Plan.indic_form_stages).
@(private)
Indic_Form :: enum u8 {
	Blwf,
	Vatu,
	Pstf,
	Pref,
	Rphf,
}

@(private, rodata)
INDIC_FORMS := [Indic_Form]string {
	.Blwf = "blwf",
	.Vatu = "vatu",
	.Pstf = "pstf",
	.Pref = "pref",
	.Rphf = "rphf",
}

// Characters Indic shaping keeps whole, then Unicode's decompositions.
@(private)
indic_decompose :: proc(r: rune) -> (a, b: rune, ok: bool) {
	switch r {
	case 0x0931, 0x09DC, 0x09DD, 0x0B94:
		return
	}
	return decompose(r)
}

@(private)
indic_setup_masks :: proc(s: ^Shaper) {
	for &info in s.info[:s.len] {
		p := char_props(info.char)
		info.category = p.indic
		info.aux = p.indic_position
	}
}

@(private)
indic_setup_syllables :: proc(s: ^Shaper) {
	syllables_by_category(s, &INDIC_MACHINE)
}

// The category tests, false for a glyph that ligated.
@(private)
is_one_of :: #force_inline proc "contextless" (info: Glyph_Info, cats: bit_set[0 ..< 64; u64]) -> bool {
	return info.props & GLYPH_LIGATED == 0 && int(info.category) < 64 && int(info.category) in cats
}

// Vowels and placeholders count as consonants (they can't be in a
// consonant syllable, and that way the vowel syllable logic is the
// consonant one).
@(private)
INDIC_CONSONANTS :: bit_set[0 ..< 64; u64]{INDIC_C, INDIC_CS, INDIC_Ra, INDIC_CM, INDIC_V, INDIC_PLACEHOLDER, INDIC_DOTTEDCIRCLE}
@(private)
INDIC_JOINERS :: bit_set[0 ..< 64; u64]{INDIC_ZWJ, INDIC_ZWNJ}

@(private)
is_consonant :: #force_inline proc "contextless" (info: Glyph_Info) -> bool {
	return is_one_of(info, INDIC_CONSONANTS)
}

@(private)
is_joiner :: #force_inline proc "contextless" (info: Glyph_Info) -> bool {
	return is_one_of(info, INDIC_JOINERS)
}

@(private)
is_halant :: #force_inline proc "contextless" (info: Glyph_Info) -> bool {
	return is_one_of(info, {INDIC_H})
}

// Zero context for the new specs (and scripts with one spec), not the
// old: Windows' behaviour (Malayalam allows context in both).
@(private)
indic_would_substitute :: proc(plan: ^Plan, form: Indic_Form, glyphs: []u16) -> bool {
	zero_context := !plan.indic_old_spec && plan.script != .Malayalam
	return would_substitute(plan, int(plan.indic_form_stages[form]), glyphs, zero_context)
}

// A consonant's position by the forms the font gives it with a virama
// (either order: old-spec lookups copied into new-spec tables match too).
@(private)
consonant_position_from_face :: proc(plan: ^Plan, consonant, virama: u16) -> u8 {
	glyphs := [3]u16{virama, consonant, virama}
	if indic_would_substitute(plan, .Blwf, glyphs[:2]) || indic_would_substitute(plan, .Blwf, glyphs[1:]) || indic_would_substitute(plan, .Vatu, glyphs[:2]) || indic_would_substitute(plan, .Vatu, glyphs[1:]) {
		return POS_BELOW_C
	}
	if indic_would_substitute(plan, .Pstf, glyphs[:2]) || indic_would_substitute(plan, .Pstf, glyphs[1:]) {
		return POS_POST_C
	}
	if indic_would_substitute(plan, .Pref, glyphs[:2]) || indic_would_substitute(plan, .Pref, glyphs[1:]) {
		return POS_POST_C
	}
	return POS_BASE_C
}

@(private)
indic_initial_reorder :: proc(s: ^Shaper, plan: ^Plan, f: ^ft.Face) {
	config := indic_config(plan.script)
	s.virama = 0
	if config.virama != 0 {
		s.virama, _ = nominal_glyph(s, config.virama)
	}
	if s.virama != 0 {
		for &info in s.info[:s.len] {
			if info.aux == POS_BASE_C {
				info.aux = consonant_position_from_face(plan, info.glyph, s.virama)
			}
		}
	}
	insert_dotted_circles(s, f, INDIC_BROKEN_CLUSTER, INDIC_DOTTEDCIRCLE, INDIC_Repha, POS_END)
	for start := 0; start < s.len; {
		end := next_syllable(s, start)
		switch int(s.info[start].syllable & 0x0F) {
		case INDIC_VOWEL_SYLLABLE, INDIC_CONSONANT_SYLLABLE, INDIC_BROKEN_CLUSTER, INDIC_STANDALONE_CLUSTER:
			// Vowels and placeholders act as consonants.
			indic_initial_reorder_syllable(s, plan, config, start, end)
		}
		start = end
	}
}

@(private)
indic_initial_reorder_syllable :: proc(s: ^Shaper, plan: ^Plan, config: ^Indic_Config, start, end: int) {
	info := s.info[:]
	masks := plan.shaper_masks[:]

	// Kannada's legacy Ra, halant, ZWJ behaves as Ra, ZWJ, halant.
	if plan.script == .Kannada && start + 3 <= end && is_one_of(info[start], {INDIC_Ra}) && is_one_of(info[start + 1], {INDIC_H}) && is_one_of(info[start + 2], {INDIC_ZWJ}) {
		merge_clusters(s, start + 1, start + 3)
		info[start + 1], info[start + 2] = info[start + 2], info[start + 1]
	}

	// 1. The base consonant: from the end, the first consonant without a
	// below or post form (post forms follow below forms), else the first
	// consonant. An initial Ra, halant that forms a reph is no candidate.
	base := end
	has_reph := false
	limit := start
	if masks[INDIC_RPHF] != 0 && start + 3 <= end && ((config.reph_mode == .Implicit && !is_joiner(info[start + 2])) || (config.reph_mode == .Explicit && info[start + 2].category == INDIC_ZWJ)) {
		glyphs := [3]u16{info[start].glyph, info[start + 1].glyph, info[start + 2].glyph if config.reph_mode == .Explicit else 0}
		if indic_would_substitute(plan, .Rphf, glyphs[:2]) || (config.reph_mode == .Explicit && indic_would_substitute(plan, .Rphf, glyphs[:3])) {
			limit += 2
			for limit < end && is_joiner(info[limit]) {
				limit += 1
			}
			base = start
			has_reph = true
		}
	} else if config.reph_mode == .Log_Repha && info[start].category == INDIC_Repha {
		limit += 1
		for limit < end && is_joiner(info[limit]) {
			limit += 1
		}
		base = start
		has_reph = true
	}
	seen_below := false
	for k := end - 1; ; k -= 1 {
		if is_consonant(info[k]) {
			if info[k].aux != POS_BELOW_C && (info[k].aux != POS_POST_C || seen_below) {
				base = k
				break
			}
			if info[k].aux == POS_BELOW_C {
				seen_below = true
			}
			base = k
		} else if start < k && info[k].category == INDIC_ZWJ && info[k - 1].category == INDIC_H {
			// A ZWJ after a halant asks for a half form: the search stops.
			// (One before a halant asks for a subjoined form.)
			break
		}
		if k <= limit {
			break
		}
	}
	// A reph with no other consonant isn't one: the Ra is the base.
	if has_reph && base == start && limit - base <= 2 {
		has_reph = false
	}

	// 2. and 3. (matras decomposed, marks ordered) normalization did.

	// Positions.
	for i in start ..< base {
		info[i].aux = min(POS_PRE_C, info[i].aux)
	}
	if base < end {
		info[base].aux = POS_BASE_C
	}
	if has_reph {
		info[start].aux = POS_RA_TO_BECOME_REPH
	}
	// Old-spec tags: the first post-base halant moves after the last
	// consonant (Kannada: unless a halant is there already).
	if plan.indic_old_spec {
		no_double := plan.script == .Kannada
		for i in base + 1 ..< end {
			if info[i].category != INDIC_H {
				continue
			}
			j := end - 1
			for ; j > i; j -= 1 {
				if is_consonant(info[j]) || (no_double && info[j].category == INDIC_H) {
					break
				}
			}
			if info[j].category != INDIC_H && j > i {
				t := info[i]
				copy(info[i:j], info[i + 1:j + 1])
				info[j] = t
			}
			break
		}
	}
	// Marks attach to what precedes them, to move with it.
	{
		last_pos: u8 = POS_START
		for i in start ..< end {
			c := info[i].category
			if c == INDIC_ZWJ || c == INDIC_ZWNJ || c == INDIC_N || c == INDIC_RS || c == INDIC_CM || c == INDIC_H {
				info[i].aux = last_pos
				if c == INDIC_H && info[i].aux == POS_PRE_M {
					// Uniscribe doesn't move a halant with a left matra.
					for j := i; j > start; j -= 1 {
						if info[j - 1].aux != POS_PRE_M {
							info[i].aux = info[j - 1].aux
							break
						}
					}
				}
			} else if info[i].aux != POS_SMVD {
				if c == INDIC_MPst && i > start && info[i - 1].category == INDIC_SM {
					info[i - 1].aux = info[i].aux
				}
				last_pos = info[i].aux
			}
		}
	}
	// Post-base consonants own what precedes them since the last consonant
	// or matra.
	{
		last := base
		for i in base + 1 ..< end {
			if is_consonant(info[i]) {
				for j in last + 1 ..< i {
					if info[j].aux < POS_SMVD {
						info[j].aux = info[i].aux
					}
				}
				last = i
			} else if info[i].category == INDIC_M || info[i].category == INDIC_MPst {
				last = i
			}
		}
	}
	{
		// Sort by position, stably; the syllable byte remembers where each
		// came from, for merging clusters after the base.
		syllable := info[start].syllable
		for i in start ..< end {
			info[i].syllable = u8(i - start)
		}
		stable_sort_by_position(info[start:end])
		// The base again; a run of left matras keeps its order.
		first_left, last_left := end, end
		base = end
		for i in start ..< end {
			if info[i].aux == POS_BASE_C {
				base = i
				break
			} else if info[i].aux == POS_PRE_M {
				if first_left == end {
					first_left = i
				}
				last_left = i
			}
		}
		if first_left < last_left {
			reverse_range(s, first_left, last_left + 1)
			k := first_left
			for j in first_left ..= last_left {
				if info[j].category == INDIC_M || info[j].category == INDIC_MPst {
					reverse_range(s, k, j + 1)
					k = j + 1
				}
			}
		}
		// After the base anything may have moved: merge the clusters of
		// what moved (all of it for old-spec, whose halants move).
		if plan.indic_old_spec || end - start > 127 {
			merge_clusters(s, base, end)
		} else {
			for i in base ..< end {
				if info[i].syllable == 255 {
					continue
				}
				lo, hi := i, i
				j := start + int(info[i].syllable)
				for j != i {
					lo, hi = min(lo, j), max(hi, j)
					next := start + int(info[j].syllable)
					info[j].syllable = 255
					j = next
				}
				merge_clusters(s, max(base, lo), hi + 1)
			}
		}
		for i in start ..< end {
			info[i].syllable = syllable
		}
	}

	// Masks.
	for i := start; i < end && info[i].aux == POS_RA_TO_BECOME_REPH; i += 1 {
		info[i].mask |= masks[INDIC_RPHF]
	}
	pre := masks[INDIC_HALF]
	if !plan.indic_old_spec && config.blwf_mode == .Pre_And_Post {
		pre |= masks[INDIC_BLWF]
	}
	for i in start ..< base {
		info[i].mask |= pre
	}
	post := masks[INDIC_BLWF] | masks[INDIC_ABVF] | masks[INDIC_PSTF]
	for i in base + 1 ..< end {
		info[i].mask |= post
	}
	if plan.indic_old_spec && plan.script == .Devanagari {
		// Old-spec eyelash Ra: below-base forms below half forms too
		// (Ra, halant, ZWJ asks for the eyelash, and keeps it).
		for i := start; i + 1 < base; i += 1 {
			if info[i].category == INDIC_Ra && info[i + 1].category == INDIC_H && (i + 2 == base || info[i + 2].category != INDIC_ZWJ) {
				info[i].mask |= masks[INDIC_BLWF]
				info[i + 1].mask |= masks[INDIC_BLWF]
			}
		}
	}
	// A halant, Ra the font has a pre-base form for.
	if masks[INDIC_PREF] != 0 && base + 2 < end {
		for i := base + 1; i + 1 < end; i += 1 {
			glyphs := [2]u16{info[i].glyph, info[i + 1].glyph}
			if indic_would_substitute(plan, .Pref, glyphs[:]) {
				info[i].mask |= masks[INDIC_PREF]
				info[i + 1].mask |= masks[INDIC_PREF]
				break
			}
		}
	}
	// ZWNJ turns off half forms before it (to the previous consonant).
	for i in start + 1 ..< end {
		if is_joiner(info[i]) {
			non_joiner := info[i].category == INDIC_ZWNJ
			j := i
			for {
				j -= 1
				if non_joiner {
					info[j].mask &~= masks[INDIC_HALF]
				}
				if j <= start || is_consonant(info[j]) {
					break
				}
			}
		}
	}
}

// Stable sort by position (Glyph_Info.aux), no clusters merged.
@(private)
stable_sort_by_position :: proc(rows: []Glyph_Info) {
	for i in 1 ..< len(rows) {
		row := rows[i]
		j := i
		for j > 0 && rows[j - 1].aux > row.aux {
			rows[j] = rows[j - 1]
			j -= 1
		}
		rows[j] = row
	}
}

@(private)
indic_final_reorder :: proc(s: ^Shaper, plan: ^Plan) {
	if s.len == 0 {
		return
	}
	config := indic_config(plan.script)
	for start := 0; start < s.len; {
		end := next_syllable(s, start)
		indic_final_reorder_syllable(s, plan, config, start, end)
		start = end
	}
}

@(private)
indic_final_reorder_syllable :: proc(s: ^Shaper, plan: ^Plan, config: ^Indic_Config, start, end: int) {
	info := s.info[:]
	masks := plan.shaper_masks[:]

	// A virama that ligated and multiplied lost its category: it's a
	// halant again.
	if s.virama != 0 {
		for i in start ..< end {
			if info[i].glyph == s.virama && info[i].props & GLYPH_LIGATED != 0 && is_multiplied(info[i]) {
				info[i].category = INDIC_H
				info[i].props &~= GLYPH_LIGATED | GLYPH_MULTIPLIED
			}
		}
	}

	// 4. Final reordering. The base again.
	try_pref := masks[INDIC_PREF] != 0
	base := start
	for ; base < end; base += 1 {
		if info[base].aux < POS_BASE_C {
			continue
		}
		if try_pref && base + 1 < end {
			for i in base + 1 ..< end {
				if info[i].mask & masks[INDIC_PREF] != 0 {
					if !(info[i].props & GLYPH_SUBSTITUTED != 0 && ligated_and_didnt_multiply(info[i])) {
						// A pref candidate that formed nothing: the base is
						// around here.
						base = i
						for base < end && is_halant(info[base]) {
							base += 1
						}
						if base < end {
							info[base].aux = POS_BASE_C
						}
						try_pref = false
					}
					break
				}
			}
			if base == end {
				break
			}
		}
		if plan.script == .Malayalam {
			// Unformed below forms (not post) are skipped.
			for i := base + 1; i < end; i += 1 {
				for i < end && is_joiner(info[i]) {
					i += 1
				}
				if i == end || !is_halant(info[i]) {
					break
				}
				i += 1
				for i < end && is_joiner(info[i]) {
					i += 1
				}
				if i < end && is_consonant(info[i]) && info[i].aux == POS_BELOW_C {
					base = i
					info[base].aux = POS_BASE_C
				}
			}
		}
		if start < base && info[base].aux > POS_BASE_C {
			base -= 1
		}
		break
	}
	if base == end && start < base && is_one_of(info[base - 1], {INDIC_ZWJ}) {
		base -= 1
	}
	if base < end {
		for start < base && is_one_of(info[base], {INDIC_N, INDIC_H}) {
			base -= 1
		}
	}

	// Pre-base matras move closer to the base: after the last standalone
	// halant (unless a ZWJ follows it), before the base.
	if start + 1 < end && start < base {
		new_pos := base - 2 if base == end else base - 1
		// Malayalam and Tamil have no half forms; chillus and ligated
		// viramas take the matra after them.
		if plan.script != .Malayalam && plan.script != .Tamil {
			for {
				for new_pos > start && !is_one_of(info[new_pos], {INDIC_M, INDIC_MPst, INDIC_H}) {
					new_pos -= 1
				}
				// A halant (not one of the matra's own) stops it.
				if is_halant(info[new_pos]) && info[new_pos].aux != POS_PRE_M {
					if new_pos + 1 < end && info[new_pos + 1].category == INDIC_ZWJ && new_pos > start {
						// After a halant with ZWJ the matra doesn't move: search
						// on.
						new_pos -= 1
						continue
					}
				} else {
					new_pos = start
				}
				break
			}
		}
		if start < new_pos && info[new_pos].aux != POS_PRE_M {
			for i := new_pos; i > start; i -= 1 {
				if info[i - 1].aux == POS_PRE_M {
					old_pos := i - 1
					if old_pos < base && base <= new_pos {
						base -= 1
					}
					t := info[old_pos]
					copy(info[old_pos:new_pos], info[old_pos + 1:new_pos + 1])
					info[new_pos] = t
					// Merged after the move: matra reordering is special.
					merge_clusters(s, new_pos, min(end, base + 1))
					new_pos -= 1
				}
			}
		} else {
			for i in start ..< base {
				if info[i].aux == POS_PRE_M {
					merge_clusters(s, i, min(end, base + 1))
					break
				}
			}
		}
	}

	// The reph moves (when it formed from Ra, halant; an encoded repha only
	// when it didn't ligate): by the script's reph position.
	if start + 1 < end && info[start].aux == POS_RA_TO_BECOME_REPH && ((info[start].category == INDIC_Repha) ~ ligated_and_didnt_multiply(info[start])) {
		new_reph := reph_target(info, config, start, end, base)
		merge_clusters(s, start, new_reph + 1)
		reph := info[start]
		copy(info[start:new_reph], info[start + 1:new_reph + 1])
		info[new_reph] = reph
		if start < base && base <= new_reph {
			base -= 1
		}
	}

	// A pre-base reordering consonant (a pref that ligated) moves before
	// the base, after a halant (and a joiner after it).
	if try_pref && base + 1 < end {
		for i in base + 1 ..< end {
			if info[i].mask & masks[INDIC_PREF] == 0 {
				continue
			}
			if ligated_and_didnt_multiply(info[i]) {
				new_pos := base
				if plan.script != .Malayalam && plan.script != .Tamil {
					for new_pos > start && !is_one_of(info[new_pos - 1], {INDIC_M, INDIC_MPst, INDIC_H}) {
						new_pos -= 1
					}
				}
				if new_pos > start && is_halant(info[new_pos - 1]) {
					if new_pos < end && is_joiner(info[new_pos]) {
						new_pos += 1
					}
				}
				old_pos := i
				merge_clusters(s, new_pos, old_pos + 1)
				t := info[old_pos]
				copy(info[new_pos + 1:old_pos + 1], info[new_pos:old_pos])
				info[new_pos] = t
				if new_pos <= base && base < old_pos {
					base += 1
				}
			}
			break
		}
	}

	// init on a left matra that starts a word.
	if info[start].aux == POS_PRE_M {
		if start == 0 || !(gc_of(info[start - 1]) >= .Cf && gc_of(info[start - 1]) <= .Mn) {
			info[start].mask |= masks[INDIC_INIT]
		}
	}
}

@(private)
ligated_and_didnt_multiply :: #force_inline proc "contextless" (info: Glyph_Info) -> bool {
	return info.props & GLYPH_LIGATED != 0 && info.props & GLYPH_MULTIPLIED == 0
}

// Where the reph goes (the steps of Microsoft's spec, as HarfBuzz reads
// them).
@(private)
reph_target :: proc(info: []Glyph_Info, config: ^Indic_Config, start, end, base: int) -> int {
	after_halant :: proc(info: []Glyph_Info, start, base: int) -> (pos: int, ok: bool) {
		// After the first explicit halant between the reph and the base
		// (and a joiner after it).
		pos = start + 1
		for pos < base && !is_halant(info[pos]) {
			pos += 1
		}
		if pos < base && is_halant(info[pos]) {
			if pos + 1 < base && is_joiner(info[pos + 1]) {
				pos += 1
			}
			return pos, true
		}
		return 0, false
	}
	if config.reph_pos != .After_Post {
		// 2. After the first halant.
		if pos, ok := after_halant(info, start, base); ok {
			return pos
		}
		// 3. After the main consonant.
		if config.reph_pos == .After_Main {
			pos := base
			for pos + 1 < end && info[pos + 1].aux <= POS_AFTER_MAIN {
				pos += 1
			}
			if pos < end {
				return pos
			}
		}
		// 4. Before the first post-base consonant (our take on it).
		if config.reph_pos == .After_Sub {
			pos := base
			for pos + 1 < end {
				p := info[pos + 1].aux
				if p == POS_POST_C || p == POS_AFTER_POST || p == POS_SMVD {
					break
				}
				pos += 1
			}
			if pos < end {
				return pos
			}
		}
	}
	// 5. After the first halant, again.
	if pos, ok := after_halant(info, start, base); ok {
		return pos
	}
	// 6. The end of the syllable, before vedic signs (and before a halant
	// after a matra, so they interact).
	pos := end - 1
	for pos > start && info[pos].aux == POS_SMVD {
		pos -= 1
	}
	if is_halant(info[pos]) {
		// (pos shrinks as the loop runs, as in HarfBuzz.)
		for i := base + 1; i < pos; i += 1 {
			if info[i].category == INDIC_M || info[i].category == INDIC_MPst {
				pos -= 1
			}
		}
	}
	return pos
}
