package svg

import "core:math"
import "core:slice"

import vg ".."

// Drawing a `Document` (svg.odin): a walk over its node table that
// issues canvas and layer calls. Group opacity, clip paths, masks, filters
// and blend modes go through the layer stack (layers.odin), patterns
// through pattern tiles. The document is read-only while drawing, so one
// document can be drawn by many canvases (threads) at once, each with its
// own `Renderer`.

// Replaces properties of the elements with `id` (every instance) while
// drawing: how a host animates parts of an SVG.
Override :: struct {
	id:                string,
	// Applied in the element's own coordinates, inside its transform (so a
	// rotation turns the part about a point of its own drawing).
	transform:         Maybe(vg.Transform2D),
	// `transform` replaces the element's transform instead.
	replace_transform: bool,
	// Replaces the element's opacity.
	opacity:           Maybe(f32),
	// Replace the fill / stroke paint (fill-opacity and stroke-opacity
	// still apply); descendants inheriting the element's fill / stroke get
	// it too.
	fill:              Maybe(vg.Color),
	stroke:            Maybe(vg.Color),
	// false hides the element; true shows it even with visibility="hidden".
	visible:           Maybe(bool),
}

// The state drawing one document on one canvas keeps, reused across draws
// (no allocation per element once warm). `renderer_bind` gives it the
// document's images; a host drawing several documents keeps a renderer for
// each.
Renderer :: struct {
	path:        vg.Path,
	clip:        vg.Path,
	// Per document id: the override index, or -1.
	override_of: [dynamic]i32,
	// Canvas images of the bound document's bitmaps, by bitmap: smooth,
	// then nearest (made only for bitmaps an image draws pixelated).
	images:      [dynamic][2]vg.Image_Id,
}

// Makes the canvas images of `doc`'s bitmaps for drawing it on `c`,
// releasing those of the document bound before.
renderer_bind :: proc(r: ^Renderer, c: ^vg.Canvas, doc: ^Document) {
	renderer_unbind(r, c)
	resize(&r.images, len(doc.bitmaps))
	pixelated := make([]bool, len(doc.bitmaps), context.temp_allocator)
	for im in doc.images {
		if im.pixelated && im.bitmap >= 0 {
			pixelated[im.bitmap] = true
		}
	}
	for &b, i in doc.bitmaps {
		src := vg.image_source_rgba(b.pixels, b.width, b.height)
		// Shared by pixel address: players of several recording canvases
		// share one texture.
		key := u64(uintptr(raw_data(b.pixels)))
		r.images[i][0], _ = vg.create_image_shared(c, src, key, stable = true)
		if pixelated[i] {
			r.images[i][1], _ = vg.create_image_shared(c, src, key ~ 1, stable = true, flags = {.Nearest})
		}
	}
}

// Releases the bound document's images (before destroying the document).
renderer_unbind :: proc(r: ^Renderer, c: ^vg.Canvas) {
	for pair in r.images {
		for id in pair {
			if vg.image_id_valid(id) {
				vg.delete_image(c, id)
			}
		}
	}
	clear(&r.images)
}

renderer_destroy :: proc(r: ^Renderer, c: ^vg.Canvas) {
	renderer_unbind(r, c)
	vg.path_destroy(&r.path)
	vg.path_destroy(&r.clip)
	delete(r.override_of)
	delete(r.images)
	r^ = {}
}

// ---- text layout ----------------------------------------------------------------------

// A document's text laid out with a font collection (`layout`), the
// stage between parsing and drawing: data out of layout, data in to
// `draw`. Positioned glyphs in one array, runs of one face over it,
// and per document text (`doc.texts` order) its range of runs. The fonts
// are borrowed: faces added keep the layout; lay out again after faces are
// removed or the emoji face set, and for each document.
Layout :: struct {
	// The collection laid out with, whose faces the runs name.
	fonts:   ^vg.Font_Collection,
	glyphs:  [dynamic]vg.Positioned_Glyph,
	// Per glyph of a run along a path: its direction (cos, sin), {0, 0}
	// off the path (text_layout_on_path).
	turns:   [dynamic]vg.Vec2,
	runs:    [dynamic]Glyph_Run,
	texts:   [dynamic]vg.Range,
	// Font families the text asks for that the collection lacks (strings
	// owned by the document), for the host to report.
	missing: [dynamic]string,
	// Scratch of the stage.
	line:    vg.Text_Layout,
	pieces:  [dynamic]vg.Text_Piece,
	path:    vg.Text_Path,
}

