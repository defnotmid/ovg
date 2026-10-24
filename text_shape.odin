package ovg

import "base:runtime"
import "core:c"
import "core:sync"
import kb "vendor:kb_text_shape"

// OpenType shaping for `text_layout` with kb_text_shape: GSUB (ligatures,
// contextual forms, Arabic joining, Indic reordering) and GPOS (kerning,
// mark positioning) per segment of one font, size, script and direction.
//
// Font_Collection keeps the shared, read-only state: a kb font per face,
// parsed on first use. Mutable state (shape configs with their scratchpads,
// glyph storage, the per-codepoint and per-glyph tables of a layout) lives
// in a `Text_Shaper`; the collection pools them so
// concurrent layouts on one collection each take their own, and a warm
// shaper lays out without allocating.

// The binding of kbts_CreateShapeScratchpad returns the scratchpad by value
// (an empty struct), dropping the pointer the C function returns.
@(private)
kb_create_shape_scratchpad :: proc(config: ^kb.shape_config) -> ^kb.shape_scratchpad {
	Create :: #type proc "c" (config: ^kb.shape_config, allocator: kb.allocator_function, data: rawptr) -> ^kb.shape_scratchpad
	return (Create)(rawptr(kb.CreateShapeScratchpad))(config, kb_allocator, nil)
}

// kb_text_shape is built without the C runtime: its allocations come here.
// It asks for zero bytes at times (no scratch for fonts without GSUB/GPOS)
// and takes nil as out of memory.
@(private)
kb_allocator :: proc "c" (data: rawptr, op: ^kb.allocator_op) {
	#partial switch op.Kind {
	case .ALLOCATE:
		op.Allocate.Pointer = runtime.heap_alloc(max(int(op.Allocate.Size), 1), false)
	case .FREE:
		runtime.heap_free(op.Free.Pointer)
	}
}

// One (face, script) shaping setup of a shaper. `kb_font == nil` shapes
// without OpenType (ovg/font advances and kerning).
@(private)
Shape_Config :: struct {
	data:      rawptr, // face identity: font bytes + offset
	fontstart: int,
	script:    kb.script,
	kb_font:   ^kb.font,
	config:    ^kb.shape_config,
	scratch:   ^kb.shape_scratchpad,
	// No GPOS: the legacy `kern` table kerns instead.
	kern:      bool,
}

// A run of codepoints in one font, size, script and direction, and the
// glyphs it shaped into (visual order, left to right).
@(private)
Shape_Segment :: struct {
	first, count:             i32, // codepoints
	glyph_first, glyph_count: i32,
	font:                     ^Font,
	em:                       f32,
	script:                   kb.script,
	level:                    u8, // bidi embedding level: 0 LTR, 1 RTL, 2 numbers in RTL
}

// Shaping state for one layout at a time (pooled by Font_Collection).
Text_Shaper :: struct {
	storage:        kb.glyph_storage,
	configs:        [dynamic]Shape_Config,
	// Per piece.
	piece_start:    [dynamic]i32, // first codepoint
	piece_font:     [dynamic]^Font,
	piece_size:     [dynamic]f32,
	// The piece's feature overrides (Text_Style.features, then letter
	// spacing's), and its glyph config while a segment holding it shapes
	// (placed in `config_words`).
	piece_features: [dynamic]Piece_Features,
	piece_config:   [dynamic]^kb.glyph_config,
	overrides:      [dynamic]kb.feature_override,
	config_words:   [dynamic]u64,
	// Per codepoint of the text.
	runes:          [dynamic]rune,
	piece:          [dynamic]i32,
	font:           [dynamic]^Font, // after fallback
	script:         [dynamic]kb.script,
	level:          [dynamic]u8, // bidi level (text_bidi.odin)
	bidi:           [dynamic]Bidi_Class, // scratch
	// Segments of the current line, and their visual order.
	segs:           [dynamic]Shape_Segment,
	order:          [dynamic]i32,
	// Shaped glyphs of the current line.
	glyphs:         [dynamic]Shaped_Glyph,
}

@(private)
Piece_Features :: struct {
	first, count: i32, // overrides
	// No `kern` override of 0: the legacy kern table applies.
	kern:         bool,
	// Features kb runs only on glyphs flagged for them (fractions around
	// U+2044, joining forms, Indic forms) that the piece turns on: its
	// glyphs take the flags, so they apply to all of it, as in HarfBuzz.
	flags:        kb.glyph_flags,
}

