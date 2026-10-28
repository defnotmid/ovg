// Test scenes shared by the parity tools: each backend renders them and
// the results are compared with the software backend.
package scenes

import "core:fmt"
import "core:math"

import "../../svg"
import "../../lottie"
import vg "../.."
import image "deps:odecs/image"

W :: 256
H :: 192

Scene :: struct {
	name: string,
	draw: proc(c: ^vg.Canvas, r: ^Resources),
}

Resources :: struct {
	checker:  vg.Image_Id,
	// Vera, and a layout of text in it (`lay`).
	fonts:    vg.Font_Collection,
	layout:   vg.Text_Layout,
	scratch:  vg.Path,
	glyphs:   [dynamic]vg.Positioned_Glyph,
	path:     vg.Path,
	target:   vg.Image_Id,
	blurred:  vg.Image_Id,
	// Filter inputs and outputs: 32x32 tiles and 96x96 panels.
	tile_a:   vg.Image_Id,
	tile_b:   vg.Image_Id,
	tile_out: vg.Image_Id,
	panel:    vg.Image_Id,
	panel_out: vg.Image_Id,
	// The "program" scene: a custom program and its two outputs.
	program:  vg.Program_Id,
	prog_out: vg.Image_Id,
	prog_opaque: vg.Image_Id,
	// The layer scenes (layer_scenes.odin).
	layers:   vg.Layer_Stack,
	// The SVG scene (svg_scenes.odin), parsed on first use.
	svg_doc:   svg.Document,
	svg_r:     svg.Renderer,
	svg_text:  svg.Layout,
	svg_fonts: vg.Font_Collection,
	svg_ready: bool,
	// The emoji scene: Vera with the bundled colour emoji face.
	emoji_fonts:  vg.Font_Collection,
	emoji_layout: vg.Text_Layout,
	// The Lottie scene (lottie_scenes.odin), parsed on first use.
	lottie_doc:   lottie.Document,
	lottie_r:     lottie.Renderer,
	lottie_fx:    lottie.Renderer,
	lottie_ready: bool,
	// The Lottie text and effects scene.
	lottie_fx_doc:   lottie.Document,
	lottie_fx_ready: bool,
	// Shapes built for one frame, destroyed at the next `draw_frame`.
	frame_shapes:    [dynamic]^vg.Shape,
}

FONT_DATA :: #load("../../assets/Vera.ttf")

ALL := [?]Scene {
	{"shapes", scene_shapes},
	{"strokes", scene_strokes},
	{"concave", scene_concave},
	{"orientation", scene_orientation},
	{"gradients", scene_gradients},
	{"images", scene_images},
	{"scissor", scene_scissor},
	{"text", scene_text},
	{"composite", scene_composite},
	{"targets", scene_targets},
	{"filters", scene_filters},
	{"blend", scene_blend},
	{"composite_filter", scene_composite_filter},
	{"spread", scene_spread},
	{"paint_transform", scene_paint_transform},
	{"program", scene_program},
	{"layers", scene_layers},
	{"layer_masks", scene_layer_masks},
	{"layer_filters", scene_layer_filters},
	{"filters_more", scene_filters_more},
	{"filter_darks", scene_filter_darks},
	{"turbulence", scene_turbulence},
	{"layer_blend", scene_layer_blend},
	{"layer_groups", scene_layer_groups},
	{"backdrop_blur", scene_backdrop_blur},
	{"svg", scene_svg},
	{"lottie", scene_lottie},
	{"lottie_text_fx", scene_lottie_text_fx},
	{"emoji", scene_emoji},
	{"curves", scene_curves},
	{"curves_alpha", scene_curves_alpha},
	{"hairlines", scene_hairlines},
	{"markers", scene_markers},
	{"motion", scene_motion},
}

// Starts a frame at the scene size, cleared to transparent, and draws the
// scene. The caller flushes.
draw_frame :: proc(c: ^vg.Canvas, s: Scene, r: ^Resources) {
	for shape in r.frame_shapes {
		vg.shape_destroy(shape)
		free(shape)
	}
	clear(&r.frame_shapes)
	vg.set_size(c, W, H)
	vg.clear_rect(c, 0, 0, W, H, vg.TRANSPARENT)
	s.draw(c, r)
}

resources_destroy :: proc(c: ^vg.Canvas, r: ^Resources) {
	svg.renderer_destroy(&r.svg_r, c)
	svg.layout_destroy(&r.svg_text)
	svg.destroy(&r.svg_doc)
	lottie.renderer_destroy(&r.lottie_r, c)
	lottie.renderer_destroy(&r.lottie_fx, c)
	lottie.destroy(&r.lottie_doc)
	lottie.destroy(&r.lottie_fx_doc)
	vg.font_collection_destroy(&r.svg_fonts)
	vg.font_collection_destroy(&r.emoji_fonts)
	vg.text_layout_destroy(&r.emoji_layout)
	vg.layer_stack_destroy(&r.layers, c)
	vg.font_collection_destroy(&r.fonts)
	vg.text_layout_destroy(&r.layout)
	for shape in r.frame_shapes {
		vg.shape_destroy(shape)
		free(shape)
	}
	delete(r.frame_shapes)
	vg.path_destroy(&r.scratch)
	vg.path_destroy(&r.path)
	delete(r.glyphs)
}