// Glyphs of one face and one document piece (`doc.pieces[piece]`, whose
// style paints them).
Glyph_Run :: struct {
	face:   vg.Face_Id,
	em:     f32, // font units to pixels
	glyphs: vg.Range,
	piece:  u32,
	// Along a path: `turns` holds its glyphs' directions.
	turned: bool,
}

// Lays out every text of `doc` with `fonts` into `out` (cleared first).
layout :: proc(doc: ^Document, fonts: ^vg.Font_Collection, out: ^Layout) {
	out.fonts = fonts
	clear(&out.glyphs)
	clear(&out.turns)
	clear(&out.runs)
	clear(&out.texts)
	clear(&out.missing)
	for &t in doc.texts {
		first := len(out.runs)
		pen: vg.Vec2
		along: f32
		for ci in t.chunks.start ..< t.chunks.start + t.chunks.count {
			ch := &doc.chunks[ci]
			pen, along = layout_chunk(fonts, doc, ch, pen, along, &out.line, &out.pieces, &out.path, &t.wrap)
			for family in out.line.missing {
				if family != "" && !slice.contains(out.missing[:], family) {
					append(&out.missing, family)
				}
			}
			drawn := wrap_glyphs(&out.line, &t.wrap)
			for run in out.line.runs {
				count := min(run.count, drawn - run.first)
				if count <= 0 {
					break
				}
				start := len(out.glyphs)
				append(&out.glyphs, ..out.line.glyphs[run.first:][:count])
				turned := len(out.line.turns) > 0
				resize(&out.turns, len(out.glyphs))
				if turned {
					copy(out.turns[start:], out.line.turns[run.first:][:count])
				}
				append(&out.runs, Glyph_Run{run.face, run.em, {u32(start), u32(count)}, ch.pieces.start + run.paint, turned})
			}
		}
		append(&out.texts, vg.Range{u32(first), u32(len(out.runs) - first)})
	}
}

layout_destroy :: proc(l: ^Layout) {
	delete(l.glyphs)
	delete(l.turns)
	delete(l.runs)
	delete(l.texts)
	delete(l.missing)
	vg.text_layout_destroy(&l.line)
	delete(l.pieces)
	vg.text_path_destroy(&l.path)
	l^ = {}
}

// Appends the filled geometry of `doc` to `out`, in its `width x height`
// coordinate system (what `draw` draws before its `transform`): every
// shape with a fill (paths, rects, circles, ellipses, lines, polygons,
// instances of `use`) under its transforms, and the text glyphs when `text`
// is the document's layout. With `id`, only that element's subtree, under
// its ancestors' transforms (its first use's, outside the drawing), even when the element
// itself is display="none" (kept for this, as for overrides); `found` is
// false when no element has the id. Skipped as `draw` skips them:
// display="none" below it, visibility="hidden", opacity 0. Ignored: strokes, images, clip paths,
// masks, filters and nested viewport clips. `rule` is the fill rule of the
// shapes (text fills non-zero); `mixed` when they differ, so no one rule
// fills the result exactly as drawn.
element_path :: proc(doc: ^Document, out: ^vg.Path, id := "", text: ^Layout = nil) -> (rule: vg.Fill_Rule, mixed, found: bool) {
	if len(doc.nodes) == 0 {
		return .Non_Zero, false, id == ""
	}
	start: i32 = 0
	t := vg.TRANSFORM_IDENTITY
	if id != "" {
		start = find(doc, id)
		if start < 0 {
			return .Non_Zero, false, false
		}
		for j := placed_in(doc, start); j >= 0; j = placed_in(doc, j) {
			t = vg.transform_multiply(t, doc.nodes[j].transform)
		}
	}
	w := Path_Walk{doc = doc, text = text, out = out, start = start}
	path_node(&w, start, t)
	return w.rule, w.mixed, true
}

@(private)
Path_Walk :: struct {
	doc:         ^Document,
	text:        ^Layout,
	out:         ^vg.Path,
	start:       i32,
	rule:        vg.Fill_Rule,
	seen, mixed: bool,
}

