package ovg

import "core:math"

// SVG filter effects on a layer (`Layer_Params.filter`): a list of filter
// primitives, each reading the source graphic, its alpha, or earlier results
// and producing a new image, the last one being the filtered layer. Built on
// the image filters (`filter_image`) and canvas drawing, so it runs on every
// backend. Lengths (stdDeviation, dx, dy) are in the layer's units at push
// time. Like SVG's default `color-interpolation-filters`, primitives work in
// linear RGB unless `srgb` is set.
//
// Every SVG 1.1 primitive; feImage shows an image (`Filter.images`), not
// an element. Lighting ignores kernelUnitLength, as resvg; feConvolveMatrix
// takes at most CONVOLVE_MAX_KERNEL kernel values. The feTurbulence lattice
// and the component transfer tables are computed on the CPU and uploaded.
//
// The filter region (`Filter.region`) cuts both the source graphic and the
// result, and bounds the layer's window. Without one the region is the
// whole canvas: the layer covers what was drawn plus `filter_reach`, or the
// whole canvas when a primitive makes pixels out of nothing (a flood, an
// alpha offset).

Filter_Op :: enum u8 {
	Gaussian_Blur,
	Offset,
	Flood,
	Composite,
	Merge,
	Blend,
	Color_Matrix,
	// feDropShadow: blur of the alpha, offset, tinted, under the input.
	Drop_Shadow,
	Component_Transfer,
	Morphology,
	Turbulence,
	Diffuse_Lighting,
	Specular_Lighting,
	// feTile: in1's subregion repeated.
	Tile,
	Displacement_Map,
	Convolve_Matrix,
	// feImage: `Filter.images[image]` fitted into the subregion (by
	// default the filter region) as preserveAspectRatio says.
	Image,
}

Image_Fit :: enum u8 {
	Meet,
	Slice,
	// preserveAspectRatio="none": stretched.
	None,
}

// A light source (feDistantLight, fePointLight, feSpotLight) in the layer's
// user units; angles in degrees.
Filter_Light :: struct {
	kind:          Light_Kind,
	azimuth:       f32,
	elevation:     f32,
	position:      [3]f32,
	points_at:     [3]f32,
	// feSpotLight specularExponent (1 by default).
	spot_exponent: f32,
	// limitingConeAngle; none when `has_cone` is false.
	cone_angle:    f32,
	has_cone:      bool,
}

Convolve_Edge :: enum u8 {
	Duplicate,
	Wrap,
	None,
}

Filter_Ref_Kind :: enum u8 {
	// The previous primitive's result (the source graphic for the first).
	Previous,
	Source_Graphic,
	Source_Alpha,
	// The result of primitive `index`.
	Result,
}

Filter_Ref :: struct {
	kind:  Filter_Ref_Kind,
	index: u16,
}

