package ovg

import "core:math"

Gradient_Stop :: struct {
	offset: f32,
	color:  Color,
}

Two_Stop_Gradient :: struct {
	start_color, end_color: Color,
}

// `stops` is borrowed: it only has to stay alive for the draw call that uses
// the paint (the ramp texture is synthesized during the call). `tint`
// multiplies every stop's alpha.
Multi_Stop_Gradient :: struct {
	stops: []Gradient_Stop,
	tint:  f32,
}

Gradient_Colors :: union {
	Two_Stop_Gradient,
	Multi_Stop_Gradient,
}

// Two stops at the ends with one alpha collapse to a two-stop gradient (no
// ramp texture). Colors interpolate in straight alpha, as in SVG.
gradient_colors_from_stops :: proc "contextless" (stops: []Gradient_Stop) -> Gradient_Colors {
	switch {
	case len(stops) == 0:
		return Two_Stop_Gradient{BLACK, BLACK}
	case len(stops) == 1:
		return Two_Stop_Gradient{stops[0].color, stops[0].color}
	case len(stops) == 2 && stops[0].offset <= 0 && stops[1].offset >= 1 && stops[0].color.a == stops[1].color.a:
		// Equal alphas: the shader's premultiplied interpolation is the
		// straight one SVG asks for (the ramp texture handles the rest).
		return Two_Stop_Gradient{stops[0].color, stops[1].color}
	}
	return Multi_Stop_Gradient{stops, 1}
}

@(private)
gradient_colors_mul_alpha :: proc "contextless" (gc: ^Gradient_Colors, a: f32) {
	switch &g in gc {
	case Two_Stop_Gradient:
		g.start_color.a *= a
		g.end_color.a *= a
	case Multi_Stop_Gradient:
		g.tint *= a
	}
}

Paint_Color :: Color

// Image paint: the image spans `width x height` with its top-left at
// `(x, y)`, rotated by `angle` around that corner.
Paint_Image :: struct {
	id:            Image_Id,
	x, y:          f32,
	width, height: f32,
	angle:         f32,
	tint:          Color,
}

Paint_Linear_Gradient :: struct {
	start, end: Vec2,
	colors:     Gradient_Colors,
}

Paint_Box_Gradient :: struct {
	pos:           Vec2,
	width, height: f32,
	radius:        f32,
	feather:       f32,
	colors:        Gradient_Colors,
}

// The gradient runs from `in_radius` to `out_radius` around `center`. With
// a `focal` offset (SVG fx / fy relative to cx / cy) it is a two-point
// conical gradient from the focal circle (`center + focal`, `in_radius`)
// to the outer circle (SVG fr / r).
Paint_Radial_Gradient :: struct {
	center:     Vec2,
	in_radius:  f32,
	out_radius: f32,
	colors:     Gradient_Colors,
	focal:      Vec2,
}

// Sweeps clockwise from 12 o'clock.
Paint_Conic_Gradient :: struct {
	center: Vec2,
	colors: Gradient_Colors,
}

Paint_Flavor :: union {
	Paint_Color,
	Paint_Image,
	Paint_Linear_Gradient,
	Paint_Box_Gradient,
	Paint_Radial_Gradient,
	Paint_Conic_Gradient,
}

Stroke_Settings :: struct {
	// Paint each pixel of a self-overlapping stroke once.
	stencil_strokes: bool,
	miter_limit:     f32,
	line_width:      f32,
	line_cap_start:  Line_Cap,
	line_cap_end:    Line_Cap,
	line_join:       Line_Join,
	// Dash pattern (on, off, ...) in path units and where it starts; empty
	// is solid (SVG stroke-dasharray / stroke-dashoffset).
	dash:            []f32,
	dash_offset:     f32,
	// When > 0, dash lengths and offset are fractions of this length (SVG
	// pathLength): `path_length = 1`, dash {1, 1}, offset 1 -> 0 draws on.
	path_length:     f32,
}

DEFAULT_STROKE :: Stroke_Settings {
	stencil_strokes = true,
	miter_limit     = 10,
	line_width      = 1,
}

// What linear, radial and box gradients do beyond their ends (SVG
// spreadMethod).
Gradient_Spread :: enum u8 {
	Pad,
	Reflect,
	Repeat,
}

// Per-draw styling. Plain value: copy and modify fields freely.
Paint :: struct {
	flavor:     Paint_Flavor,
	anti_alias: bool,
	// Fills only: edges as soft as a Gaussian blur of this standard
	// deviation (drawing units) would make them. The antialias fringe is
	// widened and eased (smoothstep) to match the blurred edge's slope
	// (1.5 sigma sqrt(2 pi)), so a blurred shape is one draw instead of a
	// blurred layer.
	feather:    f32,
	stroke:     Stroke_Settings,
	fill_rule:  Fill_Rule,
	spread:     Gradient_Spread,
	// Maps paint space to the canvas's current space, applied before the
	// canvas transform (SVG gradientTransform / patternTransform, or
	// objectBoundingBox units). The zero value is the identity.
	transform:  Transform2D,
}

