package shape

import "base:intrinsics"
import "base:runtime"
import ft "../font"

// A face's OpenType layout tables (GSUB, GPOS, GDEF and the legacy kern
// table) prepared once: where each table's lists lie, every lookup's type,
// flags and subtables with extensions resolved, and the coverages and
// class definitions read for every glyph shaped unpacked for lookup by
// glyph. Plans (plan.odin) pick lookups from it by index and the shaper
// applies them reading the font's bytes, bounds-checked like ovg/font: a
// corrupt table shapes wrongly, never out of bounds.

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
	type:  u8,
	// LookupFlag in the low 16 bits, the mark filtering set above them.
	props: u32,
	// Its subtables in Layout_Table.subtables.
	first: i32,
	count: i32,
}

Subtable :: struct {
	// Where the subtable lies, and the coverage of the glyph it starts
	// matching at.
	at:       i32,
	coverage: Unpacked,
	// Class definitions: a pair adjustment's (format 2) first and second
	// glyphs' at 0 and 1; a context rule set's (format 2) backtrack, input
	// and lookahead at 0, 1 and 2.
	classes:  [3]Unpacked,
}

// A coverage table or class definition at `table` in the font (0 for
// none: covers nothing, every glyph class 0), unpacked over the glyphs it
// lists (lo ..< lo + n): a coverage as a bit per glyph from
// Layout.bits[at] with each 64 glyphs' coverage index from
// Layout.ranks[at], a class definition as a class per glyph from
// Layout.classes[at]. `at` < 0: read from the font instead (not well
// formed for reading by glyph, a class array already, or past the
// layout's budget).
Unpacked :: struct {
	table: i32,
	at:    i32,
	n:     i32,
	lo:    u16,
}

Layout_Table :: struct {
	// 0 when the face has no such table (or it can't be read).
	at:                 int,
	size:               int,
	scripts:            int,
	features:           int,
	feature_variations: int,
	lookups:            []Lookup,
	subtables:          []Subtable,
}

Layout :: struct {
	data:                []u8,
	tables:              [Table_Kind]Layout_Table,
	// GDEF's class definitions, mark glyph sets (each set's coverage) and
	// variation store (0 for each it lacks).
	gdef:                int,
	glyph_classes:       Unpacked,
	mark_attach_classes: Unpacked,
	mark_sets:           int,
	mark_set_coverages:  []Unpacked,
	var_store:           int,
	// The legacy kern table (0 for none).
	kern:                int,
	// The face's cmap: each character's glyph (0 for none).
	cmap:                Two_Level,
	// Unpacked coverages and class definitions (Unpacked).
	bits:                []u64,
	ranks:               []u16,
	classes:             []u16,
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
	gdef, gdef_size := find_table(f, "GDEF")
	if gdef != 0 && ft.read_u16(d, gdef) == 1 {
		l.gdef = gdef
		minor := ft.read_u16(d, gdef + 2)
		l.glyph_classes.table = i32(offset16(d, gdef, gdef + 4))
		l.mark_attach_classes.table = i32(offset16(d, gdef, gdef + 10))
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
	// Unpacked, at most as many bytes as the tables hold.
	layout_unpack(l, gsub_size + gpos_size + gdef_size)
	cmap_init(&l.cmap, f, allocator)
}

layout_destroy :: proc(l: ^Layout) {
	for &t in l.tables {
		delete(t.lookups, l.allocator)
		delete(t.subtables, l.allocator)
	}
	delete(l.mark_set_coverages, l.allocator)
	delete(l.cmap.stage1, l.allocator)
	delete(l.cmap.blocks, l.allocator)
	delete(l.bits, l.allocator)
	delete(l.ranks, l.allocator)
	delete(l.classes, l.allocator)
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
	t.at, t.size = at, size
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
			t.subtables[n] = {at = i32(sub), coverage = {table = i32(subtable_coverage(d, kind, type, sub))}}
			n += 1
		}
		if lk.type == extension {
			lk.type = wrapped
		}
		lk.count = i32(n) - lk.first
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
	switch unpacked_class(l, l.glyph_classes, g) {
	case 1:
		return GLYPH_BASE
	case 2:
		return GLYPH_LIGATURE
	case 3:
		return GLYPH_MARK | u16(unpacked_class(l, l.mark_attach_classes, g)) << 8
	}
	return 0
}

// Whether mark glyph set `set` holds the glyph.
mark_set_covers :: proc(l: ^Layout, set: int, g: u16) -> bool {
	return set < len(l.mark_set_coverages) && unpacked_coverage(l, l.mark_set_coverages[set], g) >= 0
}