// The features kb gates by glyph flag (numr, frac and dnom flagged only
// around a fraction slash), by tag.
@(private, rodata)
FLAGGED_FEATURES := [?]struct {
	tag:  string,
	flag: kb.glyph_flag,
} {
	{"isol", .ISOL},
	{"fina", .FINA},
	{"fin2", .FIN2},
	{"fin3", .FIN3},
	{"medi", .MEDI},
	{"med2", .MED2},
	{"init", .INIT},
	{"ljmo", .LJMO},
	{"vjmo", .VJMO},
	{"tjmo", .TJMO},
	{"rphf", .RPHF},
	{"blwf", .BLWF},
	{"half", .HALF},
	{"pstf", .PSTF},
	{"abvf", .ABVF},
	{"pref", .PREF},
	{"numr", .NUMR},
	{"frac", .FRAC},
	{"dnom", .DNOM},
	{"cfar", .CFAR},
}

// One shaped glyph, in font units (y up). The layout reads every field per
// glyph, so these are rows.
@(private)
Shaped_Glyph :: struct {
	id:      Glyph_Index,
	cluster: i32, // first codepoint
	offset:  [2]i32,
	advance: i32,
	// Attached to a base glyph (takes no letter-spacing).
	mark:    bool,
}

@(private)
shaper_acquire :: proc(fonts: ^Font_Collection) -> ^Text_Shaper {
	sync.mutex_lock(&fonts.shape_lock)
	defer sync.mutex_unlock(&fonts.shape_lock)
	if n := len(fonts.shapers); n > 0 {
		s := fonts.shapers[n - 1]
		resize(&fonts.shapers, n - 1)
		return s
	}
	allocator := collection_allocator(fonts)
	s := new(Text_Shaper, allocator)
	s.configs.allocator = allocator
	s.piece_start.allocator = allocator
	s.piece_font.allocator = allocator
	s.piece_size.allocator = allocator
	s.piece_features.allocator = allocator
	s.piece_config.allocator = allocator
	s.overrides.allocator = allocator
	s.config_words.allocator = allocator
	s.runes.allocator = allocator
	s.piece.allocator = allocator
	s.font.allocator = allocator
	s.script.allocator = allocator
	s.level.allocator = allocator
	s.bidi.allocator = allocator
	s.segs.allocator = allocator
	s.order.allocator = allocator
	s.glyphs.allocator = allocator
	_ = kb.InitializeGlyphStorage(&s.storage, kb_allocator, nil)
	return s
}

@(private)
shaper_release :: proc(fonts: ^Font_Collection, s: ^Text_Shaper) {
	sync.mutex_lock(&fonts.shape_lock)
	defer sync.mutex_unlock(&fonts.shape_lock)
	if fonts.shapers.allocator.procedure == nil {
		fonts.shapers.allocator = collection_allocator(fonts)
	}
	append(&fonts.shapers, s)
}

@(private)
shaper_destroy :: proc(s: ^Text_Shaper) {
	for &cfg in s.configs {
		if cfg.scratch != nil {
			kb.DestroyShapeScratchpad(cfg.scratch)
		}
		if cfg.config != nil {
			kb.DestroyShapeConfig(cfg.config)
		}
	}
	kb.FreeAllGlyphs(&s.storage)
	delete(s.configs)
	delete(s.piece_start)
	delete(s.piece_font)
	delete(s.piece_size)
	delete(s.piece_features)
	delete(s.piece_config)
	delete(s.overrides)
	delete(s.config_words)
	delete(s.runes)
	delete(s.piece)
	delete(s.font)
	delete(s.script)
	delete(s.level)
	delete(s.bidi)
	delete(s.segs)
	delete(s.order)
	delete(s.glyphs)
	free(s, s.configs.allocator)
}

@(private)
collection_allocator :: proc(fonts: ^Font_Collection) -> runtime.Allocator {
	if fonts.faces.allocator.procedure != nil {
		return fonts.faces.allocator
	}
	return runtime.heap_allocator()
}

// The kb font of a face, parsed on first use (nil when kb cannot read it).
@(private)
font_kb :: proc(fonts: ^Font_Collection, f: ^Font) -> ^kb.font {
	sync.mutex_lock(&fonts.shape_lock)
	defer sync.mutex_unlock(&fonts.shape_lock)
	if f.shaping == nil && !f.shaping_failed {
		if !font_layout_tables_ok(f) {
			f.shaping_failed = true
			return nil
		}
		kf := kb.FontFromMemory(f.data, c.int(f.index), kb_allocator, nil)
		if kb.FontIsValid(&kf) {
			p := new(kb.font, runtime.heap_allocator())
			p^ = kf
			f.shaping = p
		} else {
			kb.FreeFont(&kf)
			f.shaping_failed = true
		}
	}
	return f.shaping
}

