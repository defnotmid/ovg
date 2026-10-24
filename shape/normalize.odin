package shape

import ft "../font"

// Normalization for shaping (HarfBuzz's design): each character the font
// lacks is decomposed when the font has its parts, marks are put in
// canonical order, and a base and mark the font has precomposed are
// composed. Characters the font has stay as they are, so the font's own
// ccmp sees the text as written.

// Marks reordered at most per run (longer runs keep their order).
@(private)
MAX_COMBINING_MARKS :: 32

// The font's glyph for `r` (ok false when it has none).
@(private)
nominal_glyph :: #force_inline proc(f: ^ft.Face, r: rune) -> (g: u16, ok: bool) {
	g = u16(ft.glyph_index(f, r))
	return g, g != 0
}

// `plan`'s shaper decides the mode: Composed leaves characters the font
// has alone, Composed_Full decomposes everything it can and recomposes,
// None decomposes only what the font lacks and never recomposes.
@(private)
normalize :: proc(s: ^Shaper, plan: ^Plan, f: ^ft.Face) {
	if s.len == 0 {
		return
	}
	mode := SHAPERS[plan.shaper].normalization
	always_short := mode == .None
	might_short := mode != .Composed_Full
	// Decompose: runs of characters before a mark map one to one; a base
	// with marks after it is a cluster decomposed as needed.
	all_simple := true
	count := s.len
	clear_output(s)
	for s.idx < count && s.ok {
		end := s.idx + 1
		for end < count && !is_unicode_mark(s.info[end]) {
			end += 1
		}
		if end < count {
			// Leave the base the marks belong to.
			end -= 1
		}
		done := 0
		for might_short && s.idx + done < end {
			g, ok := nominal_glyph(f, s.info[s.idx + done].char)
			if !ok {
				break
			}
			s.info[s.idx + done].glyph = g
			done += 1
		}
		next_glyphs(s, done)
		for s.idx < end && s.ok {
			decompose_current(s, plan, f, might_short)
		}
		if s.idx >= count || !s.ok {
			break
		}
		all_simple = false
		end = s.idx + 1
		for end < count && is_unicode_mark(s.info[end]) {
			end += 1
		}
		decompose_cluster(s, plan, f, end, always_short)
	}
	swap_buffers(s)

	// Reorder marks by combining class (stable, short runs only).
	if !all_simple {
		info := s.info[:s.len]
		for i := 0; i < len(info); {
			if mcc_of(info[i]) == 0 {
				i += 1
				continue
			}
			end := i + 1
			for end < len(info) && mcc_of(info[end]) != 0 {
				end += 1
			}
			if end - i <= MAX_COMBINING_MARKS {
				// Insertion sort: stable, and the runs are short.
				for k in i + 1 ..< end {
					row := info[k]
					j := k
					for j > i && mcc_of(info[j - 1]) > mcc_of(row) {
						j -= 1
					}
					if j != k {
						// Clusters merge before the move, so a cluster the
						// moved mark shares with what precedes it merges too.
						merge_clusters(s, j, k + 1)
						row = info[k]
						copy(info[j + 1:k + 1], info[j:k])
						info[j] = row
					}
				}
				shaper_reorder_marks(s, plan, i, end)
			}
			i = end + 1
		}
	}
	if .Has_CGJ in s.flags {
		// A CGJ that blocks no reordering needn't be seen.
		for i in 1 ..< max(s.len - 1, 1) {
			if s.info[i].char == 0x034F {
				last, next := mcc_of(s.info[i - 1]), mcc_of(s.info[i + 1])
				if next == 0 || last <= next {
					s.info[i].unicode &~= UPROP_HIDDEN
				}
			}
		}
	}

	// Recompose: a mark with its starter, when nothing between blocks it
	// and the font has the composite.
	if all_simple || !s.ok || mode == .None {
		return
	}
	count = s.len
	starter := 0
	clear_output(s)
	next_glyph(s)
	for s.idx < count && s.ok {
		cur := s.info[s.idx]
		out := out_rows(s)
		if is_unicode_mark(cur) && (starter == s.out_len - 1 || mcc_of(out[s.out_len - 1]) < mcc_of(cur)) {
			if ab, ok := shaper_compose(plan, out[starter].char, cur.char); ok {
				if g, has := nominal_glyph(f, ab); has {
					next_glyph(s)
					if !s.ok {
						return
					}
					merge_out_clusters(s, starter, s.out_len)
					s.out_len -= 1
					out = out_rows(s)
					out[starter].char = ab
					out[starter].glyph = g
					init_unicode(s, &out[starter])
					continue
				}
			}
		}
		next_glyph(s)
		if mcc_of(out_rows(s)[s.out_len - 1]) == 0 {
			starter = s.out_len - 1
		}
	}
	swap_buffers(s)
}

// Decomposes the current character when the font lacks it (`shortest`)
// or always; falls back to the space glyph for spaces, U+2010 for U+2011,
// else the missing glyph.
@(private)
decompose_current :: proc(s: ^Shaper, plan: ^Plan, f: ^ft.Face, shortest: bool) {
	r := s.info[s.idx].char
	g, ok := nominal_glyph(f, r)
	if !shortest || !ok {
		if decompose_into(s, plan, f, shortest, r) > 0 {
			skip_glyph(s)
			return
		}
	}
	if ok {
		s.info[s.idx].glyph = g
		next_glyph(s)
		return
	}
	if gc_of(s.info[s.idx]) == .Zs {
		if kind := space_kind(r); kind != .None {
			if space, has := nominal_glyph(f, ' '); has {
				info := &s.info[s.idx]
				info.unicode = info.unicode & 0xFF | u16(kind) << 8
				info.glyph = space
				s.flags += {.Has_Space_Fallback}
				next_glyph(s)
				return
			}
		}
	}
	if r == 0x2011 {
		if hyphen, has := nominal_glyph(f, 0x2010); has {
			s.info[s.idx].glyph = hyphen
			next_glyph(s)
			return
		}
	}
	s.info[s.idx].glyph = 0
	next_glyph(s)
}

