package scenes

import "core:math"

import vg "../.."

// Motion blur (vg.canvas_motion_blur): draws moving as set_motion says,
// each way a draw reaches the velocity twins: box, affine and hairline
// shapes, text (opaque and translucent), markers, groups and layers
// (faded, clipped, masked, blurred, blended), over a still ground.

@(private = "file")
fill :: proc(c: ^vg.Canvas, r: ^Resources, col: vg.Color) {
	vg.fill_path(c, &r.path, vg.paint_color(col))
}

// Turning by `a` about (x, y).
@(private = "file")
turning :: proc(x, y, a: f32) -> vg.Transform2D {
	return vg.transform_multiply(vg.transform_multiply(vg.transform_translation(-x, -y), vg.transform_rotation(a)), vg.transform_translation(x, y))
}

scene_motion :: proc(c: ^vg.Canvas, r: ^Resources) {
	ls := &r.layers
	p := &r.path
	vg.layer_stack_begin(ls, c, W, H, nil, true)
	vg.set_motion(c, vg.TRANSFORM_IDENTITY)
	vg.path_reset(p)
	vg.path_rect(p, 0, 0, W, H)
	vg.fill_path(c, p, vg.paint_linear_gradient(0, 0, W, H, vg.rgb(30, 40, 90), vg.rgb(220, 180, 120)))

	// A box sliding right and down, and a star turning, scaled and skewed.
	vg.set_motion(c, vg.transform_translation(-7, -3))
	vg.path_reset(p)
	vg.path_rect(p, 12, 12, 46, 30)
	fill(c, r, vg.rgb(250, 220, 60))
	vg.set_motion(c, turning(100, 40, -0.15))
	vg.save(c)
	vg.translate(c, 100, 40)
	vg.rotate(c, 0.3)
	vg.skew_x(c, 0.2)
	vg.path_reset(p)
	for i in 0 ..< 5 {
		a := f32(i) * 4 * math.PI / 5 - math.PI / 2
		if i == 0 {
			vg.path_move_to(p, 26 * math.cos(a), 26 * math.sin(a))
		} else {
			vg.path_line_to(p, 26 * math.cos(a), 26 * math.sin(a))
		}
	}
	vg.path_close(p)
	fill(c, r, vg.rgb(240, 70, 90))
	vg.restore(c)

	// Text sliding in a fading group (drawn as one group of shapes), and
	// growing in a clipped layer (drawn through images).
	vg.layer_push(ls, c, {opacity = 0.6})
	vg.set_motion(c, vg.transform_translation(-10, 0))
	f, g, em := lay(r, "Sliding", 150, 34, 26)
	vg.fill_glyph_outlines(c, f, g, em, vg.paint_color(vg.rgb(255, 255, 255)), &r.scratch)
	vg.layer_pop(ls, c)
	vg.path_reset(&r.scratch)
	vg.path_rect(&r.scratch, 150, 44, 90, 22)
	vg.layer_push(ls, c, {opacity = 0.9, clip_path = &r.scratch})
	vg.set_motion(c, vg.transform_multiply(vg.transform_multiply(vg.transform_translation(-195, -60), vg.transform_scaling(0.8, 0.8)), vg.transform_translation(195, 60)))
	f, g, em = lay(r, "Growing", 150, 64, 24)
	vg.fill_glyph_outlines(c, f, g, em, vg.paint_color(vg.rgb(40, 220, 160)), &r.scratch)
	vg.layer_pop(ls, c)

	// A blurred circle rising, a masked bar sliding left, a blended disc
	// turning.
	vg.layer_push(ls, c, {blur = 3})
	vg.set_motion(c, vg.transform_translation(0, 9))
	vg.path_reset(p)
	vg.path_circle(p, 40, 100, 18)
	fill(c, r, vg.rgb(90, 240, 200))
	vg.layer_pop(ls, c)
	vg.layer_push(ls, c, {})
	vg.set_motion(c, vg.transform_translation(12, 0))
	vg.path_reset(p)
	vg.path_rect(p, 80, 86, 80, 26)
	fill(c, r, vg.rgb(120, 60, 255))
	vg.layer_mask_begin(ls, c)
	vg.path_reset(p)
	vg.path_circle(p, 120, 99, 22)
	fill(c, r, vg.rgb(255, 255, 255))
	vg.layer_mask_end(ls, c)
	vg.layer_pop(ls, c)
	vg.layer_push(ls, c, {blend = .Screen, opacity = 0.8})
	vg.set_motion(c, turning(205, 100, 0.2))
	vg.path_reset(p)
	vg.path_ellipse(p, 205, 100, 30, 18)
	fill(c, r, vg.rgb(255, 120, 40))
	vg.layer_pop(ls, c)

	// Markers drifting, a hairline turning, translucent text sliding up.
	vg.set_motion(c, vg.transform_translation(-4, 5))
	points: [40]vg.Vec2
	for &q, k in points {
		q = {16 + f32(k % 10) * 9, 136 + f32(k / 10) * 9}
	}
	vg.fill_markers(c, .Circle, 3.5, 0, vg.paint_color(vg.rgb(250, 250, 250)), points[:])
	vg.set_motion(c, turning(150, 160, 0.1))
	vg.path_reset(p)
	vg.path_move_to(p, 110, 175)
	vg.path_bezier_to(p, 130, 130, 170, 190, 190, 140)
	if s, ok := vg.shape_from_path(p, outline = true); ok {
		shape := new_clone(s)
		append(&r.frame_shapes, shape)
		vg.hairline_shape(c, shape, vg.paint_color(vg.rgb(20, 20, 40)), 1.5)
	}
	vg.set_motion(c, vg.transform_translation(0, 6))
	f, g, em = lay(r, "up", 205, 180, 30)
	vg.fill_glyph_outlines(c, f, g, em, vg.paint_color(vg.rgba(255, 255, 255, 160)), &r.scratch)
	vg.layer_stack_end(ls, c)
}
