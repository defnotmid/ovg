package scenes

import vg "../.."

// Layer scenes: group effects through the layer stack (`layer_push` /
// `layer_pop`), with content near and across the canvas edges so layers
// sized to their content must match full-frame ones.


@(private = "file")
background :: proc(c: ^vg.Canvas, r: ^Resources) {
	p := &r.path
	vg.path_reset(p)
	vg.path_rect(p, 0, 0, W, H)
	vg.fill_path(c, p, vg.paint_linear_gradient(0, 0, W, H, vg.rgb(30, 40, 90), vg.rgb(220, 180, 120)))
}

@(private = "file")
circle :: proc(c: ^vg.Canvas, r: ^Resources, x, y, rad: f32, col: vg.Color) {
	p := &r.path
	vg.path_reset(p)
	vg.path_circle(p, x, y, rad)
	vg.fill_path(c, p, vg.paint_color(col))
}

@(private = "file")
rect :: proc(c: ^vg.Canvas, r: ^Resources, x, y, w, h: f32, col: vg.Color) {
	p := &r.path
	vg.path_reset(p)
	vg.path_rect(p, x, y, w, h)
	vg.fill_path(c, p, vg.paint_color(col))
}

@(private = "file")
blurred_circle :: proc(c: ^vg.Canvas, r: ^Resources, x, y, rad, blur: f32, col: vg.Color, opacity: f32 = 1) {
	vg.layer_push(&r.layers, c, {blur = blur, opacity = opacity})
	circle(c, r, x, y, rad, col)
	vg.layer_pop(&r.layers, c)
}

scene_layers :: proc(c: ^vg.Canvas, r: ^Resources) {
	ls := &r.layers
	vg.layer_stack_begin(ls, c, W, H)
	background(c, r)
	// Exact blurs, one across the left edge.
	blurred_circle(c, r, 40, 40, 18, 3, vg.rgb(250, 220, 60))
	blurred_circle(c, r, 4, 110, 20, 5, vg.rgba(90, 240, 200, 220), 0.8)
	// Downscaled blurs, across the right and bottom edges.
	blurred_circle(c, r, 245, 60, 26, 14, vg.rgb(255, 90, 40))
	blurred_circle(c, r, 130, 186, 16, 21, vg.rgb(250, 250, 250))
	blurred_circle(c, r, 200, 150, 9, 7.5, vg.rgb(120, 60, 255))
	// Off the canvas: nothing to draw.
	blurred_circle(c, r, 600, 40, 10, 4, vg.rgb(255, 0, 0))
	// Opacity group of overlapping shapes, scaled and rotated.
	vg.save(c)
	vg.translate(c, 100, 70)
	vg.rotate(c, 0.4)
	vg.scale(c, 1.3, 1.3)
	vg.layer_push(ls, c, {opacity = 0.6, blur = 1.5})
	circle(c, r, 0, 0, 16, vg.rgb(240, 40, 90))
	circle(c, r, 14, 6, 14, vg.rgb(40, 90, 240))
	clear(&r.glyphs)
	small := vg.font_scale_for_em(&r.font, 12)
	vg.layout_simple(&r.font, "glow", -14, 30, small, &r.glyphs)
	vg.fill_glyph_run(c, &r.font, &r.atlas, r.glyphs[:], small, vg.paint_color(vg.rgb(255, 255, 255)))
	vg.layer_pop(ls, c)
	vg.restore(c)
	// Nested: a sharp group holding blurred children and a stroke.
	vg.layer_push(ls, c, {opacity = 0.85})
	blurred_circle(c, r, 160, 30, 14, 2.5, vg.rgb(60, 220, 90))
	vg.layer_push(ls, c, {blur = 9})
	rect(c, r, 150, 80, 40, 24, vg.rgb(255, 240, 0))
	blurred_circle(c, r, 190, 100, 10, 3, vg.rgb(0, 160, 255))
	vg.layer_pop(ls, c)
	p := &r.path
	vg.path_reset(p)
	vg.path_move_to(p, 120, 20)
	vg.path_line_to(p, 230, 120)
	sp := vg.paint_color(vg.rgb(255, 255, 255))
	sp.stroke.line_width = 3
	sp.stroke.line_join = .Miter
	vg.stroke_path(c, p, sp)
	vg.layer_pop(ls, c)
	// Scissored content in a blurred layer.
	vg.save(c)
	vg.scissor(c, 20, 140, 50, 30)
	vg.layer_push(ls, c, {blur = 4})
	rect(c, r, 0, 120, 100, 72, vg.rgb(255, 120, 200))
	vg.layer_pop(ls, c)
	vg.restore(c)
	vg.layer_stack_end(ls, c)
}