// ---- two-level tables ----------------------------------------------------------------

// A table from keys (characters, glyphs) to 16-bit values in two levels:
// key k's value is blocks[stage1[k >> TWO_LEVEL_SHIFT] << TWO_LEVEL_SHIFT
// | k % TWO_LEVEL_BLOCK], 0 past stage1's keys. Built from spans of keys
// whose values are constant or count up by one: a block inside a constant
// span is one block shared by every such block of its value.
Two_Level :: struct {
	stage1: []u16,
	blocks: []u16,
}

// Keys from `start` (to the next span's start, or the table's end) with
// values from `value`, constant (`step` 0) or counting up (1).
Two_Level_Span :: struct {
	start: i32,
	value: u16,
	step:  u16,
}

TWO_LEVEL_SHIFT :: 7
TWO_LEVEL_BLOCK :: 1 << TWO_LEVEL_SHIFT

two_level_get :: #force_inline proc "contextless" (t: ^Two_Level, key: int) -> u16 {
	b := key >> TWO_LEVEL_SHIFT
	if uint(b) >= uint(len(t.stage1)) {
		return 0
	}
	return t.blocks[int(t.stage1[b]) << TWO_LEVEL_SHIFT | key % TWO_LEVEL_BLOCK]
}

// Builds `t` over keys 0 ..< `keys` from `spans` (in order, the first at
// key 0): each block within one constant span takes its value's shared
// block, the others are written out.
two_level_init :: proc(t: ^Two_Level, spans: []Two_Level_Span, keys: int, allocator: runtime.Allocator) {
	// Each block's span (the one holding its first key), whether one
	// constant span covers it, and the blocks: one per such value, one for
	// each other block; counted, placed, then filled run by run.
	top := 0
	for sp in spans {
		if sp.step == 0 {
			top = max(top, int(sp.value))
		}
	}
	shared := make([]u16, top + 1, context.temp_allocator)
	for &b in shared {
		b = 0xFFFF
	}
	stage1 := make([]u16, (keys + TWO_LEVEL_BLOCK - 1) >> TWO_LEVEL_SHIFT, allocator)
	first := make([]i32, len(stage1), context.temp_allocator)
	count := 0
	at := 0
	for &b, i in stage1 {
		lo, hi := i32(i << TWO_LEVEL_SHIFT), i32((i + 1) << TWO_LEVEL_SHIFT)
		for at + 1 < len(spans) && spans[at + 1].start <= lo {
			at += 1
		}
		first[i] = i32(at)
		if (at + 1 == len(spans) || spans[at + 1].start >= hi) && spans[at].step == 0 {
			v := spans[at].value
			if shared[v] == 0xFFFF {
				shared[v] = u16(count)
				count += 1
			}
			b = shared[v]
		} else {
			b = u16(count)
			count += 1
		}
	}
	blocks := make([]u16, count << TWO_LEVEL_SHIFT, allocator)
	done := make([]bool, count, context.temp_allocator)
	for b, i in stage1 {
		if done[b] {
			continue
		}
		done[b] = true
		out := blocks[int(b) << TWO_LEVEL_SHIFT:][:TWO_LEVEL_BLOCK]
		lo := i32(i << TWO_LEVEL_SHIFT)
		for j, k := int(first[i]), lo; k < lo + TWO_LEVEL_BLOCK; j += 1 {
			end := min(spans[j + 1].start, lo + TWO_LEVEL_BLOCK) if j + 1 < len(spans) else lo + TWO_LEVEL_BLOCK
			sp := spans[j]
			for key in k ..< end {
				out[key - lo] = sp.value + sp.step * u16(key - sp.start)
			}
			k = end
		}
	}
	t.stage1 = stage1
	t.blocks = blocks
}

