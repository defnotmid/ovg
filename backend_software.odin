package ovg

import "base:intrinsics"
import "base:runtime"
import "core:math"
import "core:mem"
import "core:simd"
import "core:slice"
import "core:strings"
import "core:sync"
import cv "deps:ocurves"
import common "deps:oicut/common"
import "deps:oksl"

// CPU rasterizer writing RGBA8. It runs the GPU backends' shaders
// (shaders/) on oksl's CPU program, textures bound to oksl as images, so its
// output is a pixel reference for GPU backends: one sample at each pixel
// center, blending in [0, 1] with rounding to 8 bits.
Software_Backend :: struct {
	allocator: mem.Allocator,
	pixels:    []u8,
	width:     u32,
	height:    u32,
	target:    Image_Id,
	// The target's `Cmd_Set_Render_Target.origin`.
	origin:    [2]i32,
	// A filter's intermediate (filter_plan), reused.
	blur_tmp:  []u8,
	// A run's draws by band (sw_draw_run): band k's are
	// `binned[starts[k]:starts[k + 1]]`, in drawing order; `bounds` holds
	// the run's instances' bounds by their index in the frame's shapes.
	binned:    [dynamic]Sw_Binned,
	starts:    [dynamic]u32,
	bounds:    [dynamic]Bounds,
	// `.Transient` images' pixels, one block carved in order for a render
	// (sw_lend) and kept at the largest render's size.
	transient: []u8,
	// The caller's pool a frame's row bands run on (oicut's Work_Pool: one
	// band a range); nil runs them all on the calling thread. A band takes
	// its shading memory from `lanes_free`.
	pool:      ^common.Work_Pool,
	// Motion blur (Frame.motion): the velocity twins of the screen and of
	// each image a frame draws into with `velocity`, one block carved for a
	// render (sw_twins) and kept at the largest render's size; `twin_at`
	// holds an image's span start by its slot (-1: none). A twin pixel is
	// (a * velocity, a * nearness, a): premultiplied by coverage.
	twins:     [][4]f32,
	twin_at:   [dynamic]int,
	// The screen's twin and the current target's (pixels nil: none).
	screen_twin: Sw_Twin,
	twin:      Sw_Twin,
	// The last frame's velocity and nearness (software_backend_velocity).
	velocity:  [dynamic][2]f32,
	nearness:  [dynamic]f32,
	// The units (shaders.odin) as oksl's CPU programs, [1] each's motion
	// variant: the shading the SDL_GPU backend's shaders do, from the same
	// source. Each is compiled the first time a run draws with it.
	programs:  [Sw_Unit][2]Sw_Program_Unit,
	// The frame's paints and motions as the shaders read them.
	paint_rows:  [dynamic][14][4]f32,
	motion_rows: [dynamic]Shader_Motion,
	// A run's groups (Cmd_Draw_Shapes.group), built before its bands: their
	// grids and members' words, the members' rows and motions as the shaders
	// read them, each group's grid and first row, and each command's group.
	group_words:   [dynamic]u32,
	group_rows:    [dynamic]Shader_Instance,
	group_motions: [dynamic]Shader_Motion,
	groups:        [dynamic]Sw_Group,
	group_of:      [dynamic]i32,
	group_grid:    Group_Grid_Scratch,
	// A run's fills' pieces in drawing coordinates, built before its bands
	// (sw_build_pieces) for sw_coverage: each piece monotone in y, and per
	// instance (piece_at: its first row in piece_rows, max(u32) for none),
	// the pieces each band it reaches reads: band piece_band0 + j's are
	// piece_list[piece_rows[at + j]:piece_rows[at + j + 1]].
	pieces:        [dynamic]Sw_Piece,
	piece_at:      [dynamic]u32,
	piece_band0:   [dynamic]i32,
	// The grids of fills recorded as pieces alone (cv.pieces_append) that the
	// shader reads (sw_build_pieces): each instance's range of `grid_words`,
	// empty for none, built with `grid_builder`.
	grid_at:       [dynamic]Range,
	grid_words:    [dynamic]u32,
	grid_builder:  cv.Builder,
	piece_rows:    [dynamic]u32,
	piece_list:    [dynamic]u32,
	// The bands' shading memory, kept warm across frames: a band takes a set
	// off `lanes_free` (making one when none is) and puts it back, so there
	// are as many as bands ever drew at once. On the heap, which the pool's
	// threads can grow from together, and not in their temp arenas, where a
	// band's 150 KB or so would open a first block of 4 MiB, zeroed.
	lanes_free:    [dynamic]^Sw_Lanes,
	lanes_lock:    sync.Mutex,
	// Every draw through the shader, none through the direct solid fill
	// (sw_fill_solid) or image blit (sw_blit_image): what
	// test_sw_fast_paths_match_shader holds them to.
	no_fast_paths: bool,
}

// The units the software backend runs on oksl's CPU program: every one but
// the clears' (sw_clear_rect) and the velocity resolve's (a copy out of the
// screen's twin, sw_resolve_velocity).
@(private = "file")
Sw_Unit :: enum u8 {
	Shape,
	Shape_Box,
	// Shape_Box's paint at coverage 1 (SHAPE_INSIDE), for sw_coverage's quads.
	Shape_Inside,
	Shape_Group,
	Marker_Group,
	Filter,
	Composite_Velocity,
}

@(private = "file", rodata)
SW_UNITS := [Sw_Unit]Shader_Unit {
	.Shape              = .Shape,
	.Shape_Box          = .Shape_Box,
	.Shape_Inside       = .Shape_Box,
	.Shape_Group        = .Shape_Group,
	.Marker_Group       = .Marker_Group,
	.Filter             = .Filter,
	.Composite_Velocity = .Composite_Velocity,
}

// A unit's CPU program and where its uniforms are in its uniform block
// (-1: it reads none): the shape units' uv, data and map from drawing
// coordinates to rc (rc_linear, rc_offset), the quad units' quad_tc and
// paint. It has no stage inputs.
@(private = "file")
Sw_Program_Unit :: struct {
	module:        ^oksl.Module,
	uv_at:         int,
	data_at:       int,
	rc_linear_at:  int,
	rc_offset_at:  int,
	quad_tc_at:    int,
	paint_at:      int,
}

// A group of a run: its grid in `group_words` and its first member's row
// in `group_rows`.
@(private = "file")
Sw_Group :: struct {
	grid:  Group_Grid,
	first: u32,
}

software_backend_init :: proc(b: ^Software_Backend, allocator := context.allocator) {
	b^ = {allocator = allocator}
	b.binned = make([dynamic]Sw_Binned, allocator)
	b.starts = make([dynamic]u32, allocator)
	b.bounds = make([dynamic]Bounds, allocator)
	b.twin_at = make([dynamic]int, allocator)
	b.velocity = make([dynamic][2]f32, allocator)
	b.nearness = make([dynamic]f32, allocator)
	b.paint_rows = make([dynamic][14][4]f32, allocator)
	b.motion_rows = make([dynamic]Shader_Motion, allocator)
	b.group_words = make([dynamic]u32, allocator)
	b.group_rows = make([dynamic]Shader_Instance, allocator)
	b.group_motions = make([dynamic]Shader_Motion, allocator)
	b.groups = make([dynamic]Sw_Group, allocator)
	b.group_of = make([dynamic]i32, allocator)
	b.group_grid = {make([dynamic]Bounds, allocator), make([dynamic][4]i32, allocator), make([dynamic]u32, allocator)}
	b.pieces = make([dynamic]Sw_Piece, allocator)
	b.piece_at = make([dynamic]u32, allocator)
	b.piece_band0 = make([dynamic]i32, allocator)
	b.grid_at = make([dynamic]Range, allocator)
	b.grid_words = make([dynamic]u32, allocator)
	b.grid_builder.curves = make([dynamic]cv.Curve, allocator)
	b.piece_rows = make([dynamic]u32, allocator)
	b.piece_list = make([dynamic]u32, allocator)
	b.lanes_free = make([dynamic]^Sw_Lanes, runtime.heap_allocator())
}

// Compiles the units `needs` (their motion variants with `motion`) that
// aren't yet, before a run's bands read them. They are ovg's own sources,
// which test_shaders_compile compiles, so a failure is a bug.
@(private = "file")
sw_programs_need :: proc(b: ^Software_Backend, needs: bit_set[Sw_Unit], motion: int) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	for u in needs {
		p := &b.programs[u][motion]
		if p.module != nil {
			continue
		}
		unit := SW_UNITS[u]
		inside := "#define SHAPE_INSIDE\n" if u == .Shape_Inside else ""
		prelude := strings.concatenate({shader_cpu_defines(unit), inside, shader_prelude(unit, motion == 1, context.temp_allocator)}, context.temp_allocator)
		context.allocator = b.allocator
		m, _, ok := oksl.compile(SHADER_SOURCES[unit].source, {profile = .Glsl, prelude = prelude, no_spirv = true, no_msl = true})
		assert(ok, "ovg's shaders compile for oksl's CPU program")
		assert(m.block_size <= SW_UNIFORM_BYTES && len(m.stage_inputs) == 0)
		at :: proc(m: ^oksl.Module, name: string) -> int {
			u, has := oksl.find_uniform(m, name)
			return u.offset if has else -1
		}
		p^ = {module = m, uv_at = at(m, "uv"), data_at = at(m, "data"), rc_linear_at = at(m, "rc_linear"), rc_offset_at = at(m, "rc_offset"), quad_tc_at = at(m, "quad_tc"), paint_at = at(m, "quad_paint")}
	}
}

software_backend_destroy :: proc(b: ^Software_Backend) {
	delete(b.pixels, b.allocator)
	delete(b.blur_tmp, b.allocator)
	delete(b.binned)
	delete(b.starts)
	delete(b.bounds)
	delete(b.transient, b.allocator)
	delete(b.twins, b.allocator)
	delete(b.twin_at)
	delete(b.velocity)
	delete(b.nearness)
	delete(b.paint_rows)
	delete(b.motion_rows)
	delete(b.group_words)
	delete(b.group_rows)
	delete(b.group_motions)
	delete(b.groups)
	delete(b.group_of)
	group_grid_scratch_destroy(&b.group_grid)
	delete(b.pieces)
	delete(b.piece_at)
	delete(b.piece_band0)
	delete(b.grid_at)
	delete(b.grid_words)
	cv.builder_destroy(&b.grid_builder)
	delete(b.piece_rows)
	delete(b.piece_list)
	for L in b.lanes_free {
		sw_lanes_destroy(L)
	}
	delete(b.lanes_free)
	// The modules were compiled from b.allocator (sw_programs_need).
	context.allocator = b.allocator
	for variants in b.programs {
		for p in variants {
			if p.module != nil {
				oksl.destroy(p.module)
			}
		}
	}
	b^ = {}
}

software_backend :: proc(b: ^Software_Backend) -> Backend {
	return {
		data = b,
		set_size = sw_set_size,
		render = sw_render,
		alloc_image = sw_alloc_image,
		update_image = sw_update_image,
		delete_image = sw_delete_image,
		screenshot = sw_screenshot,
		read_image = sw_read_image,
		memory_images = true,
		fills_as_pieces = true,
		create_program = sw_create_program,
		delete_program = sw_delete_program,
	}
}

// The screen contents (RGBA8, premultiplied, top-down).
software_backend_pixels :: proc(b: ^Software_Backend) -> Image_Source {
	return image_source_rgba(b.pixels, b.width, b.height)
}

// Motion blur (canvas_motion_blur): the last frame's velocity (pixels, the
// shutter's middle minus its opening) and nearness at each screen pixel,
// top-down, each the draws' over the pixel by their coverage over still,
// farthest ground, as o3d's motion_blur takes them; empty after a frame
// without.
software_backend_velocity :: proc(b: ^Software_Backend) -> (velocity: [][2]f32, nearness: []f32) {
	return b.velocity[:], b.nearness[:]
}

@(private = "file")
sw_set_size :: proc(data: rawptr, width, height: u32, dpi: f32) {
	b := (^Software_Backend)(data)
	if width == b.width && height == b.height && b.pixels != nil {
		return
	}
	delete(b.pixels, b.allocator)
	b.pixels, _ = sw_make_pixels(int(width * height * 4), b.allocator)
	b.width = width
	b.height = height
}

// Pixels the backend owns, SW_PIXEL_ALIGN-aligned whatever the allocator
// gives a []u8: oksl reads half and f32 texels in place and requires them
// aligned, and a lent image's span is aligned within its block (sw_span).
@(private = "file")
SW_PIXEL_ALIGN :: 64

@(private = "file")
sw_make_pixels :: proc(n: int, allocator: mem.Allocator) -> ([]u8, mem.Allocator_Error) {
	return mem.make_aligned([]u8, n, SW_PIXEL_ALIGN, allocator)
}

@(private = "file")
sw_alloc_image :: proc(data: rawptr, info: Image_Info) -> (Backend_Image, Error) {
	b := (^Software_Backend)(data)
	if .Transient in info.flags {
		// Pixels are lent for each render (sw_lend).
		return {}, nil
	}
	// Level 0, then with .Generate_Mipmaps the levels above it.
	pixels, err := sw_make_pixels(image_chain_bytes(info), b.allocator)
	if err != nil {
		return {}, .Out_Of_Memory
	}
	return {pixels = pixels}, nil
}

@(private = "file")
sw_update_image :: proc(data: rawptr, img: ^Backend_Image, info: Image_Info, src: Image_Source, x, y: u32) -> Error {
	if .Transient in info.flags {
		return .Unsupported_Operation
	}
	bpp := bytes_per_pixel(info.format)
	src_stride := image_source_stride(src)
	dst_stride := info.width * bpp
	row_bytes := src.width * bpp
	for row in 0 ..< src.height {
		s := src.data[row * src_stride:][:row_bytes]
		d := img.pixels[(y + row) * dst_stride + x * bpp:][:row_bytes]
		copy(d, s)
	}
	if image_level_count(info) > 1 {
		image_levels_build(info, img.pixels)
	}
	return nil
}

@(private = "file")
sw_delete_image :: proc(data: rawptr, img: Backend_Image, id: Image_Id) {
	b := (^Software_Backend)(data)
	if b.target == id {
		b.target = {}
	}
	delete(img.pixels, b.allocator)
}

