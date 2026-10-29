package ovg

import "base:runtime"
import "core:math"
import "core:mem"
import "core:slice"
import common "deps:odecs/common"
import cv "deps:ocurves"

// CPU rasterizer writing RGBA8. It evaluates the same per-fragment formulas
// as the GPU fragment shader (shaders/ovg.slang) and the same shape
// coverage, so its output is a pixel reference for GPU backends: one
// sample at each pixel center, blending in [0, 1] with rounding to 8 bits.
Software_Backend :: struct {
	allocator: mem.Allocator,
	pixels:    []u8,
	width:     u32,
	height:    u32,
	target:    Image_Id,
	// The target's `Cmd_Set_Render_Target.origin`.
	origin:    [2]i32,
	// The intermediate of a blur's two passes, reused.
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
	// The caller's pool a frame's row bands run on (odecs' Work_Pool: one
	// band a range); nil runs them all on the calling thread. A band takes
	// a group's scratch from context.temp_allocator, so each of the pool's
	// threads must have its own (an Odin thread's default, as odecs'
	// Static_Pool's workers do).
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
}

software_backend_init :: proc(b: ^Software_Backend, allocator := context.allocator) {
	b^ = {allocator = allocator}
	b.binned = make([dynamic]Sw_Binned, allocator)
	b.starts = make([dynamic]u32, allocator)
	b.bounds = make([dynamic]Bounds, allocator)
	b.twin_at = make([dynamic]int, allocator)
	b.velocity = make([dynamic][2]f32, allocator)
	b.nearness = make([dynamic]f32, allocator)
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
	b.pixels = make([]u8, int(width * height * 4), b.allocator)
	b.width = width
	b.height = height
}

@(private = "file")
sw_alloc_image :: proc(data: rawptr, info: Image_Info) -> (Backend_Image, Error) {
	b := (^Software_Backend)(data)
	if .Transient in info.flags {
		// Pixels are lent for each render (sw_lend).
		return {}, nil
	}
	pixels, err := make([]u8, int(info.width * info.height * bytes_per_pixel(info.format)), b.allocator)
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
		if !is_target || !is_image || !rt.velocity || b.twin_at[id.key.idx] >= 0 {
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

// A layer's motion onto the target's twin (Cmd_Composite_Velocity), over
// the part of its window inside the target.
@(private = "file")
sw_composite_velocity :: proc(b: ^Software_Backend, images: ^Image_Store, c: Cmd_Composite_Velocity) {
	src := sw_twin_of(b, images, c.source, true)
	alpha, ok := lookup_texture(images, c.alpha)
	if b.twin.pixels == nil || src.pixels == nil || !ok {
		return
	}
	// The window's corner on the target.
	wx, wy := i32(c.x) - b.origin.x, i32(c.y) - b.origin.y
	x0, y0 := max(wx, 0), max(wy, 0)
	x1 := min(wx + i32(c.w), i32(b.twin.width), wx + i32(src.width), wx + i32(alpha.width))
	y1 := min(wy + i32(c.h), i32(b.twin.height), wy + i32(src.height), wy + i32(alpha.height))
	for y in y0 ..< y1 {
		for x in x0 ..< x1 {
			sx, sy := u32(x - wx), u32(y - wy)
			twin_composite(&b.twin.pixels[int(y) * int(b.twin.width) + int(x)], src.pixels[int(sy) * int(src.width) + int(sx)], fetch(alpha, sx, sy)[3], c.opacity)
		}
	}
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

// Motion blur: a draw's motion `m` over the twin's pixel `d` at drawing
// coordinates (px, py), by its coverage `a` (its final alpha):
// premultiplied source-over, whatever the draw's blend.
@(private = "file")
twin_over :: #force_inline proc "contextless" (d: ^[4]f32, m: Shape_Motion, px, py, a: f32) {
	v := transform_point(m.velocity, px, py)
	d^ = [4]f32{v.x, v.y, m.nearness, 1} * a + d^ * (1 - a)
}

// A layer's or a group's motion `g` (a twin pixel) over the twin's pixel
// `d`, faded by `opacity` and cut to the coverage `a` it composites with
// where that is less (a clip or mask): its motion at the layer's coverage,
// or where a filter spread the layer, at its content's own.
@(private = "file")
twin_composite :: #force_inline proc "contextless" (d: ^[4]f32, g: [4]f32, a, opacity: f32) {
	s := opacity
	if g[3] > a {
		s *= a / g[3]
	}
	d^ = g * s + d^ * (1 - g[3] * s)
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
		b.transient, _ = make([]u8, total, b.allocator)
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
				for i in c.instances.start ..< c.instances.start + c.instances.count {
					if !fill {
						b.bounds[i] = instance_bounds(frame.shapes[i], frame.shape_words)
					}
					ib := b.bounds[i]
					sw_bin(&run, fill, {u32(k), i}, max(r.y0, i32(math.floor(ib.miny))), min(r.y1, i32(math.ceil(ib.maxy))))
				}
			}
		}
	}
	for band := bands; band > 0; band -= 1 {
		b.starts[band] = b.starts[band - 1]
	}
	b.starts[0] = 0
	sw_bands(b, rows, &run, sw_run_band)
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

