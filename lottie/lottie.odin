package lottie

import "core:encoding/base64"
import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:strings"

import vg ".."

// Lottie (Bodymovin JSON) import: `parse` turns an After Effects
// export into a `Document`, flat tables referenced by index:
// compositions (the root and precomp assets), layers, shape items,
// transforms, masks and animatable properties, whose keyframes and values
// are stored once. `draw` (draw.odin) evaluates it at a frame
// and issues canvas and layer calls.
//
// Supported: precomp, solid, image, null and shape layers; parenting, in /
// out points, start time, time stretch, time remapping; transforms (anchor,
// position incl. separated x / y, scale, rotation, opacity, skew); track
// mattes (alpha, luma, inverted); masks (add, subtract, intersect, inverted,
// opacity, expansion); blend modes. Shapes: group, rect, ellipse, path,
// polystar, fill, stroke (dashes), gradient fill / stroke (linear, radial
// with highlight, color and opacity stops), trim paths, repeater. Keyframes
// with temporal bezier easing, hold keyframes, spatial bezier position,
// split dimensions; markers. Layer effects: fill, tint, tritone, drop
// shadow and gaussian blur (as layer filters). Text layers: text document
// keyframes (font, size, colours, justification, tracking, line height,
// baseline shift, box text) laid out with the host's fonts, and text
// animators (range selectors; position, scale, rotation, skew, opacity,
// fill / stroke colour and width, tracking). Other effects, layer styles,
// round corners and the other shape modifiers, text on a path, embedded
// glyphs, 3D and expressions are skipped with a warning in
// `Document.warnings` (expressions keep their keyframed values).

// An animatable value. Static values have no keys; `value` then indexes
// `Document.values` (`dims` floats) or, for paths, `paths`.
Prop :: struct {
	keys:  vg.Range,
	value: u32,
	dims:  u16,
}

NONE :: max(u32)

Key :: struct {
	// Frame (of the composition holding the property's layer).
	t:         f32,
	// Into values (dims floats) or paths: the value at `t`.
	value:     u32,
	// Into values: out x, out y, in x, in y of the segment to the next key,
	// for `ease_dims` dimensions (the last one serves the rest); NONE
	// is linear.
	ease:      u32,
	ease_dims: u16,
	hold:      bool,
	// Into values: the spatial out tangent then in tangent (2 floats each,
	// relative to this and the next value), or NONE.
	spatial:   u32,
}

// A bezier path: `count` vertices in `Document.points`, three points
// each (vertex, in tangent, out tangent; tangents relative to the vertex).
Path :: struct {
	start:  u32,
	count:  u32,
	closed: bool,
}

Transform :: struct {
	// Into props, -1 for absent. Position is either `position` or the
	// separated `position_x` / `position_y`.
	anchor:        i32,
	position:      i32,
	position_x:    i32,
	position_y:    i32,
	scale:         i32,
	rotation:      i32,
	opacity:       i32,
	skew:          i32,
	skew_axis:     i32,
	// Repeater only.
	start_opacity: i32,
	end_opacity:   i32,
}

Shape_Kind :: enum u8 {
	Group,
	Rect,
	Ellipse,
	Path,
	Star,
	Fill,
	Stroke,
	Gradient_Fill,
	Gradient_Stroke,
	Trim,
	Repeater,
	// Merge paths: the geometry above it in its scope combined into one
	// (its mode in `stops`: 1 merge, 2 add, 3 subtract, 4 intersect, 5
	// exclude intersections).
	Merge,
	// Skipped (warned) items.
	Ignored,
}

Shape_Flag :: enum u8 {
	Hidden,
	// Direction 3: drawn counter-clockwise.
	Reversed,
	// Polystar: polygon rather than star.
	Polygon,
	// Gradient: radial rather than linear.
	Radial,
	Even_Odd,
	// Trim: one path along all the shapes (Individually) rather than each.
	Trim_Sequential,
	// Repeater: copies stack below the previous ones.
	Repeat_Below,
}

Shape_Flags :: bit_set[Shape_Flag;u8]

// Property slots of a shape item (`Shape.props`), by kind.
POSITION :: 0 // rect, ellipse, polystar: center
SIZE :: 1 // rect, ellipse
ROUNDNESS :: 2 // rect
PATH :: 0 // path
STAR_ROTATION :: 1
STAR_POINTS :: 2
STAR_INNER_RADIUS :: 3
STAR_INNER_ROUNDNESS :: 4
STAR_OUTER_RADIUS :: 5
STAR_OUTER_ROUNDNESS :: 6
COLOR :: 0 // fill, stroke: color; gradients: the stop array
OPACITY :: 1
WIDTH :: 2
START :: 3 // gradients: start / end points
END :: 4
HIGHLIGHT :: 5
HIGHLIGHT_ANGLE :: 6
TRIM_START :: 0
TRIM_END :: 1
TRIM_OFFSET :: 2
COPIES :: 0 // repeater
COPY_OFFSET :: 1

// One item of a shape layer's tree. A group's children are contiguous
// (`children`, in AE order: the first is on top).
Shape :: struct {
	kind:      Shape_Kind,
	flags:     Shape_Flags,
	cap:       vg.Line_Cap,
	join:      vg.Line_Join,
	// Gradients: the number of color stops. Groups: how many paints their
	// tree has (more than one overlap: group opacity needs a layer).
	stops:     u16,
	paints:    u16,
	miter:     f32,
	children:  vg.Range,
	// Group, repeater: into transforms, or -1.
	transform: i32,
	// Into dashes.
	dash:      vg.Range,
	props:     [7]i32,
}

Dash :: struct {
	prop:   i32,
	// The dash offset rather than a dash or gap length.
	offset: bool,
}

Mask_Mode :: enum u8 {
	Add,
	Subtract,
	Intersect,
	None,
}

Mask :: struct {
	mode:      Mask_Mode,
	inverted:  bool,
	// Into props, -1 for absent.
	path:      i32,
	opacity:   i32,
	expansion: i32,
}

Layer_Kind :: enum u8 {
	Precomp,
	Solid,
	Image,
	Null,
	Shape,
	// `ref` indexes texts.
	Text,
	// Camera, audio, ...: draws nothing.
	Other,
}

Matte :: enum u8 {
	None,
	Alpha,
	Alpha_Inverted,
	Luma,
	Luma_Inverted,
}