Filter_Primitive :: struct {
	op:          Filter_Op,
	in1, in2:    Filter_Ref,
	// Merge inputs: `Filter.merge_refs[merge_first:][:merge_count]`.
	merge_first: u16,
	merge_count: u16,
	// Gaussian_Blur / Drop_Shadow standard deviation (x, y).
	std:         [2]f32,
	// Offset / Drop_Shadow.
	dx, dy:      f32,
	// Flood / Drop_Shadow color, its opacity in alpha (straight).
	color:       Color,
	blend:       Blend_Mode,
	composite:   Composite_Operator,
	// Composite arithmetic k1..k4.
	k:           [4]f32,
	// Color_Matrix (feColorMatrix values; see color_matrix_* helpers).
	color_matrix: [20]f32,
	// The primitive subregion (x, y, width, height of an fe* element) in
	// the layer's user units: the result is cut to it.
	subregion:    Rect,
	has_subregion: bool,
	// Component_Transfer: feFuncR, G, B, A (tables in `Filter.values`).
	transfer:     [4]Transfer_Function,
	// Morphology radius (x, y) and operator (erode unless `dilate`).
	radius:       [2]f32,
	dilate:       bool,
	// Turbulence (`fractal_noise` false: type="turbulence").
	base_frequency: [2]f32,
	octaves:      u32,
	seed:         i32,
	stitch:       bool,
	fractal_noise: bool,
	// Lighting; `color` is the lighting-color. `light_constant` is
	// diffuseConstant or specularConstant.
	light:        Filter_Light,
	surface_scale: f32,
	light_constant: f32,
	specular_exponent: f32,
	// Displacement_Map: scale and the R/G/B/A (0..3) channel for x and y.
	scale:        f32,
	channels:     [2]u8,
	// Convolve_Matrix: order (columns, rows), target cell, kernel (row-major,
	// `kernel_count` values at `kernel_first` of `Filter.values`).
	order:        [2]u8,
	target:       [2]u8,
	kernel_first: u16,
	kernel_count: u16,
	divisor:      f32,
	bias:         f32,
	edge:         Convolve_Edge,
	preserve_alpha: bool,
	// Image: index into `Filter.images`, fit and alignment (0..1 per axis).
	image:        u16,
	image_fit:    Image_Fit,
	image_align:  Vec2,
}

Filter_Units :: enum u8 {
	// No region: the filter covers the whole canvas.
	None,
	// x, y, w, h in the layer's user units (SVG filterUnits="userSpaceOnUse").
	User_Space_On_Use,
	// Fractions of `Filter_Region.bbox` (filterUnits="objectBoundingBox").
	Object_Bounding_Box,
}

// The SVG filter region: a rectangle in the layer's user space (the
// transform at `layer_push`) outside which the filter sees and makes
// nothing. On the device it covers the whole pixels of its bounding box:
// the left/top edge floored, the width/height rounded up (as resvg).
Filter_Region :: struct {
	units:      Filter_Units,
	x, y, w, h: f32,
	// The filtered element's bounding box (user space, without stroke), for
	// Object_Bounding_Box units.
	bbox:       Rect,
}

// SVG's default region: the bounding box grown by 10% each side.
FILTER_REGION_DEFAULT :: Filter_Region{.Object_Bounding_Box, -0.1, -0.1, 1.2, 1.2, {}}

Filter :: struct {
	primitives: []Filter_Primitive,
	merge_refs: []Filter_Ref,
	// Compute in sRGB instead of SVG's default linear RGB.
	srgb:       bool,
	region:     Filter_Region,
	// Component transfer tables and convolution kernels.
	values:     []f32,
	// feImage images (sRGB, straight or premultiplied as flagged).
	images:     []Image_Id,
}

// The region in user units; false without one (or when it is empty, which
// filters everything out).
filter_region_rect :: proc "contextless" (r: Filter_Region) -> (rect: Rect, ok: bool) {
	switch r.units {
	case .None:
		return {}, false
	case .User_Space_On_Use:
		rect = {r.x, r.y, r.w, r.h}
	case .Object_Bounding_Box:
		b := r.bbox
		rect = {b.x + r.x * b.w, b.y + r.y * b.h, r.w * b.w, r.h * b.h}
	}
	return rect, true
}

// The region's device-space bounds under `xform`, snapped to pixels.
@(private)
filter_region_device :: proc "contextless" (f: ^Filter, xform: Transform2D) -> (b: Bounds, ok: bool) {
	r := filter_region_rect(f.region) or_return
	return filter_rect_device(r, xform), true
}

@(private)
filter_rect_device :: proc "contextless" (r: Rect, xform: Transform2D) -> (b: Bounds) {
	if r.w <= 0 || r.h <= 0 {
		return {}
	}
	b = {1e30, 1e30, -1e30, -1e30}
	for corner in ([4]Vec2{{r.x, r.y}, {r.x + r.w, r.y}, {r.x, r.y + r.h}, {r.x + r.w, r.y + r.h}}) {
		p := transform_point(xform, corner.x, corner.y)
		b = {min(b.minx, p.x), min(b.miny, p.y), max(b.maxx, p.x), max(b.maxy, p.y)}
	}
	x0, y0 := math.floor(b.minx), math.floor(b.miny)
	return {x0, y0, x0 + math.ceil(b.maxx - b.minx), y0 + math.ceil(b.maxy - b.miny)}
}