@(private = "file")
sw_read_image :: proc(data: rawptr, img: Backend_Image, info: Image_Info, allocator: mem.Allocator) -> ([]u8, Error) {
	if .Transient in info.flags {
		return nil, .Unsupported_Operation
	}
	n := int(info.width * info.height * bytes_per_pixel(info.format))
	pixels, err := make([]u8, n, allocator)
	if err != nil {
		return nil, .Out_Of_Memory
	}
	copy(pixels, img.pixels[:n])
	return pixels, nil
}

@(private = "file")
sw_screenshot :: proc(data: rawptr, allocator: mem.Allocator) -> (Screenshot, Error) {
	b := (^Software_Backend)(data)
	pixels, err := make([]u8, len(b.pixels), allocator)
	if err != nil {
		return {}, .Out_Of_Memory
	}
	copy(pixels, b.pixels)
	return {pixels, b.width, b.height}, nil
}

// ---- frame execution ------------------------------------------------------------

@(private = "file")
Sw_Target :: struct {
	pixels: []u8,
	width:  u32,
	height: u32,
	format: Pixel_Format,
}

// A velocity twin: its target's pixels' motion (Software_Backend.twins).
@(private = "file")
Sw_Twin :: struct {
	pixels: [][4]f32,
	width:  u32,
	height: u32,
}

@(private = "file")
sw_active_target :: proc(b: ^Software_Backend, images: ^Image_Store) -> (Sw_Target, bool) {
	if image_id_valid(b.target) {
		entry := image_store_get(images, b.target)
		if entry == nil || entry.image.pixels == nil {
			return {}, false
		}
		return {entry.image.pixels, entry.info.width, entry.info.height, entry.info.format}, true
	}
	return {b.pixels, b.width, b.height, .RGBA8}, true
}

// Clears and draws gather into runs on one target, each drawn in row bands
// (sw_draw_run); a target switch, a filter, a program or an external ends a
// run and runs on its own, after it.
@(private = "file")
sw_render :: proc(data: rawptr, output: Render_Output, images: ^Image_Store, frame: Frame) {
	b := (^Software_Backend)(data)
	sw_lend(b, images)
	sw_twins(b, images, frame)
	b.target = {}
	b.origin = {}
	b.twin = sw_twin_of(b, images, nil, frame.motion)
	// The frame's instances' bounds: room for its largest frame, kept.
	if len(b.bounds) < len(frame.shapes) {
		resize(&b.bounds, len(frame.shapes))
	}
	// The paints and motions as the shaders read them, once a frame.
	resize(&b.paint_rows, len(frame.paints))
	for p, i in frame.paints {
		b.paint_rows[i] = pack_frag_uniforms(p)
	}
	resize(&b.motion_rows, len(frame.motions))
	for m, i in frame.motions {
		b.motion_rows[i] = shader_motion(m)
	}
	run := 0
	for cmd, i in frame.commands {
		#partial switch _ in cmd.type {
		case Cmd_Clear_Rect, Cmd_Draw_Shapes:
			continue
		}
		sw_draw_run(b, images, frame, frame.commands[run:i])
		run = i + 1
		#partial switch v in cmd.type {
		case Cmd_Set_Render_Target:
			b.target = {}
			b.origin = v.origin
			if id, is_image := v.target.(Image_Id); is_image {
				b.target = id
			}
			b.twin = sw_twin_of(b, images, v.target, v.velocity)
		case Cmd_Composite_Velocity:
			sw_composite_velocity(b, images, v)
		case Cmd_Filter_Image:
			sw_filter_image(b, images, cmd, v.target_image, frame.filters[v.filter])
		case Cmd_Run_Program:
			sw_run_program(images, frame, frame.runs[v.run])
		case Cmd_Run_External:
			v.fn(v.user, nil, images)
		}
	}
	sw_draw_run(b, images, frame, frame.commands[run:])
	sw_take_back(b, images)
	sw_resolve_velocity(b)
}

// Gives the screen and every image the frame draws into with `velocity` a
// twin, its span of one block sized for them all (grown, never shrunk),
// the screen's cleared (a layer clears its own). Out of memory leaves them
// without: their motion is lost.
@(private = "file")
sw_twins :: proc(b: ^Software_Backend, images: ^Image_Store, frame: Frame) {
	clear(&b.twin_at)
	b.screen_twin = {}
	if !frame.motion {
		return
	}
	resize(&b.twin_at, len(images.entries.slots))
	for &at in b.twin_at {
		at = -1
	}
	total := int(b.width * b.height)
	for cmd in frame.commands {
		rt, is_target := cmd.type.(Cmd_Set_Render_Target)
		id, is_image := rt.target.(Image_Id)
		if !is_target || !is_image || !rt.velocity || int(id.key.idx) >= len(b.twin_at) || b.twin_at[id.key.idx] >= 0 {
			continue
		}
		if e := image_store_get(images, id); e != nil {
			b.twin_at[id.key.idx] = total
			total += int(e.info.width * e.info.height)
		}
	}
	if len(b.twins) < total {
		delete(b.twins, b.allocator)
		b.twins, _ = make([][4]f32, total, b.allocator)
	}
	if len(b.twins) < total {
		clear(&b.twin_at)
		return
	}
	b.screen_twin = {b.twins[:b.width * b.height], b.width, b.height}
	mem.zero_slice(b.screen_twin.pixels)
}

// The twin of `target` (nil: the screen), none without `velocity`.
@(private = "file")
sw_twin_of :: proc(b: ^Software_Backend, images: ^Image_Store, target: Render_Target, velocity: bool) -> Sw_Twin {
	id, is_image := target.(Image_Id)
	if !velocity || !is_image {
		return b.screen_twin if velocity else {}
	}
	e := image_store_get(images, id)
	if e == nil || int(id.key.idx) >= len(b.twin_at) || b.twin_at[id.key.idx] < 0 {
		return {}
	}
	return {b.twins[b.twin_at[id.key.idx]:][:e.info.width * e.info.height], e.info.width, e.info.height}
}

// A layer's motion onto the target's twin (Cmd_Composite_Velocity) with
// velocity.frag, over the part of its window inside the target: its twin and
// its coverage read nearest at the pixel, as the GPU draws it.
@(private = "file")
sw_composite_velocity :: proc(b: ^Software_Backend, images: ^Image_Store, c: Cmd_Composite_Velocity) {
	src := sw_twin_of(b, images, c.source, true)
	alpha, ok := lookup_texture(images, c.alpha)
	if b.twin.pixels == nil || src.pixels == nil || !ok || c.w <= 0 || c.h <= 0 {
		return
	}
	sw_programs_need(b, {.Composite_Velocity}, 0)
	// The window's corner on the target.
	wx, wy := i32(c.x) - b.origin.x, i32(c.y) - b.origin.y
	coverage := sw_channel(alpha)
	coverage.filter, coverage.wrap = .Nearest, {}
	job := Sw_Quad_Pass {
		b       = b,
		unit    = b.programs[.Composite_Velocity][0],
		raster  = {twin = b.twin, x0 = max(wx, 0), y0 = max(wy, 0), x1 = min(wx + i32(c.w), i32(b.twin.width)), y1 = min(wy + i32(c.h), i32(b.twin.height))},
		quad_tc = {1 / c.w, 1 / c.h, -f32(wx) / c.w, -f32(wy) / c.h},
		images  = {oksl.channel_image(src.pixels, int(src.width), int(src.height)), coverage},
	}
	// The opacity rides in the paint's first word.
	job.paint[0] = {c.opacity, 0, 0, 0}
	sw_bands(b, int(b.twin.height), &job, sw_quad_band)
}

// The screen's twin as velocity and nearness (software_backend_velocity).
@(private = "file")
sw_resolve_velocity :: proc(b: ^Software_Backend) {
	n := len(b.screen_twin.pixels)
	resize(&b.velocity, n)
	resize(&b.nearness, n)
	for t, i in b.screen_twin.pixels {
		b.velocity[i] = t.xy
		b.nearness[i] = t.z
	}
}

// Gives every `.Transient` image of the store pixels for this render,
// each its span of one block sized for them all (grown, never shrunk).
// Out of memory leaves them without pixels: what draws into one or samples
// it is skipped.
@(private = "file")
sw_lend :: proc(b: ^Software_Backend, images: ^Image_Store) {
	total := 0
	for &slot in images.entries.slots {
		if e := &slot.value; slot.occupied && sw_transient(e) {
			total += sw_span(e.info)
		}
	}
	if len(b.transient) < total {
		delete(b.transient, b.allocator)
		b.transient, _ = sw_make_pixels(total, b.allocator)
	}
	at := 0
	for &slot in images.entries.slots {
		if e := &slot.value; slot.occupied && sw_transient(e) {
			n := int(e.info.width * e.info.height * bytes_per_pixel(e.info.format))
			e.image.pixels = b.transient[at:][:n] if len(b.transient) >= total else nil
			at += sw_span(e.info)
		}
	}
}

// Takes the lent pixels back (sw_lend).
@(private = "file")
sw_take_back :: proc(b: ^Software_Backend, images: ^Image_Store) {
	for &slot in images.entries.slots {
		if e := &slot.value; slot.occupied && sw_transient(e) {
			e.image.pixels = nil
		}
	}
}

@(private = "file")
sw_transient :: #force_inline proc "contextless" (e: ^Image_Entry) -> bool {
	return !e.virtual && !e.borrowed && .Transient in e.info.flags
}

// A transient image's span of the block: its pixels, rounded up to a cache
// line so each starts on one.
@(private = "file")
sw_span :: #force_inline proc "contextless" (info: Image_Info) -> int {
	n := int(info.width * info.height * bytes_per_pixel(info.format))
	return (n + 63) &~ 63
}

// A draw of a run in the bands it reaches: the command (its index in the
// run) and its instance (index in the frame's shapes; SW_NO_INSTANCE for a
// clear).
@(private = "file")
Sw_Binned :: struct {
	cmd:  u32,
	inst: u32,
}

@(private = "file")
SW_NO_INSTANCE :: max(u32)

@(private = "file")
Sw_Run :: struct {
	b:      ^Software_Backend,
	images: ^Image_Store,
	frame:  Frame,
	cmds:   []Command,
	target: Sw_Target,
	origin: [2]i32,
	twin:   Sw_Twin,
}

// Draws a run's commands (clears and shape draws on the current target):
// each instance (or clear) is binned once into the row bands it reaches,
// then every band draws its own, in order, on the caller's pool. A pixel
// gets the same draws in the same order as drawing the commands one after
// another, so the result is the same.
@(private = "file")
sw_draw_run :: proc(b: ^Software_Backend, images: ^Image_Store, frame: Frame, cmds: []Command) {
	if len(cmds) == 0 {
		return
	}
	target, ok := sw_active_target(b, images)
	if !ok {
		return
	}
	run := Sw_Run{b, images, frame, cmds, target, b.origin, b.twin}
	rows := int(target.height)
	bands := (rows + SW_BAND_ROWS - 1) / SW_BAND_ROWS
	if bands == 0 {
		return
	}
	// Count each band's draws into starts[k + 1] (keeping the instances'
	// bounds), sum them into ends, fill each band from its start (leaving
	// starts[k] at band k's end), then shift back.
	resize(&b.starts, bands + 1)
	mem.zero_slice(b.starts[:])
	needs: bit_set[Sw_Unit]
	for fill in ([2]bool{false, true}) {
		if fill {
			for band in 0 ..< bands {
				b.starts[band + 1] += b.starts[band]
			}
			// Sized from the count: the bins keep their largest run's room.
			total := int(b.starts[bands])
			if total == 0 {
				return
			}
			if cap(b.binned) < total {
				reserve(&b.binned, total)
			}
			resize(&b.binned, total)
		}
		for cmd, k in cmds {
			r := sw_raster(&run, cmd)
			#partial switch c in cmd.type {
			case Cmd_Clear_Rect:
				sw_bin(&run, fill, {u32(k), SW_NO_INSTANCE}, max(r.y0, i32(c.y)), min(r.y1, i32(c.y + c.h)))
			case Cmd_Draw_Shapes:
				if !fill && c.group != 0 && c.instances.count > 0 {
					needs += {.Marker_Group if frame.shapes[c.instances.start].marker != .None else .Shape_Group}
				}
				for i in c.instances.start ..< c.instances.start + c.instances.count {
					if !fill {
						b.bounds[i] = instance_bounds(frame.shapes[i], frame.shape_words)
						t := frame.shapes[i].transform
						if c.group == 0 {
							s := frame.shapes[i]
							if !sw_can_blit_image(b, images, cmd, target, run.twin, i, s, frame.shape_words) {
								fill_solid := s.hairline == 0 && s.marker == .None && s.widen == 0 && s.edge != .Aliased && sw_can_fill_solid(b, cmd, target, s)
								if !fill_solid {
									needs += {.Shape_Box if t[1] == 0 && t[2] == 0 else .Shape}
									if s.hairline == 0 && s.marker == .None && s.widen == 0 {
										needs += {.Shape_Inside}
									}
								}
							}
						}
					}
					ib := b.bounds[i]
					sw_bin(&run, fill, {u32(k), i}, clamp_i32(math.floor(ib.miny), r.y0, r.y1), clamp_i32(math.ceil(ib.maxy), r.y0, r.y1))
				}
			}
		}
	}
	for band := bands; band > 0; band -= 1 {
		b.starts[band] = b.starts[band - 1]
	}
	b.starts[0] = 0
	sw_programs_need(b, needs, int(run.twin.pixels != nil))
	sw_build_groups(b, frame, cmds)
	sw_build_pieces(&run, bands)
	sw_bands(b, rows, &run, sw_run_band)
}

