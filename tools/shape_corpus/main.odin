// Compares ovg/shape with HarfBuzz (the system libharfbuzz) and
// kb_text_shape over strings × fonts, counting where glyphs, clusters,
// advances, offsets and pen positions differ.
//
//   odin run tools/shape_corpus -o:speed -- [options] [font files...]
//     -script:Latin        only cases of this script
//     -text:"..."          shape this text only (with -script, -dir)
//     -dir:rtl             direction for -text
//     -features:liga=0,... features (HarfBuzz syntax)
//     -var:wght=700,...    variation settings
//     -show:N              print the first N mismatching cases in full
//     -kb                  also compare kb_text_shape
//     -bench               time ovg and kb on the matching cases
//     -random:N            N random strings per script per font, from the
//                          characters the font maps (marks included)
//     -dir-fonts:PATH      every .ttf / .otf / .ttc under PATH
//     -quiet               per-font lines only for fonts with mismatches
//     -feature-sets        run everything once per built-in feature set
//     -var-random:N        for variable fonts, N random instances (the
//                          axes' extremes and defaults among them)
//     -outlines            compare every glyph's outline and advance with
//                          HarfBuzz's instead of shaping (outlines.odin)
//
// Without font files it runs the built-in corpus over a set of installed
// fonts.
package shape_corpus

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:os"
import "core:reflect"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"
import ft "../../font"
import sh "../../shape"
import kb "vendor:kb_text_shape"

foreign import hb "system:harfbuzz"

HB_Blob :: struct {}
HB_Face :: struct {}
HB_Font :: struct {}
HB_Buffer :: struct {}

HB_Glyph_Info :: struct {
	codepoint: u32,
	mask:      u32,
	cluster:   u32,
	var1:      u32,
	var2:      u32,
}

HB_Glyph_Position :: struct {
	x_advance: i32,
	y_advance: i32,
	x_offset:  i32,
	y_offset:  i32,
	var:       u32,
}

HB_Feature :: struct {
	tag:   u32,
	value: u32,
	start: u32,
	end:   u32,
}

HB_Variation :: struct {
	tag:   u32,
	value: f32,
}

HB_DIRECTION_LTR :: 4
HB_DIRECTION_RTL :: 5

@(default_calling_convention = "c")
foreign hb {
	hb_blob_create :: proc(data: [^]u8, length: u32, mode: c.int, user_data: rawptr, destroy: rawptr) -> ^HB_Blob ---
	hb_blob_destroy :: proc(blob: ^HB_Blob) ---
	hb_face_create :: proc(blob: ^HB_Blob, index: u32) -> ^HB_Face ---
	hb_face_destroy :: proc(face: ^HB_Face) ---
	hb_font_create :: proc(face: ^HB_Face) -> ^HB_Font ---
	hb_font_destroy :: proc(font: ^HB_Font) ---
	hb_font_set_variations :: proc(font: ^HB_Font, variations: [^]HB_Variation, length: u32) ---
	hb_buffer_create :: proc() -> ^HB_Buffer ---
	hb_buffer_destroy :: proc(buf: ^HB_Buffer) ---
	hb_buffer_clear_contents :: proc(buf: ^HB_Buffer) ---
	hb_buffer_add_codepoints :: proc(buf: ^HB_Buffer, text: [^]u32, text_length: c.int, item_offset: u32, item_length: c.int) ---
	hb_buffer_set_direction :: proc(buf: ^HB_Buffer, direction: c.int) ---
	hb_buffer_set_script :: proc(buf: ^HB_Buffer, script: u32) ---
	hb_shape_full :: proc(font: ^HB_Font, buf: ^HB_Buffer, features: [^]HB_Feature, num_features: u32, shapers: [^]cstring) -> b32 ---
	hb_buffer_get_glyph_infos :: proc(buf: ^HB_Buffer, length: ^u32) -> [^]HB_Glyph_Info ---
	hb_buffer_get_glyph_positions :: proc(buf: ^HB_Buffer, length: ^u32) -> [^]HB_Glyph_Position ---
	hb_feature_from_string :: proc(str: cstring, len: c.int, feature: ^HB_Feature) -> b32 ---
	hb_variation_from_string :: proc(str: cstring, len: c.int, variation: ^HB_Variation) -> b32 ---
	hb_font_get_var_coords_normalized :: proc(font: ^HB_Font, length: ^c.uint) -> [^]c.int ---
}

Case :: struct {
	script: sh.Script,
	dir:    sh.Direction,
	text:   string,
}

// A shaper's result for one case, normalized for comparison.
Result :: struct {
	glyphs: [dynamic]sh.Glyph,
}

