package scenes

import "core:math"

import vg "../.."

// Shapes drawn by coverage (vg.fill_shape): glyphs at small and large
// sizes, rotated with a gradient, a scissor and global alpha, and an
// even-odd path with an image paint.
scene_curves :: proc(c: ^vg.Canvas, r: ^Resources) {
	text :: proc(c: ^vg.Canvas, r: ^Resources, s: string, x, y, size: f32, paint: vg.Paint) {
		f, glyphs, em := lay(r, s, x, y, size)
		for g in glyphs {
			if shape := vg.font_glyph_shape(f, g.glyph); shape != nil {
				vg.fill_shape(c, shape, paint, {em, 0, 0, em, g.x, g.y})
			}
		}
	}
	text(c, r, "Coverage 9px: the quick brown fox", 6, 12, 9, vg.paint_color(vg.rgb(20, 20, 40)))
	text(c, r, "13px jumps over the lazy dog", 6, 28, 13, vg.paint_color(vg.rgb(0, 90, 160)))

	vg.save(c)
	vg.translate(c, 14, 70)
	vg.rotate(c, -0.2)
	vg.scale(c, 1.2, 0.9)
	text(c, r, "Rotated", 0, 0, 28, vg.paint_linear_gradient(0, -20, 120, 0, vg.rgb(255, 60, 0), vg.rgb(120, 0, 255)))
	vg.restore(c)

	vg.save(c)
	vg.set_global_alpha(c, 0.7)
	vg.scissor(c, 150, 40, 100, 70)
	text(c, r, "Ag", 140, 130, 110, vg.paint_radial_gradient(195, 90, 5, 60, vg.rgb(250, 200, 40), vg.rgb(200, 30, 90)))
	vg.restore(c)

	star := &r.path
	vg.path_reset(star)
	for i in 0 ..< 5 {
		a := f32(i) * 4 * math.PI / 5 - math.PI / 2
		x, y := 70 + 50 * math.cos(a), 140 + 45 * math.sin(a)
		if i == 0 {
			vg.path_move_to(star, x, y)
		} else {
			vg.path_line_to(star, x, y)
		}
	}
	vg.path_close(star)
	vg.path_circle(star, 70, 140, 14)
	if built, ok := vg.shape_from_path(star); ok {
		// Drawn this frame only: freed (with its GPU copy) next frame. The
		// frame keeps a pointer, so the shape stays put until then.
		shape := new_clone(built)
		append(&r.frame_shapes, shape)
		eo := vg.paint_image(r.checker, 20, 95, 100, 90, 0)
		eo.fill_rule = .Even_Odd
		vg.fill_shape(c, shape, eo)
		vg.fill_shape(c, shape, vg.paint_color(vg.rgba(0, 160, 80, 140)), vg.transform_translation(60, 10))
	}
}

// Translucent text whose glyphs overlap fills as one (a group):
// global alpha, a translucent colour, a translucent gradient, under a
// rotation and a scissor.
scene_curves_alpha :: proc(c: ^vg.Canvas, r: ^Resources) {
	vg.clear_rect(c, 0, 0, W, H, vg.rgb(16, 20, 24))
	run :: proc(c: ^vg.Canvas, r: ^Resources, s: string, x0, y, size, spacing: f32, paint: vg.Paint) {
		x := x0
		clear(&r.glyphs)
		font := vg.font_collection_font(&r.fonts, r.fonts.fallback.id)
		sc := vg.font_scale_for_em(font, size)
		for ch in s {
			g := vg.font_glyph_index(font, ch)
			append(&r.glyphs, vg.Positioned_Glyph{g, x, y})
			adv, _ := vg.font_glyph_advance(font, g)
			x += f32(adv) * sc + spacing
		}
		vg.fill_glyph_outlines(c, font, r.glyphs[:], sc, paint, &r.scratch)
	}
	vg.save(c)
	vg.set_global_alpha(c, 0.5)
	run(c, r, "OVERLAP", 6, 48, 44, -10, vg.paint_color(vg.WHITE))
	vg.restore(c)
	run(c, r, "OVERLAP", 6, 100, 44, -10, vg.paint_color(vg.rgba(255, 255, 255, 128)))
	vg.save(c)
	vg.translate(c, 30, 120)
	vg.rotate(c, 0.12)
	vg.scissor(c, 0, 0, 200, 60)
	run(c, r, "fading", 0, 40, 48, -8, vg.paint_linear_gradient(0, 0, 200, 0, vg.rgba(255, 200, 40, 200), vg.rgba(80, 160, 255, 90)))
	vg.restore(c)
}