// Applies `f` to `source` (released) and returns the filtered layer.
// `xform` is the canvas transform the lengths are measured in.
@(private)
apply_filter :: proc(ls: ^Layer_Stack, c: ^Canvas, f: ^Filter, source: Image_Id, xform: Transform2D) -> Image_Id {
	if len(f.primitives) == 0 {
		return source
	}
	results := make([]Image_Id, len(f.primitives), context.temp_allocator)
	w, h := ls.window.w, ls.window.h
	win := ls.window
	// Per-axis scale (resvg's Transform::get_scale).
	axis_scale := Vec2{math.hypot(xform[0], xform[2]), math.hypot(xform[1], xform[3])}
	// The filter region on the canvas (device pixels) and in the window:
	// the edge the neighbourhood filters see.
	canvas_b := Bounds{0, 0, f32(ls.width), f32(ls.height)}
	region_b := canvas_b
	if rb, ok := filter_region_device(f, xform); ok {
		region_b = bounds_intersect(rb, canvas_b)
	}
	wx, wy := f32(win.x), f32(win.y)
	valid := [4]f32 {
		clamp(region_b.minx - wx, 0, f32(w)),
		clamp(region_b.miny - wy, 0, f32(h)),
		clamp(region_b.maxx - wx, 0, f32(w)),
		clamp(region_b.maxy - wy, 0, f32(h)),
	}
	// Each result's subregion on the canvas (feTile repeats its input's).
	rects := make([]Bounds, len(f.primitives), context.temp_allocator)
	ref_rect :: proc(ref: Filter_Ref, i: int, rects: []Bounds, region: Bounds) -> Bounds {
		switch ref.kind {
		case .Previous:
			return rects[i - 1] if i > 0 else region
		case .Result:
			return rects[min(int(ref.index), i - 1)] if i > 0 else region
		case .Source_Graphic, .Source_Alpha:
		}
		return region
	}

	// Linear light needs about 12 bits to keep sRGB's dark levels (8 bits
	// keep 9 of sRGB's first 49), so a linearRGB filter's images are half
	// floats.
	format := Pixel_Format.RGBA8 if f.srgb else .RGBA16F
	graphic := source
	if !f.srgb {
		graphic = layer_acquire(ls, c, w, h, format = format)
		filter_image(c, graphic, Color_Space_Convert{to_linear = true}, source)
		layer_release(ls, source)
	}
	alpha := Image_Id{}
	get_alpha :: proc(ls: ^Layer_Stack, c: ^Canvas, graphic: Image_Id, alpha: ^Image_Id) -> Image_Id {
		if !image_id_valid(alpha^) {
			alpha^ = layer_acquire(ls, c, ls.window.w, ls.window.h)
			filter_image(c, alpha^, Color_Matrix{ALPHA_ONLY}, graphic)
		}
		return alpha^
	}
	resolve :: proc(ls: ^Layer_Stack, c: ^Canvas, ref: Filter_Ref, i: int, results: []Image_Id, graphic: Image_Id, alpha: ^Image_Id) -> Image_Id {
		switch ref.kind {
		case .Previous:
			return results[i - 1] if i > 0 else graphic
		case .Source_Graphic:
			return graphic
		case .Source_Alpha:
			return get_alpha(ls, c, graphic, alpha)
		case .Result:
			return results[min(int(ref.index), i - 1)] if i > 0 else graphic
		}
		return graphic
	}
	// A flood/shadow color in the working color space.
	working :: proc(col: Color, srgb: bool) -> Color {
		if srgb {
			return col
		}
		return {srgb_to_linear(col.r), srgb_to_linear(col.g), srgb_to_linear(col.b), col.a}
	}
	// The last primitive reading each result, which releases it for the
	// next to reuse (the final result is returned).
	last := make([]int, len(f.primitives), context.temp_allocator)
	result_of :: proc(ref: Filter_Ref, i: int) -> int {
		switch ref.kind {
		case .Previous:
			return i - 1
		case .Result:
			return min(int(ref.index), i - 1)
		case .Source_Graphic, .Source_Alpha:
		}
		return -1
	}
	for p, i in f.primitives {
		last[i] = i
		reads := [2]Filter_Ref{p.in1, p.in2}
		for ref in reads[:2 if p.op == .Composite || p.op == .Blend || p.op == .Displacement_Map else 1] {
			if r := result_of(ref, i); r >= 0 {
				last[r] = i
			}
		}
		if p.op == .Merge {
			for ref in f.merge_refs[p.merge_first:][:p.merge_count] {
				if r := result_of(ref, i); r >= 0 {
					last[r] = i
				}
			}
		}
	}
	last[len(last) - 1] = len(last)
	for &p, i in f.primitives {
		in1 := resolve(ls, c, p.in1, i, results, graphic, &alpha)
		// Turbulence is made in 8 bits (the software backend writes bytes).
		out := layer_acquire(ls, c, w, h, format = .RGBA8 if p.op == .Turbulence else format)
		switch p.op {
		case .Gaussian_Blur:
			layer_blur_into(ls, c, out, in1, p.std * axis_scale, BLUR_MAX_EXACT_SIGMA)
		case .Offset:
			filter_offset_into(ls, c, out, in1, offset_px(xform, p.dx, p.dy))
		case .Flood:
			filter_flood_into(ls, c, out, working(p.color, f.srgb))
		case .Composite:
			in2 := resolve(ls, c, p.in2, i, results, graphic, &alpha)
			filter_image(c, out, Composite{p.composite, p.k, in2}, in1)
		case .Blend:
			in2 := resolve(ls, c, p.in2, i, results, graphic, &alpha)
			filter_image(c, out, Blend{p.blend, in2}, in1)
		case .Color_Matrix:
			filter_image(c, out, Color_Matrix{p.color_matrix}, in1)
		case .Merge:
			layer_target_begin(ls, c, out)
			for ref in f.merge_refs[p.merge_first:][:p.merge_count] {
				layer_blit(ls, c, resolve(ls, c, ref, i, results, graphic, &alpha), 0, 0, w, h, 1)
			}
			layer_target_end(ls, c)
		case .Drop_Shadow:
			// blur(alpha) -> offset -> flood-in -> under the input.
			a := layer_acquire(ls, c, w, h, format = format)
			filter_image(c, a, Color_Matrix{ALPHA_ONLY}, in1)
			blurred := layer_acquire(ls, c, w, h, format = format)
			layer_blur_into(ls, c, blurred, a, p.std * axis_scale, BLUR_MAX_EXACT_SIGMA)
			moved := layer_acquire(ls, c, w, h, format = format)
			filter_offset_into(ls, c, moved, blurred, offset_px(xform, p.dx, p.dy))
			flood := layer_acquire(ls, c, w, h, format = format)
			filter_flood_into(ls, c, flood, working(p.color, f.srgb))
			filter_image(c, a, Composite{.In, {}, moved}, flood)
			layer_target_begin(ls, c, out)
			layer_blit(ls, c, a, 0, 0, w, h, 1)
			layer_blit(ls, c, in1, 0, 0, w, h, 1)
			layer_target_end(ls, c)
			layer_release(ls, blurred)
			layer_release(ls, moved)
			layer_release(ls, flood)
			layer_release(ls, a)
		case .Component_Transfer:
			lut := component_transfer_lut(p.transfer, f.values)
			id := layer_upload(ls, c, image_source_rgba(lut[:], 256, 1), {.Premultiplied, .Nearest})
			filter_image(c, out, Component_Transfer{id}, in1)
		case .Morphology:
			r := p.radius * axis_scale
			if r.x > 0 && r.y > 0 {
				filter_image(c, out, Morphology{{r.x, r.y}, p.dilate, valid}, in1)
			} else {
				filter_clear(ls, c, out)
			}
		case .Turbulence:
			filter_turbulence(ls, c, &p, out, xform, axis_scale, region_b)
		case .Diffuse_Lighting, .Specular_Lighting:
			filter_image(c, out, filter_lighting(&p, xform, win, valid), in1)
		case .Tile:
			t := ref_rect(p.in1, i, rects, region_b)
			filter_image(c, out, Tile{{t.minx - wx, t.miny - wy, t.maxx - t.minx, t.maxy - t.miny}}, in1)
		case .Displacement_Map:
			in2 := resolve(ls, c, p.in2, i, results, graphic, &alpha)
			filter_image(c, out, Displacement_Map{in2, p.scale * axis_scale, p.channels, valid}, in1)
		case .Image:
			filter_draw_image(ls, c, f, &p, out, xform)
		case .Convolve_Matrix:
			if m, ok := filter_convolve(&p, f.values, valid); ok {
				filter_image(c, out, m, in1)
			} else {
				filter_clear(ls, c, out)
			}
		}
		rects[i] = region_b
		if p.op == .Offset && i > 0 && (p.in1.kind == .Previous || p.in1.kind == .Result) {
			// feOffset takes its input's subregion (as resvg).
			rects[i] = ref_rect(p.in1, i, rects, region_b)
		} else if p.has_subregion {
			rects[i] = bounds_intersect(filter_rect_device(p.subregion, xform), canvas_b)
		}
		// Each result is cut to its subregion, by default the region (so
		// a blur after an offset fades at the region's edge).
		if p.has_subregion {
			filter_rect_clip(ls, c, p.subregion, xform, out)
		} else {
			filter_region_clip(ls, c, f, xform, out)
		}
		results[i] = out
		for r in 0 ..= i {
			if last[r] == i {
				layer_release(ls, results[r])
			}
		}
	}

	final := results[len(results) - 1]
	if image_id_valid(alpha) {
		layer_release(ls, alpha)
	}
	layer_release(ls, graphic)
	if !f.srgb {
		back := layer_acquire(ls, c, w, h)
		filter_image(c, back, Color_Space_Convert{to_linear = false}, final)
		layer_release(ls, final)
		final = back
	}
	return final
}