Counts :: struct {
	cases, glyph_cases, cluster_cases, advance_cases, offset_cases, position_cases: int,
	glyphs, glyph_diffs, cluster_diffs, advance_diffs, offset_diffs, position_diffs:  int,
}

Options :: struct {
	script:   Maybe(sh.Script),
	text:     string,
	dir:      sh.Direction,
	features: string,
	vars:     string,
	show:     int,
	kb:       bool,
	bench:    bool,
	random:   int,
	quiet:    bool,
	sets:     bool,
	var_random: int,
	outlines: bool,
	fonts:    [dynamic]string,
}

opts: Options

main :: proc() {
	for arg in os.args[1:] {
		switch {
		case strings.has_prefix(arg, "-script:"):
			name := arg[len("-script:"):]
			if v, ok := reflect.enum_from_name(sh.Script, name); ok {
				opts.script = v
			} else {
				fmt.eprintln("unknown script", name)
				os.exit(1)
			}
		case strings.has_prefix(arg, "-text:"):
			opts.text = arg[len("-text:"):]
		case arg == "-dir:rtl":
			opts.dir = .RTL
		case strings.has_prefix(arg, "-features:"):
			opts.features = arg[len("-features:"):]
		case strings.has_prefix(arg, "-var:"):
			opts.vars = arg[len("-var:"):]
		case strings.has_prefix(arg, "-show:"):
			opts.show, _ = strconv.parse_int(arg[len("-show:"):])
		case arg == "-kb":
			opts.kb = true
		case arg == "-bench":
			opts.bench = true
		case arg == "-quiet":
			opts.quiet = true
		case arg == "-feature-sets":
			opts.sets = true
		case arg == "-outlines":
			opts.outlines = true
		case strings.has_prefix(arg, "-var-random:"):
			opts.var_random, _ = strconv.parse_int(arg[len("-var-random:"):])
		case strings.has_prefix(arg, "-random:"):
			opts.random, _ = strconv.parse_int(arg[len("-random:"):])
		case strings.has_prefix(arg, "-dir-fonts:"):
			list_fonts(arg[len("-dir-fonts:"):], &opts.fonts)
		case:
			append(&opts.fonts, arg)
		}
	}
	cases: [dynamic]Case
	if opts.text != "" {
		append(&cases, Case{opts.script.? or_else .Latin, opts.dir, opts.text})
	} else {
		for cs in CORPUS {
			if s, ok := opts.script.?; ok && cs.script != s {
				continue
			}
			append(&cases, cs)
		}
	}
	fonts := opts.fonts[:]
	if len(fonts) == 0 {
		fonts = DEFAULT_FONTS[:]
	}
	feature_sets := []string{opts.features}
	if opts.sets {
		feature_sets = FEATURE_SETS[:]
	}
	total, total_kb: Counts
	shown := 0
	for set in feature_sets {
		opts.features = set
		set_total: Counts
		for path in fonts {
			data, err := os.read_entire_file_from_path(path, context.allocator)
			if err != nil {
				continue
			}
			defer delete(data)
			faces := max(ft.face_count(data), 1)
			for index in 0 ..< min(faces, 2) {
				face, ferr := ft.load(data, index)
				if ferr != nil {
					fmt.eprintln(path, index, ferr)
					continue
				}
				font_cases := cases[:]
				if opts.random > 0 {
					font_cases = random_cases(&face, opts.random)
				}
				instances := 1
				if opts.var_random > 0 {
					if face.axis_count == 0 {
						continue
					}
					instances = opts.var_random
				}
				for inst in 0 ..< instances {
					name := fmt.tprintf("%s#%d", short(path), index)
					if opts.var_random > 0 {
						opts.vars = random_instance(&face, inst)
						name = fmt.tprintf("%s %s", name, opts.vars)
					}
					c, ckb := run_font(path, data, index, &face, font_cases, &shown)
					add(&set_total, c)
					add(&total_kb, ckb)
					if !opts.quiet || c.glyph_cases + c.cluster_cases + c.position_cases > 0 {
						report(name, c)
						if opts.kb {
							report("  kb", ckb)
						}
					}
				}
				free_all(context.temp_allocator)
			}
		}
		if opts.sets {
			report(fmt.tprintf("features %q", set), set_total)
		}
		add(&total, set_total)
	}
	fmt.println("----")
	report("total ovg vs hb", total)
	if opts.kb {
		report("total kb vs hb", total_kb)
	}
	if opts.bench {
		fmt.printfln("bench over %d cases (sum of per-font medians / worst of 15 alternating runs):", bench_cases_total)
		names := [3]string{"ovg/shape", "kb_text_shape", "harfbuzz"}
		for k in 0 ..< 3 {
			fmt.printfln("  %-14s median %8.2f ms (%6.2f us/case)  worst %8.2f ms", names[k], time.duration_milliseconds(bench_median[k]), time.duration_microseconds(bench_median[k]) / f64(max(bench_cases_total, 1)), time.duration_milliseconds(bench_worst[k]))
		}
	}
}