// The face's cmap as a two-level table: the characters it maps (ascending,
// exactly those ft.glyph_index maps) in spans of consecutive characters
// with consecutive glyphs.
@(private)
cmap_init :: proc(t: ^Two_Level, f: ^ft.Face, allocator: runtime.Allocator) {
	chars := make([]rune, ft.codepoints(f, nil), context.temp_allocator)
	ft.codepoints(f, chars)
	spans := make([dynamic]Two_Level_Span, context.temp_allocator)
	append(&spans, Two_Level_Span{0, 0, 0})
	last, last_glyph := i32(-2), u16(0)
	for r in chars {
		g := u16(ft.glyph_index(f, r))
		if i32(r) == last + 1 && g == last_glyph + 1 && spans[len(spans) - 1].step == 1 {
			last, last_glyph = i32(r), g
			continue
		}
		if i32(r) != last + 1 && last >= 0 {
			append(&spans, Two_Level_Span{last + 1, 0, 0})
		}
		if top := &spans[len(spans) - 1]; top.start == i32(r) {
			top^ = {i32(r), g, 1}
		} else {
			append(&spans, Two_Level_Span{i32(r), g, 1})
		}
		last, last_glyph = i32(r), g
	}
	append(&spans, Two_Level_Span{last + 1, 0, 0})
	two_level_init(t, spans[:], int(last) + 1 if last >= 0 else 0, allocator)
}

// ---- unpacked coverages and classes -------------------------------------------------

// The glyph's index in coverage `u`; -1 when not covered.
unpacked_coverage :: #force_inline proc "contextless" (l: ^Layout, u: Unpacked, g: u16) -> int {
	if u.at < 0 {
		return coverage_index(l.data, int(u.table), g)
	}
	i := int(g) - int(u.lo)
	if uint(i) >= uint(u.n) {
		return -1
	}
	w := int(u.at) + i >> 6
	bits, below := l.bits[w], u64(1) << uint(i & 63)
	if bits & below == 0 {
		return -1
	}
	return int(l.ranks[w]) + int(intrinsics.count_ones(bits & (below - 1)))
}

// The glyph's class in class definition `u` (0 when unlisted).
unpacked_class :: #force_inline proc "contextless" (l: ^Layout, u: Unpacked, g: u16) -> int {
	if u.at < 0 {
		return class_of(l.data, int(u.table), g)
	}
	i := int(g) - int(u.lo)
	if uint(i) >= uint(u.n) {
		return 0
	}
	return int(l.classes[int(u.at) + i])
}

// Unpacks the coverages and class definitions read for every glyph
// shaped: subtables' first coverages, pair adjustment and context class
// definitions, GDEF's glyph classes and mark glyph sets. Each distinct
// table once, in that order while `budget` bytes last (the rest are read
// from the font): spans found, arrays allocated once, then filled.
@(private)
layout_unpack :: proc(l: ^Layout, budget: int) {
	d := l.data
	Slot :: struct {
		u:     ^Unpacked,
		class: bool,
	}
	slots := make([dynamic]Slot, context.temp_allocator)
	add := proc(slots: ^[dynamic]Slot, u: ^Unpacked, class: bool) {
		u.at = -1
		if u.table != 0 {
			append(slots, Slot{u, class})
		}
	}
	add(&slots, &l.glyph_classes, true)
	add(&slots, &l.mark_attach_classes, true)
	if l.mark_sets != 0 && ft.read_u16(d, l.mark_sets) == 1 {
		l.mark_set_coverages = make([]Unpacked, ft.read_u16(d, l.mark_sets + 2), l.allocator)
		for &u, set in l.mark_set_coverages {
			u.table = i32(offset32(d, l.mark_sets, l.mark_sets + 4 + 4 * set))
			add(&slots, &u, false)
		}
	}
	for kind in Table_Kind {
		t := &l.tables[kind]
		pair: u8 = GPOS_PAIR if kind == .GPOS else 0
		rules: u8 = GSUB_CONTEXT if kind == .GSUB else GPOS_CONTEXT
		chain: u8 = GSUB_CHAIN_CONTEXT if kind == .GSUB else GPOS_CHAIN_CONTEXT
		for lk in t.lookups {
			for &sub in t.subtables[lk.first:][:lk.count] {
				add(&slots, &sub.coverage, false)
				at := int(sub.at)
				if ft.read_u16(d, at) != 2 {
					continue
				}
				switch lk.type {
				case pair:
					sub.classes[0].table = i32(offset16(d, at, at + 8))
					sub.classes[1].table = i32(offset16(d, at, at + 10))
				case rules:
					sub.classes[1].table = i32(offset16(d, at, at + 4))
				case chain:
					for &u, k in sub.classes {
						u.table = i32(offset16(d, at, at + 4 + 2 * k))
					}
				}
				for &u in sub.classes {
					add(&slots, &u, true)
				}
			}
		}
	}
	// Each distinct table's span and place, in slot order.
	Key :: struct {
		table: i32,
		class: bool,
	}
	found := make(map[Key]Unpacked, allocator = context.temp_allocator)
	unpacked := make([dynamic]Key, context.temp_allocator)
	words, classes, bytes := 0, 0, 0
	for slot in slots {
		key := Key{slot.u.table, slot.class}
		if key in found {
			continue
		}
		u := Unpacked{table = key.table, at = -1}
		lo, n, ok := unpacked_span(d, int(key.table), key.class)
		size := n * 2 if key.class else (n + 63) / 64 * 10
		if ok && bytes + size <= budget {
			u.lo, u.n = u16(lo), i32(n)
			bytes += size
			if key.class {
				u.at = i32(classes)
				classes += n
			} else {
				u.at = i32(words)
				words += (n + 63) / 64
			}
			append(&unpacked, key)
		}
		found[key] = u
	}
	l.bits = make([]u64, words, l.allocator)
	l.ranks = make([]u16, words, l.allocator)
	l.classes = make([]u16, classes, l.allocator)
	for key in unpacked {
		u := found[key]
		if key.class {
			unpack_classes(d, int(key.table), u, l.classes[u.at:][:u.n])
		} else {
			count := int(u.n + 63) / 64
			unpack_coverage(d, int(key.table), u, l.bits[u.at:][:count], l.ranks[u.at:][:count])
		}
	}
	for slot in slots {
		slot.u^ = found[{slot.u.table, slot.class}]
	}
}