Layer :: struct {
	kind:        Layer_Kind,
	blend:       vg.Blend_Mode,
	matte:       Matte,
	hidden:      bool,
	// A track matte of another layer: drawn only as that layer's matte.
	matte_source: bool,
	// Into layers (absolute), or -1.
	parent:      i32,
	matte_layer: i32,
	// In / out points (comp frames) and start time.
	in_frame:    f32,
	out_frame:   f32,
	start:       f32,
	stretch:     f32,
	transform:   i32,
	shapes:      vg.Range,
	masks:       vg.Range,
	// Into effects, applied in order.
	effects:     vg.Range,
	// Precomp: into comps; image: into bitmaps; text: into texts; -1 if
	// missing.
	ref:         i32,
	// Precomp: time remap (seconds) in props, or -1.
	time_remap:  i32,
	// Precomp / solid / image size (image: the asset's, 0 for the bitmap's).
	w, h:        f32,
	color:       vg.Color,
	// Shape layers: how many paints the shapes have.
	paints:      u16,
	name:        string,
}

Effect_Kind :: enum u8 {
	Tint,
	Fill,
	Tritone,
	Drop_Shadow,
	Gaussian_Blur,
}

// A layer effect (`ef`): the controls its kind reads (EFFECTS), as
// props in `effect_params`, one per slot of the kind's table row (-1 for a
// control the file leaves out).
Effect :: struct {
	kind:   Effect_Kind,
	params: vg.Range,
}

// At most this many effects per layer apply (each is a filter layer).
MAX_EFFECTS :: 4

// The most controls an effect kind reads.
EFFECT_MAX_PARAMS :: 5

// One control an effect reads: its index in the effect's `ef` list and its
// value when the file leaves it out.
Effect_Param :: struct {
	control: u8,
	default: [4]f32,
}

// An effect kind: its After Effects type number (`ty`) and the controls it
// reads, by slot.
Effect_Info :: struct {
	type_id: i32,
	count:   u8,
	params:  [EFFECT_MAX_PARAMS]Effect_Param,
}

EFFECTS :: [Effect_Kind]Effect_Info {
	// Black and white mapped to, amount (%).
	.Tint          = {20, 3, {{0, {0, 0, 0, 1}}, {1, {1, 1, 1, 1}}, {2, {100, 0, 0, 0}}, {}, {}}},
	// Colour, opacity (0..1).
	.Fill          = {21, 2, {{2, {1, 0, 0, 1}}, {6, {1, 0, 0, 0}}, {}, {}, {}}},
	// Shadows, midtones, highlights.
	.Tritone       = {23, 3, {{2, {0, 0, 0, 1}}, {1, {0.5, 0.5, 0.5, 1}}, {0, {1, 1, 1, 1}}, {}, {}}},
	// Colour, opacity (0..255), direction (degrees), distance, softness.
	.Drop_Shadow   = {25, 5, {{0, {0, 0, 0, 1}}, {1, {255, 0, 0, 0}}, {2, {135, 0, 0, 0}}, {3, {5, 0, 0, 0}}, {4, {}}}},
	// Blurriness, dimensions (1 both, 2 horizontal, 3 vertical).
	.Gaussian_Blur = {29, 2, {{0, {}}, {1, {1, 0, 0, 0}}, {}, {}, {}}},
}

// A font of the `fonts` list: text documents name it by `name`; drawn
// with the host collection's face for `family` and `style`.
Font :: struct {
	name:   string,
	family: string,
	weight: int,
	italic: bool,
	// Ascent in percent of the size (box text's first baseline), 0 when
	// absent.
	ascent: f32,
}

Justify :: enum u8 {
	Left,
	Right,
	Center,
}

// One text document keyframe value (`t.d.k[i].s`).
Text_Doc :: struct {
	text:           string,
	// Into fonts, or -1.
	font:           i32,
	size:           f32,
	line_height:    f32,
	// Thousandths of an em between letters.
	tracking:       f32,
	baseline_shift: f32,
	stroke_width:   f32,
	fill, stroke:   vg.Color,
	has_fill:       bool,
	has_stroke:     bool,
	// Stroke drawn over the fill (else under it).
	stroke_over:    bool,
	all_caps:       bool,
	justify:        Justify,
	// Box text: lines wrap at `box_size.x`, the box's top left at `box_pos`.
	has_box:        bool,
	box_size:       vg.Vec2,
	box_pos:        vg.Vec2,
}

Text_Key :: struct {
	t:   f32,
	doc: u32,
}

// A text layer's data: its document keyframes, animators and the anchor
// point grouping (`t.m`).
Text :: struct {
	keys:      vg.Range,
	animators: vg.Range,
	// 1 characters, 2 words, 3 lines, 4 all.
	grouping:  u8,
	// Grouping alignment (percent), a prop or -1.
	alignment: i32,
}

Selector_Shape :: enum u8 {
	Square = 1,
	Ramp_Up,
	Ramp_Down,
	Triangle,
	Round,
	Smooth,
}

// A text animator (`t.a[i]`): a range selector and the properties it
// animates (props, -1 when absent; values as in the file: percent for
// scale and opacity, degrees for rotation).
Text_Animator :: struct {
	// Range selector: 1 characters, 2 characters excluding spaces, 3
	// words, 4 lines.
	based_on:    u8,
	shape:       Selector_Shape,
	// Start / end / offset in indices rather than percent.
	index_units: bool,
	// Into props, -1 when absent.
	props:       [Animator_Prop]i32,
}

// A text animator's properties: its range selector's, then the letter
// properties it animates.
Animator_Prop :: enum u8 {
	Start,
	End,
	Offset,
	Amount,
	Ease_High,
	Ease_Low,
	Smoothness,
	Anchor,
	Position,
	Scale,
	Rotation,
	Skew,
	Skew_Axis,
	Opacity,
	Fill,
	Stroke,
	Stroke_Width,
	Tracking,
}

// Where each animator property is in the file (the selector object "s" or
// the properties object "a") and its value when absent.
Animator_Prop_Info :: struct {
	key:      string,
	selector: bool,
	default:  [4]f32,
}

ANIMATOR_PROPS :: [Animator_Prop]Animator_Prop_Info {
	.Start        = {"s", true, {}},
	.End          = {"e", true, {100, 0, 0, 0}},
	.Offset       = {"o", true, {}},
	.Amount       = {"a", true, {100, 0, 0, 0}},
	.Ease_High    = {"xe", true, {}},
	.Ease_Low     = {"ne", true, {}},
	.Smoothness   = {"sm", true, {100, 0, 0, 0}},
	.Anchor       = {"a", false, {}},
	.Position     = {"p", false, {}},
	.Scale        = {"s", false, {100, 100, 0, 0}},
	.Rotation     = {"r", false, {}},
	.Skew         = {"sk", false, {}},
	.Skew_Axis    = {"sa", false, {}},
	.Opacity      = {"o", false, {100, 0, 0, 0}},
	.Fill         = {"fc", false, {0, 0, 0, 1}},
	.Stroke       = {"sc", false, {0, 0, 0, 1}},
	.Stroke_Width = {"sw", false, {}},
	.Tracking     = {"t", false, {}},
}

Comp :: struct {
	layers: vg.Range,
	w, h:   f32,
}

