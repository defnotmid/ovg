package ovg

import "core:math"

// Per-pixel math of the image filters, on RGBA in [0, 1]. The software
// backend runs these procedures; shaders/ovg.slang carries the same
// formulas for the GPU, so the two stay pixel-identical.

unpremultiply :: #force_inline proc "contextless" (c: [4]f32) -> [4]f32 {
	if c.a <= 0 {
		return {}
	}
	return {c.r / c.a, c.g / c.a, c.b / c.a, c.a}
}

premultiply :: #force_inline proc "contextless" (c: [4]f32) -> [4]f32 {
	return {c.r * c.a, c.g * c.a, c.b * c.a, c.a}
}

srgb_to_linear :: #force_inline proc "contextless" (v: f32) -> f32 {
	return v / 12.92 if v <= 0.04045 else math.pow((v + 0.055) / 1.055, 2.4)
}

linear_to_srgb :: #force_inline proc "contextless" (v: f32) -> f32 {
	return v * 12.92 if v <= 0.0031308 else 1.055 * math.pow(v, 1 / 2.4) - 0.055
}

// `Color_Space_Convert` on one premultiplied pixel.
color_space_pixel :: proc "contextless" (c: [4]f32, to_linear: bool) -> [4]f32 {
	s := unpremultiply(c)
	for k in 0 ..< 3 {
		s[k] = srgb_to_linear(s[k]) if to_linear else linear_to_srgb(s[k])
	}
	return premultiply(s)
}

// `Color_Matrix` on one premultiplied pixel.
color_matrix_pixel :: proc "contextless" (m: [20]f32, c: [4]f32) -> [4]f32 {
	s := unpremultiply(c)
	out: [4]f32
	for row in 0 ..< 4 {
		i := row * 5
		out[row] = clamp(m[i] * s.r + m[i + 1] * s.g + m[i + 2] * s.b + m[i + 3] * s.a + m[i + 4], 0, 1)
	}
	return premultiply(out)
}

@(private = "file")
lum :: #force_inline proc "contextless" (c: [3]f32) -> f32 {
	return 0.3 * c.r + 0.59 * c.g + 0.11 * c.b
}

@(private = "file")
clip_color :: proc "contextless" (c: [3]f32) -> [3]f32 {
	l := lum(c)
	n := min(c.r, c.g, c.b)
	x := max(c.r, c.g, c.b)
	c := c
	if n < 0 && l - n > 0 {
		c = l + (c - l) * l / (l - n)
	}
	if x > 1 && x - l > 0 {
		c = l + (c - l) * (1 - l) / (x - l)
	}
	return c
}

@(private = "file")
set_lum :: proc "contextless" (c: [3]f32, l: f32) -> [3]f32 {
	return clip_color(c + (l - lum(c)))
}

@(private = "file")
sat :: #force_inline proc "contextless" (c: [3]f32) -> f32 {
	return max(c.r, c.g, c.b) - min(c.r, c.g, c.b)
}

// W3C SetSat: the smallest channel to 0, the largest to `s`, the middle one
// scaled in between (all three at once).
@(private = "file")
set_sat :: proc "contextless" (c: [3]f32, s: f32) -> [3]f32 {
	lo, hi := min(c.r, c.g, c.b), max(c.r, c.g, c.b)
	if hi <= lo {
		return {}
	}
	return (c - lo) * (s / (hi - lo))
}

@(private = "file")
blend_channel :: proc "contextless" (mode: Blend_Mode, cb, cs: f32) -> f32 {
	#partial switch mode {
	case .Multiply:
		return cb * cs
	case .Screen:
		return cb + cs - cb * cs
	case .Overlay:
		return blend_channel(.Hard_Light, cs, cb)
	case .Darken:
		return min(cb, cs)
	case .Lighten:
		return max(cb, cs)
	case .Color_Dodge:
		if cb <= 0 {return 0}
		if cs >= 1 {return 1}
		return min(1, cb / (1 - cs))
	case .Color_Burn:
		if cb >= 1 {return 1}
		if cs <= 0 {return 0}
		return 1 - min(1, (1 - cb) / cs)
	case .Hard_Light:
		if cs <= 0.5 {return cb * 2 * cs}
		return blend_channel(.Screen, cb, 2 * cs - 1)
	case .Soft_Light:
		if cs <= 0.5 {
			return cb - (1 - 2 * cs) * cb * (1 - cb)
		}
		d := ((16 * cb - 12) * cb + 4) * cb if cb <= 0.25 else math.sqrt(cb)
		return cb + (2 * cs - 1) * (d - cb)
	case .Difference:
		return abs(cb - cs)
	case .Exclusion:
		return cb + cs - 2 * cb * cs
	}
	return cs
}

