package ovg

import "core:mem"

// Renderer contract and the types that cross the canvas -> backend boundary.
//
// A backend is a `Backend` value: a data pointer plus procedures. The canvas
// records `Command`s and `Vertex`es for a frame and hands them to `render` on
// `flush`. Images live in the canvas-owned `Image_Store`, which calls back
// into the backend to allocate, upload and free them.

Error :: enum u8 {
	None,
	General,
	Out_Of_Memory,
	Image_Decode,
	Io,
	Font_Parse,
	Shader_Compile,
	Shader_Link,
	Render_Target,
	Image_Id_Not_Found,
	Image_Update_Out_Of_Bounds,
	Image_Update_With_Different_Format,
	Unsupported_Format,
	Unsupported_Operation,
	Atlas_Full,
}

// One vertex of a frame's triangles, as a GPU takes it: the position, a
// (u, v) pair in 0..1 stored as 16-bit fractions (`unorm16`), and the row of
// `Frame.paints` it is drawn with, so draws with different paints can share
// one draw call. For paths `u` runs across a stroke and `v` is edge
// coverage; for glyphs (u, v) is the atlas coordinate.
Vertex :: struct {
	x, y:  f32,
	u, v:  u16,
	paint: u32,
}

vertex :: #force_inline proc "contextless" (x, y, u, v: f32, paint: u32) -> Vertex {
	return {x, y, unorm16(u), unorm16(v), paint}
}

// `f` in 0..1 as a 16-bit fraction (65535 is 1).
unorm16 :: #force_inline proc "contextless" (f: f32) -> u16 {
	return u16(clamp(f, 0, 1) * 65535 + 0.5)
}

// A vertex's (u, v) as 0..1.
vertex_uv :: #force_inline proc "contextless" (v: Vertex) -> [2]f32 {
	return {f32(v.u) / 65535, f32(v.v) / 65535}
}

// `[start, start + count)` into one of the frame's arrays; `count == 0`
// means "absent".
Range :: struct {
	start, count: u32,
}

// A run of a draw's vertices: a triangle list, or a strip (triangle i is
// vertices i, i+1, i+2). A GPU backend draws both through generated indices
// (`piece_index_count`), so draws of either kind merge.
Piece :: struct {
	verts: Range,
	strip: bool,
}

// The triangle indices `p` takes: 3 per triangle.
piece_index_count :: #force_inline proc "contextless" (p: Piece) -> u32 {
	if !p.strip {
		return p.verts.count
	}
	return 3 * (p.verts.count - 2) if p.verts.count >= 3 else 0
}

// How a draw uses the stencil (femtovg's GL backend).
Stencil_Mode :: enum u8 {
	// No stencil test.
	None,
	// Winding count: front faces increment, back faces decrement (wrapping);
	// no color.
	Winding,
	// Where `stencil & 0xff == 0` / `stencil & 1 == 0`, keeping it.
	Outside_Non_Zero,
	Outside_Even_Odd,
	// Where the masked stencil is set, zeroing it.
	Cover_Non_Zero,
	Cover_Even_Odd,
	// Where the stencil is 0, then incrementing it: each pixel once.
	Once,
	// Zeroes the stencil; no color.
	Clear,
}

Shader_Type :: enum u8 {
	Fill_Gradient             = 0,
	Fill_Image                = 1,
	Stencil                   = 2,
	Fill_Image_Gradient       = 3,
	Filter_Image              = 4,
	Fill_Color                = 5,
	Texture_Copy_Unclipped    = 6,
	Fill_Color_Unclipped      = 7,
	Fill_Gradient_Conic       = 8,
	Fill_Image_Gradient_Conic = 9,
	// Image filter passes (full-target quads, Copy blend).
	Filter_Color_Matrix       = 10,
	Filter_Blend              = 11,
	Filter_Composite          = 12,
	Filter_Color_Space        = 13,
	Filter_Component_Transfer = 14,
	Filter_Morphology         = 15,
	Filter_Lighting           = 16,
	Filter_Tile               = 17,
	Filter_Displacement       = 18,
	Filter_Convolve           = 19,
	Filter_Turbulence         = 20,
}

// A draw's paint (a row of `Frame.paints`). GPU backends upload these
// packed (`pack_frag_uniforms`); the software backend evaluates the same
// formulas.
Params :: struct {
	scissor_mat:                 [12]f32,
	paint_mat:                   [12]f32,
	inner_col:                   [4]f32,
	outer_col:                   [4]f32,
	scissor_ext:                 [2]f32,
	scissor_scale:               [2]f32,
	extent:                      [2]f32,
	radius:                      f32,
	feather:                     f32,
	stroke_mult:                 f32,
	stroke_thr:                  f32,
	tex_type:                    f32,
	shader_type:                 Shader_Type,
	// 0 = none, 1 = alpha mask, 2 = color texture.
	glyph_texture_type:          u8,
	image_blur_filter_direction: [2]f32,
	// Blur taps each side of the center (see `blur_pass_coefficients`).
	image_blur_filter_taps:      f32,
	image_blur_filter_coeff:     [3]f32,
	// 0 = transparent beyond the image, 1 = clamp to the edge.
	image_blur_filter_edge:      f32,
	// `Gradient_Spread` as a number.
	spread:                      f32,
	// Two-point conical radial gradient: 1 and the focal point (gradient
	// space, outer center at the origin); extent = (outer r, focal r).
	focal:                       [3]f32,
	// Coverage eases in and out across the fringe (smoothstep) instead of a
	// straight ramp: a feathered fill's wide edge then has no visible
	// shoulder (`Paint.feather`).
	smooth_edge:                 bool,
}

