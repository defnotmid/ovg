package ovg

import "core:mem"
import "core:sync"

import ft "deps:oglyph/font"
import sh "deps:oglyph/shape"

// Font files, each face of one as its tables have it whatever the instance
// drawn: its family, weight and style, its layout tables prepared for
// shaping and its shaping plans, made once for every face added from it to
// the collections that share the table (font_collection_init's `files`),
// on any thread. Rows are made one at a time and never move: faces keep
// theirs as other threads add files, and only making a row, its layout
// tables or a plan takes the lock. The data is borrowed; the table must
// outlive the collections that share it.
Font_Files :: struct {
	lock:      sync.Mutex,
	rows:      [dynamic]^Font_File,
	allocator: mem.Allocator,
}

// Face `index` of a font file `data` (borrowed).
Font_File :: struct {
	data:    []u8,
	index:   i32,
	family:  string, // owned
	weight:  int,
	italic:  bool,
	// The layout tables, prepared on first use, and the plans made for the
	// file's faces, newest first; each published whole (read without the
	// lock).
	shaping: ^sh.Layout,
	plans:   ^File_Plan,
}

// A plan for the faces whose instances pick `records` (sh.plan_variations),
// for a script, direction and feature settings (their ranges dropped: a
// plan depends on tags, values and whether each is global).
@(private)
File_Plan :: struct {
	next:      ^File_Plan,
	records:   [sh.Table_Kind]i32,
	script:    sh.Script,
	direction: sh.Direction,
	features:  []sh.Feature,
	plan:      sh.Plan,
}

font_files_init :: proc(files: ^Font_Files, allocator := context.allocator) {
	files^ = {allocator = allocator}
	files.rows.allocator = allocator
}

font_files_destroy :: proc(files: ^Font_Files) {
	for file in files.rows {
		delete(file.family, files.allocator)
		if file.shaping != nil {
			sh.layout_destroy(file.shaping)
			free(file.shaping, files.allocator)
		}
		for p := file.plans; p != nil; {
			next := p.next
			sh.plan_destroy(&p.plan)
			delete(p.features, files.allocator)
			free(p, files.allocator)
			p = next
		}
		free(file, files.allocator)
	}
	delete(files.rows)
	files^ = {}
}

// The row of `font` (face `index` of `data`), made the first time it is
// asked for.
@(private)
font_file :: proc(files: ^Font_Files, data: []u8, index: i32, font: ^Font) -> ^Font_File {
	sync.mutex_lock(&files.lock)
	defer sync.mutex_unlock(&files.lock)
	for file in files.rows {
		if raw_data(file.data) == raw_data(data) && len(file.data) == len(data) && file.index == index {
			return file
		}
	}
	file := new(Font_File, files.allocator)
	file.data, file.index = data, index
	file.family, file.weight, file.italic = font_identity(data, font, files.allocator)
	append(&files.rows, file)
	return file
}

// The file's layout tables, prepared from `face` (any of its instances)
// on first use.
@(private)
file_shaping :: proc(files: ^Font_Files, file: ^Font_File, face: ^ft.Face) -> ^sh.Layout {
	if l := sync.atomic_load_explicit(&file.shaping, .Acquire); l != nil {
		return l
	}
	sync.mutex_lock(&files.lock)
	defer sync.mutex_unlock(&files.lock)
	if file.shaping == nil {
		l := new(sh.Layout, files.allocator)
		sh.layout_init(l, face, files.allocator)
		sync.atomic_store_explicit(&file.shaping, l, .Release)
	}
	return file.shaping
}

// The plan for `font` (an instance of the file) shaping a script and
// direction with feature settings, made on first use.
@(private)
file_plan :: proc(files: ^Font_Files, file: ^Font_File, font: ^Font, script: sh.Script, direction: sh.Direction, features: []sh.Feature) -> ^sh.Plan {
	records := font.plan_records
	head := sync.atomic_load_explicit(&file.plans, .Acquire)
	if p := plan_find(head, nil, records, script, direction, features); p != nil {
		return &p.plan
	}
	layout := file_shaping(files, file, &font.face)
	sync.mutex_lock(&files.lock)
	defer sync.mutex_unlock(&files.lock)
	// One made since `head` was read.
	if p := plan_find(file.plans, head, records, script, direction, features); p != nil {
		return &p.plan
	}
	p := new(File_Plan, files.allocator)
	p.next, p.records, p.script, p.direction = file.plans, records, script, direction
	p.features = make([]sh.Feature, len(features), files.allocator)
	for k, i in features {
		// Ranged settings are kept as covering one codepoint.
		p.features[i] = {k.tag, k.value, 0, 0 if sh.feature_is_global(k) else 1}
	}
	sh.plan_init(&p.plan, layout, &font.face, script, direction, 0, features, files.allocator)
	sync.atomic_store_explicit(&file.plans, p, .Release)
	return &p.plan
}

// The plan of the list from `p` up to `stop` that matches.
@(private = "file")
plan_find :: proc(p, stop: ^File_Plan, records: [sh.Table_Kind]i32, script: sh.Script, direction: sh.Direction, features: []sh.Feature) -> ^File_Plan {
	search: for q := p; q != stop; q = q.next {
		if q.records != records || q.script != script || q.direction != direction || len(q.features) != len(features) {
			continue
		}
		for k, i in q.features {
			if k.tag != features[i].tag || k.value != features[i].value || sh.feature_is_global(k) != sh.feature_is_global(features[i]) {
				continue search
			}
		}
		return q
	}
	return nil
}
