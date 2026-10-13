package ovg

import "core:encoding/base64"
import "core:encoding/xml"
import "core:fmt"
import "core:math"
import "core:mem"
import "core:mem/virtual"
import "core:slice"
import "core:strings"
import stbi "vendor:stb/image"

// SVG import: `svg_parse` turns SVG markup into an `Svg_Document`, a
// render-ready, data-oriented copy (like usvg's tree): `<use>` instances
// expanded, styles computed (presentation attributes, `style`, `<style>`
// rules, inheritance), units resolved, shapes converted to path data
// stored once, paint servers, clip paths, masks and filters in tables
// referenced by index. `svg_draw` (svg_draw.odin) walks it and issues
// canvas and layer calls, with per-id overrides for animating parts.
//
// Supported: svg (nested, viewBox, preserveAspectRatio), g, a, switch, use
// (elements, symbols, nested svg), path, rect, circle, ellipse, line,
// polyline, polygon, text / tspan (x, y, dx, dy, font properties,
// text-anchor, dominant-baseline, letter-spacing), image (data: URIs,
// other hrefs through `Svg_Parse_Options.load_file`; raster or SVG), linearGradient,
// radialGradient (fx, fy, fr), pattern, clipPath, mask, filter (every SVG
// 1.1 primitive; feImage of images, not elements),
// opacity, fill / stroke properties with dashes, visibility, display,
// mix-blend-mode, isolation, shape-rendering. Anything else is skipped with
// a warning in `Svg_Document.warnings`.

Svg_Node_Kind :: enum u8 {
	Group,
	Shape,
	Text,
	Image,
}

Svg_Node_Flag :: enum u8 {
	// visibility="hidden": the node draws nothing (its children may).
	Hidden,
	// display="none" on an element with an id: kept but not drawn, with its
	// children, unless an override shows it (visible = true).
	Off,
	// The fill / stroke is inherited from the parent node, so an override
	// of the parent's fill / stroke reaches it.
	Fill_Inherited,
	Stroke_Inherited,
	// The visibility is inherited, so an override showing the parent shows
	// it too.
	Visibility_Inherited,
	// isolation="isolate": a group of its own.
	Isolate,
	// shape-rendering="crispEdges" / "optimizeSpeed": no antialiasing.
	Crisp,
	// Clip to `clip_rect` (a nested svg's or symbol's viewport).
	Clip_Rect,
}

Svg_Node_Flags :: bit_set[Svg_Node_Flag;u8]

// One element of the render tree. Node 0 is the root; children follow
// their parent (pre-order). Content of clip paths, masks and patterns hangs
// off detached group nodes (parent -1).
Svg_Node :: struct {
	kind:        Svg_Node_Kind,
	flags:       Svg_Node_Flags,
	blend:       Blend_Mode,
	parent:      i32,
	first_child: i32,
	last_child:  i32,
	next:        i32,
	// Index into `Svg_Document.ids`, or -1.
	id:          i32,
	// Index into shapes / texts / images by kind.
	data:        i32,
	// Into clips / masks / filters, or -1.
	clip:        i32,
	mask:        i32,
	filter:      i32,
	opacity:     f32,
	// Local to parent coordinates.
	transform:   Transform2D,
	// Object bounding box (fill geometry, no stroke) in local coordinates.
	bbox:        Rect,
	// Local coordinates (Clip_Rect).
	clip_rect:   Rect,
}

Svg_Paint_Kind :: enum u8 {
	None,
	Color,
	// `server` indexes `Svg_Document.servers`.
	Server,
}

Svg_Paint :: struct {
	kind:   Svg_Paint_Kind,
	server: i32,
	color:  Color,
}

Svg_Style :: struct {
	fill:           Svg_Paint,
	stroke:         Svg_Paint,
	fill_opacity:   f32,
	stroke_opacity: f32,
	stroke_width:   f32,
	miter_limit:    f32,
	dash_offset:    f32,
	// Into `Svg_Document.dashes`; empty is solid.
	dash:           Range,
	fill_rule:      Fill_Rule,
	cap:            Line_Cap,
	join:           Line_Join,
}

Svg_Shape :: struct {
	// Into `Svg_Document.verbs` / `coords`.
	verbs:       Range,
	coords:      Range,
	style:       Svg_Style,
	// SVG pathLength (dash units), 0 for none.
	path_length: f32,
}

Svg_Text :: struct {
	chunks: Range,
}

// Text starting at an absolute position (the text element, or a tspan
// with x or y), laid out as one line.
Svg_Text_Chunk :: struct {
	x, y:     f32,
	// A missing coordinate continues where the previous chunk ended.
	has_x:    bool,
	has_y:    bool,
	anchor:   Text_Align,
	baseline: Text_Baseline,
	pieces:   Range,
}

Svg_Text_Piece :: struct {
	text:             string,
	// Into `Svg_Document.families`: font-family candidates in order.
	families:         Range,
	size:             f32,
	weight:           int,
	italic:           bool,
	letter_spacing:   f32,
	dx, dy:           f32,
	// Degrees, each glyph about its origin (SVG rotate).
	rotate:           f32,
	style:            Svg_Style,
	fill_inherited:   bool,
	stroke_inherited: bool,
	hidden:           bool,
}

Svg_Image_Fit :: enum u8 {
	Meet,
	Slice,
	None,
}

Svg_Image :: struct {
	x, y, w, h: f32,
	fit:        Svg_Image_Fit,
	// Alignment of the image in its box, 0..1 per axis.
	align:      Vec2,
	bitmap:     i32,
	pixelated:  bool,
}

// Decoded straight-alpha RGBA8, owned by the document.
Svg_Bitmap :: struct {
	pixels:        []u8,
	width, height: u32,
}

Svg_Server_Kind :: enum u8 {
	Linear,
	Radial,
	Pattern,
}

Svg_Server :: struct {
	kind:         Svg_Server_Kind,
	// Coordinates are fractions of the painted element's bounding box.
	bbox_units:   bool,
	// Pattern content in bounding-box fractions (patternContentUnits).
	content_bbox: bool,
	has_view_box: bool,
	spread:       Gradient_Spread,
	// gradientTransform / patternTransform.
	transform:    Transform2D,
	// Linear: x1 y1 x2 y2. Radial: cx cy r fx fy fr.
	v:            [6]f32,
	// Into `Svg_Document.stops`.
	stops:        Range,
	// Pattern tile, viewBox, alignment and content group.
	rect:         Rect,
	view_box:     Rect,
	aspect:       Svg_Aspect,
	content:      i32,
}

// preserveAspectRatio.
Svg_Aspect :: struct {
	align: Vec2,
	slice: bool,
	none:  bool,
}

Svg_Clip :: struct {
	bbox_units: bool,
	transform:  Transform2D,
	// Detached group of the clip's shapes (drawn white, clip-rule fills).
	content:    i32,
	// clip-path on the clipPath element: intersected.
	clip:       i32,
	// The single plain shape the clip is, for a path clip; else -1.
	simple:     i32,
}

Svg_Mask :: struct {
	bbox_units:   bool,
	content_bbox: bool,
	alpha:        bool,
	rect:         Rect,
	content:      i32,
	mask:         i32,
}

Svg_Filter :: struct {
	// Into `filter_prims` / `filter_refs`; lengths in user units (scaled by
	// the bounding box for primitiveUnits="objectBoundingBox").
	primitives: Range,
	refs:       Range,
	// Into `filter_values` and `filter_bitmaps`.
	values:     Range,
	bitmaps:    Range,
	srgb:       bool,
	// Units and rectangle; the bounding box is filled in when drawn.
	region:     Filter_Region,
	prim_bbox:  bool,
	// Some primitive has a subregion (resolved per element when finishing).
	subregions: bool,
}

// A primitive's x / y / width / height as written (`set` bit i: component
// i given), in primitive units; parallel to `filter_prims`.
Svg_Subregion :: struct {
	v:   [4]f32,
	set: u8,
}

Svg_Document :: struct {
	// Size in user units of the outer coordinate system (`svg_draw` draws
	// into `width x height`).
	width, height: f32,
	nodes:         [dynamic]Svg_Node,
	shapes:        [dynamic]Svg_Shape,
	texts:         [dynamic]Svg_Text,
	chunks:        [dynamic]Svg_Text_Chunk,
	pieces:        [dynamic]Svg_Text_Piece,
	families:      [dynamic]string,
	images:        [dynamic]Svg_Image,
	bitmaps:       [dynamic]Svg_Bitmap,
	servers:       [dynamic]Svg_Server,
	stops:         [dynamic]Gradient_Stop,
	clips:         [dynamic]Svg_Clip,
	masks:         [dynamic]Svg_Mask,
	filters:       [dynamic]Svg_Filter,
	filter_prims:  [dynamic]Filter_Primitive,
	filter_refs:   [dynamic]Filter_Ref,
	filter_subs:   [dynamic]Svg_Subregion,
	// Component transfer tables and convolution kernels.
	filter_values: [dynamic]f32,
	// feImage bitmaps (into `bitmaps`).
	filter_bitmaps: [dynamic]i32,
	verbs:         [dynamic]Verb,
	coords:        [dynamic]Vec2,
	dashes:        [dynamic]f32,
	// Element ids; `id_map` finds them.
	ids:           [dynamic]string,
	id_map:        map[string]i32,
	// Unsupported features met while parsing (unique).
	warnings:      [dynamic]string,
	// Some node blends with its backdrop (mix-blend-mode): the layer stack
	// must start with a root layer when drawing onto the screen.
	uses_blend:    bool,
	// Owns the strings.
	arena:         ^virtual.Arena,
	allocator:     mem.Allocator,
}

Svg_Error :: enum u8 {
	None,
	// Not well-formed XML.
	Xml,
	// The root element is not <svg>.
	Not_Svg,
	Out_Of_Memory,
}

Svg_Parse_Options :: struct {
	// Reads the file an <image> href that is not a data: URI names (e.g.
	// relative to the SVG): its bytes (PNG, JPEG, ... or SVG), allocated
	// with `allocator` (scratch, freed after parsing).
	load_file:  proc(user: rawptr, href: string, allocator: mem.Allocator) -> (data: []u8, ok: bool),
	user:       rawptr,
	// Lays out text at parse time for exact text bounding boxes (gradients
	// and effects in objectBoundingBox units); without it they are estimated.
	fonts:      ^Font_Collection,
	// Bounds on the work the file can cause (limits.odin); nil is
	// DEFAULT_LIMITS.
	limits:     ^Limits,
}

svg_destroy :: proc(doc: ^Svg_Document) {
	context.allocator = doc.allocator
	for b in doc.bitmaps {
		delete(b.pixels)
	}
	delete(doc.nodes)
	delete(doc.shapes)
	delete(doc.texts)
	delete(doc.chunks)
	delete(doc.pieces)
	delete(doc.families)
	delete(doc.images)
	delete(doc.bitmaps)
	delete(doc.servers)
	delete(doc.stops)
	delete(doc.clips)
	delete(doc.masks)
	delete(doc.filters)
	delete(doc.filter_prims)
	delete(doc.filter_refs)
	delete(doc.filter_subs)
	delete(doc.filter_values)
	delete(doc.filter_bitmaps)
	delete(doc.verbs)
	delete(doc.coords)
	delete(doc.dashes)
	delete(doc.ids)
	delete(doc.id_map)
	delete(doc.warnings)
	if doc.arena != nil {
		virtual.arena_destroy(doc.arena)
		free(doc.arena)
	}
	doc^ = {}
}

// The node of the element with `id` (the first instance), or -1.
svg_find :: proc(doc: ^Svg_Document, id: string) -> i32 {
	idx, ok := doc.id_map[id]
	if !ok {
		return -1
	}
	for n, i in doc.nodes {
		if n.id == idx {
			return i32(i)
		}
	}
	return -1
}

// The bounding box of the element with `id` in document coordinates (the
// `width x height` space `svg_draw` draws), or false.
svg_element_bbox :: proc(doc: ^Svg_Document, id: string) -> (Rect, bool) {
	i := svg_find(doc, id)
	if i < 0 {
		return {}, false
	}
	b := doc.nodes[i].bbox
	t := TRANSFORM_IDENTITY
	for j := i; j >= 0; j = doc.nodes[j].parent {
		t = transform_multiply(t, doc.nodes[j].transform)
	}
	return svg_rect_transform(b, t), true
}

// Parses SVG markup. Warnings about unsupported features land in
// `doc.warnings`; the document draws what is supported.
svg_parse :: proc(data: []u8, opts: Svg_Parse_Options = {}, allocator := context.allocator) -> (doc: Svg_Document, err: Svg_Error) {
	context.allocator = allocator
	doc.allocator = allocator
	doc.arena = new(virtual.Arena)
	if virtual.arena_init_growing(doc.arena) != nil {
		free(doc.arena)
		doc.arena = nil
		return doc, .Out_Of_Memory
	}

	// The XML tree and the parser's tables live in a scratch arena.
	scratch: virtual.Arena
	if virtual.arena_init_growing(&scratch) != nil {
		return doc, .Out_Of_Memory
	}
	defer virtual.arena_destroy(&scratch)
	tmp := virtual.arena_allocator(&scratch)

	doc.id_map = make(map[string]i32, 64)
	warned := make(map[string]bool, 16, tmp)
	p: Svg_Parser
	if err = svg_parser_open(&p, &doc, data, opts, virtual.arena_allocator(doc.arena), tmp, &warned); err != nil {
		svg_destroy(&doc)
		return
	}
	defer path_destroy(&p.path)
	budget: Budget
	budget_init(&budget, opts.limits)
	p.budget = &budget

	// The root viewport.
	root := &p.x.elements[0]
	root_style := svg_initial_style()
	st := svg_compute_style(&p, 0, &root_style)
	w, h, vb, has_vb := svg_root_size(&p, &st)
	doc.width, doc.height = w, h
	append(&p.viewports, Vec2{vb.w, vb.h} if has_vb else Vec2{w, h})
	root_xform := TRANSFORM_IDENTITY
	if has_vb {
		root_xform = svg_view_box_transform(vb, svg_aspect(root), w, h)
	}
	n := svg_new_node(&p, .Group, -1)
	doc.nodes[n].transform = root_xform
	svg_node_effects(&p, n, 0, &st, true)
	st.fill_decl, st.stroke_decl, st.visible_decl = false, false, false
	svg_convert_children(&p, 0, &st, n)

	svg_finish(&p)
	budget_warn(&budget, &doc.warnings, p.sa)
	return doc, .None
}

// Text whitespace is significant in SVG, but the XML reader trims text
// bodies and drops whitespace-only ones: in the copy it parses, whitespace
// in the content of <text> elements becomes SVG_SPACE (a private-use
// character), turned back into spaces by the text whitespace handling.
@(private)
SVG_SPACE :: "\uE000"

@(private)
svg_prepare_source :: proc(data: []u8, allocator: mem.Allocator) -> []u8 {
	if !strings.contains(string(data), "<text") && !strings.contains(string(data), ":text") {
		out := make([]u8, len(data), allocator)
		copy(out, data)
		return out
	}
	out := make([dynamic]u8, 0, len(data) + len(data) / 8, allocator)
	depth := 0 // open <text> elements
	in_tag := false
	quote: u8 = 0
	// Bytes since `run` are copied as they are when the next substitution
	// (or the end) comes.
	run := 0
	for i := 0; i < len(data); i += 1 {
		ch := data[i]
		if in_tag {
			if quote != 0 {
				if ch == quote {
					quote = 0
				}
			} else if ch == '"' || ch == '\'' {
				quote = ch
			} else if ch == '>' {
				in_tag = false
			}
			continue
		}
		if ch == '<' {
			rest := string(data[i:])
			if strings.has_prefix(rest, "<!--") || strings.has_prefix(rest, "<![CDATA[") {
				end_mark := "-->" if rest[1] == '!' && rest[2] == '-' else "]]>"
				end := strings.index(rest, end_mark)
				i += (len(rest) if end < 0 else end + len(end_mark)) - 1
				continue
			}
			// <text ...> opens, </text> closes (with or without a prefix).
			j := i + 1
			closing := j < len(data) && data[j] == '/'
			if closing {
				j += 1
			}
			k := j
			for k < len(data) && data[k] != ' ' && data[k] != '>' && data[k] != '/' && data[k] != '\t' && data[k] != '\n' && data[k] != '\r' {
				k += 1
			}
			if svg_tag(string(data[j:k])) == "text" {
				if closing {
					depth = max(depth - 1, 0)
				} else {
					// <text/> has no content.
					e := strings.index_byte(rest, '>')
					if !(e > 0 && rest[e - 1] == '/') {
						depth += 1
					}
				}
			}
			in_tag = true
			continue
		}
		if depth > 0 && (ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r') {
			append(&out, ..data[run:i])
			append(&out, SVG_SPACE)
			run = i + 1
		}
	}
	append(&out, ..data[run:])
	return out[:]
}

