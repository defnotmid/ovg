package font

// The code points the face's cmap maps to a glyph other than 0, ascending:
// exactly those `glyph_index` maps. Writes the first len(out) into `out` and
// returns how many there are, so a call with nil sizes `out`. The cmap's
// ranges are walked in order past the last one covered and clamped to
// Unicode, so a malformed table costs at most one pass over U+0..U+10FFFF.
codepoints :: proc(f: ^Face, out: []rune) -> (n: int) {
	c := &f.cmap
	next := 0
	span :: proc(f: ^Face, out: []rune, n, next: ^int, first, last: int) {
		for cp in max(first, next^) ..= min(last, 0x10FFFF) {
			if glyph_index(f, rune(cp)) != 0 {
				if n^ < len(out) {
					out[n^] = rune(cp)
				}
				n^ += 1
			}
		}
		next^ = max(next^, min(last, 0x10FFFF) + 1)
	}
	switch c.format {
	case 0:
		span(f, out, &n, &next, 0, len(c.bytes) - 1)
	case 4:
		for end, i in c.ends {
			span(f, out, &n, &next, int(c.starts[i].v), int(end.v))
		}
	case 6:
		span(f, out, &n, &next, c.first, c.first + len(c.glyphs) - 1)
	case 12, 13:
		for g in c.groups {
			span(f, out, &n, &next, int(g.first), int(g.last))
		}
	}
	return n
}