setup :: proc(c: ^vg.Canvas, r: ^Resources) {
	// 8x8 checker with colored quadrants.
	pix: [8 * 8 * 4]u8
	for y in 0 ..< 8 {
		for x in 0 ..< 8 {
			i := (y * 8 + x) * 4
			on := (x + y) % 2 == 0
			pix[i + 0] = 230 if x < 4 else 40
			pix[i + 1] = 200 if on else 60
			pix[i + 2] = 230 if y >= 4 else 40
			pix[i + 3] = 255 if (x != 7 || y != 0) else 64
		}
	}
	r.checker, _ = vg.create_image(c, vg.image_source_rgba(pix[:], 8, 8))
	vg.font_collection_init(&r.fonts, FONT_DATA)
	vg.font_collection_init(&r.svg_fonts, FONT_DATA)
	vg.font_collection_init(&r.emoji_fonts, FONT_DATA)
	vg.font_collection_set_emoji(&r.emoji_fonts, vg.EMOJI_FONT_DATA)
	r.target, _ = vg.create_image_empty(c, 96, 96, .RGBA8, {.Premultiplied})
	r.blurred, _ = vg.create_image_empty(c, 96, 96, .RGBA8, {.Premultiplied})
	r.tile_a, _ = vg.create_image_empty(c, 32, 32, .RGBA8, {.Premultiplied})
	r.tile_b, _ = vg.create_image_empty(c, 32, 32, .RGBA8, {.Premultiplied})
	r.tile_out, _ = vg.create_image_empty(c, 32, 32, .RGBA8, {.Premultiplied})
	r.panel, _ = vg.create_image_empty(c, 80, 80, .RGBA8, {.Premultiplied})
	r.panel_out, _ = vg.create_image_empty(c, 80, 80, .RGBA8, {.Premultiplied})
	r.program, _ = vg.create_program(
		c,
		{
			frag_spirv = PROGRAM_FRAG_SPV,
			frag_msl = PROGRAM_FRAG_MSL,
			frag_msl_entry = "fs_main",
			vert_spirv = PROGRAM_VERT_SPV,
			vert_msl = PROGRAM_VERT_MSL,
			vert_msl_entry = "vs_main",
			uniform_size = size_of(Program_Params),
			num_samplers = 2,
			cpu = program_cpu,
		},
	)
	r.prog_out, _ = vg.create_image_empty(c, 100, 80, .RGBA8, {.Premultiplied})
	r.prog_opaque, _ = vg.create_image_empty(c, 100, 80, .RGBA8, {.Premultiplied})
}

scene_shapes :: proc(c: ^vg.Canvas, r: ^Resources) {
	p := &r.path
	vg.path_reset(p)
	vg.path_rect(p, 10, 10, 60, 40)
	vg.fill_path(c, p, vg.paint_color(vg.rgb(220, 60, 50)))
	vg.path_reset(p)
	vg.path_rounded_rect(p, 85, 12, 70, 50, 14)
	vg.fill_path(c, p, vg.paint_color(vg.rgba(40, 120, 220, 200)))
	vg.path_reset(p)
	vg.path_circle(p, 200, 45, 33)
	vg.fill_path(c, p, vg.paint_color(vg.rgb(30, 170, 90)))
	vg.path_reset(p)
	vg.path_ellipse(p, 60, 130, 45, 25)
	vg.path_rounded_rect_varying(p, 120, 95, 90, 70, 4, 20, 30, 0)
	vg.fill_path(c, p, vg.paint_color(vg.rgba(250, 180, 30, 180)))
	vg.save(c)
	vg.translate(c, 220, 150)
	vg.rotate(c, 0.5)
	vg.path_reset(p)
	vg.path_rect(p, -18, -18, 36, 36)
	vg.fill_path(c, p, vg.paint_color(vg.rgb(120, 40, 200)))
	vg.restore(c)
}