short :: proc(path: string) -> string {
	i := strings.last_index_byte(path, '/')
	return path[i + 1:]
}

add :: proc(a: ^Counts, b: Counts) {
	a.cases += b.cases
	a.glyph_cases += b.glyph_cases
	a.cluster_cases += b.cluster_cases
	a.advance_cases += b.advance_cases
	a.offset_cases += b.offset_cases
	a.position_cases += b.position_cases
	a.glyphs += b.glyphs
	a.glyph_diffs += b.glyph_diffs
	a.cluster_diffs += b.cluster_diffs
	a.advance_diffs += b.advance_diffs
	a.offset_diffs += b.offset_diffs
	a.position_diffs += b.position_diffs
}

report :: proc(name: string, c: Counts) {
	fmt.printfln("%-40s cases %4v  bad: glyph %3v clus %3v adv %3v off %3v pos %3v | glyphs %5v diffs: id %4v clus %4v adv %4v off %4v pos %4v", name, c.cases, c.glyph_cases, c.cluster_cases, c.advance_cases, c.offset_cases, c.position_cases, c.glyphs, c.glyph_diffs, c.cluster_diffs, c.advance_diffs, c.offset_diffs, c.position_diffs)
}

hb_tag :: proc(s: string) -> u32 {
	return u32(sh.tag(s))
}

