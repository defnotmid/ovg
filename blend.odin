package ovg

import "core:math"

// The `Blend` filter on one pixel, on the CPU, for callers that need a
// blended color outside a render (hit-testing through a blended layer, for
// example). shaders/filter.frag's blend_pixel is the one ovg renders with;
// these are its formulas line for line, and test_blend_pixel_matches_filter
// checks every mode against it.

// Premultiplied source `s` blended onto premultiplied backdrop `b` (W3C
// Compositing: the blend function B(Cb, Cs), then source-over), RGBA in
// [0, 1].
blend_pixel :: proc "contextless" (mode: Blend_Mode, s, b: [4]f32) -> [4]f32 {
	us, ub := blend_unpremultiply(s), blend_unpremultiply(b)
	f := blend_function(mode, ub.rgb, us.rgb)
	rgb := s.rgb * (1 - b.a) + b.rgb * (1 - s.a) + f * (s.a * b.a)
	a := s.a + b.a - s.a * b.a
	return {clamp(rgb.r, 0, 1), clamp(rgb.g, 0, 1), clamp(rgb.b, 0, 1), clamp(a, 0, 1)}
}

@(private = "file")
blend_unpremultiply :: #force_inline proc "contextless" (c: [4]f32) -> [4]f32 {
	if c.a <= 0 {
		return {}
	}
	return {c.r / c.a, c.g / c.a, c.b / c.a, c.a}
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
@(private = "file")
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