scene_strokes :: proc(c: ^vg.Canvas, r: ^Resources) {
	p := &r.path
	joins := [3]vg.Line_Join{.Miter, .Round, .Bevel}
	caps := [3]vg.Line_Cap{.Butt, .Round, .Square}
	for i in 0 ..< 3 {
		vg.path_reset(p)
		x := f32(20 + i * 80)
		vg.path_move_to(p, x, 70)
		vg.path_line_to(p, x + 25, 20)
		vg.path_line_to(p, x + 50, 70)
		sp := vg.paint_color(vg.rgb(20, 20, 30))
		sp.stroke.line_width = 10
		sp.stroke.line_join = joins[i]
		vg.paint_set_line_cap(&sp, caps[i])
		vg.stroke_path(c, p, sp)
	}
	vg.path_reset(p)
	vg.path_move_to(p, 20, 100)
	vg.path_bezier_to(p, 80, 60, 120, 190, 236, 110)
	sp := vg.paint_color(vg.rgba(200, 30, 90, 160))
	sp.stroke.line_width = 7
	vg.stroke_path(c, p, sp)
	// Self-overlapping translucent stroke (each pixel once).
	vg.path_reset(p)
	vg.path_move_to(p, 30, 130)
	vg.path_line_to(p, 110, 180)
	vg.path_line_to(p, 30, 180)
	vg.path_line_to(p, 110, 130)
	sp2 := vg.paint_color(vg.rgba(0, 90, 200, 140))
	sp2.stroke.line_width = 9
	vg.stroke_path(c, p, sp2)
	// Hairlines.
	for i in 0 ..< 6 {
		vg.path_reset(p)
		vg.path_move_to(p, 140, f32(130 + i * 9))
		vg.path_line_to(p, 240, f32(125 + i * 11))
		hp := vg.paint_color(vg.BLACK)
		hp.stroke.line_width = 0.4 + f32(i) * 0.3
		vg.stroke_path(c, p, hp)
	}
	vg.path_reset(p)
	vg.path_arc(p, 200, 60, 30, 0, math.PI * 1.5, .Hole)
	ap := vg.paint_color(vg.rgb(250, 120, 0))
	ap.stroke.line_width = 5
	vg.paint_set_line_cap(&ap, .Round)
	vg.stroke_path(c, p, ap)
}

scene_concave :: proc(c: ^vg.Canvas, r: ^Resources) {
	p := &r.path
	star :: proc(p: ^vg.Path, cx, cy, r0, r1: f32) {
		for i in 0 ..< 10 {
			a := f32(i) * math.PI / 5 - math.PI / 2
			rr := r0 if i % 2 == 0 else r1
			if i == 0 {
				vg.path_move_to(p, cx + math.cos(a) * rr, cy + math.sin(a) * rr)
			} else {
				vg.path_line_to(p, cx + math.cos(a) * rr, cy + math.sin(a) * rr)
			}
		}
		vg.path_close(p)
	}
	vg.path_reset(p)
	star(p, 64, 64, 55, 22)
	vg.fill_path(c, p, vg.paint_color(vg.rgb(240, 200, 20)))
	// Pentagram: even-odd leaves the center empty.
	vg.path_reset(p)
	for i in 0 ..< 5 {
		a := f32(i * 2) * math.TAU / 5 - math.PI / 2
		if i == 0 {
			vg.path_move_to(p, 190 + math.cos(a) * 55, 64 + math.sin(a) * 55)
		} else {
			vg.path_line_to(p, 190 + math.cos(a) * 55, 64 + math.sin(a) * 55)
		}
	}
	vg.path_close(p)
	eo := vg.paint_color(vg.rgba(200, 40, 40, 220))
	eo.fill_rule = .Even_Odd
	vg.fill_path(c, p, eo)
	// Ring with a hole.
	vg.path_reset(p)
	vg.path_circle(p, 70, 150, 36)
	vg.path_circle(p, 70, 150, 18)
	vg.path_solidity(p, .Hole)
	vg.fill_path(c, p, vg.paint_color(vg.rgb(40, 150, 210)))
	// Wavy closed curve.
	vg.path_reset(p)
	vg.path_move_to(p, 140, 120)
	vg.path_bezier_to(p, 180, 90, 200, 190, 240, 130)
	vg.path_bezier_to(p, 250, 180, 160, 200, 150, 170)
	vg.path_quad_to(p, 120, 150, 140, 120)
	vg.fill_path(c, p, vg.paint_color(vg.rgba(60, 180, 90, 200)))
}

// Clockwise and counter-clockwise contours cover the same pixels: squares,
// donuts with holes wound both ways, and an off-grid clockwise curve.
scene_orientation :: proc(c: ^vg.Canvas, r: ^Resources) {
	p := &r.path
	square :: proc(p: ^vg.Path, x0, y0, x1, y1: f32, clockwise: bool) {
		vg.path_move_to(p, x0, y0)
		if clockwise {
			vg.path_line_to(p, x1, y0)
			vg.path_line_to(p, x1, y1)
			vg.path_line_to(p, x0, y1)
		} else {
			vg.path_line_to(p, x0, y1)
			vg.path_line_to(p, x1, y1)
			vg.path_line_to(p, x1, y0)
		}
		vg.path_close(p)
	}
	for cw, i in ([2]bool{true, false}) {
		x := f32(i) * 64
		vg.path_reset(p)
		square(p, 8 + x, 8, 56 + x, 56, cw)
		vg.fill_path(c, p, vg.paint_color(vg.rgb(30, 90, 200)))
		vg.path_reset(p)
		square(p, 8.5 + x, 72.25, 55.5 + x, 119.75, cw)
		vg.fill_path(c, p, vg.paint_color(vg.rgba(200, 60, 40, 200)))
		// Donut, hole wound against the outer contour.
		vg.path_reset(p)
		square(p, 136 + x, 8, 184 + x, 56, cw)
		square(p, 150 + x, 22, 170 + x, 42, !cw)
		vg.fill_path(c, p, vg.paint_color(vg.rgb(40, 160, 80)))
		// Donut, same winding, even-odd.
		vg.path_reset(p)
		square(p, 136 + x, 72, 184 + x, 120, cw)
		square(p, 150 + x, 86, 170 + x, 106, cw)
		eo := vg.paint_color(vg.rgb(120, 40, 160))
		eo.fill_rule = .Even_Odd
		vg.fill_path(c, p, eo)
		// Off-grid curve.
		vg.path_reset(p)
		vg.path_move_to(p, 10.3 + x, 140.6)
		if cw {
			vg.path_bezier_to(p, 40 + x, 120, 60 + x, 160, 50.7 + x, 185.2)
			vg.path_line_to(p, 14.1 + x, 180.4)
		} else {
			vg.path_line_to(p, 14.1 + x, 180.4)
			vg.path_line_to(p, 50.7 + x, 185.2)
			vg.path_bezier_to(p, 60 + x, 160, 40 + x, 120, 10.3 + x, 140.6)
		}
		vg.path_close(p)
		vg.fill_path(c, p, vg.paint_color(vg.rgb(220, 160, 20)))
	}
}