// The run's groups as the group and marker shaders read them, before its
// bands: each group's grid and its members' words (copied after it, each
// drawn level once a member) in `group_words`, the members' rows (words at
// their copies) and motions in `group_rows` and `group_motions`, and each
// command's group in `group_of` (-1: none).
@(private = "file")
sw_build_groups :: proc(b: ^Software_Backend, frame: Frame, cmds: []Command) {
	clear(&b.group_words)
	clear(&b.group_rows)
	clear(&b.group_motions)
	clear(&b.groups)
	resize(&b.group_of, len(cmds))
	for cmd, k in cmds {
		b.group_of[k] = -1
		c, is_draw := cmd.type.(Cmd_Draw_Shapes)
		if !is_draw || c.group == 0 || c.instances.count == 0 {
			continue
		}
		members := frame.shapes[c.instances.start:][:c.instances.count]
		grid := group_grid(&b.group_grid, &b.group_words, members, frame.shape_words)
		b.group_of[k] = i32(len(b.groups))
		append(&b.groups, Sw_Group{grid, u32(len(b.group_rows))})
		for inst, i in members {
			at := u32(len(b.group_words))
			if inst.marker == .None {
				// The group shader reads each member's grid.
				if words := instance_words(inst, frame.shape_words); cv.has_grid(words) {
					append(&b.group_words, ..words)
				} else {
					cv.grid_append(&b.grid_builder, words, &b.group_words)
				}
			}
			append(&b.group_rows, shader_instance(inst, frame.shape_words, at, {}))
			m: Shader_Motion
			if len(frame.motions) > 0 {
				m = b.motion_rows[int(c.instances.start) + i]
			}
			append(&b.group_motions, m)
		}
	}
}

// A draw reaching rows [y0, y1) (drawing coordinates) of the run's target:
// counted in each band it reaches, or placed there (`fill`).
@(private = "file")
sw_bin :: proc(run: ^Sw_Run, fill: bool, item: Sw_Binned, y0, y1: i32) {
	if y0 >= y1 {
		return
	}
	b := run.b
	for band in int(y0 - run.origin.y) / SW_BAND_ROWS ..= int(y1 - 1 - run.origin.y) / SW_BAND_ROWS {
		if fill {
			b.binned[b.starts[band]] = item
			b.starts[band] += 1
		} else {
			b.starts[band + 1] += 1
		}
	}
}

// One band of a run: its draws, a command's together, with a set of the
// backend's shading memory (lanes_free).
@(private = "file")
sw_run_band :: proc(data: rawptr, y0, y1: int) {
	run := (^Sw_Run)(data)
	b := run.b
	k := y0 / SW_BAND_ROWS
	items := b.binned[b.starts[k]:b.starts[k + 1]]
	top, bottom := i32(y0) + run.origin.y, i32(y1) + run.origin.y
	lanes := sw_lanes_take(b)
	// oksl's Scratch grows from context.allocator.
	context.allocator = runtime.heap_allocator()
	for i := 0; i < len(items); {
		j := i + 1
		for j < len(items) && items[j].cmd == items[i].cmd {
			j += 1
		}
		sw_band_command(run, items[i].cmd, items[i:j], k, top, bottom, lanes)
		i = j
	}
	sw_lanes_give(b, lanes)
}

// Pixels are addressed in drawing coordinates: (x, y) is target pixel
// (x - ox, y - oy), and [x0, x1) x [y0, y1) is the drawable area.
@(private = "file")
Raster :: struct {
	target:  Sw_Target,
	ox, oy:  i32,
	x0, y0:  i32,
	x1, y1:  i32,
	blend:   Composite_Operation_State,
	twin:    Sw_Twin,
}

@(private = "file")
clamp_i32 :: #force_inline proc "contextless" (v: f32, lo, hi: i32) -> i32 {
	return i32(clamp(v, f32(lo), f32(hi)))
}

// The command's drawable area on the run's target (its scissor applied).
@(private = "file")
sw_raster :: proc(run: ^Sw_Run, cmd: Command) -> Raster {
	r := Raster {
		target  = run.target,
		blend   = cmd.composite_operation,
		ox      = run.origin.x,
		oy      = run.origin.y,
		x0      = run.origin.x,
		y0      = run.origin.y,
		x1      = run.origin.x + i32(run.target.width),
		y1      = run.origin.y + i32(run.target.height),
		twin    = run.twin,
	}
	if sr, ok := cmd.scissor_rect.?; ok {
		r.x0 = clamp_i32(math.floor(sr.x), r.x0, r.x1)
		r.y0 = clamp_i32(math.floor(sr.y), r.y0, r.y1)
		r.x1 = clamp_i32(math.ceil(sr.x + sr.w), r.x0, r.x1)
		r.y1 = clamp_i32(math.ceil(sr.y + sr.h), r.y0, r.y1)
	}
	return r
}

// Command `k`'s draws in band `band`, rows [top, bottom).
@(private = "file")
sw_band_command :: proc(run: ^Sw_Run, k: u32, items: []Sw_Binned, band: int, top, bottom: i32, lanes: ^Sw_Lanes) {
	cmd := run.cmds[k]
	r := sw_raster(run, cmd)
	r.y0 = max(r.y0, top)
	r.y1 = min(r.y1, bottom)
	if r.y0 >= r.y1 {
		return
	}
	frame := run.frame
	#partial switch c in cmd.type {
	case Cmd_Clear_Rect:
		sw_clear_rect(&r, c)
	case Cmd_Draw_Shapes:
		b := run.b
		// The draw's image as `tex`; white without one, as the GPU binds then.
		textures := [2]oksl.Channel_Image{sw_white(), sw_white()}
		if tex, ok := lookup_texture(run.images, cmd.image); ok {
			textures[0] = sw_channel(tex)
			textures[0].levels = sw_levels(tex, &lanes.levels)
		}
		// With a twin, the units' motion variants, whose motion goes over it.
		motion := int(r.twin.pixels != nil)
		paints := slice.reinterpret([]u32, b.paint_rows[:])
		if g := b.group_of[k]; g >= 0 {
			group := b.groups[g]
			grid := group.grid
			unit := Sw_Unit.Marker_Group if frame.shapes[c.instances.start].marker != .None else .Shape_Group
			// Cell units at the pixel: the group's records map them to
			// drawing coordinates.
			to_cells := Transform2D{1 / grid.cell.x, 0, 0, 1 / grid.cell.y, -grid.area.minx / grid.cell.x, -grid.area.miny / grid.cell.y}
			buffers := [4][]u32{paints, b.group_words[:], slice.reinterpret([]u32, b.group_rows[:]), slice.reinterpret([]u32, b.group_motions[:])}
			prog := b.programs[unit][motion]
			uniforms := sw_shape_uniforms(prog, to_cells, {}, {u32(grid.head), c.group - 1, group.first, 0})
			sw_shade_rect(lanes, &r, prog, sw_pixels(&r, grid.area), uniforms[:], buffers[:], textures[:])
			return
		}
		for it in items {
			inst := frame.shapes[it.inst]
			px := sw_pixels(&r, b.bounds[it.inst])
			if px[0] >= px[2] || px[1] >= px[3] {
				continue
			}
			if sw_fill_solid(lanes, &r, b, it.inst, inst, px, band) {
				continue
			}
			words := instance_words(inst, frame.shape_words)
			if g := b.grid_at[it.inst]; g.count > 0 {
				words = b.grid_words[g.start:][:g.count]
			}
			if sw_blit_image(b, run.images, cmd, &r, it.inst, inst, words, px) {
				continue
			}
			unit := Sw_Unit.Shape_Box if inst.transform[1] == 0 && inst.transform[2] == 0 else .Shape
			uv, data := shader_instance_inputs(inst, 0)
			data.w = it.inst
			buffers := [4][]u32{paints, words, nil, slice.reinterpret([]u32, b.motion_rows[:])}
			prog := b.programs[unit][motion]
			to_rc := transform_inverse(inst.transform)
			uniforms := sw_shape_uniforms(prog, to_rc, uv, data)
			// A fill: its coverage accumulated from its pieces, and its paint
			// shaded where it covers: at coverage 1, scaled by the pixel's (the
			// paint's colour and motion are linear in it). An aliased fill's
			// partly covered quads take the shader's winding test.
			if !sw_coverage(lanes, b, it.inst, inst, px, band) {
				sw_shade_rect(lanes, &r, prog, px, uniforms[:], buffers[:], textures[:])
				continue
			}
			inside := b.programs[.Shape_Inside][motion]
			inside_uniforms := sw_shape_uniforms(inside, to_rc, uv, data)
			sw_shade_quads(lanes, &r, inside, px, lanes.inside[:], inside_uniforms[:], buffers[:], textures[:])
			if inst.edge == .Aliased {
				sw_shade_quads(lanes, &r, prog, px, lanes.edge[:], uniforms[:], buffers[:], textures[:])
			} else {
				cov := Sw_Coverage{lanes.cov[:], px.xy &~ 1, int(px[2] - (px[0] &~ 1) + 1) / 2 * 2 + 1, inst.edge == .Smooth}
				sw_shade_quads(lanes, &r, inside, px, lanes.edge[:], inside_uniforms[:], buffers[:], textures[:], cov)
			}
		}
	}
}

@(private = "file")
sw_clear_rect :: proc(r: ^Raster, c: Cmd_Clear_Rect) {
	x0 := max(r.x0, i32(c.x))
	y0 := max(r.y0, i32(c.y))
	x1 := min(r.x1, i32(c.x + c.w))
	y1 := min(r.y1, i32(c.y + c.h))
	if x0 >= x1 || y0 >= y1 {
		return
	}
	col := color_to_array(premultiplied(c.color))
	if r.target.format == .RGBA8 {
		packed := transmute(u32)to_unorm8x4(col)
		px := slice.reinterpret([]u32, r.target.pixels)
		w := int(r.target.width)
		tx0, tx1 := int(x0 - r.ox), int(x1 - r.ox)
		for y in y0 ..< y1 {
			row := px[int(y - r.oy) * w + tx0 : int(y - r.oy) * w + tx1]
			for &p in row {
				p = packed
			}
		}
	} else {
		for y in y0 ..< y1 {
			for x in x0 ..< x1 {
				store_texel(r.target, u32(x - r.ox), u32(y - r.oy), col)
			}
		}
	}
	// What a clear leaves is still and farthest, at its alpha.
	if r.twin.pixels != nil {
		for y in y0 ..< y1 {
			row := r.twin.pixels[int(y - r.oy) * int(r.twin.width):]
			for x in x0 ..< x1 {
				row[x - r.ox] = {0, 0, 0, col[3]}
			}
		}
	}
}

// ---- textures ----------------------------------------------------------------

@(private = "file")
Sw_Texture :: struct {
	pixels: []u8,
	width:  u32,
	height: u32,
	format: Pixel_Format,
	flags:  Image_Flags,
}

@(private = "file")
lookup_texture :: proc(images: ^Image_Store, id: Image_Id) -> (Sw_Texture, bool) {
	if !image_id_valid(id) {
		return {}, false
	}
	entry := image_store_get(images, id)
	if entry == nil || entry.image.pixels == nil {
		return {}, false
	}
	// Bound to oksl, and `fetch` reads it unchecked: every texel must be
	// there.
	if entry.info.width == 0 || entry.info.height == 0 || len(entry.image.pixels) < int(entry.info.width) * int(entry.info.height) * int(bytes_per_pixel(entry.info.format)) {
		return {}, false
	}
	return {entry.image.pixels, entry.info.width, entry.info.height, entry.info.format, entry.info.flags}, true
}

// `t` as a shader's texture (a channel oksl reads itself), filtered and
// wrapped by its flags as the GPU backends' samplers are (Nearest, Repeat_X,
// Repeat_Y), its texels as stored (Gray8 and Gray16 are (g, 0, 0, 1)).
@(private = "file")
sw_channel :: proc "contextless" (t: Sw_Texture) -> oksl.Channel_Image {
	@(static, rodata)
	FORMATS := [Pixel_Format]oksl.Channel_Format {
		.RGBA8   = .Rgba8,
		.Gray8   = .Gray8,
		.Gray16  = .Gray16,
		.RGBA16F = .Rgba16f,
	}
	return {
		format = FORMATS[t.format],
		pixels = t.pixels,
		width  = int(t.width),
		height = int(t.height),
		filter = .Nearest if .Nearest in t.flags else .Linear,
		wrap   = {.Repeat if .Repeat_X in t.flags else .Clamp, .Repeat if .Repeat_Y in t.flags else .Clamp},
	}
}

// A texture's levels above level 0 (Image_Flag.Generate_Mipmaps), in
// `levels`; none when it keeps only level 0, or its pixels (lent ones) hold
// no more.
@(private = "file")
sw_levels :: proc "contextless" (t: Sw_Texture, levels: ^[IMAGE_MAX_LEVELS - 1]oksl.Channel_Level) -> []oksl.Channel_Level {
	info := Image_Info{t.flags, t.width, t.height, t.format}
	n := image_level_count(info)
	if n == 1 || len(t.pixels) < image_chain_bytes(info) {
		return nil
	}
	for l in 1 ..< n {
		w, h, at := image_level(info, l)
		levels[l - 1] = {texels = t.pixels[at:][:int(w * h * bytes_per_pixel(t.format))], width = int(w), height = int(h)}
	}
	return levels[:n - 1]
}

@(private = "file", rodata)
SW_WHITE := [4]u8{255, 255, 255, 255}

// One white texel: the texture of a draw without an image.
@(private = "file")
sw_white :: proc "contextless" () -> oksl.Channel_Image {
	return {format = .Rgba8, pixels = SW_WHITE[:], width = 1, height = 1}
}

// ---- texels -------------------------------------------------------------------------

// Texel as a GPU sampler returns it: Gray8 and Gray16 are (g, 0, 0, 1).
@(private = "file")
fetch :: #force_inline proc "contextless" (t: Sw_Texture, x, y: u32) -> [4]f32 {
	i := int(y * t.width + x)
	_ = t.pixels[(i + 1) * int(bytes_per_pixel(t.format)) - 1]
	return decode_texel(raw_data(t.pixels), i, t.format)
}