Marker :: struct {
	name:     string,
	frame:    f32,
	duration: f32,
}

Document :: struct {
	width, height: f32,
	// Frames per second; the animation runs from `in_frame` to `out_frame`.
	fps:           f32,
	in_frame:      f32,
	out_frame:     f32,
	// comps[0] is the root composition.
	comps:         [dynamic]Comp,
	layers:        [dynamic]Layer,
	shapes:        [dynamic]Shape,
	transforms:    [dynamic]Transform,
	masks:         [dynamic]Mask,
	dashes:        [dynamic]Dash,
	props:         [dynamic]Prop,
	keys:          [dynamic]Key,
	values:        [dynamic]f32,
	paths:         [dynamic]Path,
	points:        [dynamic]vg.Vec2,
	bitmaps:       [dynamic]vg.Bitmap,
	markers:       [dynamic]Marker,
	effects:       [dynamic]Effect,
	effect_params: [dynamic]i32,
	fonts:         [dynamic]Font,
	texts:         [dynamic]Text,
	text_keys:     [dynamic]Text_Key,
	text_docs:     [dynamic]Text_Doc,
	animators:     [dynamic]Text_Animator,
	// Unsupported features met while parsing (unique).
	warnings:      [dynamic]string,
	// The parse options' limits, which bound each draw too.
	limits:        vg.Limits,
	// Some layer blends with its backdrop: begin the layer stack with a
	// root layer when drawing onto the screen.
	uses_blend:    bool,
	// Owns the strings.
	arena:         ^virtual.Arena,
	allocator:     mem.Allocator,
}

Error :: enum u8 {
	None,
	Json,
	// Valid JSON without "v" and "layers".
	Not_Lottie,
	Out_Of_Memory,
	// JSON nested deeper than the Depth limit.
	Too_Deep,
}

Parse_Options :: struct {
	// Reads an image asset that is not a data: URI (its "u" + "p", e.g.
	// relative to the JSON): its bytes, allocated with `allocator`
	// (scratch, freed after parsing).
	load_file: proc(user: rawptr, path: string, allocator: mem.Allocator) -> (data: []u8, ok: bool),
	user:      rawptr,
	// Bounds on the work the file can cause, parsing and drawing
	// (limits.odin); nil is DEFAULT_LIMITS.
	limits:    ^vg.Limits,
}

destroy :: proc(doc: ^Document) {
	context.allocator = doc.allocator
	for b in doc.bitmaps {
		delete(b.pixels)
	}
	delete(doc.comps)
	delete(doc.layers)
	delete(doc.shapes)
	delete(doc.transforms)
	delete(doc.masks)
	delete(doc.dashes)
	delete(doc.props)
	delete(doc.keys)
	delete(doc.values)
	delete(doc.paths)
	delete(doc.points)
	delete(doc.bitmaps)
	delete(doc.markers)
	delete(doc.effects)
	delete(doc.effect_params)
	delete(doc.fonts)
	delete(doc.texts)
	delete(doc.text_keys)
	delete(doc.text_docs)
	delete(doc.animators)
	delete(doc.warnings)
	if doc.arena != nil {
		virtual.arena_destroy(doc.arena)
		free(doc.arena)
	}
	doc^ = {}
}

// Whether `data` looks like a Lottie file: a JSON object with "v" and
// "layers" near its start (cheap; `parse` decides).
sniff :: proc(data: []u8) -> bool {
	head := string(data[:min(len(data), 4096)])
	i := 0
	for i < len(head) && (head[i] == ' ' || head[i] == '\t' || head[i] == '\n' || head[i] == '\r' || head[i] == 0xef || head[i] == 0xbb || head[i] == 0xbf) {
		i += 1
	}
	if i >= len(head) || head[i] != '{' {
		return false
	}
	return strings.contains(head, "\"v\"") && strings.contains(string(data), "\"layers\"")
}

// The frame `seconds` into the animation.
frame_at :: proc "contextless" (doc: ^Document, seconds: f32) -> f32 {
	return doc.in_frame + seconds * doc.fps
}

// The animation's length in seconds.
duration :: proc "contextless" (doc: ^Document) -> f32 {
	return (doc.out_frame - doc.in_frame) / doc.fps if doc.fps > 0 else 0
}

parse :: proc(data: []u8, opts: Parse_Options = {}, allocator := context.allocator) -> (doc: Document, err: Error) {
	context.allocator = allocator
	doc.allocator = allocator
	doc.arena = new(virtual.Arena)
	if virtual.arena_init_growing(doc.arena) != nil {
		free(doc.arena)
		doc.arena = nil
		return doc, .Out_Of_Memory
	}
	scratch: virtual.Arena
	if virtual.arena_init_growing(&scratch) != nil {
		destroy(&doc)
		return doc, .Out_Of_Memory
	}
	defer virtual.arena_destroy(&scratch)
	tmp := virtual.arena_allocator(&scratch)

	budget: vg.Budget
	vg.budget_init(&budget, opts.limits)
	doc.limits = budget.limits
	// core:encoding/json recurses per nesting level.
	if json_too_deep(data, budget.limits[.Depth]) {
		destroy(&doc)
		return doc, .Too_Deep
	}
	root_value, jerr := json.parse(data, .JSON, false, tmp)
	if jerr != nil {
		destroy(&doc)
		return doc, .Json
	}
	root, is_obj := root_value.(json.Object)
	if !is_obj || "layers" not_in root || "v" not_in root {
		destroy(&doc)
		return doc, .Not_Lottie
	}
	p := Parser {
		doc    = &doc,
		sa     = virtual.arena_allocator(doc.arena),
		tmp    = tmp,
		opts   = opts,
		budget = budget,
	}
	p.warned = make(map[string]bool, 16, tmp)
	p.assets = make(map[string]Asset_Ref, 16, tmp)

	doc.width = lj_num(root, "w", 0)
	doc.height = lj_num(root, "h", 0)
	doc.fps = lj_num(root, "fr", 30)
	if doc.fps <= 0 {
		doc.fps = 30
	}
	doc.in_frame = lj_num(root, "ip", 0)
	doc.out_frame = lj_num(root, "op", doc.in_frame)
	if lj_num(root, "ddd", 0) == 1 {
		warn(&p, "3D compositions are drawn flat")
	}

	for fv in lj_array(lj_obj(root, "fonts"), "list") {
		fo, ok := fv.(json.Object)
		if !ok {
			continue
		}
		weight, italic := font_style(lj_str(fo, "fStyle"))
		append(&doc.fonts, Font{
			name   = strings.clone(lj_str(fo, "fName"), p.sa),
			family = strings.clone(lj_str(fo, "fFamily"), p.sa),
			weight = weight,
			italic = italic,
			ascent = lj_num(fo, "ascent", 0),
		})
	}
	if len(lj_array(root, "chars")) > 0 {
		warn(&p, "embedded glyphs (chars) are drawn with fonts instead")
	}

	// Comp 0 is the root; precomp assets get their indices before any
	// layers parse (layers reference them).
	append(&doc.comps, Comp{w = doc.width, h = doc.height})
	assets := lj_array(root, "assets")
	for a in assets {
		ao, ok := a.(json.Object)
		if !ok {
			continue
		}
		id := lj_str(ao, "id")
		if _, has_layers := ao["layers"]; has_layers {
			p.assets[id] = {comp = i32(len(doc.comps)), bitmap = -1}
			append(&doc.comps, Comp{w = lj_num(ao, "w", 0), h = lj_num(ao, "h", 0)})
		} else if _, has_path := ao["p"]; has_path {
			p.assets[id] = {comp = -1, bitmap = load_image(&p, ao), w = lj_num(ao, "w", 0), h = lj_num(ao, "h", 0)}
		}
	}
	parse_layers(&p, 0, lj_array(root, "layers"))
	for a in assets {
		ao, ok := a.(json.Object)
		if !ok {
			continue
		}
		if ref, found := p.assets[lj_str(ao, "id")]; found && ref.comp > 0 {
			parse_layers(&p, ref.comp, lj_array(ao, "layers"))
		}
	}
	for m in lj_array(root, "markers") {
		mo, ok := m.(json.Object)
		if !ok {
			continue
		}
		append(&doc.markers, Marker{strings.clone(lj_str(mo, "cm"), p.sa), lj_num(mo, "tm", 0), lj_num(mo, "dr", 0)})
	}
	vg.budget_warn(&p.budget, &doc.warnings, p.sa)
	return doc, nil
}

