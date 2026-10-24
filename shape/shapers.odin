package shape

import ft "../font"

// Script shapers: what a script needs beyond the default pipeline. Each
// is a kind with a few settings (how text is normalized, when mark
// advances are zeroed, whether marks get fallback positions) and hooks the
// pipeline calls by kind: features and stage breaks at plan time, then
// text preprocessing, per-glyph masks, work between GSUB stages and after
// positioning. HarfBuzz's shapers are the reference (hb-ot-shaper-*.cc).

Shaper_Kind :: enum u8 {
	Default,
	Arabic,
	Hangul,
	Hebrew,
	Thai,
	Indic,
	Khmer,
	Myanmar,
	USE,
}

// How normalization treats characters the font has: kept as they are
// (Composed), or decomposed and recomposed regardless (Composed_Full);
// None only maps them.
Normalization :: enum u8 {
	None,
	Composed,
	Composed_Full,
}

// How mark advances are zeroed: before GPOS, after, or not at all.
Zero_Marks :: enum u8 {
	None,
	Early,
	Late,
}

// What a script shaper does between GSUB stages.
Pause :: enum u8 {
	None,
	// Arabic: glyphs a stch lookup multiplied are marked to be tiled.
	Arabic_Stch,
	// Glyphs forget they were substituted (so the next stage's can be told).
	Clear_Substitution_Flags,
	// USE: syllables and their masks; a substituted repha and pre-base form
	// recorded; reordering.
	Use_Setup_Syllables,
	Use_Record_Rphf,
	Use_Record_Pref,
	Use_Reorder,
	Indic_Setup_Syllables,
	Indic_Initial_Reorder,
	Indic_Final_Reorder,
	Khmer_Setup_Syllables,
	Khmer_Reorder,
	Myanmar_Setup_Syllables,
	Myanmar_Reorder,
}

Shaper_Info :: struct {
	normalization:  Normalization,
	zero_marks:     Zero_Marks,
	fallback_marks: bool,
	// GPOS applies only when its lookups are this script's (Hebrew).
	gpos_tag:       string,
}

@(rodata)
SHAPERS := [Shaper_Kind]Shaper_Info {
	.Default = {.Composed, .Late, true, ""},
	.Arabic  = {.Composed, .Late, true, ""},
	.Hangul  = {.None, .None, true, ""},
	.Hebrew  = {.Composed, .Late, true, "hebr"},
	.Thai    = {.Composed, .Late, false, ""},
	.Indic   = {.Composed_Full, .None, false, ""},
	.Khmer   = {.Composed_Full, .None, false, ""},
	.Myanmar = {.Composed_Full, .Early, false, ""},
	.USE     = {.Composed_Full, .Early, false, ""},
}

// The shaper for a script, given the script tag GSUB's lookups were
// chosen under: fonts made for DFLT or latn get the default shaper.
choose_shaper :: proc(script: Script, gsub: Tag) -> Shaper_Kind {
	generic := gsub == tag("DFLT") || gsub == tag("latn")
	#partial switch script {
	case .Arabic:
		return .Arabic
	case .Syriac:
		return .Default if gsub == tag("DFLT") else .Arabic
	case .Thai, .Lao:
		return .Thai
	case .Hangul:
		return .Hangul
	case .Hebrew:
		return .Hebrew
	case .Bengali, .Devanagari, .Gujarati, .Gurmukhi, .Kannada, .Malayalam, .Oriya, .Tamil, .Telugu:
		if generic {
			return .Default
		}
		// Version 3 tags are shaped with the Universal Shaping Engine.
		return .USE if gsub & 0xFF == '3' else .Indic
	case .Khmer:
		return .Khmer
	case .Myanmar:
		// mymr predates the Myanmar shaping spec (mym2).
		return .Default if generic || gsub == tag("mymr") else .Myanmar
	case .Tibetan, .Mongolian, .Sinhala, .Buhid, .Hanunoo, .Tagalog, .Tagbanwa, .Limbu, .Tai_Le, .Buginese, .Kharoshthi, .Syloti_Nagri, .Tifinagh, .Balinese, .Nko, .Phags_Pa, .Cham, .Kayah_Li, .Lepcha, .Rejang, .Saurashtra, .Sundanese, .Egyptian_Hieroglyphs, .Javanese, .Kaithi, .Meetei_Mayek, .Tai_Tham, .Tai_Viet, .Batak, .Brahmi, .Mandaic, .Chakma, .Miao, .Sharada, .Takri, .Duployan, .Grantha, .Khojki, .Khudawadi, .Mahajani, .Manichaean, .Modi, .Pahawh_Hmong, .Psalter_Pahlavi, .Siddham, .Tirhuta, .Ahom, .Multani, .Adlam, .Bhaiksuki, .Marchen, .Newa, .Masaram_Gondi, .Soyombo, .Zanabazar_Square, .Dogra, .Gunjala_Gondi, .Hanifi_Rohingya, .Makasar, .Medefaidrin, .Old_Sogdian, .Sogdian, .Elymaic, .Nandinagari, .Nyiakeng_Puachue_Hmong, .Wancho, .Chorasmian, .Dives_Akuru, .Khitan_Small_Script, .Yezidi, .Cypro_Minoan, .Old_Uyghur, .Tangsa, .Toto, .Vithkuqi, .Kawi, .Nag_Mundari, .Garay, .Gurung_Khema, .Kirat_Rai, .Ol_Onal, .Sunuwar, .Todhri, .Tulu_Tigalari, .Beria_Erfe, .Sidetic, .Tai_Yo, .Tolong_Siki:
		return .Default if generic else .USE
	}
	return .Default
}