@(private)
path_node :: proc(w: ^Path_Walk, i: i32, parent: vg.Transform2D) {
	doc := w.doc
	n := &doc.nodes[i]
	if (.Off in n.flags && i != w.start) || n.opacity <= 0 {
		return
	}
	t := vg.transform_multiply(n.transform, parent)
	switch n.kind {
	case .Group:
		for ch := n.first_child; ch >= 0; ch = doc.nodes[ch].next {
			path_node(w, ch, t)
		}
	case .Shape:
		sh := &doc.shapes[n.data]
		if .Hidden in n.flags || sh.style.fill.kind == .None {
			return
		}
		vg.path_append_contours(w.out, &doc.geometry, int(sh.contours.start), int(sh.contours.count), t)
		path_rule(w, sh.style.fill_rule)
	case .Text:
		if w.text == nil || int(n.data) >= len(w.text.texts) {
			return
		}
		runs := w.text.texts[n.data]
		for run in w.text.runs[runs.start:][:runs.count] {
			pc := &doc.pieces[run.piece]
			if pc.hidden || pc.style.fill.kind == .None {
				continue
			}
			font := vg.font_collection_font(w.text.fonts, run.face)
			for g, k in w.text.glyphs[run.glyphs.start:][:run.glyphs.count] {
				c0 := len(w.out.pts)
				if pc.rotate == 0 && !run.turned {
					vg.font_glyph_path(font, g.glyph, g.x, g.y, run.em, w.out)
					path_transform(w.out, c0, t)
				} else if gt, drawn := glyph_transform(w.text, run, pc, k); drawn {
					vg.font_glyph_path(font, g.glyph, 0, 0, run.em, w.out)
					path_transform(w.out, c0, vg.transform_multiply(gt, t))
				}
			}
			path_rule(w, .Non_Zero)
		}
	case .Image:
	case .Use:
		path_node(w, n.data, t)
	}
}

// Maps the points of `p` from index `first` on by `t`.
@(private)
path_transform :: proc(p: ^vg.Path, first: int, t: vg.Transform2D) {
	if t == vg.TRANSFORM_IDENTITY {
		return
	}
	for &q in p.pts[first:] {
		q = vg.transform_point(t, q.x, q.y)
	}
}

@(private)
path_rule :: proc(w: ^Path_Walk, rule: vg.Fill_Rule) {
	if !w.seen {
		w.rule, w.seen = rule, true
	} else if rule != w.rule {
		w.mixed = true
	}
}

// Draws `doc` into its `width x height` coordinate system, mapped by
// `transform` before the canvas's current transform. Effects need the
// layer stack begun for the frame (`layer_stack_begin`, with a root layer
// when `doc.uses_blend` and the target is the screen).
draw :: proc(c: ^vg.Canvas, ls: ^vg.Layer_Stack, r: ^Renderer, doc: ^Document, text: ^Layout, transform := vg.TRANSFORM_IDENTITY, overrides: []Override = nil) {
	if len(doc.nodes) == 0 {
		return
	}
	if len(overrides) > 0 {
		resize(&r.override_of, len(doc.ids))
		for &o in r.override_of {
			o = -1
		}
		for ov, i in overrides {
			if idx, ok := doc.id_map[ov.id]; ok {
				r.override_of[idx] = i32(i)
			}
		}
	}
	d := Draw {
		c         = c,
		ls        = ls,
		r         = r,
		doc       = doc,
		text      = text,
		overrides = overrides,
	}
	vg.save(c)
	vg.apply_transform(c, transform)
	draw_node(&d, 0, {}, false)
	vg.restore(c)
}

@(private)
Draw :: struct {
	c:         ^vg.Canvas,
	ls:        ^vg.Layer_Stack,
	r:         ^Renderer,
	doc:       ^Document,
	// The document's text laid out (layout); nil draws no text.
	text:      ^Layout,
	overrides: []Override,
}

// Fill / stroke overrides that children inheriting from their parent get,
// and whether an override showed the parent (`visible = true`).
@(private)
Inherit :: struct {
	fill, stroke: Maybe(vg.Color),
	visible:      bool,
}

