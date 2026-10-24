package shape

// The glyph buffer: a row per glyph (what it is, its cluster, mask and
// properties) and its position, in logical order until positioning ends.
// Substitutions read the rows at `idx` and write them out at `out_len`:
// in place while the output keeps behind the input, into the second row
// array once it would overtake it (a multiple substitution), swapped in
// when the lookup ends. The rows are copied whole, so they are rows, not
// columns; positions are a separate array GSUB never touches.

Glyph_Info :: struct {
	// The character, then the glyph it maps to (and what GSUB makes it).
	char:     rune,
	glyph:    u16,
	// GDEF class and substitution bits (GLYPH_*), mark attachment class in
	// the high byte.
	props:    u16,
	// The character's general category and flags (UPROP_*), and in the
	// high byte a mark's combining class, a space's kind or the joiner bits.
	unicode:  u16,
	// Ligature id (3 bits), whether it is a ligature, and the component it
	// belongs to (or the ligature's component count).
	lig:      u8,
	syllable: u8,
	mask:     u32,
	cluster:  i32,
	// Script shapers' per-glyph facts: a character category (Indic, USE)
	// and an auxiliary value (a position in the syllable, Arabic's joining
	// action, Hangul's jamo feature).
	category: u8,
	aux:      u8,
}

Glyph_Pos :: struct {
	x_advance:    i32,
	x_offset:     i32,
	y_offset:     i32,
	// The glyph this one attaches to, relative to it (0 for none), and
	// how (ATTACH_*).
	attach_chain: i16,
	attach_type:  u8,
}

ATTACH_MARK :: 1
ATTACH_CURSIVE :: 2

// Glyph_Info.unicode: the general category in the low 5 bits, then flags.
UPROP_GC :: 0x1F
UPROP_IGNORABLE :: 0x20
UPROP_HIDDEN :: 0x40
UPROP_CONTINUATION :: 0x80
// High byte of a format character's props.
UPROP_ZWNJ :: 0x0100
UPROP_ZWJ :: 0x0200

// Lig: id in the top 3 bits, the ligature bit, the component (4 bits).
@(private)
LIG_IS_BASE :: 0x10

// Shaping stops growing the buffer past this many times the text (or a
// minimum), and stops applying lookups after this many operations per
// character: corrupt fonts can't loop or grow without bound.
@(private)
MAX_LEN_FACTOR :: 64
@(private)
MAX_LEN_MIN :: 16384
@(private)
MAX_OPS_FACTOR :: 1024
@(private)
MAX_OPS_MIN :: 16384

Scratch_Flag :: enum u8 {
	Has_Non_ASCII,
	Has_Default_Ignorables,
	Has_Space_Fallback,
	Has_GPOS_Attachment,
	Has_CGJ,
	// Arabic: stch multiplied glyphs to tile.
	Has_Stch,
	// A syllable machine found a broken syllable (it takes a dotted circle).
	Has_Broken_Syllable,
}

// ---- row facts ----------------------------------------------------------------------

gc_of :: #force_inline proc "contextless" (info: Glyph_Info) -> General_Category {
	return General_Category(info.unicode & UPROP_GC)
}

is_unicode_mark :: #force_inline proc "contextless" (info: Glyph_Info) -> bool {
	return gc_is_mark(gc_of(info))
}

// The modified combining class of a mark (0 for others).
mcc_of :: #force_inline proc "contextless" (info: Glyph_Info) -> u8 {
	return u8(info.unicode >> 8) if is_unicode_mark(info) else 0
}

is_zwnj :: #force_inline proc "contextless" (info: Glyph_Info) -> bool {
	return gc_of(info) == .Cf && info.unicode & UPROP_ZWNJ != 0
}

is_zwj :: #force_inline proc "contextless" (info: Glyph_Info) -> bool {
	return gc_of(info) == .Cf && info.unicode & UPROP_ZWJ != 0
}

// A default ignorable not yet replaced by GSUB.
is_ignorable :: #force_inline proc "contextless" (info: Glyph_Info) -> bool {
	return info.unicode & UPROP_IGNORABLE != 0 && info.props & GLYPH_SUBSTITUTED == 0
}