// Parses `data` into `p` (reading ids and stylesheets) for converting into
// `doc`; nested SVG images open their own parser on the same document.
@(private)
svg_parser_open :: proc(p: ^Svg_Parser, doc: ^Svg_Document, data: []u8, opts: Svg_Parse_Options, sa, tmp: mem.Allocator, warned: ^map[string]bool) -> Svg_Error {
	silent :: proc(pos: xml.Pos, msg: string, args: ..any) {}
	src := svg_prepare_source(data, tmp)
	x, xerr := xml.parse_bytes(src, {flags = {.Ignore_Unsupported, .Unbox_CDATA, .Decode_SGML_Entities, .Input_May_Be_Modified}}, "", silent, tmp)
	if xerr != .None || x == nil || x.element_count == 0 {
		return .Xml
	}
	if svg_tag(x.elements[0].ident) != "svg" {
		return .Not_Svg
	}
	p^ = {
		doc    = doc,
		x      = x,
		opts   = opts,
		sa     = sa,
		tmp    = tmp,
		warned = warned,
	}
	p.by_id = make(map[string]u32, 64, tmp)
	for &d in p.defs {
		d = make([]i32, len(x.elements), tmp)
		slice.fill(d, SVG_DEF_UNSEEN)
	}
	p.bitmap_of = make(map[string]i32, 4, tmp)
	p.use_stack = make([dynamic]u32, tmp)
	p.viewports = make([dynamic]Vec2, tmp)
	p.sheet.rules = make([dynamic]Css_Rule, tmp)
	p.sheet.decls = make([dynamic]Css_Decl, tmp)
	// Ids and stylesheets first: references may point forward.
	for i in 0 ..< int(x.element_count) {
		e := &x.elements[i]
		if e.kind != .Element {
			continue
		}
		if id, ok := svg_attr(e, "id"); ok && id != "" {
			if _, dup := p.by_id[id]; !dup {
				p.by_id[id] = u32(i)
			}
		}
		if svg_tag(e.ident) == "style" {
			if t, ok := svg_attr(e, "type"); ok && t != "" && t != "text/css" {
				continue
			}
			for v in e.value {
				if s, is_str := v.(string); is_str {
					css_parse_sheet(&p.sheet, s)
				}
			}
		}
	}
	if p.sheet.skipped > 0 {
		svg_warn(p, "unsupported CSS selectors or at-rules are ignored")
	}
	css_sort_rules(&p.sheet)
	return nil
}

// The root svg's size (missing or percentage sizes come from the viewBox,
// 100 x 100 without one) and viewBox.
@(private)
svg_root_size :: proc(p: ^Svg_Parser, st: ^Svg_Computed) -> (w, h: f32, vb: Rect, has_vb: bool) {
	root := &p.x.elements[0]
	vb, has_vb = svg_view_box(root)
	w = svg_attr_length(p, root, "width", 0, -1, st.font_size)
	h = svg_attr_length(p, root, "height", 1, -1, st.font_size)
	ws, _ := svg_attr(root, "width")
	hs, _ := svg_attr(root, "height")
	if has_vb && (vb.w <= 0 || vb.h <= 0) {
		has_vb = false
	}
	w_auto := w <= 0 || strings.has_suffix(ws, "%")
	h_auto := h <= 0 || strings.has_suffix(hs, "%")
	switch {
	case w_auto && h_auto:
		w, h = 100, 100
		if has_vb {
			w, h = vb.w, vb.h
		}
	case w_auto:
		// One side given: the other follows the viewBox's aspect.
		w = h * vb.w / vb.h if has_vb else 100
	case h_auto:
		h = w * vb.h / vb.w if has_vb else 100
	}
	return
}

// ---- parser state --------------------------------------------------------------

@(private)
Svg_Parser :: struct {
	doc:         ^Svg_Document,
	// The element being converted has display="none" and an id: its node
	// is marked Off (svg_node_effects).
	pending_off: bool,
	x:           ^xml.Document,
	opts:        Svg_Parse_Options,
	// Allocates the document's strings.
	sa:          mem.Allocator,
	tmp:         mem.Allocator,
	by_id:       map[string]u32,
	sheet:       Css_Sheet,
	// Converted definitions by kind and XML element (svg_def_seen).
	defs:        [Svg_Def][]i32,
	bitmap_of:   map[string]i32,
	// Shared with nested SVG images' parsers.
	warned:      ^map[string]bool,
	use_stack:   [dynamic]u32,
	// SVG images nested inside this one.
	image_depth: int,
	// Width and height that percentages refer to.
	viewports:   [dynamic]Vec2,
	path:        Path,
	// Converting a clipPath's content: shapes fill white with clip-rule.
	in_clip:     bool,
	// Shared with nested SVG images' parsers.
	budget:      ^Budget,
	// Elements being converted, outermost first.
	depth:       int,
}

// The computed style of an element (CSS cascade and inheritance resolved).
@(private)
Svg_Computed :: struct {
	// Inherited.
	fill:             Svg_Paint,
	stroke:           Svg_Paint,
	fill_opacity:     f32,
	stroke_opacity:   f32,
	fill_rule:        Fill_Rule,
	clip_rule:        Fill_Rule,
	stroke_width:     f32,
	miter_limit:      f32,
	dash_offset:      f32,
	dash:             Range,
	cap:              Line_Cap,
	join:             Line_Join,
	visible:          bool,
	color:            Color,
	families:         Range,
	font_size:        f32,
	font_weight:      int,
	italic:           bool,
	anchor:           Text_Align,
	baseline:         Text_Baseline,
	letter_spacing:   f32,
	crisp:            bool,
	srgb_filters:     bool,
	preserve_space:   bool,
	// fill / stroke declared on this element or an elided group since the
	// last node (so the node's own value, not the parent node's).
	fill_decl:        bool,
	stroke_decl:      bool,
	visible_decl:     bool,
	// fill / stroke is currentColor: it follows `color` where used.
	fill_current:     bool,
	stroke_current:   bool,
	// Not inherited.
	opacity:          f32,
	display_none:     bool,
	clip_path:        string,
	mask:             string,
	filter:           string,
	blend:            Blend_Mode,
	isolate:          bool,
	stop_color:       Color,
	stop_opacity:     f32,
	flood_color:      Color,
	lighting_color:   Color,
	flood_opacity:    f32,
	mask_alpha:       bool,
	overflow_visible: bool,
	css_transform:    string,
	baseline_set:     bool,
}

@(private)
svg_initial_style :: proc() -> Svg_Computed {
	return {
		fill = {kind = .Color, color = BLACK},
		fill_opacity = 1,
		stroke_opacity = 1,
		stroke_width = 1,
		miter_limit = 4,
		visible = true,
		color = BLACK,
		font_size = 16,
		font_weight = 400,
		opacity = 1,
		stop_color = BLACK,
		stop_opacity = 1,
		flood_color = BLACK,
		lighting_color = WHITE,
		flood_opacity = 1,
		cap = .Butt,
		join = .Miter,
	}
}

@(private)
svg_warn :: proc(p: ^Svg_Parser, format: string, args: ..any) {
	msg := fmt.tprintf(format, ..args)
	if msg in p.warned {
		return
	}
	owned := strings.clone(msg, p.sa)
	p.warned[owned] = true
	append(&p.doc.warnings, owned)
}

@(private)
svg_tag :: proc "contextless" (ident: string) -> string {
	for i in 0 ..< len(ident) {
		if ident[i] == ':' {
			return ident[i + 1:]
		}
	}
	return ident
}

@(private)
svg_attr :: proc(e: ^xml.Element, name: string) -> (string, bool) {
	for a in e.attribs {
		if a.key == name {
			return a.val, true
		}
	}
	return "", false
}

@(private)
svg_href :: proc(e: ^xml.Element) -> (string, bool) {
	if v, ok := svg_attr(e, "href"); ok {
		return v, true
	}
	return svg_attr(e, "xlink:href")
}

// The element an `#id` / `url(#id)` reference names.
@(private)
svg_ref :: proc(p: ^Svg_Parser, ref: string) -> (u32, bool) {
	r := strings.trim_space(ref)
	if strings.has_prefix(r, "url(") {
		end := strings.index_byte(r, ')')
		if end < 0 {
			return 0, false
		}
		r = strings.trim_space(r[4:end])
		r = strings.trim(r, "'\"")
	}
	if !strings.has_prefix(r, "#") {
		return 0, false
	}
	return p.by_id[r[1:]]
}

@(private)
svg_viewport :: proc(p: ^Svg_Parser) -> Vec2 {
	if len(p.viewports) == 0 {
		// The root's own attributes, before its size is known.
		return {100, 100}
	}
	return p.viewports[len(p.viewports) - 1]
}

// A length attribute in user units. `axis`: 0 = x (percent of the viewport
// width), 1 = y, 2 = the normalized diagonal.
@(private)
svg_attr_length :: proc(p: ^Svg_Parser, e: ^xml.Element, name: string, axis: int, def: f32, font_size: f32) -> f32 {
	s, ok := svg_attr(e, name)
	if !ok {
		return def
	}
	l, lok := svg_parse_length(strings.trim_space(s))
	if !lok {
		return def
	}
	return svg_length_px(l, svg_percent_base(p, axis), font_size)
}

@(private)
svg_percent_base :: proc(p: ^Svg_Parser, axis: int) -> f32 {
	vp := svg_viewport(p)
	switch axis {
	case 0:
		return vp.x
	case 1:
		return vp.y
	}
	return math.sqrt((vp.x * vp.x + vp.y * vp.y) / 2)
}

@(private)
svg_view_box :: proc(e: ^xml.Element) -> (r: Rect, ok: bool) {
	s := svg_attr(e, "viewBox") or_return
	sc := Svg_Scanner{s = s}
	v: [4]f32
	for i in 0 ..< 4 {
		v[i] = svg_scan_number(&sc) or_return
	}
	return {v[0], v[1], v[2], v[3]}, true
}

@(private)
svg_aspect :: proc(e: ^xml.Element) -> (a: Svg_Aspect) {
	a.align = {0.5, 0.5}
	s, ok := svg_attr(e, "preserveAspectRatio")
	if !ok {
		return
	}
	rest := s
	for f in strings.fields_iterator(&rest) {
		switch f {
		case "defer":
		case "none":
			a.none = true
		case "meet":
		case "slice":
			a.slice = true
		case:
			if len(f) == 8 {
				axis :: proc(s: string) -> f32 {
					switch s {
					case "Min":
						return 0
					case "Max":
						return 1
					}
					return 0.5
				}
				a.align = {axis(f[1:4]), axis(f[5:8])}
			}
		}
	}
	return
}

// Maps viewBox `vb` into a `w x h` viewport.
svg_view_box_transform :: proc "contextless" (vb: Rect, a: Svg_Aspect, w, h: f32) -> Transform2D {
	sx := w / vb.w
	sy := h / vb.h
	if !a.none {
		s := max(sx, sy) if a.slice else min(sx, sy)
		sx, sy = s, s
	}
	tx := -vb.x * sx + (w - vb.w * sx) * (0 if a.none else a.align.x)
	ty := -vb.y * sy + (h - vb.h * sy) * (0 if a.none else a.align.y)
	return {sx, 0, 0, sy, tx, ty}
}

@(private)
svg_rect_transform :: proc "contextless" (r: Rect, t: Transform2D) -> Rect {
	if r.w < 0 {
		return r
	}
	lo := Vec2{1e30, 1e30}
	hi := Vec2{-1e30, -1e30}
	for c in ([4]Vec2{{r.x, r.y}, {r.x + r.w, r.y}, {r.x, r.y + r.h}, {r.x + r.w, r.y + r.h}}) {
		q := transform_point(t, c.x, c.y)
		lo = {min(lo.x, q.x), min(lo.y, q.y)}
		hi = {max(hi.x, q.x), max(hi.y, q.y)}
	}
	return {lo.x, lo.y, hi.x - lo.x, hi.y - lo.y}
}

@(private)
svg_invertible :: proc "contextless" (t: Transform2D) -> bool {
	return abs(t[0] * t[3] - t[1] * t[2]) > 1e-12
}

// An empty bounding box (union identity).
@(private)
SVG_EMPTY_BOX :: Rect{0, 0, -1, -1}

@(private)
svg_box_union :: proc "contextless" (a, b: Rect) -> Rect {
	if a.w < 0 {
		return b
	}
	if b.w < 0 {
		return a
	}
	x0, y0 := min(a.x, b.x), min(a.y, b.y)
	x1, y1 := max(a.x + a.w, b.x + b.w), max(a.y + a.h, b.y + b.h)
	return {x0, y0, x1 - x0, y1 - y0}
}

// ---- style --------------------------------------------------------------------

// Gathers the declarations that apply to element `el`: presentation
// attributes, then stylesheet rules by specificity, then `style`.
@(private)
svg_collect_decls :: proc(p: ^Svg_Parser, el: u32, d: ^Svg_Decls) {
	e := &p.x.elements[el]
	style := ""
	for a in e.attribs {
		switch a.key {
		case "style":
			style = a.val
		case "transform", "mix-blend-mode", "isolation":
		// The element's transform, not the CSS property; blending and
		// isolation are CSS only.
		case:
			if prop, ok := svg_prop_from_name(a.key); ok {
				d[prop] = strings.trim_space(a.val)
			}
		}
	}
	important := false
	if len(p.sheet.rules) > 0 {
		for &r in p.sheet.rules {
			if css_matches(&r.selector, p.x, el, p.budget) {
				for dc in p.sheet.decls[r.decls.start:][:r.decls.count] {
					if dc.important {
						important = true
					} else {
						d[dc.prop] = dc.value
					}
				}
			}
		}
	}
	if style != "" {
		svg_apply_style_attr(d, style)
	}
	if important {
		// !important rules beat the style attribute.
		for &r in p.sheet.rules {
			if css_matches(&r.selector, p.x, el, p.budget) {
				for dc in p.sheet.decls[r.decls.start:][:r.decls.count] {
					if dc.important {
						d[dc.prop] = dc.value
					}
				}
			}
		}
	}
}

@(private)
svg_compute_style :: proc(p: ^Svg_Parser, el: u32, parent: ^Svg_Computed) -> Svg_Computed {
	st := parent^
	// Non-inherited properties start from their initial values.
	initial := svg_initial_style()
	for &info in svg_props {
		if !info.inherited {
			info.copy(&st, &initial)
		}
	}
	st.baseline_set = false
	e := &p.x.elements[el]
	if sp, ok := svg_attr(e, "xml:space"); ok {
		st.preserve_space = sp == "preserve"
	}

	d: Svg_Decls
	svg_collect_decls(p, el, &d)
	declare :: proc(p: ^Svg_Parser, st, parent: ^Svg_Computed, prop: Svg_Prop, v: string) {
		switch v {
		case "":
		case "inherit":
			svg_props[prop].copy(st, parent)
		case:
			svg_props[prop].apply(p, st, parent, v)
		}
	}
	// `color` and `font-size` first: currentColor and em units use them.
	declare(p, &st, parent, .Color, d[.Color])
	declare(p, &st, parent, .Font_Size, d[.Font_Size])
	for v, prop in d {
		if prop != .Color && prop != .Font_Size {
			declare(p, &st, parent, prop, v)
		}
	}
	if st.fill_current {
		st.fill = {kind = .Color, color = st.color}
	}
	if st.stroke_current {
		st.stroke = {kind = .Color, color = st.color}
	}
	return st
}

// What the cascade does with one property: its CSS name, whether it
// inherits, how a declared value applies to the computed style, and how it
// copies the property's fields from another style (the parent's for
// `inherit`, the initial style's to reset a property that doesn't inherit).
@(private)
Svg_Prop_Info :: struct {
	name:      string,
	inherited: bool,
	apply:     proc(p: ^Svg_Parser, st, parent: ^Svg_Computed, v: string),
	copy:      proc(st, from: ^Svg_Computed),
}