@(private = "file")
filter_clear :: proc(ls: ^Layer_Stack, c: ^Canvas, img: Image_Id) {
	layer_target_begin(ls, c, img)
	layer_target_end(ls, c)
}

// feTurbulence into `out` (the window) as resvg computes it over the
// region: a `Turbulence` filter of the seed's lattice.
@(private = "file")
filter_turbulence :: proc(ls: ^Layer_Stack, c: ^Canvas, p: ^Filter_Primitive, out: Image_Id, xform: Transform2D, s: Vec2, region: Bounds) {
	win := ls.window
	if s.x < 1e-6 || s.y < 1e-6 || win.w == 0 || win.h == 0 {
		filter_clear(ls, c, out)
		return
	}
	t := Turbulence {
		params = {
			base_frequency = {f64(max(p.base_frequency.x, 0)), f64(max(p.base_frequency.y, 0))},
			octaves = p.octaves,
			fractal_noise = p.fractal_noise,
			stitch = p.stitch,
		},
		seed = p.seed,
		offset = {f64(win.x) - f64(xform[4]), f64(win.y) - f64(xform[5])},
		scale = {f64(s.x), f64(s.y)},
		region = {f64(region.minx) - f64(win.x), f64(region.miny) - f64(win.y), f64(region.maxx - region.minx), f64(region.maxy - region.miny)},
	}
	filter_image(c, out, t, layer_turbulence_lattice(ls, c, p.seed))
}