scene_gradients :: proc(c: ^vg.Canvas, r: ^Resources) {
	p := &r.path
	vg.path_reset(p)
	vg.path_rect(p, 8, 8, 112, 80)
	vg.fill_path(c, p, vg.paint_linear_gradient(8, 8, 120, 88, vg.rgb(255, 80, 0), vg.rgba(0, 60, 255, 128)))
	vg.path_reset(p)
	vg.path_rect(p, 136, 8, 112, 80)
	vg.fill_path(c, p, vg.paint_radial_gradient(192, 48, 6, 40, vg.WHITE, vg.rgb(120, 0, 160)))
	vg.path_reset(p)
	vg.path_rect(p, 8, 100, 112, 84)
	vg.fill_path(c, p, vg.paint_box_gradient(24, 116, 80, 52, 10, 14, vg.rgb(20, 20, 20), vg.rgb(240, 240, 200)))
	stops := [?]vg.Gradient_Stop{{0, vg.rgb(255, 0, 0)}, {0.3, vg.rgb(255, 255, 0)}, {0.6, vg.rgba(0, 255, 0, 128)}, {1, vg.rgb(0, 0, 255)}}
	vg.path_reset(p)
	vg.path_rect(p, 136, 100, 112, 40)
	vg.fill_path(c, p, vg.paint_linear_gradient_stops(136, 0, 248, 0, stops[:]))
	vg.path_reset(p)
	vg.path_circle(p, 166, 164, 22)
	vg.fill_path(c, p, vg.paint_conic_gradient_stops(166, 164, stops[:]))
	vg.path_reset(p)
	vg.path_circle(p, 222, 164, 22)
	two := [?]vg.Gradient_Stop{{0, vg.rgb(0, 200, 200)}, {1, vg.rgb(200, 0, 100)}}
	vg.fill_path(c, p, vg.paint_conic_gradient_stops(222, 164, two[:]))
}

scene_images :: proc(c: ^vg.Canvas, r: ^Resources) {
	p := &r.path
	vg.path_reset(p)
	vg.path_rect(p, 8, 8, 96, 96)
	vg.fill_path(c, p, vg.paint_image(r.checker, 8, 8, 96, 96, 0))
	vg.save(c)
	vg.translate(c, 180, 60)
	vg.rotate(c, 0.35)
	vg.path_reset(p)
	vg.path_rounded_rect(p, -50, -40, 100, 80, 12)
	vg.fill_path(c, p, vg.paint_image(r.checker, -50, -40, 100, 80, 0, 0.8))
	vg.restore(c)
	vg.path_reset(p)
	vg.path_circle(p, 70, 150, 36)
	vg.fill_path(c, p, vg.paint_image_tint(r.checker, 30, 110, 24, 24, 0.2, vg.rgba(255, 200, 200, 220)))
}

scene_scissor :: proc(c: ^vg.Canvas, r: ^Resources) {
	p := &r.path
	vg.scissor(c, 20, 20, 100, 60)
	vg.path_reset(p)
	vg.path_circle(p, 70, 50, 50)
	vg.fill_path(c, p, vg.paint_color(vg.rgb(200, 50, 50)))
	vg.intersect_scissor(c, 60, 30, 100, 100)
	vg.path_reset(p)
	vg.path_rect(p, 0, 0, W, H)
	vg.fill_path(c, p, vg.paint_color(vg.rgba(0, 0, 0, 100)))
	vg.reset_scissor(c)
	vg.save(c)
	vg.translate(c, 190, 130)
	vg.rotate(c, 0.6)
	vg.scissor(c, -40, -30, 80, 60)
	vg.reset_transform(c)
	vg.path_reset(p)
	vg.path_rect(p, 120, 60, 136, 132)
	vg.fill_path(c, p, vg.paint_linear_gradient(120, 60, 256, 192, vg.rgb(0, 150, 255), vg.rgb(255, 0, 150)))
	vg.restore(c)
}