// Frees the kb font of a face.
@(private)
font_kb_destroy :: proc(f: ^Font) {
	if f.shaping != nil {
		kb.FreeFont(f.shaping)
		free(f.shaping, runtime.heap_allocator())
		f.shaping = nil
	}
}

// The shaper's setup for (face, script), made on first use.
@(private)
shaper_config :: proc(fonts: ^Font_Collection, s: ^Text_Shaper, f: ^Font, script: kb.script) -> ^Shape_Config {
	data := raw_data(f.data)
	for &cfg in s.configs {
		if cfg.data == data && cfg.fontstart == f.face.start && cfg.script == script {
			return &cfg
		}
	}
	cfg := Shape_Config{data = data, fontstart = f.face.start, script = script}
	if kf := font_kb(fonts, f); kf != nil {
		cfg.config = kb.CreateShapeConfig(kf, script, .DONT_KNOW, kb_allocator, nil)
		if cfg.config != nil {
			cfg.scratch = kb_create_shape_scratchpad(cfg.config)
		}
		if cfg.scratch != nil {
			cfg.kb_font = kf
			cfg.kern = kf.Blob.Tables[.GPOS].Length == 0
		} else if cfg.config != nil {
			kb.DestroyShapeConfig(cfg.config)
			cfg.config = nil
		}
	}
	if cfg.kb_font == nil {
		cfg.kern = true
	}
	append(&s.configs, cfg)
	return &s.configs[len(s.configs) - 1]
}

// Script and bidi level of each codepoint of the line [a, b) (Unicode script
// runs from kb_text_shape; levels for a left-to-right paragraph,
// text_bidi.odin).
@(private)
shaper_itemize :: proc(s: ^Text_Shaper, a, b: i32) {
	// Fast path: Latin with common punctuation, symbols and digits is one
	// left-to-right Latin run.
	latin := true
	for r in s.runes[a:b] {
		if r >= 0x370 && (r < 0x2000 || r > 0x20cf) {
			latin = false
			break
		}
	}
	if latin {
		for i in a ..< b {
			s.script[i] = .LATIN
			s.level[i] = 0
		}
		return
	}
	bs: kb.break_state
	kb.BreakBegin(&bs, .KBTS_DIRECTION_LTR, .NORMAL, {})
	// Breaks come per kind in order, but kinds interleave: script changes
	// are applied from their position on.
	apply :: proc(s: ^Text_Shaper, br: kb.break_type, a, b: i32) {
		at := a + i32(br.Position)
		if at < b {
			for i in at ..< b {
				s.script[i] = br.Script
			}
		}
	}
	for i in a ..< b {
		s.script[i] = .DONT_KNOW
	}
	for i in a ..< b {
		kb.BreakAddCodepoint(&bs, s.runes[i], 1, b32(i == b - 1))
		for {
			br, ok := kb.Break(&bs)
			if !ok {
				break
			}
			if .SCRIPT in br.Flags {
				apply(s, br, a, b)
			}
		}
	}
	kb.BreakEnd(&bs)
	for {
		br, ok := kb.Break(&bs)
		if !ok {
			break
		}
		if .SCRIPT in br.Flags {
			apply(s, br, a, b)
		}
	}
	for i in a ..< b {
		s.bidi[i] = bidi_class(s.runes[i], s.script[i])
	}
	bidi_resolve(s.bidi[a:b], s.level[a:b])
}