is_hidden :: #force_inline proc "contextless" (info: Glyph_Info) -> bool {
	return info.unicode & UPROP_HIDDEN != 0
}

is_continuation :: #force_inline proc "contextless" (info: Glyph_Info) -> bool {
	return info.unicode & UPROP_CONTINUATION != 0
}

is_mark :: #force_inline proc "contextless" (info: Glyph_Info) -> bool {
	return info.props & GLYPH_MARK != 0
}

is_ligature :: #force_inline proc "contextless" (info: Glyph_Info) -> bool {
	return info.props & GLYPH_LIGATURE != 0
}

is_base_glyph :: #force_inline proc "contextless" (info: Glyph_Info) -> bool {
	return info.props & GLYPH_BASE != 0
}

is_multiplied :: #force_inline proc "contextless" (info: Glyph_Info) -> bool {
	return info.props & GLYPH_MULTIPLIED != 0
}

lig_id :: #force_inline proc "contextless" (info: Glyph_Info) -> u8 {
	return info.lig >> 5
}

// The component a mark belongs to (0 for a ligature itself).
lig_comp :: #force_inline proc "contextless" (info: Glyph_Info) -> u8 {
	return 0 if info.lig & LIG_IS_BASE != 0 else info.lig & 0x0F
}

lig_num_comps :: #force_inline proc "contextless" (info: Glyph_Info) -> u8 {
	return info.lig & 0x0F if info.props & GLYPH_LIGATURE != 0 && info.lig & LIG_IS_BASE != 0 else 1
}

// The components a glyph adds to a ligature it takes part in: none for a
// later piece of a multiple substitution (its marks belong to the first).
lig_num_comps_in_ligation :: #force_inline proc "contextless" (info: Glyph_Info) -> u8 {
	return 0 if is_multiplied(info) && lig_comp(info) != 0 else lig_num_comps(info)
}

set_lig_for_ligature :: #force_inline proc "contextless" (info: ^Glyph_Info, id, num_comps: u8) {
	info.lig = id << 5 | LIG_IS_BASE | num_comps & 0x0F
}

set_lig_for_mark :: #force_inline proc "contextless" (info: ^Glyph_Info, id, comp: u8) {
	info.lig = id << 5 | comp & 0x0F
}

// Sets a row's Unicode facts from its character.
init_unicode :: proc(s: ^Shaper, info: ^Glyph_Info) {
	r := info.char
	p := char_props(r)
	u := u16(p.gc)
	if r >= 0x80 {
		s.flags += {.Has_Non_ASCII}
		if is_default_ignorable(r) {
			u |= UPROP_IGNORABLE
			s.flags += {.Has_Default_Ignorables}
			switch r {
			case 0x200C:
				u |= UPROP_ZWNJ
			case 0x200D:
				u |= UPROP_ZWJ
			case 0x180B ..= 0x180D, 0x180F, 0xE0020 ..= 0xE007F:
				// Mongolian free variation selectors and tags: hidden like
				// ignorables, yet seen by lookups.
				u |= UPROP_HIDDEN
			case 0x034F:
				// COMBINING GRAPHEME JOINER: seen by lookups unless it
				// blocks no reordering (normalize).
				u |= UPROP_HIDDEN
				s.flags += {.Has_CGJ}
			}
		}
		if gc_is_mark(p.gc) {
			u |= UPROP_CONTINUATION | u16(modified_ccc(r)) << 8
		}
	}
	info.unicode = u
}

// ---- buffer operations --------------------------------------------------------------

// The rows output so far: the input rows themselves until the output
// separates.
out_rows :: #force_inline proc "contextless" (s: ^Shaper) -> []Glyph_Info {
	return s.out[:] if s.separate else s.info[:]
}

// Room for `size` rows in every array (grown geometrically); false when
// that exceeds the buffer's limit.
@(private)
ensure :: proc(s: ^Shaper, size: int) -> bool {
	if size <= len(s.info) {
		return true
	}
	if size > s.max_len {
		s.ok = false
		return false
	}
	n := max(size, 2 * len(s.info), 64)
	resize(&s.info, n)
	resize(&s.out, n)
	resize(&s.pos, n)
	return true
}