// Whether JSON arrays and objects nest deeper than `limit` (strings
// skipped; malformed input is left to the parser).
@(private)
json_too_deep :: proc(data: []u8, limit: int) -> bool {
	depth := 0
	in_str := false
	for i := 0; i < len(data); i += 1 {
		ch := data[i]
		if in_str {
			if ch == '\\' {
				i += 1
			} else if ch == '"' {
				in_str = false
			}
			continue
		}
		switch ch {
		case '"':
			in_str = true
		case '[', '{':
			if depth += 1; depth > limit {
				return true
			}
		case ']', '}':
			depth -= 1
		}
	}
	return false
}

@(private)
Asset_Ref :: struct {
	comp:   i32,
	bitmap: i32,
	// An image asset's size in the composition (the bitmap stretches to it).
	w, h:   f32,
}

@(private)
Parser :: struct {
	doc:    ^Document,
	// The document's string arena.
	sa:     mem.Allocator,
	tmp:    mem.Allocator,
	opts:   Parse_Options,
	warned: map[string]bool,
	assets: map[string]Asset_Ref,
	budget: vg.Budget,
	// Shape groups being parsed.
	depth:  int,
}

@(private)
warn :: proc(p: ^Parser, format: string, args: ..any) {
	msg := fmt.tprintf(format, ..args)
	if msg in p.warned {
		return
	}
	owned := strings.clone(msg, p.sa)
	p.warned[owned] = true
	append(&p.doc.warnings, owned)
}

// ---- JSON access -------------------------------------------------------------------

@(private)
lj_value_num :: proc "contextless" (v: json.Value) -> (f32, bool) {
	#partial switch x in v {
	case json.Float:
		return f32(x), true
	case json.Integer:
		return f32(x), true
	case json.Boolean:
		return 1 if x else 0, true
	}
	return 0, false
}

@(private)
lj_num :: proc(o: json.Object, key: string, def: f32) -> f32 {
	if v, ok := o[key]; ok {
		if n, is_num := lj_value_num(v); is_num {
			return n
		}
		// A one-element array (old exports) or a static property.
		if arr, is_arr := v.(json.Array); is_arr && len(arr) > 0 {
			if n, is_num := lj_value_num(arr[0]); is_num {
				return n
			}
		}
		if po, is_obj := v.(json.Object); is_obj {
			return lj_num(po, "k", def)
		}
	}
	return def
}

@(private)
lj_str :: proc(o: json.Object, key: string) -> string {
	if s, ok := o[key].(json.String); ok {
		return s
	}
	return ""
}

@(private)
lj_array :: proc(o: json.Object, key: string) -> json.Array {
	if a, ok := o[key].(json.Array); ok {
		return a
	}
	return nil
}

@(private)
lj_obj :: proc(o: json.Object, key: string) -> json.Object {
	if a, ok := o[key].(json.Object); ok {
		return a
	}
	return nil
}

@(private)
lj_has :: proc(o: json.Object, key: string) -> bool {
	_, ok := o[key]
	return ok
}

// ---- assets ------------------------------------------------------------------------

@(private)
load_image :: proc(p: ^Parser, ao: json.Object) -> i32 {
	doc := p.doc
	name := lj_str(ao, "p")
	bytes: []u8
	if strings.has_prefix(name, "data:") {
		comma := strings.index_byte(name, ',')
		if comma < 0 || !strings.contains(name[:comma], "base64") {
			warn(p, "image asset with an unsupported data URI")
			return -1
		}
		decoded, derr := base64.decode(name[comma + 1:], allocator = p.tmp)
		if derr != nil {
			warn(p, "image asset with broken base64 data")
			return -1
		}
		bytes = decoded
	} else {
		if p.opts.load_file == nil {
			warn(p, "image asset %q can not be loaded (no file loader)", name)
			return -1
		}
		path := strings.concatenate({lj_str(ao, "u"), name}, p.tmp)
		ok: bool
		bytes, ok = p.opts.load_file(p.opts.user, path, p.tmp)
		if !ok {
			warn(p, "image asset %q not found", path)
			return -1
		}
	}
	pixels, w, h, ok := vg.decode_image(bytes, doc.allocator, &p.budget)
	if !ok {
		warn(p, "image asset %q does not decode", name)
		return -1
	}
	append(&doc.bitmaps, vg.Bitmap{pixels, w, h})
	return i32(len(doc.bitmaps) - 1)
}

// ---- layers ------------------------------------------------------------------------