@(private)
draw_node :: proc(d: ^Draw, i: i32, inh: Inherit, clip_mode: bool) {
	doc, c := d.doc, d.c
	n := &doc.nodes[i]
	hidden := .Hidden in n.flags
	// Shown by an override on an ancestor, its visibility inherited.
	forced := inh.visible && .Visibility_Inherited in n.flags
	if forced {
		hidden = false
	}
	opacity := n.opacity if !clip_mode else 1
	fill_ov := inh.fill if .Fill_Inherited in n.flags else nil
	stroke_ov := inh.stroke if .Stroke_Inherited in n.flags else nil
	ov: ^Override
	if n.id >= 0 && len(d.overrides) > 0 {
		if k := d.r.override_of[n.id]; k >= 0 {
			ov = &d.overrides[k]
		}
	}
	shown := false
	if ov != nil {
		if v, ok := ov.visible.?; ok {
			if !v {
				return
			}
			hidden, shown, forced = false, true, true
		}
		if o, ok := ov.opacity.?; ok && !clip_mode {
			opacity = clamp(o, 0, 1)
		}
		if f, ok := ov.fill.?; ok {
			fill_ov = f
		}
		if s, ok := ov.stroke.?; ok {
			stroke_ov = s
		}
	}
	if .Off in n.flags && !shown {
		return // display="none" until an override shows it
	}
	if opacity <= 0 {
		return
	}
	fl: vg.Filter
	has_filter := false
	if n.filter >= 0 && !clip_mode {
		ok: bool
		fl, ok = make_filter(doc, n)
		if bms := doc.filter_bitmaps[doc.filters[n.filter].bitmaps.start:][:doc.filters[n.filter].bitmaps.count]; ok && len(bms) > 0 {
			// feImage bitmaps as canvas images (the filter lives until
			// the node's layer pops, within this call).
			ids := make([]vg.Image_Id, len(bms), context.temp_allocator)
			for bm, i in bms {
				ids[i] = bitmap_image(d.r, bm, false)
			}
			fl.images = ids
		}
		if !ok {
			return
		}
		has_filter = true
	}

	vg.save(c)
	defer vg.restore(c)
	if ov != nil && ov.replace_transform {
		if t, ok := ov.transform.?; ok {
			vg.apply_transform(c, t)
		} else {
			vg.apply_transform(c, n.transform)
		}
	} else {
		vg.apply_transform(c, n.transform)
		if ov != nil {
			if t, ok := ov.transform.?; ok {
				vg.apply_transform(c, t)
			}
		}
	}
	if .Clip_Rect in n.flags {
		cr := n.clip_rect
		vg.intersect_scissor(c, cr.x, cr.y, cr.w, cr.h)
	}

	layers := push_effects(d, n, opacity, &fl if has_filter else nil, clip_mode, fill_ov, stroke_ov)
	child_inh := Inherit{fill_ov, stroke_ov, forced}
	switch n.kind {
	case .Group:
		for ch := n.first_child; ch >= 0; ch = doc.nodes[ch].next {
			draw_node(d, ch, child_inh, clip_mode)
		}
	case .Shape:
		if !hidden {
			draw_shape(d, n, fill_ov, stroke_ov, clip_mode)
		}
	case .Text:
		// Pieces carry their own visibility (a tspan can show in hidden text).
		draw_text(d, n, fill_ov, stroke_ov, clip_mode, forced)
	case .Image:
		if !hidden && !clip_mode {
			draw_image(d, n)
		}
	case .Use:
		draw_node(d, n.data, child_inh, clip_mode)
	}
	for _ in 0 ..< layers {
		vg.layer_pop(d.ls, c)
	}
}

// The node's filter with its region's bounding box; false when the element
// is filtered away (no primitives, an empty region).
@(private)
make_filter :: proc(doc: ^Document, n: ^Node) -> (vg.Filter, bool) {
	f := &doc.filters[n.filter]
	if f.primitives.count == 0 {
		return {}, false
	}
	region := f.region
	region.bbox = n.bbox
	if region.units == .Object_Bounding_Box && (n.bbox.w <= 0 || n.bbox.h <= 0) {
		return {}, false
	}
	return vg.Filter {
			primitives = doc.filter_prims[f.primitives.start:][:f.primitives.count],
			merge_refs = doc.filter_refs[f.refs.start:][:f.refs.count],
			srgb = f.srgb,
			region = region,
			values = doc.filter_values[f.values.start:][:f.values.count],
		},
		true
}

