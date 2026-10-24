package shape

import "core:hash"
import "core:mem"
import "core:slice"
import ft "../font"

// A plan: which lookups of a face's GSUB and GPOS apply, in what order and
// to which glyphs, for one script, direction, language and feature set.
// Built once (`plan_init`) and kept by the caller for every segment shaped
// with those settings, as HarfBuzz keeps shape plans.
//
// Features get bits of each glyph's mask: on-by-default features share a
// global bit, others (alternates with values, features over part of the
// text, script forms) get bits of their own. A lookup applies to the
// glyphs whose mask meets the masks of the features that use it. Within a
// stage lookups run in lookup-list order; stages split where a script
// shaper needs to act between them (Arabic's joining forms, Indic's
// reordering).

// An OpenType tag, the four bytes big-endian.
Tag :: distinct u32

// The tag for a string of up to four characters (padded with spaces).
tag :: proc "contextless" (s: string) -> Tag {
	t: u32
	for i in 0 ..< 4 {
		t = t << 8 | (u32(s[i]) if i < len(s) else ' ')
	}
	return Tag(t)
}

Direction :: enum u8 {
	LTR,
	RTL,
}

// A feature setting for part or all of the text: value 0 turns it off, 1
// on, more picks an alternate.
Feature :: struct {
	tag:   Tag,
	value: u32,
	// The characters (indices into the shaped text) it applies to: start
	// ..< end, with end 0 for the end of the text.
	start: int,
	end:   int,
}

feature_is_global :: #force_inline proc "contextless" (f: Feature) -> bool {
	return f.start == 0 && f.end == 0
}

// How a feature takes part in shaping.
Feature_Flag :: enum u8 {
	// On for every glyph unless a setting turns it off.
	Global,
	// Wanted even when the font lacks it (kern from the kern table).
	Has_Fallback,
	// Its lookups don't skip ZWNJ / ZWJ when matching.
	Manual_ZWNJ,
	Manual_ZWJ,
	// rand: an alternate picked at random.
	Random,
	// Matches only within a syllable (complex scripts).
	Per_Syllable,
}

Feature_Flags :: bit_set[Feature_Flag;u8]

Plan_Lookup :: struct {
	index: u16,
	flags: Feature_Flags,
	mask:  u32,
}

Plan_Stage :: struct {
	// One past the stage's last lookup in Plan.lookups.
	end:   i32,
	pause: Pause,
}

Plan_Feature :: struct {
	tag:        Tag,
	shift:      u8,
	mask:       u32,
	// The GSUB stage its lookups are applied in.
	gsub_stage: u8,
}

Plan :: struct {
	layout:                  ^Layout,
	script:                  Script,
	direction:               Direction,
	shaper:                  Shaper_Kind,
	// The script tag each table's lookups were chosen under (0 for none).
	chosen_script:           [Table_Kind]Tag,
	// The script shaper's feature masks: Arabic's joining forms by joining
	// action (then USE's rphf and topographical forms), Hangul's jamo forms,
	// Indic's and Khmer's features in their order.
	shaper_masks:            [24]u32,
	// GPOS has mark positioning (Hebrew composes presentation forms
	// without it).
	has_gpos_mark:           bool,
	lookups:                 [Table_Kind][dynamic]Plan_Lookup,
	stages:                  [Table_Kind][dynamic]Plan_Stage,
	// The features given mask bits, sorted by tag.
	features:                [dynamic]Plan_Feature,
	global_mask:             u32,
	frac_mask, numr_mask:    u32,
	dnom_mask, rtlm_mask:    u32,
	kern_mask:               u32,
	zero_marks:              Zero_Marks,
	// GPOS positions; else the kern table kerns (when kern is on).
	apply_gpos, apply_kern:  bool,
	// No GDEF glyph classes: marks are known by their characters.
	fallback_glyph_classes:  bool,
	// No GPOS: a zeroed mark moves back over its base, and marks are
	// placed by their combining classes (fallback.odin) when the script
	// shaper wants that.
	adjust_mark_positioning: bool,
	fallback_marks:          bool,
	// Arabic's stch feature is on: stretched glyphs are tiled.
	has_stch:                bool,
	// Indic: the font's lookups are for the original (not version 2) tags.
	indic_old_spec:          bool,
	// Indic: the GSUB stage of each form (-1 when the plan lacks it).
	indic_form_stages:       [Indic_Form]i8,
	// Per table, which of its lookups can start at each glyph.
	starts:                  [Table_Kind]Lookup_Starts,
	allocator:               mem.Allocator,
}