// Texel `i` of pixels in `format`, unchecked: the caller knows it is there.
@(private = "file")
decode_texel :: #force_inline proc "contextless" (pixels: [^]u8, i: int, format: Pixel_Format) -> [4]f32 {
	switch format {
	case .RGBA8:
		p := pixels[i * 4:]
		return {f32(p[0]), f32(p[1]), f32(p[2]), f32(p[3])} / 255
	case .Gray8:
		return {f32(pixels[i]) / 255, 0, 0, 1}
	case .Gray16:
		return {f32(u16(pixels[i * 2]) | u16(pixels[i * 2 + 1]) << 8) / 65535, 0, 0, 1}
	case .RGBA16F:
		p := (^[4]u16)(&pixels[i * 8])^
		return {half_to_f32(p[0]), half_to_f32(p[1]), half_to_f32(p[2]), half_to_f32(p[3])}
	}
	return {}
}

// f32(f16) for every finite half, without the library call it is on CPUs
// without F16C (Odin's default target): the bits moved to f32's places,
// scaled by 2^112 for the exponent bias (subnormals included).
@(private = "file")
half_to_f32 :: #force_inline proc "contextless" (h: u16) -> f32 {
	return transmute(f32)(transmute(u32)(transmute(f32)(u32(h & 0x7fff) << 13) * 0h77800000) | u32(h & 0x8000) << 16)
}

@(private = "file")
load_texel :: #force_inline proc "contextless" (t: Sw_Target, x, y: u32) -> [4]f32 {
	return fetch({t.pixels, t.width, t.height, t.format, {}}, x, y)
}

@(private = "file")
to_unorm8 :: #force_inline proc "contextless" (v: f32) -> u8 {
	return u8(clamp(v * 255 + 0.5, 0, 255))
}

// to_unorm8 of each of the four at once.
@(private = "file")
to_unorm8x4 :: #force_inline proc "contextless" (c: [4]f32) -> [4]u8 {
	return simd.to_array(cast(#simd[4]u8)simd.clamp(simd.from_array(c) * 255 + 0.5, 0, 255))
}

// clamp(c, 0, 1) for each of the four at once.
@(private = "file")
saturate4 :: #force_inline proc "contextless" (c: [4]f32) -> [4]f32 {
	return simd.to_array(simd.clamp(simd.from_array(c), 0, 1))
}

@(private = "file")
store_texel :: #force_inline proc "contextless" (t: Sw_Target, x, y: u32, c: [4]f32) {
	i := int(y * t.width + x)
	switch t.format {
	case .RGBA8:
		(^[4]u8)(raw_data(t.pixels[i * 4:][:4]))^ = to_unorm8x4(c)
	case .Gray8:
		t.pixels[i] = to_unorm8(c[0])
	case .Gray16:
		v := u16(clamp(c[0], 0, 1) * 65535 + 0.5)
		t.pixels[i * 2], t.pixels[i * 2 + 1] = u8(v), u8(v >> 8)
	case .RGBA16F:
		(^[4]f16)(&t.pixels[i * 8])^ = {f16(c[0]), f16(c[1]), f16(c[2]), f16(c[3])}
	}
}

// ---- blending ------------------------------------------------------------------------

@(private = "file")
factor_rgb :: #force_inline proc "contextless" (f: Blend_Factor, src, dst: [4]f32) -> [3]f32 {
	switch f {
	case .Zero:
		return {0, 0, 0}
	case .One:
		return {1, 1, 1}
	case .Src_Color:
		return src.rgb
	case .One_Minus_Src_Color:
		return 1 - src.rgb
	case .Dst_Color:
		return dst.rgb
	case .One_Minus_Dst_Color:
		return 1 - dst.rgb
	case .Src_Alpha:
		return src.a
	case .One_Minus_Src_Alpha:
		return 1 - src.a
	case .Dst_Alpha:
		return dst.a
	case .One_Minus_Dst_Alpha:
		return 1 - dst.a
	case .Src_Alpha_Saturate:
		return min(src.a, 1 - dst.a)
	}
	return {}
}

@(private = "file")
factor_alpha :: #force_inline proc "contextless" (f: Blend_Factor, sa, da: f32) -> f32 {
	switch f {
	case .Zero:
		return 0
	case .One, .Src_Alpha_Saturate:
		return 1
	case .Src_Color, .Src_Alpha:
		return sa
	case .One_Minus_Src_Color, .One_Minus_Src_Alpha:
		return 1 - sa
	case .Dst_Color, .Dst_Alpha:
		return da
	case .One_Minus_Dst_Color, .One_Minus_Dst_Alpha:
		return 1 - da
	}
	return 0
}

// Blends `src` onto the target's texel as a GPU's blend unit does: a unorm
// target clamps the source to [0, 1] first and the result as it stores it
// (store_texel); an RGBA16F target clamps neither.
@(private = "file")
blend_texel :: #force_inline proc "contextless" (t: Sw_Target, x, y: u32, s: Composite_Operation_State, src: [4]f32) {
	src := src
	if t.format != .RGBA16F {
		src = saturate4(src)
	}
	if s.src_rgb == .One && s.src_alpha == .One {
		if (s.dst_rgb == .Zero && s.dst_alpha == .Zero) || (s.dst_rgb == .One_Minus_Src_Alpha && s.dst_alpha == .One_Minus_Src_Alpha && src[3] >= 1) {
			store_texel(t, x, y, src)
			return
		}
	}
	dst := load_texel(t, x, y)
	sf := factor_rgb(s.src_rgb, src, dst)
	df := factor_rgb(s.dst_rgb, src, dst)
	rgb := src.rgb * sf + dst.rgb * df
	a := src.a * factor_alpha(s.src_alpha, src.a, dst.a) + dst.a * factor_alpha(s.dst_alpha, src.a, dst.a)
	store_texel(t, x, y, {rgb.r, rgb.g, rgb.b, a})
}

// ---- image filters -------------------------------------------------------------------

// Runs one image filter with the filter unit (shaders/filter.frag), in the
// passes `filter_plan` lays out for every backend: each a quad over its
// output in row bands (sw_quad_band), a two-pass filter's second reading
// the whole first from the intermediate.
@(private = "file")
sw_filter_image :: proc(b: ^Software_Backend, images: ^Image_Store, cmd: Command, target: Image_Id, filter: Image_Filter) {
	src, src_ok := lookup_texture(images, cmd.image)
	dst_entry := image_store_get(images, target)
	if !src_ok || dst_entry == nil || dst_entry.image.pixels == nil {
		return
	}
	backdrop := filter_backdrop(filter)
	back, back_ok := lookup_texture(images, backdrop)
	back_info: Maybe(Image_Info)
	if back_ok {
		back_info = Image_Info{back.flags, back.width, back.height, back.format}
	}
	src_info := Image_Info{src.flags, src.width, src.height, src.format}
	plan, ok := filter_plan(filter, src_info, dst_entry.info, back_info, target == cmd.image || target == backdrop)
	if !ok {
		return
	}
	dst := Sw_Target{dst_entry.image.pixels, dst_entry.info.width, dst_entry.info.height, dst_entry.info.format}
	mid: Sw_Texture
	if plan.count == 2 || plan.copy {
		info := src_info if plan.count == 2 else dst_entry.info
		mid = {sw_blur_tmp(b, int(info.width * info.height * bytes_per_pixel(info.format))), info.width, info.height, info.format, info.flags}
	}
	sw_programs_need(b, {.Filter}, 0)
	for pass in plan.passes[:plan.count] {
		from := mid if pass.from_mid else src
		to := Sw_Target{mid.pixels, mid.width, mid.height, mid.format} if pass.to_mid else dst
		job := Sw_Quad_Pass {
			b       = b,
			unit    = b.programs[.Filter][0],
			raster  = {target = to, x1 = i32(to.width), y1 = i32(to.height), blend = composite_state_from_op(.Copy)},
			quad_tc = {1 / f32(to.width), 1 / f32(to.height), 0, 0},
			paint   = pass.paint,
			images  = {sw_channel(from), sw_channel(back) if back_ok else {}},
		}
		sw_bands(b, int(to.height), &job, sw_quad_band)
	}
	if plan.copy {
		copy(dst.pixels, mid.pixels)
	}
}

// The intermediate of a filter's passes, `n` bytes.
@(private = "file")
sw_blur_tmp :: proc(b: ^Software_Backend, n: int) -> []u8 {
	if len(b.blur_tmp) < n {
		delete(b.blur_tmp, b.allocator)
		b.blur_tmp, _ = sw_make_pixels(n, b.allocator)
	}
	return b.blur_tmp[:n]
}

// A quad unit drawn over the raster's area as the GPU draws a quad over it
// (its pixels are drawing coordinates): its paint `paint`, `quad_tc`
// the map from a pixel's centre to ftcoord, `images` its `tex` and
// `glyphtex`. A raster without a target takes the unit's output as motion
// over its twin.
@(private = "file")
Sw_Quad_Pass :: struct {
	b:       ^Software_Backend,
	unit:    Sw_Program_Unit,
	raster:  Raster,
	quad_tc: [4]f32,
	paint:   [14][4]f32,
	images:  [2]oksl.Channel_Image,
}

// Rows [y0, y1) of a quad pass, with a set of the backend's shading memory.
@(private = "file")
sw_quad_band :: proc(data: rawptr, y0, y1: int) {
	job := (^Sw_Quad_Pass)(data)
	r := job.raster
	r.y0, r.y1 = max(r.y0, i32(y0)), min(r.y1, i32(y1))
	if r.y0 >= r.y1 || r.x0 >= r.x1 {
		return
	}
	lanes := sw_lanes_take(job.b)
	// oksl's Scratch grows from context.allocator.
	context.allocator = runtime.heap_allocator()
	uniforms: [SW_UNIFORM_BYTES]u8
	if job.unit.quad_tc_at >= 0 {
		(^[4]f32)(&uniforms[job.unit.quad_tc_at])^ = job.quad_tc
	}
	if job.unit.paint_at >= 0 {
		(^[14][4]f32)(&uniforms[job.unit.paint_at])^ = job.paint
	}
	sw_shade_rect(lanes, &r, job.unit, {r.x0, r.y0, r.x1, r.y1}, uniforms[:job.unit.module.block_size], nil, job.images[:])
	sw_lanes_give(job.b, lanes)
}

// ---- row bands -----------------------------------------------------------------------

@(private = "file")
SW_BAND_ROWS :: 16

@(private = "file")
Sw_Bands :: struct {
	data: rawptr,
	band: proc(data: rawptr, y0, y1: int),
	rows: int,
}

// Runs `band` over `rows` rows in bands of SW_BAND_ROWS, a range of bands
// at a time on the caller's pool (`b.pool`; nil: all on this thread). Bands
// write disjoint rows; a band never starts another sweep.
@(private = "file")
sw_bands :: proc(b: ^Software_Backend, rows: int, data: rawptr, band: proc(data: rawptr, y0, y1: int)) {
	job := Sw_Bands{data, band, rows}
	count := (rows + SW_BAND_ROWS - 1) / SW_BAND_ROWS
	if b.pool == nil {
		sw_band_range(&job, 0, count)
		return
	}
	b.pool.run(b.pool, count, sw_band_range, &job)
}

@(private = "file")
sw_band_range :: proc(data: rawptr, first, end: int) {
	job := (^Sw_Bands)(data)
	for k in first ..< end {
		y := k * SW_BAND_ROWS
		job.band(job.data, y, min(y + SW_BAND_ROWS, job.rows))
	}
}

// ---- custom programs ------------------------------------------------------------------

@(private = "file")
Sw_Program :: struct {
	cpu:  Program_Cpu_Proc,
	user: rawptr,
}

@(private = "file")
sw_create_program :: proc(data: rawptr, desc: Program_Desc) -> (Backend_Program, Error) {
	b := (^Software_Backend)(data)
	if desc.cpu == nil {
		return {}, .Unsupported_Operation
	}
	p := new(Sw_Program, b.allocator)
	p^ = {desc.cpu, desc.cpu_user}
	return {user = p}, nil
}

@(private = "file")
sw_delete_program :: proc(data: rawptr, program: Backend_Program) {
	b := (^Software_Backend)(data)
	free(program.user, b.allocator)
}

@(private = "file")
sw_run_program :: proc(images: ^Image_Store, frame: Frame, cmd: Program_Run) {
	p := (^Sw_Program)(cmd.program.user)
	entry := image_store_get(images, cmd.target)
	if p == nil || entry == nil || entry.image.pixels == nil || (entry.info.format != .RGBA8 && entry.info.format != .RGBA16F) {
		return
	}
	sampler: Program_Sampler
	for id, i in cmd.channels {
		if t, ok := lookup_texture(images, id); ok {
			sampler.images[i] = sw_channel(t)
			sampler.sizes[i] = {i32(t.width), i32(t.height), 1}
		}
	}
	w, h := int(entry.info.width), int(entry.info.height)
	format := entry.info.format
	if format == .RGBA16F {
		out := slice.reinterpret([][4]f16, entry.image.pixels[:w * h * 8])
		alpha: f16 = 1 if .Opaque in cmd.flags else 0
		for &px in out {
			px = {0, 0, 0, alpha}
		}
		p.cpu(p.user, frame_bytes(frame, cmd.uniforms), w, h, entry.image.pixels[:w * h * 8], w * 8, format, sampler)
		if .Opaque in cmd.flags {
			for &px in out {
				px[3] = 1
			}
		}
		return
	}
	out := entry.image.pixels[:w * h * 4]
	clear_to: u8 = 255 if .Opaque in cmd.flags else 0
	for i := 0; i < len(out); i += 4 {
		out[i], out[i + 1], out[i + 2], out[i + 3] = 0, 0, 0, clear_to
	}
	p.cpu(p.user, frame_bytes(frame, cmd.uniforms), w, h, out, w * 4, format, sampler)
	if .Opaque in cmd.flags {
		for i := 3; i < len(out); i += 4 {
			out[i] = 255
		}
	}
}

// ---- the shape shaders on oksl's CPU program ------------------------------------