default_params :: proc "contextless" () -> Params {
	return {scissor_ext = {1, 1}, scissor_scale = {1, 1}}
}

// The 14 x vec4 uniform array the fragment shader reads as `frag[]`.
pack_frag_uniforms :: proc "contextless" (p: Params) -> (out: [14][4]f32) {
	out[0] = {p.scissor_mat[0], p.scissor_mat[1], p.scissor_mat[2], 1 if p.smooth_edge else 0}
	out[1] = {p.scissor_mat[4], p.scissor_mat[5], p.scissor_mat[6], 0}
	out[2] = {p.scissor_mat[8], p.scissor_mat[9], p.scissor_mat[10], 0}
	out[3] = {p.paint_mat[0], p.paint_mat[1], p.paint_mat[2], 0}
	out[4] = {p.paint_mat[4], p.paint_mat[5], p.paint_mat[6], 0}
	out[5] = {p.paint_mat[8], p.paint_mat[9], p.paint_mat[10], 0}
	out[6] = p.inner_col
	out[7] = p.outer_col
	out[8] = {p.scissor_ext[0], p.scissor_ext[1], p.scissor_scale[0], p.scissor_scale[1]}
	out[9] = {p.extent[0], p.extent[1], p.radius, p.feather}
	out[10] = {p.stroke_mult, p.stroke_thr, p.tex_type, f32(p.shader_type)}
	out[11] = {
		f32(p.glyph_texture_type),
		p.image_blur_filter_direction[0],
		p.image_blur_filter_direction[1],
		p.image_blur_filter_taps,
	}
	out[12] = {p.image_blur_filter_coeff[0], p.image_blur_filter_coeff[1], p.image_blur_filter_coeff[2], p.image_blur_filter_edge}
	out[13] = {p.spread, p.focal[0], p.focal[1], p.focal[2]}
	return
}

Glyph_Texture_Kind :: enum u8 {
	None          = 0,
	Alpha_Mask    = 1,
	Color_Texture = 2,
}

Glyph_Texture :: struct {
	kind:  Glyph_Texture_Kind,
	image: Image_Id,
}

// `nil` is the screen (the backend's default output); an `Image_Id` renders
// into that image. Images rendered into are stored top-down, like uploaded
// images, on every backend.
Render_Target :: union {
	Image_Id,
}

Fill_Rule :: enum u8 {
	Non_Zero,
	Even_Odd,
}

Line_Cap :: enum u8 {
	Butt,
	Round,
	Square,
}

Line_Join :: enum u8 {
	Miter,
	Round,
	Bevel,
}

Solidity :: enum u8 {
	None,
	Solid,
	Hole,
}

Blend_Factor :: enum u8 {
	Zero,
	One,
	Src_Color,
	One_Minus_Src_Color,
	Dst_Color,
	One_Minus_Dst_Color,
	Src_Alpha,
	One_Minus_Src_Alpha,
	Dst_Alpha,
	One_Minus_Dst_Alpha,
	Src_Alpha_Saturate,
}

Composite_Operation :: enum u8 {
	Source_Over,
	Source_In,
	Source_Out,
	Atop,
	Destination_Over,
	Destination_In,
	Destination_Out,
	Destination_Atop,
	Lighter,
	Copy,
	Xor,
}

Composite_Operation_State :: struct {
	src_rgb, dst_rgb, src_alpha, dst_alpha: Blend_Factor,
}

composite_state_from_op :: proc "contextless" (op: Composite_Operation) -> Composite_Operation_State {
	s, d: Blend_Factor
	switch op {
	case .Source_Over:
		s, d = .One, .One_Minus_Src_Alpha
	case .Source_In:
		s, d = .Dst_Alpha, .Zero
	case .Source_Out:
		s, d = .One_Minus_Dst_Alpha, .Zero
	case .Atop:
		s, d = .Dst_Alpha, .One_Minus_Src_Alpha
	case .Destination_Over:
		s, d = .One_Minus_Dst_Alpha, .One
	case .Destination_In:
		s, d = .Zero, .Src_Alpha
	case .Destination_Out:
		s, d = .Zero, .One_Minus_Src_Alpha
	case .Destination_Atop:
		s, d = .One_Minus_Dst_Alpha, .Src_Alpha
	case .Lighter:
		s, d = .One, .One
	case .Copy:
		s, d = .One, .Zero
	case .Xor:
		s, d = .One_Minus_Dst_Alpha, .One_Minus_Src_Alpha
	}
	return {s, d, s, d}
}