@(private)
parse_layers :: proc(p: ^Parser, comp: i32, arr: json.Array) {
	doc := p.doc
	first := u32(len(doc.layers))
	// Layer "ind" -> absolute index, for parents and mattes.
	by_ind := make(map[i32]i32, len(arr), p.tmp)
	parents := make([]i32, len(arr), p.tmp)
	matte_parents := make([]i32, len(arr), p.tmp)
	for v, i in arr {
		lo, _ := v.(json.Object)
		l := parse_layer(p, lo)
		idx := i32(len(doc.layers))
		append(&doc.layers, l)
		if lj_has(lo, "ind") {
			by_ind[i32(lj_num(lo, "ind", 0))] = idx
		}
		parents[i] = i32(lj_num(lo, "parent", -1)) if lj_has(lo, "parent") else min(i32)
		matte_parents[i] = i32(lj_num(lo, "tp", -1)) if lj_has(lo, "tp") else min(i32)
	}
	doc.comps[comp].layers = {first, u32(len(arr))}
	for i in 0 ..< len(arr) {
		l := &doc.layers[first + u32(i)]
		if parents[i] != min(i32) {
			if pi, ok := by_ind[parents[i]]; ok && pi != i32(first) + i32(i) {
				l.parent = pi
			}
		}
		if l.matte == .None {
			continue
		}
		if matte_parents[i] != min(i32) {
			if mi, ok := by_ind[matte_parents[i]]; ok {
				l.matte_layer = mi
				doc.layers[mi].matte_source = true
			}
		} else if i > 0 {
			// Older files: the layer above, flagged td.
			l.matte_layer = i32(first) + i32(i) - 1
		}
	}
}

@(private)
parse_layer :: proc(p: ^Parser, lo: json.Object) -> (l: Layer) {
	doc := p.doc
	l.parent, l.matte_layer, l.ref, l.time_remap, l.transform = -1, -1, -1, -1, -1
	l.name = strings.clone(lj_str(lo, "nm"), p.sa)
	l.in_frame = lj_num(lo, "ip", 0)
	l.out_frame = lj_num(lo, "op", 0)
	l.start = lj_num(lo, "st", 0)
	l.stretch = lj_num(lo, "sr", 1)
	if l.stretch == 0 {
		l.stretch = 1
	}
	l.hidden = lj_num(lo, "hd", 0) != 0
	l.matte_source = lj_num(lo, "td", 0) != 0
	tt := int(lj_num(lo, "tt", 0))
	if tt >= 1 && tt <= 4 {
		l.matte = Matte(tt)
	}
	bm := int(lj_num(lo, "bm", 0))
	switch {
	case bm > 0 && bm <= int(max(vg.Blend_Mode)):
		l.blend = vg.Blend_Mode(bm)
		doc.uses_blend = true
	case bm > int(max(vg.Blend_Mode)):
		warn(p, "blend mode %d (add / hard mix) is drawn as normal", bm)
	}
	if lj_num(lo, "ddd", 0) != 0 {
		warn(p, "3D layers are drawn flat")
	}
	if lj_num(lo, "ao", 0) != 0 {
		warn(p, "auto-orient is not supported")
	}
	l.effects = parse_effects(p, lj_array(lo, "ef"))
	if len(lj_array(lo, "sy")) > 0 {
		warn(p, "layer styles are not supported")
	}
	if ks := lj_obj(lo, "ks"); ks != nil {
		l.transform = parse_transform(p, ks)
	}
	masks := lj_array(lo, "masksProperties")
	l.masks.start = u32(len(doc.masks))
	for mv in masks {
		mo, ok := mv.(json.Object)
		if !ok {
			continue
		}
		m := Mask {
			inverted  = lj_num(mo, "inv", 0) != 0,
			path      = parse_prop(p, mo["pt"], .Path),
			opacity   = parse_prop(p, mo["o"], .Number),
			expansion = parse_prop(p, mo["x"], .Number),
		}
		switch lj_str(mo, "mode") {
		case "a":
			m.mode = .Add
		case "s":
			m.mode = .Subtract
		case "i":
			m.mode = .Intersect
		case "n":
			m.mode = .None
		case:
			warn(p, "mask mode %q is drawn as add", lj_str(mo, "mode"))
		}
		if mf, has_feather := mo["f"].(json.Object); has_feather && lj_num(mf, "k", 0) != 0 && !lj_has(mf, "a") {
			warn(p, "mask feather is not supported")
		}
		append(&doc.masks, m)
	}
	l.masks.count = u32(len(doc.masks)) - l.masks.start
	switch int(lj_num(lo, "ty", -1)) {
	case 0:
		l.kind = .Precomp
		l.w = lj_num(lo, "w", 0)
		l.h = lj_num(lo, "h", 0)
		if ref, ok := p.assets[lj_str(lo, "refId")]; ok && ref.comp > 0 {
			l.ref = ref.comp
		} else {
			warn(p, "precomp %q not found", lj_str(lo, "refId"))
		}
		if lj_has(lo, "tm") {
			l.time_remap = parse_prop(p, lo["tm"], .Number)
		}
	case 1:
		l.kind = .Solid
		l.w = lj_num(lo, "sw", 0)
		l.h = lj_num(lo, "sh", 0)
		col, ok := vg.css_color_parse(lj_str(lo, "sc"))
		l.color = col if ok else vg.BLACK
	case 2:
		l.kind = .Image
		if ref, ok := p.assets[lj_str(lo, "refId")]; ok {
			l.ref = ref.bitmap
			l.w, l.h = ref.w, ref.h
		}
	case 3:
		l.kind = .Null
	case 4:
		l.kind = .Shape
		l.shapes = parse_shapes(p, lj_array(lo, "shapes"))
		l.paints = count_paints(doc, l.shapes)
	case 5:
		l.kind = .Text
		l.ref = parse_text(p, lj_obj(lo, "t"))
	case 13:
		l.kind = .Other
		warn(p, "cameras are not supported")
	case:
		l.kind = .Other
	}
	return
}

@(private)
parse_transform :: proc(p: ^Parser, o: json.Object) -> i32 {
	t := Transform {
		anchor        = parse_prop(p, o["a"], .Number),
		position      = -1,
		position_x    = -1,
		position_y    = -1,
		scale         = parse_prop(p, o["s"], .Number),
		rotation      = parse_prop(p, o["r"], .Number),
		opacity       = parse_prop(p, o["o"], .Number),
		skew          = parse_prop(p, o["sk"], .Number),
		skew_axis     = parse_prop(p, o["sa"], .Number),
		start_opacity = parse_prop(p, o["so"], .Number),
		end_opacity   = parse_prop(p, o["eo"], .Number),
	}
	if t.rotation < 0 {
		// 3D layers: the z rotation.
		t.rotation = parse_prop(p, o["rz"], .Number)
	}
	if lj_has(o, "rx") || lj_has(o, "ry") || lj_has(o, "or") {
		warn(p, "3D rotation is drawn flat")
	}
	if po, ok := o["p"].(json.Object); ok && lj_num(po, "s", 0) != 0 {
		t.position_x = parse_prop(p, po["x"], .Number)
		t.position_y = parse_prop(p, po["y"], .Number)
	} else {
		t.position = parse_prop(p, o["p"], .Number)
	}
	append(&p.doc.transforms, t)
	return i32(len(p.doc.transforms) - 1)
}

// ---- shapes ------------------------------------------------------------------------