// A band's working memory for the shaders: oksl's registers, and a call's
// quads and outputs (at most SW_SHADE_QUADS), reused from draw to draw and
// frame to frame (Software_Backend.lanes_free).
@(private = "file")
Sw_Lanes :: struct {
	// The draw's image's levels above level 0 (sw_levels), bound with it.
	levels:   [IMAGE_MAX_LEVELS - 1]oksl.Channel_Level,
	scratch:  oksl.Scratch,
	origins:  [dynamic][2]i32,
	helpers:  [dynamic]oksl.Quad_Lanes,
	shaded:   [dynamic]oksl.Quad_Lanes,
	color:    [dynamic][4]f32,
	motion:   [dynamic][4]f32,
	// sw_coverage's: a coverage a pixel, and the quads it sorts.
	cov:      [dynamic]f32,
	edge:     [dynamic][2]i32,
	inside:   [dynamic][2]i32,
}

// A free set of the backend's shading memory, or a new one on the heap.
@(private = "file")
sw_lanes_take :: proc(b: ^Software_Backend) -> ^Sw_Lanes {
	sync.lock(&b.lanes_lock)
	free_set, ok := pop_safe(&b.lanes_free)
	sync.unlock(&b.lanes_lock)
	if ok {
		return free_set
	}
	heap := runtime.heap_allocator()
	L := new(Sw_Lanes, heap)
	L^ = {
		origins = make([dynamic][2]i32, heap),
		helpers = make([dynamic]oksl.Quad_Lanes, heap),
		shaded = make([dynamic]oksl.Quad_Lanes, heap),
		color = make([dynamic][4]f32, heap),
		motion = make([dynamic][4]f32, heap),
		cov = make([dynamic]f32, heap),
		edge = make([dynamic][2]i32, heap),
		inside = make([dynamic][2]i32, heap),
	}
	return L
}

// Puts a set back on `lanes_free`.
@(private = "file")
sw_lanes_give :: proc(b: ^Software_Backend, L: ^Sw_Lanes) {
	sync.lock(&b.lanes_lock)
	append(&b.lanes_free, L)
	sync.unlock(&b.lanes_lock)
}

@(private = "file")
sw_lanes_destroy :: proc(L: ^Sw_Lanes) {
	context.allocator = runtime.heap_allocator()
	oksl.scratch_destroy(&L.scratch)
	delete(L.origins)
	delete(L.helpers)
	delete(L.shaded)
	delete(L.color)
	delete(L.motion)
	delete(L.cov)
	delete(L.edge)
	delete(L.inside)
	free(L)
}

// The pixels of `bounds` (drawing coordinates) in the raster: x0, y0, x1, y1.
@(private = "file")
sw_pixels :: proc "contextless" (r: ^Raster, bounds: Bounds) -> [4]i32 {
	return {clamp_i32(math.floor(bounds.minx), r.x0, r.x1), clamp_i32(math.floor(bounds.miny), r.y0, r.y1), clamp_i32(math.ceil(bounds.maxx), r.x0, r.x1), clamp_i32(math.ceil(bounds.maxy), r.y0, r.y1)}
}

// Quads one run_fragment call shades: 16 of oksl's batches, so a call's
// outputs (two colours a pixel, 32 KB) stay small and in cache however wide
// the pixels are.
@(private = "file")
SW_SHADE_QUADS :: 16 * oksl.LANES / 4

// A unit's uniform block: the shape units' uv, data, rc_linear and
// rc_offset, or the quad units' quad_tc and paint.
@(private = "file")
SW_UNIFORM_BYTES :: 256

// A shape unit's uniforms: uv, data and `to_rc` (the map from fpos, a
// pixel's centre, to rc).
@(private = "file")
sw_shape_uniforms :: proc "contextless" (prog: Sw_Program_Unit, to_rc: Transform2D, uv: [4]f32, data: [4]u32) -> (uniforms: [SW_UNIFORM_BYTES]u8) {
	if prog.uv_at >= 0 {
		(^[4]f32)(&uniforms[prog.uv_at])^ = uv
	}
	if prog.data_at >= 0 {
		(^[4]u32)(&uniforms[prog.data_at])^ = data
	}
	if prog.rc_linear_at >= 0 {
		(^[4]f32)(&uniforms[prog.rc_linear_at])^ = {to_rc[0], to_rc[1], to_rc[2], to_rc[3]}
	}
	if prog.rc_offset_at >= 0 {
		(^[2]f32)(&uniforms[prog.rc_offset_at])^ = {to_rc[4], to_rc[5]}
	}
	return
}

// Shades the raster's pixels `px` (x0, y0, x1, y1) in 2x2 quads with a
// unit, as the GPU rasterizes a quad over them, from its uniform block,
// storage buffers and textures (bound by channel). Then each pixel it
// shades blends in order (and with a twin, its motion over the twin's
// pixel, premultiplied source-over, whatever the blend); a raster without
// a target takes the unit's one output as that motion. The quads go
// SW_SHADE_QUADS at a time, row by row.
@(private = "file")
sw_shade_rect :: proc(L: ^Sw_Lanes, r: ^Raster, prog: Sw_Program_Unit, px: [4]i32, uniforms: []u8, buffers: [][]u32, textures: []oksl.Channel_Image) {
	x0, y0, x1, y1 := px[0], px[1], px[2], px[3]
	if x0 >= x1 || y0 >= y1 {
		return
	}
	qx0, qy0 := x0 &~ 1, y0 &~ 1
	nqx := int(x1 - qx0 + 1) / 2
	quads := nqx * (int(y1 - qy0 + 1) / 2)
	resize(&L.origins, SW_SHADE_QUADS)
	for first := 0; first < quads; first += SW_SHADE_QUADS {
		count := min(quads - first, SW_SHADE_QUADS)
		for q in 0 ..< count {
			k := first + q
			L.origins[q] = {qx0 + i32(k % nqx) * 2, qy0 + i32(k / nqx) * 2}
		}
		sw_shade_batch(L, r, prog, px, L.origins[:count], uniforms, buffers, textures)
	}
}

// sw_shade_rect over the listed quads of `px` (their top-left pixels, on
// its grid) instead of all of them.
@(private = "file")
sw_shade_quads :: proc(L: ^Sw_Lanes, r: ^Raster, prog: Sw_Program_Unit, px: [4]i32, quads: [][2]i32, uniforms: []u8, buffers: [][]u32, textures: []oksl.Channel_Image, cov := Sw_Coverage{}) {
	for first := 0; first < len(quads); first += SW_SHADE_QUADS {
		sw_shade_batch(L, r, prog, px, quads[first:min(first + SW_SHADE_QUADS, len(quads))], uniforms, buffers, textures, cov)
	}
}

// Coverage a pixel (sw_coverage's), which scales what a coverage-1 unit
// shades: from grid pixel `origin`, `stride` a row; eased as shape_ease
// when `ease`. No pixels: none.
@(private = "file")
Sw_Coverage :: struct {
	pixels: []f32,
	origin: [2]i32,
	stride: int,
	ease:   bool,
}

// One run_fragment call over at most SW_SHADE_QUADS quads, the lanes off
// `px` helpers, then their pixels blended.
@(private = "file")
sw_shade_batch :: proc(L: ^Sw_Lanes, r: ^Raster, prog: Sw_Program_Unit, px: [4]i32, origins: [][2]i32, uniforms: []u8, buffers: [][]u32, textures: []oksl.Channel_Image, cov := Sw_Coverage{}) {
	x0, y0, x1, y1 := px[0], px[1], px[2], px[3]
	m := prog.module
	colour := r.target.pixels != nil
	moves := len(m.stage_outputs) > 1 || !colour
	count := len(origins)
	total := count * 4
	resize(&L.helpers, SW_SHADE_QUADS)
	resize(&L.shaded, SW_SHADE_QUADS)
	resize(&L.color, SW_SHADE_QUADS * 4)
	if moves {
		resize(&L.motion, SW_SHADE_QUADS * 4)
	}
	for o, q in origins {
		h: oksl.Quad_Lanes
		if o.x + 1 >= x1 {h += {1, 3}}
		if o.x < x0 {h += {0, 2}}
		if o.y + 1 >= y1 {h += {2, 3}}
		if o.y < y0 {h += {0, 1}}
		L.helpers[q] = h
	}
	targets := [2][][4]f32{L.color[:total], L.motion[:total] if moves else nil}
	outputs := targets[:2 if moves else 1]
	if !colour {
		outputs = targets[1:]
	}
	shaded := L.shaded[:count]
	in_ := oksl.Fragment_Quads{count = count, origin = origins, helpers = L.helpers[:count]}
	oksl.run_fragment(&m.program, uniforms, in_, outputs, shaded, &L.scratch, {buffers = buffers, channel_images = textures})
	fast_rgba8 := colour && r.target.format == .RGBA8
	blend_ok, is_copy := sw_solid_blend(r.blend)
	fast_over := fast_rgba8 && blend_ok && !is_copy
	fast_copy := fast_rgba8 && blend_ok && is_copy
	dst_px: []u32
	dst_stride: int
	if fast_over || fast_copy {
		dst_px = slice.reinterpret([]u32, r.target.pixels)
		dst_stride = int(r.target.width)
	}
	has_cov := cov.pixels != nil
	for lanes, q in shaded {
		o := origins[q]
		for l in lanes {
			if has_cov {
				// The shader's discard below half an 8-bit step, and its
				// scale.
				v := cov.pixels[int(o.y + i32(l >> 1) - cov.origin.y) * cov.stride + int(o.x + i32(l & 1) - cov.origin.x)]
				if v < 1.0 / 510 {
					continue
				}
				if cov.ease {
					v = v * v * (3 - 2 * v)
				}
				L.color[q * 4 + l] *= v
				if moves {
					L.motion[q * 4 + l] *= v
				}
			}
			tx, ty := int(o.x + i32(l & 1) - r.ox), int(o.y + i32(l >> 1) - r.oy)
			if fast_over {
				c := saturate4(L.color[q * 4 + l])
				if c[3] >= 1 {
					dst_px[ty * dst_stride + tx] = transmute(u32)to_unorm8x4(c)
				} else if c != {} {
					d := transmute([4]u8)dst_px[ty * dst_stride + tx]
					df := #simd[4]f32{f32(d[0]), f32(d[1]), f32(d[2]), f32(d[3])}
					ia := 1 - c[3]
					out := simd.fma(df, #simd[4]f32{ia, ia, ia, ia}, simd.from_array(c * 255 + 0.5))
					dst_px[ty * dst_stride + tx] = transmute(u32)cast(#simd[4]u8)simd.clamp(out, 0, 255)
				}
			} else if fast_copy {
				dst_px[ty * dst_stride + tx] = transmute(u32)to_unorm8x4(saturate4(L.color[q * 4 + l]))
			} else if colour {
				blend_texel(r.target, u32(tx), u32(ty), r.blend, L.color[q * 4 + l])
			}
			if moves {
				mo := L.motion[q * 4 + l]
				d := &r.twin.pixels[ty * int(r.twin.width) + tx]
				d^ = mo + d^ * (1 - mo[3])
			}
		}
	}
}

// A piece of a fill in drawing coordinates, monotone in y over [0, 1]:
// P(s) = a s^2 + b s + c, from y = c.y to y = a.y + b.y + c.y.
// Straight segments have a == {0, 0}.
@(private = "file")
Sw_Piece :: struct {
	a, b, c: [2]f32,
}

// Slack for rounding in the pieces' solves, in pixels.
@(private = "file")
SW_EPS :: 1.0 / 64

@(private = "file")
sw_floor :: #force_inline proc "contextless" (x: f32) -> i32 {
	i := i32(x)
	return i - 1 if f32(i) > x else i
}

@(private = "file")
sw_ceil :: #force_inline proc "contextless" (x: f32) -> i32 {
	i := i32(x)
	return i + 1 if f32(i) < x else i
}

// The pixel rows whose footprints reach a piece's rows.
@(private = "file")
sw_piece_rows :: #force_inline proc "contextless" (p: Sw_Piece) -> (y0, y1: i32) {
	ya, yb := p.c.y, p.a.y + p.b.y + p.c.y
	return sw_floor(min(ya, yb) - SW_EPS), sw_ceil(max(ya, yb) + SW_EPS)
}

// The run's fills' pieces for sw_coverage, once a run instead of once a
// band: each instance's pieces mapped to drawing coordinates and split
// where y turns (`pieces`), then listed by the bands whose rows their
// footprints reach, counted and then placed (`piece_rows`, `piece_list`).
@(private = "file")
sw_build_pieces :: proc(run: ^Sw_Run, bands: int) {
	b := run.b
	frame := run.frame
	clear(&b.pieces)
	clear(&b.piece_rows)
	clear(&b.piece_list)
	clear(&b.grid_words)
	if len(b.piece_at) < len(frame.shapes) {
		resize(&b.piece_at, len(frame.shapes))
		resize(&b.piece_band0, len(frame.shapes))
		resize(&b.grid_at, len(frame.shapes))
	}
	for cmd in run.cmds {
		c, is_draw := cmd.type.(Cmd_Draw_Shapes)
		if !is_draw || c.group != 0 {
			continue
		}
		r := sw_raster(run, cmd)
		for i in c.instances.start ..< c.instances.start + c.instances.count {
			b.piece_at[i] = max(u32)
			b.grid_at[i] = {}
			inst := frame.shapes[i]
			// The shader reads the grid of a feathered fill and of an aliased
			// one's edges: built here for a fill recorded without one.
			if inst.marker == .None && inst.hairline == 0 && (inst.widen != 0 || inst.edge == .Aliased) {
				if words := instance_words(inst, frame.shape_words); !cv.has_grid(words) {
					at := len(b.grid_words)
					if cv.grid_append(&b.grid_builder, words, &b.grid_words) {
						b.grid_at[i] = {u32(at), u32(len(b.grid_words) - at)}
					}
				}
			}
			ib := b.bounds[i]
			y0, y1 := clamp_i32(math.floor(ib.miny), r.y0, r.y1), clamp_i32(math.ceil(ib.maxy), r.y0, r.y1)
			// A hairline's or a marker's coverage isn't its pieces' area,
			// nor a widened footprint's a pixel's.
			if inst.hairline > 0 || inst.marker != .None || inst.widen != 0 || y0 >= y1 {
				continue
			}
			words := instance_words(inst, frame.shape_words)
			x0, x1 := clamp_i32(math.floor(ib.minx), r.x0, r.x1), clamp_i32(math.ceil(ib.maxx), r.x0, r.x1)
			if x0 >= x1 || sw_can_blit_image(b, run.images, cmd, run.target, run.twin, i, inst, frame.shape_words) {
				continue
			}
			first := len(b.pieces)
			sw_append_pieces(&b.pieces, inst, words)
			band0 := int(y0 - run.origin.y) / SW_BAND_ROWS
			band1 := int(y1 - 1 - run.origin.y) / SW_BAND_ROWS
			nb := band1 - band0 + 1
			at := len(b.piece_rows)
			base := u32(len(b.piece_list))
			b.piece_at[i] = u32(at)
			b.piece_band0[i] = i32(band0)
			resize(&b.piece_rows, at + nb + 1)
			rows := b.piece_rows[at:]
			slice.zero(rows)
			// Count each band's pieces into rows[j + 1], prefix-sum from `base`
			// shifted right by one slot, then fill each from rows[j + 1]
			// (leaving rows[j + 1] at band j's end).
			for fill in ([2]bool{false, true}) {
				if fill {
					rows[0] = base
					for j in 0 ..< nb {
						rows[j + 1] += rows[j]
					}
					resize(&b.piece_list, int(rows[nb]))
					for j := nb; j > 0; j -= 1 {
						rows[j] = rows[j - 1]
					}
				}
				for p, k in b.pieces[first:] {
					py0, py1 := sw_piece_rows(p)
					if py1 <= y0 || py0 >= y1 {
						continue
					}
					j0 := (max(int(py0), int(y0)) - int(run.origin.y)) / SW_BAND_ROWS - band0
					j1 := (min(int(py1), int(y1)) - 1 - int(run.origin.y)) / SW_BAND_ROWS - band0
					for j in max(j0, 0) ..= min(j1, nb - 1) {
						if fill {
							b.piece_list[rows[j + 1]] = u32(first + k)
							rows[j + 1] += 1
						} else {
							rows[j + 1] += 1
						}
					}
				}
			}
		}
	}
}