// Lays out `s` in Vera at `size` from (x, y) into `r.layout`: its one
// run's font, glyphs and font units to pixels.
lay :: proc(r: ^Resources, s: string, x, y, size: f32) -> (font: ^vg.Font, glyphs: []vg.Positioned_Glyph, em: f32) {
	vg.text_layout(&r.fonts, {{text = s, style = {size = size}}}, {x = x, y = y}, &r.layout)
	run := r.layout.runs[0]
	return vg.text_layout_font(&r.layout, run), r.layout.glyphs[run.first:][:run.count], run.em
}

scene_text :: proc(c: ^vg.Canvas, r: ^Resources) {
	f, g, em := lay(r, "Vector text!", 10, 40, 28)
	vg.fill_glyph_outlines(c, f, g, em, vg.paint_color(vg.rgb(20, 20, 40)), &r.scratch)
	vg.save(c)
	vg.translate(c, 20, 80)
	vg.rotate(c, 0.15)
	f, g, em = lay(r, "Rotated", 0, 30, 28)
	gp := vg.paint_linear_gradient(0, 0, 150, 0, vg.rgb(255, 60, 0), vg.rgb(120, 0, 255))
	vg.fill_glyph_outlines(c, f, g, em, gp, &r.scratch)
	vg.restore(c)
	f, g, em = lay(r, "Small glyphs 0123", 10, 170, 16)
	vg.fill_glyph_outlines(c, f, g, em, vg.paint_color(vg.rgb(0, 100, 50)), &r.scratch)
	f, g, em = lay(r, "Outline", 150, 130, 28)
	op := vg.paint_color(vg.rgb(200, 0, 0))
	op.stroke.line_width = 1
	vg.stroke_glyph_outlines(c, f, g, em, op, &r.scratch)
}

// COLRv1 colour glyphs (layers, gradients, transforms) among plain text.
scene_emoji :: proc(c: ^vg.Canvas, r: ^Resources) {
	text :: proc(c: ^vg.Canvas, r: ^Resources, s: string, size, x, y: f32, paint: vg.Paint) {
		l := &r.emoji_layout
		vg.text_layout(&r.emoji_fonts, {{text = s, style = {size = size}}}, {x = x, y = y}, l)
		for run in l.runs {
			vg.fill_glyph_outlines(c, vg.text_layout_font(l, run), l.glyphs[run.first:][:run.count], run.em, paint, &r.scratch)
		}
	}
	text(c, r, "Hi 👋🔥😂 👩‍💻🇯🇵", 26, 8, 34, vg.paint_color(vg.rgb(20, 20, 40)))
	vg.save(c)
	vg.translate(c, 60, 120)
	vg.rotate(c, -0.2)
	text(c, r, "🎉", 96, -48, 36, vg.paint_color(vg.BLACK))
	vg.restore(c)
	text(c, r, "❤️🌈", 56, 130, 150, vg.paint_color(vg.rgba(0, 0, 0, 160)))
}

scene_composite :: proc(c: ^vg.Canvas, r: ^Resources) {
	p := &r.path
	ops := [?]vg.Composite_Operation{.Source_Over, .Source_In, .Destination_Over, .Destination_Out, .Lighter, .Xor, .Atop, .Copy}
	for op, i in ops {
		x := f32(i % 4) * 62 + 6
		y := f32(i / 4) * 92 + 6
		vg.set_composite_operation(c, .Source_Over)
		vg.path_reset(p)
		vg.path_rect(p, x, y, 36, 36)
		vg.fill_path(c, p, vg.paint_color(vg.rgba(30, 90, 220, 220)))
		vg.set_composite_operation(c, op)
		vg.path_reset(p)
		vg.path_circle(p, x + 36, y + 36, 20)
		vg.fill_path(c, p, vg.paint_color(vg.rgba(230, 60, 40, 180)))
	}
	vg.set_composite_operation(c, .Source_Over)
	vg.set_global_alpha(c, 0.5)
	vg.path_reset(p)
	vg.path_rect(p, 0, 80, W, 12)
	vg.fill_path(c, p, vg.paint_color(vg.BLACK))
	vg.set_global_alpha(c, 1)
}

scene_targets :: proc(c: ^vg.Canvas, r: ^Resources) {
	p := &r.path
	vg.set_render_target(c, r.target)
	vg.clear_rect(c, 0, 0, 96, 96, vg.TRANSPARENT)
	vg.path_reset(p)
	vg.path_circle(p, 48, 40, 26)
	vg.fill_path(c, p, vg.paint_color(vg.rgb(250, 200, 0)))
	vg.path_reset(p)
	vg.path_rect(p, 10, 70, 76, 14)
	vg.fill_path(c, p, vg.paint_color(vg.rgb(200, 30, 60)))
	vg.set_render_target(c, nil)
	vg.filter_image(c, r.blurred, vg.Gaussian_Blur{3}, r.target)
	vg.path_reset(p)
	vg.path_rect(p, 16, 40, 96, 96)
	vg.fill_path(c, p, vg.paint_image(r.target, 16, 40, 96, 96, 0))
	vg.path_reset(p)
	vg.path_rect(p, 140, 40, 96, 96)
	vg.fill_path(c, p, vg.paint_image(r.blurred, 140, 40, 96, 96, 0))
}