run_font :: proc(path: string, data: []u8, index: int, face: ^ft.Face, cases: []Case, shown: ^int) -> (counts, counts_kb: Counts) {
	// HarfBuzz.
	blob := hb_blob_create(raw_data(data), u32(len(data)), 0, nil, nil)
	defer hb_blob_destroy(blob)
	hface := hb_face_create(blob, u32(index))
	defer hb_face_destroy(hface)
	hfont := hb_font_create(hface)
	defer hb_font_destroy(hfont)
	buf := hb_buffer_create()
	defer hb_buffer_destroy(buf)

	// Features and variations (HarfBuzz syntax for both).
	hb_features: [dynamic]HB_Feature
	features: [dynamic]sh.Feature
	if opts.features != "" {
		for item in strings.split(opts.features, ",", context.temp_allocator) {
			hf: HB_Feature
			cs := strings.clone_to_cstring(item, context.temp_allocator)
			if hb_feature_from_string(cs, -1, &hf) {
				append(&hb_features, hf)
				f := sh.Feature{sh.Tag(hf.tag), hf.value, int(hf.start), 0}
				if hf.end != 0xFFFFFFFF {
					f.end = int(hf.end)
				}
				append(&features, f)
			}
		}
	}
	if opts.vars != "" {
		hv: [dynamic]HB_Variation
		settings: [dynamic]ft.Variation
		for item in strings.split(opts.vars, ",", context.temp_allocator) {
			v: HB_Variation
			cs := strings.clone_to_cstring(item, context.temp_allocator)
			if hb_variation_from_string(cs, -1, &v) {
				append(&hv, v)
				t := transmute([4]u8)(u32be(v.tag))
				append(&settings, ft.Variation{strings.clone(string(t[:])), v.value})
			}
		}
		hb_font_set_variations(hfont, raw_data(hv), u32(len(hv)))
		ft.set_variations(face, settings[:])
		n: c.uint
		hc := hb_font_get_var_coords_normalized(hfont, &n)
		for i in 0 ..< int(n) {
			if i32(hc[i]) != i32(face.coords[i]) {
				fmt.printfln("%s: axis %d normalized: hb %d, ovg %d", short(path), i, hc[i], face.coords[i])
			}
		}
	}

	if opts.outlines {
		oc := compare_outlines(short(path), face, hfont, shown)
		fmt.printfln("%-40s %s glyphs %d  outline diffs %d  advance diffs %d  max error %v", short(path), opts.vars, oc.glyphs, oc.outline_diffs, oc.advance_diffs, oc.max_error)
		counts.glyphs += oc.glyphs
		counts.glyph_diffs += oc.outline_diffs
		counts.advance_diffs += oc.advance_diffs
		return
	}

	// ovg/shape.
	layout: sh.Layout
	sh.layout_init(&layout, face)
	defer sh.layout_destroy(&layout)
	shaper: sh.Shaper
	sh.shaper_init(&shaper)
	defer sh.shaper_destroy(&shaper)
	plans: map[[2]int]^sh.Plan
	defer {
		for _, p in plans {
			sh.plan_destroy(p)
			free(p)
		}
		delete(plans)
	}

	// kb_text_shape.
	kfont: kb.font
	if opts.kb || opts.bench {
		kfont = kb.FontFromMemory(data, c.int(index), kb_allocator, nil)
	}
	defer if opts.kb || opts.bench {
		kb.FreeFont(&kfont)
	}
	storage: kb.glyph_storage
	kb_configs: map[sh.Script]Kb_Config
	if opts.kb || opts.bench {
		_ = kb.InitializeGlyphStorage(&storage, kb_allocator, nil)
	}

	ours, theirs, kbs: [dynamic]sh.Glyph
	runes: [dynamic]rune
	bench_cases: [dynamic]int
	for cs, ci in cases {
		clear(&runes)
		for r in cs.text {
			append(&runes, r)
		}
		// Skip cases the font can't show at all (most of the text missing).
		missing := 0
		for r in runes {
			if r > ' ' && ft.glyph_index(face, r) == 0 {
				missing += 1
			}
		}
		if missing * 2 > len(runes) {
			continue
		}
		key := [2]int{int(cs.script), int(cs.dir)}
		plan := plans[key]
		if plan == nil {
			plan = new(sh.Plan)
			sh.plan_init(plan, &layout, face, cs.script, cs.dir, 0, features[:])
			plans[key] = plan
		}
		clear(&ours)
		sh.shape(&shaper, plan, face, runes[:], features[:], &ours)
		append(&bench_cases, ci)

		clear(&theirs)
		hb_buffer_clear_contents(buf)
		hb_buffer_add_codepoints(buf, cast([^]u32)raw_data(runes), c.int(len(runes)), 0, c.int(len(runes)))
		hb_buffer_set_direction(buf, HB_DIRECTION_RTL if cs.dir == .RTL else HB_DIRECTION_LTR)
		hb_buffer_set_script(buf, hb_tag(sh.SCRIPT_TAGS[cs.script]))
		hb_shape_ot(hfont, buf, hb_features[:])
		n: u32
		infos := hb_buffer_get_glyph_infos(buf, &n)
		positions := hb_buffer_get_glyph_positions(buf, &n)
		for i in 0 ..< int(n) {
			p := positions[i]
			append(&theirs, sh.Glyph{u16(infos[i].codepoint), i32(infos[i].cluster), p.x_advance, {p.x_offset, p.y_offset}, false})
		}
		counts.cases += 1
		bad := compare(ours[:], theirs[:], &counts)
		if bad && shown^ < opts.show {
			shown^ += 1
			fmt.printfln("== %s [%v %v] %q", short(path), cs.script, cs.dir, cs.text)
			dump("ovg", ours[:])
			dump("hb ", theirs[:])
		}
		if opts.kb && kb.FontIsValid(&kfont) {
			clear(&kbs)
			kc := kb_config(&kb_configs, &kfont, cs.script)
			kb_shape(kc, &kfont, &storage, cs, runes[:], &kbs)
			counts_kb.cases += 1
			compare(kbs[:], theirs[:], &counts_kb)
		}
	}
	if opts.bench && kb.FontIsValid(&kfont) {
		// Each shaper over every case the font shows, alternating, several
		// times: medians and worst.
		REPS :: 15
		times: [3][REPS]time.Duration
		for rep in 0 ..< REPS {
			for which in 0 ..< 3 {
				k := (which + rep) % 3
				start := time.tick_now()
				for ci in bench_cases {
					cs := cases[ci]
					clear(&runes)
					for r in cs.text {
						append(&runes, r)
					}
					switch k {
					case 0:
						clear(&ours)
						sh.shape(&shaper, plans[{int(cs.script), int(cs.dir)}], face, runes[:], features[:], &ours)
					case 1:
						clear(&kbs)
						kb_shape(kb_config(&kb_configs, &kfont, cs.script), &kfont, &storage, cs, runes[:], &kbs)
					case 2:
						hb_buffer_clear_contents(buf)
						hb_buffer_add_codepoints(buf, cast([^]u32)raw_data(runes), c.int(len(runes)), 0, c.int(len(runes)))
						hb_buffer_set_direction(buf, HB_DIRECTION_RTL if cs.dir == .RTL else HB_DIRECTION_LTR)
						hb_buffer_set_script(buf, hb_tag(sh.SCRIPT_TAGS[cs.script]))
						hb_shape_ot(hfont, buf, hb_features[:])
					}
				}
				times[k][rep] = time.tick_since(start)
			}
		}
		for k in 0 ..< 3 {
			slice.sort(times[k][:])
			bench_median[k] += times[k][REPS / 2]
			bench_worst[k] += times[k][REPS - 1]
		}
		bench_cases_total += len(bench_cases)
	}
	for _, kc in kb_configs {
		kb.DestroyShapeScratchpad(kc.scratch)
		kb.DestroyShapeConfig(kc.config)
	}
	delete(kb_configs)
	return
}