// Which of a table's plan lookups can start at each glyph (the glyphs
// their subtables' first coverages list): glyph g's row is `rows` entry
// row_of[g] (a two-level table over all 65,536 glyph ids, built from the
// coverages' spans), `words` words with bit k for Plan.lookups[kind][k].
// Equal rows are stored once.
Lookup_Starts :: struct {
	words:  int,
	row_of: Two_Level,
	rows:   []u64,
}

// Row `r`'s bits.
starts_row :: #force_inline proc "contextless" (st: ^Lookup_Starts, r: u16) -> []u64 {
	return st.rows[int(r) * st.words:][:st.words]
}

// Glyph g's row.
starts_row_of :: #force_inline proc "contextless" (st: ^Lookup_Starts, g: u16) -> u16 {
	return two_level_get(&st.row_of, int(g))
}

// The global bit every on-by-default feature shares.
@(private)
GLOBAL_MASK :: 1

// Values at most 255 (8 bits) a feature.
@(private)
FEATURE_MAX_VALUE :: 255

// Lookups nest this deep at most (contexts calling lookups).
@(private)
MAX_NESTING :: 64

// A feature as collected, before bits are assigned.
@(private)
Feature_Info :: struct {
	tag:           Tag,
	seq:           int,
	max_value:     u32,
	default_value: u32,
	flags:         Feature_Flags,
	stage:         [Table_Kind]int,
}

// The planner's state while collecting features.
@(private)
Planner :: struct {
	plan:   ^Plan,
	infos:  [dynamic]Feature_Info,
	stage:  [Table_Kind]int,
	// Each table's stage breaks, in order.
	pauses: [Table_Kind][dynamic]Pause,
}

@(private)
add_feature :: proc(p: ^Planner, name: string, flags: Feature_Flags = {}, value: u32 = 1) {
	add_feature_tag(p, tag(name), flags, value)
}

@(private)
add_feature_tag :: proc(p: ^Planner, t: Tag, flags: Feature_Flags, value: u32) {
	append(&p.infos, Feature_Info{t, len(p.infos), value, value if .Global in flags else 0, flags, p.stage})
}

@(private)
enable_feature :: proc(p: ^Planner, name: string, flags: Feature_Flags = {}, value: u32 = 1) {
	add_feature(p, name, flags + {.Global}, value)
}

// Whether a feature was collected already.
@(private)
has_feature :: proc(p: ^Planner, name: string) -> bool {
	t := tag(name)
	for info in p.infos {
		if info.tag == t {
			return true
		}
	}
	return false
}

@(private)
add_pause :: proc(p: ^Planner, kind: Table_Kind, pause := Pause.None) {
	append(&p.pauses[kind], pause)
	p.stage[kind] += 1
}