@(private, rodata)
svg_props := [Svg_Prop]Svg_Prop_Info {
	.Fill = {"fill", true, proc(p: ^Svg_Parser, st, parent: ^Svg_Computed, v: string) {
			st.fill = svg_parse_paint(p, v, st, parent.fill)
			st.fill_decl = true
			st.fill_current = v == "currentColor" || v == "currentcolor"
		}, proc(st, from: ^Svg_Computed) {st.fill, st.fill_current = from.fill, from.fill_current}},
	.Fill_Opacity = {"fill-opacity", true, proc(p: ^Svg_Parser, st, parent: ^Svg_Computed, v: string) {
			st.fill_opacity = svg_opacity(v)
		}, proc(st, from: ^Svg_Computed) {st.fill_opacity = from.fill_opacity}},
	.Fill_Rule = {"fill-rule", true, proc(p: ^Svg_Parser, st, parent: ^Svg_Computed, v: string) {
			st.fill_rule = .Even_Odd if v == "evenodd" else .Non_Zero
		}, proc(st, from: ^Svg_Computed) {st.fill_rule = from.fill_rule}},
	.Stroke = {"stroke", true, proc(p: ^Svg_Parser, st, parent: ^Svg_Computed, v: string) {
			st.stroke = svg_parse_paint(p, v, st, parent.stroke)
			st.stroke_decl = true
			st.stroke_current = v == "currentColor" || v == "currentcolor"
		}, proc(st, from: ^Svg_Computed) {st.stroke, st.stroke_current = from.stroke, from.stroke_current}},
	.Stroke_Opacity = {"stroke-opacity", true, proc(p: ^Svg_Parser, st, parent: ^Svg_Computed, v: string) {
			st.stroke_opacity = svg_opacity(v)
		}, proc(st, from: ^Svg_Computed) {st.stroke_opacity = from.stroke_opacity}},
	.Stroke_Width = {"stroke-width", true, proc(p: ^Svg_Parser, st, parent: ^Svg_Computed, v: string) {
			if l, ok := svg_parse_length(v); ok {
				if w := svg_length_px(l, svg_percent_base(p, 2), st.font_size); w >= 0 {
					st.stroke_width = w
				}
			}
		}, proc(st, from: ^Svg_Computed) {st.stroke_width = from.stroke_width}},
	.Stroke_Linecap = {"stroke-linecap", true, proc(p: ^Svg_Parser, st, parent: ^Svg_Computed, v: string) {
			switch v {
			case "butt":
				st.cap = .Butt
			case "round":
				st.cap = .Round
			case "square":
				st.cap = .Square
			}
		}, proc(st, from: ^Svg_Computed) {st.cap = from.cap}},
	.Stroke_Linejoin = {"stroke-linejoin", true, proc(p: ^Svg_Parser, st, parent: ^Svg_Computed, v: string) {
			switch v {
			case "miter", "miter-clip", "arcs":
				st.join = .Miter
			case "round":
				st.join = .Round
			case "bevel":
				st.join = .Bevel
			}
		}, proc(st, from: ^Svg_Computed) {st.join = from.join}},
	.Stroke_Miterlimit = {"stroke-miterlimit", true, proc(p: ^Svg_Parser, st, parent: ^Svg_Computed, v: string) {
			if m, ok := svg_parse_number(v); ok && m >= 1 {
				st.miter_limit = m
			}
		}, proc(st, from: ^Svg_Computed) {st.miter_limit = from.miter_limit}},
	.Stroke_Dasharray = {"stroke-dasharray", true, proc(p: ^Svg_Parser, st, parent: ^Svg_Computed, v: string) {
			st.dash = svg_parse_dash(p, v, st.font_size)
		}, proc(st, from: ^Svg_Computed) {st.dash = from.dash}},
	.Stroke_Dashoffset = {"stroke-dashoffset", true, proc(p: ^Svg_Parser, st, parent: ^Svg_Computed, v: string) {
			if l, ok := svg_parse_length(v); ok {
				st.dash_offset = svg_length_px(l, svg_percent_base(p, 2), st.font_size)
			}
		}, proc(st, from: ^Svg_Computed) {st.dash_offset = from.dash_offset}},
	.Opacity = {"opacity", false, proc(p: ^Svg_Parser, st, parent: ^Svg_Computed, v: string) {
			st.opacity = svg_opacity(v)
		}, proc(st, from: ^Svg_Computed) {st.opacity = from.opacity}},
	.Visibility = {"visibility", true, proc(p: ^Svg_Parser, st, parent: ^Svg_Computed, v: string) {
			st.visible = v == "visible"
			st.visible_decl = true
		}, proc(st, from: ^Svg_Computed) {st.visible = from.visible}},
	.Display = {"display", false, proc(p: ^Svg_Parser, st, parent: ^Svg_Computed, v: string) {
			st.display_none = v == "none"
		}, proc(st, from: ^Svg_Computed) {st.display_none = from.display_none}},
	.Color = {"color", true, proc(p: ^Svg_Parser, st, parent: ^Svg_Computed, v: string) {
			// currentColor: the inherited colour, already there.
			if v != "currentColor" {
				if c, ok := css_color_parse(v); ok {
					st.color = c
				}
			}
		}, proc(st, from: ^Svg_Computed) {st.color = from.color}},
	.Font_Family = {"font-family", true, proc(p: ^Svg_Parser, st, parent: ^Svg_Computed, v: string) {
			st.families = svg_parse_families(p, v)
		}, proc(st, from: ^Svg_Computed) {st.families = from.families}},
	.Font_Size = {"font-size", true, proc(p: ^Svg_Parser, st, parent: ^Svg_Computed, v: string) {
			st.font_size = svg_font_size(v, parent.font_size)
		}, proc(st, from: ^Svg_Computed) {st.font_size = from.font_size}},
	.Font_Weight = {"font-weight", true, proc(p: ^Svg_Parser, st, parent: ^Svg_Computed, v: string) {
			st.font_weight = svg_font_weight(v, parent.font_weight)
		}, proc(st, from: ^Svg_Computed) {st.font_weight = from.font_weight}},
	.Font_Style = {"font-style", true, proc(p: ^Svg_Parser, st, parent: ^Svg_Computed, v: string) {
			st.italic = v == "italic" || v == "oblique"
		}, proc(st, from: ^Svg_Computed) {st.italic = from.italic}},
	.Text_Anchor = {"text-anchor", true, proc(p: ^Svg_Parser, st, parent: ^Svg_Computed, v: string) {
			switch v {
			case "start":
				st.anchor = .Left
			case "middle":
				st.anchor = .Center
			case "end":
				st.anchor = .Right
			}
		}, proc(st, from: ^Svg_Computed) {st.anchor = from.anchor}},
	.Dominant_Baseline = {"dominant-baseline", true, svg_apply_baseline, svg_copy_baseline},
	.Alignment_Baseline = {"alignment-baseline", true, svg_apply_baseline, svg_copy_baseline},
	.Letter_Spacing = {"letter-spacing", true, proc(p: ^Svg_Parser, st, parent: ^Svg_Computed, v: string) {
			if v == "normal" {
				st.letter_spacing = 0
			} else if l, ok := svg_parse_length(v); ok {
				st.letter_spacing = svg_length_px(l, svg_percent_base(p, 0), st.font_size)
			}
		}, proc(st, from: ^Svg_Computed) {st.letter_spacing = from.letter_spacing}},
	.Clip_Path = {"clip-path", false, proc(p: ^Svg_Parser, st, parent: ^Svg_Computed, v: string) {
			st.clip_path = "" if v == "none" else v
		}, proc(st, from: ^Svg_Computed) {st.clip_path = from.clip_path}},
	.Clip_Rule = {"clip-rule", true, proc(p: ^Svg_Parser, st, parent: ^Svg_Computed, v: string) {
			st.clip_rule = .Even_Odd if v == "evenodd" else .Non_Zero
		}, proc(st, from: ^Svg_Computed) {st.clip_rule = from.clip_rule}},
	.Mask = {"mask", false, proc(p: ^Svg_Parser, st, parent: ^Svg_Computed, v: string) {
			st.mask = "" if v == "none" else v
		}, proc(st, from: ^Svg_Computed) {st.mask = from.mask}},
	.Mask_Type = {"mask-type", false, proc(p: ^Svg_Parser, st, parent: ^Svg_Computed, v: string) {
			st.mask_alpha = v == "alpha"
		}, proc(st, from: ^Svg_Computed) {st.mask_alpha = from.mask_alpha}},
	.Filter = {"filter", false, proc(p: ^Svg_Parser, st, parent: ^Svg_Computed, v: string) {
			st.filter = "" if v == "none" else v
		}, proc(st, from: ^Svg_Computed) {st.filter = from.filter}},
	.Mix_Blend_Mode = {"mix-blend-mode", false, proc(p: ^Svg_Parser, st, parent: ^Svg_Computed, v: string) {
			st.blend = svg_blend_mode(v)
		}, proc(st, from: ^Svg_Computed) {st.blend = from.blend}},
	.Isolation = {"isolation", false, proc(p: ^Svg_Parser, st, parent: ^Svg_Computed, v: string) {
			st.isolate = v == "isolate"
		}, proc(st, from: ^Svg_Computed) {st.isolate = from.isolate}},
	.Stop_Color = {"stop-color", false, proc(p: ^Svg_Parser, st, parent: ^Svg_Computed, v: string) {
			st.stop_color = svg_parse_color(v, st.color)
		}, proc(st, from: ^Svg_Computed) {st.stop_color = from.stop_color}},
	.Stop_Opacity = {"stop-opacity", false, proc(p: ^Svg_Parser, st, parent: ^Svg_Computed, v: string) {
			st.stop_opacity = svg_opacity(v)
		}, proc(st, from: ^Svg_Computed) {st.stop_opacity = from.stop_opacity}},
	.Flood_Color = {"flood-color", false, proc(p: ^Svg_Parser, st, parent: ^Svg_Computed, v: string) {
			st.flood_color = svg_parse_color(v, st.color)
		}, proc(st, from: ^Svg_Computed) {st.flood_color = from.flood_color}},
	.Flood_Opacity = {"flood-opacity", false, proc(p: ^Svg_Parser, st, parent: ^Svg_Computed, v: string) {
			st.flood_opacity = svg_opacity(v)
		}, proc(st, from: ^Svg_Computed) {st.flood_opacity = from.flood_opacity}},
	.Lighting_Color = {"lighting-color", false, proc(p: ^Svg_Parser, st, parent: ^Svg_Computed, v: string) {
			if v == "currentColor" || v == "currentcolor" {
				st.lighting_color = st.color
			} else if lc, ok := css_color_parse(v); ok {
				st.lighting_color = lc
			} else {
				st.lighting_color = WHITE
			}
			st.lighting_color.a = 1
		}, proc(st, from: ^Svg_Computed) {st.lighting_color = from.lighting_color}},
	.Shape_Rendering = {"shape-rendering", true, proc(p: ^Svg_Parser, st, parent: ^Svg_Computed, v: string) {
			st.crisp = v == "crispEdges" || v == "optimizeSpeed"
		}, proc(st, from: ^Svg_Computed) {st.crisp = from.crisp}},
	.Overflow = {"overflow", false, proc(p: ^Svg_Parser, st, parent: ^Svg_Computed, v: string) {
			st.overflow_visible = v == "visible" || v == "auto"
		}, proc(st, from: ^Svg_Computed) {st.overflow_visible = from.overflow_visible}},
	.Color_Interpolation_Filters = {"color-interpolation-filters", true, proc(p: ^Svg_Parser, st, parent: ^Svg_Computed, v: string) {
			st.srgb_filters = v == "sRGB"
		}, proc(st, from: ^Svg_Computed) {st.srgb_filters = from.srgb_filters}},
	.Transform = {"transform", false, proc(p: ^Svg_Parser, st, parent: ^Svg_Computed, v: string) {
			st.css_transform = v
		}, proc(st, from: ^Svg_Computed) {st.css_transform = from.css_transform}},
	.Marker = {"marker", true, proc(p: ^Svg_Parser, st, parent: ^Svg_Computed, v: string) {
			if v != "none" {
				svg_warn(p, "markers are not supported")
			}
		}, svg_copy_nothing},
	.Text_Decoration = {"text-decoration", false, proc(p: ^Svg_Parser, st, parent: ^Svg_Computed, v: string) {
			if v != "none" {
				svg_warn(p, "text-decoration is not supported")
			}
		}, svg_copy_nothing},
	.Paint_Order = {"paint-order", true, proc(p: ^Svg_Parser, st, parent: ^Svg_Computed, v: string) {
			if v != "normal" && v != "fill" && v != "fill stroke" && v != "fill stroke markers" {
				svg_warn(p, "paint-order is not supported")
			}
		}, svg_copy_nothing},
}

@(private)
svg_apply_baseline :: proc(p: ^Svg_Parser, st, parent: ^Svg_Computed, v: string) {
	st.baseline_set = true
	switch v {
	case "middle":
		st.baseline = .Middle
	case "central":
		st.baseline = .Central
	case "hanging":
		st.baseline = .Hanging
	case "text-before-edge", "text-top":
		st.baseline = .Top
	case "text-after-edge", "text-bottom", "ideographic":
		st.baseline = .Bottom
	case "auto", "alphabetic", "baseline":
		st.baseline = .Alphabetic
	case:
		svg_warn(p, "dominant-baseline=%q is not supported", v)
	}
}

@(private)
svg_copy_baseline :: proc(st, from: ^Svg_Computed) {
	st.baseline = from.baseline
}

// Properties ovg only warns about hold nothing to copy.
@(private)
svg_copy_nothing :: proc(st, from: ^Svg_Computed) {}

@(private)
svg_opacity :: proc(v: string) -> f32 {
	if l, ok := svg_parse_length(v); ok && (l.unit == .None || l.unit == .Percent) {
		x := l.v / 100 if l.unit == .Percent else l.v
		return clamp(x, 0, 1)
	}
	return 1
}

@(private)
svg_font_size :: proc(v: string, parent: f32) -> f32 {
	switch v {
	case "xx-small":
		return 9
	case "x-small":
		return 10
	case "small":
		return 13
	case "medium":
		return 16
	case "large":
		return 18
	case "x-large":
		return 24
	case "xx-large":
		return 32
	case "larger":
		return parent * 1.2
	case "smaller":
		return parent / 1.2
	}
	if l, ok := svg_parse_length(v); ok {
		s := svg_length_px(l, parent, parent)
		if s >= 0 {
			return s
		}
	}
	return parent
}

@(private)
svg_font_weight :: proc(v: string, parent: int) -> int {
	switch v {
	case "normal":
		return 400
	case "bold":
		return 700
	case "bolder":
		return min(parent + 300, 900) if parent < 600 else 900
	case "lighter":
		return max(parent - 300, 100) if parent > 400 else 100
	}
	if n, ok := svg_parse_number(v); ok {
		return clamp(int(n), 1, 1000)
	}
	return parent
}

@(private)
svg_parse_families :: proc(p: ^Svg_Parser, v: string) -> Range {
	start := len(p.doc.families)
	rest := v
	for f in strings.split_iterator(&rest, ",") {
		name := strings.trim(strings.trim_space(f), "'\"")
		if name != "" {
			append(&p.doc.families, strings.clone(name, p.sa))
		}
	}
	return {u32(start), u32(len(p.doc.families) - start)}
}

@(private)
svg_parse_dash :: proc(p: ^Svg_Parser, v: string, font_size: f32) -> Range {
	if v == "none" {
		return {}
	}
	start := len(p.doc.dashes)
	sc := Svg_Scanner{s = v}
	sum: f32
	for {
		svg_skip_ws(&sc)
		if sc.pos >= len(sc.s) {
			break
		}
		l, ok := svg_scan_length(&sc)
		if !ok {
			resize(&p.doc.dashes, start)
			return {}
		}
		d := svg_length_px(l, svg_percent_base(p, 2), font_size)
		if d < 0 {
			resize(&p.doc.dashes, start)
			return {}
		}
		sum += d
		append(&p.doc.dashes, d)
	}
	n := len(p.doc.dashes) - start
	if n == 0 || sum <= 0 {
		resize(&p.doc.dashes, start)
		return {}
	}
	if n % 2 == 1 {
		for i in 0 ..< n {
			append(&p.doc.dashes, p.doc.dashes[start + i])
		}
	}
	return {u32(start), u32(len(p.doc.dashes) - start)}
}