// Pushes the layers the node's effects need (opacity, clip, mask, filter,
// blend, isolation) and returns how many. `fl` must stay valid until the
// layers are popped.
@(private)
push_effects :: proc(d: ^Draw, n: ^Node, opacity: f32, fl: ^vg.Filter, clip_mode: bool, fill_ov, stroke_ov: Maybe(vg.Color)) -> int {
	doc, c, ls := d.doc, d.c, d.ls
	if clip_mode {
		if n.clip < 0 {
			return 0
		}
		return push_clip(d, n.clip, n.bbox)
	}
	needs := opacity < 1 || n.clip >= 0 || n.mask >= 0 || fl != nil || n.blend != .Normal || .Isolate in n.flags
	if !needs {
		return 0
	}
	if opacity < 1 && n.clip < 0 && n.mask < 0 && fl == nil && n.blend == .Normal && .Isolate not_in n.flags && single_paint(d, n, fill_ov, stroke_ov) {
		// One paint over its own pixels: multiplying alpha is exact.
		vg.set_global_alpha(c, vg.state(c).alpha * opacity)
		return 0
	}
	params := vg.Layer_Params {
		opacity = opacity,
		blend   = n.blend,
	}
	complex := false
	if n.clip >= 0 {
		cl := &doc.clips[n.clip]
		if cl.simple >= 0 {
			params.clip_rule = clip_path(d, n.clip, n.bbox)
			params.clip_path = &d.r.clip
		} else {
			complex = true
		}
	}
	if !complex {
		params.filter = fl
		if n.mask >= 0 {
			params.mask_alpha = doc.masks[n.mask].alpha
		}
		vg.layer_push(ls, c, params)
		if n.mask >= 0 {
			vg.layer_mask_begin(ls, c)
			draw_mask(d, n.mask, n.bbox)
			vg.layer_mask_end(ls, c)
		}
		return 1
	}
	count := 0
	if n.mask >= 0 {
		// Mask, opacity and blend outside; filter and clip inside (SVG
		// order: filter, clip, mask, opacity).
		params.mask_alpha = doc.masks[n.mask].alpha
		vg.layer_push(ls, c, params)
		vg.layer_mask_begin(ls, c)
		draw_mask(d, n.mask, n.bbox)
		vg.layer_mask_end(ls, c)
		params = {}
		count = 1
	}
	params.filter = fl
	params.mask_alpha = true
	vg.layer_push(ls, c, params)
	vg.layer_mask_begin(ls, c)
	draw_clip_content(d, n.clip, n.bbox)
	vg.layer_mask_end(ls, c)
	return count + 1
}

// Whether the node paints one fill or one stroke only (and nothing under
// it overlaps itself).
@(private)
single_paint :: proc(d: ^Draw, n: ^Node, fill_ov, stroke_ov: Maybe(vg.Color)) -> bool {
	#partial switch n.kind {
	case .Image:
		return true
	case .Shape:
		s := &d.doc.shapes[n.data].style
		has_fill := s.fill.kind != .None || fill_ov != nil
		has_stroke := (s.stroke.kind != .None || stroke_ov != nil) && s.stroke_width > 0
		return !(has_fill && has_stroke)
	}
	return false
}

// A layer clipped by clip `idx` (a path, or its content as a mask).
@(private)
push_clip :: proc(d: ^Draw, idx: i32, bbox: vg.Rect) -> int {
	cl := &d.doc.clips[idx]
	if cl.simple >= 0 {
		params: vg.Layer_Params
		params.clip_rule = clip_path(d, idx, bbox)
		params.clip_path = &d.r.clip
		vg.layer_push(d.ls, d.c, params)
		return 1
	}
	vg.layer_push(d.ls, d.c, {mask_alpha = true})
	vg.layer_mask_begin(d.ls, d.c)
	draw_clip_content(d, idx, bbox)
	vg.layer_mask_end(d.ls, d.c)
	return 1
}

// The clip transform for content in clip `cl` of an element with `bbox`.
@(private)
clip_transform :: proc(cl: ^Clip, bbox: vg.Rect) -> vg.Transform2D {
	if cl.bbox_units {
		return vg.transform_multiply({bbox.w, 0, 0, bbox.h, bbox.x, bbox.y}, cl.transform)
	}
	return cl.transform
}