// feImage into `out`: the image fitted into the subregion, converted to
// the working color space.
@(private = "file")
filter_draw_image :: proc(ls: ^Layer_Stack, c: ^Canvas, f: ^Filter, p: ^Filter_Primitive, out: Image_Id, xform: Transform2D) {
	box, has_box := filter_region_rect(f.region)
	if p.has_subregion {
		box, has_box = p.subregion, true
	}
	id := f.images[p.image] if int(p.image) < len(f.images) else {}
	info, ok := image_info(c, id)
	if !has_box || !ok || box.w <= 0 || box.h <= 0 || info.width == 0 || info.height == 0 {
		filter_clear(ls, c, out)
		return
	}
	iw, ih := f32(info.width), f32(info.height)
	img := box
	if p.image_fit != .None {
		k := min(box.w / iw, box.h / ih) if p.image_fit == .Meet else max(box.w / iw, box.h / ih)
		img.w, img.h = iw * k, ih * k
		img.x = box.x + (box.w - img.w) * p.image_align.x
		img.y = box.y + (box.h - img.h) * p.image_align.y
	}
	area := rect_intersect(box, img)
	win := ls.window
	layer_target_begin(ls, c, out, origin = {i32(win.x), i32(win.y)})
	save(c)
	reset_scissor(c)
	set_transform(c, xform)
	path_reset(&ls.scratch)
	path_rect(&ls.scratch, area.x, area.y, area.w, area.h)
	fill_path(c, &ls.scratch, paint_image(id, img.x, img.y, img.w, img.h, 0))
	restore(c)
	layer_target_end(ls, c)
	if !f.srgb {
		filter_image(c, out, Color_Space_Convert{to_linear = true}, out)
	}
}