// Plans shaping with `layout` (face `f`'s tables) for a script, direction
// and language (an OpenType language system tag; 0 for the default) with
// feature settings: their tags and values decide the plan, their ranges
// are applied per call (`shape` takes them again). The plan is for the
// face's instance as it is now (FeatureVariations pick lookups by it):
// after set_variations, plan again. Scratch comes from the temp allocator.
plan_init :: proc(p: ^Plan, layout: ^Layout, f: ^ft.Face, script: Script, direction: Direction, language: Tag = 0, features: []Feature = nil, allocator := context.allocator) {
	p^ = {layout = layout, script = script, direction = direction, allocator = allocator}
	for kind in Table_Kind {
		p.lookups[kind] = make([dynamic]Plan_Lookup, allocator)
		p.stages[kind] = make([dynamic]Plan_Stage, allocator)
	}
	p.features = make([dynamic]Plan_Feature, allocator)

	for kind in Table_Kind {
		_, p.chosen_script[kind], _ = select_langsys(layout, kind, script, language)
	}
	p.shaper = choose_shaper(script, p.chosen_script[.GSUB])
	info := SHAPERS[p.shaper]

	pl := Planner{plan = p}
	pl.infos = make([dynamic]Feature_Info, context.temp_allocator)
	for kind in Table_Kind {
		pl.pauses[kind] = make([dynamic]Pause, context.temp_allocator)
	}
	collect_features(&pl, features)
	compile(&pl, f, language)
	shaper_plan(p)
	for kind in Table_Kind {
		lookup_starts_init(&p.starts[kind], layout, kind, p.lookups[kind][:], allocator)
	}

	// Who positions: GPOS when the face has it (and, for scripts whose
	// shaper asks, it has the script's own lookups), the kern table when
	// GPOS has no kern feature.
	d := layout.data
	p.apply_gpos = layout.tables[.GPOS].at != 0 && (info.gpos_tag == "" || p.chosen_script[.GPOS] == tag(info.gpos_tag))
	has_gpos_kern := false
	for feat in p.features {
		if feat.tag == tag("kern") {
			p.kern_mask = feat.mask
		}
	}
	if p.apply_gpos {
		has_gpos_kern = lookups_of_feature_exist(layout, .GPOS, script, language, tag("kern"))
	}
	// The legacy kern table only for the shapers that position fallback
	// marks (others' scripts have GPOS).
	p.apply_kern = info.fallback_marks && layout.kern != 0 && (!has_gpos_kern || !p.apply_gpos) && ft.read_u16(d, layout.kern + 2) > 0
	p.fallback_glyph_classes = layout.glyph_classes.table == 0
	p.zero_marks = info.zero_marks
	if p.apply_kern && kern_has_state_machine(layout) {
		p.zero_marks = .None
	}
	p.adjust_mark_positioning = !p.apply_gpos
	p.fallback_marks = p.adjust_mark_positioning && info.fallback_marks
	p.has_gpos_mark = one_mask(p, "mark") != 0
}

plan_destroy :: proc(p: ^Plan) {
	for kind in Table_Kind {
		delete(p.lookups[kind])
		delete(p.stages[kind])
		delete(p.starts[kind].row_of.stage1, p.allocator)
		delete(p.starts[kind].row_of.blocks, p.allocator)
		delete(p.starts[kind].rows, p.allocator)
	}
	delete(p.features)
	p^ = {}
}