@(private)
clear_output :: proc(s: ^Shaper) {
	s.have_output = true
	s.separate = false
	s.idx = 0
	s.out_len = 0
}

// Ends a pass of output: the rest of the input is kept and the output
// becomes the input.
@(private)
swap_buffers :: proc(s: ^Shaper) {
	if !s.ok {
		s.have_output = false
		s.out_len = 0
		s.idx = 0
		return
	}
	next_glyphs(s, s.len - s.idx)
	if s.separate {
		s.info, s.out = s.out, s.info
	}
	s.len = s.out_len
	s.have_output = false
	s.separate = false
	s.out_len = 0
	s.idx = 0
}

// Room to output `num_out` rows for `num_in` read: the output separates
// from the input when it would overtake it.
@(private)
make_room_for :: proc(s: ^Shaper, num_in, num_out: int) -> bool {
	if !ensure(s, s.out_len + num_out) {
		return false
	}
	if !s.separate && s.out_len + num_out > s.idx + num_in {
		s.separate = true
		copy(s.out[:s.out_len], s.info[:s.out_len])
	}
	return true
}

// Copies the current row to the output.
next_glyph :: proc(s: ^Shaper) {
	if s.have_output {
		if s.separate || s.out_len != s.idx {
			if !make_room_for(s, 1, 1) {
				return
			}
			out_rows(s)[s.out_len] = s.info[s.idx]
		}
		s.out_len += 1
	}
	s.idx += 1
}

next_glyphs :: proc(s: ^Shaper, n: int) {
	if s.have_output {
		if s.separate || s.out_len != s.idx {
			if !make_room_for(s, n, n) {
				return
			}
			copy(out_rows(s)[s.out_len:][:n], s.info[s.idx:][:n])
		}
		s.out_len += n
	}
	s.idx += n
}

// Drops the current row.
skip_glyph :: #force_inline proc "contextless" (s: ^Shaper) {
	s.idx += 1
}

// Outputs the current row with a new glyph and moves on.
replace_glyph :: proc(s: ^Shaper, g: u16) {
	if s.separate || s.out_len != s.idx {
		if !make_room_for(s, 1, 1) {
			return
		}
		out_rows(s)[s.out_len] = s.info[s.idx]
	}
	out_rows(s)[s.out_len].glyph = g
	s.idx += 1
	s.out_len += 1
}

// Outputs a copy of the current row (the last output row at the end) with
// a new glyph, staying on the current row.
output_glyph :: proc(s: ^Shaper, g: u16) {
	if !make_room_for(s, 0, 1) {
		return
	}
	if s.idx == s.len && s.out_len == 0 {
		return
	}
	out := out_rows(s)
	out[s.out_len] = s.info[s.idx] if s.idx < s.len else out[s.out_len - 1]
	out[s.out_len].glyph = g
	s.out_len += 1
}

// Outputs a row for character `r` (mapped to `g`) built from the current
// row, staying on it.
output_char :: proc(s: ^Shaper, r: rune, g: u16) {
	if !make_room_for(s, 0, 1) {
		return
	}
	out := out_rows(s)
	out[s.out_len] = s.info[s.idx]
	out[s.out_len].char = r
	out[s.out_len].glyph = g
	init_unicode(s, &out[s.out_len])
	s.out_len += 1
}

// Moves the output position to `i` (output rows counted, then input):
// forward copies rows out, backward puts output rows back in front.
move_to :: proc(s: ^Shaper, i: int) -> bool {
	if !s.have_output {
		s.idx = i
		return true
	}
	if !s.ok {
		return false
	}
	if s.out_len < i {
		count := i - s.out_len
		if !make_room_for(s, count, count) {
			return false
		}
		copy(out_rows(s)[s.out_len:][:count], s.info[s.idx:][:count])
		s.idx += count
		s.out_len += count
	} else if s.out_len > i {
		count := s.out_len - i
		if s.idx < count {
			// Shift the input forward to make room in front of it.
			shift := count - s.idx
			if !ensure(s, s.len + shift) {
				return false
			}
			copy(s.info[s.idx + shift:s.len + shift], s.info[s.idx:s.len])
			s.len += shift
			s.idx += shift
		}
		s.idx -= count
		s.out_len -= count
		copy(s.info[s.idx:][:count], out_rows(s)[s.out_len:][:count])
	}
	return true
}