scene_layer_masks :: proc(c: ^vg.Canvas, r: ^Resources) {
	ls := &r.layers
	vg.layer_stack_begin(ls, c, W, H)
	background(c, r)
	p := &r.path
	// Clip path (a star) over a large blurred rectangle.
	vg.path_reset(&r.scratch)
	vg.path_move_to(&r.scratch, 60, 10)
	vg.path_line_to(&r.scratch, 75, 80)
	vg.path_line_to(&r.scratch, 10, 35)
	vg.path_line_to(&r.scratch, 110, 35)
	vg.path_line_to(&r.scratch, 45, 80)
	vg.path_close(&r.scratch)
	vg.layer_push(ls, c, {blur = 6, clip_path = &r.scratch, clip_rule = .Even_Odd})
	rect(c, r, -40, -40, 180, 160, vg.rgb(250, 200, 30))
	circle(c, r, 60, 45, 20, vg.rgb(200, 0, 80))
	vg.layer_pop(ls, c)
	// Luminance mask: a radial gradient.
	vg.layer_push(ls, c, {opacity = 0.9})
	vg.layer_mask_begin(ls, c)
	vg.path_reset(p)
	vg.path_circle(p, 180, 50, 45)
	vg.fill_path(c, p, vg.paint_radial_gradient(180, 50, 5, 45, vg.rgb(255, 255, 255), vg.rgba(0, 0, 0, 255)))
	vg.layer_mask_end(ls, c)
	rect(c, r, 120, 0, 136, 110, vg.rgb(40, 230, 255))
	vg.layer_pop(ls, c)
	// Alpha mask with a blur, across the bottom edge.
	vg.layer_push(ls, c, {blur = 10, mask_alpha = true})
	vg.layer_mask_begin(ls, c)
	rect(c, r, 20, 120, 90, 80, vg.rgba(0, 0, 0, 160))
	vg.layer_mask_end(ls, c)
	circle(c, r, 60, 170, 40, vg.rgb(255, 60, 30))
	vg.layer_pop(ls, c)
	// Clip and mask together, the mask touching the right edge.
	vg.path_reset(&r.scratch)
	vg.path_circle(&r.scratch, 200, 150, 40)
	vg.layer_push(ls, c, {clip_path = &r.scratch, blur = 2})
	vg.layer_mask_begin(ls, c)
	rect(c, r, 180, 100, 80, 90, vg.rgb(255, 255, 255))
	vg.layer_mask_end(ls, c)
	rect(c, r, 140, 110, 120, 80, vg.rgb(120, 255, 90))
	vg.layer_pop(ls, c)
	// A pattern tile drawn inside a blurred layer.
	vg.layer_push(ls, c, {blur = 1})
	tile := vg.layer_pattern_begin(ls, c, 8, 8)
	rect(c, r, 0, 0, 4, 4, vg.rgb(0, 0, 0))
	rect(c, r, 4, 4, 4, 4, vg.rgb(255, 255, 255))
	vg.layer_pattern_end(ls, c)
	vg.path_reset(p)
	vg.path_rect(p, 120, 120, 40, 40)
	vg.fill_path(c, p, vg.paint_image(tile, 0, 0, 8, 8, 0))
	vg.layer_pop(ls, c)
	vg.layer_stack_end(ls, c)
}

