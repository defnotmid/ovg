package ovg

import "core:math"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:unicode"

import ft "deps:oglyph/font"

// A set of font faces found by family, weight and style (CSS font
// matching), with per-glyph fallback through every face. Face data is
// borrowed and must outlive the collection.

// A face of a Font_Collection, for as long as the collection holds it:
// the collection that made it and the face's index in its id table. Faces
// added before or after it keep it, a removed face's id names no face, and
// ids aren't reused; Face_Id{} names none, and neither does an id another
// collection made. Keep a face by its id: the pointers font_collection_face
// and font_collection_font give are for immediate use (adding faces moves
// them).
Face_Id :: struct {
	collection: u32,
	index:      u32,
}

Font_Face :: struct {
	family: string, // owned
	weight: int,
	italic: bool,
	font:   Font,
	id:     Face_Id,
}

Font_Collection :: struct {
	// Its allocator is the collection's: faces, their family names and their
	// fonts' shapes (collection_allocator).
	faces:          [dynamic]Font_Face,
	// Used when nothing matches, and as the last fallback for glyphs.
	fallback:       Font_Face,
	// Colour emoji face tried after `faces` (font_collection_set_emoji);
	// never matched by family.
	emoji:          Maybe(Font_Face),
	// The family text that names none is drawn in (borrowed); empty, or
	// a family no face has: every face competes by weight and style.
	default_family: string,
	// Guards the shaping state below and each face's layout tables
	// (prepared on first use), so layouts may run concurrently on one
	// collection.
	shape_lock:     sync.Mutex,
	// Idle shapers (text_shape.odin), one per concurrent layout.
	shapers:        [dynamic]^Text_Shaper,
	// Which collection this is (Face_Id.collection), set with its first id.
	serial:         u32,
	// Per face id, where its face is: its index in `faces`, else
	// PLACE_FALLBACK, PLACE_EMOJI or PLACE_GONE (removed, or an emoji face
	// replaced).
	places:         [dynamic]i32,
	// The faces of `faces` by a hash of their family (family_hash),
	// ascending, with what finding one scores: a family's faces lie
	// together, so a find is a binary search and a sweep of its run, not a
	// scan of every face.
	by_family:      [dynamic]Family_Entry,
}

@(private)
Family_Entry :: struct {
	hash:   u64,
	face:   Face_Id,
	// The face's (its family string, borrowed).
	family: string,
	weight: i32,
	italic: bool,
}

@(private = "file")
PLACE_FALLBACK :: -1
@(private = "file")
PLACE_EMOJI :: -2
@(private = "file")
PLACE_GONE :: -3

font_collection_init :: proc(c: ^Font_Collection, fallback_data: []u8 = nil, allocator := context.allocator) {
	c.faces = make([dynamic]Font_Face, allocator)
	c.places = make([dynamic]i32, allocator)
	c.by_family = make([dynamic]Family_Entry, allocator)
	data := fallback_data if fallback_data != nil else DEFAULT_FONT_DATA
	font, _ := font_load(data, 0, allocator)
	family, weight, italic := font_identity(data, &font, allocator)
	c.fallback = {family, weight, italic, font, face_id_new(c, PLACE_FALLBACK)}
}

font_collection_destroy :: proc(c: ^Font_Collection) {
	allocator := collection_allocator(c)
	for s in c.shapers {
		shaper_destroy(s)
	}
	delete(c.shapers)
	for &f in c.faces {
		delete(f.family, allocator)
		font_destroy(&f.font)
	}
	delete(c.faces)
	delete(c.places)
	delete(c.by_family)
	delete(c.fallback.family, allocator)
	font_destroy(&c.fallback.font)
	if e, ok := &c.emoji.?; ok {
		delete(e.family, allocator)
		font_destroy(&e.font)
	}
	c^ = {}
}

// The bundled default face (Bitstream Vera Sans).
DEFAULT_FONT_DATA :: #load("assets/Vera.ttf")

// Noto Color Emoji, COLRv1 build (vector, SIL OFL 1.1; ~5 MB). Linked only
// into programs that use it: `font_collection_set_emoji(&fonts, EMOJI_FONT_DATA)`.
EMOJI_FONT_DATA :: #load("assets/Noto-COLRv1.ttf")

// Sets the colour emoji face, tried for glyphs no face has and preferred for
// emoji presentation sequences (U+FE0F); a face it replaces is gone. The
// data is borrowed. Not while layouts run on the collection.
font_collection_set_emoji :: proc(c: ^Font_Collection, data: []u8) -> bool {
	allocator := collection_allocator(c)
	font, err := font_load(data, 0, allocator)
	if err != nil {
		return false
	}
	drop_shapers(c)
	if old, ok := &c.emoji.?; ok {
		c.places[old.id.index] = PLACE_GONE
		delete(old.family, allocator)
		font_destroy(&old.font)
	}
	family, weight, italic := font_identity(data, &font, allocator)
	c.emoji = Font_Face{family, weight, italic, font, face_id_new(c, PLACE_EMOJI)}
	return true
}