// The lighting filter of a lighting primitive: light positions in window
// pixels (z scaled as resvg's transform_light_source).
@(private = "file")
filter_lighting :: proc(p: ^Filter_Primitive, xform: Transform2D, win: Layer_Window, valid: [4]f32) -> Lighting {
	lt := p.light
	l := Lighting {
		specular          = p.op == .Specular_Lighting,
		light             = lt.kind,
		color             = {p.color.r, p.color.g, p.color.b},
		surface_scale     = p.surface_scale,
		constant          = p.light_constant,
		specular_exponent = p.specular_exponent,
		spot_exponent     = lt.spot_exponent,
		cone_cos          = -2,
		valid             = valid,
	}
	to_px :: proc(xform: Transform2D, win: Layer_Window, v: [3]f32) -> [3]f32 {
		pt := transform_point(xform, v.x, v.y)
		sz := math.sqrt(xform[0] * xform[0] + xform[3] * xform[3]) / math.SQRT_TWO
		return {pt.x - f32(win.x), pt.y - f32(win.y), v.z * sz}
	}
	switch lt.kind {
	case .Distant:
		az := lt.azimuth * math.RAD_PER_DEG
		el := lt.elevation * math.RAD_PER_DEG
		l.position = {math.cos(az) * math.cos(el), math.sin(az) * math.cos(el), math.sin(el)}
	case .Point, .Spot:
		l.position = to_px(xform, win, lt.position)
		l.points_at = to_px(xform, win, lt.points_at)
		if lt.has_cone {
			l.cone_cos = math.cos(lt.cone_angle * math.RAD_PER_DEG)
		}
	}
	return l
}

// The convolution of a feConvolveMatrix primitive; false when it is
// invalid (it then makes transparent black, as resvg) or too large.
@(private = "file")
filter_convolve :: proc(p: ^Filter_Primitive, values: []f32, valid: [4]f32) -> (m: Convolve_Matrix, ok: bool) {
	n := int(p.order.x) * int(p.order.y)
	if n == 0 || n > CONVOLVE_MAX_KERNEL || int(p.kernel_count) != n || int(p.kernel_first) + n > len(values) || p.divisor == 0 {
		return {}, false
	}
	if p.target.x >= p.order.x || p.target.y >= p.order.y {
		return {}, false
	}
	copy(m.kernel[:], values[p.kernel_first:][:n])
	m.order = {i32(p.order.x), i32(p.order.y)}
	m.target = {i32(p.target.x), i32(p.target.y)}
	m.divisor = p.divisor
	m.bias = p.bias
	m.edge = u8(p.edge)
	m.preserve_alpha = p.preserve_alpha
	m.valid = valid
	return m, true
}