// Drawing coordinates (x, y) land on pixel (x - origin.x, y - origin.y) of
// `target`: the target is a window onto a larger drawing space (the layer
// stack draws a layer in canvas coordinates into an image of its bounds).
// Clear rectangles and scissor rectangles are in drawing coordinates too;
// image filters and programs ignore the origin.
Cmd_Set_Render_Target :: struct {
	target: Render_Target,
	origin: [2]i32,
}
// Overwrites `rect` (clipped by the command's scissor) with `color`.
Cmd_Clear_Rect :: struct {
	x, y, w, h: u32,
	color:      Color,
}
// The triangles of `Command.pieces` under `stencil`, painted with
// `Frame.paints[paint]` (every vertex names the same row). A convex fill
// is one draw; a concave fill three (its winding, the fringe outside it,
// cover); a stroke one, or two when it paints each pixel once (once, then
// clear, over the same pieces).
Cmd_Draw :: struct {
	stencil: Stencil_Mode,
	paint:   u32,
}
// Shape instances `Frame.shapes[instances]`, each filled by coverage
// (shape.odin) with its own paint row; one command covers a run of them
// that share the command's image, blend and scissor.
Cmd_Draw_Shapes :: struct {
	instances: Range,
}
// A shape drawn under `transform` (shape units to drawing coordinates).
Shape_Instance :: struct {
	shape:     ^Shape,
	transform: Transform2D,
	paint:     u32,
	even_odd:  bool,
}
// `Frame.filters[filter]` from the command's image into `target_image`.
Cmd_Filter_Image :: struct {
	target_image: Image_Id,
	filter:       u32,
}

Command_Type :: union {
	Cmd_Set_Render_Target,
	Cmd_Clear_Rect,
	Cmd_Draw,
	Cmd_Draw_Shapes,
	Cmd_Filter_Image,
	Cmd_Run_Program,
	Cmd_Run_External,
}

Command :: struct {
	type:                Command_Type,
	// Cmd_Draw's triangles: a range of `Frame.pieces`.
	pieces:              Range,
	// Paint image, gradient ramp, or the filter source.
	image:               Image_Id,
	glyph_texture:       Glyph_Texture,
	composite_operation: Composite_Operation_State,
	// Axis-aligned scissor captured at record time. `nil` means either no
	// clipping or a rotated scissor that only the shader's `scissor_mat`
	// test handles.
	scissor_rect:        Maybe(Rect),
}

// Everything one `flush` hands to the backend.
Frame :: struct {
	verts:     []Vertex,
	pieces:    []Piece,
	paints:    []Params,
	commands:  []Command,
	// Uniform blocks of program runs (`Program_Run.uniforms`).
	bytes:     []u8,
	// Commands stay small: payloads a few commands carry live in side tables
	// they index (`Cmd_Filter_Image.filter`, `Cmd_Run_Program.run`).
	filters:   []Image_Filter,
	runs:      []Program_Run,
	shapes:    []Shape_Instance,
}

frame_pieces :: #force_inline proc "contextless" (f: Frame, cmd: Command) -> []Piece {
	return f.pieces[cmd.pieces.start:][:cmd.pieces.count]
}

// Backend-specific output for `render`; the SDL_GPU backend reads it as a
// pointer to its `Output` (0 = its own offscreen screen texture).
Render_Output :: distinct u64

Screenshot :: struct {
	pixels: []u8, // RGBA8, top-down
	width:  u32,
	height: u32,
}

Backend :: struct {
	data:         rawptr,
	set_size:     proc(data: rawptr, width, height: u32, dpi: f32),
	render:       proc(data: rawptr, output: Render_Output, images: ^Image_Store, frame: Frame),
	alloc_image:  proc(data: rawptr, info: Image_Info) -> (Backend_Image, Error),
	update_image: proc(data: rawptr, image: ^Backend_Image, info: Image_Info, src: Image_Source, x, y: u32) -> Error,
	delete_image: proc(data: rawptr, image: Backend_Image, id: Image_Id),
	screenshot:   proc(data: rawptr, allocator: mem.Allocator) -> (Screenshot, Error),
	// An image's texels as stored, tightly packed (`read_image`); nil when
	// unsupported.
	read_image:   proc(data: rawptr, image: Backend_Image, info: Image_Info, allocator: mem.Allocator) -> ([]u8, Error),
	// Images are read from memory as stored (`Backend_Image.pixels`): a
	// player borrows stable shared pixels instead of copying them.
	memory_images: bool,
	// Custom programs (program.odin); nil when unsupported.
	create_program: proc(data: rawptr, desc: Program_Desc) -> (Backend_Program, Error),
	delete_program: proc(data: rawptr, program: Backend_Program),
}