// How many pieces a shape's words hold (curves.FORMAT).
@(private = "file")
sw_piece_count :: proc "contextless" (words: []u32) -> int {
	first := int(words[6])
	end := len(words)
	if o := int(words[4]); o > first {
		end = o
	}
	return (end - first) / 6
}

// An instance's pieces (its words' curves.FORMAT pieces) mapped to drawing
// coordinates, split where y turns into pieces on [0, 1]. Nearly-flat curves
// collapse to straight segments (a == 0) so accumulation skips solving roots.
@(private = "file")
sw_append_pieces :: proc(pieces: ^[dynamic]Sw_Piece, inst: Shape_Instance, words: []u32) {
	t := inst.transform
	first := int(words[6])
	for at := first; at < first + 6 * sw_piece_count(words); at += 6 {
		f := slice.reinterpret([]f32, words[at:at + 6])
		p1 := transform_point(t, f[0], f[1])
		p2 := transform_point(t, f[2], f[3])
		p3 := transform_point(t, f[4], f[5])
		a := p1 - 2 * p2 + p3
		// Max chord deviation of P(t) = a t^2 + b t + c on [0, 1] is |a|/4.
		if max(abs(a.x), abs(a.y)) <= 1.0 / 256 {
			if p1.y != p3.y {
				append(pieces, Sw_Piece{{}, p3 - p1, p1})
			}
			continue
		}
		b := 2 * (p2 - p1)
		if a.y != 0 {
			if s := -b.y / (2 * a.y); s > 0 && s < 1 {
				q0 := p1 + s * (p2 - p1)
				q1 := p2 + s * (p3 - p2)
				pm := q0 + s * (q1 - q0)
				// Both halves keep exact y-monotonicity at the split point.
				q0.y = pm.y
				q1.y = pm.y
				if p1.y != pm.y {
					append(pieces, Sw_Piece{p1 - 2 * q0 + pm, 2 * (q0 - p1), p1})
				}
				if pm.y != p3.y {
					append(pieces, Sw_Piece{pm - 2 * q1 + p3, 2 * (q1 - pm), pm})
				}
				continue
			}
		}
		if p1.y != p3.y {
			append(pieces, Sw_Piece{a, b, p1})
		}
	}
}

// Accumulates a straight segment from (xa, sy0) to (xb, sy1) within one pixel row.
@(private = "file")
sw_accumulate_row_line :: #force_inline proc "contextless" (acc: []f32, xa, sy0, xb, sy1: f32, w: int) {
	fw := f32(w)
	dy_row := sy1 - sy0
	if max(xa, xb) <= 0 {
		acc[0] += dy_row
		return
	}
	if min(xa, xb) >= fw {
		return
	}
	if xa == xb {
		col := sw_floor(xa)
		if col >= 0 && col < i32(w) {
			area := dy_row * (f32(col + 1) - xa)
			acc[col] += area
			acc[col + 1] += dy_row - area
		}
		return
	}
	step: i32 = 1 if xb > xa else -1
	col := sw_floor(xa) if step > 0 else sw_ceil(xa) - 1
	side := f32(col + 1) if step > 0 else f32(col)
	if col >= 0 && col < i32(w) && ((step > 0 && xb <= side) || (step < 0 && xb >= side)) {
		area := dy_row * (f32(col + 1) - 0.5 * (xa + xb))
		acc[col] += area
		acc[col + 1] += dy_row - area
		return
	}
	inv_dx := 1 / (xb - xa)
	x, y := xa, sy0
	if step > 0 && x < 0 {
		yc := sy0 + clamp(-xa * inv_dx, 0, 1) * dy_row
		acc[0] += yc - y
		x, y = 0, yc
		col = 0
	} else if step < 0 && x > fw {
		y = sy0 + clamp((fw - xa) * inv_dx, 0, 1) * dy_row
		x = fw
		col = i32(w) - 1
	}
	for {
		if col >= i32(w) {
			break
		}
		if col < 0 {
			acc[0] += sy1 - y
			break
		}
		c_side := f32(col + 1) if step > 0 else f32(col)
		xu, yu := xb, sy1
		if (step > 0 && xb > c_side) || (step < 0 && xb < c_side) {
			xu = c_side
			yu = sy0 + clamp((c_side - xa) * inv_dx, 0, 1) * dy_row
		}
		d_y := yu - y
		area := d_y * (f32(col + 1) - 0.5 * (x + xu))
		acc[col] += area
		acc[col + 1] += d_y - area
		if xu == xb {
			break
		}
		x, y = xu, yu
		col += step
	}
}

// Accumulates a straight monotone segment (x0, y0) -> (x0 + dx, y0 + dy) on a
// `w x h` pixel grid into `L.cov`.
@(private = "file")
sw_accumulate_line :: #force_inline proc "contextless" (cov: []f32, x0, y0, dx, dy: f32, w, h, stride: int) {
	if dy == 0 {
		return
	}
	down := dy > 0
	ylo := y0 if down else y0 + dy
	yhi := y0 + dy if down else y0
	cy0, cy1 := max(ylo, 0), min(yhi, f32(h))
	if cy0 >= cy1 {
		return
	}
	dx_dy := dx / dy
	for row in sw_floor(cy0) ..< sw_ceil(cy1) {
		ra, rb := max(f32(row), cy0), min(f32(row + 1), cy1)
		if ra >= rb {
			continue
		}
		sy0 := ra if down else rb
		sy1 := rb if down else ra
		xa := x0 + (sy0 - y0) * dx_dy
		xb := x0 + (sy1 - y0) * dx_dy
		sw_accumulate_row_line(cov[int(row) * stride:][:stride], xa, sy0, xb, sy1, w)
	}
}

// Accumulates `list`'s pieces into `L.cov` on an integer pixel grid of size
// `w x h` starting at drawing coordinates `(gx, gy)`, with `stride` floats per
// row (`stride >= w + 1`).
@(private = "file")
sw_accumulate_pieces :: proc(L: ^Sw_Lanes, b: ^Software_Backend, list: []u32, gx, gy: i32, w, h, stride: int) {
	resize(&L.cov, stride * h)
	slice.zero(L.cov[:])
	fgx, fgy := f32(gx), f32(gy)
	for k in list {
		p := b.pieces[k]
		a := p.a
		bb := p.b
		c := p.c - {fgx, fgy}
		if a.x == 0 && a.y == 0 {
			sw_accumulate_line(L.cov[:], c.x, c.y, bb.x, bb.y, w, h, stride)
			continue
		}
		ya, yb := c.y, a.y + bb.y + c.y
		ylo, yhi := max(min(ya, yb), 0), min(max(ya, yb), f32(h))
		if ylo >= yhi {
			continue
		}
		r0, r1 := sw_floor(ylo), sw_ceil(yhi)
		inc := yb > ya
		y_edge := ylo
		t_edge := (f32(0) if ylo == ya else sw_solve_monotone(a.y, bb.y, c.y, 0, 1, ya, yb, ylo)) if inc else (f32(1) if ylo == yb else sw_solve_monotone(a.y, bb.y, c.y, 0, 1, ya, yb, ylo))
		x_edge := sw_quad_at(a.x, bb.x, c.x, t_edge)
		sx_turn: f32
		has_x_turn := a.x != 0
		if has_x_turn {
			sx_turn = -bb.x / (2 * a.x)
		}
		for row in r0 ..< r1 {
			y_next := min(f32(row + 1), yhi)
			t_next := (f32(1) if y_next == yb else sw_solve_monotone(a.y, bb.y, c.y, 0, 1, ya, yb, y_next)) if inc else (f32(0) if y_next == ya else sw_solve_monotone(a.y, bb.y, c.y, 0, 1, ya, yb, y_next))
			x_next := sw_quad_at(a.x, bb.x, c.x, t_next)
			ta, xa, y_a, tb, xb, y_b := t_edge, x_edge, y_edge, t_next, x_next, y_next
			if !inc {
				ta, xa, y_a, tb, xb, y_b = t_next, x_next, y_next, t_edge, x_edge, y_edge
			}
			t_edge, x_edge, y_edge = t_next, x_next, y_next
			if ta >= tb {
				continue
			}
			acc := L.cov[int(row) * stride:][:stride]
			if has_x_turn && sx_turn > ta && sx_turn < tb {
				xm := sw_quad_at(a.x, bb.x, c.x, sx_turn)
				ym := sw_quad_at(a.y, bb.y, c.y, sx_turn)
				sw_accumulate_cells(acc, a, bb, c, ta, sx_turn, xa, y_a, xm, ym, w)
				sw_accumulate_cells(acc, a, bb, c, sx_turn, tb, xm, ym, xb, y_b, w)
			} else {
				sw_accumulate_cells(acc, a, bb, c, ta, tb, xa, y_a, xb, y_b, w)
			}
		}
	}
}

@(private = "file")
Sw_Blit_Op :: enum u8 {
	Source_Over,
	Copy,
	Source_In,
	Destination_Out,
}

@(private = "file")
sw_blit_op :: proc "contextless" (blend: Composite_Operation_State) -> (op: Sw_Blit_Op, ok: bool) {
	switch blend {
	case composite_state_from_op(.Source_Over):
		return .Source_Over, true
	case composite_state_from_op(.Copy):
		return .Copy, true
	case composite_state_from_op(.Source_In):
		return .Source_In, true
	case composite_state_from_op(.Destination_Out):
		return .Destination_Out, true
	}
	return {}, false
}

// Axis-aligned scissor bounds where the horizontal mask is 1 across `[x0, x0 + w)`.
@(private = "file")
sw_scissor_x :: proc "contextless" (pr: ^[14][4]f32, x0, w: int, is_copy: bool) -> (has_scissor: bool, in_x0, in_x1: int, alive: bool) {
	ax, bx, ex, sx := pr[0][0], pr[2][0], pr[8][0], pr[8][2]
	ay, by := pr[1][1], pr[2][1]
	has_scissor = ax != 0 || ay != 0 || bx != 0 || by != 0 || pr[8] != {1, 1, 1, 1}
	in_x0, in_x1 = 0, w
	if !has_scissor {
		return false, 0, w, true
	}
	if ax == 0 {
		mx := clamp(0.5 - (abs(bx) - ex) * sx, 0, 1)
		if mx <= 0 {
			if !is_copy {
				return true, 0, 0, false
			}
			return true, 0, 0, true
		}
		if mx < 1 {
			in_x0, in_x1 = 0, 0
		}
		return true, in_x0, in_x1, true
	}
	if sx <= 0 {
		return true, 0, 0, true
	}
	lim := ex - 0.5 / sx
	if lim < 0 {
		return true, 0, 0, true
	}
	c0 := (-lim - bx) / ax
	c1 := (lim - bx) / ax
	if c0 > c1 {
		c0, c1 = c1, c0
	}
	in_x0 = clamp(int(math.ceil(c0 - 0.5 + 1e-5)) - x0, 0, w)
	in_x1 = clamp(int(math.floor(c1 - 0.5 - 1e-5)) - x0 + 1, in_x0, w)
	return true, in_x0, in_x1, true
}

