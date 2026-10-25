package ovg

import "core:math"
import "core:mem"
import "core:sync"
import "core:thread"

import cv "curves"

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
	// A shape group's pixels before its tint, reused.
	group:     [][4]f32,
	// Borrowed task pool (the caller owns it) the heaviest filters
	// (feTurbulence) run row bands on; nil runs them on the calling thread.
	pool:      ^thread.Pool,
}

software_backend_init :: proc(b: ^Software_Backend, allocator := context.allocator) {
	b^ = {allocator = allocator}
}

software_backend_destroy :: proc(b: ^Software_Backend) {
	delete(b.pixels, b.allocator)
	delete(b.blur_tmp, b.allocator)
	delete(b.group, b.allocator)
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
	pixels, err := make([]u8, int(info.width * info.height * bytes_per_pixel(info.format)), b.allocator)
	if err != nil {
		return {}, .Out_Of_Memory
	}
	return {pixels = pixels}, nil
}

@(private = "file")
sw_update_image :: proc(data: rawptr, img: ^Backend_Image, info: Image_Info, src: Image_Source, x, y: u32) -> Error {
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

@(private = "file")
sw_active_target :: proc(b: ^Software_Backend, images: ^Image_Store) -> (Sw_Target, bool) {
	if image_id_valid(b.target) {
		entry := image_store_get(images, b.target)
		if entry == nil {
			return {}, false
		}
		return {entry.image.pixels, entry.info.width, entry.info.height, entry.info.format}, true
	}
	return {b.pixels, b.width, b.height, .RGBA8}, true
}

@(private = "file")
sw_render :: proc(data: rawptr, output: Render_Output, images: ^Image_Store, frame: Frame) {
	b := (^Software_Backend)(data)
	b.target = {}
	b.origin = {}
	for cmd in frame.commands {
		if rt, ok := cmd.type.(Cmd_Set_Render_Target); ok {
			b.target = {}
			b.origin = rt.origin
			if id, is_image := rt.target.(Image_Id); is_image {
				b.target = id
			}
			continue
		}
		if f, ok := cmd.type.(Cmd_Filter_Image); ok {
			sw_filter_image(b, images, cmd, f.target_image, frame.filters[f.filter])
			continue
		}
		if p, ok := cmd.type.(Cmd_Run_Program); ok {
			sw_run_program(images, frame, frame.runs[p.run])
			continue
		}
		if e, ok := cmd.type.(Cmd_Run_External); ok {
			e.fn(e.user, nil, images)
			continue
		}
		target, ok := sw_active_target(b, images)
		if !ok {
			continue
		}
		sw_run_command(b, images, frame, cmd, target)
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
}

@(private = "file")
sw_run_command :: proc(b: ^Software_Backend, images: ^Image_Store, frame: Frame, cmd: Command, target: Sw_Target) {
	r := Raster {
		target  = target,
		blend   = cmd.composite_operation,
		ox      = b.origin.x,
		oy      = b.origin.y,
		x0      = b.origin.x,
		y0      = b.origin.y,
		x1      = b.origin.x + i32(target.width),
		y1      = b.origin.y + i32(target.height),
	}
	if sr, ok := cmd.scissor_rect.?; ok {
		r.x0 = max(r.x0, i32(math.floor(sr.x)))
		r.y0 = max(r.y0, i32(math.floor(sr.y)))
		r.x1 = min(r.x1, i32(math.ceil(sr.x + sr.w)))
		r.y1 = min(r.y1, i32(math.ceil(sr.y + sr.h)))
	}
	#partial switch c in cmd.type {
	case Cmd_Clear_Rect:
		sw_clear_rect(&r, c)
	case Cmd_Draw_Shapes:
		if c.group != 0 {
			raster_group(b, &r, images, frame, cmd, c)
			return
		}
		frag: Frag
		row := max(u32)
		for inst in frame.shapes[c.instances.start:][:c.instances.count] {
			if inst.paint != row {
				frag = make_frag(images, cmd, frame.paints[inst.paint])
				row = inst.paint
			}
			r.frag = &frag
			raster_shape(&r, inst, frame.shape_words)
		}
	}
}

// A group, as the shape shader draws it: each pixel the instances
// source-over in order (each as `raster_shape` shades it), then times the
// tint, blended once.
@(private = "file")
raster_group :: proc(b: ^Software_Backend, r: ^Raster, images: ^Image_Store, frame: Frame, cmd: Command, c: Cmd_Draw_Shapes) {
	instances := frame.shapes[c.instances.start:][:c.instances.count]
	area := EMPTY_BOUNDS
	for inst in instances {
		ib := instance_bounds(inst, frame.shape_words)
		area = {min(area.minx, ib.minx), min(area.miny, ib.miny), max(area.maxx, ib.maxx), max(area.maxy, ib.maxy)}
	}
	x0 := max(r.x0, i32(math.floor(area.minx)))
	y0 := max(r.y0, i32(math.floor(area.miny)))
	x1 := min(r.x1, i32(math.ceil(area.maxx)))
	y1 := min(r.y1, i32(math.ceil(area.maxy)))
	if x0 >= x1 || y0 >= y1 {
		return
	}
	w, h := int(x1 - x0), int(y1 - y0)
	if len(b.group) < w * h {
		delete(b.group, b.allocator)
		b.group = make([][4]f32, w * h, b.allocator)
	}
	acc := b.group[:w * h]
	mem.zero_slice(acc)
	frag: Frag
	row := max(u32)
	for inst in instances {
		if inst.paint != row {
			frag = make_frag(images, cmd, frame.paints[inst.paint])
			row = inst.paint
		}
		ib := instance_bounds(inst, frame.shape_words)
		ix0, iy0 := max(x0, i32(math.floor(ib.minx))), max(y0, i32(math.floor(ib.miny)))
		ix1, iy1 := min(x1, i32(math.ceil(ib.maxx))), min(y1, i32(math.ceil(ib.maxy)))
		inv := transform_inverse(inst.transform)
		u, v := instance_footprint(inst)
		words := instance_words(inst, frame.shape_words)
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
				a := &acc[int(y - y0) * w + int(x - x0)]
				a^ = src + a^ * (1 - src[3])
			}
		}
	}
	tint := make_frag(images, cmd, frame.paints[c.group - 1])
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
			dst := load_texel(r.target, tx, ty)
			store_texel(r.target, tx, ty, apply_blend(r.blend, a * t, dst))
		}
	}
}