// Adds every face of a TTF/OTF/TTC, in order before face `before` (at the
// end when past the last), variable ones at the instance `variations` pick
// (font_load). Family, weight and style come from the font's tables, the
// weight from a wght setting and the style from ital or slnt when given.
// Returns the number of faces added. Not while layouts run on the
// collection (faces move; their ids stay).
font_collection_add :: proc(c: ^Font_Collection, data: []u8, before := max(int), variations: []Font_Variation = nil) -> int {
	allocator := collection_allocator(c)
	// A collection never initialized takes its allocator here, not from
	// the first append.
	c.faces.allocator = allocator
	c.by_family.allocator = allocator
	added := 0
	for index in 0 ..< 64 {
		font, err := font_load(data, i32(index), allocator, variations)
		if err != nil {
			break
		}
		family, weight, italic := font_identity(data, &font, allocator)
		for v in variations {
			switch v.tag {
			case "wght":
				weight = int(math.round(v.value))
			case "ital":
				italic = v.value >= 0.5
			case "slnt":
				italic = v.value != 0
			}
		}
		id := face_id_new(c, i32(len(c.faces)))
		append(&c.faces, Font_Face{family, weight, italic, font, id})
		h := family_hash(family)
		inject_at(&c.by_family, family_first(c, h), Family_Entry{h, id, c.faces[len(c.faces) - 1].family, i32(weight), italic})
		added += 1
	}
	if at := len(c.faces) - added; before < at {
		slice.rotate_right(c.faces[max(before, 0):], added)
		face_places(c, max(before, 0))
	}
	return added
}

// Removes and frees face `i` (of `faces`), whose id names no face after
// it; a `default_family` that is its name becomes empty. Not while layouts
// run on the collection.
font_collection_remove :: proc(c: ^Font_Collection, i: int) {
	drop_shapers(c)
	face := &c.faces[i]
	if raw_data(c.default_family) == raw_data(face.family) {
		c.default_family = ""
	}
	c.places[face.id.index] = PLACE_GONE
	h := family_hash(face.family)
	for k := family_first(c, h); k < len(c.by_family) && c.by_family[k].hash == h; k += 1 {
		if c.by_family[k].face == face.id {
			ordered_remove(&c.by_family, k)
			break
		}
	}
	delete(face.family, collection_allocator(c))
	font_destroy(&face.font)
	ordered_remove(&c.faces, i)
	face_places(c, i)
}

// Face `id`, for immediate use (adding faces moves it); nil once the face
// is removed (or, for an emoji face, replaced), for Face_Id{}, for an id
// of another collection and without a collection.
font_collection_face :: proc(c: ^Font_Collection, id: Face_Id) -> ^Font_Face {
	if c == nil || c.serial == 0 || id.collection != c.serial || int(id.index) >= len(c.places) {
		return nil
	}
	switch at := c.places[id.index]; at {
	case PLACE_FALLBACK:
		return &c.fallback
	case PLACE_EMOJI:
		return &c.emoji.?
	case PLACE_GONE:
		return nil
	case:
		return &c.faces[at]
	}
}

// The font of face `id` (font_collection_face's), to draw with.
font_collection_font :: proc(c: ^Font_Collection, id: Face_Id) -> ^Font {
	if f := font_collection_face(c, id); f != nil {
		return &f.font
	}
	return nil
}

// A new face id, its face at `place`. The first one a collection makes
// (font_collection_init makes the fallback's first) takes the collection's
// serial and gives the fallback index 0.
@(private = "file")
face_id_new :: proc(c: ^Font_Collection, place: i32) -> Face_Id {
	if c.serial == 0 {
		if c.places.allocator.procedure == nil {
			c.places.allocator = collection_allocator(c)
		}
		c.serial = serial_next()
		append(&c.places, PLACE_FALLBACK)
		c.fallback.id = {c.serial, 0}
		if place == PLACE_FALLBACK {
			return c.fallback.id
		}
	}
	append(&c.places, place)
	return {c.serial, u32(len(c.places) - 1)}
}

// A hash of a family name that names equal under strings.equal_fold
// share: each character taken as the least of its case-fold orbit
// (unicode.simple_fold), as equal_fold compares them.
@(private = "file")
family_hash :: proc(family: string) -> u64 {
	h: u64 = 0xcbf29ce484222325
	for r in family {
		least := r
		if r < 0x80 {
			if r >= 'a' && r <= 'z' {
				least = r - ('a' - 'A')
			}
		} else {
			for f := unicode.simple_fold(r); f != r; f = unicode.simple_fold(f) {
				least = min(least, f)
			}
		}
		h = (h ~ u64(least)) * 0x100000001b3
	}
	return h
}