// Parses shape items into a contiguous run (their groups' children follow).
@(private)
parse_shapes :: proc(p: ^Parser, arr: json.Array) -> vg.Range {
	doc := p.doc
	// A group's transform item ("tr") is not an item of its own.
	n := 0
	for v in arr {
		if o, ok := v.(json.Object); ok && lj_str(o, "ty") != "tr" {
			n += 1
		}
	}
	start := u32(len(doc.shapes))
	resize(&doc.shapes, len(doc.shapes) + n)
	i := start
	for v in arr {
		o, ok := v.(json.Object)
		if !ok || lj_str(o, "ty") == "tr" {
			continue
		}
		sh := parse_shape(p, o)
		doc.shapes[i] = sh
		i += 1
	}
	return {start, u32(n)}
}

@(private)
parse_shape :: proc(p: ^Parser, o: json.Object) -> (sh: Shape) {
	sh.transform = -1
	for &k in sh.props {
		k = -1
	}
	sh.miter = 4
	if lj_num(o, "hd", 0) != 0 {
		sh.flags += {.Hidden}
	}
	if lj_num(o, "d", 1) == 3 {
		sh.flags += {.Reversed}
	}
	ty := lj_str(o, "ty")
	switch ty {
	case "gr":
		sh.kind = .Group
		items := lj_array(o, "it")
		for v in items {
			if io, ok := v.(json.Object); ok && lj_str(io, "ty") == "tr" {
				sh.transform = parse_transform(p, io)
			}
		}
		if !vg.budget_over(&p.budget, .Depth, p.depth + 1) {
			p.depth += 1
			sh.children = parse_shapes(p, items)
			p.depth -= 1
		}
		sh.paints = count_paints(p.doc, sh.children)
	case "rc":
		sh.kind = .Rect
		sh.props[POSITION] = parse_prop(p, o["p"], .Number)
		sh.props[SIZE] = parse_prop(p, o["s"], .Number)
		sh.props[ROUNDNESS] = parse_prop(p, o["r"], .Number)
	case "el":
		sh.kind = .Ellipse
		sh.props[POSITION] = parse_prop(p, o["p"], .Number)
		sh.props[SIZE] = parse_prop(p, o["s"], .Number)
	case "sh":
		sh.kind = .Path
		sh.props[PATH] = parse_prop(p, o["ks"], .Path)
	case "sr":
		sh.kind = .Star
		if lj_num(o, "sy", 1) == 2 {
			sh.flags += {.Polygon}
		}
		sh.props[POSITION] = parse_prop(p, o["p"], .Number)
		sh.props[STAR_ROTATION] = parse_prop(p, o["r"], .Number)
		sh.props[STAR_POINTS] = parse_prop(p, o["pt"], .Number)
		sh.props[STAR_INNER_RADIUS] = parse_prop(p, o["ir"], .Number)
		sh.props[STAR_INNER_ROUNDNESS] = parse_prop(p, o["is"], .Number)
		sh.props[STAR_OUTER_RADIUS] = parse_prop(p, o["or"], .Number)
		sh.props[STAR_OUTER_ROUNDNESS] = parse_prop(p, o["os"], .Number)
	case "fl", "st", "gf", "gs":
		switch ty {
		case "fl":
			sh.kind = .Fill
		case "st":
			sh.kind = .Stroke
		case "gf":
			sh.kind = .Gradient_Fill
		case "gs":
			sh.kind = .Gradient_Stroke
		}
		sh.props[OPACITY] = parse_prop(p, o["o"], .Number)
		if lj_num(o, "r", 1) == 2 {
			sh.flags += {.Even_Odd}
		}
		if ty == "fl" || ty == "st" {
			sh.props[COLOR] = parse_prop(p, o["c"], .Number)
		} else {
			g := lj_obj(o, "g")
			sh.stops = u16(lj_num(g, "p", 0))
			sh.props[COLOR] = parse_prop(p, g["k"], .Number)
			sh.props[START] = parse_prop(p, o["s"], .Number)
			sh.props[END] = parse_prop(p, o["e"], .Number)
			if lj_num(o, "t", 1) == 2 {
				sh.flags += {.Radial}
				sh.props[HIGHLIGHT] = parse_prop(p, o["h"], .Number)
				sh.props[HIGHLIGHT_ANGLE] = parse_prop(p, o["a"], .Number)
			}
		}
		if ty == "st" || ty == "gs" {
			sh.props[WIDTH] = parse_prop(p, o["w"], .Number)
			switch int(lj_num(o, "lc", 2)) {
			case 1:
				sh.cap = .Butt
			case 3:
				sh.cap = .Square
			case:
				sh.cap = .Round
			}
			switch int(lj_num(o, "lj", 2)) {
			case 1:
				sh.join = .Miter
			case 3:
				sh.join = .Bevel
			case:
				sh.join = .Round
			}
			sh.miter = lj_num(o, "ml", 4)
			if lj_has(o, "ml2") {
				sh.miter = lj_num(lj_obj(o, "ml2"), "k", sh.miter)
			}
			dashes := lj_array(o, "d")
			sh.dash.start = u32(len(p.doc.dashes))
			for dv in dashes {
				dobj, ok := dv.(json.Object)
				if !ok {
					continue
				}
				append(&p.doc.dashes, Dash{parse_prop(p, dobj["v"], .Number), lj_str(dobj, "n") == "o"})
			}
			sh.dash.count = u32(len(p.doc.dashes)) - sh.dash.start
		}
	case "tm":
		sh.kind = .Trim
		sh.props[TRIM_START] = parse_prop(p, o["s"], .Number)
		sh.props[TRIM_END] = parse_prop(p, o["e"], .Number)
		sh.props[TRIM_OFFSET] = parse_prop(p, o["o"], .Number)
		if lj_num(o, "m", 1) == 2 {
			sh.flags += {.Trim_Sequential}
		}
	case "rp":
		sh.kind = .Repeater
		sh.props[COPIES] = parse_prop(p, o["c"], .Number)
		sh.props[COPY_OFFSET] = parse_prop(p, o["o"], .Number)
		if tr := lj_obj(o, "tr"); tr != nil {
			sh.transform = parse_transform(p, tr)
		}
		if lj_num(o, "m", 1) == 2 {
			sh.flags += {.Repeat_Below}
		}
	case "mm":
		sh.kind = .Merge
		sh.stops = u16(clamp(lj_num(o, "mm", 1), 1, 5))
	case "rd":
		sh.kind = .Ignored
		warn(p, "round corners are not supported")
	case:
		sh.kind = .Ignored
		warn(p, "shape item %q is not supported", ty)
	}
	return
}