// Shapes one segment, appending its glyphs to the shaper's line glyphs.
@(private)
shaper_shape :: proc(fonts: ^Font_Collection, s: ^Text_Shaper, seg: ^Shape_Segment, pieces: []Text_Piece) {
	seg.glyph_first = i32(len(s.glyphs))
	defer seg.glyph_count = i32(len(s.glyphs)) - seg.glyph_first

	cfg := shaper_config(fonts, s, seg.font, seg.script)
	shaped := false
	if cfg.kb_font != nil {
		shaper_place_configs(s, cfg, seg)
		kb.ClearActiveGlyphs(&s.storage)
		for i in seg.first ..< seg.first + seg.count {
			p := s.piece[i]
			if g := kb.PushGlyph(&s.storage, cfg.kb_font, s.runes[i], s.piece_config[p], c.int(i)); g != nil {
				g.Flags += s.piece_features[p].flags
			}
		}
		dir: kb.direction = .KBTS_DIRECTION_RTL if seg.level & 1 == 1 else .KBTS_DIRECTION_LTR
		it, err := kb.ShapeDirect(cfg.scratch, &s.storage, dir)
		if err == .NONE && !s.storage.Error {
			for {
				g, ok := kb.GlyphIteratorNext(&it)
				if !ok {
					break
				}
				append(&s.glyphs, Shaped_Glyph{Glyph_Index(g.Id), i32(g.UserIdOrCodepointIndex), {g.OffsetX, g.OffsetY}, g.AdvanceX, g.AttachGlyph != nil})
			}
			shaped = true
		} else {
			resize(&s.glyphs, int(seg.glyph_first))
		}
	}
	if !shaped {
		// No OpenType shaping for this face: one glyph per codepoint.
		for i in seg.first ..< seg.first + seg.count {
			g := font_glyph_index(seg.font, s.runes[i])
			adv, _ := font_glyph_advance(seg.font, g)
			append(&s.glyphs, Shaped_Glyph{id = g, cluster = i, advance = adv})
		}
	}
	rows := s.glyphs[seg.glyph_first:]
	if cfg.kern && seg.level & 1 == 0 {
		// Legacy `kern` table pairs (fonts without GPOS, e.g. Vera).
		for j in 1 ..< len(rows) {
			if s.piece_features[s.piece[rows[j - 1].cluster]].kern {
				rows[j - 1].advance += font_glyph_kern(seg.font, rows[j - 1].id, rows[j].id)
			}
		}
	}
}

// Records a piece's feature overrides: its style's, then liga, clig and
// dlig off when letter-spaced (CSS); kb_text_shape takes a tag's first.
@(private)
shaper_add_piece_features :: proc(s: ^Text_Shaper, st: Text_Style) {
	pf := Piece_Features{first = i32(len(s.overrides)), kern = true}
	for f in st.features {
		tag := [4]u8{' ', ' ', ' ', ' '}
		copy(tag[:], f.tag)
		append(&s.overrides, kb.feature_override{kb.feature_tag(transmute(u32)tag), c.int(f.value)})
		if pf.kern && string(tag[:]) == "kern" && f.value == 0 {
			pf.kern = false
		}
		if f.value != 0 {
			for ff in FLAGGED_FEATURES {
				if ff.tag == string(tag[:]) {
					pf.flags += {ff.flag}
				}
			}
		}
	}
	if st.letter_spacing != 0 {
		append(&s.overrides, kb.feature_override{.liga, 0}, kb.feature_override{.clig, 0}, kb.feature_override{.dlig, 0})
	}
	pf.count = i32(len(s.overrides)) - pf.first
	append(&s.piece_features, pf)
	append(&s.piece_config, nil)
}

// Places the glyph configs of the segment's pieces that override features
// into the shaper's words (sized, then placed once: the configs point into
// them), good while the segment shapes.
@(private)
shaper_place_configs :: proc(s: ^Text_Shaper, cfg: ^Shape_Config, seg: ^Shape_Segment) {
	p0, p1 := s.piece[seg.first], s.piece[seg.first + seg.count - 1]
	words := 0
	for p in p0 ..= p1 {
		pf := s.piece_features[p]
		if pf.count > 0 {
			words += (int(kb.SizeOfGlyphConfig(cfg.config, s.overrides[pf.first:][:pf.count])) + 7) / 8
		}
	}
	resize(&s.config_words, words)
	at := 0
	for p in p0 ..= p1 {
		pf := s.piece_features[p]
		s.piece_config[p] = nil
		if pf.count > 0 {
			o := s.overrides[pf.first:][:pf.count]
			s.piece_config[p] = kb.PlaceGlyphConfig(cfg.config, o, &s.config_words[at])
			at += (int(kb.SizeOfGlyphConfig(cfg.config, o)) + 7) / 8
		}
	}
}

// Visual order of the line's segments (UAX #9 rule L2 over their levels).
@(private)
shaper_reorder :: proc(s: ^Text_Shaper) {
	clear(&s.order)
	top: u8
	for seg, i in s.segs {
		append(&s.order, i32(i))
		top = max(top, seg.level)
	}
	for level := top; level >= 1; level -= 1 {
		i := 0
		for i < len(s.order) {
			if s.segs[s.order[i]].level < level {
				i += 1
				continue
			}
			j := i
			for j < len(s.order) && s.segs[s.order[j]].level >= level {
				j += 1
			}
			for x, y := i, j - 1; x < y; x, y = x + 1, y - 1 {
				s.order[x], s.order[y] = s.order[y], s.order[x]
			}
			i = j
		}
	}
}