// Checks whether an instance is a 1:1 axis-aligned premultiplied RGBA8 image
// rectangle eligible for direct blitting (`sw_blit_image`).
@(private = "file")
sw_match_blit_image :: proc(b: ^Software_Backend, images: ^Image_Store, cmd: Command, target: Sw_Target, twin: Sw_Twin, idx: u32, inst: Shape_Instance, words: []u32) -> (src: Sw_Texture, op: Sw_Blit_Op, rx0, ry0, rx1, ry1, ox, oy: i32, ok: bool) {
	if b.no_fast_paths || target.format != .RGBA8 || target.pixels == nil {
		return
	}
	if inst.hairline > 0 || inst.marker != .None || inst.widen != 0 || inst.edge != .Aliased {
		return
	}
	if twin.pixels != nil && int(idx) < len(b.motion_rows) && b.motion_rows[idx][1][2] != 0 {
		return
	}
	bop, op_ok := sw_blit_op(cmd.composite_operation)
	if !op_ok {
		return
	}
	pr := &b.paint_rows[inst.paint]
	if pr[10][3] != f32(Shader_Type.Fill_Image) || pr[10][2] != 0 || pr[10][0] < 1 {
		return
	}
	if pr[0][1] != 0 || pr[1][0] != 0 {
		return
	}
	if pr[3][0] != 1 || pr[3][1] != 0 || pr[4][0] != 0 || pr[4][1] != 1 {
		return
	}
	tex, tex_ok := lookup_texture(images, cmd.image)
	if !tex_ok || tex.format != .RGBA8 || .Repeat_X in tex.flags || .Repeat_Y in tex.flags {
		return
	}
	if pr[9][0] != f32(tex.width) || pr[9][1] != f32(tex.height) {
		return
	}
	ox_f, oy_f := -pr[5][0], -pr[5][1]
	ox_i, oy_i := i32(math.round(ox_f)), i32(math.round(oy_f))
	if abs(f32(ox_i) - ox_f) > 1e-4 || abs(f32(oy_i) - oy_f) > 1e-4 {
		return
	}
	if sw_piece_count(words) != 4 {
		return
	}
	first := int(words[6])
	t := inst.transform
	pts: [4][4]f32 // {p1.x, p1.y, p3.x, p3.y}
	minx, miny := f32(1e30), f32(1e30)
	maxx, maxy := f32(-1e30), f32(-1e30)
	for k in 0 ..< 4 {
		f := slice.reinterpret([]f32, words[first + k * 6:][:6])
		p1 := transform_point(t, f[0], f[1])
		p2 := transform_point(t, f[2], f[3])
		p3 := transform_point(t, f[4], f[5])
		a := p1 - 2 * p2 + p3
		if max(abs(a.x), abs(a.y)) > 1e-4 {
			return
		}
		pts[k] = {p1.x, p1.y, p3.x, p3.y}
		minx = min(minx, min(p1.x, p3.x))
		miny = min(miny, min(p1.y, p3.y))
		maxx = max(maxx, max(p1.x, p3.x))
		maxy = max(maxy, max(p1.y, p3.y))
	}
	left_dy: f32 = 0
	for k in 0 ..< 4 {
		p := pts[k]
		horiz := abs(p[1] - p[3]) <= 1e-4
		vert := abs(p[0] - p[2]) <= 1e-4
		if !horiz && !vert {
			return
		}
		if (abs(p[0] - minx) > 1e-4 && abs(p[0] - maxx) > 1e-4) ||
		   (abs(p[2] - minx) > 1e-4 && abs(p[2] - maxx) > 1e-4) ||
		   (abs(p[1] - miny) > 1e-4 && abs(p[1] - maxy) > 1e-4) ||
		   (abs(p[3] - miny) > 1e-4 && abs(p[3] - maxy) > 1e-4) {
			return
		}
		if vert && abs(p[0] - minx) <= 1e-4 {
			left_dy += p[3] - p[1]
		}
	}
	if abs(abs(left_dy) - (maxy - miny)) > 1e-3 {
		return
	}
	ix0, iy0 := i32(math.round(minx)), i32(math.round(miny))
	ix1, iy1 := i32(math.round(maxx)), i32(math.round(maxy))
	if abs(f32(ix0) - minx) > 1e-4 || abs(f32(iy0) - miny) > 1e-4 || abs(f32(ix1) - maxx) > 1e-4 || abs(f32(iy1) - maxy) > 1e-4 {
		return
	}
	if ix0 >= ix1 || iy0 >= iy1 || ix0 < ox_i || iy0 < oy_i || ix1 > ox_i + i32(tex.width) || iy1 > oy_i + i32(tex.height) {
		return
	}
	return tex, bop, ix0, iy0, ix1, iy1, ox_i, oy_i, true
}

@(private = "file")
sw_can_blit_image :: proc(b: ^Software_Backend, images: ^Image_Store, cmd: Command, target: Sw_Target, twin: Sw_Twin, idx: u32, inst: Shape_Instance, frame_words: []u32) -> bool {
	words := instance_words(inst, frame_words)
	_, _, _, _, _, _, _, _, ok := sw_match_blit_image(b, images, cmd, target, twin, idx, inst, words)
	return ok
}