// One band of a run: its draws, a command's together. A group's pixels
// before its tint (and their motion, on a twin) go through the band's
// scratch, in the temp arena of the thread drawing the band.
@(private = "file")
sw_run_band :: proc(data: rawptr, y0, y1: int) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	run := (^Sw_Run)(data)
	b := run.b
	k := y0 / SW_BAND_ROWS
	items := b.binned[b.starts[k]:b.starts[k + 1]]
	top, bottom := i32(y0) + run.origin.y, i32(y1) + run.origin.y
	scratch, motion: [][4]f32
	for i := 0; i < len(items); {
		j := i + 1
		for j < len(items) && items[j].cmd == items[i].cmd {
			j += 1
		}
		cmd := run.cmds[items[i].cmd]
		if c, ok := cmd.type.(Cmd_Draw_Shapes); ok && c.group != 0 && scratch == nil {
			n := int(run.target.width) * (y1 - y0)
			scratch = make([][4]f32, n, context.temp_allocator)
			if run.twin.pixels != nil {
				motion = make([][4]f32, n, context.temp_allocator)
			}
		}
		sw_band_command(run, cmd, items[i:j], top, bottom, scratch, motion)
		i = j
	}
}

// Pixels are addressed in drawing coordinates: (x, y) is target pixel
// (x - ox, y - oy), and [x0, x1) x [y0, y1) is the drawable area.
@(private = "file")
Raster :: struct {
	target:  Sw_Target,
	ox, oy:  i32,
	x0, y0:  i32,
	x1, y1:  i32,
	frag:    ^Frag,
	blend:   Composite_Operation_State,
	twin:    Sw_Twin,
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
		r.x0 = max(r.x0, i32(math.floor(sr.x)))
		r.y0 = max(r.y0, i32(math.floor(sr.y)))
		r.x1 = min(r.x1, i32(math.ceil(sr.x + sr.w)))
		r.y1 = min(r.y1, i32(math.ceil(sr.y + sr.h)))
	}
	return r
}

// A command's draws in one band, rows [top, bottom); `scratch` holds a
// group's band before its tint, and `motion` its motion.
@(private = "file")
sw_band_command :: proc(run: ^Sw_Run, cmd: Command, items: []Sw_Binned, top, bottom: i32, scratch, motion: [][4]f32) {
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
		// With a twin or not, once per command.
		twinned := r.twin.pixels != nil
		if c.group != 0 && frame.shapes[c.instances.start].marker != .None {
			if twinned {
				raster_markers(run, &r, cmd, c, items, scratch, true)
			} else {
				raster_markers(run, &r, cmd, c, items, scratch, false)
			}
			return
		} else if c.group != 0 {
			if twinned {
				raster_group(run, &r, cmd, c, items, scratch, motion, true)
			} else {
				raster_group(run, &r, cmd, c, items, scratch, motion, false)
			}
			return
		}
		frag: Frag
		row := max(u32)
		for it in items {
			inst := frame.shapes[it.inst]
			if inst.paint != row {
				frag = make_frag(run.images, cmd, frame.paints[inst.paint])
				row = inst.paint
			}
			r.frag = &frag
			// Moving or not, once per instance.
			if m := sw_motion(run, it.inst); m.nearness != 0 {
				raster_shape(&r, inst, m, run.b.bounds[it.inst], frame.shape_words, true)
			} else {
				raster_shape(&r, inst, m, run.b.bounds[it.inst], frame.shape_words, false)
			}
		}
	}
}

// Instance `i`'s motion where the run's target keeps a twin, else none
// (nearness 0).
@(private = "file")
sw_motion :: #force_inline proc "contextless" (run: ^Sw_Run, i: u32) -> Shape_Motion {
	return run.frame.motions[i] if run.twin.pixels != nil else {}
}

// The area a group's or markers' draws in a band cover, clipped to the
// raster.
@(private = "file")
sw_items_area :: proc(run: ^Sw_Run, r: ^Raster, items: []Sw_Binned) -> (x0, y0, x1, y1: i32) {
	area := EMPTY_BOUNDS
	for it in items {
		ib := run.b.bounds[it.inst]
		area = {min(area.minx, ib.minx), min(area.miny, ib.miny), max(area.maxx, ib.maxx), max(area.maxy, ib.maxy)}
	}
	x0 = max(r.x0, i32(math.floor(area.minx)))
	y0 = max(r.y0, i32(math.floor(area.miny)))
	x1 = min(r.x1, i32(math.ceil(area.maxx)))
	y1 = min(r.y1, i32(math.ceil(area.maxy)))
	return
}