// The glyphs the table at `t` lists, lo ..< lo + n; ok when it can be
// unpacked: its glyphs (or ranges) in order without overlap, a coverage's
// ranges numbering its glyphs in order (so a glyph's index is how many
// covered glyphs precede it). A class definition's format 1 is a class
// per glyph already.
@(private)
unpacked_span :: proc(d: []u8, t: int, class: bool) -> (lo, n: int, ok: bool) {
	format := ft.read_u16(d, t)
	prev, index := -1, 0
	switch {
	case format == 1 && !class:
		count := min(int(ft.read_u16(d, t + 2)), max(len(d) - t - 4, 0) / 2)
		for i in 0 ..< count {
			g := int(ft.read_u16(d, t + 4 + 2 * i))
			if g <= prev {
				return
			}
			if i == 0 {
				lo = g
			}
			prev = g
		}
	case format == 2:
		count := min(int(ft.read_u16(d, t + 2)), max(len(d) - t - 4, 0) / 6)
		for i in 0 ..< count {
			r := t + 4 + 6 * i
			a, b := int(ft.read_u16(d, r)), int(ft.read_u16(d, r + 2))
			if a > b || a <= prev || (!class && int(ft.read_u16(d, r + 4)) != index) {
				return
			}
			if i == 0 {
				lo = a
			}
			prev = b
			index += b - a + 1
		}
	case:
		return
	}
	return lo, prev + 1 - lo, prev >= 0
}

// Sets a coverage's glyphs in `bits` (from u.lo) and each word's coverage
// index of its first glyph in `ranks`.
@(private)
unpack_coverage :: proc(d: []u8, t: int, u: Unpacked, bits: []u64, ranks: []u16) {
	lo := int(u.lo)
	if ft.read_u16(d, t) == 1 {
		count := min(int(ft.read_u16(d, t + 2)), max(len(d) - t - 4, 0) / 2)
		for i in 0 ..< count {
			g := int(ft.read_u16(d, t + 4 + 2 * i)) - lo
			bits[g >> 6] |= 1 << uint(g & 63)
		}
	} else {
		count := min(int(ft.read_u16(d, t + 2)), max(len(d) - t - 4, 0) / 6)
		for i in 0 ..< count {
			r := t + 4 + 6 * i
			for g in int(ft.read_u16(d, r)) - lo ..= int(ft.read_u16(d, r + 2)) - lo {
				bits[g >> 6] |= 1 << uint(g & 63)
			}
		}
	}
	rank := 0
	for w, i in bits {
		ranks[i] = u16(rank)
		rank += int(intrinsics.count_ones(w))
	}
}

// Fills `classes` (from u.lo) from a class definition's ranges.
@(private)
unpack_classes :: proc(d: []u8, t: int, u: Unpacked, classes: []u16) {
	lo := int(u.lo)
	count := min(int(ft.read_u16(d, t + 2)), max(len(d) - t - 4, 0) / 6)
	for i in 0 ..< count {
		r := t + 4 + 6 * i
		class := ft.read_u16(d, r + 4)
		for g in int(ft.read_u16(d, r)) - lo ..= int(ft.read_u16(d, r + 2)) - lo {
			classes[g] = class
		}
	}
}