@(private)
svg_blend_mode :: proc(v: string) -> Blend_Mode {
	switch v {
	case "multiply":
		return .Multiply
	case "screen":
		return .Screen
	case "overlay":
		return .Overlay
	case "darken":
		return .Darken
	case "lighten":
		return .Lighten
	case "color-dodge":
		return .Color_Dodge
	case "color-burn":
		return .Color_Burn
	case "hard-light":
		return .Hard_Light
	case "soft-light":
		return .Soft_Light
	case "difference":
		return .Difference
	case "exclusion":
		return .Exclusion
	case "hue":
		return .Hue
	case "saturation":
		return .Saturation
	case "color":
		return .Color
	case "luminosity":
		return .Luminosity
	}
	return .Normal
}

// A color value; `currentColor` is `current`, anything unparsable black.
@(private)
svg_parse_color :: proc(v: string, current: Color) -> Color {
	if v == "currentColor" || v == "currentcolor" {
		return current
	}
	c, _ := css_color_parse(v)
	return c
}

@(private)
svg_parse_paint :: proc(p: ^Svg_Parser, v: string, st: ^Svg_Computed, parent: Svg_Paint) -> Svg_Paint {
	switch v {
	case "none":
		return {}
	case "currentColor", "currentcolor":
		return {kind = .Color, color = st.color}
	case "context-fill", "context-stroke":
		svg_warn(p, "%s is not supported", v)
		return {}
	}
	if strings.has_prefix(v, "url(") {
		end := strings.index_byte(v, ')')
		fallback := strings.trim_space(v[end + 1:]) if end >= 0 else ""
		if el, ok := svg_ref(p, v); ok {
			paint := svg_server_paint(p, el)
			if paint.kind != .None || fallback == "" {
				return paint
			}
		}
		if fallback != "" {
			return svg_parse_paint(p, fallback, st, parent)
		}
		return {}
	}
	if c, ok := css_color_parse(v); ok {
		return {kind = .Color, color = c}
	}
	// An invalid paint is ignored (the inherited value stays).
	return parent
}

// ---- tree construction -------------------------------------------------------------

@(private)
svg_new_node :: proc(p: ^Svg_Parser, kind: Svg_Node_Kind, parent: i32) -> i32 {
	doc := p.doc
	idx := i32(len(doc.nodes))
	append(
		&doc.nodes,
		Svg_Node {
			kind = kind,
			parent = parent,
			first_child = -1,
			last_child = -1,
			next = -1,
			id = -1,
			data = -1,
			clip = -1,
			mask = -1,
			filter = -1,
			opacity = 1,
			transform = TRANSFORM_IDENTITY,
			bbox = SVG_EMPTY_BOX,
		},
	)
	if parent >= 0 {
		par := &doc.nodes[parent]
		if par.last_child < 0 {
			par.first_child = idx
		} else {
			doc.nodes[par.last_child].next = idx
		}
		par.last_child = idx
	}
	return idx
}

// The element's own transform: the attribute, or a CSS transform.
@(private)
svg_element_transform :: proc(p: ^Svg_Parser, e: ^xml.Element, st: ^Svg_Computed, name := "transform") -> Transform2D {
	src := st.css_transform
	if src == "" {
		src, _ = svg_attr(e, name)
	}
	if src == "" {
		return TRANSFORM_IDENTITY
	}
	t, ok := transform_svg(src)
	if !ok {
		svg_warn(p, "invalid transform %q", src)
	}
	return t
}

// Sets the node's id, visibility and effects from the element and its
// style. False when the element must not be drawn (a broken filter).
@(private)
svg_node_effects :: proc(p: ^Svg_Parser, n: i32, el: u32, st: ^Svg_Computed, clip_ok := true) -> bool {
	doc := p.doc
	e := &p.x.elements[el]
	node := &doc.nodes[n]
	if id, ok := svg_attr(e, "id"); ok && id != "" {
		idx, found := doc.id_map[id]
		if !found {
			idx = i32(len(doc.ids))
			owned := strings.clone(id, p.sa)
			append(&doc.ids, owned)
			doc.id_map[owned] = idx
		}
		node.id = idx
	}
	if !st.visible {
		node.flags += {.Hidden}
	}
	if !st.visible_decl {
		node.flags += {.Visibility_Inherited}
	}
	if p.pending_off {
		node.flags += {.Off}
		p.pending_off = false
	}
	if !st.fill_decl {
		node.flags += {.Fill_Inherited}
	}
	if !st.stroke_decl {
		node.flags += {.Stroke_Inherited}
	}
	if st.crisp {
		node.flags += {.Crisp}
	}
	if p.in_clip {
		// Clip content: only geometry and nested clip paths count.
		if st.clip_path != "" && clip_ok {
			if ref, ok := svg_ref(p, st.clip_path); ok {
				c := svg_clip(p, ref)
				doc.nodes[n].clip = c
			}
		}
		return true
	}
	node.opacity = st.opacity
	node.blend = st.blend
	if st.blend != .Normal {
		doc.uses_blend = true
	}
	if st.isolate {
		node.flags += {.Isolate}
	}
	if st.clip_path != "" {
		if ref, ok := svg_ref(p, st.clip_path); ok && svg_tag(p.x.elements[ref].ident) == "clipPath" {
			c := svg_clip(p, ref)
			doc.nodes[n].clip = c
		} else {
			svg_warn(p, "clip-path %q does not name a clipPath", st.clip_path)
		}
	}
	if st.mask != "" {
		if ref, ok := svg_ref(p, st.mask); ok && svg_tag(p.x.elements[ref].ident) == "mask" {
			m := svg_mask(p, ref)
			doc.nodes[n].mask = m
		} else {
			svg_warn(p, "mask %q does not name a mask", st.mask)
		}
	}
	if st.filter != "" {
		if ref, ok := svg_ref(p, st.filter); ok && svg_tag(p.x.elements[ref].ident) == "filter" {
			f := svg_filter_def(p, ref)
			if f < 0 {
				return false
			}
			doc.nodes[n].filter = f
		} else {
			if strings.has_prefix(st.filter, "url(") {
				// A reference to nothing: the element is not rendered.
				return false
			}
			svg_warn(p, "CSS filter functions are not supported (filter=%q)", st.filter)
		}
	}
	return true
}

// Whether a group with this style needs a node of its own.
@(private)
svg_group_needed :: proc(p: ^Svg_Parser, e: ^xml.Element, st: ^Svg_Computed, t: Transform2D) -> bool {
	if p.in_clip {
		return t != TRANSFORM_IDENTITY || st.clip_path != ""
	}
	if _, has_id := svg_attr(e, "id"); has_id {
		return true
	}
	return t != TRANSFORM_IDENTITY || st.opacity < 1 || st.clip_path != "" || st.mask != "" || st.filter != "" || st.blend != .Normal || st.isolate || !st.visible
}

@(private)
svg_convert_children :: proc(p: ^Svg_Parser, el: u32, st: ^Svg_Computed, parent: i32) {
	for v in p.x.elements[el].value {
		if child, ok := v.(xml.Element_ID); ok {
			svg_convert_element(p, child, st, parent)
		}
	}
}

// Whether the conditional processing attributes let the element render.
@(private)
svg_conditions_pass :: proc(e: ^xml.Element) -> bool {
	if v, ok := svg_attr(e, "requiredExtensions"); ok && strings.trim_space(v) != "" {
		return false
	}
	if v, ok := svg_attr(e, "systemLanguage"); ok {
		rest := v
		for lang in strings.split_iterator(&rest, ",") {
			l := strings.trim_space(lang)
			if l == "en" || strings.has_prefix(l, "en-") {
				return true
			}
		}
		return false
	}
	return true
}

@(private)
svg_convert_element :: proc(p: ^Svg_Parser, el: u32, parent_st: ^Svg_Computed, parent: i32) {
	e := &p.x.elements[el]
	if e.kind != .Element {
		return
	}
	if colon := strings.index_byte(e.ident, ':'); colon >= 0 && e.ident[:colon] != "svg" {
		// Editor metadata (sodipodi:, inkscape:, ...).
		return
	}
	if budget_over(p.budget, .Depth, p.depth + 1) || !budget_take(p.budget, .Svg_Elements) {
		return
	}
	p.depth += 1
	defer p.depth -= 1
	tag := svg_tag(e.ident)
	switch tag {
	case "defs", "linearGradient", "radialGradient", "pattern", "clipPath", "mask", "filter", "symbol", "style", "title", "desc", "metadata", "marker", "script", "font", "font-face", "glyph", "missing-glyph", "cursor", "view", "animate", "animateMotion", "animateTransform", "animateColor", "set", "mpath", "foreignObject", "stop":
		if tag == "foreignObject" {
			svg_warn(p, "foreignObject is not supported")
		}
		return
	}
	if p.in_clip {
		switch tag {
		case "path", "rect", "circle", "ellipse", "line", "polyline", "polygon", "text", "use":
		case:
			return
		}
	}
	if !svg_conditions_pass(e) {
		return
	}
	st := svg_compute_style(p, el, parent_st)
	if st.display_none {
		// With an id it is kept, off, so an override can show it (a
		// character's alternate eyes); without one nothing could.
		id, has := svg_attr(e, "id")
		if !has || id == "" || p.in_clip {
			return
		}
		st.display_none = false
		p.pending_off = true
	}
	defer p.pending_off = false
	switch tag {
	case "g", "a":
		t := svg_element_transform(p, e, &st)
		n := parent
		if svg_group_needed(p, e, &st, t) {
			n = svg_new_node(p, .Group, parent)
			p.doc.nodes[n].transform = t
			if !svg_node_effects(p, n, el, &st) {
				svg_drop_node(p, n)
				return
			}
			st.fill_decl, st.stroke_decl, st.visible_decl = false, false, false
		}
		svg_convert_children(p, el, &st, n)
	case "switch":
		t := svg_element_transform(p, e, &st)
		n := svg_new_node(p, .Group, parent)
		p.doc.nodes[n].transform = t
		if !svg_node_effects(p, n, el, &st) {
			svg_drop_node(p, n)
			return
		}
		st.fill_decl, st.stroke_decl, st.visible_decl = false, false, false
		for v in e.value {
			child, ok := v.(xml.Element_ID)
			if !ok || p.x.elements[child].kind != .Element {
				continue
			}
			if svg_conditions_pass(&p.x.elements[child]) {
				svg_convert_element(p, child, &st, n)
				break
			}
		}
	case "svg":
		svg_convert_viewport(p, el, &st, parent, -1, -1)
	case "use":
		svg_convert_use(p, el, &st, parent)
	case "path", "rect", "circle", "ellipse", "line", "polyline", "polygon":
		svg_convert_shape(p, el, tag, &st, parent)
	case "text":
		svg_convert_text(p, el, &st, parent)
	case "image":
		svg_convert_image(p, el, &st, parent)
	case "tspan", "textPath", "tref":
	// Only inside text.
	case:
		svg_warn(p, "<%s> is not supported", tag)
	}
}

// Unlinks node `n` from its parent (definitions converted after it stay).
@(private)
svg_drop_node :: proc(p: ^Svg_Parser, n: i32) {
	doc := p.doc
	parent := doc.nodes[n].parent
	doc.nodes[n].parent = -1
	if parent < 0 {
		return
	}
	par := &doc.nodes[parent]
	if par.first_child == n {
		par.first_child, par.last_child = -1, -1
		return
	}
	for c := par.first_child; c >= 0; c = doc.nodes[c].next {
		if doc.nodes[c].next == n {
			doc.nodes[c].next = -1
			par.last_child = c
			break
		}
	}
}

// A nested <svg> (or one a <use> instantiates, with its width and height).
@(private)
svg_convert_viewport :: proc(p: ^Svg_Parser, el: u32, st: ^Svg_Computed, parent: i32, use_w, use_h: f32) {
	e := &p.x.elements[el]
	x := svg_attr_length(p, e, "x", 0, 0, st.font_size)
	y := svg_attr_length(p, e, "y", 1, 0, st.font_size)
	w := use_w if use_w > 0 else svg_attr_length(p, e, "width", 0, svg_percent_base(p, 0), st.font_size)
	h := use_h if use_h > 0 else svg_attr_length(p, e, "height", 1, svg_percent_base(p, 1), st.font_size)
	if w <= 0 || h <= 0 {
		return
	}
	vb, has_vb := svg_view_box(e)
	if has_vb && (vb.w <= 0 || vb.h <= 0) {
		return
	}
	t := transform_translation(x, y)
	clip := Rect{0, 0, w, h}
	if has_vb {
		vt := svg_view_box_transform(vb, svg_aspect(e), w, h)
		t = transform_multiply(vt, t)
		clip = svg_rect_transform(clip, transform_inverse(vt))
	}
	// SVG 2: a transform on the nested svg applies outside its viewport.
	t = transform_multiply(t, svg_element_transform(p, e, st))
	n := svg_new_node(p, .Group, parent)
	p.doc.nodes[n].transform = t
	if !st.overflow_visible {
		p.doc.nodes[n].flags += {.Clip_Rect}
		p.doc.nodes[n].clip_rect = clip
	}
	if !svg_node_effects(p, n, el, st) {
		svg_drop_node(p, n)
		return
	}
	cst := st^
	cst.fill_decl, cst.stroke_decl, cst.visible_decl = false, false, false
	append(&p.viewports, Vec2{vb.w, vb.h} if has_vb else Vec2{w, h})
	svg_convert_children(p, el, &cst, n)
	pop(&p.viewports)
}

@(private)
svg_convert_use :: proc(p: ^Svg_Parser, el: u32, st: ^Svg_Computed, parent: i32) {
	e := &p.x.elements[el]
	href, has := svg_href(e)
	if !has {
		return
	}
	ref, found := svg_ref(p, href)
	if !found {
		return
	}
	for u in p.use_stack {
		if u == ref {
			svg_warn(p, "recursive <use> of %q is skipped", href)
			return
		}
	}
	if ref == el || len(p.use_stack) > 32 {
		return
	}
	// A use can't reference an ancestor of itself.
	for a := p.x.elements[el].parent; a != 0; a = p.x.elements[a].parent {
		if a == ref {
			return
		}
	}
	if ref == 0 {
		return
	}
	x := svg_attr_length(p, e, "x", 0, 0, st.font_size)
	y := svg_attr_length(p, e, "y", 1, 0, st.font_size)
	t := transform_multiply(transform_translation(x, y), svg_element_transform(p, e, st))
	n := svg_new_node(p, .Group, parent)
	p.doc.nodes[n].transform = t
	if !svg_node_effects(p, n, el, st) {
		svg_drop_node(p, n)
		return
	}
	cst := st^
	cst.fill_decl, cst.stroke_decl, cst.visible_decl = false, false, false
	append(&p.use_stack, ref)
	defer pop(&p.use_stack)
	re := &p.x.elements[ref]
	switch svg_tag(re.ident) {
	case "symbol":
		if p.in_clip {
			return
		}
		sst := svg_compute_style(p, ref, &cst)
		if sst.display_none {
			return
		}
		w := svg_attr_length(p, e, "width", 0, -1, st.font_size)
		h := svg_attr_length(p, e, "height", 1, -1, st.font_size)
		if w < 0 {
			w = svg_attr_length(p, re, "width", 0, svg_percent_base(p, 0), st.font_size)
		}
		if h < 0 {
			h = svg_attr_length(p, re, "height", 1, svg_percent_base(p, 1), st.font_size)
		}
		vb, has_vb := svg_view_box(re)
		sn := svg_new_node(p, .Group, n)
		if !svg_node_effects(p, sn, ref, &sst) {
			svg_drop_node(p, sn)
			return
		}
		if has_vb && vb.w > 0 && vb.h > 0 && w > 0 && h > 0 {
			vt := svg_view_box_transform(vb, svg_aspect(re), w, h)
			p.doc.nodes[sn].transform = vt
			if !sst.overflow_visible {
				p.doc.nodes[sn].flags += {.Clip_Rect}
				p.doc.nodes[sn].clip_rect = svg_rect_transform({0, 0, w, h}, transform_inverse(vt))
			}
			append(&p.viewports, Vec2{vb.w, vb.h})
		} else {
			if !sst.overflow_visible && w > 0 && h > 0 {
				p.doc.nodes[sn].flags += {.Clip_Rect}
				p.doc.nodes[sn].clip_rect = {0, 0, w, h}
			}
			append(&p.viewports, Vec2{w, h} if w > 0 && h > 0 else svg_viewport(p))
		}
		// A transform on the symbol itself is SVG 2 only: ignored, as resvg.
		sst.fill_decl, sst.stroke_decl, sst.visible_decl = false, false, false
		svg_convert_children(p, ref, &sst, sn)
		pop(&p.viewports)
	case "svg":
		if p.in_clip {
			return
		}
		sst := svg_compute_style(p, ref, &cst)
		if sst.display_none {
			return
		}
		svg_convert_viewport(p, ref, &sst, n, svg_attr_length(p, e, "width", 0, -1, st.font_size), svg_attr_length(p, e, "height", 1, -1, st.font_size))
	case:
		svg_convert_element(p, ref, &cst, n)
	}
}