// A group, as the shape shader draws it: each pixel the instances
// source-over in order (each as `raster_shape` shades it), then times the
// tint, blended once. `scratch` holds the band's pixels before the tint,
// and on a twin (`twinned`) `motion` their motion, which composites as a
// layer's.
@(private = "file")
raster_group :: proc(run: ^Sw_Run, r: ^Raster, cmd: Command, c: Cmd_Draw_Shapes, items: []Sw_Binned, scratch, motion: [][4]f32, $twinned: bool) {
	frame := run.frame
	x0, y0, x1, y1 := sw_items_area(run, r, items)
	if x0 >= x1 || y0 >= y1 {
		return
	}
	w, h := int(x1 - x0), int(y1 - y0)
	acc := scratch[:w * h]
	mem.zero_slice(acc)
	when twinned {
		vacc := motion[:w * h]
		mem.zero_slice(vacc)
	}
	frag: Frag
	row := max(u32)
	for it in items {
		inst := frame.shapes[it.inst]
		if inst.paint != row {
			frag = make_frag(run.images, cmd, frame.paints[inst.paint])
			row = inst.paint
		}
		ib := run.b.bounds[it.inst]
		ix0, iy0 := max(x0, i32(math.floor(ib.minx))), max(y0, i32(math.floor(ib.miny)))
		ix1, iy1 := min(x1, i32(math.ceil(ib.maxx))), min(y1, i32(math.ceil(ib.maxy)))
		inv := transform_inverse(inst.transform)
		u, v := instance_footprint(inst)
		words := instance_words(inst, frame.shape_words)
		when twinned {
			m := sw_motion(run, it.inst)
			moves := m.nearness != 0
		}
		for y in iy0 ..< iy1 {
			py := f32(y) + 0.5
			for x in ix0 ..< ix1 {
				px := f32(x) + 0.5
				cov := instance_coverage(inst, words, transform_point(inv, px, py), u, v)
				if cov < 1.0 / 510 {
					continue
				}
				src, keep := shade(&frag, px, py, 0.5, cov)
				if !keep {
					continue
				}
				i := int(y - y0) * w + int(x - x0)
				acc[i] = src + acc[i] * (1 - src[3])
				when twinned {
					if moves {
						twin_over(&vacc[i], m, px, py, src[3])
					}
				}
			}
		}
	}
	tint := make_frag(run.images, cmd, frame.paints[c.group - 1])
	for y in y0 ..< y1 {
		py := f32(y) + 0.5
		for x in x0 ..< x1 {
			a := acc[int(y - y0) * w + int(x - x0)]
			if a[3] < 1.0 / 510 {
				continue
			}
			px := f32(x) + 0.5
			t, keep := shade(&tint, px, py, 0.5, 1)
			if !keep {
				continue
			}
			tx, ty := u32(x - r.ox), u32(y - r.oy)
			blend_texel(r.target, tx, ty, r.blend, a * t)
			when twinned {
				twin_composite(&r.twin.pixels[ty * r.twin.width + tx], vacc[int(y - y0) * w + int(x - x0)], a[3], t[3])
			}
		}
	}
}

// A group of markers (draw_markers), as their shader draws it: each pixel
// the union of the markers' fills and of their outlines, a pixel stopping
// once both are whole (or absent), then the fill's paint at the first and
// the outlines' (the tint) at the second over it, blended once. The fill,
// its paint and the outline width are the command's first marker's, and
// so is the motion they take on a twin (`twinned`).
@(private = "file")
raster_markers :: proc(run: ^Sw_Run, r: ^Raster, cmd: Command, c: Cmd_Draw_Shapes, items: []Sw_Binned, scratch: [][4]f32, $twinned: bool) {
	frame := run.frame
	x0, y0, x1, y1 := sw_items_area(run, r, items)
	if x0 >= x1 || y0 >= y1 {
		return
	}
	w, h := int(x1 - x0), int(y1 - y0)
	// Per pixel: the fills' union, the outlines'.
	acc := scratch[:w * h]
	mem.zero_slice(acc)
	first := frame.shapes[c.instances.start]
	filled, outline := first.marker_fill, first.hairline
	for it in items {
		inst := frame.shapes[it.inst]
		ib := run.b.bounds[it.inst]
		ix0, iy0 := max(x0, i32(math.floor(ib.minx))), max(y0, i32(math.floor(ib.miny)))
		ix1, iy1 := min(x1, i32(math.ceil(ib.maxx))), min(y1, i32(math.ceil(ib.maxy)))
		inv := transform_inverse(inst.transform)
		u, v := instance_footprint(inst)
		circle := inst.marker == .Circle
		for y in iy0 ..< iy1 {
			py := f32(y) + 0.5
			for x in ix0 ..< ix1 {
				a := &acc[int(y - y0) * w + int(x - x0)]
				if (!filled || a[0] >= 1) && (outline <= 0 || a[1] >= 1) {
					continue
				}
				rc := transform_point(inv, f32(x) + 0.5, py)
				if filled {
					f := cv.marker(circle, rc, u, v, 0)
					a[0] += f - a[0] * f
				}
				if outline > 0 {
					o := cv.marker(circle, rc, u, v, outline)
					a[1] += o - a[1] * o
				}
			}
		}
	}
	fill := make_frag(run.images, cmd, frame.paints[first.paint])
	tint := make_frag(run.images, cmd, frame.paints[c.group - 1])
	when twinned {
		m := sw_motion(run, c.instances.start)
		moves := m.nearness != 0
	}
	for y in y0 ..< y1 {
		py := f32(y) + 0.5
		for x in x0 ..< x1 {
			a := acc[int(y - y0) * w + int(x - x0)]
			px := f32(x) + 0.5
			src: [4]f32
			if a[0] >= 1.0 / 510 {
				if f, keep := shade(&fill, px, py, 0.5, a[0]); keep {
					src = f
				}
			}
			if a[1] >= 1.0 / 510 {
				if o, keep := shade(&tint, px, py, 0.5, a[1]); keep {
					src = o + src * (1 - o[3])
				}
			}
			if src[3] < 1.0 / 510 {
				continue
			}
			tx, ty := u32(x - r.ox), u32(y - r.oy)
			blend_texel(r.target, tx, ty, r.blend, src)
			when twinned {
				if moves {
					twin_over(&r.twin.pixels[ty * r.twin.width + tx], m, px, py, src[3])
				}
			}
		}
	}
}