// Builds a table's Lookup_Starts: each lookup's covered spans as edges
// (+1 at a span's first glyph, -1 past its last), sorted and swept into
// spans of glyphs with one row each, then blocks. Past as many edges as
// the table has bytes (work in proportion to the font) a lookup covers
// every glyph, as does every lookup when the rows would outnumber 16 bits.
@(private)
lookup_starts_init :: proc(st: ^Lookup_Starts, l: ^Layout, kind: Table_Kind, lookups: []Plan_Lookup, allocator: mem.Allocator) {
	n := len(lookups)
	if n == 0 {
		return
	}
	words := (n + 63) / 64
	st.words = words
	d := l.data
	t := &l.tables[kind]
	// Each lookup's coverage edges (subtables sharing a coverage give it
	// again; the sweep counts overlaps): counted, a lookup past the budget
	// taking one span over every glyph, placed once, filled, sorted by
	// glyph.
	budget := max(t.size, 2)
	spans := make([]int, n, context.temp_allocator)
	total := 0
	for pl, k in lookups {
		lk := t.lookups[pl.index]
		room := max(budget - total, 0) / 2
		for sub in t.subtables[lk.first:][:lk.count] {
			if spans[k] += coverage_edges(d, int(sub.coverage.table), i32(k), nil, room - spans[k]); spans[k] > room {
				spans[k] = -1
				break
			}
		}
		total += 2 * spans[k] if spans[k] >= 0 else 2
	}
	edges := make([]Start_Edge, total, context.temp_allocator)
	at := 0
	for pl, k in lookups {
		if spans[k] < 0 {
			edges[at], edges[at + 1] = {0, i32(k), 1}, {1 << 16, i32(k), -1}
			at += 2
			continue
		}
		lk := t.lookups[pl.index]
		for sub in t.subtables[lk.first:][:lk.count] {
			at += 2 * coverage_edges(d, int(sub.coverage.table), i32(k), edges[at:], len(edges))
		}
	}
	sort_edges(edges, make([]Start_Edge, total, context.temp_allocator))

	// Spans of glyphs with one row each, the rows stored once.
	glyph_spans := make([dynamic]Two_Level_Span, context.temp_allocator)
	rows := make([dynamic]u64, words, context.temp_allocator)
	// Rows by a hash of their words (a collision only stores a row twice).
	ids := make(map[u64]u16, allocator = context.temp_allocator)
	counts := make([]i32, n, context.temp_allocator)
	row := make([]u64, words, context.temp_allocator)
	ids[hash.fnv64a(mem.slice_to_bytes(row))] = 0
	append(&glyph_spans, Two_Level_Span{0, 0, 0})
	overflow := false
	for i := 0; i < len(edges) && !overflow; {
		g := edges[i].glyph
		for ; i < len(edges) && edges[i].glyph == g; i += 1 {
			e := edges[i]
			counts[e.lookup] += e.delta
			bit := u64(1) << uint(e.lookup % 64)
			if counts[e.lookup] > 0 {
				row[e.lookup / 64] |= bit
			} else {
				row[e.lookup / 64] &~= bit
			}
		}
		if g >= 1 << 16 {
			break
		}
		key := hash.fnv64a(mem.slice_to_bytes(row))
		id, found := ids[key]
		if !found || !slice.equal(rows[int(id) * words:][:words], row) {
			if len(rows) / words > 0xFFFF {
				overflow = true
				break
			}
			id = u16(len(rows) / words)
			ids[key] = id
			append(&rows, ..row)
		}
		if last := &glyph_spans[len(glyph_spans) - 1]; last.start == g {
			last.value = id
		} else if last.value != id {
			append(&glyph_spans, Two_Level_Span{g, id, 0})
		}
	}
	if overflow {
		// Every lookup at every glyph.
		clear(&glyph_spans)
		resize(&rows, 2 * words)
		for &v, i in rows[words:] {
			v = ~u64(0) >> uint(64 - min(n - 64 * i, 64))
		}
		append(&glyph_spans, Two_Level_Span{0, 1, 0})
	}
	two_level_init(&st.row_of, glyph_spans[:], 1 << 16, allocator)
	st.rows = slice.clone(rows[:], allocator)
}

@(private)
Start_Edge :: struct {
	glyph:  i32,
	lookup: i32,
	delta:  i32,
}

// The spans the coverage at `t` lists (a format 1 coverage's consecutive
// glyphs as one), each written as two edges for lookup `k` into `out`
// while they fit: a call with nil counts them. Stops past `limit` spans.
@(private)
coverage_edges :: proc(d: []u8, t: int, k: i32, out: []Start_Edge, limit: int) -> (spans: int) {
	if t == 0 {
		return
	}
	span :: #force_inline proc(out: []Start_Edge, spans: ^int, a, b: int, k: i32) {
		if 2 * spans^ + 2 <= len(out) {
			out[2 * spans^], out[2 * spans^ + 1] = {i32(a), k, 1}, {i32(b) + 1, k, -1}
		}
		spans^ += 1
	}
	switch ft.read_u16(d, t) {
	case 1:
		count := min(int(ft.read_u16(d, t + 2)), max(len(d) - t - 4, 0) / 2)
		first, last := -1, -1
		for i in 0 ..< count {
			g := int(ft.read_u16(d, t + 4 + 2 * i))
			if g == last + 1 && first >= 0 {
				last = g
				continue
			}
			if first >= 0 {
				span(out, &spans, first, last, k)
			}
			if spans > limit {
				return
			}
			first, last = g, g
		}
		if first >= 0 {
			span(out, &spans, first, last, k)
		}
	case 2:
		count := min(int(ft.read_u16(d, t + 2)), max(len(d) - t - 4, 0) / 6)
		for i in 0 ..< count {
			r := t + 4 + 6 * i
			if a, b := int(ft.read_u16(d, r)), int(ft.read_u16(d, r + 2)); a <= b {
				span(out, &spans, a, b, k)
			}
			if spans > limit {
				return
			}
		}
	}
	return
}