// A length vector in the layer's pixels.
@(private = "file")
offset_px :: proc "contextless" (xform: Transform2D, dx, dy: f32) -> Vec2 {
	return {xform[0] * dx + xform[2] * dy, xform[1] * dx + xform[3] * dy}
}

// How far (pixels per axis) the filter moves or spreads what was drawn, and
// whether its result stays transparent where the source is (false when a
// primitive makes pixels out of nothing: a flood, a matrix adding alpha,
// arithmetic with k4 > 0). Primitives past the 64th count as unbounded.
@(private)
filter_reach :: proc "contextless" (f: ^Filter, xform: Transform2D) -> (reach: Vec2, bounded: bool) {
	axis := Vec2{math.hypot(xform[0], xform[2]), math.hypot(xform[1], xform[3])}
	ok: u64 // bit i: primitive i's result is bounded
	is_bounded :: proc "contextless" (ref: Filter_Ref, i: int, ok: u64) -> bool {
		k := i - 1
		switch ref.kind {
		case .Source_Graphic, .Source_Alpha:
			return true
		case .Previous:
		case .Result:
			k = min(int(ref.index), i - 1)
		}
		return k < 0 || (k < 64 && ok & (1 << uint(k)) != 0)
	}
	for &p, i in f.primitives {
		b1 := is_bounded(p.in1, i, ok)
		b2 := is_bounded(p.in2, i, ok)
		b := b1
		switch p.op {
		case .Gaussian_Blur:
			reach += blur_reach(p.std * axis, BLUR_MAX_EXACT_SIGMA)
		case .Offset:
			d := offset_px(xform, p.dx, p.dy)
			reach += {abs(d.x), abs(d.y)}
		case .Drop_Shadow:
			d := offset_px(xform, p.dx, p.dy)
			reach += blur_reach(p.std * axis, BLUR_MAX_EXACT_SIGMA) + {abs(d.x), abs(d.y)}
		case .Flood:
			b = p.color.a <= 0
		case .Turbulence, .Diffuse_Lighting, .Specular_Lighting, .Tile, .Image:
			b = false
		case .Component_Transfer:
			b = b1 && transfer_value(p.transfer[3], f.values, 0) == 0
		case .Morphology:
			if p.dilate {
				reach += {math.ceil(abs(p.radius.x) * axis.x), math.ceil(abs(p.radius.y) * axis.y)} + 1
			}
		case .Displacement_Map:
			reach += {abs(p.scale) * axis.x, abs(p.scale) * axis.y} * 0.5 + 1
		case .Convolve_Matrix:
			reach += {f32(p.order.x), f32(p.order.y)}
			b = b1 && (p.preserve_alpha || p.bias <= 0) && p.edge != .Wrap
		case .Color_Matrix:
			b = b1 && p.color_matrix[19] <= 0
		case .Blend:
			b = b1 && b2
		case .Composite:
			switch p.composite {
			case .Over, .Xor, .Lighter:
				b = b1 && b2
			case .In:
				b = b1 || b2
			case .Out:
				b = b1
			case .Atop:
				b = b2
			case .Arithmetic:
				k := p.k
				b = k[3] <= 0 && (k[0] == 0 || b1 || b2) && (k[1] == 0 || b1) && (k[2] == 0 || b2)
			}
		case .Merge:
			b = true
			for ref in f.merge_refs[p.merge_first:][:p.merge_count] {
				b &&= is_bounded(ref, i, ok)
			}
		}
		if b && i < 64 {
			ok |= 1 << uint(i)
		}
	}
	n := len(f.primitives)
	return reach, n == 0 || (n <= 64 && ok & (1 << uint(n - 1)) != 0)
}