// Every pixel center of the instance's bounds `ib` (instance_bounds): its
// coverage (shape.odin) as the paint's edge coverage, as the shader does,
// and if it `moves` its motion `m` on the twin.
@(private = "file")
raster_shape :: proc(r: ^Raster, inst: Shape_Instance, m: Shape_Motion, ib: Bounds, frame_words: []u32, $moves: bool) {
	x0 := max(r.x0, i32(math.floor(ib.minx)))
	y0 := max(r.y0, i32(math.floor(ib.miny)))
	x1 := min(r.x1, i32(math.ceil(ib.maxx)))
	y1 := min(r.y1, i32(math.ceil(ib.maxy)))
	inv := transform_inverse(inst.transform)
	u, v := instance_footprint(inst)
	words := instance_words(inst, frame_words)
	for y in y0 ..< y1 {
		py := f32(y) + 0.5
		for x in x0 ..< x1 {
			px := f32(x) + 0.5
			cov := instance_coverage(inst, words, transform_point(inv, px, py), u, v)
			// Rounding's slivers where the shape is absent (as the shader).
			if cov < 1.0 / 510 {
				continue
			}
			src, keep := shade(r.frag, px, py, 0.5, cov)
			if !keep {
				continue
			}
			tx, ty := u32(x - r.ox), u32(y - r.oy)
			blend_texel(r.target, tx, ty, r.blend, src)
			when moves {
				twin_over(&r.twin.pixels[ty * r.twin.width + tx], m, px, py, src[3])
			}
		}
	}
}

// The coverage of the instance's pixel centered at `rc` (shape units) with
// sides `u` and `v` (instance_footprint): the shape shader's.
@(private = "file")
instance_coverage :: proc "contextless" (inst: Shape_Instance, words: []u32, rc, u, v: Vec2) -> f32 {
	if inst.marker != .None {
		return cv.marker(inst.marker == .Circle, rc, u, v, inst.hairline)
	}
	if inst.hairline > 0 {
		return cv.hairline(words, rc, u, v, inst.hairline)
	}
	if inst.aliased {
		// Off center as the shader samples it.
		w := cv.winding(words, rc + (u + v) / 64)
		return 1 if cv.fill_inside(w, inst.rule) else 0
	}
	return shape_coverage(words, rc, u, v, inst.rule)
}

@(private = "file")
sw_clear_rect :: proc(r: ^Raster, c: Cmd_Clear_Rect) {
	x0 := max(r.x0, i32(c.x))
	y0 := max(r.y0, i32(c.y))
	x1 := min(r.x1, i32(c.x + c.w))
	y1 := min(r.y1, i32(c.y + c.h))
	col := color_to_array(premultiplied(c.color))
	for y in y0 ..< y1 {
		for x in x0 ..< x1 {
			store_texel(r.target, u32(x - r.ox), u32(y - r.oy), col)
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

// ---- fragment evaluation (mirrors shaders/ovg.slang) ---------------------

@(private = "file")
Sw_Texture :: struct {
	pixels: []u8,
	width:  u32,
	height: u32,
	format: Pixel_Format,
	flags:  Image_Flags,
}

@(private = "file")
Frag :: struct {
	p:       Params,
	tex:     Sw_Texture,
	has_tex: bool,
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
	return {entry.image.pixels, entry.info.width, entry.info.height, entry.info.format, entry.info.flags}, true
}

@(private = "file")
make_frag :: proc(images: ^Image_Store, cmd: Command, p: Params) -> (f: Frag) {
	f.p = p
	f.tex, f.has_tex = lookup_texture(images, cmd.image)
	return
}

@(private = "file")
paint_point :: #force_inline proc "contextless" (m: [12]f32, px, py: f32) -> Vec2 {
	return {m[0] * px + m[4] * py + m[8], m[1] * px + m[5] * py + m[9]}
}

@(private = "file")
sd_round_rect :: proc "contextless" (pt, ext: Vec2, rad: f32) -> f32 {
	d := Vec2{abs(pt.x), abs(pt.y)} - (ext - rad)
	return min(max(d.x, d.y), 0) + math.hypot(max(d.x, 0), max(d.y, 0)) - rad
}

@(private = "file")
mix4 :: #force_inline proc "contextless" (a, b: [4]f32, t: f32) -> [4]f32 {
	return a * (1 - t) + b * t
}

@(private = "file")
conic_fraction :: proc "contextless" (p: Params, px, py: f32) -> f32 {
	pt := paint_point(p.paint_mat, px, py)
	return -math.atan2(pt.x, pt.y) / math.TAU + 0.5
}

@(private = "file")
apply_tex_type :: #force_inline proc "contextless" (c: [4]f32, tex_type: f32) -> [4]f32 {
	switch int(tex_type) {
	case 1:
		return {c[0] * c[3], c[1] * c[3], c[2] * c[3], c[3]}
	case 2:
		return {c[0], c[0], c[0], c[0]}
	}
	return c
}

// One fragment: the color to blend, or `keep = false` for a discard.
@(private = "file")
shade :: proc(f: ^Frag, px, py, u, v: f32) -> (result: [4]f32, keep: bool) {
	p := &f.p

	stroke_alpha: f32 = 1
	if p.shader_type != .Texture_Copy_Unclipped {
		stroke_alpha = min(1, (1 - abs(u * 2 - 1)) * p.stroke_mult) * min(1, v)
		if p.smooth_edge {
			stroke_alpha = stroke_alpha * stroke_alpha * (3 - 2 * stroke_alpha)
		}
		if stroke_alpha < p.stroke_thr {
			return {}, false
		}
	}

	switch p.shader_type {
	case .Fill_Gradient:
		result = mix4(p.inner_col, p.outer_col, gradient_t(p, px, py))
	case .Fill_Image_Gradient:
		// The ramp is the stops; inner_col carries the paint's alpha.
		d := gradient_t(p, px, py)
		result = sample(f.tex, d, 0) * p.inner_col if f.has_tex else p.inner_col
	case .Fill_Gradient_Conic:
		result = mix4(p.inner_col, p.outer_col, conic_fraction(p^, px, py))
	case .Fill_Image_Gradient_Conic:
		result = sample(f.tex, conic_fraction(p^, px, py), 0) * p.inner_col if f.has_tex else p.inner_col
	case .Fill_Image:
		if f.has_tex {
			pt := paint_point(p.paint_mat, px, py) / p.extent
			result = apply_tex_type(sample(f.tex, pt.x, pt.y), p.tex_type) * p.inner_col
		} else {
			result = p.inner_col
		}
	case .Texture_Copy_Unclipped:
		result = apply_tex_type(sample(f.tex, u, v), p.tex_type) * p.inner_col if f.has_tex else p.inner_col
		return result, true
	case .Fill_Color, .Fill_Color_Unclipped, .Filter_Image, .Filter_Color_Matrix, .Filter_Blend, .Filter_Composite, .Filter_Color_Space, .Filter_Component_Transfer, .Filter_Morphology, .Filter_Lighting, .Filter_Tile, .Filter_Displacement, .Filter_Convolve, .Filter_Turbulence:
		result = p.inner_col
	}

	// Rotated scissor; always 1 when no scissor is set.
	sp := paint_point(p.scissor_mat, px, py)
	sc := Vec2{0.5, 0.5} - (Vec2{abs(sp.x), abs(sp.y)} - p.scissor_ext) * p.scissor_scale
	scissor := clamp(sc.x, 0, 1) * clamp(sc.y, 0, 1)

	if p.shader_type != .Filter_Image {
		result *= stroke_alpha * scissor
	}
	return result, true
}