@(private)
svg_convert_shape :: proc(p: ^Svg_Parser, el: u32, tag: string, st: ^Svg_Computed, parent: i32) {
	e := &p.x.elements[el]
	path := &p.path
	path_reset(path)
	fs := st.font_size
	switch tag {
	case "path":
		d, _ := svg_attr(e, "d")
		if !path_svg(path, d) {
			// Rendered up to the error, as in SVG.
			svg_warn(p, "malformed path data is drawn up to the error")
		}
	case "rect":
		x := svg_attr_length(p, e, "x", 0, 0, fs)
		y := svg_attr_length(p, e, "y", 1, 0, fs)
		w := svg_attr_length(p, e, "width", 0, 0, fs)
		h := svg_attr_length(p, e, "height", 1, 0, fs)
		if w <= 0 || h <= 0 {
			return
		}
		rx := svg_attr_length(p, e, "rx", 0, -1, fs)
		ry := svg_attr_length(p, e, "ry", 1, -1, fs)
		if rx < 0 && ry < 0 {
			rx, ry = 0, 0
		} else if rx < 0 {
			rx = ry
		} else if ry < 0 {
			ry = rx
		}
		svg_rect_path(path, x, y, w, h, min(rx, w / 2), min(ry, h / 2))
	case "circle":
		r := svg_attr_length(p, e, "r", 2, 0, fs)
		if r <= 0 {
			return
		}
		svg_ellipse_path(path, svg_attr_length(p, e, "cx", 0, 0, fs), svg_attr_length(p, e, "cy", 1, 0, fs), r, r)
	case "ellipse":
		rx := svg_attr_length(p, e, "rx", 0, -1, fs)
		ry := svg_attr_length(p, e, "ry", 1, -1, fs)
		if rx < 0 {
			rx = ry
		}
		if ry < 0 {
			ry = rx
		}
		if rx <= 0 || ry <= 0 {
			return
		}
		svg_ellipse_path(path, svg_attr_length(p, e, "cx", 0, 0, fs), svg_attr_length(p, e, "cy", 1, 0, fs), rx, ry)
	case "line":
		path_move_to(path, svg_attr_length(p, e, "x1", 0, 0, fs), svg_attr_length(p, e, "y1", 1, 0, fs))
		path_line_to(path, svg_attr_length(p, e, "x2", 0, 0, fs), svg_attr_length(p, e, "y2", 1, 0, fs))
	case "polyline", "polygon":
		pts, _ := svg_attr(e, "points")
		sc := Svg_Scanner{s = pts}
		n := 0
		for {
			x, ok1 := svg_scan_number(&sc)
			if !ok1 {
				break
			}
			y, ok2 := svg_scan_number(&sc)
			if !ok2 {
				break
			}
			if n == 0 {
				path_move_to(path, x, y)
			} else {
				path_line_to(path, x, y)
			}
			n += 1
		}
		if n < 2 {
			return
		}
		if tag == "polygon" {
			path_close(path)
		}
	}
	if len(path.verbs) == 0 || len(path.coords) == 0 {
		return
	}
	doc := p.doc
	if p.in_clip && !st.visible {
		return
	}
	// Into the document before the effects: converting a referenced clip
	// path reuses the scratch path.
	shape := Svg_Shape {
		verbs  = {u32(len(doc.verbs)), u32(len(path.verbs))},
		coords = {u32(len(doc.coords)), u32(len(path.coords))},
		style  = svg_shape_style(p, st),
	}
	if pl, ok := svg_attr(e, "pathLength"); ok {
		if v, vok := svg_parse_number(pl); vok && v > 0 {
			shape.path_length = v
		}
	}
	if tag == "line" {
		// No area to fill.
		shape.style.fill = {}
	}
	bbox := svg_path_bbox(path.verbs[:], path.coords[:])
	append(&doc.verbs, ..path.verbs[:])
	append(&doc.coords, ..path.coords[:])
	n := svg_new_node(p, .Shape, parent)
	doc.nodes[n].transform = svg_element_transform(p, e, st)
	doc.nodes[n].data = i32(len(doc.shapes))
	doc.nodes[n].bbox = bbox
	append(&doc.shapes, shape)
	if !svg_node_effects(p, n, el, st) {
		svg_drop_node(p, n)
	}
}

// SVG's rect path: from (x + rx, y) clockwise (dashes start there).
@(private)
svg_rect_path :: proc(p: ^Path, x, y, w, h, rx, ry: f32) {
	if rx <= 0 || ry <= 0 {
		path_move_to(p, x, y)
		path_line_to(p, x + w, y)
		path_line_to(p, x + w, y + h)
		path_line_to(p, x, y + h)
		path_close(p)
		return
	}
	k: f32 = 1 - KAPPA90
	path_move_to(p, x + rx, y)
	path_line_to(p, x + w - rx, y)
	path_bezier_to(p, x + w - rx * k, y, x + w, y + ry * k, x + w, y + ry)
	path_line_to(p, x + w, y + h - ry)
	path_bezier_to(p, x + w, y + h - ry * k, x + w - rx * k, y + h, x + w - rx, y + h)
	path_line_to(p, x + rx, y + h)
	path_bezier_to(p, x + rx * k, y + h, x, y + h - ry * k, x, y + h - ry)
	path_line_to(p, x, y + ry)
	path_bezier_to(p, x, y + ry * k, x + rx * k, y, x + rx, y)
	path_close(p)
}

// SVG's ellipse path: from (cx + rx, cy) clockwise.
@(private)
svg_ellipse_path :: proc(p: ^Path, cx, cy, rx, ry: f32) {
	kx, ky := rx * f32(KAPPA90), ry * f32(KAPPA90)
	path_move_to(p, cx + rx, cy)
	path_bezier_to(p, cx + rx, cy + ky, cx + kx, cy + ry, cx, cy + ry)
	path_bezier_to(p, cx - kx, cy + ry, cx - rx, cy + ky, cx - rx, cy)
	path_bezier_to(p, cx - rx, cy - ky, cx - kx, cy - ry, cx, cy - ry)
	path_bezier_to(p, cx + kx, cy - ry, cx + rx, cy - ky, cx + rx, cy)
	path_close(p)
}

@(private)
svg_shape_style :: proc(p: ^Svg_Parser, st: ^Svg_Computed) -> Svg_Style {
	if p.in_clip {
		return {fill = {kind = .Color, color = WHITE}, fill_opacity = 1, fill_rule = st.clip_rule}
	}
	s := Svg_Style {
		fill           = st.fill,
		stroke         = st.stroke,
		fill_opacity   = st.fill_opacity,
		stroke_opacity = st.stroke_opacity,
		stroke_width   = st.stroke_width,
		miter_limit    = st.miter_limit,
		dash_offset    = st.dash_offset,
		dash           = st.dash,
		fill_rule      = st.fill_rule,
		cap            = st.cap,
		join           = st.join,
	}
	if s.stroke_width <= 0 {
		s.stroke = {}
	}
	return s
}

// The exact bounds of path data (curve extrema, not control points).
@(private)
svg_path_bbox :: proc(verbs: []Verb, coords: []Vec2) -> Rect {
	lo := Vec2{1e30, 1e30}
	hi := Vec2{-1e30, -1e30}
	add :: #force_inline proc "contextless" (lo, hi: ^Vec2, q: Vec2) {
		lo^ = {min(lo.x, q.x), min(lo.y, q.y)}
		hi^ = {max(hi.x, q.x), max(hi.y, q.y)}
	}
	ci := 0
	cur: Vec2
	for v in verbs {
		switch v {
		case .Move_To, .Line_To:
			cur = coords[ci]
			add(&lo, &hi, cur)
			ci += 1
		case .Bezier_To:
			c1, c2, to := coords[ci], coords[ci + 1], coords[ci + 2]
			add(&lo, &hi, to)
			// Roots of the derivative per axis.
			for axis in 0 ..< 2 {
				p0, p1, p2, p3 := cur[axis], c1[axis], c2[axis], to[axis]
				a := -p0 + 3 * p1 - 3 * p2 + p3
				b := 2 * (p0 - 2 * p1 + p2)
				c := p1 - p0
				ts: [2]f32
				nt := 0
				if abs(a) < 1e-12 {
					if abs(b) > 1e-12 {
						ts[0] = -c / b
						nt = 1
					}
				} else {
					disc := b * b - 4 * a * c
					if disc >= 0 {
						sq := math.sqrt(disc)
						ts[0] = (-b + sq) / (2 * a)
						ts[1] = (-b - sq) / (2 * a)
						nt = 2
					}
				}
				for t in ts[:nt] {
					if t > 0 && t < 1 {
						mt := 1 - t
						q := cur * (mt * mt * mt) + c1 * (3 * mt * mt * t) + c2 * (3 * mt * t * t) + to * (t * t * t)
						add(&lo, &hi, q)
					}
				}
			}
			cur = to
			ci += 3
		case .Close, .Solid, .Hole:
		}
	}
	if lo.x > hi.x {
		return SVG_EMPTY_BOX
	}
	return {lo.x, lo.y, hi.x - lo.x, hi.y - lo.y}
}

@(private)
svg_convert_image :: proc(p: ^Svg_Parser, el: u32, st: ^Svg_Computed, parent: i32) {
	if p.in_clip {
		return
	}
	e := &p.x.elements[el]
	href, has := svg_href(e)
	if !has {
		return
	}
	fs := st.font_size
	img := Svg_Image {
		x = svg_attr_length(p, e, "x", 0, 0, fs),
		y = svg_attr_length(p, e, "y", 1, 0, fs),
		w = svg_attr_length(p, e, "width", 0, 0, fs),
		h = svg_attr_length(p, e, "height", 1, 0, fs),
	}
	a := svg_aspect(e)
	img.align = a.align
	img.fit = .None if a.none else (.Slice if a.slice else .Meet)
	if r, ok := svg_attr(e, "image-rendering"); ok {
		img.pixelated = r == "pixelated" || r == "optimizeSpeed" || r == "crisp-edges"
	}
	bm, svg_data := svg_bitmap(p, href)
	if svg_data != nil {
		svg_convert_svg_image(p, el, st, parent, svg_data, img, a)
		return
	}
	if bm < 0 {
		return
	}
	b := p.doc.bitmaps[bm]
	img.bitmap = bm
	iw, ih := f32(b.width), f32(b.height)
	switch {
	case img.w <= 0 && img.h <= 0:
		img.w, img.h = iw, ih
	case img.w <= 0:
		img.w = img.h * iw / ih
	case img.h <= 0:
		img.h = img.w * ih / iw
	}
	doc := p.doc
	n := svg_new_node(p, .Image, parent)
	doc.nodes[n].transform = svg_element_transform(p, e, st)
	doc.nodes[n].data = i32(len(doc.images))
	doc.nodes[n].bbox = {img.x, img.y, img.w, img.h}
	append(&doc.images, img)
	if !svg_node_effects(p, n, el, st) {
		svg_drop_node(p, n)
	}
}

// The bytes an image href names: a data: URI or the host's file.
@(private)
svg_image_bytes :: proc(p: ^Svg_Parser, href: string) -> (data: []u8, ok: bool) {
	if !strings.has_prefix(href, "data:") {
		if p.opts.load_file == nil {
			svg_warn(p, "<image> href %q needs a file loader", href)
			return
		}
		return p.opts.load_file(p.opts.user, href, p.tmp)
	}
	comma := strings.index_byte(href, ',')
	if comma < 0 {
		return
	}
	meta := href[5:comma]
	payload := href[comma + 1:]
	if !strings.has_suffix(meta, ";base64") {
		return transmute([]u8)payload, true
	}
	// Base64 may be wrapped over lines and lack its padding.
	clean := make([dynamic]u8, 0, len(payload) + 3, p.tmp)
	for ch in transmute([]u8)payload {
		if ch != ' ' && ch != '\n' && ch != '\r' && ch != '\t' {
			append(&clean, ch)
		}
	}
	for len(clean) % 4 != 0 {
		append(&clean, '=')
	}
	decoded, derr := base64.decode(string(clean[:]), allocator = p.tmp)
	if derr != nil {
		svg_warn(p, "an <image> data URI does not decode")
		return
	}
	return decoded, true
}

// The bitmap an image href names (decoded once per document), or -1;
// SVG data is returned instead for the caller to convert.
@(private)
svg_bitmap :: proc(p: ^Svg_Parser, href: string) -> (bm: i32, svg_data: []u8) {
	if cached, ok := p.bitmap_of[href]; ok {
		return cached, nil
	}
	bm = -1
	data, read := svg_image_bytes(p, href)
	if !read {
		p.bitmap_of[strings.clone(href, p.tmp)] = -1
		return
	}
	if svg_is_svg(data) {
		return -1, data
	}
	pixels, w, h, dok := svg_decode_image(data, p.doc.allocator, p.budget)
	if dok {
		bm = i32(len(p.doc.bitmaps))
		append(&p.doc.bitmaps, Svg_Bitmap{pixels, w, h})
	} else {
		svg_warn(p, "<image> %q could not be decoded", href if len(href) < 64 else "data:...")
	}
	p.bitmap_of[strings.clone(href, p.tmp)] = bm
	return bm, nil
}

@(private)
svg_is_svg :: proc(data: []u8) -> bool {
	head := string(data[:min(len(data), 1024)])
	return strings.contains(head, "<svg") || strings.contains(head, ":svg")
}

// An SVG used as an image: its tree joins the document under a group
// mapping its viewBox into the image's box (the image's own
// preserveAspectRatio wins) and clipping to that box.
@(private)
svg_convert_svg_image :: proc(p: ^Svg_Parser, el: u32, st: ^Svg_Computed, parent: i32, data: []u8, img: Svg_Image, aspect: Svg_Aspect) {
	if p.image_depth >= 4 {
		svg_warn(p, "SVG images nested too deep are skipped")
		return
	}
	doc := p.doc
	e := &p.x.elements[el]
	sub: Svg_Parser
	if svg_parser_open(&sub, doc, data, p.opts, p.sa, p.tmp, p.warned) != nil {
		svg_warn(p, "an SVG <image> does not parse")
		return
	}
	defer path_destroy(&sub.path)
	sub.image_depth = p.image_depth + 1
	sub.budget, sub.depth = p.budget, p.depth
	root_style := svg_initial_style()
	sst := svg_compute_style(&sub, 0, &root_style)
	sw, sh, vb, has_vb := svg_root_size(&sub, &sst)
	w, h := img.w, img.h
	switch {
	case w <= 0 && h <= 0:
		w, h = sw, sh
	case w <= 0:
		w = h * sw / sh
	case h <= 0:
		h = w * sh / sw
	}
	if w <= 0 || h <= 0 {
		return
	}
	if !has_vb {
		vb = {0, 0, sw, sh}
	}
	n := svg_new_node(p, .Group, parent)
	doc.nodes[n].transform = svg_element_transform(p, e, st)
	if !svg_node_effects(p, n, el, st) {
		svg_drop_node(p, n)
		return
	}
	vt := svg_view_box_transform(vb, aspect, w, h)
	inner := svg_new_node(p, .Group, n)
	doc.nodes[inner].transform = transform_multiply(vt, transform_translation(img.x, img.y))
	doc.nodes[inner].flags += {.Clip_Rect}
	doc.nodes[inner].clip_rect = svg_rect_transform({0, 0, w, h}, transform_inverse(vt))
	append(&sub.viewports, Vec2{vb.w, vb.h})
	sst.fill_decl, sst.stroke_decl, sst.visible_decl = false, false, false
	svg_convert_children(&sub, 0, &sst, inner)
}

// Decodes PNG / JPEG / ... bytes to straight RGBA8 with `allocator`. Images
// over the budget's (or DEFAULT_LIMITS') Image_Pixels are not decoded.
svg_decode_image :: proc(data: []u8, allocator: mem.Allocator, budget: ^Budget = nil) -> (pixels: []u8, width, height: u32, ok: bool) {
	if len(data) == 0 || len(data) > int(max(i32)) {
		return
	}
	w, h, ch: i32
	if stbi.info_from_memory(raw_data(data), i32(len(data)), &w, &h, &ch) == 0 {
		return
	}
	if budget != nil && budget_over(budget, .Image_Pixels, int(w) * int(h)) {
		return
	} else if budget == nil && int(w) * int(h) > DEFAULT_LIMITS[.Image_Pixels] {
		return
	}
	px := stbi.load_from_memory(raw_data(data), i32(len(data)), &w, &h, &ch, 4)
	if px == nil {
		return
	}
	defer stbi.image_free(px)
	n := int(w) * int(h) * 4
	pixels = make([]u8, n, allocator)
	copy(pixels, px[:n])
	return pixels, u32(w), u32(h), true
}