// Pixel difference between two RGBA8 images of the same size.
// Draws `img` (w x h) at (x, y) on the current target.
@(private = "file")
show :: proc(c: ^vg.Canvas, r: ^Resources, img: vg.Image_Id, x, y, w, h: f32) {
	p := &r.path
	vg.path_reset(p)
	vg.path_rect(p, x, y, w, h)
	ip := vg.paint_image(img, x, y, w, h, 0)
	ip.anti_alias = false
	vg.fill_path(c, p, ip)
}

// A panel with shapes in saturated colors, partly transparent.
@(private = "file")
draw_panel :: proc(c: ^vg.Canvas, r: ^Resources) {
	vg.set_render_target(c, r.panel)
	vg.clear_rect(c, 0, 0, 80, 80, vg.TRANSPARENT)
	p := &r.path
	vg.path_reset(p)
	vg.path_rect(p, 10, 10, 40, 40)
	vg.fill_path(c, p, vg.paint_color(vg.rgb(230, 60, 40)))
	vg.path_reset(p)
	vg.path_circle(p, 50, 50, 22)
	vg.fill_path(c, p, vg.paint_color(vg.rgba(40, 140, 230, 200)))
	vg.path_reset(p)
	vg.path_rect(p, 0, 66, 80, 14)
	vg.fill_path(c, p, vg.paint_linear_gradient(0, 0, 80, 0, vg.rgb(250, 220, 40), vg.rgba(40, 200, 90, 128)))
	vg.set_render_target(c, nil)
}

scene_filters :: proc(c: ^vg.Canvas, r: ^Resources) {
	draw_panel(c, r)
	filters := [6]vg.Image_Filter {
		vg.Gaussian_Blur{3},
		vg.Blur_XY{6, 0, .Transparent},
		vg.Blur_XY{1.5, 4, .Clamp},
		vg.color_matrix_saturate(0.2),
		vg.color_matrix_hue_rotate(120),
		vg.color_matrix_luminance_to_alpha(),
	}
	for f, i in filters {
		vg.filter_image(c, r.panel_out, f, r.panel)
		show(c, r, r.panel_out, f32(i % 3) * 85, f32(i / 3) * 85, 80, 80)
	}
	vg.filter_image(c, r.panel_out, vg.Color_Space_Convert{true}, r.panel)
	show(c, r, r.panel_out, 0, 170, 80, 20)
	vg.filter_image(c, r.panel_out, vg.Color_Space_Convert{false}, r.panel)
	show(c, r, r.panel_out, 85, 170, 80, 20)
	m := vg.COLOR_MATRIX_IDENTITY
	m.m = {0.2, 0.5, 0.3, 0, 0.1, 0, 1, 0, 0, 0, 0.6, 0.2, 0.1, 0, 0, 0, 0, 0, 0.7, 0.05}
	vg.filter_image(c, r.panel_out, m, r.panel)
	show(c, r, r.panel_out, 170, 170, 80, 20)
}

// Backdrop tile (gradient with a translucent band) and source tile (shapes
// over transparency).
@(private = "file")
draw_tiles :: proc(c: ^vg.Canvas, r: ^Resources) {
	p := &r.path
	vg.set_render_target(c, r.tile_b)
	vg.clear_rect(c, 0, 0, 32, 32, vg.TRANSPARENT)
	vg.path_reset(p)
	vg.path_rect(p, 0, 0, 32, 32)
	vg.fill_path(c, p, vg.paint_linear_gradient(0, 0, 32, 32, vg.rgb(30, 90, 220), vg.rgb(240, 200, 60)))
	vg.path_reset(p)
	vg.path_rect(p, 0, 24, 32, 8)
	vg.fill_path(c, p, vg.paint_color(vg.rgba(255, 255, 255, 100)))
	vg.set_render_target(c, r.tile_a)
	vg.clear_rect(c, 0, 0, 32, 32, vg.TRANSPARENT)
	vg.path_reset(p)
	vg.path_circle(p, 16, 14, 12)
	vg.fill_path(c, p, vg.paint_color(vg.rgba(230, 50, 120, 230)))
	vg.path_reset(p)
	vg.path_rect(p, 4, 20, 24, 10)
	vg.fill_path(c, p, vg.paint_color(vg.rgba(60, 220, 180, 160)))
	vg.set_render_target(c, nil)
}