@(private = "file")
ALPHA_ONLY :: [20]f32{0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0}

@(private = "file")
filter_offset_into :: proc(ls: ^Layer_Stack, c: ^Canvas, dst, src: Image_Id, d: Vec2) {
	draw_scaled_into(ls, c, dst, src, ls.window.w, ls.window.h, d)
}

@(private = "file")
filter_flood_into :: proc(ls: ^Layer_Stack, c: ^Canvas, dst: Image_Id, col: Color) {
	layer_target_begin(ls, c, dst)
	save(c)
	reset_transform(c)
	reset_scissor(c)
	path_reset(&ls.scratch)
	path_rect(&ls.scratch, 0, 0, f32(ls.window.w), f32(ls.window.h))
	p := paint_color(col)
	p.anti_alias = false
	fill_path(c, &ls.scratch, p)
	restore(c)
	layer_target_end(ls, c)
}

// Replaces `dst` (w x h) with `src` scaled to fit it and moved by `d`.
@(private = "file")
draw_scaled_into :: proc(ls: ^Layer_Stack, c: ^Canvas, dst, src: Image_Id, w, h: u32, d: Vec2) {
	layer_target_begin(ls, c, dst)
	save(c)
	reset_transform(c)
	reset_scissor(c)
	// Only the moved image area: outside it stays transparent (image
	// paints clamp at their edges).
	path_reset(&ls.scratch)
	path_rect(&ls.scratch, d.x, d.y, f32(w), f32(h))
	p := paint_image(src, d.x, d.y, f32(w), f32(h), 0)
	p.anti_alias = false
	fill_path(c, &ls.scratch, p)
	restore(c)
	layer_target_end(ls, c)
}

// Cuts `img` (a layer image of the window being popped) to the filter
// region: clears the window outside the region's device bounds (whole
// pixels; a rotated region cuts to its bounding box, as resvg).
@(private)
filter_region_clip :: proc(ls: ^Layer_Stack, c: ^Canvas, f: ^Filter, xform: Transform2D, img: Image_Id) {
	if r, ok := filter_region_rect(f.region); ok {
		filter_rect_clip(ls, c, r, xform, img)
	}
}

// Cuts `img` to rectangle `r` (user units under `xform`), like
// `filter_region_clip`.
@(private)
filter_rect_clip :: proc(ls: ^Layer_Stack, c: ^Canvas, r: Rect, xform: Transform2D, img: Image_Id) {
	rb := filter_rect_device(r, xform)
	win := ls.window
	wx0, wy0 := f32(win.x), f32(win.y)
	wx1, wy1 := wx0 + f32(win.w), wy0 + f32(win.h)
	if rb.minx <= wx0 && rb.miny <= wy0 && rb.maxx >= wx1 && rb.maxy >= wy1 {
		return
	}
	x0 := clamp(rb.minx, wx0, wx1)
	y0 := clamp(rb.miny, wy0, wy1)
	x1 := clamp(rb.maxx, x0, wx1)
	y1 := clamp(rb.maxy, y0, wy1)
	layer_target_begin(ls, c, img, keep = true, origin = {i32(win.x), i32(win.y)})
	save(c)
	reset_scissor(c)
	strip :: proc(c: ^Canvas, x0, y0, x1, y1: f32) {
		if x1 > x0 && y1 > y0 {
			clear_rect(c, u32(x0), u32(y0), u32(x1 - x0), u32(y1 - y0), TRANSPARENT)
		}
	}
	strip(c, wx0, wy0, wx1, y0) // above
	strip(c, wx0, y1, wx1, wy1) // below
	strip(c, wx0, y0, x0, y1) // left
	strip(c, x1, y0, wx1, y1) // right
	restore(c)
	layer_target_end(ls, c)
}