// ---- texels -------------------------------------------------------------------------

// Texel as a GPU sampler returns it: Gray8 and Gray16 are (g, 0, 0, 1), RGB8
// has alpha 1.
@(private = "file")
fetch :: #force_inline proc "contextless" (t: Sw_Texture, x, y: u32) -> [4]f32 {
	i := int(y * t.width + x)
	switch t.format {
	case .RGBA8:
		p := t.pixels[i * 4:]
		return {f32(p[0]), f32(p[1]), f32(p[2]), f32(p[3])} / 255
	case .RGB8:
		p := t.pixels[i * 3:]
		return {f32(p[0]) / 255, f32(p[1]) / 255, f32(p[2]) / 255, 1}
	case .Gray8:
		return {f32(t.pixels[i]) / 255, 0, 0, 1}
	case .Gray16:
		return {f32(u16(t.pixels[i * 2]) | u16(t.pixels[i * 2 + 1]) << 8) / 65535, 0, 0, 1}
	case .RGBA16F:
		p := (^[4]u16)(&t.pixels[i * 8])^
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
wrap_coord :: #force_inline proc "contextless" (c: i32, dim: u32, repeat: bool) -> u32 {
	d := i32(dim)
	if repeat {
		r := c % d
		return u32(r + d if r < 0 else r)
	}
	return u32(clamp(c, 0, d - 1))
}

// GPU texture lookup at normalized (u, v) honouring repeat and nearest flags.
@(private = "file")
sample :: proc "contextless" (t: Sw_Texture, u, v: f32) -> [4]f32 {
	if t.width == 0 || t.height == 0 {
		return {}
	}
	rx := .Repeat_X in t.flags
	ry := .Repeat_Y in t.flags
	fw, fh := f32(t.width), f32(t.height)
	if .Nearest in t.flags {
		x := wrap_coord(i32(math.floor(u * fw)), t.width, rx)
		y := wrap_coord(i32(math.floor(v * fh)), t.height, ry)
		return fetch(t, x, y)
	}
	fx := u * fw - 0.5
	fy := v * fh - 0.5
	ix := i32(math.floor(fx))
	iy := i32(math.floor(fy))
	tx := fx - f32(ix)
	ty := fy - f32(iy)
	x0 := wrap_coord(ix, t.width, rx)
	x1 := wrap_coord(ix + 1, t.width, rx)
	y0 := wrap_coord(iy, t.height, ry)
	y1 := wrap_coord(iy + 1, t.height, ry)
	top := mix4(fetch(t, x0, y0), fetch(t, x1, y0), tx)
	bot := mix4(fetch(t, x0, y1), fetch(t, x1, y1), tx)
	return mix4(top, bot, ty)
}

@(private = "file")
load_texel :: #force_inline proc "contextless" (t: Sw_Target, x, y: u32) -> [4]f32 {
	return fetch({t.pixels, t.width, t.height, t.format, {}}, x, y)
}

@(private = "file")
to_unorm8 :: #force_inline proc "contextless" (v: f32) -> u8 {
	return u8(clamp(v * 255 + 0.5, 0, 255))
}

@(private = "file")
store_texel :: #force_inline proc "contextless" (t: Sw_Target, x, y: u32, c: [4]f32) {
	i := int(y * t.width + x)
	switch t.format {
	case .RGBA8:
		p := t.pixels[i * 4:]
		p[0], p[1], p[2], p[3] = to_unorm8(c[0]), to_unorm8(c[1]), to_unorm8(c[2]), to_unorm8(c[3])
	case .RGB8:
		p := t.pixels[i * 3:]
		p[0], p[1], p[2] = to_unorm8(c[0]), to_unorm8(c[1]), to_unorm8(c[2])
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
		src = {clamp(src[0], 0, 1), clamp(src[1], 0, 1), clamp(src[2], 0, 1), clamp(src[3], 0, 1)}
	}
	dst := load_texel(t, x, y)
	sf := factor_rgb(s.src_rgb, src, dst)
	df := factor_rgb(s.dst_rgb, src, dst)
	rgb := src.rgb * sf + dst.rgb * df
	a := src.a * factor_alpha(s.src_alpha, src.a, dst.a) + dst.a * factor_alpha(s.dst_alpha, src.a, dst.a)
	store_texel(t, x, y, {rgb.r, rgb.g, rgb.b, a})
}

// ---- image filters -------------------------------------------------------------------