// ---- text ---------------------------------------------------------------------------

// Positioning attributes of one text / tspan element (lists, user units),
// applying from character `start` of the text.
@(private)
Svg_Text_Lists :: struct {
	start:              int,
	x, y, dx, dy, rot:  []f32,
	has_rot:            bool,
}

@(private)
Svg_Text_State :: struct {
	text:       i32,
	chunk:      i32,
	// The last character emitted was a space (collapsing whitespace).
	last_space: bool,
	baseline:   Text_Baseline,
	// Characters emitted so far (after whitespace handling).
	chars:      int,
	rot:        f32,
	lists:      [dynamic]Svg_Text_Lists,
}

@(private)
svg_convert_text :: proc(p: ^Svg_Parser, el: u32, st: ^Svg_Computed, parent: i32) {
	doc := p.doc
	e := &p.x.elements[el]
	n := svg_new_node(p, .Text, parent)
	doc.nodes[n].transform = svg_element_transform(p, e, st)
	if !svg_node_effects(p, n, el, st) {
		svg_drop_node(p, n)
		return
	}
	text := i32(len(doc.texts))
	piece_start := len(doc.pieces)
	append(&doc.texts, Svg_Text{chunks = {u32(len(doc.chunks)), 0}})
	doc.nodes[n].data = text
	ts := Svg_Text_State {
		text       = text,
		chunk      = -1,
		last_space = true,
		baseline   = st.baseline,
		lists      = make([dynamic]Svg_Text_Lists, p.tmp),
	}
	cst := st^
	cst.fill_decl, cst.stroke_decl, cst.visible_decl = false, false, false
	svg_text_push_lists(p, e, &cst, &ts)
	svg_collect_text(p, el, &cst, &ts)
	// Trailing whitespace of the whole text goes.
	t := &doc.texts[text]
	t.chunks.count = u32(len(doc.chunks)) - t.chunks.start
	for i := len(doc.pieces) - 1; i >= piece_start && !st.preserve_space; i -= 1 {
		pc := &doc.pieces[i]
		pc.text = strings.trim_right(pc.text, " ")
		if pc.text != "" {
			break
		}
	}
	if t.chunks.count == 0 {
		svg_drop_node(p, n)
		resize(&doc.texts, int(text))
		return
	}
	doc.nodes[n].bbox = svg_text_bbox(p, t^, st.font_size)
}

// Reads the x / y / dx / dy / rotate lists of a text or tspan.
@(private)
svg_text_push_lists :: proc(p: ^Svg_Parser, e: ^xml.Element, st: ^Svg_Computed, ts: ^Svg_Text_State) {
	list :: proc(p: ^Svg_Parser, e: ^xml.Element, name: string, axis: int, fs: f32, number: bool) -> (out: []f32, has: bool) {
		s := svg_attr(e, name) or_return
		vals := make([dynamic]f32, p.tmp)
		sc := Svg_Scanner{s = s}
		for {
			if number {
				v, ok := svg_scan_number(&sc)
				if !ok {
					break
				}
				append(&vals, v)
			} else {
				l, ok := svg_scan_length(&sc)
				if !ok {
					break
				}
				append(&vals, svg_length_px(l, svg_percent_base(p, axis), fs))
			}
		}
		return vals[:], true
	}
	fs := st.font_size
	l := Svg_Text_Lists {
		start = ts.chars,
	}
	l.x, _ = list(p, e, "x", 0, fs, false)
	l.y, _ = list(p, e, "y", 1, fs, false)
	l.dx, _ = list(p, e, "dx", 0, fs, false)
	l.dy, _ = list(p, e, "dy", 1, fs, false)
	l.rot, l.has_rot = list(p, e, "rotate", 0, fs, true)
	append(&ts.lists, l)
	if _, ok := svg_attr(e, "textLength"); ok {
		svg_warn(p, "textLength is not supported")
	}
}

// The positioning of character `g`: the innermost element with a value.
@(private)
svg_text_char_pos :: proc(ts: ^Svg_Text_State, g: int) -> (x, y, dx, dy: Maybe(f32), rot: f32) {
	at :: proc(l: []f32, i: int) -> Maybe(f32) {
		if i >= 0 && i < len(l) {
			return l[i]
		}
		return nil
	}
	rot_found := false
	#reverse for &l in ts.lists {
		i := g - l.start
		if x == nil {x = at(l.x, i)}
		if y == nil {y = at(l.y, i)}
		if dx == nil {dx = at(l.dx, i)}
		if dy == nil {dy = at(l.dy, i)}
		if !rot_found && l.has_rot && len(l.rot) > 0 {
			// The last value repeats for the remaining characters.
			rot = l.rot[min(i, len(l.rot) - 1)]
			rot_found = true
		}
	}
	return
}

@(private)
svg_collect_text :: proc(p: ^Svg_Parser, el: u32, st: ^Svg_Computed, ts: ^Svg_Text_State) {
	for v in p.x.elements[el].value {
		switch c in v {
		case string:
			s := svg_text_whitespace(p, c, st.preserve_space, &ts.last_space)
			if s != "" {
				svg_text_emit(p, s, st, ts)
			}
		case xml.Element_ID:
			ce := &p.x.elements[c]
			if ce.kind != .Element {
				continue
			}
			tag := svg_tag(ce.ident)
			switch tag {
			case "tspan", "a", "textPath":
				if tag == "textPath" {
					svg_warn(p, "textPath is not supported (drawn as a tspan)")
				}
				if !svg_conditions_pass(ce) {
					continue
				}
				cst := svg_compute_style(p, c, st)
				if cst.display_none {
					// Its characters still take their positions.
					continue
				}
				svg_text_push_lists(p, ce, &cst, ts)
				svg_collect_text(p, c, &cst, ts)
				pop(&ts.lists)
			case "tref":
				svg_warn(p, "tref is not supported")
			}
		}
	}
}

// Appends the processed text `s` in style `st`, split into pieces where
// characters are positioned (a new chunk at an absolute x / y).
@(private)
svg_text_emit :: proc(p: ^Svg_Parser, s: string, st: ^Svg_Computed, ts: ^Svg_Text_State) {
	doc := p.doc
	// In a clip path the text is geometry, filled white whatever its fill,
	// as shapes are (svg_shape_style).
	style := svg_shape_style(p, st)
	if !p.in_clip {
		style.fill = st.fill
		if st.stroke_width > 0 {
			style.stroke = st.stroke
		}
	}
	piece_from := 0
	cur_dx, cur_dy: f32
	cur_rot := ts.rot
	flush :: proc(p: ^Svg_Parser, s: string, from, to: int, st: ^Svg_Computed, ts: ^Svg_Text_State, style: Svg_Style, dx, dy, rot: f32) {
		if to <= from {
			return
		}
		doc := p.doc
		append(
			&doc.pieces,
			Svg_Text_Piece {
				text = s[from:to],
				families = st.families,
				size = st.font_size,
				weight = st.font_weight,
				italic = st.italic,
				letter_spacing = st.letter_spacing,
				dx = dx,
				dy = dy,
				rotate = rot,
				style = style,
				fill_inherited = !st.fill_decl,
				stroke_inherited = !st.stroke_decl,
				hidden = !st.visible,
			},
		)
		ch := &doc.chunks[ts.chunk]
		ch.pieces.count = u32(len(doc.pieces)) - ch.pieces.start
	}
	for _, off in s {
		x, y, dx, dy, rot := svg_text_char_pos(ts, ts.chars)
		_, has_x := x.?
		_, has_y := y.?
		new_chunk := has_x || has_y || ts.chunk < 0
		ddx, ddy := dx.? or_else 0, dy.? or_else 0
		if new_chunk || ddx != 0 || ddy != 0 || rot != cur_rot {
			flush(p, s, piece_from, off, st, ts, style, cur_dx, cur_dy, cur_rot)
			piece_from = off
			cur_dx, cur_dy, cur_rot = ddx, ddy, rot
		}
		if new_chunk {
			first := ts.chunk < 0
			append(&doc.chunks, Svg_Text_Chunk{x = x.? or_else 0, y = y.? or_else 0, has_x = has_x || first, has_y = has_y || first, anchor = st.anchor, baseline = ts.baseline, pieces = {u32(len(doc.pieces)), 0}})
			ts.chunk = i32(len(doc.chunks) - 1)
		}
		ts.chars += 1
	}
	flush(p, s, piece_from, len(s), st, ts, style, cur_dx, cur_dy, cur_rot)
	ts.rot = cur_rot
}

// Text whitespace (CSS white-space: normal, as resvg and browsers): any
// whitespace is a space, runs collapse (across tspans), the text's leading
// and trailing spaces go. xml:space="preserve" keeps every space.
@(private)
svg_text_whitespace :: proc(p: ^Svg_Parser, s: string, preserve: bool, last_space: ^bool) -> string {
	out := make([]u8, len(s), p.sa)
	n := 0
	src := transmute([]u8)s
	for i := 0; i < len(src); i += 1 {
		c := src[i]
		if c == 0xEE && i + 2 < len(src) && src[i + 1] == 0x80 && src[i + 2] == 0x80 {
			// SVG_SPACE: whitespace protected from the XML reader.
			c = ' '
			i += 2
		}
		if preserve {
			if c == '\n' || c == '\r' || c == '\t' {
				c = ' '
			}
			out[n] = c
			n += 1
			continue
		}
		if c == '\n' || c == '\r' || c == '\t' {
			c = ' '
		}
		if c == ' ' {
			if last_space^ {
				continue
			}
			last_space^ = true
		} else {
			last_space^ = false
		}
		out[n] = c
		n += 1
	}
	return string(out[:n])
}

// The text's bounding box: laid out with the parse fonts, else estimated.
@(private)
svg_text_bbox :: proc(p: ^Svg_Parser, t: Svg_Text, font_size: f32) -> Rect {
	doc := p.doc
	box := SVG_EMPTY_BOX
	if p.opts.fonts != nil {
		l: Text_Layout
		pieces := make([dynamic]Text_Piece, p.tmp)
		defer text_layout_destroy(&l)
		pen: Vec2
		for ci in t.chunks.start ..< t.chunks.start + t.chunks.count {
			pen = svg_layout_chunk(p.opts.fonts, doc, &doc.chunks[ci], pen, &l, &pieces)
			if len(l.glyphs) > 0 {
				box = svg_box_union(box, {l.min.x, l.min.y, l.max.x - l.min.x, l.max.y - l.min.y})
			}
		}
		return box
	}
	pen: Vec2
	for ci in t.chunks.start ..< t.chunks.start + t.chunks.count {
		ch := &doc.chunks[ci]
		x := ch.x if ch.has_x else pen.x
		y := ch.y if ch.has_y else pen.y
		w: f32
		size := font_size
		for pc in doc.pieces[ch.pieces.start:][:ch.pieces.count] {
			w += f32(len(pc.text)) * pc.size * 0.55 + pc.dx
			y += pc.dy
			size = pc.size
		}
		x0 := x - (w if ch.anchor == .Right else (w / 2 if ch.anchor == .Center else 0))
		box = svg_box_union(box, {x0, y - size * 0.8, w, size})
		pen = {x0 + w, y}
	}
	return box
}

// Lays out one chunk into `l` from the pen position left by the previous
// chunk; returns where this one ends. `pieces` is scratch.
svg_layout_chunk :: proc(fonts: ^Font_Collection, doc: ^Svg_Document, ch: ^Svg_Text_Chunk, pen: Vec2, l: ^Text_Layout, pieces: ^[dynamic]Text_Piece) -> Vec2 {
	clear(pieces)
	y := ch.y if ch.has_y else pen.y
	x := ch.x if ch.has_x else pen.x
	total_dy: f32
	for &pc, i in doc.pieces[ch.pieces.start:][:ch.pieces.count] {
		family := svg_pick_family(fonts, doc, pc.families)
		append(pieces, Text_Piece{pc.text, {family, pc.size, pc.weight, pc.italic, pc.letter_spacing, u32(i)}, pc.dx, pc.dy})
		total_dy += pc.dy
	}
	text_layout(fonts, pieces[:], {x = x, y = y, baseline = ch.baseline}, l)
	if len(l.glyphs) == 0 {
		return {x, y + total_dy}
	}
	// text-anchor aligns the extent of the glyphs (dx included, trailing
	// letter-spacing not), as resvg does.
	lo, hi := f32(1e30), f32(-1e30)
	for run in l.runs {
		for g in l.glyphs[run.first:][:run.count] {
			adv, _ := font_glyph_advance(run.font, g.glyph)
			lo = min(lo, g.x)
			hi = max(hi, g.x + f32(adv) * run.em)
		}
	}
	shift: f32
	switch ch.anchor {
	case .Left:
		shift = x - lo if lo < x else 0
	case .Center:
		shift = x - (lo + hi) / 2
	case .Right:
		shift = x - hi
	}
	if shift != 0 {
		for &g in l.glyphs {
			g.x += shift
		}
		l.min.x += shift
		l.max.x += shift
	}
	end := x + (l.lines[0].width if len(l.lines) > 0 else 0) + shift
	return {end, y + total_dy}
}

// The first family of `families` the collection has (generic names map to
// the collection's fallback), else the first one.
svg_pick_family :: proc(fonts: ^Font_Collection, doc: ^Svg_Document, families: Range) -> string {
	list := doc.families[families.start:][:families.count]
	for f in list {
		if _, found := font_collection_find(fonts, f, 400); found {
			return f
		}
	}
	for f in list {
		switch f {
		case "serif", "sans-serif", "monospace", "cursive", "fantasy", "system-ui":
			// The fallback face, without a missing-family report.
			return fonts.fallback.family
		}
	}
	if len(list) > 0 {
		return list[0]
	}
	return ""
}

// ---- paint servers --------------------------------------------------------------------

// The paint a url() to element `el` gives: a server, a solid color (a
// one-stop gradient) or none.
@(private)
svg_server_paint :: proc(p: ^Svg_Parser, el: u32) -> Svg_Paint {
	idx := svg_server(p, el)
	if idx < 0 {
		return {}
	}
	s := p.doc.servers[idx]
	if s.kind != .Pattern && s.stops.count == 1 {
		return {kind = .Color, color = p.doc.stops[s.stops.start].color}
	}
	return {kind = .Server, server = idx}
}

// The `href` chain of a paint server / filter, `el` first.
@(private)
svg_href_chain :: proc(p: ^Svg_Parser, el: u32, chain: ^[16]u32) -> int {
	n := 0
	cur := el
	for n < len(chain) {
		// Cycles end the chain.
		for c in chain[:n] {
			if c == cur {
				return n
			}
		}
		chain[n] = cur
		n += 1
		href, has := svg_href(&p.x.elements[cur])
		if !has {
			break
		}
		next, ok := svg_ref(p, href)
		if !ok {
			break
		}
		cur = next
	}
	return n
}

// The first attribute `name` along the chain (only from elements whose tag
// is in `tags`, "" = any gradient).
@(private)
svg_chain_attr :: proc(p: ^Svg_Parser, chain: []u32, name: string, tag: string = "") -> (v: string, owner: u32, ok: bool) {
	for el in chain {
		e := &p.x.elements[el]
		t := svg_tag(e.ident)
		if tag != "" && t != tag {
			continue
		}
		if tag == "" && t != "linearGradient" && t != "radialGradient" && t != "pattern" {
			continue
		}
		if val, has := svg_attr(e, name); has {
			return val, el, true
		}
	}
	return "", 0, false
}

// The computed style of element `el` from the root down (for definitions,
// which inherit from where they are written, not where they are used).
@(private)
svg_style_chain :: proc(p: ^Svg_Parser, el: u32) -> Svg_Computed {
	path: [64]u32
	n := 0
	for cur := el; n < len(path); {
		path[n] = cur
		n += 1
		if cur == 0 {
			break
		}
		cur = p.x.elements[cur].parent
	}
	st := svg_initial_style()
	for i := n - 1; i >= 0; i -= 1 {
		st = svg_compute_style(p, path[i], &st)
	}
	return st
}