scene_blend :: proc(c: ^vg.Canvas, r: ^Resources) {
	draw_tiles(c, r)
	for mode, i in vg.Blend_Mode {
		_ = i
		k := int(mode)
		vg.filter_image(c, r.tile_out, vg.Blend{mode, r.tile_b}, r.tile_a)
		show(c, r, r.tile_out, f32(k % 8) * 32, f32(k / 8) * 40, 32, 32)
	}
	// In place: the backdrop is also the target.
	vg.filter_image(c, r.tile_b, vg.Blend{.Multiply, r.tile_b}, r.tile_a)
	show(c, r, r.tile_b, 0, 100, 64, 64)
}

scene_composite_filter :: proc(c: ^vg.Canvas, r: ^Resources) {
	draw_tiles(c, r)
	ops := [8]vg.Composite {
		{.Over, {}, r.tile_b},
		{.In, {}, r.tile_b},
		{.Out, {}, r.tile_b},
		{.Atop, {}, r.tile_b},
		{.Xor, {}, r.tile_b},
		{.Lighter, {}, r.tile_b},
		{.Arithmetic, {0.5, 0.5, 0.5, 0}, r.tile_b},
		{.Arithmetic, {1, 0.2, -0.3, 0.1}, r.tile_b},
	}
	for op, i in ops {
		vg.filter_image(c, r.tile_out, op, r.tile_a)
		show(c, r, r.tile_out, f32(i % 4) * 64, f32(i / 4) * 64, 64, 64)
	}
}

scene_spread :: proc(c: ^vg.Canvas, r: ^Resources) {
	p := &r.path
	stops := [?]vg.Gradient_Stop{{0, vg.rgb(250, 60, 30)}, {0.4, vg.rgb(250, 220, 40)}, {1, vg.rgba(30, 90, 230, 160)}}
	for spread, i in vg.Gradient_Spread {
		y := f32(i) * 62
		two := vg.paint_linear_gradient(20, 0, 60, 0, vg.rgb(20, 20, 40), vg.rgb(90, 220, 250))
		two.spread = spread
		vg.path_reset(p)
		vg.path_rect(p, 0, y, 128, 28)
		vg.fill_path(c, p, two)
		multi := vg.paint_linear_gradient_stops(20, 0, 60, 0, stops[:])
		multi.spread = spread
		vg.path_reset(p)
		vg.path_rect(p, 0, y + 30, 128, 28)
		vg.fill_path(c, p, multi)
		radial := vg.paint_radial_gradient(192, y + 29, 4, 16, vg.rgb(250, 250, 250), vg.rgb(120, 40, 200))
		radial.spread = spread
		vg.path_reset(p)
		vg.path_rect(p, 132, y, 124, 58)
		vg.fill_path(c, p, radial)
	}
}

scene_paint_transform :: proc(c: ^vg.Canvas, r: ^Resources) {
	p := &r.path
	// objectBoundingBox: a 0..1 gradient mapped onto the rect.
	g := vg.paint_linear_gradient(0, 0, 1, 1, vg.rgb(250, 80, 40), vg.rgb(40, 80, 250))
	g.transform = vg.Transform2D{110, 0, 0, 80, 10, 10}
	vg.path_reset(p)
	vg.path_rect(p, 10, 10, 110, 80)
	vg.fill_path(c, p, g)
	// gradientTransform: rotated and skewed, with repeat.
	g2 := vg.paint_linear_gradient(0, 0, 20, 0, vg.rgb(250, 230, 60), vg.rgb(30, 160, 90))
	g2.spread = .Reflect
	g2.transform = vg.transform_multiply(vg.transform_skew_x(0.4), vg.transform_rotation(0.6))
	vg.path_reset(p)
	vg.path_rect(p, 136, 10, 110, 80)
	vg.fill_path(c, p, g2)
	// An elliptical radial gradient (non-uniform scale), under a canvas
	// rotation that the paint transform composes with.
	vg.save(c)
	vg.translate(c, 64, 140)
	vg.rotate(c, 0.3)
	rg := vg.paint_radial_gradient(0, 0, 0, 1, vg.rgb(255, 255, 255), vg.rgba(200, 30, 90, 0))
	rg.transform = vg.transform_scaling(50, 25)
	vg.path_reset(p)
	vg.path_rect(p, -60, -40, 120, 80)
	vg.fill_path(c, p, rg)
	vg.restore(c)
	// Image paint with a paint transform (scaled and rotated checker).
	ip := vg.paint_image(r.checker, 0, 0, 8, 8, 0)
	ip.transform = vg.transform_multiply(vg.transform_rotation(0.3), vg.transform_scaling(5, 5))
	ip.transform[4] += 150
	ip.transform[5] += 105
	vg.path_reset(p)
	vg.path_rect(p, 140, 100, 100, 85)
	vg.fill_path(c, p, ip)
}

Diff :: struct {
	max:    int,
	mean:   f64,
	// Pixels whose largest channel difference exceeds 2 and 16.
	over2:  int,
	over16: int,
	// Grayscale visualization (difference x 8).
	image:  []u8,
}