bench_median, bench_worst: [3]time.Duration
bench_cases_total: int

Kb_Config :: struct {
	config:  ^kb.shape_config,
	scratch: ^kb.shape_scratchpad,
}

// kb's setup for a script, made once per font (as text_shape.odin keeps
// it per face and script).
kb_config :: proc(configs: ^map[sh.Script]Kb_Config, f: ^kb.font, script: sh.Script) -> Kb_Config {
	if kc, ok := configs[script]; ok {
		return kc
	}
	kc: Kb_Config
	kc.config = kb.CreateShapeConfig(f, kb_script(script), .DONT_KNOW, kb_allocator, nil)
	if kc.config != nil {
		kc.scratch = kb_create_shape_scratchpad(kc.config)
	}
	configs[script] = kc
	return kc
}

dump :: proc(name: string, glyphs: []sh.Glyph) {
	b := strings.builder_make(context.temp_allocator)
	pen: i32
	for g in glyphs {
		fmt.sbprintf(&b, " %d@%d", g.id, g.cluster)
		fmt.sbprintf(&b, "+%d", g.advance)
		if g.offset != {} {
			fmt.sbprintf(&b, "<%d,%d>", g.offset.x, g.offset.y)
		}
		pen += g.advance
	}
	fmt.printfln("  %s%s  (w %d)", name, strings.to_string(b), pen)
}

// Compares two glyph runs; true when glyphs, clusters or pen positions
// differ.
compare :: proc(a, b: []sh.Glyph, counts: ^Counts) -> bool {
	counts.glyphs += len(b)
	if len(a) != len(b) {
		counts.glyph_cases += 1
		counts.glyph_diffs += max(len(a), len(b))
		return true
	}
	glyph, cluster, advance, offset, position := 0, 0, 0, 0, 0
	pa, pb: i32
	for i in 0 ..< len(a) {
		if a[i].id != b[i].id {
			glyph += 1
		}
		if a[i].cluster != b[i].cluster {
			cluster += 1
		}
		if a[i].advance != b[i].advance {
			advance += 1
		}
		if a[i].offset != b[i].offset {
			offset += 1
		}
		if pa + a[i].offset.x != pb + b[i].offset.x || a[i].offset.y != b[i].offset.y {
			position += 1
		}
		pa += a[i].advance
		pb += b[i].advance
	}
	if pa != pb {
		position += 1
	}
	counts.glyph_diffs += glyph
	counts.cluster_diffs += cluster
	counts.advance_diffs += advance
	counts.offset_diffs += offset
	counts.position_diffs += position
	counts.glyph_cases += int(glyph > 0)
	counts.cluster_cases += int(cluster > 0)
	counts.advance_cases += int(advance > 0)
	counts.offset_cases += int(offset > 0)
	counts.position_cases += int(position > 0)
	// Raw advances and offsets may differ where pen positions agree (the
	// kern table: HarfBuzz splits each pair's value over both glyphs).
	return glyph + cluster + position > 0
}

// ---- kb_text_shape ----------------------------------------------------------------

kb_allocator :: proc "c" (data: rawptr, op: ^kb.allocator_op) {
	#partial switch op.Kind {
	case .ALLOCATE:
		op.Allocate.Pointer = runtime.heap_alloc(max(int(op.Allocate.Size), 1), false)
	case .FREE:
		runtime.heap_free(op.Free.Pointer)
	}
}

kb_create_shape_scratchpad :: proc(config: ^kb.shape_config) -> ^kb.shape_scratchpad {
	Create :: #type proc "c" (config: ^kb.shape_config, allocator: kb.allocator_function, data: rawptr) -> ^kb.shape_scratchpad
	return (Create)(rawptr(kb.CreateShapeScratchpad))(config, kb_allocator, nil)
}

kb_script :: proc(s: sh.Script) -> kb.script {
	#partial switch s {
	case .Han:
		return .CJK_IDEOGRAPHIC
	}
	name := strings.to_upper(fmt.tprint(s), context.temp_allocator)
	if v, ok := reflect.enum_from_name(kb.script, name); ok {
		return v
	}
	return .DONT_KNOW
}