// Sorts edges by glyph (up to 1 << 16, the end past the last glyph):
// two stable counting passes of 9 bits, through `scratch` and back.
@(private)
sort_edges :: proc(edges, scratch: []Start_Edge) {
	src, dst := edges, scratch
	for shift in ([2]uint{0, 9}) {
		counts: [1 << 9 + 1]int
		for e in src {
			counts[int(e.glyph) >> shift & (1 << 9 - 1) + 1] += 1
		}
		for i in 1 ..< len(counts) {
			counts[i] += counts[i - 1]
		}
		for e in src {
			b := int(e.glyph) >> shift & (1 << 9 - 1)
			dst[counts[b]] = e
			counts[b] += 1
		}
		src, dst = dst, src
	}
}


// The mask (and its shift) of a feature in the plan; 0 when it has none.
plan_feature_mask :: proc(p: ^Plan, t: Tag) -> (mask: u32, shift: u8) {
	i, found := slice.binary_search_by(p.features[:], t, proc(f: Plan_Feature, t: Tag) -> slice.Ordering {
		return slice.cmp(f.tag, t)
	})
	if !found {
		return 0, 0
	}
	return p.features[i].mask, p.features[i].shift
}

// The features every plan has, in HarfBuzz's order, then the script
// shaper's and the caller's.
@(private)
collect_features :: proc(p: ^Planner, user: []Feature) {
	enable_feature(p, "rvrn")
	add_pause(p, .GSUB)
	switch p.plan.direction {
	case .LTR:
		enable_feature(p, "ltra")
		enable_feature(p, "ltrm")
	case .RTL:
		enable_feature(p, "rtla")
		add_feature(p, "rtlm")
	}
	// Automatic fractions (around U+2044 FRACTION SLASH).
	add_feature(p, "frac")
	add_feature(p, "numr")
	add_feature(p, "dnom")
	enable_feature(p, "rand", {.Random}, FEATURE_MAX_VALUE)
	enable_feature(p, "HARF")
	shaper_collect_features(p)
	enable_feature(p, "BUZZ")
	for name in ([?]string{"abvm", "blwm", "ccmp", "locl"}) {
		add_feature(p, name, {.Global})
	}
	add_feature(p, "mark", {.Global, .Manual_ZWNJ, .Manual_ZWJ})
	add_feature(p, "mkmk", {.Global, .Manual_ZWNJ, .Manual_ZWJ})
	add_feature(p, "rlig", {.Global})
	for name in ([?]string{"calt", "clig", "curs", "dist"}) {
		add_feature(p, name, {.Global})
	}
	add_feature(p, "kern", {.Global, .Has_Fallback})
	add_feature(p, "liga", {.Global})
	add_feature(p, "rclt", {.Global})
	for f in user {
		add_feature_tag(p, f.tag, {.Global} if feature_is_global(f) else {}, f.value)
	}
	shaper_override_features(p)
}

// The OpenType script tags for a script, most preferred first: Indic
// scripts' version 3 and 2 tags, then the original.
@(private)
script_tags :: proc(script: Script) -> (tags: [3]Tag, count: int) {
	new_tag: string
	#partial switch script {
	case .Bengali:
		new_tag = "bng2"
	case .Devanagari:
		new_tag = "dev2"
	case .Gujarati:
		new_tag = "gjr2"
	case .Gurmukhi:
		new_tag = "gur2"
	case .Kannada:
		new_tag = "knd2"
	case .Malayalam:
		new_tag = "mlm2"
	case .Oriya:
		new_tag = "ory2"
	case .Tamil:
		new_tag = "tml2"
	case .Telugu:
		new_tag = "tel2"
	case .Myanmar:
		new_tag = "mym2"
	}
	if new_tag != "" {
		if script != .Myanmar {
			tags[count] = tag(new_tag) & ~Tag(0xFF) | Tag('3')
			count += 1
		}
		tags[count] = tag(new_tag)
		count += 1
	}
	old: Tag
	#partial switch script {
	case .Unknown:
		return
	case .Hiragana, .Katakana:
		old = tag("kana")
	case .Lao:
		old = tag("lao ")
	case .Yi:
		old = tag("yi  ")
	case .Nko:
		old = tag("nko ")
	case .Vai:
		old = tag("vai ")
	case:
		// The ISO 15924 tag, lowercased.
		old = tag(SCRIPT_TAGS[script]) | 0x20000000
	}
	tags[count] = old
	count += 1
	return
}