// The blend function B(Cb, Cs) on straight color.
blend_function :: proc "contextless" (mode: Blend_Mode, cb, cs: [3]f32) -> [3]f32 {
	switch mode {
	case .Hue:
		return set_lum(set_sat(cs, sat(cb)), lum(cb))
	case .Saturation:
		return set_lum(set_sat(cb, sat(cs)), lum(cb))
	case .Color:
		return set_lum(cs, lum(cb))
	case .Luminosity:
		return set_lum(cb, lum(cs))
	case .Normal, .Multiply, .Screen, .Overlay, .Darken, .Lighten, .Color_Dodge, .Color_Burn, .Hard_Light, .Soft_Light, .Difference, .Exclusion:
	}
	return {blend_channel(mode, cb.r, cs.r), blend_channel(mode, cb.g, cs.g), blend_channel(mode, cb.b, cs.b)}
}

// `Blend` on one pixel: premultiplied source `s` onto premultiplied backdrop
// `b`.
blend_pixel :: proc "contextless" (mode: Blend_Mode, s, b: [4]f32) -> [4]f32 {
	us, ub := unpremultiply(s), unpremultiply(b)
	f := blend_function(mode, ub.rgb, us.rgb)
	rgb := s.rgb * (1 - b.a) + b.rgb * (1 - s.a) + f * (s.a * b.a)
	a := s.a + b.a - s.a * b.a
	return {clamp(rgb.r, 0, 1), clamp(rgb.g, 0, 1), clamp(rgb.b, 0, 1), clamp(a, 0, 1)}
}

// `Composite` on one pixel: premultiplied `i1` (in) and `i2` (in2).
composite_pixel :: proc "contextless" (op: Composite_Operator, k: [4]f32, i1, i2: [4]f32) -> [4]f32 {
	out: [4]f32
	switch op {
	case .Over:
		out = i1 + i2 * (1 - i1.a)
	case .In:
		out = i1 * i2.a
	case .Out:
		out = i1 * (1 - i2.a)
	case .Atop:
		out = i1 * i2.a + i2 * (1 - i1.a)
	case .Xor:
		out = i1 * (1 - i2.a) + i2 * (1 - i1.a)
	case .Lighter:
		out = i1 + i2
	case .Arithmetic:
		out = i1 * i2 * k[0] + i1 * k[1] + i2 * k[2] + k[3]
	}
	a := clamp(out.a, 0, 1)
	return {clamp(out.r, 0, a), clamp(out.g, 0, a), clamp(out.b, 0, a), a}
}

// Gradient position `t` after the spread method.
spread_t :: #force_inline proc "contextless" (t: f32, spread: f32) -> f32 {
	switch int(spread) {
	case 1:
		m := t - 2 * math.floor(t * 0.5)
		return 2 - m if m > 1 else m
	case 2:
		return t - math.floor(t)
	}
	return clamp(t, 0, 1)
}

// Gradient position of the two-point conical (focal) radial gradient at
// `pt` (gradient space): the largest t whose circle, interpolated from
// the focal circle (`focal`, `fr`) to the outer one (origin, `r`), passes
// through `pt`.
focal_gradient_t :: proc "contextless" (pt: Vec2, r, fr: f32, focal: Vec2) -> f32 {
	cd := -focal
	dr := r - fr
	pd := pt - focal
	a := cd.x * cd.x + cd.y * cd.y - dr * dr
	b := pd.x * cd.x + pd.y * cd.y + fr * dr
	c := pd.x * pd.x + pd.y * pd.y - fr * fr
	if abs(a) < 1e-6 {
		return c / (2 * b) if abs(b) > 1e-12 else 0
	}
	sq := math.sqrt(max(b * b - a * c, 0))
	hi := (b + sq) / a if a > 0 else (b - sq) / a
	if fr + hi * dr >= 0 {
		return hi
	}
	return (b - sq) / a if a > 0 else (b + sq) / a
}

// ---- lighting (feDiffuseLighting / feSpecularLighting) ----------------------------

