package shape

// Thai and Lao: SARA AM decomposes into NIKHAHIT and SARA AA, the nikhahit
// moving back over the above-base marks before it (what Uniscribe does;
// <0E14, 0E4B, 0E33> becomes <0E14, 0E4D, 0E4B, 0E32>). Lao's characters
// are Thai's plus 0x80.

@(private)
is_sara_am :: #force_inline proc "contextless" (r: rune) -> bool {
	return r & ~rune(0x80) == 0x0E33
}

@(private)
is_above_base_mark :: #force_inline proc "contextless" (r: rune) -> bool {
	u := r & ~rune(0x80)
	return (u >= 0x0E34 && u <= 0x0E37) || (u >= 0x0E47 && u <= 0x0E4E) || u == 0x0E31 || u == 0x0E3B
}

@(private)
thai_preprocess :: proc(s: ^Shaper) {
	clear_output(s)
	for s.idx < s.len && s.ok {
		r := s.info[s.idx].char
		if !is_sara_am(r) {
			next_glyph(s)
			continue
		}
		// Nikhahit (a mark, combining class 0), then sara aa.
		if !make_room_for(s, 1, 2) {
			break
		}
		out := out_rows(s)
		row := s.info[s.idx]
		nikhahit, aa := row, row
		nikhahit.char = r - 0x0E33 + 0x0E4D
		nikhahit.unicode = u16(General_Category.Mn) | row.unicode & (0xFF &~ UPROP_GC) | UPROP_CONTINUATION
		aa.char = r - 1
		out[s.out_len], out[s.out_len + 1] = nikhahit, aa
		s.out_len += 2
		s.idx += 1
		end := s.out_len
		start := end - 2
		for start > 0 && is_above_base_mark(out[start - 1].char) {
			start -= 1
		}
		if start + 2 < end {
			// The nikhahit goes before the above-base marks.
			merge_out_clusters(s, start, end)
			out = out_rows(s)
			t := out[end - 2]
			copy(out[start + 1:end - 1], out[start:end - 2])
			out[start] = t
		} else if start > 0 {
			// Decomposed into a mark: one cluster with what precedes.
			merge_out_clusters(s, start - 1, end)
		}
	}
	swap_buffers(s)
}