// Every pixel center of the instance's bounds: its coverage (shape.odin)
// as the paint's edge coverage, as the shader does.
@(private = "file")
raster_shape :: proc(r: ^Raster, inst: Shape_Instance, frame_words: []u32) {
	b := instance_bounds(inst, frame_words)
	x0 := max(r.x0, i32(math.floor(b.minx)))
	y0 := max(r.y0, i32(math.floor(b.miny)))
	x1 := min(r.x1, i32(math.ceil(b.maxx)))
	y1 := min(r.y1, i32(math.ceil(b.maxy)))
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
			dst := load_texel(r.target, tx, ty)
			store_texel(r.target, tx, ty, apply_blend(r.blend, src, dst))
		}
	}
}

// The coverage of the instance's pixel centered at `rc` (shape units) with
// sides `u` and `v` (instance_footprint): the shape shader's.
@(private = "file")
instance_coverage :: proc "contextless" (inst: Shape_Instance, words: []u32, rc, u, v: Vec2) -> f32 {
	if inst.aliased {
		// Off center as the shader samples it.
		w := cv.winding(words, rc + (u + v) / 64)
		return 1 if cv.fill_inside(w, inst.even_odd) else 0
	}
	return shape_coverage(words, rc, u, v, inst.even_odd)
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
	if entry == nil {
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

@(private = "file")
apply_blend :: proc "contextless" (s: Composite_Operation_State, src, dst: [4]f32) -> [4]f32 {
	sf := factor_rgb(s.src_rgb, src, dst)
	df := factor_rgb(s.dst_rgb, src, dst)
	rgb := src.rgb * sf + dst.rgb * df
	a := src.a * factor_alpha(s.src_alpha, src.a, dst.a) + dst.a * factor_alpha(s.dst_alpha, src.a, dst.a)
	return {clamp(rgb.r, 0, 1), clamp(rgb.g, 0, 1), clamp(rgb.b, 0, 1), clamp(a, 0, 1)}
}

// ---- image filters -------------------------------------------------------------------

// Runs one image filter (see `Image_Filter`). Inputs are read as a GPU
// sampler returns them and converted to premultiplied color by their
// `tex_type`, as the shader does; every pixel is computed before it is
// written, so the target may alias an input.
@(private = "file")
sw_filter_image :: proc(b: ^Software_Backend, images: ^Image_Store, cmd: Command, target: Image_Id, filter: Image_Filter) {
	src, src_ok := lookup_texture(images, cmd.image)
	dst_entry := image_store_get(images, target)
	if !src_ok || dst_entry == nil {
		return
	}
	dst := Sw_Target{dst_entry.image.pixels, dst_entry.info.width, dst_entry.info.height, dst_entry.info.format}
	if t, is_turbulence := filter.(Turbulence); is_turbulence {
		// The source is the GPU's lattice image; the seed makes the f64 one.
		if dst.format == .RGBA8 {
			sw_turbulence(b, dst, t)
		}
		return
	}
	if dst.width != src.width || dst.height != src.height {
		return
	}
	src_tt := tex_type_for({src.flags, src.width, src.height, src.format})

	if sx, sy, edge, is_blur := blur_params(filter); is_blur {
		if len(b.blur_tmp) < len(src.pixels) {
			delete(b.blur_tmp, b.allocator)
			b.blur_tmp = make([]u8, len(src.pixels), b.allocator)
		}
		tmp := b.blur_tmp[:len(src.pixels)]
		mid := Sw_Target{tmp, src.width, src.height, src.format}
		blur_pass(src, mid, {1, 0}, sx, src_tt, edge)
		mid_tex := Sw_Texture{tmp, src.width, src.height, src.format, src.flags}
		// The intermediate already holds premultiplied color.
		blur_pass(mid_tex, dst, {0, 1}, sy, 2 if src.format == .Gray8 else 0, edge)
		return
	}

	if m, is_morph := filter.(Morphology); is_morph {
		if len(b.blur_tmp) < len(src.pixels) {
			delete(b.blur_tmp, b.allocator)
			b.blur_tmp = make([]u8, len(src.pixels), b.allocator)
		}
		tmp := b.blur_tmp[:len(src.pixels)]
		morphology_pass(src, {tmp, src.width, src.height, src.format}, m, 0, src_tt)
		mid_tex := Sw_Texture{tmp, src.width, src.height, src.format, src.flags}
		morphology_pass(mid_tex, dst, m, 1, 2 if src.format == .Gray8 else 0)
		return
	}

	back: Sw_Texture
	back_tt: f32
	if id := filter_backdrop(filter); image_id_valid(id) {
		ok: bool
		back, ok = lookup_texture(images, id)
		_, is_lut := filter.(Component_Transfer)
		if !ok || (!is_lut && (back.width != src.width || back.height != src.height)) {
			return
		}
		back_tt = tex_type_for({back.flags, back.width, back.height, back.format})
	}
	#partial switch v in filter {
	case Lighting, Tile, Displacement_Map, Convolve_Matrix:
		// Neighbourhood filters: the target may alias the source.
		out := dst
		if raw_data(dst.pixels) == raw_data(src.pixels) || raw_data(dst.pixels) == raw_data(back.pixels) {
			if len(b.blur_tmp) < len(dst.pixels) {
				delete(b.blur_tmp, b.allocator)
				b.blur_tmp = make([]u8, len(dst.pixels), b.allocator)
			}
			out.pixels = b.blur_tmp[:len(dst.pixels)]
		}
		neighbourhood_filter(src, src_tt, back, back_tt, out, filter)
		if raw_data(out.pixels) != raw_data(dst.pixels) {
			copy(dst.pixels, out.pixels)
		}
		return
	}
	for y in 0 ..< dst.height {
		for x in 0 ..< dst.width {
			s := apply_tex_type(fetch(src, x, y), src_tt)
			out: [4]f32
			#partial switch v in filter {
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
	sw_bands(b, int(dst.height), &job, proc(data: rawptr, y0, y1: int) {
		j := (^Sw_Turbulence)(data)
		turbulence_fill(j.dst.pixels, int(j.dst.width), int(j.dst.height), j.t, j.lattice, y0, y1)
	})
}

// ---- row bands -----------------------------------------------------------------------

@(private = "file")
SW_BAND_ROWS :: 16

@(private = "file")
Sw_Bands :: struct {
	data:    rawptr,
	band:    proc(data: rawptr, y0, y1: int),
	rows:    int,
	// The next band to take, shared by the takers.
	next:    int,
	// Pool tasks not finished.
	pending: sync.Futex,
}

// Runs `band` over `rows` rows in bands of SW_BAND_ROWS: on this thread and,
// with `b.pool`, on its threads too. While waiting this thread runs any
// waiting pool task, so it may itself be a pool task.
@(private = "file")
sw_bands :: proc(b: ^Software_Backend, rows: int, data: rawptr, band: proc(data: rawptr, y0, y1: int)) {
	job := Sw_Bands{data = data, band = band, rows = rows}
	helpers := 0
	if b.pool != nil {
		sync.mutex_lock(&b.pool.mutex)
		helpers = min(len(b.pool.threads), (rows - 1) / SW_BAND_ROWS)
		sync.mutex_unlock(&b.pool.mutex)
	}
	job.pending = sync.Futex(max(helpers, 0))
	for i in 0 ..< helpers {
		thread.pool_add_task(b.pool, context.allocator, sw_band_task, &job, i)
	}
	sw_take_bands(&job)
	if helpers <= 0 {
		return
	}
	for {
		left := sync.atomic_load(&job.pending)
		if left == 0 {
			break
		}
		if task, ok := thread.pool_pop_waiting(b.pool); ok {
			thread.pool_do_work(b.pool, task)
			continue
		}
		sync.futex_wait(&job.pending, u32(left))
	}
	// Forget this job's finished tasks (the pool keeps a record of each until
	// popped); the host's own records stay for it to pop. A worker appends
	// its record after the task returns, so `pending` can reach 0 first:
	// wait for all `helpers` of them (each task gets exactly one), then
	// remove them in one pass.
	mine :: #force_inline proc(t: thread.Task, job: ^Sw_Bands) -> bool {
		return t.procedure == sw_band_task && t.data == rawptr(job)
	}
	for {
		sync.mutex_lock(&b.pool.mutex)
		found := 0
		for t in b.pool.tasks_done {
			found += int(mine(t, &job))
		}
		if found == helpers {
			kept := 0
			for t in b.pool.tasks_done {
				if !mine(t, &job) {
					b.pool.tasks_done[kept] = t
					kept += 1
				}
			}
			resize(&b.pool.tasks_done, kept)
			sync.atomic_sub(&b.pool.num_done, found)
			sync.mutex_unlock(&b.pool.mutex)
			break
		}
		sync.mutex_unlock(&b.pool.mutex)
		thread.yield()
	}
}

@(private = "file")
sw_band_task :: proc(t: thread.Task) {
	job := (^Sw_Bands)(t.data)
	sw_take_bands(job)
	if sync.atomic_sub(&job.pending, 1) == 1 {
		sync.futex_broadcast(&job.pending)
	}
}

@(private = "file")
sw_take_bands :: proc(job: ^Sw_Bands) {
	for {
		y := sync.atomic_add(&job.next, 1) * SW_BAND_ROWS
		if y >= job.rows {
			return
		}
		job.band(job.data, y, min(y + SW_BAND_ROWS, job.rows))
	}
}

// One direction (`axis` 0 = x) of a morphology box: min or max over the
// taps inside the valid rectangle.
@(private = "file")
morphology_pass :: proc(src: Sw_Texture, dst: Sw_Target, m: Morphology, axis: int, tex_type: f32) {
	rf := clamp(m.radius[axis], 0, MORPHOLOGY_MAX_RADIUS)
	r := i32(rf)
	frac := rf - f32(r)
	op :: #force_inline proc(a, b: [4]f32, dilate: bool) -> [4]f32 {
		return {max(a.r, b.r), max(a.g, b.g), max(a.b, b.b), max(a.a, b.a)} if dilate else {min(a.r, b.r), min(a.g, b.g), min(a.b, b.b), min(a.a, b.a)}
	}
	lo, hi := i32(m.valid[axis]), i32(m.valid[axis + 2]) - 1
	for y in 0 ..< dst.height {
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
neighbourhood_filter :: proc(src: Sw_Texture, src_tt: f32, back: Sw_Texture, back_tt: f32, dst: Sw_Target, filter: Image_Filter) {
	texel :: #force_inline proc(t: Sw_Texture, tt: f32, x, y: i32) -> [4]f32 {
		if x < 0 || y < 0 || x >= i32(t.width) || y >= i32(t.height) {
			return {}
		}
		return apply_tex_type(fetch(t, u32(x), u32(y)), tt)
	}
	for y in 0 ..< i32(dst.height) {
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
blur_pass :: proc(src: Sw_Texture, dst: Sw_Target, dir: [2]i32, sigma: f32, tex_type: f32, edge: Blur_Edge) {
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
	for y in 0 ..< dst.height {
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
	if p == nil || entry == nil || (entry.info.format != .RGBA8 && entry.info.format != .RGBA16F) {
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
		out := ([^][4]f16)(raw_data(entry.image.pixels))[:w * h]
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