// A table's script and language system for a script and language: the
// first of the script's tags the table has, else DFLT, dflt or latn (the
// tag chosen); the language's system, else dflt, else the script's
// default (0 when none).
@(private)
select_langsys :: proc(l: ^Layout, kind: Table_Kind, script: Script, language: Tag) -> (langsys: int, chosen: Tag, found: bool) {
	d := l.data
	list := l.tables[kind].scripts
	if l.tables[kind].at == 0 || list == 0 {
		return 0, 0, false
	}
	find :: proc(d: []u8, list: int, t: Tag) -> int {
		count := int(ft.read_u16(d, list))
		for i in 0 ..< count {
			rec := list + 2 + 6 * i
			if Tag(ft.read_u32(d, rec)) == t {
				return offset16(d, list, rec + 4)
			}
		}
		return 0
	}
	tags, n := script_tags(script)
	at := 0
	for t in tags[:n] {
		if at = find(d, list, t); at != 0 {
			chosen = t
			break
		}
	}
	if at == 0 {
		for t in ([?]string{"DFLT", "dflt", "latn"}) {
			if at = find(d, list, tag(t)); at != 0 {
				chosen = tag(t)
				break
			}
		}
	}
	if at == 0 {
		return 0, 0, false
	}
	// The script table: its default language system, then records.
	count := int(ft.read_u16(d, at + 2))
	dflt := 0
	for i in 0 ..< count {
		rec := at + 4 + 6 * i
		t := Tag(ft.read_u32(d, rec))
		if language != 0 && t == language {
			return offset16(d, at, rec + 4), chosen, true
		}
		if t == tag("dflt") {
			dflt = offset16(d, at, rec + 4)
		}
	}
	if dflt != 0 {
		return dflt, chosen, true
	}
	return offset16(d, at, at), chosen, true
}

// The index of the feature tagged `t` in a language system; -1 for none.
@(private)
langsys_feature :: proc(l: ^Layout, kind: Table_Kind, langsys: int, t: Tag) -> int {
	d := l.data
	features := l.tables[kind].features
	count := int(ft.read_u16(d, langsys + 4))
	for i in 0 ..< count {
		index := int(ft.read_u16(d, langsys + 6 + 2 * i))
		if Tag(ft.read_u32(d, features + 2 + 6 * index)) == t {
			return index
		}
	}
	return -1
}

@(private)
lookups_of_feature_exist :: proc(l: ^Layout, kind: Table_Kind, script: Script, language: Tag, t: Tag) -> bool {
	langsys, _, found := select_langsys(l, kind, script, language)
	return found && langsys != 0 && langsys_feature(l, kind, langsys, t) >= 0
}

// The feature table of feature `index`, or its substitute under the
// variation record `variation` (-1 for none).
@(private)
feature_table :: proc(l: ^Layout, kind: Table_Kind, index: int, variation: int) -> int {
	d := l.data
	t := &l.tables[kind]
	if variation >= 0 {
		fv := t.feature_variations
		rec := fv + 8 + 8 * variation
		subst := offset32(d, fv, rec + 4)
		if subst != 0 {
			count := int(ft.read_u16(d, subst + 4))
			for i in 0 ..< count {
				r := subst + 6 + 6 * i
				if int(ft.read_u16(d, r)) == index {
					return offset32(d, subst, r + 2)
				}
			}
		}
	}
	return offset16(d, t.features, t.features + 2 + 6 * index + 4)
}