// The transform a paint is evaluated with: its own, then `canvas`.
paint_space :: proc "contextless" (p: Paint, canvas: Transform2D) -> Transform2D {
	if p.transform == {} {
		return canvas
	}
	return transform_multiply(p.transform, canvas)
}

paint_from_flavor :: proc "contextless" (flavor: Paint_Flavor) -> Paint {
	return {flavor = flavor, anti_alias = true, stroke = DEFAULT_STROKE}
}

paint_color :: proc "contextless" (c: Color) -> Paint {
	return paint_from_flavor(c)
}

paint_image :: proc "contextless" (id: Image_Id, x, y, width, height, angle: f32, alpha: f32 = 1) -> Paint {
	return paint_from_flavor(Paint_Image{id, x, y, width, height, angle, {1, 1, 1, alpha}})
}

paint_image_tint :: proc "contextless" (id: Image_Id, x, y, width, height, angle: f32, tint: Color) -> Paint {
	return paint_from_flavor(Paint_Image{id, x, y, width, height, angle, tint})
}

paint_linear_gradient :: proc "contextless" (sx, sy, ex, ey: f32, start_color, end_color: Color) -> Paint {
	return paint_from_flavor(Paint_Linear_Gradient{{sx, sy}, {ex, ey}, Two_Stop_Gradient{start_color, end_color}})
}

paint_linear_gradient_stops :: proc "contextless" (sx, sy, ex, ey: f32, stops: []Gradient_Stop) -> Paint {
	return paint_from_flavor(Paint_Linear_Gradient{{sx, sy}, {ex, ey}, gradient_colors_from_stops(stops)})
}

paint_box_gradient :: proc "contextless" (x, y, w, h, radius, feather: f32, inner, outer: Color) -> Paint {
	return paint_from_flavor(Paint_Box_Gradient{{x, y}, w, h, radius, feather, Two_Stop_Gradient{inner, outer}})
}

paint_radial_gradient :: proc "contextless" (cx, cy, in_radius, out_radius: f32, inner, outer: Color) -> Paint {
	return paint_from_flavor(Paint_Radial_Gradient{center = {cx, cy}, in_radius = in_radius, out_radius = out_radius, colors = Two_Stop_Gradient{inner, outer}})
}

paint_radial_gradient_stops :: proc "contextless" (cx, cy, in_radius, out_radius: f32, stops: []Gradient_Stop) -> Paint {
	return paint_from_flavor(Paint_Radial_Gradient{center = {cx, cy}, in_radius = in_radius, out_radius = out_radius, colors = gradient_colors_from_stops(stops)})
}

// An SVG radial gradient: outer circle (cx, cy, r), focal circle (fx, fy,
// fr). A focal point outside the outer circle moves onto its edge (SVG
// 1.1 / resvg).
paint_radial_gradient_focal_stops :: proc "contextless" (cx, cy, r, fx, fy, fr: f32, stops: []Gradient_Stop) -> Paint {
	f := Vec2{fx - cx, fy - cy}
	if d := math.hypot(f.x, f.y); d > r * 0.999 && d > 0 {
		f *= r * 0.999 / d
	}
	return paint_from_flavor(Paint_Radial_Gradient{center = {cx, cy}, in_radius = fr, out_radius = r, colors = gradient_colors_from_stops(stops), focal = f})
}

paint_conic_gradient_stops :: proc "contextless" (cx, cy: f32, stops: []Gradient_Stop) -> Paint {
	return paint_from_flavor(Paint_Conic_Gradient{{cx, cy}, gradient_colors_from_stops(stops)})
}

paint_set_line_cap :: proc "contextless" (p: ^Paint, cap: Line_Cap) {
	p.stroke.line_cap_start = cap
	p.stroke.line_cap_end = cap
}

@(private)
flavor_mul_alpha :: proc "contextless" (f: ^Paint_Flavor, a: f32) {
	switch &v in f {
	case Paint_Color:
		v.a *= a
	case Paint_Image:
		v.tint.a *= a
	case Paint_Linear_Gradient:
		gradient_colors_mul_alpha(&v.colors, a)
	case Paint_Box_Gradient:
		gradient_colors_mul_alpha(&v.colors, a)
	case Paint_Radial_Gradient:
		gradient_colors_mul_alpha(&v.colors, a)
	case Paint_Conic_Gradient:
		gradient_colors_mul_alpha(&v.colors, a)
	}
}

@(private)
flavor_gradient_colors :: proc "contextless" (f: ^Paint_Flavor) -> ^Gradient_Colors {
	#partial switch &v in f {
	case Paint_Linear_Gradient:
		return &v.colors
	case Paint_Box_Gradient:
		return &v.colors
	case Paint_Radial_Gradient:
		return &v.colors
	case Paint_Conic_Gradient:
		return &v.colors
	}
	return nil
}