// Outputs the decomposition of `r` (recursively, as far as the font
// needs); the characters output, 0 when the font can't show it.
@(private)
decompose_into :: proc(s: ^Shaper, plan: ^Plan, f: ^ft.Face, shortest: bool, r: rune) -> int {
	a, b, ok := shaper_decompose(plan, r)
	if !ok {
		return 0
	}
	a_glyph, has_a := nominal_glyph(f, a)
	b_glyph: u16
	if b != 0 {
		has_b: bool
		if b_glyph, has_b = nominal_glyph(f, b); !has_b {
			return 0
		}
	}
	if !shortest || !has_a {
		if n := decompose_into(s, plan, f, shortest, a); n > 0 {
			if b != 0 {
				output_char(s, b, b_glyph)
				return n + 1
			}
			return n
		}
	}
	if has_a {
		output_char(s, a, a_glyph)
		if b != 0 {
			output_char(s, b, b_glyph)
			return 2
		}
		return 1
	}
	return 0
}

// A base and its marks (idx ..< end). With a variation selector the
// font's variation sequences decide; otherwise each decomposes fully, to
// be recomposed as far as the font has composites (only what the font
// lacks, with `shortest`).
@(private)
decompose_cluster :: proc(s: ^Shaper, plan: ^Plan, f: ^ft.Face, end: int, shortest: bool) {
	for i in s.idx ..< end {
		if is_variation_selector(s.info[i].char) {
			variation_cluster(s, f, end)
			return
		}
	}
	for s.idx < end && s.ok {
		decompose_current(s, plan, f, shortest)
	}
}

@(private)
variation_cluster :: proc(s: ^Shaper, f: ^ft.Face, end: int) {
	set_glyph :: proc(s: ^Shaper, f: ^ft.Face) {
		if g, ok := nominal_glyph(f, s.info[s.idx].char); ok {
			s.info[s.idx].glyph = g
		}
	}
	for s.idx < end - 1 && s.ok {
		if is_variation_selector(s.info[s.idx + 1].char) {
			if g, ok := variation_glyph(f, s.info[s.idx].char, s.info[s.idx + 1].char); ok {
				// The sequence's glyph; the selector is dropped.
				s.info[s.idx].glyph = g
				merge_clusters(s, s.idx, s.idx + 2)
				next_glyph(s)
				skip_glyph(s)
			} else {
				set_glyph(s, f)
				next_glyph(s)
				set_glyph(s, f)
				next_glyph(s)
			}
			for s.idx < end && is_variation_selector(s.info[s.idx].char) {
				set_glyph(s, f)
				next_glyph(s)
			}
		} else {
			set_glyph(s, f)
			next_glyph(s)
		}
	}
	if s.idx < end {
		set_glyph(s, f)
		next_glyph(s)
	}
}

// The glyph cmap's variation sequences (format 14) give a character with
// a selector: its own glyph, or the default (the character's) glyph.
@(private)
variation_glyph :: proc(f: ^ft.Face, r, selector: rune) -> (g: u16, ok: bool) {
	d := f.data
	cmap := f.tables[.cmap].at
	if cmap == 0 {
		return
	}
	n := int(ft.read_u16(d, cmap + 2))
	sub := 0
	for i in 0 ..< n {
		rec := cmap + 4 + 8 * i
		if ft.read_u16(d, rec) == 0 && ft.read_u16(d, rec + 2) == 5 {
			sub = cmap + int(ft.read_u32(d, rec + 4))
			break
		}
	}
	if sub == 0 || ft.read_u16(d, sub) != 14 {
		return
	}
	// Selector records (sorted): selector, default UVS, non-default UVS.
	records := int(ft.read_u32(d, sub + 6))
	lo, hi := 0, min(records, (len(d) - sub - 10) / 11)
	for lo < hi {
		mid := (lo + hi) / 2
		rec := sub + 10 + 11 * mid
		v := rune(ft.read_u24(d, rec))
		if v < selector {
			lo = mid + 1
		} else if v > selector {
			hi = mid
		} else {
			// Default: ranges of characters that keep their glyph.
			if def := int(ft.read_u32(d, rec + 3)); def != 0 {
				at := sub + def
				count := int(ft.read_u32(d, at))
				for k in 0 ..< min(count, (len(d) - at - 4) / 4) {
					start := rune(ft.read_u24(d, at + 4 + 4 * k))
					extra := rune(ft.read_u8(d, at + 7 + 4 * k))
					if r >= start && r <= start + extra {
						return nominal_glyph(f, r)
					}
				}
			}
			// Non-default: characters with their own glyph.
			if non := int(ft.read_u32(d, rec + 7)); non != 0 {
				at := sub + non
				count := int(ft.read_u32(d, at))
				for k in 0 ..< min(count, (len(d) - at - 4) / 5) {
					if rune(ft.read_u24(d, at + 4 + 5 * k)) == r {
						g = ft.read_u16(d, at + 7 + 5 * k)
						return g, true
					}
				}
			}
			return
		}
	}
	return
}