// Runs one image filter (see `Image_Filter`). Inputs are read as a GPU
// sampler returns them and converted to premultiplied color by their
// `tex_type`, as the shader does; every pixel is computed before it is
// written, so the target may alias an input. Each pass is a sweep of row
// bands (sw_bands); a two-pass filter's second reads the whole first.
@(private = "file")
sw_filter_image :: proc(b: ^Software_Backend, images: ^Image_Store, cmd: Command, target: Image_Id, filter: Image_Filter) {
	src, src_ok := lookup_texture(images, cmd.image)
	dst_entry := image_store_get(images, target)
	if !src_ok || dst_entry == nil || dst_entry.image.pixels == nil {
		return
	}
	dst := Sw_Target{dst_entry.image.pixels, dst_entry.info.width, dst_entry.info.height, dst_entry.info.format}
	if t, is_turbulence := filter.(Turbulence); is_turbulence {
		// The source is the GPU's lattice image; the seed makes the f64 one.
		if dst.format == .RGBA8 || dst.format == .RGBA16F {
			sw_turbulence(b, dst, t)
		}
		return
	}
	if dst.width != src.width || dst.height != src.height {
		return
	}
	src_tt := tex_type_for({src.flags, src.width, src.height, src.format})
	job := Sw_Filter{src = src, src_tt = src_tt, dst = dst, filter = filter}
	rows := int(dst.height)

	if sx, sy, edge, is_blur := blur_params(filter); is_blur {
		tmp := sw_blur_tmp(b, len(src.pixels))
		job.edge = edge
		job.dst = {tmp, src.width, src.height, src.format}
		job.dir, job.sigma, job.tex_type = {1, 0}, sx, src_tt
		sw_bands(b, rows, &job, sw_blur_band)
		// The intermediate already holds premultiplied color.
		job.src = {tmp, src.width, src.height, src.format, src.flags}
		job.dst = dst
		job.dir, job.sigma, job.tex_type = {0, 1}, sy, 2 if src.format == .Gray8 else 0
		sw_bands(b, rows, &job, sw_blur_band)
		return
	}

	if m, is_morph := filter.(Morphology); is_morph {
		tmp := sw_blur_tmp(b, len(src.pixels))
		job.morph = m
		job.dst = {tmp, src.width, src.height, src.format}
		job.axis, job.tex_type = 0, src_tt
		sw_bands(b, rows, &job, sw_morphology_band)
		job.src = {tmp, src.width, src.height, src.format, src.flags}
		job.dst = dst
		job.axis, job.tex_type = 1, 2 if src.format == .Gray8 else 0
		sw_bands(b, rows, &job, sw_morphology_band)
		return
	}

	if id := filter_backdrop(filter); image_id_valid(id) {
		ok: bool
		job.back, ok = lookup_texture(images, id)
		_, is_lut := filter.(Component_Transfer)
		if !ok || (!is_lut && (job.back.width != src.width || job.back.height != src.height)) {
			return
		}
		job.back_tt = tex_type_for({job.back.flags, job.back.width, job.back.height, job.back.format})
	}
	#partial switch v in filter {
	case Lighting, Tile, Displacement_Map, Convolve_Matrix:
		// Neighbourhood filters: the target may alias the source.
		if raw_data(dst.pixels) == raw_data(src.pixels) || raw_data(dst.pixels) == raw_data(job.back.pixels) {
			job.dst.pixels = sw_blur_tmp(b, len(dst.pixels))
		}
		sw_bands(b, rows, &job, proc(data: rawptr, y0, y1: int) {
			j := (^Sw_Filter)(data)
			neighbourhood_filter(j.src, j.src_tt, j.back, j.back_tt, j.dst, j.filter, y0, y1)
		})
		if raw_data(job.dst.pixels) != raw_data(dst.pixels) {
			copy(dst.pixels, job.dst.pixels)
		}
		return
	}
	sw_bands(b, rows, &job, sw_pixel_filter_band)
}

// One filter pass's inputs and output, shared by its bands.
@(private = "file")
Sw_Filter :: struct {
	src:      Sw_Texture,
	src_tt:   f32,
	back:     Sw_Texture,
	back_tt:  f32,
	dst:      Sw_Target,
	filter:   Image_Filter,
	// A blur or morphology pass.
	tex_type: f32,
	dir:      [2]i32,
	sigma:    f32,
	edge:     Blur_Edge,
	morph:    Morphology,
	axis:     int,
}

// The scratch between a two-pass filter's passes, `n` bytes.
@(private = "file")
sw_blur_tmp :: proc(b: ^Software_Backend, n: int) -> []u8 {
	if len(b.blur_tmp) < n {
		delete(b.blur_tmp, b.allocator)
		b.blur_tmp = make([]u8, n, b.allocator)
	}
	return b.blur_tmp[:n]
}

@(private = "file")
sw_blur_band :: proc(data: rawptr, y0, y1: int) {
	j := (^Sw_Filter)(data)
	blur_pass(j.src, j.dst, j.dir, j.sigma, j.tex_type, j.edge, y0, y1)
}

@(private = "file")
sw_morphology_band :: proc(data: rawptr, y0, y1: int) {
	j := (^Sw_Filter)(data)
	morphology_pass(j.src, j.dst, j.morph, j.axis, j.tex_type, y0, y1)
}