// Fast 1:1 RGBA8 blit for axis-aligned layer/image rectangles, matching
// shape.frag (`textureLod * inner_col * scissor_mask`) without JIT shading.
@(private = "file")
sw_blit_image :: proc(b: ^Software_Backend, images: ^Image_Store, cmd: Command, r: ^Raster, idx: u32, inst: Shape_Instance, words: []u32, px: [4]i32) -> bool {
	src_tex, op, rx0, ry0, rx1, ry1, ox, oy, ok := sw_match_blit_image(b, images, cmd, r.target, r.twin, idx, inst, words)
	if !ok {
		return false
	}
	x0 := max(px[0], rx0)
	y0 := max(px[1], ry0)
	x1 := min(px[2], rx1)
	y1 := min(px[3], ry1)
	if x0 >= x1 || y0 >= y1 {
		return true
	}
	w := int(x1 - x0)
	pr := &b.paint_rows[inst.paint]
	tint := pr[6]
	has_scissor, in_x0, in_x1, alive := sw_scissor_x(pr, int(x0), w, op == .Copy)
	if !alive {
		return true
	}
	unit_tint := tint == {1, 1, 1, 1}
	tint4 := simd.from_array(tint)
	src_px := slice.reinterpret([]u32, src_tex.pixels)
	dst_px := slice.reinterpret([]u32, r.target.pixels)
	src_stride := int(src_tex.width)
	dst_stride := int(r.target.width)
	sx0 := int(x0 - ox)
	dx0 := int(x0 - r.ox)
	ax, bx, ex, sx := pr[0][0], pr[2][0], pr[8][0], pr[8][2]
	ay, by, ey, sy := pr[1][1], pr[2][1], pr[8][1], pr[8][3]
	inv255 := #simd[4]f32{1.0 / 255, 1.0 / 255, 1.0 / 255, 1.0 / 255}
	half := #simd[4]f32{0.5, 0.5, 0.5, 0.5}
	c255 := #simd[4]f32{255, 255, 255, 255}

	blend_px :: #force_inline proc "contextless" (dst: ^u32, su: u32, op: Sw_Blit_Op, scale: #simd[4]f32, inv255, half, c255: #simd[4]f32) {
		sb := transmute([4]u8)su
		sf := #simd[4]f32{f32(sb[0]), f32(sb[1]), f32(sb[2]), f32(sb[3])} * inv255 * scale
		sf = simd.clamp(sf, 0, 1)
		switch op {
		case .Copy:
			dst^ = transmute(u32)cast(#simd[4]u8)simd.clamp(sf * 255 + half, 0, 255)
		case .Source_Over:
			sa := simd.extract(sf, 3)
			if sa >= 1 {
				dst^ = transmute(u32)cast(#simd[4]u8)simd.clamp(sf * 255 + half, 0, 255)
			} else if sf != {} {
				db := transmute([4]u8)dst^
				df := #simd[4]f32{f32(db[0]), f32(db[1]), f32(db[2]), f32(db[3])}
				ia := 1 - sa
				out := simd.fma(df, #simd[4]f32{ia, ia, ia, ia}, simd.fma(sf, c255, half))
				dst^ = transmute(u32)cast(#simd[4]u8)simd.clamp(out, 0, 255)
			}
		case .Source_In:
			da := f32(u8(dst^ >> 24)) * (1.0 / 255)
			dst^ = transmute(u32)cast(#simd[4]u8)simd.clamp(sf * (da * 255) + half, 0, 255)
		case .Destination_Out:
			sa := simd.extract(sf, 3)
			if sa >= 1 {
				dst^ = 0
			} else if sa > 0 {
				db := transmute([4]u8)dst^
				df := #simd[4]f32{f32(db[0]), f32(db[1]), f32(db[2]), f32(db[3])}
				ia := 1 - sa
				dst^ = transmute(u32)cast(#simd[4]u8)simd.clamp(df * #simd[4]f32{ia, ia, ia, ia} + half, 0, 255)
			}
		}
	}

	for y in y0 ..< y1 {
		my: f32 = 1
		if has_scissor {
			my = clamp(0.5 - (abs(ay * (f32(y) + 0.5) + by) - ey) * sy, 0, 1)
			if my <= 0 && op != .Copy && op != .Source_In {
				continue
			}
		}
		srow := src_px[int(y - oy) * src_stride + sx0 :][:w]
		drow := dst_px[int(y - r.oy) * dst_stride + dx0 :][:w]
		row_full := my >= 1
		i0 := in_x0 if row_full else 0
		i1 := in_x1 if row_full else 0

		for cx in 0 ..< i0 {
			mx := my * clamp(0.5 - (abs(ax * (f32(x0 + i32(cx)) + 0.5) + bx) - ex) * sx, 0, 1)
			blend_px(&drow[cx], srow[cx], op, tint4 * #simd[4]f32{mx, mx, mx, mx}, inv255, half, c255)
		}

		if i1 > i0 {
			sr := srow[i0:i1]
			dr := drow[i0:i1]
			if unit_tint {
				switch op {
				case .Copy:
					copy(dr, sr)
				case .Source_Over:
					for su, cx in sr {
						if su == 0 {
							continue
						}
						if (su >> 24) == 255 {
							dr[cx] = su
							continue
						}
						sb := transmute([4]u8)su
						db := transmute([4]u8)dr[cx]
						sf := #simd[4]f32{f32(sb[0]), f32(sb[1]), f32(sb[2]), f32(sb[3])}
						df := #simd[4]f32{f32(db[0]), f32(db[1]), f32(db[2]), f32(db[3])}
						ia := 1 - f32(sb[3]) * (1.0 / 255)
						out := simd.fma(df, #simd[4]f32{ia, ia, ia, ia}, sf + half)
						dr[cx] = transmute(u32)cast(#simd[4]u8)simd.clamp(out, 0, 255)
					}
				case .Source_In:
					for su, cx in sr {
						du := dr[cx]
						if du == 0 {
							continue
						}
						da8 := du >> 24
						if da8 == 0 {
							dr[cx] = 0
							continue
						}
						if da8 == 255 {
							dr[cx] = su
							continue
						}
						if su == 0 {
							dr[cx] = 0
							continue
						}
						sb := transmute([4]u8)su
						sf := #simd[4]f32{f32(sb[0]), f32(sb[1]), f32(sb[2]), f32(sb[3])}
						da := f32(da8) * (1.0 / 255)
						dr[cx] = transmute(u32)cast(#simd[4]u8)simd.clamp(sf * #simd[4]f32{da, da, da, da} + half, 0, 255)
					}
				case .Destination_Out:
					for su, cx in sr {
						if su == 0 {
							continue
						}
						sa8 := su >> 24
						if sa8 == 255 {
							dr[cx] = 0
							continue
						}
						if sa8 == 0 {
							continue
						}
						db := transmute([4]u8)dr[cx]
						df := #simd[4]f32{f32(db[0]), f32(db[1]), f32(db[2]), f32(db[3])}
						ia := 1 - f32(sa8) * (1.0 / 255)
						dr[cx] = transmute(u32)cast(#simd[4]u8)simd.clamp(df * #simd[4]f32{ia, ia, ia, ia} + half, 0, 255)
					}
				}
			} else {
				for su, cx in sr {
					if su == 0 && op != .Copy && op != .Source_In {
						continue
					}
					blend_px(&dr[cx], su, op, tint4, inv255, half, c255)
				}
			}
		}

		for cx in i1 ..< w {
			mx := my
			if has_scissor && (cx < in_x0 || cx >= in_x1) {
				mx *= clamp(0.5 - (abs(ax * (f32(x0 + i32(cx)) + 0.5) + bx) - ex) * sx, 0, 1)
			}
			blend_px(&drow[cx], srow[cx], op, tint4 * #simd[4]f32{mx, mx, mx, mx}, inv255, half, c255)
		}
	}
	return true
}

@(private = "file")
sw_solid_blend :: proc "contextless" (blend: Composite_Operation_State) -> (ok: bool, is_copy: bool) {
	if blend == composite_state_from_op(.Source_Over) {
		return true, false
	}
	if blend == composite_state_from_op(.Copy) {
		return true, true
	}
	return false, false
}

@(private = "file")
sw_can_fill_solid :: proc "contextless" (b: ^Software_Backend, cmd: Command, target: Sw_Target, inst: Shape_Instance) -> bool {
	if b.no_fast_paths || target.format != .RGBA8 || target.pixels == nil {
		return false
	}
	if inst.hairline > 0 || inst.marker != .None || inst.widen != 0 || inst.edge == .Aliased {
		return false
	}
	blend_ok, _ := sw_solid_blend(cmd.composite_operation)
	if !blend_ok {
		return false
	}
	pr := &b.paint_rows[inst.paint]
	return pr[10][3] == f32(Shader_Type.Fill_Color) && pr[0][1] == 0 && pr[1][0] == 0
}

// Fast path for solid-colour, axis-aligned-scissored fills on RGBA8 targets
// under Source_Over or Copy: accumulates coverage directly over `px`, skips empty
// spans and fills interior full-coverage spans without running the shader or
// building 2x2 quad lists. False when the instance must fall back.
@(private = "file")
sw_fill_solid :: proc(L: ^Sw_Lanes, r: ^Raster, b: ^Software_Backend, i: u32, inst: Shape_Instance, px: [4]i32, band: int) -> bool {
	if b.no_fast_paths || r.target.format != .RGBA8 || r.target.pixels == nil {
		return false
	}
	if inst.edge == .Aliased || b.piece_at[i] == max(u32) {
		return false
	}
	blend_ok, is_copy := sw_solid_blend(r.blend)
	if !blend_ok {
		return false
	}
	pr := &b.paint_rows[inst.paint]
	if pr[10][3] != f32(Shader_Type.Fill_Color) || pr[0][1] != 0 || pr[1][0] != 0 {
		return false
	}
	x0, y0, x1, y1 := px[0], px[1], px[2], px[3]
	if x0 >= x1 || y0 >= y1 {
		return true
	}
	w, h := int(x1 - x0), int(y1 - y0)
	// Axis-aligned scissor bounds where x mask == 1 across all rows.
	ax, bx, ex, sx := pr[0][0], pr[2][0], pr[8][0], pr[8][2]
	ay, by, ey, sy := pr[1][1], pr[2][1], pr[8][1], pr[8][3]
	has_scissor, in_x0, in_x1, alive := sw_scissor_x(pr, int(x0), w, is_copy)
	if !alive {
		return true
	}
	at := int(b.piece_at[i]) + band - int(b.piece_band0[i])
	list := b.piece_list[b.piece_rows[at]:b.piece_rows[at + 1]]
	stride := w + 1
	sw_accumulate_pieces(L, b, list, x0, y0, w, h, stride)

	// Base premultiplied color scaled by stroke_mask(0.5, 1).
	base := saturate4(pr[6] * min(f32(1), pr[10][0]))
	packed_src := transmute(u32)to_unorm8x4(base)
	opaque_src := is_copy || base[3] >= 1
	base255_s := simd.from_array(base * 255)
	base255 := simd.from_array(base * 255 + 0.5)
	base_a := base[3]
	inv_a := #simd[4]f32{1 - base[3], 1 - base[3], 1 - base[3], 1 - base[3]}

	moves := r.twin.pixels != nil && int(i) < len(b.motion_rows) && b.motion_rows[i][1][2] != 0
	m: Shader_Motion
	if moves {
		m = b.motion_rows[i]
	}

	FULL :: 1 - 1.0 / 4096
	EMPTY :: 1.0 / 510
	even_odd := inst.rule == .Even_Odd
	smooth := inst.edge == .Smooth
	dst_stride := int(r.target.width)
	dst_px := slice.reinterpret([]u32, r.target.pixels)
	dst_x0 := int(x0 - r.ox)

	blend_partial :: #force_inline proc "contextless" (dst: ^u32, base255_s: #simd[4]f32, base_a, k: f32, is_copy: bool) -> f32 {
		ca := base_a * k
		src := simd.fma(base255_s, #simd[4]f32{k, k, k, k}, #simd[4]f32{0.5, 0.5, 0.5, 0.5})
		if is_copy {
			dst^ = transmute(u32)cast(#simd[4]u8)simd.clamp(src, 0, 255)
			return ca
		}
		d := transmute([4]u8)dst^
		df := #simd[4]f32{f32(d[0]), f32(d[1]), f32(d[2]), f32(d[3])}
		ia := 1 - ca
		out := simd.fma(df, #simd[4]f32{ia, ia, ia, ia}, src)
		dst^ = transmute(u32)cast(#simd[4]u8)simd.clamp(out, 0, 255)
		return ca
	}

	write_motion :: #force_inline proc "contextless" (twin: Sw_Twin, tx, ty: int, m: Shader_Motion, px_x, px_y, ca: f32) {
		vx := m[0][0] * px_x + m[0][2] * px_y + m[1][0]
		vy := m[0][1] * px_x + m[0][3] * px_y + m[1][1]
		mo := [4]f32{vx, vy, m[1][2], 1} * ca
		d := &twin.pixels[ty * int(twin.width) + tx]
		d^ = mo + d^ * (1 - mo[3])
	}

	for row in 0 ..< h {
		py_c := f32(y0 + i32(row)) + 0.5
		my: f32 = 1
		if has_scissor {
			my = clamp(0.5 - (abs(ay * py_c + by) - ey) * sy, 0, 1)
			if my <= 0 && !is_copy {
				continue
			}
		}
		acc := L.cov[row * stride:][:stride]
		ty := int(y0 + i32(row) - r.oy)
		drow := dst_px[ty * dst_stride + dst_x0 :][:w]
		full_scissor := my >= 1
		sum: f32 = 0
		x := 0
		for x < w {
			sum += acc[x]
			raw := abs(sum)
			cov := 1 - abs(1 - (raw * 0.5 - math.floor(raw * 0.5)) * 2) if even_odd else min(raw, 1)
			if cov < EMPTY {
				x = sw_skip_zeros(acc, x + 1, w)
				continue
			}
			if cov >= FULL && full_scissor && x >= in_x0 && x < in_x1 {
				start := x
				x = sw_skip_zeros(acc, x + 1, in_x1)
				if opaque_src {
					for &px_out in drow[start:x] {
						px_out = packed_src
					}
				} else {
					for &px_out in drow[start:x] {
						d := transmute([4]u8)px_out
						df := #simd[4]f32{f32(d[0]), f32(d[1]), f32(d[2]), f32(d[3])}
						px_out = transmute(u32)cast(#simd[4]u8)simd.clamp(simd.fma(df, inv_a, base255), 0, 255)
					}
				}
				if moves {
					for cx in start ..< x {
						write_motion(r.twin, dst_x0 + cx, ty, m, f32(x0 + i32(cx)) + 0.5, py_c, base[3])
					}
				}
				continue
			}
			v := cov * cov * (3 - 2 * cov) if smooth else cov
			mx := my
			px_c := f32(x0 + i32(x)) + 0.5
			if has_scissor && (x < in_x0 || x >= in_x1) {
				mx *= clamp(0.5 - (abs(ax * px_c + bx) - ex) * sx, 0, 1)
			}
			if mx > 0 || is_copy {
				ca := blend_partial(&drow[x], base255_s, base_a, v * mx, is_copy)
				if moves {
					write_motion(r.twin, dst_x0 + x, ty, m, px_c, py_c, ca)
				}
			}
			x += 1
		}
	}
	return true
}

// Returns the smallest index in `start ..< limit` where `acc[i] != 0`, or `limit`.
@(private = "file")
sw_skip_zeros :: #force_inline proc "contextless" (acc: []f32, start, limit: int) -> int {
	x := start
	lim := min(limit, len(acc))
	ptr := raw_data(acc)
	zero := #simd[4]f32{}
	for x + 8 <= lim {
		v0 := intrinsics.unaligned_load((^#simd[4]f32)(&ptr[x]))
		v1 := intrinsics.unaligned_load((^#simd[4]f32)(&ptr[x + 4]))
		m := simd.bit_or(simd.lanes_ne(v0, zero), simd.lanes_ne(v1, zero))
		if simd.reduce_or(m) != 0 {
			break
		}
		x += 8
	}
	if x + 4 <= lim {
		v := intrinsics.unaligned_load((^#simd[4]f32)(&ptr[x]))
		if simd.reduce_or(simd.lanes_ne(v, zero)) == 0 {
			x += 4
		}
	}
	for x < lim && ptr[x] == 0 {
		x += 1
	}
	return x
}

// Adds a stretch [ta, tb] of P(t) = a t^2 + b t + c (grid units, monotone in
// x and y, within one row) to that row's cells: per column it crosses, the
// signed area between it and the column's right side (to that pixel), and
// the rest of its rise (to the next).
@(private = "file")
sw_accumulate_cells :: proc "contextless" (acc: []f32, a, b, c: [2]f32, ta, tb, xa, ya, xb, yb: f32, w: int) {
	if max(xa, xb) <= 0 {
		acc[0] += yb - ya
		return
	}
	if min(xa, xb) >= f32(w) {
		return
	}
	d := tb - ta
	if max(abs(a.x), abs(a.y)) * (d * d) <= 1.0 / 256 {
		sw_accumulate_row_line(acc, xa, ya, xb, yb, w)
		return
	}
	if xb >= xa {
		if xa >= 0 {
			col := sw_floor(xa)
			if xb <= f32(col + 1) {
				dy := yb - ya
				area := sw_cell_area(a, b, f32(col + 1) - xa, ta, d)
				acc[col] += area
				acc[col + 1] += dy - area
				return
			}
		}
	} else {
		if xb >= 0 && xa <= f32(w) {
			col := sw_ceil(xa) - 1
			if xb >= f32(col) {
				dy := yb - ya
				area := sw_cell_area(a, b, f32(col + 1) - xa, ta, d)
				acc[col] += area
				acc[col + 1] += dy - area
				return
			}
		}
	}
	t, x, y := ta, xa, ya
	step: i32 = 1 if xb > xa else -1
	if step > 0 && x < 0 {
		u0 := sw_solve_monotone(a.x, b.x, c.x, t, tb, x, xb, 0)
		y0 := sw_quad_at(a.y, b.y, c.y, u0)
		acc[0] += y0 - y
		t, x, y = u0, 0, y0
	} else if step < 0 && x > f32(w) {
		u0 := sw_solve_monotone(a.x, b.x, c.x, t, tb, x, xb, f32(w))
		y0 := sw_quad_at(a.y, b.y, c.y, u0)
		t, x, y = u0, f32(w), y0
	}
	col := sw_floor(x) if xb >= xa else sw_ceil(x) - 1
	for {
		if col >= i32(w) {
			break
		}
		if col < 0 {
			acc[0] += yb - y
			break
		}
		// Where it leaves this column, or its end.
		side := f32(col + 1) if step > 0 else f32(col)
		u, xu := tb, xb
		if (step > 0 && xb > side) || (step < 0 && xb < side) {
			u = sw_solve_monotone(a.x, b.x, c.x, t, tb, x, xb, side)
			xu = side
		}
		yu := yb if u >= tb else sw_quad_at(a.y, b.y, c.y, u)
		dy := yu - y
		// The area between the piece and the column's right side, by
		// the integral of (right - x(t)) y'(t) over [t, u], about t.
		area := sw_cell_area(a, b, f32(col + 1) - x, t, u - t)
		acc[col] += area
		acc[col + 1] += dy - area
		if u >= tb {
			break
		}
		t, x, y = u, xu, yu
		col += step
	}
}

// The integral over s in [0, d] of (g0 - (x(t + s) - x(t))) y'(t + s), where
// x and y are a t^2 + b t + c: g0 is the column's right side less x(t).
@(private = "file")
sw_cell_area :: #force_inline proc "contextless" (a, b: [2]f32, g0, t, d: f32) -> f32 {
	// x(t + s) - x(t) = dx s + a.x s^2, y'(t + s) = dy + 2 a.y s.
	dx := 2 * a.x * t + b.x
	dy := 2 * a.y * t + b.y
	// (g0 - dx s - a.x s^2)(dy + 2 a.y s)
	c0 := g0 * dy
	c1 := 2 * a.y * g0 - dx * dy
	c2 := -2 * a.y * dx - a.x * dy
	c3 := -2 * a.y * a.x
	return d * (c0 + d * (c1 * 0.5 + d * (c2 * (1.0 / 3.0) + d * c3 * 0.25)))
}

@(private = "file")
sw_quad_at :: #force_inline proc "contextless" (a, b, c, s: f32) -> f32 {
	return (a * s + b) * s + c
}

// The s in [sa, sb] where a s^2 + b s + c = v, the quadratic monotone there
// from ya to yb (v between them): the root within the range, by the stable
// form of the quadratic formula.
@(private = "file")
sw_solve_monotone :: proc "contextless" (a, b, c, sa, sb, ya, yb, v: f32) -> f32 {
	if v == ya {
		return sa
	}
	if v == yb {
		return sb
	}
	s: f32
	cv := c - v
	if abs(a) <= 1e-7 * abs(b) {
		s = -cv / b
	} else {
		sq := math.sqrt(max(b * b - 4 * a * cv, 0))
		q := -0.5 * (b + (sq if b >= 0 else -sq))
		r1 := q / a
		r2 := cv / q if q != 0 else r1
		s = r1 if abs(r1 - (sa + sb) * 0.5) <= abs(r2 - (sa + sb) * 0.5) else r2
	}
	return clamp(s, sa, sb)
}

// A fill instance's coverage over the quads of `px` in band `band` (on
// sw_shade_rect's grid), by accumulation: each piece adds, to each pixel
// cell it crosses, the signed area between it and the cell's right side,
// and the rest of its rise to the next cell, so a row's running sum is each
// pixel's signed area, read by the fill rule as curves_fill reads the
// shader's. That is the area the shader integrates over the pixel's
// footprint, which for a fill without widen is the pixel's box. Its quads
// covered whole go to `L.inside`, those with any coverage to `L.edge`, and
// the coverage to `L.cov` (one f32 a pixel of the grid, row by row). False,
// working out nothing, when the instance has no pieces (sw_build_pieces) or
// the band more pieces than quads.
@(private = "file")
sw_coverage :: proc(L: ^Sw_Lanes, b: ^Software_Backend, i: u32, inst: Shape_Instance, px: [4]i32, band: int) -> bool {
	clear(&L.edge)
	clear(&L.inside)
	if b.piece_at[i] == max(u32) {
		return false
	}
	x0, y0, x1, y1 := px[0], px[1], px[2], px[3]
	if x0 >= x1 || y0 >= y1 {
		return true
	}
	qx0, qy0 := x0 &~ 1, y0 &~ 1
	nqx := int(x1 - qx0 + 1) / 2
	nqy := int(y1 - qy0 + 1) / 2
	at := int(b.piece_at[i]) + band - int(b.piece_band0[i])
	list := b.piece_list[b.piece_rows[at]:b.piece_rows[at + 1]]
	w, h := 2 * nqx, 2 * nqy
	// One more column: a piece's rise past the last cell.
	stride := w + 1
	sw_accumulate_pieces(L, b, list, qx0, qy0, w, h, stride)
	even_odd := inst.rule == .Even_Odd
	for row in 0 ..< h {
		acc := L.cov[row * stride:][:stride]
		sum: f32 = 0
		for &v in acc[:w] {
			sum += v
			cov := abs(sum)
			v = 1 - abs(1 - (cov * 0.5 - math.floor(cov * 0.5)) * 2) if even_odd else min(cov, 1)
		}
	}
	FULL :: 1 - 1.0 / 4096
	EMPTY :: 1.0 / 510
	for qr in 0 ..< nqy {
		for q in 0 ..< nqx {
			o := [2]i32{qx0 + 2 * i32(q), qy0 + 2 * i32(qr)}
			full, any := true, false
			for l in 0 ..< 4 {
				px_x, px_y := o.x + i32(l & 1), o.y + i32(l >> 1)
				if px_x < x0 || px_x >= x1 || px_y < y0 || px_y >= y1 {
					continue
				}
				v := L.cov[(2 * qr + (l >> 1)) * stride + 2 * q + (l & 1)]
				full &&= v >= FULL
				any ||= v >= EMPTY
			}
			if full {
				append(&L.inside, o)
			} else if any {
				append(&L.edge, o)
			}
		}
	}
	return true
}