// ---- plan-time hooks --------------------------------------------------------------

@(private)
shaper_collect_features :: proc(p: ^Planner) {
	#partial switch p.plan.shaper {
	case .USE:
		use_collect_features(p)
	case .Indic:
		indic_collect_features(p)
	case .Khmer:
		khmer_collect_features(p)
	case .Myanmar:
		myanmar_collect_features(p)
	case .Arabic:
		arabic_collect_features(p)
	case .Hangul:
		for name in ([?]string{"ljmo", "vjmo", "tjmo"}) {
			add_feature(p, name)
		}
	}
}

// After the caller's features.
@(private)
shaper_override_features :: proc(p: ^Planner) {
	#partial switch p.plan.shaper {
	case .Indic:
		indic_override_features(p)
	case .Khmer:
		khmer_override_features(p)
	case .Hangul:
		// Fonts put jamo lookups in calt, which Uniscribe doesn't apply for
		// Hangul: calt gets its own bit, cleared on jamo (setup masks).
		add_feature(p, "calt")
	}
}

// The shaper's masks, once features have bits.
@(private)
shaper_plan :: proc(p: ^Plan) {
	#partial switch p.shaper {
	case .USE:
		use_plan(p)
	case .Indic:
		indic_plan(p)
	case .Khmer:
		khmer_plan(p)
	case .Arabic:
		for name, i in ARABIC_FEATURES {
			p.shaper_masks[i] = one_mask(p, name)
		}
		p.has_stch = one_mask(p, "stch") != 0
	case .Hangul:
		p.shaper_masks[HANGUL_LJMO] = one_mask(p, "ljmo")
		p.shaper_masks[HANGUL_VJMO] = one_mask(p, "vjmo")
		p.shaper_masks[HANGUL_TJMO] = one_mask(p, "tjmo")
		p.shaper_masks[HANGUL_CALT] = one_mask(p, "calt")
	}
}

// ---- shaping hooks -----------------------------------------------------------------

// Before normalization (with characters, not glyphs, in the rows).
@(private)
shaper_preprocess :: proc(s: ^Shaper, plan: ^Plan, f: ^ft.Face) {
	#partial switch plan.shaper {
	case .Thai:
		thai_preprocess(s)
	case .Hangul:
		hangul_preprocess(s, f)
	case .USE, .Indic:
		vowel_constraints(s, plan.script)
	}
}

// After normalization: the shaper's per-glyph feature masks.
@(private)
shaper_setup_masks :: proc(s: ^Shaper, plan: ^Plan) {
	#partial switch plan.shaper {
	case .USE:
		use_setup_masks(s, plan)
	case .Indic:
		indic_setup_masks(s)
	case .Khmer, .Myanmar:
		for &info in s.info[:s.len] {
			info.category = char_props(info.char).indic
		}
	case .Arabic:
		arabic_joining(s, plan)
		for &info in s.info[:s.len] {
			info.mask |= plan.shaper_masks[info.aux]
		}
	case .Hangul:
		for &info in s.info[:s.len] {
			info.mask |= plan.shaper_masks[info.aux]
			if is_jamo_l(info.char) || is_jamo_v(info.char) || is_jamo_t(info.char) {
				info.mask &~= plan.shaper_masks[HANGUL_CALT]
			}
		}
	}
}

// Between GSUB stages.
@(private)
shaper_pause :: proc(c: ^Apply_Context, pause: Pause) {
	switch pause {
	case .None:
	case .Arabic_Stch:
		arabic_record_stch(c.s, c.plan)
	case .Clear_Substitution_Flags:
		clear_substitution_flags(c.s)
	case .Use_Setup_Syllables:
		use_setup_syllables(c.s, c.plan)
	case .Use_Record_Rphf:
		use_record_rphf(c.s, c.plan)
	case .Use_Record_Pref:
		use_record_pref(c.s)
	case .Use_Reorder:
		use_reorder(c.s, c.face)
	case .Indic_Setup_Syllables:
		indic_setup_syllables(c.s)
	case .Indic_Initial_Reorder:
		indic_initial_reorder(c.s, c.plan, c.face)
	case .Indic_Final_Reorder:
		indic_final_reorder(c.s, c.plan)
	case .Khmer_Setup_Syllables:
		khmer_setup_syllables(c.s)
	case .Khmer_Reorder:
		khmer_reorder(c.s, c.plan, c.face)
	case .Myanmar_Setup_Syllables:
		myanmar_setup_syllables(c.s)
	case .Myanmar_Reorder:
		myanmar_reorder(c.s, c.face)
	}
}