kb_shape :: proc(kc: Kb_Config, f: ^kb.font, storage: ^kb.glyph_storage, cs: Case, runes: []rune, out: ^[dynamic]sh.Glyph) {
	if kc.scratch == nil {
		return
	}
	scratch := kc.scratch
	kb.ClearActiveGlyphs(storage)
	for r, i in runes {
		_ = kb.PushGlyph(storage, f, r, nil, c.int(i))
	}
	dir: kb.direction = .KBTS_DIRECTION_RTL if cs.dir == .RTL else .KBTS_DIRECTION_LTR
	it, err := kb.ShapeDirect(scratch, storage, dir)
	if err != .NONE {
		return
	}
	for {
		g, ok := kb.GlyphIteratorNext(&it)
		if !ok {
			break
		}
		append(out, sh.Glyph{u16(g.Id), i32(g.UserIdOrCodepointIndex), g.AdvanceX, {g.OffsetX, g.OffsetY}, g.AttachGlyph != nil})
	}
}

// Every font file under `dir`, sorted.
list_fonts :: proc(dir: string, out: ^[dynamic]string) {
	start := len(out)
	walk :: proc(dir: string, out: ^[dynamic]string) {
		entries, err := os.read_all_directory_by_path(dir, context.allocator)
		if err != nil {
			return
		}
		for e in entries {
			if e.type == .Directory {
				walk(e.fullpath, out)
			} else if strings.has_suffix(e.name, ".ttf") || strings.has_suffix(e.name, ".otf") || strings.has_suffix(e.name, ".ttc") {
				append(out, e.fullpath)
			}
		}
	}
	walk(dir, out)
	slice.sort(out[start:])
}

// Characters per script for random strings: the script's letters, then
// marks that may follow them.
Script_Chars :: struct {
	script: sh.Script,
	ranges: []([2]rune),
	marks:  []([2]rune),
}

