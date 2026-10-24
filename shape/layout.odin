package shape

import "base:runtime"
import ft "../font"

// A face's OpenType layout tables (GSUB, GPOS, GDEF and the legacy kern
// table) prepared once: where each table's lists lie, every lookup's type,
// flags and subtables with extensions resolved, each subtable's coverage.
// Plans (plan.odin) pick lookups from it by index and the shaper applies
// them reading the font's bytes, bounds-checked like ovg/font: a corrupt
// table shapes wrongly, never out of bounds.

Table_Kind :: enum u8 {
	GSUB,
	GPOS,
}

// LookupFlag bits.
LOOKUP_RIGHT_TO_LEFT :: 0x0001
LOOKUP_IGNORE_BASE :: 0x0002
LOOKUP_IGNORE_LIGATURES :: 0x0004
LOOKUP_IGNORE_MARKS :: 0x0008
LOOKUP_IGNORE_FLAGS :: LOOKUP_IGNORE_BASE | LOOKUP_IGNORE_LIGATURES | LOOKUP_IGNORE_MARKS
LOOKUP_USE_MARK_FILTERING_SET :: 0x0010
LOOKUP_MARK_ATTACHMENT_TYPE :: 0xFF00

// GSUB lookup types (extensions resolved to the type they wrap).
GSUB_SINGLE :: 1
GSUB_MULTIPLE :: 2
GSUB_ALTERNATE :: 3
GSUB_LIGATURE :: 4
GSUB_CONTEXT :: 5
GSUB_CHAIN_CONTEXT :: 6
GSUB_EXTENSION :: 7
GSUB_REVERSE_CHAIN :: 8

GPOS_SINGLE :: 1
GPOS_PAIR :: 2
GPOS_CURSIVE :: 3
GPOS_MARK_BASE :: 4
GPOS_MARK_LIGATURE :: 5
GPOS_MARK_MARK :: 6
GPOS_CONTEXT :: 7
GPOS_CHAIN_CONTEXT :: 8
GPOS_EXTENSION :: 9

Lookup :: struct {
	type:   u8,
	// LookupFlag in the low 16 bits, the mark filtering set above them.
	props:  u32,
	// Its subtables in Layout_Table.subtables.
	first:  i32,
	count:  i32,
	// The glyphs its subtables start at, as a digest: a glyph it lacks is
	// surely not covered (most glyphs, for most lookups).
	digest: Digest,
}

// A set of glyphs summarized as bits of three shifts of each glyph id
// (HarfBuzz's set digest): no false negatives, few false positives.
Digest :: [3]u64

@(private)
DIGEST_SHIFTS :: [3]u32{4, 0, 9}

digest_may_have :: #force_inline proc "contextless" (dg: ^Digest, g: u16) -> bool {
	shifts := DIGEST_SHIFTS
	a := dg[0] >> ((u32(g) >> shifts[0]) & 63)
	b := dg[1] >> ((u32(g) >> shifts[1]) & 63)
	c := dg[2] >> ((u32(g) >> shifts[2]) & 63)
	return (a & b & c & 1) != 0
}

digests_intersect :: #force_inline proc "contextless" (a, b: ^Digest) -> bool {
	return a[0] & b[0] != 0 && a[1] & b[1] != 0 && a[2] & b[2] != 0
}

@(private)
digest_add_range :: proc "contextless" (dg: ^Digest, a, b: u16) {
	shifts := DIGEST_SHIFTS
	for k in 0 ..< 3 {
		lo, hi := u32(a) >> shifts[k], u32(b) >> shifts[k]
		if hi - lo >= 63 {
			dg[k] = ~u64(0)
			continue
		}
		for v in lo ..= hi {
			dg[k] |= 1 << (v & 63)
		}
	}
}