// After positioning and the final reorder.
@(private)
shaper_postprocess :: proc(s: ^Shaper, plan: ^Plan, f: ^ft.Face) {
	#partial switch plan.shaper {
	case .Arabic:
		arabic_apply_stch(s, f)
	}
}

// After canonical reordering, a run of marks (start ..< end) the shaper
// orders further.
@(private)
shaper_reorder_marks :: proc(s: ^Shaper, plan: ^Plan, start, end: int) {
	#partial switch plan.shaper {
	case .Hebrew:
		hebrew_reorder_marks(s, start, end)
	case .Arabic:
		arabic_reorder_marks(s, start, end)
	}
}

// Decomposition: Unicode's, with a shaper's exceptions.
@(private)
shaper_decompose :: proc(plan: ^Plan, r: rune) -> (a, b: rune, ok: bool) {
	#partial switch plan.shaper {
	case .Indic:
		return indic_decompose(r)
	case .Khmer:
		return khmer_decompose(r)
	}
	return decompose(r)
}

// Composition: Unicode's, plus a shaper's own.
@(private)
shaper_compose :: proc(plan: ^Plan, a, b: rune) -> (ab: rune, ok: bool) {
	#partial switch plan.shaper {
	case .USE, .Indic, .Khmer:
		// Split matras aren't recomposed.
		if gc_is_mark(char_props(a).gc) {
			return 0, false
		}
		if plan.shaper == .Indic && a == 0x09AF && b == 0x09BC {
			// A composition exclusion Indic shaping wants composed.
			return 0x09DF, true
		}
	}
	if ab, ok = compose(a, b); ok {
		return
	}
	if plan.shaper == .Hebrew && !plan.has_gpos_mark {
		return hebrew_compose(a, b)
	}
	return
}

// ---- Hebrew -------------------------------------------------------------------------

// Presentation forms with dagesh for U+05D0 ..= U+05EA (0: none).
@(private, rodata)
HEBREW_DAGESH_FORMS := [27]u16 {
	0xFB30, 0xFB31, 0xFB32, 0xFB33, 0xFB34, 0xFB35, 0xFB36, 0, 0xFB38, 0xFB39,
	0xFB3A, 0xFB3B, 0xFB3C, 0, 0xFB3E, 0, 0xFB40, 0xFB41, 0, 0xFB43,
	0xFB44, 0, 0xFB46, 0xFB47, 0xFB48, 0xFB49, 0xFB4A,
}

// Hebrew presentation forms, which normalization excludes but fonts
// without GPOS mark positioning need for their points.
@(private)
hebrew_compose :: proc(a, b: rune) -> (ab: rune, ok: bool) {
	switch b {
	case 0x05B4:
		// Hiriq.
		if a == 0x05D9 {
			return 0xFB1D, true
		}
	case 0x05B7:
		// Patah.
		if a == 0x05F2 {
			return 0xFB1F, true
		} else if a == 0x05D0 {
			return 0xFB2E, true
		}
	case 0x05B8:
		// Qamats.
		if a == 0x05D0 {
			return 0xFB2F, true
		}
	case 0x05B9:
		// Holam.
		if a == 0x05D5 {
			return 0xFB4B, true
		}
	case 0x05BC:
		// Dagesh.
		if a >= 0x05D0 && a <= 0x05EA {
			form := rune(HEBREW_DAGESH_FORMS[a - 0x05D0])
			return form, form != 0
		} else if a == 0xFB2A {
			return 0xFB2C, true
		} else if a == 0xFB2B {
			return 0xFB2D, true
		}
	case 0x05BF:
		// Rafe.
		switch a {
		case 0x05D1:
			return 0xFB4C, true
		case 0x05DB:
			return 0xFB4D, true
		case 0x05E4:
			return 0xFB4E, true
		}
	case 0x05C1:
		// Shin dot.
		if a == 0x05E9 {
			return 0xFB2A, true
		} else if a == 0xFB49 {
			return 0xFB2C, true
		}
	case 0x05C2:
		// Sin dot.
		if a == 0x05E9 {
			return 0xFB2B, true
		} else if a == 0xFB49 {
			return 0xFB2D, true
		}
	}
	return
}

// Patah or qamats, then sheva or hiriq, then meteg or a below mark: the
// last two swap (the order SBL Hebrew fonts expect).
@(private)
hebrew_reorder_marks :: proc(s: ^Shaper, start, end: int) {
	info := s.info[:]
	for i in start + 2 ..< end {
		c0, c1, c2 := mcc_of(info[i - 2]), mcc_of(info[i - 1]), mcc_of(info[i])
		if (c0 == 20 || c0 == 21) && (c1 == 22 || c1 == 23) && (c2 == 25 || c2 == 220) {
			merge_clusters(s, i - 1, i + 1)
			info[i - 1], info[i] = info[i], info[i - 1]
			break
		}
	}
}