// Definitions converted on first reference, by the document table they
// go into.
@(private)
Svg_Def :: enum u8 {
	Server, // doc.servers
	Clip,   // doc.clips
	Mask,   // doc.masks
	Filter, // doc.filters
}

// A definition slot not looked at yet; -2 marks one being converted (a
// reference back to it is recursive), -1 one that did not convert.
@(private)
SVG_DEF_UNSEEN :: -3

// The conversion of definition `el` when it was seen before (-2 while it
// is being converted); otherwise marks it as being converted. The caller
// stores the result in `p.defs[kind][el]`.
@(private)
svg_def_seen :: proc(p: ^Svg_Parser, kind: Svg_Def, el: u32) -> (idx: i32, seen: bool) {
	slot := &p.defs[kind][el]
	if slot^ != SVG_DEF_UNSEEN {
		return slot^, true
	}
	slot^ = -2
	return -1, false
}

@(private)
svg_server :: proc(p: ^Svg_Parser, el: u32) -> i32 {
	if idx, seen := svg_def_seen(p, .Server, el); seen {
		return max(idx, -1)
	}
	idx := i32(-1)
	defer p.defs[.Server][el] = idx
	tag := svg_tag(p.x.elements[el].ident)
	chain_buf: [16]u32
	chain := chain_buf[:svg_href_chain(p, el, &chain_buf)]
	doc := p.doc
	s: Svg_Server
	s.transform = TRANSFORM_IDENTITY
	switch tag {
	case "linearGradient", "radialGradient":
		s.kind = .Linear if tag == "linearGradient" else .Radial
		units, _, _ := svg_chain_attr(p, chain, "gradientUnits")
		s.bbox_units = units != "userSpaceOnUse"
		if sp, _, ok := svg_chain_attr(p, chain, "spreadMethod"); ok {
			s.spread = .Reflect if sp == "reflect" else (.Repeat if sp == "repeat" else .Pad)
		}
		if tr, _, ok := svg_chain_attr(p, chain, "gradientTransform"); ok {
			t, tok := transform_svg(tr)
			if tok && svg_invertible(t) {
				s.transform = t
			}
		}
		coord :: proc(p: ^Svg_Parser, chain: []u32, tag, name: string, axis: int, def: string, bbox: bool) -> f32 {
			v, _, ok := svg_chain_attr(p, chain, name, tag)
			if !ok {
				v = def
			}
			l, lok := svg_parse_length(strings.trim_space(v))
			if !lok {
				l, _ = svg_parse_length(def)
			}
			if bbox {
				return l.v / 100 if l.unit == .Percent else l.v
			}
			return svg_length_px(l, svg_percent_base(p, axis), 16)
		}
		b := s.bbox_units
		if s.kind == .Linear {
			s.v = {coord(p, chain, tag, "x1", 0, "0%", b), coord(p, chain, tag, "y1", 1, "0%", b), coord(p, chain, tag, "x2", 0, "100%", b), coord(p, chain, tag, "y2", 1, "0%", b), 0, 0}
		} else {
			cx := coord(p, chain, tag, "cx", 0, "50%", b)
			cy := coord(p, chain, tag, "cy", 1, "50%", b)
			r := coord(p, chain, tag, "r", 2, "50%", b)
			_, _, has_fx := svg_chain_attr(p, chain, "fx", tag)
			_, _, has_fy := svg_chain_attr(p, chain, "fy", tag)
			fx := coord(p, chain, tag, "fx", 0, "50%", b) if has_fx else cx
			fy := coord(p, chain, tag, "fy", 1, "50%", b) if has_fy else cy
			fr := coord(p, chain, tag, "fr", 2, "0%", b)
			s.v = {cx, cy, r, fx, fy, fr}
			if r <= 0 {
				// Painted with the last stop's color (below).
			}
		}
		// Stops come from the first element of the chain that has any.
		for g in chain {
			ge := &p.x.elements[g]
			gt := svg_tag(ge.ident)
			if gt != "linearGradient" && gt != "radialGradient" {
				continue
			}
			gst := svg_style_chain(p, g)
			start := len(doc.stops)
			last: f32 = 0
			for v in ge.value {
				c, ok := v.(xml.Element_ID)
				if !ok || svg_tag(p.x.elements[c].ident) != "stop" {
					continue
				}
				ce := &p.x.elements[c]
				sst := svg_compute_style(p, c, &gst)
				off: f32
				if os, has := svg_attr(ce, "offset"); has {
					if l, lok := svg_parse_length(strings.trim_space(os)); lok && (l.unit == .None || l.unit == .Percent) {
						off = l.v / 100 if l.unit == .Percent else l.v
					}
				}
				off = clamp(off, 0, 1)
				off = max(off, last)
				last = off
				col := sst.stop_color
				col.a *= sst.stop_opacity
				append(&doc.stops, Gradient_Stop{off, col})
			}
			if len(doc.stops) > start {
				s.stops = {u32(start), u32(len(doc.stops) - start)}
				break
			}
		}
		if s.stops.count == 0 {
			return -1
		}
		degenerate := (s.kind == .Linear && s.v[0] == s.v[2] && s.v[1] == s.v[3]) || (s.kind == .Radial && s.v[2] <= 0)
		if degenerate {
			// Painted with the last stop's color.
			last_stop := doc.stops[s.stops.start + s.stops.count - 1]
			s.stops = {u32(len(doc.stops)), 1}
			append(&doc.stops, last_stop)
		}
	case "pattern":
		s.kind = .Pattern
		units, _, _ := svg_chain_attr(p, chain, "patternUnits", "pattern")
		s.bbox_units = units != "userSpaceOnUse"
		cunits, _, _ := svg_chain_attr(p, chain, "patternContentUnits", "pattern")
		s.content_bbox = cunits == "objectBoundingBox"
		if tr, _, ok := svg_chain_attr(p, chain, "patternTransform", "pattern"); ok {
			if t, tok := transform_svg(tr); tok && svg_invertible(t) {
				s.transform = t
			}
		}
		num :: proc(p: ^Svg_Parser, chain: []u32, name: string, axis: int, bbox: bool) -> f32 {
			v, _, ok := svg_chain_attr(p, chain, name, "pattern")
			if !ok {
				return 0
			}
			l, lok := svg_parse_length(strings.trim_space(v))
			if !lok {
				return 0
			}
			if bbox {
				return l.v / 100 if l.unit == .Percent else l.v
			}
			return svg_length_px(l, svg_percent_base(p, axis), 16)
		}
		b := s.bbox_units
		s.rect = {num(p, chain, "x", 0, b), num(p, chain, "y", 1, b), num(p, chain, "width", 0, b), num(p, chain, "height", 1, b)}
		if s.rect.w <= 0 || s.rect.h <= 0 {
			return -1
		}
		for g in chain {
			ge := &p.x.elements[g]
			if svg_tag(ge.ident) != "pattern" {
				continue
			}
			if vb, ok := svg_view_box(ge); ok && vb.w > 0 && vb.h > 0 {
				s.view_box = vb
				s.has_view_box = true
				s.aspect = svg_aspect(ge)
				break
			}
		}
		// Content from the first pattern of the chain with children.
		content_el := el
		for g in chain {
			ge := &p.x.elements[g]
			if svg_tag(ge.ident) != "pattern" {
				continue
			}
			has_children := false
			for v in ge.value {
				if c, ok := v.(xml.Element_ID); ok && p.x.elements[c].kind == .Element {
					has_children = true
					break
				}
			}
			if has_children {
				content_el = g
				break
			}
		}
		saved_clip := p.in_clip
		p.in_clip = false
		cst := svg_style_chain(p, content_el)
		cst.fill_decl, cst.stroke_decl, cst.visible_decl = false, false, false
		s.content = svg_new_node(p, .Group, -1)
		svg_convert_children(p, content_el, &cst, s.content)
		p.in_clip = saved_clip
	case:
		return -1
	}
	idx = i32(len(doc.servers))
	append(&doc.servers, s)
	return idx
}

// ---- clip paths and masks ---------------------------------------------------------------

@(private)
svg_clip :: proc(p: ^Svg_Parser, el: u32) -> i32 {
	if idx, seen := svg_def_seen(p, .Clip, el); seen {
		if idx == -2 {
			svg_warn(p, "recursive clip-path is skipped")
		}
		return max(idx, -1)
	}
	idx := i32(-1)
	defer p.defs[.Clip][el] = idx
	doc := p.doc
	e := &p.x.elements[el]
	st := svg_style_chain(p, el)
	c := Svg_Clip {
		transform = svg_element_transform(p, e, &st),
		clip      = -1,
		simple    = -1,
	}
	units, _ := svg_attr(e, "clipPathUnits")
	c.bbox_units = units == "objectBoundingBox"
	if st.clip_path != "" {
		if ref, ok := svg_ref(p, st.clip_path); ok {
			c.clip = svg_clip(p, ref)
		}
	}
	saved := p.in_clip
	p.in_clip = true
	c.content = svg_new_node(p, .Group, -1)
	cst := st
	cst.clip_path = ""
	svg_convert_children(p, el, &cst, c.content)
	p.in_clip = saved
	root := &doc.nodes[c.content]
	if c.clip < 0 && root.first_child >= 0 && root.first_child == root.last_child {
		k := root.first_child
		if doc.nodes[k].kind == .Shape && doc.nodes[k].clip < 0 && .Hidden not_in doc.nodes[k].flags && .Off not_in doc.nodes[k].flags {
			c.simple = k
		}
	}
	idx = i32(len(doc.clips))
	append(&doc.clips, c)
	return idx
}

@(private)
svg_mask :: proc(p: ^Svg_Parser, el: u32) -> i32 {
	if idx, seen := svg_def_seen(p, .Mask, el); seen {
		if idx == -2 {
			svg_warn(p, "recursive mask is skipped")
		}
		return max(idx, -1)
	}
	idx := i32(-1)
	defer p.defs[.Mask][el] = idx
	doc := p.doc
	e := &p.x.elements[el]
	st := svg_style_chain(p, el)
	m := Svg_Mask {
		mask = -1,
	}
	units, _ := svg_attr(e, "maskUnits")
	m.bbox_units = units != "userSpaceOnUse"
	cunits, _ := svg_attr(e, "maskContentUnits")
	m.content_bbox = cunits == "objectBoundingBox"
	m.alpha = st.mask_alpha
	if m.bbox_units {
		frac :: proc(e: ^xml.Element, name: string, def: f32) -> f32 {
			v, ok := svg_attr(e, name)
			if !ok {
				return def
			}
			l, lok := svg_parse_length(strings.trim_space(v))
			if !lok {
				return def
			}
			return l.v / 100 if l.unit == .Percent else l.v
		}
		m.rect = {frac(e, "x", -0.1), frac(e, "y", -0.1), frac(e, "width", 1.2), frac(e, "height", 1.2)}
	} else {
		vp := svg_viewport(p)
		m.rect = {
			svg_attr_length(p, e, "x", 0, -0.1 * vp.x, st.font_size),
			svg_attr_length(p, e, "y", 1, -0.1 * vp.y, st.font_size),
			svg_attr_length(p, e, "width", 0, 1.2 * vp.x, st.font_size),
			svg_attr_length(p, e, "height", 1, 1.2 * vp.y, st.font_size),
		}
	}
	if st.mask != "" {
		if ref, ok := svg_ref(p, st.mask); ok && ref != el {
			m.mask = svg_mask(p, ref)
		}
	}
	saved := p.in_clip
	p.in_clip = false
	m.content = svg_new_node(p, .Group, -1)
	cst := st
	cst.mask, cst.clip_path, cst.filter, cst.opacity = "", "", "", 1
	cst.fill_decl, cst.stroke_decl, cst.visible_decl = false, false, false
	svg_convert_children(p, el, &cst, m.content)
	p.in_clip = saved
	idx = i32(len(doc.masks))
	append(&doc.masks, m)
	return idx
}

// ---- filters --------------------------------------------------------------------------