// The rows' cluster becomes the smallest among rows start ..< end, and so
// do clusters they share with neighbours (output rows included).
merge_clusters :: proc(s: ^Shaper, start, end: int) {
	if end - start < 2 {
		return
	}
	start, end := start, end
	info := s.info[:]
	cluster := info[start].cluster
	for i in start + 1 ..< end {
		cluster = min(cluster, info[i].cluster)
	}
	if cluster != info[end - 1].cluster {
		for end < s.len && info[end - 1].cluster == info[end].cluster {
			end += 1
		}
	}
	if cluster != info[start].cluster {
		for s.idx < start && info[start - 1].cluster == info[start].cluster {
			start -= 1
		}
	}
	if s.idx == start && info[start].cluster != cluster {
		out := out_rows(s)
		for i := s.out_len; i > 0 && out[i - 1].cluster == info[start].cluster; i -= 1 {
			out[i - 1].cluster = cluster
		}
	}
	for i in start ..< end {
		info[i].cluster = cluster
	}
}

// merge_clusters over output rows.
merge_out_clusters :: proc(s: ^Shaper, start, end: int) {
	if end - start < 2 {
		return
	}
	start, end := start, end
	out := out_rows(s)
	cluster := out[start].cluster
	for i in start + 1 ..< end {
		cluster = min(cluster, out[i].cluster)
	}
	for start > 0 && out[start - 1].cluster == out[start].cluster {
		start -= 1
	}
	for end < s.out_len && out[end - 1].cluster == out[end].cluster {
		end += 1
	}
	if end == s.out_len {
		for i := s.idx; i < s.len && s.info[i].cluster == out[end - 1].cluster; i += 1 {
			s.info[i].cluster = cluster
		}
	}
	for i in start ..< end {
		out[i].cluster = cluster
	}
}

// Deletes the current row, merging its cluster into a neighbour's when
// no other row holds it.
delete_glyph :: proc(s: ^Shaper) {
	cluster := s.info[s.idx].cluster
	if s.idx + 1 < s.len && cluster == s.info[s.idx + 1].cluster {
		skip_glyph(s)
		return
	}
	if s.out_len != 0 {
		out := out_rows(s)
		if cluster < out[s.out_len - 1].cluster {
			old := out[s.out_len - 1].cluster
			for i := s.out_len; i > 0 && out[i - 1].cluster == old; i -= 1 {
				out[i - 1].cluster = cluster
			}
		}
		skip_glyph(s)
		return
	}
	if s.idx + 1 < s.len {
		merge_clusters(s, s.idx, s.idx + 2)
	}
	skip_glyph(s)
}

// Reverses rows (and positions) start ..< end.
reverse_range :: proc(s: ^Shaper, start, end: int) {
	for i, j := start, end - 1; i < j; i, j = i + 1, j - 1 {
		s.info[i], s.info[j] = s.info[j], s.info[i]
		s.pos[i], s.pos[j] = s.pos[j], s.pos[i]
	}
}

// A new ligature id (1 ..= 7, cycling).
@(private)
allocate_lig_id :: proc(s: ^Shaper) -> u8 {
	s.serial += 1
	id := u8(s.serial & 7)
	if id == 0 {
		s.serial += 1
		id = u8(s.serial & 7)
	}
	return id
}

// Each grapheme (a character and the continuations after it) as start,
// end pairs: calls `f` for each.
@(private)
next_grapheme :: proc(s: ^Shaper, start: int) -> int {
	end := start + 1
	for end < s.len && is_continuation(s.info[end]) {
		end += 1
	}
	return end
}