// Adds a coverage table's glyphs; false when `budget` (glyphs to add)
// runs out first.
@(private)
digest_add_coverage :: proc(dg: ^Digest, d: []u8, t: int, budget: ^int) -> bool {
	if t == 0 {
		return true
	}
	count := int(ft.read_u16(d, t + 2))
	switch ft.read_u16(d, t) {
	case 1:
		n := min(count, max(len(d) - t - 4, 0) / 2)
		budget^ -= n
		if budget^ < 0 {
			return false
		}
		for i in 0 ..< n {
			g := ft.read_u16(d, t + 4 + 2 * i)
			digest_add_range(dg, g, g)
		}
	case 2:
		n := min(count, max(len(d) - t - 4, 0) / 6)
		budget^ -= n
		if budget^ < 0 {
			return false
		}
		for i in 0 ..< n {
			r := t + 4 + 6 * i
			a, b := ft.read_u16(d, r), ft.read_u16(d, r + 2)
			if a <= b {
				digest_add_range(dg, a, b)
			}
		}
	}
	return true
}

Subtable :: struct {
	// Where the subtable lies, and the coverage of the glyph it starts
	// matching at (0 when it has none), with its digest.
	at:       i32,
	coverage: i32,
	digest:   Digest,
}

Layout_Table :: struct {
	// 0 when the face has no such table (or it can't be read).
	at:                 int,
	scripts:            int,
	features:           int,
	feature_variations: int,
	lookups:            []Lookup,
	subtables:          []Subtable,
}

Layout :: struct {
	data:                []u8,
	tables:              [Table_Kind]Layout_Table,
	// GDEF's class definitions, mark glyph sets and variation store
	// (0 for each it lacks).
	gdef:                int,
	glyph_classes:       int,
	mark_attach_classes: int,
	mark_sets:           int,
	var_store:           int,
	// The legacy kern table (0 for none).
	kern:                int,
	allocator:           runtime.Allocator,
}

// Where the table tagged `tag` lies in face `f` (at 0 for none).
find_table :: proc(f: ^ft.Face, tag: string) -> (at, size: int) {
	d := f.data
	count := int(ft.read_u16(d, f.start + 4))
	for i in 0 ..< count {
		rec := f.start + 12 + i * 16
		if rec + 16 <= len(d) && string(d[rec:rec + 4]) == tag {
			at, size = int(ft.read_u32(d, rec + 8)), int(ft.read_u32(d, rec + 12))
			if at <= 0 || at >= len(d) {
				return 0, 0
			}
			return at, min(size, len(d) - at)
		}
	}
	return 0, 0
}

// Prepares face `f`'s layout tables into `l`. The face's data is borrowed
// and must outlive the layout.
layout_init :: proc(l: ^Layout, f: ^ft.Face, allocator := context.allocator) {
	l^ = {data = f.data, allocator = allocator}
	d := f.data
	gsub, gsub_size := find_table(f, "GSUB")
	gpos, gpos_size := find_table(f, "GPOS")
	if gdef, _ := find_table(f, "GDEF"); gdef != 0 && ft.read_u16(d, gdef) == 1 {
		l.gdef = gdef
		minor := ft.read_u16(d, gdef + 2)
		l.glyph_classes = offset16(d, gdef, gdef + 4)
		l.mark_attach_classes = offset16(d, gdef, gdef + 10)
		if minor >= 2 {
			l.mark_sets = offset16(d, gdef, gdef + 12)
		}
		if minor >= 3 {
			l.var_store = offset32(d, gdef, gdef + 14)
		}
	}
	layout_table_init(l, .GSUB, gsub, gsub_size)
	layout_table_init(l, .GPOS, gpos, gpos_size)
	if kern, _ := find_table(f, "kern"); kern != 0 {
		l.kern = kern
	}
}

layout_destroy :: proc(l: ^Layout) {
	for &t in l.tables {
		delete(t.lookups, l.allocator)
		delete(t.subtables, l.allocator)
	}
	l^ = {}
}

// The table an offset at `at` (from `base`) points to; 0 for a null offset.
@(private)
offset16 :: #force_inline proc "contextless" (d: []u8, base, at: int) -> int {
	o := int(ft.read_u16(d, at))
	return base + o if o != 0 else 0
}