@(rodata)
SCRIPT_CHARS := [?]Script_Chars {
	{.Latin, {{0x41, 0x5A}, {0x61, 0x7A}, {0xC0, 0x24F}, {0x1E00, 0x1EFF}, {0xFB00, 0xFB06}}, {{0x300, 0x36F}, {0x1AB0, 0x1ACE}, {0x1DC0, 0x1DFF}}},
	{.Greek, {{0x370, 0x3FF}, {0x1F00, 0x1FFF}}, {{0x300, 0x345}}},
	{.Cyrillic, {{0x400, 0x52F}, {0x1C80, 0x1C88}, {0xA640, 0xA69F}}, {{0x300, 0x36F}, {0x483, 0x489}}},
	{.Arabic, {{0x620, 0x64A}, {0x660, 0x66F}, {0x671, 0x6D3}, {0x6EE, 0x6FF}, {0x750, 0x77F}, {0x8A0, 0x8C9}, {0x640, 0x640}, {0x200C, 0x200D}}, {{0x64B, 0x65F}, {0x670, 0x670}, {0x6D6, 0x6ED}, {0x8CA, 0x8FF}}},
	{.Syriac, {{0x710, 0x72F}, {0x74D, 0x74F}, {0x860, 0x86A}, {0x700, 0x70D}}, {{0x730, 0x74A}}},
	{.Hebrew, {{0x5D0, 0x5EA}, {0x5EF, 0x5F4}, {0xFB1D, 0xFB4F}}, {{0x591, 0x5BD}, {0x5BF, 0x5BF}, {0x5C1, 0x5C2}, {0x5C4, 0x5C7}}},
	{.Thai, {{0xE01, 0xE30}, {0xE32, 0xE33}, {0xE3F, 0xE46}, {0xE4F, 0xE5B}}, {{0xE31, 0xE31}, {0xE34, 0xE3A}, {0xE47, 0xE4E}}},
	{.Lao, {{0xE81, 0xEB0}, {0xEB2, 0xEB3}, {0xEBD, 0xEC6}, {0xED0, 0xEDF}}, {{0xEB1, 0xEB1}, {0xEB4, 0xEBC}, {0xEC8, 0xECE}}},
	{.Hangul, {{0xAC00, 0xAC80}, {0xD500, 0xD5A0}, {0x1100, 0x1112}, {0x1161, 0x1175}, {0x11A8, 0x11C2}, {0x3131, 0x318E}, {0xA960, 0xA97C}, {0xD7B0, 0xD7C6}}, {{0x302E, 0x302F}}},
	{.Mongolian, {{0x1820, 0x1878}, {0x1880, 0x18AA}, {0x180B, 0x180F}}, {{0x1885, 0x1886}, {0x18A9, 0x18A9}}},
	{.Nko, {{0x7CA, 0x7EA}, {0x7C0, 0x7C9}, {0x7F4, 0x7FA}}, {{0x7EB, 0x7F3}, {0x7FD, 0x7FD}}},
	{.Tibetan, {{0xF40, 0xF6C}, {0xF00, 0xF17}, {0xF20, 0xF33}}, {{0xF71, 0xF87}, {0xF8D, 0xFBC}, {0xF18, 0xF19}, {0xF35, 0xF35}, {0xF37, 0xF37}, {0xF39, 0xF39}}},
	{.Javanese, {{0xA984, 0xA9B2}, {0xA9C1, 0xA9CD}, {0xA9D0, 0xA9D9}}, {{0xA980, 0xA983}, {0xA9B3, 0xA9C0}}},
	{.Balinese, {{0x1B05, 0x1B33}, {0x1B45, 0x1B4C}, {0x1B50, 0x1B7F}}, {{0x1B00, 0x1B04}, {0x1B34, 0x1B44}}},
	{.Sinhala, {{0xD85, 0xDC6}, {0xDE6, 0xDEF}, {0xDF4, 0xDF4}}, {{0xD81, 0xD83}, {0xDCA, 0xDDF}, {0xDF2, 0xDF3}}},
	{.Adlam, {{0x1E900, 0x1E943}, {0x1E94B, 0x1E94B}, {0x1E950, 0x1E959}}, {{0x1E944, 0x1E94A}}},
	{.Khmer, {{0x1780, 0x17B3}, {0x17D4, 0x17DC}, {0x17E0, 0x17E9}, {0x19E0, 0x19FF}}, {{0x17B4, 0x17D3}, {0x17DD, 0x17DD}}},
	{.Myanmar, {{0x1000, 0x102A}, {0x103F, 0x1055}, {0x105A, 0x105D}, {0x1061, 0x1061}, {0x1065, 0x1066}, {0x106E, 0x1070}, {0x1075, 0x1081}, {0x108E, 0x108E}, {0x1090, 0x1099}, {0xAA60, 0xAA76}}, {{0x102B, 0x103E}, {0x1056, 0x1059}, {0x105E, 0x1060}, {0x1062, 0x1064}, {0x1067, 0x106D}, {0x1071, 0x1074}, {0x1082, 0x108D}, {0x108F, 0x108F}, {0x109A, 0x109D}}},
	{.Devanagari, {{0x904, 0x939}, {0x93D, 0x93D}, {0x950, 0x950}, {0x958, 0x961}, {0x964, 0x97F}, {0x200C, 0x200D}}, {{0x900, 0x903}, {0x93A, 0x93C}, {0x93E, 0x94F}, {0x951, 0x957}, {0x962, 0x963}}},
	{.Bengali, {{0x985, 0x9B9}, {0x9BD, 0x9BD}, {0x9CE, 0x9CE}, {0x9DC, 0x9E1}, {0x9E6, 0x9FD}, {0x200C, 0x200D}}, {{0x981, 0x983}, {0x9BC, 0x9BC}, {0x9BE, 0x9CD}, {0x9D7, 0x9D7}, {0x9E2, 0x9E3}, {0x9FE, 0x9FE}}},
	{.Gurmukhi, {{0xA05, 0xA39}, {0xA59, 0xA5E}, {0xA66, 0xA6F}, {0xA72, 0xA74}, {0xA76, 0xA76}}, {{0xA01, 0xA03}, {0xA3C, 0xA51}, {0xA70, 0xA71}, {0xA75, 0xA75}}},
	{.Gujarati, {{0xA85, 0xAB9}, {0xABD, 0xABD}, {0xAD0, 0xAD0}, {0xAE0, 0xAE1}, {0xAE6, 0xAF1}, {0xAF9, 0xAF9}}, {{0xA81, 0xA83}, {0xABC, 0xABC}, {0xABE, 0xACD}, {0xAE2, 0xAE3}, {0xAFA, 0xAFF}}},
	{.Oriya, {{0xB05, 0xB39}, {0xB3D, 0xB3D}, {0xB5C, 0xB61}, {0xB66, 0xB77}}, {{0xB01, 0xB03}, {0xB3C, 0xB3C}, {0xB3E, 0xB57}, {0xB62, 0xB63}}},
	{.Tamil, {{0xB83, 0xBB9}, {0xBD0, 0xBD0}, {0xBE6, 0xBFA}}, {{0xB82, 0xB82}, {0xBBE, 0xBCD}, {0xBD7, 0xBD7}}},
	{.Telugu, {{0xC05, 0xC39}, {0xC3D, 0xC3D}, {0xC58, 0xC61}, {0xC66, 0xC7F}}, {{0xC00, 0xC04}, {0xC3C, 0xC3C}, {0xC3E, 0xC56}, {0xC62, 0xC63}}},
	{.Kannada, {{0xC85, 0xCB9}, {0xCBD, 0xCBD}, {0xCDD, 0xCE1}, {0xCE6, 0xCF2}}, {{0xC80, 0xC84}, {0xCBC, 0xCBC}, {0xCBE, 0xCD6}, {0xCE2, 0xCE3}, {0xCF3, 0xCF3}}},
	{.Malayalam, {{0xD04, 0xD3A}, {0xD3D, 0xD3D}, {0xD4E, 0xD4F}, {0xD54, 0xD56}, {0xD58, 0xD61}, {0xD66, 0xD7F}}, {{0xD00, 0xD03}, {0xD3B, 0xD3C}, {0xD3E, 0xD4D}, {0xD57, 0xD57}, {0xD62, 0xD63}}},
}