// The first FeatureVariations record whose conditions the normalized
// coordinates meet; -1 for none.
@(private)
feature_variation_index :: proc(l: ^Layout, kind: Table_Kind, coords: []i16) -> int {
	d := l.data
	fv := l.tables[kind].feature_variations
	if fv == 0 || ft.read_u16(d, fv) != 1 {
		return -1
	}
	count := int(ft.read_u32(d, fv + 4))
	count = min(count, (len(d) - fv) / 8)
	for i in 0 ..< count {
		set := offset32(d, fv, fv + 8 + 8 * i)
		if set == 0 {
			// No conditions: always met.
			return i
		}
		met := true
		conditions := int(ft.read_u16(d, set))
		for k in 0 ..< conditions {
			c := offset32(d, set, set + 2 + 4 * k)
			// Format 1: an axis and a range of its normalized value.
			if c == 0 || ft.read_u16(d, c) != 1 {
				met = false
				break
			}
			axis := int(ft.read_u16(d, c + 2))
			v := coords[axis] if axis < len(coords) else 0
			if v < ft.read_i16(d, c + 4) || v > ft.read_i16(d, c + 6) {
				met = false
				break
			}
		}
		if met {
			return i
		}
	}
	return -1
}

// Assigns mask bits to the collected features and lists each table's
// lookups by stage.
@(private)
compile :: proc(p: ^Planner, f: ^ft.Face, language: Tag) {
	plan := p.plan
	l := plan.layout
	d := l.data
	add_pause(p, .GSUB)
	add_pause(p, .GPOS)

	langsys: [Table_Kind]int
	required: [Table_Kind]int
	required_tag: [Table_Kind]Tag
	for kind in Table_Kind {
		required[kind] = -1
		ls, _, found := select_langsys(l, kind, plan.script, language)
		if !found || ls == 0 {
			continue
		}
		langsys[kind] = ls
		if r := int(ft.read_u16(d, ls + 2)); r != 0xFFFF {
			required[kind] = r
			features := l.tables[kind].features
			required_tag[kind] = Tag(ft.read_u32(d, features + 2 + 6 * r))
		}
	}

	// Merge settings of the same feature: a later global one wins, a later
	// partial one makes it partial with the larger value.
	infos := p.infos[:]
	slice.sort_by(infos, proc(a, b: Feature_Info) -> bool {
		return a.tag < b.tag || (a.tag == b.tag && a.seq < b.seq)
	})
	n := 0
	for i in 0 ..< len(infos) {
		if n > 0 && infos[i].tag == infos[n - 1].tag {
			a, b := &infos[n - 1], infos[i]
			if .Global in b.flags {
				a.flags += {.Global}
				a.max_value, a.default_value = b.max_value, b.default_value
			} else {
				a.flags -= {.Global}
				a.max_value = max(a.max_value, b.max_value)
			}
			a.flags += b.flags & {.Has_Fallback}
			for kind in Table_Kind {
				a.stage[kind] = min(a.stage[kind], b.stage[kind])
			}
			continue
		}
		infos[n] = infos[i]
		n += 1
	}
	infos = infos[:n]

	// Bits: the global bit for on-by-default features, else enough for the
	// largest value.
	// Bits 1 ..< 4 are left free and 31 is the last: features get as many
	// bits as HarfBuzz gives them (it keeps the low bits for glyph flags and
	// the top one for the global bit), so the same ones are dropped when
	// they don't fit.
	plan.global_mask = GLOBAL_MASK
	next_bit: u32 = 4
	required_stage: [Table_Kind]int
	feature_index := make([dynamic][Table_Kind]int, context.temp_allocator)
	feature_flags := make([dynamic]Feature_Flags, context.temp_allocator)
	feature_stage := make([dynamic][Table_Kind]int, context.temp_allocator)
	for info in infos {
		global_bit := .Global in info.flags && info.max_value == 1
		bits: u32 = 0
		if !global_bit {
			for v := min(info.max_value, FEATURE_MAX_VALUE); v > 0; v >>= 1 {
				bits += 1
			}
		}
		if info.max_value == 0 || next_bit + bits >= 31 {
			continue
		}
		index: [Table_Kind]int
		found := false
		for kind in Table_Kind {
			index[kind] = -1
			if required_tag[kind] == info.tag {
				required_stage[kind] = info.stage[kind]
			}
			if langsys[kind] != 0 {
				index[kind] = langsys_feature(l, kind, langsys[kind], info.tag)
				found ||= index[kind] >= 0
			}
		}
		if !found && .Has_Fallback not_in info.flags {
			continue
		}
		feat := Plan_Feature{tag = info.tag, gsub_stage = u8(info.stage[.GSUB])}
		if global_bit {
			feat.shift, feat.mask = 0, GLOBAL_MASK
		} else {
			feat.shift = u8(next_bit)
			feat.mask = (1 << (next_bit + bits)) - (1 << next_bit)
			next_bit += bits
			plan.global_mask |= (info.default_value << feat.shift) & feat.mask
		}
		append(&plan.features, feat)
		append(&feature_index, index)
		append(&feature_flags, info.flags)
		append(&feature_stage, info.stage)
	}
	plan.frac_mask = one_mask(plan, "frac")
	plan.numr_mask = one_mask(plan, "numr")
	plan.dnom_mask = one_mask(plan, "dnom")
	plan.rtlm_mask = one_mask(plan, "rtlm")
	if plan.frac_mask == 0 && (plan.numr_mask == 0 || plan.dnom_mask == 0) {
		plan.frac_mask, plan.numr_mask, plan.dnom_mask = 0, 0, 0
	}

	// Each stage's lookups: the required feature's, then each feature's,
	// sorted by lookup index with duplicates merged.
	for kind in Table_Kind {
		variation := feature_variation_index(l, kind, f.coords[:f.axis_count])
		lookups := &plan.lookups[kind]
		last := 0
		pause := 0
		for stage in 0 ..< p.stage[kind] {
			if required[kind] >= 0 && required_stage[kind] == stage {
				add_lookups(l, kind, lookups, feature_table(l, kind, required[kind], variation), GLOBAL_MASK, {})
			}
			for feat, i in plan.features {
				if feature_index[i][kind] >= 0 && feature_stage[i][kind] == stage {
					add_lookups(l, kind, lookups, feature_table(l, kind, feature_index[i][kind], variation), feat.mask, feature_flags[i])
				}
			}
			rows := lookups[last:]
			slice.sort_by(rows, proc(a, b: Plan_Lookup) -> bool {
				return a.index < b.index
			})
			k := 0
			for i in 0 ..< len(rows) {
				if k > 0 && rows[i].index == rows[k - 1].index {
					rows[k - 1].mask |= rows[i].mask
					// Joiners are skipped only when every feature lets them be.
					rows[k - 1].flags += rows[i].flags & {.Manual_ZWNJ, .Manual_ZWJ}
					continue
				}
				rows[k] = rows[i]
				k += 1
			}
			resize(lookups, last + k)
			last = len(lookups)
			if pause < len(p.pauses[kind]) {
				append(&plan.stages[kind], Plan_Stage{i32(last), p.pauses[kind][pause]})
				pause += 1
			}
		}
	}
}

@(private)
one_mask :: proc(plan: ^Plan, name: string) -> u32 {
	mask, shift := plan_feature_mask(plan, tag(name))
	return (1 << shift) & mask
}

// Appends the lookups of the feature table at `feature`.
@(private)
add_lookups :: proc(l: ^Layout, kind: Table_Kind, lookups: ^[dynamic]Plan_Lookup, feature: int, mask: u32, flags: Feature_Flags) {
	if feature == 0 {
		return
	}
	d := l.data
	lookup_count := len(l.tables[kind].lookups)
	count := int(ft.read_u16(d, feature + 2))
	for i in 0 ..< count {
		index := int(ft.read_u16(d, feature + 4 + 2 * i))
		if index < lookup_count {
			append(lookups, Plan_Lookup{u16(index), flags & {.Manual_ZWNJ, .Manual_ZWJ, .Random, .Per_Syllable}, mask})
		}
	}
}