scene_layer_filters :: proc(c: ^vg.Canvas, r: ^Resources) {
	ls := &r.layers
	vg.layer_stack_begin(ls, c, W, H)
	background(c, r)
	// Drop shadow.
	shadow := [1]vg.Filter_Primitive{{op = .Drop_Shadow, std = {3, 3}, dx = 6, dy = 5, color = vg.rgba(0, 0, 0, 200)}}
	f1 := vg.Filter{primitives = shadow[:]}
	vg.layer_push(ls, c, {filter = &f1})
	rect(c, r, 20, 20, 50, 30, vg.rgb(250, 250, 250))
	vg.layer_pop(ls, c)
	// Offset copies merged with the source, srgb, wide anisotropic blur.
	prims := [3]vg.Filter_Primitive {
		{op = .Gaussian_Blur, std = {12, 2}},
		{op = .Offset, dx = -14, dy = 9},
		{op = .Merge, merge_first = 0, merge_count = 2},
	}
	refs := [2]vg.Filter_Ref{{kind = .Previous}, {kind = .Source_Graphic}}
	f2 := vg.Filter{primitives = prims[:], merge_refs = refs[:], srgb = true}
	vg.layer_push(ls, c, {filter = &f2})
	circle(c, r, 240, 40, 22, vg.rgb(255, 80, 120))
	vg.layer_pop(ls, c)
	// Flood composited into the source alpha: bounded.
	glow := [3]vg.Filter_Primitive {
		{op = .Flood, color = vg.rgba(255, 220, 0, 180)},
		{op = .Composite, composite = .In, in1 = {kind = .Previous}, in2 = {kind = .Source_Alpha}},
		{op = .Gaussian_Blur, std = {4, 4}},
	}
	f3 := vg.Filter{primitives = glow[:]}
	vg.layer_push(ls, c, {filter = &f3})
	circle(c, r, 70, 120, 20, vg.rgb(0, 0, 0))
	vg.layer_pop(ls, c)
	// A flood alone covers the whole layer, whatever is drawn.
	flood := [2]vg.Filter_Primitive {
		{op = .Flood, color = vg.rgba(0, 80, 255, 40)},
		{op = .Merge, merge_first = 0, merge_count = 2},
	}
	frefs := [2]vg.Filter_Ref{{kind = .Previous}, {kind = .Source_Graphic}}
	f4 := vg.Filter{primitives = flood[:], merge_refs = frefs[:]}
	vg.layer_push(ls, c, {filter = &f4})
	circle(c, r, 170, 130, 15, vg.rgb(255, 255, 255))
	vg.layer_pop(ls, c)
	// A matrix that adds alpha everywhere.
	m := [1]vg.Filter_Primitive{{op = .Color_Matrix}}
	m[0].color_matrix = {1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0.08}
	f5 := vg.Filter{primitives = m[:], srgb = true}
	vg.layer_push(ls, c, {filter = &f5, blur = 3})
	circle(c, r, 200, 180, 12, vg.rgb(255, 0, 0))
	vg.layer_pop(ls, c)
	vg.layer_stack_end(ls, c)
}