// Builds a simple clip's path in the element's coordinates into r.clip.
@(private)
clip_path :: proc(d: ^Draw, idx: i32, bbox: vg.Rect) -> vg.Fill_Rule {
	doc := d.doc
	cl := &doc.clips[idx]
	k := &doc.nodes[cl.simple]
	sh := &doc.shapes[k.data]
	t := vg.transform_multiply(k.transform, clip_transform(cl, bbox))
	p := &d.r.clip
	vg.path_reset(p)
	vg.path_append_contours(p, &doc.geometry, int(sh.contours.start), int(sh.contours.count), t)
	return sh.style.fill_rule
}

// Draws a clip's content (white, clip-rule fills) into the current mask.
@(private)
draw_clip_content :: proc(d: ^Draw, idx: i32, bbox: vg.Rect) {
	doc, c := d.doc, d.c
	cl := &doc.clips[idx]
	nested := 0
	if cl.clip >= 0 {
		nested = push_clip(d, cl.clip, bbox)
	}
	vg.save(c)
	vg.set_global_alpha(c, 1)
	vg.apply_transform(c, clip_transform(cl, bbox))
	root := &doc.nodes[cl.content]
	for ch := root.first_child; ch >= 0; ch = doc.nodes[ch].next {
		draw_node(d, ch, {}, true)
	}
	vg.restore(c)
	for _ in 0 ..< nested {
		vg.layer_pop(d.ls, c)
	}
}

// Draws mask `idx`'s content into the current mask.
@(private)
draw_mask :: proc(d: ^Draw, idx: i32, bbox: vg.Rect) {
	doc, c, ls := d.doc, d.c, d.ls
	m := &doc.masks[idx]
	rect := m.rect
	if m.bbox_units {
		if bbox.w <= 0 || bbox.h <= 0 {
			return
		}
		rect = {bbox.x + rect.x * bbox.w, bbox.y + rect.y * bbox.h, rect.w * bbox.w, rect.h * bbox.h}
	}
	if rect.w <= 0 || rect.h <= 0 {
		return
	}
	nested := false
	if m.mask >= 0 {
		vg.layer_push(ls, c, {mask_alpha = doc.masks[m.mask].alpha})
		vg.layer_mask_begin(ls, c)
		draw_mask(d, m.mask, bbox)
		vg.layer_mask_end(ls, c)
		nested = true
	}
	vg.save(c)
	vg.set_global_alpha(c, 1)
	vg.intersect_scissor(c, rect.x, rect.y, rect.w, rect.h)
	if m.content_bbox {
		vg.apply_transform(c, {bbox.w, 0, 0, bbox.h, bbox.x, bbox.y})
	}
	root := &doc.nodes[m.content]
	for ch := root.first_child; ch >= 0; ch = doc.nodes[ch].next {
		draw_node(d, ch, {}, false)
	}
	vg.restore(c)
	if nested {
		vg.layer_pop(ls, c)
	}
}

@(private)
draw_shape :: proc(d: ^Draw, n: ^Node, fill_ov, stroke_ov: Maybe(vg.Color), clip_mode: bool) {
	doc, c := d.doc, d.c
	sh := &doc.shapes[n.data]
	s := &sh.style
	aa := .Crisp not_in n.flags
	// Paints first: pattern tiles draw with the scratch path.
	fill, has_fill := paint(d, s.fill, s.fill_opacity, fill_ov, n.bbox, clip_mode)
	stroke: vg.Paint
	has_stroke := false
	if !clip_mode && s.stroke_width > 0 {
		stroke, has_stroke = paint(d, s.stroke, s.stroke_opacity, stroke_ov, n.bbox, false)
	}
	if !has_fill && !has_stroke {
		return
	}
	if has_fill && sh.fill.data != nil {
		fill.fill_rule = s.fill_rule
		fill.anti_alias = aa
		vg.fill_shape(c, &sh.fill, fill)
	}
	if has_stroke && sh.stroke.data != nil {
		stroke.fill_rule = .Non_Zero
		stroke.anti_alias = aa
		vg.fill_shape(c, &sh.stroke, stroke)
	}
}

