package shape

import ft "../font"

// Hangul: syllables the font lacks are decomposed into jamo, and jamo
// sequences the font has as a syllable are composed; jamo left as jamo
// take the ljmo, vjmo and tjmo features (leading consonant, vowel,
// trailing consonant). Tone marks move before the syllable they follow
// (alone, they sit on a dotted circle).

// The jamo feature a glyph takes (Glyph_Info.aux; 0 for none).
@(private)
HANGUL_LJMO :: 1
@(private)
HANGUL_VJMO :: 2
@(private)
HANGUL_TJMO :: 3
// Where the plan keeps calt's mask (shaper_masks).
@(private)
HANGUL_CALT :: 4

@(private)
is_hangul_tone :: #force_inline proc "contextless" (r: rune) -> bool {
	return r >= 0x302E && r <= 0x302F
}

@(private)
is_jamo_l :: #force_inline proc "contextless" (r: rune) -> bool {
	return (r >= 0x1100 && r <= 0x115F) || (r >= 0xA960 && r <= 0xA97C)
}

@(private)
is_jamo_v :: #force_inline proc "contextless" (r: rune) -> bool {
	return (r >= 0x1160 && r <= 0x11A7) || (r >= 0xD7B0 && r <= 0xD7C6)
}

@(private)
is_jamo_t :: #force_inline proc "contextless" (r: rune) -> bool {
	return (r >= 0x11A8 && r <= 0x11FF) || (r >= 0xD7CB && r <= 0xD7FB)
}

// Jamo that compose into the precomposed syllables (U+AC00 ..= U+D7A3).
@(private)
is_combining_l :: #force_inline proc "contextless" (r: rune) -> bool {
	return r >= HANGUL_L && r < HANGUL_L + HANGUL_L_COUNT
}

@(private)
is_combining_v :: #force_inline proc "contextless" (r: rune) -> bool {
	return r >= HANGUL_V && r < HANGUL_V + HANGUL_V_COUNT
}

@(private)
is_combining_t :: #force_inline proc "contextless" (r: rune) -> bool {
	return r > HANGUL_T && r < HANGUL_T + HANGUL_T_COUNT
}

@(private)
is_syllable :: #force_inline proc "contextless" (r: rune) -> bool {
	return r >= HANGUL_S && r < HANGUL_S + HANGUL_S_COUNT
}

@(private)
has_glyph :: #force_inline proc(s: ^Shaper, r: rune) -> bool {
	_, ok := nominal_glyph(s, r)
	return ok
}

// Replaces the next `n` rows with one for character `r` (clusters merged).
@(private)
replace_chars :: proc(s: ^Shaper, n: int, r: rune) {
	merge_clusters(s, s.idx, s.idx + n)
	row := s.info[s.idx]
	row.char = r
	init_unicode(s, &row)
	if !make_room_for(s, n, 1) {
		return
	}
	out_rows(s)[s.out_len] = row
	s.out_len += 1
	s.idx += n
}

@(private)
hangul_preprocess :: proc(s: ^Shaper, f: ^ft.Face) {
	clear_output(s)
	// The current syllable's output rows (start ..< end).
	start, end := 0, 0
	for s.idx < s.len && s.ok {
		r := s.info[s.idx].char
		if is_hangul_tone(r) {
			// A tone mark after a syllable goes before it, unless it draws
			// with no advance (then it stays, combining).
			if start < end && end == s.out_len {
				next_glyph(s)
				g, _ := nominal_glyph(s, r)
				if g == 0 || ft.advance(f, g) != 0 {
					merge_out_clusters(s, start, end + 1)
					out := out_rows(s)
					tone := out[end]
					copy(out[start + 1:end + 1], out[start:end])
					out[start] = tone
				}
			} else if has_glyph(s, 0x25CC) {
				// Alone: shown on a dotted circle (after it when the tone
				// mark has no advance of its own).
				g, _ := nominal_glyph(s, r)
				zero_width := g != 0 && ft.advance(f, g) == 0
				row := s.info[s.idx]
				if !make_room_for(s, 1, 2) {
					break
				}
				out := out_rows(s)
				out[s.out_len], out[s.out_len + 1] = row, row
				out[s.out_len + (0 if zero_width else 1)].char = 0x25CC
				s.out_len += 2
				s.idx += 1
			} else {
				next_glyph(s)
			}
			start, end = s.out_len, s.out_len
			continue
		}
		start = s.out_len
		if is_jamo_l(r) && s.idx + 1 < s.len {
			l, v := r, s.info[s.idx + 1].char
			if is_jamo_v(v) {
				t: rune
				t_index := 0
				if s.idx + 2 < s.len {
					t = s.info[s.idx + 2].char
					if is_jamo_t(t) {
						t_index = int(t - HANGUL_T)
					} else {
						t = 0
					}
				}
				// L V (T) the font has as a syllable: composed.
				if is_combining_l(l) && is_combining_v(v) && (t == 0 || is_combining_t(t)) {
					syllable := rune(HANGUL_S + int(l - HANGUL_L) * HANGUL_N_COUNT + int(v - HANGUL_V) * HANGUL_T_COUNT + t_index)
					if has_glyph(s, syllable) {
						replace_chars(s, 3 if t != 0 else 2, syllable)
						end = start + 1
						continue
					}
				}
				// Else jamo with their features, one cluster.
				s.info[s.idx].aux = HANGUL_LJMO
				next_glyph(s)
				s.info[s.idx].aux = HANGUL_VJMO
				next_glyph(s)
				if t != 0 {
					s.info[s.idx].aux = HANGUL_TJMO
					next_glyph(s)
					end = start + 3
				} else {
					end = start + 2
				}
				merge_out_clusters(s, start, end)
				continue
			}
		} else if is_syllable(r) {
			has := has_glyph(s, r)
			si := int(r - HANGUL_S)
			l_index, n_index := si / HANGUL_N_COUNT, si % HANGUL_N_COUNT
			v_index, t_index := n_index / HANGUL_T_COUNT, n_index % HANGUL_T_COUNT
			// An LV syllable and a trailing jamo the font has composed.
			if t_index == 0 && s.idx + 1 < s.len && is_combining_t(s.info[s.idx + 1].char) {
				composed := r + s.info[s.idx + 1].char - HANGUL_T
				if has_glyph(s, composed) {
					replace_chars(s, 2, composed)
					end = start + 1
					continue
				}
			}
			// A syllable the font lacks, or an LV before a trailing jamo,
			// decomposed when the font has the jamo.
			if !has || (t_index == 0 && s.idx + 1 < s.len && is_jamo_t(s.info[s.idx + 1].char)) {
				parts := [3]rune{rune(HANGUL_L + l_index), rune(HANGUL_V + v_index), rune(HANGUL_T + t_index)}
				if has_glyph(s, parts[0]) && has_glyph(s, parts[1]) && (t_index == 0 || has_glyph(s, parts[2])) {
					n := 3 if t_index != 0 else 2
					for k in 0 ..< n {
						output_char(s, parts[k], 0)
					}
					skip_glyph(s)
					if has && t_index == 0 {
						next_glyph(s)
						n += 1
					}
					end = start + n
					out := out_rows(s)
					out[start].aux = HANGUL_LJMO
					out[start + 1].aux = HANGUL_VJMO
					if start + 2 < end {
						out[start + 2].aux = HANGUL_TJMO
					}
					merge_out_clusters(s, start, end)
					continue
				}
			}
			if has {
				end = start + 1
				next_glyph(s)
				continue
			}
		}
		next_glyph(s)
	}
	swap_buffers(s)
}