@(private)
offset32 :: #force_inline proc "contextless" (d: []u8, base, at: int) -> int {
	o := int(ft.read_u32(d, at))
	return base + o if o != 0 && base + o < len(d) else 0
}

@(private)
layout_table_init :: proc(l: ^Layout, kind: Table_Kind, at, size: int) {
	d := l.data
	if at == 0 || ft.read_u16(d, at) != 1 {
		return
	}
	t := &l.tables[kind]
	t.at = at
	t.scripts = offset16(d, at, at + 4)
	t.features = offset16(d, at, at + 6)
	list := offset16(d, at, at + 8)
	if ft.read_u16(d, at + 2) >= 1 {
		t.feature_variations = offset32(d, at, at + 10)
	}
	if list == 0 {
		return
	}
	extension: u8 = GSUB_EXTENSION if kind == .GSUB else GPOS_EXTENSION
	// Count, then fill. Valid tables give each lookup its own subtable
	// offsets, so a table holds at most size / 2 of them: a corrupt one
	// claiming more is cut there.
	lookup_count := int(ft.read_u16(d, list))
	subtable_count := 0
	for i in 0 ..< lookup_count {
		lookup := offset16(d, list, list + 2 + 2 * i)
		subtable_count += int(ft.read_u16(d, lookup + 4))
	}
	subtable_count = min(subtable_count, size / 2)
	t.lookups = make([]Lookup, lookup_count, l.allocator)
	t.subtables = make([]Subtable, subtable_count, l.allocator)
	// Coverages are shared between subtables, so digesting them reads more
	// than the table; a corrupt table sharing one huge coverage everywhere
	// would read without end, so past a generous budget lookups take full
	// digests (always tried).
	budget := 8 * size + 65536
	n := 0
	for i in 0 ..< lookup_count {
		lookup := offset16(d, list, list + 2 + 2 * i)
		lk := &t.lookups[i]
		lk.type = u8(ft.read_u16(d, lookup))
		flags := ft.read_u16(d, lookup + 2)
		count := int(ft.read_u16(d, lookup + 4))
		lk.props = u32(flags)
		if flags & LOOKUP_USE_MARK_FILTERING_SET != 0 {
			// A set GDEF lacks: the flag is dropped (HarfBuzz's choice).
			set := ft.read_u16(d, lookup + 6 + 2 * count)
			if l.mark_sets != 0 && ft.read_u16(d, l.mark_sets) == 1 && set < ft.read_u16(d, l.mark_sets + 2) {
				lk.props |= u32(set) << 16
			} else {
				lk.props &~= LOOKUP_USE_MARK_FILTERING_SET
			}
		}
		lk.first = i32(n)
		wrapped: u8
		room := min(count, subtable_count - n)
		for k in 0 ..< room {
			sub := offset16(d, lookup, lookup + 6 + 2 * k)
			if sub == 0 {
				continue
			}
			type := lk.type
			if type == extension {
				// Format 1: the wrapped type and a 32-bit offset.
				if ft.read_u16(d, sub) != 1 {
					continue
				}
				type = u8(ft.read_u16(d, sub + 2))
				if wrapped == 0 {
					wrapped = type
				}
				if type != wrapped || type == extension {
					continue
				}
				sub = offset32(d, sub, sub + 4)
				if sub == 0 {
					continue
				}
			}
			t.subtables[n] = {i32(sub), i32(subtable_coverage(d, kind, type, sub)), {}}
			n += 1
		}
		if lk.type == extension {
			lk.type = wrapped
		}
		lk.count = i32(n) - lk.first
		for &sub in t.subtables[lk.first:n] {
			if !digest_add_coverage(&sub.digest, d, int(sub.coverage), &budget) {
				sub.digest = {~u64(0), ~u64(0), ~u64(0)}
			}
			for k in 0 ..< 3 {
				lk.digest[k] |= sub.digest[k]
			}
		}
	}
}