@(private)
stroke_settings :: proc(p: ^vg.Paint, s: ^Style, doc: ^Document, path_length: f32) {
	p.stroke.line_width = s.stroke_width
	p.stroke.line_join = s.join
	p.stroke.miter_limit = s.miter_limit
	vg.paint_set_line_cap(p, s.cap)
	if s.dash.count > 0 {
		p.stroke.dash = doc.dashes[s.dash.start:][:s.dash.count]
		p.stroke.dash_offset = s.dash_offset
		p.stroke.path_length = path_length
	}
}

// The ovg paint for an SVG paint over an element with `bbox`; false
// for none (or a bounding-box paint on an element without area).
@(private)
paint :: proc(d: ^Draw, sp: Paint, opacity: f32, ov: Maybe(vg.Color), bbox: vg.Rect, clip_mode: bool) -> (out: vg.Paint, ok: bool) {
	if clip_mode {
		return vg.paint_color(vg.WHITE), sp.kind != .None
	}
	if col, has := ov.?; has {
		out = vg.paint_color(col)
		vg.paint_mul_alpha(&out, opacity)
		return out, true
	}
	switch sp.kind {
	case .None:
		return {}, false
	case .Color:
		out = vg.paint_color(sp.color)
	case .Server:
		doc := d.doc
		s := &doc.servers[sp.server]
		if s.bbox_units && (bbox.w <= 0 || bbox.h <= 0) {
			return {}, false
		}
		switch s.kind {
		case .Linear:
			out = vg.paint_linear_gradient_stops(s.v[0], s.v[1], s.v[2], s.v[3], doc.stops[s.stops.start:][:s.stops.count])
		case .Radial:
			out = vg.paint_radial_gradient_focal_stops(s.v[0], s.v[1], s.v[2], s.v[3], s.v[4], s.v[5], doc.stops[s.stops.start:][:s.stops.count])
		case .Pattern:
			out = pattern_paint(d, s, bbox) or_return
		}
		out.spread = s.spread
		t := s.transform
		if s.bbox_units && s.kind != .Pattern {
			t = vg.transform_multiply(t, {bbox.w, 0, 0, bbox.h, bbox.x, bbox.y})
		}
		if t != vg.TRANSFORM_IDENTITY {
			out.transform = t
		}
	}
	vg.paint_mul_alpha(&out, opacity)
	return out, true
}

// Renders a pattern's tile at the current scale and returns an image paint
// repeating it.
@(private)
pattern_paint :: proc(d: ^Draw, s: ^Server, bbox: vg.Rect) -> (vg.Paint, bool) {
	doc, c, ls := d.doc, d.c, d.ls
	rect := s.rect
	if s.bbox_units {
		rect = {bbox.x + rect.x * bbox.w, bbox.y + rect.y * bbox.h, rect.w * bbox.w, rect.h * bbox.h}
	}
	if rect.w <= 0 || rect.h <= 0 {
		return {}, false
	}
	t := vg.transform_multiply(s.transform, vg.current_transform(c))
	sx := math.hypot(t[0], t[1])
	sy := math.hypot(t[2], t[3])
	pw := u32(clamp(math.ceil(rect.w * sx), 1, 4096))
	ph := u32(clamp(math.ceil(rect.h * sy), 1, 4096))
	tile := vg.layer_pattern_begin(ls, c, pw, ph)
	vg.save(c)
	vg.reset_transform(c)
	vg.reset_scissor(c)
	vg.set_global_alpha(c, 1)
	vg.set_composite_operation(c, .Source_Over)
	vg.scale(c, f32(pw) / rect.w, f32(ph) / rect.h)
	if s.has_view_box {
		vg.apply_transform(c, view_box_transform(s.view_box, s.aspect, rect.w, rect.h))
	} else if s.content_bbox {
		vg.apply_transform(c, {bbox.w, 0, 0, bbox.h, 0, 0})
	}
	root := &doc.nodes[s.content]
	for ch := root.first_child; ch >= 0; ch = doc.nodes[ch].next {
		draw_node(d, ch, {}, false)
	}
	vg.restore(c)
	vg.layer_pattern_end(ls, c)
	p := vg.paint_image(tile, rect.x, rect.y, rect.w, rect.h, 0)
	if s.transform != vg.TRANSFORM_IDENTITY {
		p.transform = s.transform
	}
	return p, true
}