// The filters that read only the pixel under them (and the backdrop's).
@(private = "file")
sw_pixel_filter_band :: proc(data: rawptr, y0, y1: int) {
	j := (^Sw_Filter)(data)
	src, src_tt, back, back_tt, dst := j.src, j.src_tt, j.back, j.back_tt, j.dst
	for y in u32(y0) ..< u32(y1) {
		for x in 0 ..< dst.width {
			s := apply_tex_type(fetch(src, x, y), src_tt)
			out: [4]f32
			#partial switch v in j.filter {
			case Color_Matrix:
				out = color_matrix_pixel(v.m, s)
			case Color_Space_Convert:
				out = color_space_pixel(s, v.to_linear)
			case Blend:
				out = blend_pixel(v.mode, s, apply_tex_type(fetch(back, x, y), back_tt))
			case Composite:
				out = composite_pixel(v.op, v.k, s, apply_tex_type(fetch(back, x, y), back_tt))
			case Component_Transfer:
				us := unpremultiply(s)
				for k in 0 ..< 4 {
					us[k] = fetch(back, u32(component_transfer_index(us[k])), 0)[k]
				}
				out = premultiply(us)
			}
			store_texel(dst, x, y, out)
		}
	}
}

@(private = "file")
Sw_Turbulence :: struct {
	dst:     Sw_Target,
	t:       Turbulence,
	lattice: ^Turbulence_Lattice,
}

@(private = "file")
sw_turbulence :: proc(b: ^Software_Backend, dst: Sw_Target, t: Turbulence) {
	lattice: Turbulence_Lattice
	turbulence_init(&lattice, t.seed)
	job := Sw_Turbulence{dst, t, &lattice}
	if dst.format == .RGBA16F {
		sw_bands(b, int(dst.height), &job, proc(data: rawptr, y0, y1: int) {
			j := (^Sw_Turbulence)(data)
			turbulence_fill(j.dst.pixels, int(j.dst.width), int(j.dst.height), j.t, j.lattice, y0, y1, true)
		})
		return
	}
	sw_bands(b, int(dst.height), &job, proc(data: rawptr, y0, y1: int) {
		j := (^Sw_Turbulence)(data)
		turbulence_fill(j.dst.pixels, int(j.dst.width), int(j.dst.height), j.t, j.lattice, y0, y1, false)
	})
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

// One direction (`axis` 0 = x) of a morphology box: min or max over the
// taps inside the valid rectangle.
@(private = "file")
morphology_pass :: proc(src: Sw_Texture, dst: Sw_Target, m: Morphology, axis: int, tex_type: f32, y0, y1: int) {
	rf := clamp(m.radius[axis], 0, MORPHOLOGY_MAX_RADIUS)
	r := i32(rf)
	frac := rf - f32(r)
	op :: #force_inline proc(a, b: [4]f32, dilate: bool) -> [4]f32 {
		return {max(a.r, b.r), max(a.g, b.g), max(a.b, b.b), max(a.a, b.a)} if dilate else {min(a.r, b.r), min(a.g, b.g), min(a.b, b.b), min(a.a, b.a)}
	}
	lo, hi := i32(m.valid[axis]), i32(m.valid[axis + 2]) - 1
	for y in u32(y0) ..< u32(y1) {
		for x in 0 ..< dst.width {
			p := [2]i32{i32(x), i32(y)}
			c := p[axis]
			acc: [4]f32 = 0 if m.dilate else 1
			for t in max(c - r, lo) ..= min(c + r, hi) {
				q := p
				q[axis] = t
				acc = op(acc, fetch(src, u32(q.x), u32(q.y)), m.dilate)
			}
			if frac > 0 {
				ring := acc
				for t in ([2]i32{c - r - 1, c + r + 1}) {
					if t < lo || t > hi do continue
					q := p
					q[axis] = t
					ring = op(ring, fetch(src, u32(q.x), u32(q.y)), m.dilate)
				}
				acc += (ring - acc) * frac
			}
			if lo > hi {
				acc = {}
			}
			store_texel(dst, x, y, apply_tex_type(acc, tex_type))
		}
	}
}

// Lighting, tiling, displacement and convolution, pixel by pixel as the
// shader's `render_neighbourhood` does.
@(private = "file")
neighbourhood_filter :: proc(src: Sw_Texture, src_tt: f32, back: Sw_Texture, back_tt: f32, dst: Sw_Target, filter: Image_Filter, y0, y1: int) {
	texel :: #force_inline proc(t: Sw_Texture, tt: f32, x, y: i32) -> [4]f32 {
		if x < 0 || y < 0 || x >= i32(t.width) || y >= i32(t.height) {
			return {}
		}
		return apply_tex_type(fetch(t, u32(x), u32(y)), tt)
	}
	for y in i32(y0) ..< i32(y1) {
		for x in 0 ..< i32(dst.width) {
			out: [4]f32
			#partial switch v in filter {
			case Lighting:
				vr := v.valid
				fx, fy := f32(x), f32(y)
				left, right := fx - 1 >= vr[0], fx + 1 < vr[2]
				up, down := fy - 1 >= vr[1], fy + 1 < vr[3]
				a: [3][3]f32
				for j in 0 ..< 3 {
					for i in 0 ..< 3 {
						a[j][i] = texel(src, src_tt, x + i32(i) - 1, y + i32(j) - 1).a
					}
				}
				out = lighting_pixel(v, a, left, right, up, down, fx, fy)
			case Tile:
				r := [4]i32{i32(math.round(v.rect[0])), i32(math.round(v.rect[1])), i32(math.round(v.rect[2])), i32(math.round(v.rect[3]))}
				if r[2] >= 1 && r[3] >= 1 {
					tx := ((x - r[0]) % r[2] + r[2]) % r[2]
					ty := ((y - r[1]) % r[3] + r[3]) % r[3]
					out = texel(src, src_tt, r[0] + tx, r[1] + ty)
				}
			case Displacement_Map:
				m := texel(back, back_tt, x, y)
				o := displacement_offset(v, m, f32(x), f32(y))
				vr := v.valid
				if o.x >= vr[0] && o.y >= vr[1] && o.x < vr[2] && o.y < vr[3] {
					out = texel(src, src_tt, i32(o.x), i32(o.y))
				}
			case Convolve_Matrix:
				out = convolve_pixel(v, src, src_tt, x, y)
			}
			store_texel(dst, u32(x), u32(y), out)
		}
	}
}