// The coverage table a subtable matches its first glyph against.
@(private)
subtable_coverage :: proc(d: []u8, kind: Table_Kind, type: u8, at: int) -> int {
	format := ft.read_u16(d, at)
	is_context := kind == .GSUB ? type == GSUB_CONTEXT : type == GPOS_CONTEXT
	is_chain := kind == .GSUB ? type == GSUB_CHAIN_CONTEXT : type == GPOS_CHAIN_CONTEXT
	if is_context && format == 3 {
		return offset16(d, at, at + 6)
	}
	if is_chain && format == 3 {
		backtrack := int(ft.read_u16(d, at + 2))
		return offset16(d, at, at + 4 + 2 * backtrack + 2)
	}
	return offset16(d, at, at + 2)
}

// ---- coverage and classes ---------------------------------------------------------

// The glyph's index in the coverage table at `t`; -1 when not covered.
coverage_index :: proc "contextless" (d: []u8, t: int, g: u16) -> int {
	if t == 0 {
		return -1
	}
	count := int(ft.read_u16(d, t + 2))
	switch ft.read_u16(d, t) {
	case 1:
		// Sorted glyphs.
		lo, hi := 0, min(count, (len(d) - t - 4) / 2)
		for lo < hi {
			mid := (lo + hi) / 2
			v := ft.read_u16(d, t + 4 + 2 * mid)
			if v < g {
				lo = mid + 1
			} else if v > g {
				hi = mid
			} else {
				return mid
			}
		}
	case 2:
		// Sorted ranges: first, last, coverage index of first.
		lo, hi := 0, min(count, (len(d) - t - 4) / 6)
		for lo < hi {
			mid := (lo + hi) / 2
			r := t + 4 + 6 * mid
			if ft.read_u16(d, r + 2) < g {
				lo = mid + 1
			} else if ft.read_u16(d, r) > g {
				hi = mid
			} else {
				return int(ft.read_u16(d, r + 4)) + int(g) - int(ft.read_u16(d, r))
			}
		}
	}
	return -1
}

// The glyph's class in the class definition at `t` (0 when unlisted).
class_of :: proc "contextless" (d: []u8, t: int, g: u16) -> int {
	if t == 0 {
		return 0
	}
	switch ft.read_u16(d, t) {
	case 1:
		first := ft.read_u16(d, t + 2)
		if g >= first && int(g - first) < int(ft.read_u16(d, t + 4)) {
			return int(ft.read_u16(d, t + 6 + 2 * int(g - first)))
		}
	case 2:
		lo, hi := 0, min(int(ft.read_u16(d, t + 2)), (len(d) - t - 4) / 6)
		for lo < hi {
			mid := (lo + hi) / 2
			r := t + 4 + 6 * mid
			if ft.read_u16(d, r + 2) < g {
				lo = mid + 1
			} else if ft.read_u16(d, r) > g {
				hi = mid
			} else {
				return int(ft.read_u16(d, r + 4))
			}
		}
	}
	return 0
}

// ---- GDEF ---------------------------------------------------------------------------

// Glyph property bits (the lookup flags' ignore bits, then what shaping
// did to the glyph; the mark attachment class in the high byte).
GLYPH_BASE :: 0x02
GLYPH_LIGATURE :: 0x04
GLYPH_MARK :: 0x08
GLYPH_SUBSTITUTED :: 0x10
GLYPH_LIGATED :: 0x20
GLYPH_MULTIPLIED :: 0x40

// The glyph's properties from GDEF's glyph classes.
glyph_props :: proc(l: ^Layout, g: u16) -> u16 {
	switch class_of(l.data, l.glyph_classes, g) {
	case 1:
		return GLYPH_BASE
	case 2:
		return GLYPH_LIGATURE
	case 3:
		return GLYPH_MARK | u16(class_of(l.data, l.mark_attach_classes, g)) << 8
	}
	return 0
}

// Whether mark glyph set `set` holds the glyph.
mark_set_covers :: proc(l: ^Layout, set: int, g: u16) -> bool {
	d, at := l.data, l.mark_sets
	if at == 0 || ft.read_u16(d, at) != 1 || set >= int(ft.read_u16(d, at + 2)) {
		return false
	}
	return coverage_index(d, offset32(d, at, at + 4 + 4 * set), g) >= 0
}