compare :: proc(a, b: []u8, allocator := context.allocator) -> (d: Diff) {
	d.image = make([]u8, len(a), allocator)
	sum := 0
	for i := 0; i < len(a); i += 4 {
		pd := 0
		for k in 0 ..< 4 {
			v := abs(int(a[i + k]) - int(b[i + k]))
			pd = max(pd, v)
			sum += v
		}
		d.max = max(d.max, pd)
		if pd > 2 {
			d.over2 += 1
		}
		if pd > 16 {
			d.over16 += 1
		}
		v := u8(min(pd * 8, 255))
		d.image[i], d.image[i + 1], d.image[i + 2], d.image[i + 3] = v, v, v, 255
	}
	d.mean = f64(sum) / f64(len(a))
	return
}

// A few edge pixels may differ (rounding at exact edge hits), but the
// images must agree almost everywhere.
diff_ok :: proc(d: Diff) -> bool {
	return d.over16 <= (W * H) / 500 && d.mean < 0.5
}

// Prints one result line and writes `<name>_<a>.png`, `<name>_<b>.png` and
// `<name>_diff.png` into `out_dir`.
report :: proc(out_dir, name, a_tag, b_tag: string, a, b: []u8, d: Diff) -> bool {
	ok := diff_ok(d)
	fmt.printfln(
		"%-10s max diff %d, mean %.3f, pixels >2: %d, >16: %d  %s",
		name,
		d.max,
		d.mean,
		d.over2,
		d.over16,
		"ok" if ok else "MISMATCH",
	)
	image.write_png(fmt.tprintf("%s/%s_%s.png", out_dir, name, a_tag), a, W, H)
	image.write_png(fmt.tprintf("%s/%s_%s.png", out_dir, name, b_tag), b, W, H)
	image.write_png(fmt.tprintf("%s/%s_diff.png", out_dir, name), d.image, W, H)
	return ok
}

// ---- custom program ---------------------------------------------------------------

PROGRAM_VERT_SPV :: #load("program.vert.spv")
PROGRAM_FRAG_SPV :: #load("program.frag.spv")
PROGRAM_VERT_MSL :: #load("program.vert.msl")
PROGRAM_FRAG_MSL :: #load("program.frag.msl")

// program.slang's uniform block.
Program_Params :: struct {
	color_a: [4]f32,
	color_b: [4]f32,
	// Ring radius, ring width, texture scale.
	shape:   [4]f32,
}

// program.slang's fs_main on the CPU.
program_cpu :: proc(user: rawptr, uniforms: []u8, width, height: int, out: []u8, stride: int, format: vg.Pixel_Format, sampler: vg.Program_Sampler) {
	p: Program_Params
	copy(([^]u8)(&p)[:size_of(p)], uniforms)
	unorm :: proc(v: f32) -> u8 {
		return u8(clamp(v * 255 + 0.5, 0, 255))
	}
	for y in 0 ..< height {
		for x in 0 ..< width {
			uv := [2]f32{(f32(x) + 0.5) / f32(width), (f32(y) + 0.5) / f32(height)}
			tex := sampler.sample(sampler.data, 0, uv * p.shape.z, 0)
			none := sampler.sample(sampler.data, 1, uv, 0)
			d := math.sqrt((uv.x - 0.5) * (uv.x - 0.5) + (uv.y - 0.5) * (uv.y - 0.5))
			ring := clamp(1 - abs(d - p.shape.x) / p.shape.y, 0, 1)
			grad := p.color_a + (p.color_b - p.color_a) * uv.x
			a := ring * grad.a
			k := tex.a * (1 - a) * 0.5
			o := [4]f32{grad.r * a + tex.r * k, grad.g * a + tex.g * k, grad.b * a + tex.b * k, a + k} + none
			px := out[y * stride + x * 4:]
			px[0], px[1], px[2], px[3] = unorm(o[0]), unorm(o[1]), unorm(o[2]), unorm(o[3])
		}
	}
}

scene_program :: proc(c: ^vg.Canvas, r: ^Resources) {
	a := Program_Params{{1, 0.3, 0.1, 1}, {0.1, 0.4, 1, 0.8}, {0.3, 0.12, 1.5, 0}}
	vg.run_program(c, r.program, r.prog_out, ([^]u8)(&a)[:size_of(a)], {r.checker})
	b := Program_Params{{0.9, 0.9, 0.2, 1}, {0.2, 0.9, 0.5, 1}, {0.2, 0.2, 0.75, 0}}
	vg.run_program(c, r.program, r.prog_opaque, ([^]u8)(&b)[:size_of(b)], {r.checker}, {.Opaque})
	show(c, r, r.prog_out, 12, 20, 100, 80)
	show(c, r, r.prog_opaque, 140, 20, 100, 80)
	// Scaled and rotated like any image.
	vg.save(c)
	vg.translate(c, 128, 140)
	vg.rotate(c, -0.2)
	p := &r.path
	vg.path_reset(p)
	vg.path_rounded_rect(p, -75, -30, 150, 60, 10)
	vg.fill_path(c, p, vg.paint_image(r.prog_out, -75, -30, 150, 60, 0, 0.9))
	vg.restore(c)
}
