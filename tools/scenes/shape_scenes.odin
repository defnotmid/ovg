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
		font := &r.fonts.fallback.font
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