@(private)
draw_text :: proc(d: ^Draw, n: ^Node, fill_ov, stroke_ov: Maybe(vg.Color), clip_mode, force_visible: bool) {
	doc, c, r, text := d.doc, d.c, d.r, d.text
	if text == nil || int(n.data) >= len(text.texts) {
		return
	}
	runs := text.texts[n.data]
	for run in text.runs[runs.start:][:runs.count] {
		pc := &doc.pieces[run.piece]
		if pc.hidden && !force_visible {
			continue
		}
		glyphs := text.glyphs[run.glyphs.start:][:run.glyphs.count]
		font := vg.font_collection_font(text.fonts, run.face)
		s := &pc.style
		fo := fill_ov if pc.fill_inherited else nil
		so := stroke_ov if pc.stroke_inherited else nil
		fill, has_fill := paint(d, s.fill, s.fill_opacity, fo, n.bbox, clip_mode)
		fill.fill_rule = .Non_Zero
		stroke: vg.Paint
		has_stroke := false
		if !clip_mode && s.stroke_width > 0 {
			stroke, has_stroke = paint(d, s.stroke, s.stroke_opacity, so, n.bbox, false)
			stroke_settings(&stroke, s, doc, 0)
		}
		if pc.rotate == 0 && !run.turned {
			if has_fill {
				vg.fill_glyph_outlines(c, font, glyphs, run.em, fill, &r.path)
			}
			if has_stroke {
				vg.stroke_glyph_outlines(c, font, glyphs, run.em, stroke, &r.path)
			}
			continue
		}
		for g, k in glyphs {
			gt, drawn := glyph_transform(text, run, pc, k)
			if !drawn {
				continue
			}
			vg.save(c)
			vg.apply_transform(c, gt)
			one := [1]vg.Positioned_Glyph{{g.glyph, 0, 0}}
			if has_fill {
				vg.fill_glyph_outlines(c, font, one[:], run.em, fill, &r.path)
			}
			if has_stroke {
				vg.stroke_glyph_outlines(c, font, one[:], run.em, stroke, &r.path)
			}
			vg.restore(c)
		}
	}
}

// Where glyph k of `run` goes, from its origin: turned along a path, then
// by SVG rotate about its origin; not drawn when off its path.
@(private)
glyph_transform :: proc(text: ^Layout, run: Glyph_Run, pc: ^Text_Piece, k: int) -> (t: vg.Transform2D, drawn: bool) {
	i := int(run.glyphs.start) + k
	g := text.glyphs[i]
	t = vg.transform_rotation(pc.rotate * math.RAD_PER_DEG)
	if run.turned {
		turn := text.turns[i]
		if turn == {} {
			return
		}
		t = vg.transform_multiply(t, {turn.x, turn.y, -turn.y, turn.x, 0, 0})
	}
	return vg.transform_multiply(t, vg.transform_translation(g.x, g.y)), true
}

// The canvas image of document bitmap `bm` (renderer_bind); none when
// the renderer isn't bound to the document.
@(private)
bitmap_image :: proc(r: ^Renderer, bm: i32, pixelated: bool) -> vg.Image_Id {
	if bm < 0 || int(bm) >= len(r.images) {
		return {}
	}
	return r.images[bm][1 if pixelated else 0]
}

@(private)
draw_image :: proc(d: ^Draw, n: ^Node) {
	doc, c, r := d.doc, d.c, d.r
	im := &doc.images[n.data]
	b := &doc.bitmaps[im.bitmap]
	id := bitmap_image(r, im.bitmap, im.pixelated)
	if !vg.image_id_valid(id) {
		return
	}
	iw, ih := f32(b.width), f32(b.height)
	ix, iy, dw, dh := im.x, im.y, im.w, im.h
	if im.fit != .None {
		k := min(im.w / iw, im.h / ih) if im.fit == .Meet else max(im.w / iw, im.h / ih)
		dw, dh = iw * k, ih * k
		ix = im.x + (im.w - dw) * im.align.x
		iy = im.y + (im.h - dh) * im.align.y
	}
	p := vg.paint_image(id, ix, iy, dw, dh, 0)
	path := &r.path
	vg.path_reset(path)
	if im.fit == .Slice {
		vg.path_rect(path, im.x, im.y, im.w, im.h)
	} else {
		vg.path_rect(path, ix, iy, dw, dh)
	}
	vg.fill_path(c, path, p)
}