// The paints drawn by `items` (and their groups); repeaters count as many.
count_paints :: proc(doc: ^Document, items: vg.Range) -> u16 {
	n: int
	for i in items.start ..< items.start + items.count {
		sh := &doc.shapes[i]
		#partial switch sh.kind {
		case .Group:
			n += int(sh.paints)
		case .Fill, .Stroke, .Gradient_Fill, .Gradient_Stroke:
			n += 1
		case .Repeater:
			n += 2
		}
	}
	return u16(min(n, int(max(u16))))
}

// ---- effects and text --------------------------------------------------------------

@(private)
parse_effects :: proc(p: ^Parser, arr: json.Array) -> vg.Range {
	doc := p.doc
	r := vg.Range{u32(len(doc.effects)), 0}
	for v in arr {
		eo, ok := v.(json.Object)
		if !ok || lj_num(eo, "en", 1) == 0 {
			continue
		}
		e: Effect
		ty := i32(lj_num(eo, "ty", -1))
		if ty == 5 {
			// Expression controls (sliders, checkboxes ...): no pixels.
			continue
		}
		known := false
		for info, kind in EFFECTS {
			if info.type_id == ty {
				e.kind, known = kind, true
			}
		}
		if !known {
			warn(p, "effect %q (type %d) is not supported", lj_str(eo, "nm"), ty)
			continue
		}
		if r.count == MAX_EFFECTS {
			warn(p, "more than %d effects on a layer: the rest are skipped", MAX_EFFECTS)
			break
		}
		controls := lj_array(eo, "ef")
		info := EFFECTS
		row := info[e.kind]
		e.params = {u32(len(doc.effect_params)), u32(row.count)}
		for param in row.params[:row.count] {
			prop := i32(-1)
			if int(param.control) < len(controls) {
				co, _ := controls[param.control].(json.Object)
				prop = parse_prop(p, co["v"], .Number)
			}
			append(&doc.effect_params, prop)
		}
		append(&doc.effects, e)
		r.count += 1
	}
	return r
}

// A font style name ("Bold Italic", "SemiBold", ...) as a weight and italic.
font_style :: proc(style: string) -> (weight: int, italic: bool) {
	s := strings.to_lower(style, context.temp_allocator)
	italic = strings.contains(s, "italic") || strings.contains(s, "oblique")
	weight = 400
	names := [?]struct {
		name:   string,
		weight: int,
	}{{"thin", 100}, {"hairline", 100}, {"extralight", 200}, {"ultralight", 200}, {"light", 300}, {"medium", 500}, {"semibold", 600}, {"demibold", 600}, {"extrabold", 800}, {"ultrabold", 800}, {"bold", 700}, {"black", 900}, {"heavy", 900}}
	flat, _ := strings.remove_all(s, " ", context.temp_allocator)
	flat, _ = strings.remove_all(flat, "-", context.temp_allocator)
	for n in names {
		if strings.contains(flat, n.name) {
			return n.weight, italic
		}
	}
	return
}

@(private)
parse_text :: proc(p: ^Parser, t: json.Object) -> i32 {
	doc := p.doc
	txt := Text {
		grouping  = u8(lj_num(lj_obj(t, "m"), "g", 1)),
		alignment = parse_prop(p, lj_obj(t, "m")["a"], .Number),
	}
	// Document keyframes (always held).
	txt.keys.start = u32(len(doc.text_keys))
	d := lj_obj(t, "d")
	keys := lj_array(d, "k")
	if keys == nil {
		if ko, ok := d["k"].(json.Object); ok {
			append(&doc.text_keys, Text_Key{0, parse_text_doc(p, ko)})
		}
	}
	for kv in keys {
		ko, ok := kv.(json.Object)
		if !ok {
			continue
		}
		so := lj_obj(ko, "s")
		if so == nil {
			continue
		}
		append(&doc.text_keys, Text_Key{lj_num(ko, "t", 0), parse_text_doc(p, so)})
	}
	if lj_has(d, "x") {
		warn(p, "expressions are ignored")
	}
	txt.keys.count = u32(len(doc.text_keys)) - txt.keys.start
	if tp := lj_obj(t, "p"); tp != nil && lj_has(tp, "m") {
		warn(p, "text on a path is not supported")
	}
	txt.animators.start = u32(len(doc.animators))
	for av in lj_array(t, "a") {
		ao, ok := av.(json.Object)
		if !ok {
			continue
		}
		so := lj_obj(ao, "s")
		if int(lj_num(so, "t", 0)) != 0 {
			warn(p, "expression text selectors are not supported")
			continue
		}
		if lj_num(so, "rn", 0) != 0 {
			warn(p, "randomized text selectors keep their order")
		}
		props := lj_obj(ao, "a")
		a := Text_Animator {
			based_on    = u8(clamp(lj_num(so, "b", 1), 1, 4)),
			shape       = Selector_Shape(clamp(int(lj_num(so, "sh", 1)), 1, 6)),
			index_units = lj_num(so, "r", 1) == 2,
		}
		for info, k in ANIMATOR_PROPS {
			a.props[k] = parse_prop(p, (so if info.selector else props)[info.key], .Number)
		}
		if a.props[.Rotation] < 0 {
			a.props[.Rotation] = parse_prop(p, props["rz"], .Number)
		}
		if lj_has(props, "rx") || lj_has(props, "ry") {
			warn(p, "3D text animator rotation is drawn flat")
		}
		if lj_has(props, "fh") || lj_has(props, "fs") || lj_has(props, "fb") {
			warn(p, "text animator hue / saturation / brightness is not supported")
		}
		append(&doc.animators, a)
	}
	txt.animators.count = u32(len(doc.animators)) - txt.animators.start
	append(&doc.texts, txt)
	return i32(len(doc.texts) - 1)
}

@(private)
parse_text_doc :: proc(p: ^Parser, o: json.Object) -> u32 {
	doc := p.doc
	color :: proc(o: json.Object, key: string) -> (vg.Color, bool) {
		arr := lj_array(o, key)
		if len(arr) < 3 {
			return {}, false
		}
		c: [4]f32 = {0, 0, 0, 1}
		for i in 0 ..< min(len(arr), 4) {
			c[i], _ = lj_value_num(arr[i])
		}
		return vg.Color{clamp(c[0], 0, 1), clamp(c[1], 0, 1), clamp(c[2], 0, 1), clamp(c[3], 0, 1)}, true
	}
	td := Text_Doc {
		text           = strings.clone(lj_str(o, "t"), p.sa),
		font           = -1,
		size           = lj_num(o, "s", 16),
		tracking       = lj_num(o, "tr", 0),
		baseline_shift = lj_num(o, "ls", 0),
		stroke_width   = lj_num(o, "sw", 0),
		stroke_over    = lj_num(o, "of", 1) != 0,
		all_caps       = lj_num(o, "ca", 0) == 1,
	}
	td.line_height = lj_num(o, "lh", td.size * 1.2)
	td.fill, td.has_fill = color(o, "fc")
	// A stroke colour makes a stroke even at width 0: an animator may give
	// it width (lottie-web).
	td.stroke, td.has_stroke = color(o, "sc")
	switch int(lj_num(o, "j", 0)) {
	case 1, 4:
		td.justify = .Right
	case 2, 5:
		td.justify = .Center
	}
	if sz := lj_array(o, "sz"); len(sz) >= 2 {
		td.has_box = true
		td.box_size = {lj_vec_num(sz, 0), lj_vec_num(sz, 1)}
		ps := lj_array(o, "ps")
		td.box_pos = {lj_vec_num(ps, 0), lj_vec_num(ps, 1)}
	}
	name := lj_str(o, "f")
	for f, i in doc.fonts {
		if f.name == name {
			td.font = i32(i)
		}
	}
	append(&doc.text_docs, td)
	return u32(len(doc.text_docs) - 1)
}