// The first entry of `by_family` at or past hash `h`.
@(private = "file")
family_first :: proc(c: ^Font_Collection, h: u64) -> int {
	lo, hi := 0, len(c.by_family)
	for lo < hi {
		mid := (lo + hi) / 2
		if c.by_family[mid].hash < h {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return lo
}

// The places of faces[from:], after they moved.
@(private = "file")
face_places :: proc(c: ^Font_Collection, from: int) {
	for f, i in c.faces[from:] {
		c.places[f.id.index] = i32(from + i)
	}
}

// Pooled shapers hold plans made for faces (keyed by face id): a face
// going takes them with it.
@(private = "file")
drop_shapers :: proc(c: ^Font_Collection) {
	sync.mutex_lock(&c.shape_lock)
	for s in c.shapers {
		shaper_destroy(s)
	}
	clear(&c.shapers)
	sync.mutex_unlock(&c.shape_lock)
}

// The best face for `family` (case-insensitive): with `variations`, one
// whose instance they pick first; matching style next, then the nearest
// weight (0 means 400). An empty family is `default_family`
// when the collection has it, else every face competes (earlier faces win
// ties). `found = false` gives the fallback face, which is also found by
// its own family (so `default_family` may name it).
font_collection_find :: proc(c: ^Font_Collection, family: string, weight: int, italic := false, variations: []Font_Variation = nil) -> (face: Face_Id, found: bool) {
	if family == "" && c.default_family != "" {
		if f, ok := font_collection_find(c, c.default_family, weight, italic, variations); ok {
			return f, true
		}
	}
	want := weight if weight > 0 else 400
	// The best by score, then by place (earlier faces win ties).
	best := -1
	best_score := max(int)
	score :: #force_inline proc(f: ^Font, weight: int, face_italic: bool, want: int, italic: bool, variations: []Font_Variation) -> int {
		s := abs(weight - want) * 2 + (0 if face_italic == italic else 10000)
		if len(variations) > 0 && !picks_instance(f, variations) {
			s += 1 << 30
		}
		return s
	}
	if family == "" {
		// No family asked for: every face competes, the first of the right
		// style winning.
		for &f, i in c.faces {
			if sc := i + score(&f.font, f.weight, f.italic, want, italic, variations); sc < best_score {
				best, best_score = i, sc
			}
		}
	} else {
		// The family's run of the index, scored from its entries.
		h := family_hash(family)
		for k := family_first(c, h); k < len(c.by_family) && c.by_family[k].hash == h; k += 1 {
			e := &c.by_family[k]
			if e.family != family && !strings.equal_fold(e.family, family) {
				continue
			}
			at := int(c.places[e.face.index])
			if sc := score(&c.faces[at].font, int(e.weight), e.italic, want, italic, variations); sc < best_score || (sc == best_score && at < best) {
				best, best_score = at, sc
			}
		}
	}
	if best < 0 {
		// The fallback face answers to its own family too.
		return c.fallback.id, family == "" || strings.equal_fold(family, c.fallback.family)
	}
	return c.faces[best].id, true
}

// Whether `variations` pick the instance the font draws (a font without
// axes is the one instance any settings pick).
@(private = "file")
picks_instance :: proc(f: ^Font, variations: []Font_Variation) -> bool {
	face := f.face
	ft.set_variations(&face, variations)
	return face.coords == f.face.coords
}

// The face with a glyph for `r`: `primary`, else the first of `faces`,
// then the emoji face, then the fallback; `primary` and 0 when none has
// one.
font_collection_glyph :: proc(c: ^Font_Collection, r: rune, primary: Face_Id) -> (Face_Id, Glyph_Index) {
	if f := font_collection_font(c, primary); f != nil {
		if g := font_glyph_index_drawable(f, r); g != 0 {
			return primary, g
		}
	}
	for &f in c.faces {
		if f.id != primary {
			if g := font_glyph_index_drawable(&f.font, r); g != 0 {
				return f.id, g
			}
		}
	}
	if e, ok := &c.emoji.?; ok {
		if g := font_glyph_index(&e.font, r); g != 0 {
			return e.id, g
		}
	}
	if g := font_glyph_index(&c.fallback.font, r); g != 0 {
		return c.fallback.id, g
	}
	return primary, 0
}

// The first colour (COLR) face with a glyph for `r`: added faces, then the
// emoji face; Face_Id{} and 0 when none has one.
font_collection_emoji_glyph :: proc(c: ^Font_Collection, r: rune) -> (Face_Id, Glyph_Index) {
	for &f in c.faces {
		if f.font.colr != nil {
			if g := font_glyph_index(&f.font, r); g != 0 {
				return f.id, g
			}
		}
	}
	if e, ok := &c.emoji.?; ok && e.font.colr != nil {
		if g := font_glyph_index(&e.font, r); g != 0 {
			return e.id, g
		}
	}
	return {}, 0
}

// ---- font tables --------------------------------------------------------------------

// Family name (typographic family, else family), OS/2 weight class and
// italic bit of the face `font` was loaded from.
font_identity :: proc(data: []u8, font: ^Font, allocator := context.allocator) -> (family: string, weight: int, italic: bool) {
	weight = 400
	family = ft.name_string(&font.face, 16, allocator)
	if family == "" {
		family = ft.name_string(&font.face, 1, allocator)
	}
	if os2 := font.face.tables[.OS2]; os2.size >= 64 {
		weight = int(ft.read_u16(data, os2.at + 4))
		italic = ft.read_u16(data, os2.at + 62) & 1 != 0
	}
	if family == "" {
		family = strings.clone("Unknown", allocator)
	}
	return
}