@(private)
svg_filter_def :: proc(p: ^Svg_Parser, el: u32) -> i32 {
	if idx, seen := svg_def_seen(p, .Filter, el); seen {
		return max(idx, -1)
	}
	idx := i32(-1)
	defer p.defs[.Filter][el] = idx
	doc := p.doc
	e := &p.x.elements[el]
	st := svg_style_chain(p, el)
	f: Svg_Filter
	units, _ := svg_attr(e, "filterUnits")
	if units == "userSpaceOnUse" {
		vp := svg_viewport(p)
		f.region = {
			units = .User_Space_On_Use,
			x     = svg_attr_length(p, e, "x", 0, -0.1 * vp.x, st.font_size),
			y     = svg_attr_length(p, e, "y", 1, -0.1 * vp.y, st.font_size),
			w     = svg_attr_length(p, e, "width", 0, 1.2 * vp.x, st.font_size),
			h     = svg_attr_length(p, e, "height", 1, 1.2 * vp.y, st.font_size),
		}
	} else {
		frac :: proc(e: ^xml.Element, name: string, def: f32) -> f32 {
			v, ok := svg_attr(e, name)
			if !ok {
				return def
			}
			l, lok := svg_parse_length(strings.trim_space(v))
			if !lok {
				return def
			}
			return l.v / 100 if l.unit == .Percent else l.v
		}
		f.region = {
			units = .Object_Bounding_Box,
			x     = frac(e, "x", -0.1),
			y     = frac(e, "y", -0.1),
			w     = frac(e, "width", 1.2),
			h     = frac(e, "height", 1.2),
		}
	}
	if f.region.w <= 0 || f.region.h <= 0 {
		// An empty region filters the element away.
		return -1
	}
	pu, _ := svg_attr(e, "primitiveUnits")
	f.prim_bbox = pu == "objectBoundingBox"

	names := make(map[string]u16, 8, p.tmp)
	prim_start := len(doc.filter_prims)
	ref_start := len(doc.filter_refs)
	value_start := len(doc.filter_values)
	bitmap_start := len(doc.filter_bitmaps)
	// Appends a number list to the filter's values: (first, count).
	number_list :: proc(doc: ^Svg_Document, value_start: int, v: string) -> (first, count: u16) {
		first = u16(len(doc.filter_values) - value_start)
		sc := Svg_Scanner{s = v}
		for {
			x, ok := svg_scan_number(&sc)
			if !ok {
				break
			}
			append(&doc.filter_values, x)
		}
		svg_skip_ws(&sc)
		if sc.pos < len(sc.s) {
			// Not a plain number list: none (as usvg).
			resize(&doc.filter_values, value_start + int(first))
		}
		return first, u16(len(doc.filter_values) - value_start) - first
	}
	first := true
	ref_of :: proc(p: ^Svg_Parser, e: ^xml.Element, name: string, names: map[string]u16) -> Filter_Ref {
		v, ok := svg_attr(e, name)
		if !ok {
			return {kind = .Previous}
		}
		v = strings.trim_space(v)
		switch v {
		case "SourceGraphic":
			return {kind = .Source_Graphic}
		case "SourceAlpha":
			return {kind = .Source_Alpha}
		case "BackgroundImage", "BackgroundAlpha", "FillPaint", "StrokePaint":
			svg_warn(p, "filter input %s is not supported (SourceGraphic is used)", v)
			return {kind = .Source_Graphic}
		}
		if i, found := names[v]; found {
			return {kind = .Result, index = i}
		}
		return {kind = .Previous}
	}
	num :: proc(e: ^xml.Element, name: string, def: f32) -> f32 {
		v, ok := svg_attr(e, name)
		if !ok {
			return def
		}
		n, nok := svg_parse_number(strings.trim_space(v))
		return n if nok else def
	}
	for v in e.value {
		c, ok := v.(xml.Element_ID)
		if !ok || p.x.elements[c].kind != .Element {
			continue
		}
		ce := &p.x.elements[c]
		tag := svg_tag(ce.ident)
		pst := svg_compute_style(p, c, &st)
		if first {
			f.srgb = pst.srgb_filters
		} else if pst.srgb_filters != f.srgb {
			svg_warn(p, "mixed color-interpolation-filters in one filter are not supported")
		}
		sub: Svg_Subregion
		for name, k in ([4]string{"x", "y", "width", "height"}) {
			v, has := svg_attr(ce, name)
			if !has {
				continue
			}
			l, lok := svg_parse_length(strings.trim_space(v))
			if !lok {
				continue
			}
			if f.prim_bbox {
				sub.v[k] = l.v / 100 if l.unit == .Percent else l.v
			} else {
				sub.v[k] = svg_length_px(l, svg_percent_base(p, k % 2), st.font_size)
			}
			sub.set |= 1 << u8(k)
		}
		prim := Filter_Primitive {
			in1 = ref_of(p, ce, "in", names),
			in2 = ref_of(p, ce, "in2", names),
		}
		switch tag {
		case "feGaussianBlur", "feDropShadow":
			prim.op = .Gaussian_Blur if tag == "feGaussianBlur" else .Drop_Shadow
			def: f32 = 0 if tag == "feGaussianBlur" else 2
			sx, sy := def, def
			if s, has := svg_attr(ce, "stdDeviation"); has {
				sc := Svg_Scanner{s = s}
				if a, aok := svg_scan_number(&sc); aok {
					sx, sy = a, a
					if b, bok := svg_scan_number(&sc); bok {
						sy = b
					}
					if _, more := svg_scan_number(&sc); more {
						// More than two values: invalid, no blur.
						sx, sy = 0, 0
					}
				}
			}
			if sx < 0 || sy < 0 {
				sx, sy = 0, 0
			}
			prim.std = {sx, sy}
			if prim.op == .Drop_Shadow {
				prim.dx = num(ce, "dx", 2)
				prim.dy = num(ce, "dy", 2)
				prim.color = pst.flood_color
				prim.color.a *= pst.flood_opacity
			}
		case "feOffset":
			prim.op = .Offset
			prim.dx = num(ce, "dx", 0)
			prim.dy = num(ce, "dy", 0)
		case "feFlood":
			prim.op = .Flood
			prim.color = pst.flood_color
			prim.color.a *= pst.flood_opacity
		case "feComposite":
			prim.op = .Composite
			op, _ := svg_attr(ce, "operator")
			switch op {
			case "in":
				prim.composite = .In
			case "out":
				prim.composite = .Out
			case "atop":
				prim.composite = .Atop
			case "xor":
				prim.composite = .Xor
			case "lighter":
				prim.composite = .Lighter
			case "arithmetic":
				prim.composite = .Arithmetic
				prim.k = {num(ce, "k1", 0), num(ce, "k2", 0), num(ce, "k3", 0), num(ce, "k4", 0)}
			case:
				prim.composite = .Over
			}
		case "feBlend":
			prim.op = .Blend
			mode, _ := svg_attr(ce, "mode")
			prim.blend = svg_blend_mode(mode)
		case "feColorMatrix":
			prim.op = .Color_Matrix
			kind, _ := svg_attr(ce, "type")
			vals, _ := svg_attr(ce, "values")
			switch kind {
			case "saturate":
				s, sok := svg_parse_number(strings.trim_space(vals))
				prim.color_matrix = color_matrix_saturate(clamp(s, 0, 1e9) if sok else 1).m
			case "hueRotate":
				h, hok := svg_parse_number(strings.trim_space(vals))
				prim.color_matrix = color_matrix_hue_rotate(h if hok else 0).m
			case "luminanceToAlpha":
				prim.color_matrix = color_matrix_luminance_to_alpha().m
			case:
				prim.color_matrix = COLOR_MATRIX_IDENTITY.m
				sc := Svg_Scanner{s = vals}
				m: [20]f32
				n := 0
				for n < 20 {
					x, xok := svg_scan_number(&sc)
					if !xok {
						break
					}
					m[n] = x
					n += 1
				}
				_, extra := svg_scan_number(&sc)
				if n == 20 && !extra {
					prim.color_matrix = m
				}
			}
		case "feMerge":
			prim.op = .Merge
			prim.merge_first = u16(len(doc.filter_refs) - ref_start)
			for mv in ce.value {
				mc, mok := mv.(xml.Element_ID)
				if !mok || svg_tag(p.x.elements[mc].ident) != "feMergeNode" {
					continue
				}
				append(&doc.filter_refs, ref_of(p, &p.x.elements[mc], "in", names))
			}
			prim.merge_count = u16(len(doc.filter_refs) - ref_start) - prim.merge_first
		case "feComponentTransfer":
			prim.op = .Component_Transfer
			prim.transfer = TRANSFER_IDENTITY
			for fv in ce.value {
				fc, fok := fv.(xml.Element_ID)
				if !fok {
					continue
				}
				fe := &p.x.elements[fc]
				k := -1
				switch svg_tag(fe.ident) {
				case "feFuncR":
					k = 0
				case "feFuncG":
					k = 1
				case "feFuncB":
					k = 2
				case "feFuncA":
					k = 3
				}
				kind, has_kind := svg_attr(fe, "type")
				if k < 0 || !has_kind {
					continue
				}
				fn := TRANSFER_IDENTITY
				switch strings.trim_space(kind) {
				case "identity":
				case "table", "discrete":
					fn.kind = .Table if strings.trim_space(kind) == "table" else .Discrete
					if tv, has := svg_attr(fe, "tableValues"); has {
						fn.first, fn.count = number_list(doc, value_start, tv)
					}
				case "linear":
					fn.kind = .Linear
					fn.slope = num(fe, "slope", 1)
					fn.intercept = num(fe, "intercept", 0)
				case "gamma":
					fn.kind = .Gamma
					fn.amplitude = num(fe, "amplitude", 1)
					fn.exponent = num(fe, "exponent", 1)
					fn.offset = num(fe, "offset", 0)
				case:
					continue
				}
				prim.transfer[k] = fn
			}
		case "feMorphology":
			prim.op = .Morphology
			op, _ := svg_attr(ce, "operator")
			prim.dilate = strings.trim_space(op) == "dilate"
			// As usvg: a zero radius counts as 1, a negative one leaves
			// the default (1).
			prim.radius = {1, 1}
			if r, has := svg_attr(ce, "radius"); has {
				sc := Svg_Scanner{s = r}
				vals: [3]f32
				n := 0
				for n < 3 {
					x, xok := svg_scan_number(&sc)
					if !xok {
						break
					}
					vals[n] = x
					n += 1
				}
				rx, ry: f32
				if n == 2 {
					rx, ry = vals[0], vals[1]
				} else if n == 1 {
					rx, ry = vals[0], vals[0]
				}
				if rx == 0 {rx = 1}
				if ry == 0 {ry = 1}
				if rx > 0 && ry > 0 {
					prim.radius = {rx, ry}
				}
			}
		case "feTurbulence":
			prim.op = .Turbulence
			if bf, has := svg_attr(ce, "baseFrequency"); has {
				sc := Svg_Scanner{s = bf}
				vals: [3]f32
				n := 0
				for n < 3 {
					x, xok := svg_scan_number(&sc)
					if !xok {
						break
					}
					vals[n] = x
					n += 1
				}
				fx, fy: f32
				if n == 2 {
					fx, fy = vals[0], vals[1]
				} else if n == 1 {
					fx, fy = vals[0], vals[0]
				}
				if fx >= 0 && fy >= 0 {
					prim.base_frequency = {fx, fy}
				}
			}
			octaves := math.round(clamp(num(ce, "numOctaves", 1), 0, f32(max(i32))))
			prim.octaves = u32(budget_cap(p.budget, .Turbulence_Octaves, int(octaves)))
			prim.seed = i32(math.trunc(num(ce, "seed", 0)))
			st_, _ := svg_attr(ce, "stitchTiles")
			prim.stitch = strings.trim_space(st_) == "stitch"
			kind, _ := svg_attr(ce, "type")
			prim.fractal_noise = strings.trim_space(kind) == "fractalNoise"
		case "feDiffuseLighting", "feSpecularLighting":
			prim.op = .Diffuse_Lighting if tag == "feDiffuseLighting" else .Specular_Lighting
			prim.surface_scale = num(ce, "surfaceScale", 1)
			prim.color = pst.lighting_color
			prim.specular_exponent = 1
			valid := false
			if prim.op == .Diffuse_Lighting {
				prim.light_constant = num(ce, "diffuseConstant", 1)
				valid = true
			} else {
				prim.light_constant = num(ce, "specularConstant", 1)
				prim.specular_exponent = num(ce, "specularExponent", 1)
				valid = prim.specular_exponent >= 1 && prim.specular_exponent <= 128
			}
			found := false
			for lv in ce.value {
				lc, lok := lv.(xml.Element_ID)
				if !lok || found {
					continue
				}
				le := &p.x.elements[lc]
				lt := &prim.light
				switch svg_tag(le.ident) {
				case "feDistantLight":
					lt.kind = .Distant
					lt.azimuth = num(le, "azimuth", 0)
					lt.elevation = num(le, "elevation", 0)
				case "fePointLight", "feSpotLight":
					lt.kind = .Point if svg_tag(le.ident) == "fePointLight" else .Spot
					lt.position = {num(le, "x", 0), num(le, "y", 0), num(le, "z", 0)}
					lt.points_at = {num(le, "pointsAtX", 0), num(le, "pointsAtY", 0), num(le, "pointsAtZ", 0)}
					lt.spot_exponent = num(le, "specularExponent", 1)
					if lt.spot_exponent < 0 {
						lt.spot_exponent = 1
					}
					if ca, has := svg_attr(le, "limitingConeAngle"); has {
						lt.cone_angle, lt.has_cone = svg_parse_number(strings.trim_space(ca))
					}
				case:
					continue
				}
				found = true
			}
			if !found || !valid {
				// As usvg: an invalid primitive makes transparent black.
				prim.op = .Flood
				prim.color = {}
			}
		case "feImage":
			// Images only: an element reference makes transparent black.
			prim.op = .Flood
			prim.color = {}
			href, _ := svg_href(ce)
			if strings.has_prefix(href, "#") {
				svg_warn(p, "<feImage> referencing an element is not supported")
			} else if strings.has_prefix(href, "http:") || strings.has_prefix(href, "https:") {
				svg_warn(p, "<feImage> external URLs are not loaded")
			} else if href != "" {
				bm, svg_data := svg_bitmap(p, href)
				if svg_data != nil {
					svg_warn(p, "<feImage> with an SVG image is not supported")
				} else if bm >= 0 {
					prim.op = .Image
					prim.image = u16(len(doc.filter_bitmaps) - bitmap_start)
					append(&doc.filter_bitmaps, bm)
					a := svg_aspect(ce)
					prim.image_align = a.align
					prim.image_fit = .None if a.none else (.Slice if a.slice else .Meet)
				}
			}
		case "feTile":
			prim.op = .Tile
		case "feDisplacementMap":
			prim.op = .Displacement_Map
			prim.scale = num(ce, "scale", 0)
			for name, k in ([2]string{"xChannelSelector", "yChannelSelector"}) {
				v, _ := svg_attr(ce, name)
				switch strings.trim_space(v) {
				case "R":
					prim.channels[k] = 0
				case "G":
					prim.channels[k] = 1
				case "B":
					prim.channels[k] = 2
				case:
					prim.channels[k] = 3
				}
			}
		case "feConvolveMatrix":
			prim.op = .Convolve_Matrix
			ox, oy := 3, 3
			if o, has := svg_attr(ce, "order"); has {
				sc := Svg_Scanner{s = o}
				x, xok := svg_scan_number(&sc)
				y, yok := svg_scan_number(&sc)
				xi := int(x) if xok else 3
				yi := int(y) if yok else xi
				if xi > 0 && yi > 0 {
					ox, oy = xi, yi
				}
			}
			order_ok := ox <= 255 && oy <= 255
			sum: f32
			if km, has := svg_attr(ce, "kernelMatrix"); has && order_ok {
				mark := len(doc.filter_values)
				prim.kernel_first, prim.kernel_count = number_list(doc, value_start, km)
				if int(prim.kernel_count) != ox * oy {
					resize(&doc.filter_values, mark)
					prim.kernel_count = 0
				}
				for k in doc.filter_values[mark:] {
					sum += k
				}
			}
			sum = math.round(sum * 1e6) / 1e6
			if sum == 0 {
				sum = 1
			}
			prim.divisor = num(ce, "divisor", sum)
			prim.bias = num(ce, "bias", 0)
			target :: proc(e: ^xml.Element, name: string, order: int) -> (int, bool) {
				v, has := svg_attr(e, name)
				t := order / 2
				if has {
					n, nok := svg_parse_number(strings.trim_space(v))
					if nok {
						t = int(n)
					}
				}
				return t, t >= 0 && t < order
			}
			tx, txok := target(ce, "targetX", ox)
			ty, tyok := target(ce, "targetY", oy)
			edge, _ := svg_attr(ce, "edgeMode")
			switch strings.trim_space(edge) {
			case "none":
				prim.edge = .None
			case "wrap":
				prim.edge = .Wrap
			}
			pa, _ := svg_attr(ce, "preserveAlpha")
			prim.preserve_alpha = strings.trim_space(pa) == "true"
			if order_ok && txok && tyok {
				prim.order = {u8(ox), u8(oy)}
				prim.target = {u8(tx), u8(ty)}
				if ox * oy > CONVOLVE_MAX_KERNEL {
					svg_warn(p, "feConvolveMatrix with more than %d kernel values is not supported", CONVOLVE_MAX_KERNEL)
				}
			}
			if !order_ok || !txok || !tyok || prim.kernel_count == 0 || prim.divisor == 0 {
				prim.op = .Flood
				prim.color = {}
			}
		case:
			svg_warn(p, "<%s> is not supported (skipped)", tag)
			continue
		}
		if budget_over(p.budget, .Filter_Primitives, len(doc.filter_prims) - prim_start + 1) {
			break
		}
		first = false
		if r, has := svg_attr(ce, "result"); has && r != "" {
			names[r] = u16(len(doc.filter_prims) - prim_start)
		}
		append(&doc.filter_prims, prim)
		append(&doc.filter_subs, sub)
		if sub.set != 0 {
			f.subregions = true
		}
	}
	f.primitives = {u32(prim_start), u32(len(doc.filter_prims) - prim_start)}
	f.refs = {u32(ref_start), u32(len(doc.filter_refs) - ref_start)}
	f.values = {u32(value_start), u32(len(doc.filter_values) - value_start)}
	f.bitmaps = {u32(bitmap_start), u32(len(doc.filter_bitmaps) - bitmap_start)}
	idx = i32(len(doc.filters))
	append(&doc.filters, f)
	return idx
}

// ---- finishing --------------------------------------------------------------------------

// Bounding boxes bottom-up, then filters that scale with them.
@(private)
svg_finish :: proc(p: ^Svg_Parser) {
	doc := p.doc
	#reverse for &n in doc.nodes {
		// display="none" kept for overrides (Off) is not in its parent's
		// box (SVG: no box), visibility="hidden" is.
		if n.parent >= 0 && n.bbox.w >= 0 && .Off not_in n.flags {
			par := &doc.nodes[n.parent]
			par.bbox = svg_box_union(par.bbox, svg_rect_transform(n.bbox, n.transform))
		}
	}
	for &n in doc.nodes {
		if n.filter < 0 || !(doc.filters[n.filter].prim_bbox || doc.filters[n.filter].subregions) {
			continue
		}
		// Lengths in bounding-box fractions (primitiveUnits =
		// "objectBoundingBox") and subregions depend on the element: it
		// gets its own resolved copy.
		f := doc.filters[n.filter]
		start := len(doc.filter_prims)
		bw, bh := max(n.bbox.w, 0), max(n.bbox.h, 0)
		region := f.region
		region.bbox = n.bbox
		rr, _ := filter_region_rect(region)
		for i in f.primitives.start ..< f.primitives.start + f.primitives.count {
			prim := doc.filter_prims[i]
			sub := doc.filter_subs[i]
			if f.prim_bbox {
				prim.std = {prim.std.x * bw, prim.std.y * bh}
				prim.dx *= bw
				prim.dy *= bh
				prim.radius *= {bw, bh}
				prim.scale *= (bw + bh) / 2
				for k in 0 ..< 4 {
					if sub.set & (1 << u8(k)) != 0 {
						origin := n.bbox.x if k == 0 else n.bbox.y
						sub.v[k] = (origin if k < 2 else 0) + sub.v[k] * (bw if k % 2 == 0 else bh)
					}
				}
			}
			if sub.set != 0 {
				r := rr
				if sub.set & 1 != 0 {r.x = sub.v[0]}
				if sub.set & 2 != 0 {r.y = sub.v[1]}
				if sub.set & 4 != 0 {r.w = sub.v[2]}
				if sub.set & 8 != 0 {r.h = sub.v[3]}
				prim.subregion = r
				prim.has_subregion = true
			}
			append(&doc.filter_prims, prim)
			append(&doc.filter_subs, Svg_Subregion{})
		}
		f.primitives = {u32(start), f.primitives.count}
		f.prim_bbox = false
		f.subregions = false
		n.filter = i32(len(doc.filters))
		append(&doc.filters, f)
	}
	shrink(&doc.nodes)
}