// feComponentTransfer, feMorphology, feTurbulence, lighting, feTile,
// feDisplacementMap and feConvolveMatrix, each in its own region.
scene_filters_more :: proc(c: ^vg.Canvas, r: ^Resources) {
	ls := &r.layers
	vg.layer_stack_begin(ls, c, W, H)
	background(c, r)
	region :: proc(x, y, w, h: f32) -> vg.Filter_Region {
		return {units = .User_Space_On_Use, x = x, y = y, w = w, h = h}
	}
	values := [?]f32{0, 1, 0.2, 0.9, 0.1, 0.5, 1, 0, -1, 0, -1, 5, -1, 0, -1, 0}
	// Component transfer: table on red, discrete on green, gamma on blue.
	ct := [1]vg.Filter_Primitive{{op = .Component_Transfer}}
	ct[0].transfer = vg.TRANSFER_IDENTITY
	ct[0].transfer[0] = {kind = .Table, first = 2, count = 2}
	ct[0].transfer[1] = {kind = .Discrete, first = 4, count = 3}
	ct[0].transfer[2] = {kind = .Gamma, amplitude = 1.2, exponent = 0.5, offset = 0.05}
	f1 := vg.Filter{primitives = ct[:], region = region(5, 5, 70, 55), values = values[:]}
	vg.layer_push(ls, c, {filter = &f1})
	circle(c, r, 40, 32, 24, vg.rgba(200, 120, 60, 220))
	vg.layer_pop(ls, c)
	// Dilate then erode.
	mo := [2]vg.Filter_Primitive{{op = .Morphology, radius = {3, 1}, dilate = true}, {op = .Morphology, radius = {1, 2}}}
	f2 := vg.Filter{primitives = mo[:], region = region(85, 5, 80, 55)}
	vg.layer_push(ls, c, {filter = &f2})
	rect(c, r, 100, 15, 20, 30, vg.rgb(30, 160, 90))
	circle(c, r, 145, 32, 12, vg.rgba(230, 40, 90, 200))
	vg.layer_pop(ls, c)
	// Fractal noise, stitched.
	tu := [1]vg.Filter_Primitive{{op = .Turbulence, base_frequency = {0.05, 0.08}, octaves = 3, seed = 7, stitch = true, fractal_noise = true}}
	f3 := vg.Filter{primitives = tu[:], region = region(175, 5, 75, 55)}
	vg.layer_push(ls, c, {filter = &f3})
	rect(c, r, 180, 10, 4, 4, vg.rgb(0, 0, 0))
	vg.layer_pop(ls, c)
	// Diffuse lighting (point light) and specular lighting (spot light)
	// over a blurred alpha.
	li := [3]vg.Filter_Primitive {
		{op = .Gaussian_Blur, std = {3, 3}, in1 = {kind = .Source_Alpha}},
		{op = .Diffuse_Lighting, color = vg.rgb(255, 230, 200), surface_scale = 4, light_constant = 1, light = {kind = .Point, position = {30, 70, 40}}},
		{op = .Composite, composite = .In, in1 = {kind = .Previous}, in2 = {kind = .Source_Alpha}},
	}
	f4 := vg.Filter{primitives = li[:], region = region(5, 65, 80, 60)}
	vg.layer_push(ls, c, {filter = &f4})
	circle(c, r, 45, 95, 25, vg.rgb(255, 255, 255))
	vg.layer_pop(ls, c)
	sp := [2]vg.Filter_Primitive {
		{op = .Gaussian_Blur, std = {2, 2}, in1 = {kind = .Source_Alpha}},
		{
			op = .Specular_Lighting,
			color = vg.rgb(200, 220, 255),
			surface_scale = 5,
			light_constant = 1.2,
			specular_exponent = 12,
			light = {kind = .Spot, position = {100, 70, 60}, points_at = {125, 100, 0}, spot_exponent = 2, cone_angle = 40, has_cone = true},
		},
	}
	f5 := vg.Filter{primitives = sp[:], region = region(90, 65, 75, 60)}
	vg.layer_push(ls, c, {filter = &f5})
	rect(c, r, 105, 75, 40, 40, vg.rgb(0, 0, 0))
	vg.layer_pop(ls, c)
	// Tile of a flood subregion offset into it; distant light over it.
	ti := [3]vg.Filter_Primitive {
		{op = .Flood, color = vg.rgb(250, 160, 30), has_subregion = true, subregion = {175, 65, 12, 12}},
		{op = .Offset, dx = 5, dy = 4},
		{op = .Tile},
	}
	f6 := vg.Filter{primitives = ti[:], region = region(175, 65, 75, 60)}
	vg.layer_push(ls, c, {filter = &f6})
	rect(c, r, 180, 70, 4, 4, vg.rgb(0, 0, 0))
	vg.layer_pop(ls, c)
	// Displacement by noise.
	di := [2]vg.Filter_Primitive {
		{op = .Turbulence, base_frequency = {0.06, 0.06}, octaves = 2, seed = 3},
		{op = .Displacement_Map, in1 = {kind = .Source_Graphic}, in2 = {kind = .Previous}, scale = 14, channels = {0, 1}},
	}
	f7 := vg.Filter{primitives = di[:], region = region(5, 130, 120, 58)}
	vg.layer_push(ls, c, {filter = &f7})
	rect(c, r, 20, 140, 90, 12, vg.rgb(40, 90, 230))
	rect(c, r, 20, 162, 90, 12, vg.rgb(230, 90, 40))
	vg.layer_pop(ls, c)
	// Emboss-like convolution, wrapping at the region's edge.
	cv := [1]vg.Filter_Primitive{{op = .Convolve_Matrix, order = {3, 3}, target = {1, 1}, kernel_first = 7, kernel_count = 9, divisor = 1, bias = 0.1, edge = .Wrap}}
	f8 := vg.Filter{primitives = cv[:], region = region(130, 130, 120, 58), values = values[:]}
	vg.layer_push(ls, c, {filter = &f8})
	circle(c, r, 190, 159, 22, vg.rgb(120, 200, 80))
	vg.layer_pop(ls, c)
	vg.layer_stack_end(ls, c)
}