@(private)
lj_vec_num :: proc(arr: json.Array, i: int) -> f32 {
	if i >= len(arr) {
		return 0
	}
	n, _ := lj_value_num(arr[i])
	return n
}

// ---- properties --------------------------------------------------------------------

@(private)
Prop_Type :: enum u8 {
	Number,
	Path,
}

// Parses an animatable property ({"a": 0|1, "k": ...}) into props; -1 when
// absent.
@(private)
parse_prop :: proc(p: ^Parser, v: json.Value, type: Prop_Type) -> i32 {
	o, ok := v.(json.Object)
	if !ok {
		return -1
	}
	k, has_k := o["k"]
	if !has_k {
		return -1
	}
	if lj_has(o, "x") {
		if _, is_str := o["x"].(json.String); is_str {
			warn(p, "expressions are ignored")
		}
	}
	doc := p.doc
	prop: Prop
	if arr, is_arr := k.(json.Array); is_arr && len(arr) > 0 {
		if ko, is_key := arr[0].(json.Object); is_key && lj_has(ko, "t") {
			prop.keys.start = u32(len(doc.keys))
			prev_end := NONE
			for kv in arr {
				kf, _ := kv.(json.Object)
				key := Key {
					t       = lj_num(kf, "t", 0),
					hold    = lj_num(kf, "h", 0) != 0,
					ease    = NONE,
					spatial = NONE,
				}
				if s, has_s := kf["s"]; has_s {
					// Every key holds the first key's value shape (eval
					// reads `dims` floats of each); others are dropped.
					value, dims := parse_value(p, s, type)
					if dims == 0 || (prop.dims != 0 && dims != prop.dims) {
						warn(p, "keyframes with mismatched values are skipped")
						continue
					}
					key.value, prop.dims = value, dims
				} else if prev_end != NONE {
					key.value = prev_end
				} else if len(doc.keys) > int(prop.keys.start) {
					key.value = doc.keys[len(doc.keys) - 1].value
				} else {
					continue
				}
				prev_end = NONE
				if e, has_e := kf["e"]; has_e {
					if value, dims := parse_value(p, e, type); dims == prop.dims {
						prev_end = value
					}
				}
				key.ease, key.ease_dims = parse_ease(p, kf)
				if type == .Number {
					to := lj_array(kf, "to")
					ti := lj_array(kf, "ti")
					if len(to) >= 2 && len(ti) >= 2 {
						key.spatial = u32(len(doc.values))
						for q in ([4]json.Value{to[0], to[1], ti[0], ti[1]}) {
							n, _ := lj_value_num(q)
							append(&doc.values, n)
						}
					}
				}
				append(&doc.keys, key)
			}
			prop.keys.count = u32(len(doc.keys)) - prop.keys.start
			if prop.keys.count == 0 {
				return -1
			}
			append(&doc.props, prop)
			return i32(len(doc.props) - 1)
		}
	}
	prop.value, prop.dims = parse_value(p, k, type)
	if prop.dims == 0 {
		return -1
	}
	append(&doc.props, prop)
	return i32(len(doc.props) - 1)
}

// Stores one value: numbers into values, a path into paths.
@(private)
parse_value :: proc(p: ^Parser, v: json.Value, type: Prop_Type) -> (idx: u32, dims: u16) {
	doc := p.doc
	if type == .Path {
		po, ok := v.(json.Object)
		if !ok {
			// Keyframe values wrap the path in an array.
			if arr, is_arr := v.(json.Array); is_arr && len(arr) > 0 {
				po, ok = arr[0].(json.Object)
			}
		}
		if !ok {
			return NONE, 0
		}
		verts := lj_array(po, "v")
		ins := lj_array(po, "i")
		outs := lj_array(po, "o")
		path := Path {
			start  = u32(len(doc.points)),
			count  = u32(len(verts)),
			closed = lj_num(po, "c", 0) != 0,
		}
		for i in 0 ..< len(verts) {
			append(&doc.points, lj_vec2(verts, i), lj_vec2(ins, i), lj_vec2(outs, i))
		}
		append(&doc.paths, path)
		return u32(len(doc.paths) - 1), 1
	}
	idx = u32(len(doc.values))
	if n, is_num := lj_value_num(v); is_num {
		append(&doc.values, n)
		return idx, 1
	}
	if arr, is_arr := v.(json.Array); is_arr {
		for e in arr {
			n, _ := lj_value_num(e)
			append(&doc.values, n)
		}
		return idx, u16(len(arr))
	}
	return NONE, 0
}

@(private)
lj_vec2 :: proc(arr: json.Array, i: int) -> vg.Vec2 {
	if i >= len(arr) {
		return {}
	}
	pt, _ := arr[i].(json.Array)
	if len(pt) < 2 {
		return {}
	}
	x, _ := lj_value_num(pt[0])
	y, _ := lj_value_num(pt[1])
	return {x, y}
}

// A keyframe's easing ("o" out and "i" in handles, numbers or per-dimension
// arrays) into values.
@(private)
parse_ease :: proc(p: ^Parser, kf: json.Object) -> (idx: u32, dims: u16) {
	o := lj_obj(kf, "o")
	i := lj_obj(kf, "i")
	if o == nil || i == nil {
		return NONE, 0
	}
	parts := [4]json.Value{o["x"], o["y"], i["x"], i["y"]}
	n := 1
	for part in parts {
		if arr, ok := part.(json.Array); ok {
			n = max(n, len(arr))
		}
	}
	doc := p.doc
	idx = u32(len(doc.values))
	for d in 0 ..< n {
		for part in parts {
			val: f32
			if arr, ok := part.(json.Array); ok {
				if len(arr) > 0 {
					val, _ = lj_value_num(arr[min(d, len(arr) - 1)])
				}
			} else {
				val, _ = lj_value_num(part)
			}
			append(&doc.values, val)
		}
	}
	return idx, u16(n)
}