@(private = "file")
convolve_pixel :: proc(v: Convolve_Matrix, src: Sw_Texture, src_tt: f32, x, y: i32) -> [4]f32 {
	vr := [4]i32{i32(v.valid[0]), i32(v.valid[1]), i32(v.valid[2]), i32(v.valid[3])}
	vw, vh := vr[2] - vr[0], vr[3] - vr[1]
	if vw <= 0 || vh <= 0 {
		return {}
	}
	load :: #force_inline proc(src: Sw_Texture, tt: f32, x, y: i32, unpremul: bool) -> [4]f32 {
		c := apply_tex_type(fetch(src, u32(x), u32(y)), tt)
		return unpremultiply(c) if unpremul else c
	}
	sum: [4]f32
	for oy in 0 ..< v.order.y {
		for ox in 0 ..< v.order.x {
			tx := x - v.target.x + ox
			ty := y - v.target.y + oy
			switch v.edge {
			case 2:
				if tx < vr[0] || tx >= vr[2] || ty < vr[1] || ty >= vr[3] {
					continue
				}
			case 1:
				tx = vr[0] + ((tx - vr[0]) % vw + vw) % vw
				ty = vr[1] + ((ty - vr[1]) % vh + vh) % vh
			case:
				tx = clamp(tx, vr[0], vr[2] - 1)
				ty = clamp(ty, vr[1], vr[3] - 1)
			}
			k := v.kernel[(v.order.y - oy - 1) * v.order.x + (v.order.x - ox - 1)]
			sum += load(src, src_tt, tx, ty, v.preserve_alpha) * k
		}
	}
	center := apply_tex_type(fetch(src, u32(x), u32(y)), src_tt)
	return convolve_finish(v, sum, center.a)
}

// One direction of a separable gaussian, with the GPU shader's incremental
// coefficients and tap count. Transparent edges count the missing taps as
// black (keeping their weight).
@(private = "file")
blur_pass :: proc(src: Sw_Texture, dst: Sw_Target, dir: [2]i32, sigma: f32, tex_type: f32, edge: Blur_Edge, y0, y1: int) {
	coeff, taps := blur_pass_coefficients(sigma)
	w, h := i32(src.width), i32(src.height)
	tap :: #force_inline proc(src: Sw_Texture, x, y, w, h: i32, edge: Blur_Edge) -> [4]f32 {
		if edge == .Clamp {
			return fetch(src, u32(clamp(x, 0, w - 1)), u32(clamp(y, 0, h - 1)))
		}
		if x < 0 || y < 0 || x >= w || y >= h {
			return {}
		}
		return fetch(src, u32(x), u32(y))
	}
	for y in u32(y0) ..< u32(y1) {
		for x in 0 ..< dst.width {
			g := coeff
			sum := fetch(src, x, y) * g[0]
			weight := g[0]
			g.xy *= g.yz
			for i in 1 ..= taps {
				o := i32(i)
				sum += tap(src, i32(x) - o * dir.x, i32(y) - o * dir.y, w, h, edge) * g[0]
				sum += tap(src, i32(x) + o * dir.x, i32(y) + o * dir.y, w, h, edge) * g[0]
				weight += 2 * g[0]
				g.xy *= g.yz
			}
			store_texel(dst, x, y, apply_tex_type(sum / weight, tex_type))
		}
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
Sw_Channels :: [PROGRAM_MAX_CHANNELS]Maybe(Sw_Texture)

// GL texture() semantics over the channel images, for the CPU program.
@(private = "file")
sw_program_sample :: proc(data: rawptr, channel: int, uv: [2]f32, lod: f32) -> [4]f32 {
	channels := (^Sw_Channels)(data)
	if channel < 0 || channel >= PROGRAM_MAX_CHANNELS {
		return {}
	}
	t, ok := channels[channel].?
	if !ok {
		return {}
	}
	return sample(t, uv.x, uv.y)
}

@(private = "file")
sw_run_program :: proc(images: ^Image_Store, frame: Frame, cmd: Program_Run) {
	p := (^Sw_Program)(cmd.program.user)
	entry := image_store_get(images, cmd.target)
	if p == nil || entry == nil || entry.image.pixels == nil || (entry.info.format != .RGBA8 && entry.info.format != .RGBA16F) {
		return
	}
	channels: Sw_Channels
	sampler := Program_Sampler{&channels, sw_program_sample, {}}
	for id, i in cmd.channels {
		if t, ok := lookup_texture(images, id); ok {
			channels[i] = t
			sampler.sizes[i] = {i32(t.width), i32(t.height)}
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

// The shader's `gradient_t`: box / linear / radial distance, or the focal
// radial gradient, after the spread method.
@(private = "file")
gradient_t :: #force_inline proc "contextless" (p: ^Params, px, py: f32) -> f32 {
	pt := paint_point(p.paint_mat, px, py)
	if p.focal[0] != 0 {
		return spread_t(focal_gradient_t(pt, p.extent[0], p.extent[1], {p.focal[1], p.focal[2]}), p.spread)
	}
	return spread_t((sd_round_rect(pt, p.extent, p.radius) + p.feather * 0.5) / p.feather, p.spread)
}