// Hairlines (vg.hairline_shape): one shape's fill and its outline, the
// outline at 1 px, at 2.5 px turned and magnified (the width stays), an
// open path's (no closing edge), translucent and under a scissor, and a
// small ring at many places (vg.hairline_shapes).
scene_hairlines :: proc(c: ^vg.Canvas, r: ^Resources) {
	vg.clear_rect(c, 0, 0, W, H, vg.rgb(245, 243, 238))
	kept :: proc(r: ^Resources, built: vg.Shape) -> ^vg.Shape {
		shape := new_clone(built)
		append(&r.frame_shapes, shape)
		return shape
	}
	p := &r.path
	vg.path_reset(p)
	for i in 0 ..< 5 {
		a := f32(i) * 4 * math.PI / 5 - math.PI / 2
		x, y := 50 + 38 * math.cos(a), 52 + 36 * math.sin(a)
		if i == 0 {
			vg.path_move_to(p, x, y)
		} else {
			vg.path_line_to(p, x, y)
		}
	}
	vg.path_close(p)
	vg.path_circle(p, 50, 52, 11)
	star, ok := vg.shape_from_path(p, outline = true)
	if !ok {
		return
	}
	s := kept(r, star)
	vg.fill_shape(c, s, vg.paint_color(vg.rgb(250, 210, 120)))
	vg.hairline_shape(c, s, vg.paint_color(vg.rgb(20, 60, 200)), 1)
	turned := vg.transform_multiply(vg.transform_multiply(vg.transform_translation(-50, -52), vg.transform_multiply(vg.transform_scaling(1.6, 1.6), vg.transform_rotation(0.3))), vg.transform_translation(150, 70))
	vg.hairline_shape(c, s, vg.paint_color(vg.rgba(200, 30, 60, 170)), 2.5, turned)

	// An open path: handle lines and a curve, the closing edge not drawn.
	vg.path_reset(p)
	vg.path_move_to(p, 20, 170)
	vg.path_line_to(p, 60, 120)
	vg.path_bezier_to(p, 90, 100, 120, 190, 160, 150)
	vg.path_line_to(p, 175, 175)
	if open_path, open_ok := vg.shape_from_path(p, outline = true); open_ok {
		o := kept(r, open_path)
		vg.hairline_shape(c, o, vg.paint_linear_gradient(20, 0, 175, 0, vg.rgb(0, 140, 90), vg.rgb(120, 0, 160)), 1.5)
		vg.save(c)
		vg.scissor(c, 90, 120, 60, 40)
		vg.hairline_shape(c, o, vg.paint_color(vg.rgb(0, 0, 0)), 3, vg.transform_translation(8, -12))
		vg.restore(c)
	}

	// One ring at many places.
	vg.path_reset(p)
	vg.path_circle(p, 0, 0, 3.5)
	if ring_shape, ring_ok := vg.shape_from_path(p, outline = true); ring_ok {
		ring := kept(r, ring_shape)
		locals: [24]vg.Transform2D
		for &l, k in locals {
			l = vg.transform_translation(196 + f32(k % 6) * 9.3, 120 + f32(k / 6) * 9.7)
		}
		vg.hairline_shapes(c, ring, vg.paint_color(vg.rgb(30, 30, 30)), 1, locals[:])
	}
}

// Markers (vg.fill_markers, vg.draw_markers): circles piled thick enough
// that most pixels see dozens, a gradient paint shading a batch once,
// translucent outlines only, and squares filled and outlined in one call,
// under a scale (the markers keep their pixel size).
scene_markers :: proc(c: ^vg.Canvas, r: ^Resources) {
	vg.clear_rect(c, 0, 0, W, H, vg.rgb(245, 243, 238))
	points: [400]vg.Vec2
	for &q, k in points {
		a := f32(k) * 2.399963
		d := 6 * math.sqrt(f32(k))
		q = {64 + d * math.cos(a) * 0.45, 96 + d * math.sin(a) * 0.6}
	}
	vg.fill_markers(c, .Circle, 4.5, 0, vg.paint_linear_gradient(20, 0, 110, 0, vg.rgb(30, 90, 220), vg.rgb(200, 40, 120)), points[:])
	vg.draw_markers(c, .Circle, 3, 1.25, nil, vg.paint_color(vg.rgba(0, 0, 0, 200)), points[:60])
	vg.save(c)
	vg.translate(c, 150, 30)
	vg.scale(c, 1.7, 1.7)
	squares: [24]vg.Vec2
	for &q, k in squares {
		q = {f32(k % 6) * 9.5, f32(k / 6) * 9.25}
	}
	vg.draw_markers(c, .Square, 3.5, 1.5, vg.paint_color(vg.rgb(255, 255, 255)), vg.paint_color(vg.rgb(20, 90, 230)), squares[:])
	vg.restore(c)
}