// feTurbulence: both types, many octaves, stitching, under scale and
// rotation (the GPU's f32 noise against the software backend's f64).
scene_turbulence :: proc(c: ^vg.Canvas, r: ^Resources) {
	ls := &r.layers
	vg.layer_stack_begin(ls, c, W, H)
	background(c, r)
	region :: proc(x, y, w, h: f32) -> vg.Filter_Region {
		return {units = .User_Space_On_Use, x = x, y = y, w = w, h = h}
	}
	cases := [4]vg.Filter_Primitive {
		{op = .Turbulence, base_frequency = {0.03, 0.05}, octaves = 4, seed = 11},
		{op = .Turbulence, base_frequency = {0.02, 0.02}, octaves = 10, seed = -20, fractal_noise = true},
		{op = .Turbulence, base_frequency = {0.07, 0.04}, octaves = 3, seed = 2, stitch = true},
		{op = .Turbulence, base_frequency = {0.01, 0.09}, octaves = 2, seed = 1, stitch = true, fractal_noise = true},
	}
	for i in 0 ..< 4 {
		f := vg.Filter{primitives = cases[i:][:1], region = region(0, 0, 110, 80)}
		vg.save(c)
		vg.translate(c, 10 + f32(i % 2) * 125, 10 + f32(i / 2) * 92)
		if i == 2 {
			vg.scale(c, 1.3, 0.8)
		} else if i == 3 {
			vg.translate(c, 55, 40)
			vg.rotate(c, 0.3)
			vg.translate(c, -55, -40)
		}
		vg.layer_push(ls, c, {filter = &f})
		rect(c, r, 2, 2, 4, 4, vg.rgb(0, 0, 0))
		vg.layer_pop(ls, c)
		vg.restore(c)
	}
	vg.layer_stack_end(ls, c)
}

scene_layer_blend :: proc(c: ^vg.Canvas, r: ^Resources) {
	ls := &r.layers
	vg.layer_stack_begin(ls, c, W, H, nil, true)
	background(c, r)
	vg.layer_push(ls, c, {blend = .Multiply})
	circle(c, r, 60, 60, 40, vg.rgb(255, 120, 40))
	vg.layer_pop(ls, c)
	// A blended child inside a blurred parent.
	vg.layer_push(ls, c, {blur = 2, opacity = 0.9})
	rect(c, r, 120, 30, 100, 60, vg.rgb(40, 120, 220))
	vg.layer_push(ls, c, {blend = .Screen, opacity = 0.7})
	circle(c, r, 170, 60, 30, vg.rgb(250, 200, 30))
	vg.layer_pop(ls, c)
	vg.layer_pop(ls, c)
	// Sharp blurred groups next to blended ones.
	blurred_circle(c, r, 60, 150, 25, 6, vg.rgb(0, 250, 120))
	vg.layer_push(ls, c, {blend = .Difference, blur = 3})
	rect(c, r, 150, 120, 90, 60, vg.rgb(255, 255, 255))
	vg.layer_pop(ls, c)
	vg.layer_stack_end(ls, c)
}