// The surface normal's x, y at a pixel from its 3 x 3 alpha neighbourhood
// `a` (a[row][col], row 0 above): the Filter Effects Sobel kernels, with
// the spec's edge kernels where a neighbour column (`left`, `right`) or row
// (`up`, `down`) lies outside the image. Unscaled (multiply by
// -surfaceScale for the normal).
lighting_gradient :: proc "contextless" (a: [3][3]f32, left, right, up, down: bool) -> Vec2 {
	xl, xr := 0 if left else 1, 2 if right else 1
	yu, yd := 0 if up else 1, 2 if down else 1
	g: Vec2
	if xr > xl {
		sum, weight: f32
		for row in yu ..= yd {
			w: f32 = 2 if row == 1 else 1
			sum += w * (a[row][xr] - a[row][xl])
			weight += w
		}
		g.x = sum / weight * 2 / f32(xr - xl)
	}
	if yd > yu {
		sum, weight: f32
		for col in xl ..= xr {
			w: f32 = 2 if col == 1 else 1
			sum += w * (a[yd][col] - a[yu][col])
			weight += w
		}
		g.y = sum / weight * 2 / f32(yd - yu)
	}
	return g
}

// One lit pixel (premultiplied) at image pixel (x, y) with alpha `a`
// around it (see `lighting_gradient`), following resvg's lighting.rs:
// colors are rounded to 8 bits where it rounds them.
lighting_pixel :: proc "contextless" (l: Lighting, a: [3][3]f32, left, right, up, down: bool, x, y: f32) -> [4]f32 {
	g := lighting_gradient(a, left, right, up, down)
	n := [3]f32{-g.x * l.surface_scale, -g.y * l.surface_scale, 1}
	lv := l.position
	if l.light != .Distant {
		v := l.position - {x, y, a[1][1] * l.surface_scale}
		len_v := math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
		lv = v / len_v if len_v > 0 else v
	}
	color := l.color * 255
	if l.light == .Spot {
		s := l.points_at - l.position
		len_s := math.sqrt(s.x * s.x + s.y * s.y + s.z * s.z)
		if len_s > 0 {
			s /= len_s
		}
		minus_l_dot_s := -(lv.x * s.x + lv.y * s.y + lv.z * s.z)
		if minus_l_dot_s <= 0 || minus_l_dot_s < l.cone_cos {
			color = 0
		} else {
			f := math.pow(minus_l_dot_s, l.spot_exponent)
			for k in 0 ..< 3 {
				color[k] = math.floor(clamp(color[k] * f, 0, 255) + 0.5)
			}
		}
	}
	len_n := math.sqrt(n.x * n.x + n.y * n.y + 1)
	factor: f32
	if !l.specular {
		factor = l.constant * (n.x * lv.x + n.y * lv.y + lv.z) / len_n
	} else {
		h := lv + {0, 0, 1}
		len_h := math.sqrt(h.x * h.x + h.y * h.y + h.z * h.z)
		if len_h > 0 {
			n_dot_h := (n.x * h.x + n.y * h.y + h.z) / len_n / len_h
			if l.specular_exponent != 1 {
				n_dot_h = math.pow(max(n_dot_h, 0), l.specular_exponent)
			}
			factor = l.constant * n_dot_h
		}
	}
	out: [4]f32
	for k in 0 ..< 3 {
		out[k] = math.floor(clamp(color[k] * factor, 0, 255) + 0.5) / 255
	}
	out.a = max(out.r, out.g, out.b) if l.specular else 1
	return out
}

// ---- component transfer, displacement, convolution ---------------------------------

// The LUT entry for straight channel value `v` (0..1): v as 8 bits.
component_transfer_index :: #force_inline proc "contextless" (v: f32) -> f32 {
	return math.floor(clamp(v, 0, 1) * 255 + 0.5)
}

// Rounds half away from zero (Rust's f32::round, which resvg uses).
round_away :: #force_inline proc "contextless" (v: f32) -> f32 {
	return math.floor(abs(v) + 0.5) * (1 if v >= 0 else -1)
}

// Where feDisplacementMap reads for pixel (x, y), given the displacement
// map's (premultiplied, as resvg) pixel `m`.
displacement_offset :: proc "contextless" (d: Displacement_Map, m: [4]f32, x, y: f32) -> Vec2 {
	dx := m[d.channels.x & 3] - 0.5
	dy := m[d.channels.y & 3] - 0.5
	return {round_away(x + dx * d.scale.x), round_away(y + dy * d.scale.y)}
}

// feConvolveMatrix from the kernel sum (premultiplied color, or straight
// with preserveAlpha) and the source pixel's alpha, as resvg's
// convolve_matrix.rs.
convolve_finish :: proc "contextless" (v: Convolve_Matrix, sum: [4]f32, src_alpha: f32) -> [4]f32 {
	a := src_alpha if v.preserve_alpha else sum.a / v.divisor + v.bias
	ba := clamp(a, 0, 1)
	out: [4]f32
	for k in 0 ..< 3 {
		c := sum[k] / v.divisor + v.bias * a
		out[k] = clamp(c, 0, 1) * ba if v.preserve_alpha else clamp(c, 0, ba)
	}
	out.a = ba
	return out
}