@(rodata)
COMMON_CHARS := [?][2]rune{{0x20, 0x40}, {0x5B, 0x60}, {0x7B, 0x7E}, {0xA0, 0xBF}, {0x2010, 0x2027}, {0x2030, 0x205E}, {0x20A0, 0x20C0}, {0x2150, 0x218B}, {0x200B, 0x200D}}

rng_state: u64 = 0x9E3779B97F4A7C15

rng :: proc(n: int) -> int {
	rng_state ~= rng_state << 13
	rng_state ~= rng_state >> 7
	rng_state ~= rng_state << 17
	return int(rng_state % u64(n))
}

// `n` random strings per script the font covers.
random_cases :: proc(f: ^ft.Face, n: int) -> []Case {
	cases := make([dynamic]Case, context.temp_allocator)
	pool := make([dynamic]rune, context.temp_allocator)
	marks := make([dynamic]rune, context.temp_allocator)
	common := make([dynamic]rune, context.temp_allocator)
	for r in COMMON_CHARS {
		for c in r[0] ..= r[1] {
			if ft.glyph_index(f, c) != 0 {
				append(&common, c)
			}
		}
	}
	for sc in SCRIPT_CHARS {
		if s, ok := opts.script.?; ok && sc.script != s {
			continue
		}
		clear(&pool)
		clear(&marks)
		for r in sc.ranges {
			for c in r[0] ..= r[1] {
				if ft.glyph_index(f, c) != 0 {
					append(&pool, c)
				}
			}
		}
		for r in sc.marks {
			for c in r[0] ..= r[1] {
				if ft.glyph_index(f, c) != 0 {
					append(&marks, c)
				}
			}
		}
		if len(pool) < 10 {
			continue
		}
		for _ in 0 ..< n {
			b := strings.builder_make(context.temp_allocator)
			length := 2 + rng(18)
			for _ in 0 ..< length {
				k := rng(100)
				switch {
				case k < 70 || len(common) == 0:
					strings.write_rune(&b, pool[rng(len(pool))])
				case k < 85 && len(marks) > 0:
					strings.write_rune(&b, marks[rng(len(marks))])
				case:
					strings.write_rune(&b, common[rng(len(common))])
				}
			}
			dir: sh.Direction = .RTL if sh.script_is_rtl(sc.script) else .LTR
			if rng(10) == 0 {
				dir = .LTR if dir == .RTL else .RTL
			}
			append(&cases, Case{sc.script, dir, strings.to_string(b)})
		}
	}
	return cases[:]
}


// Settings for instance `k` of a variable font: the default first, then
// each axis's extremes, then random values (in HarfBuzz syntax).
random_instance :: proc(f: ^ft.Face, k: int) -> string {
	b := strings.builder_make(context.temp_allocator)
	for i in 0 ..< f.axis_count {
		a, _ := ft.axis(f, i)
		v := a.default
		if k > 0 && k <= 2 * f.axis_count {
			if (k - 1) / 2 == i {
				v = a.min if k % 2 == 1 else a.max
			}
		} else if k > 0 {
			v = a.min + (a.max - a.min) * f32(rng(10001)) / 10000
		}
		if i > 0 {
			strings.write_byte(&b, ',')
		}
		fmt.sbprintf(&b, "%s=%v", a.tag, v)
	}
	return strings.to_string(b)
}

// HarfBuzz's OpenType shaper only: a system HarfBuzz built with graphite2
// would shape fonts with a Silf table (Graphite) with it instead.
hb_shape_ot :: proc(font: ^HB_Font, buf: ^HB_Buffer, features: []HB_Feature) {
	shapers := [2]cstring{"ot", nil}
	hb_shape_full(font, buf, raw_data(features), u32(len(features)), raw_data(shapers[:]))
}
