package ovg

// Straight (non-premultiplied) RGBA with components in [0, 1].
Color :: struct {
	r, g, b, a: f32,
}

WHITE :: Color{1, 1, 1, 1}
BLACK :: Color{0, 0, 0, 1}
TRANSPARENT :: Color{0, 0, 0, 0}

rgb :: proc "contextless" (r, g, b: u8) -> Color {
	return {f32(r) / 255, f32(g) / 255, f32(b) / 255, 1}
}

rgba :: proc "contextless" (r, g, b, a: u8) -> Color {
	return {f32(r) / 255, f32(g) / 255, f32(b) / 255, f32(a) / 255}
}

rgbf :: proc "contextless" (r, g, b: f32) -> Color {
	return {r, g, b, 1}
}

rgbaf :: proc "contextless" (r, g, b, a: f32) -> Color {
	return {r, g, b, a}
}

hsl :: proc "contextless" (h, s, l: f32) -> Color {
	return hsla(h, s, l, 1)
}

// Hue in turns ([0, 1) is one full circle), saturation and lightness in [0, 1].
hsla :: proc "contextless" (hue, sat, light, a: f32) -> Color {
	h := hue - f32(int(hue))
	if h < 0 {
		h += 1
	}
	s := clamp(sat, 0, 1)
	l := clamp(light, 0, 1)
	m2 := l * (1 + s) if l <= 0.5 else l + s - l * s
	m1 := 2 * l - m2
	return {
		clamp(hue_channel(h + 1.0 / 3.0, m1, m2), 0, 1),
		clamp(hue_channel(h, m1, m2), 0, 1),
		clamp(hue_channel(h - 1.0 / 3.0, m1, m2), 0, 1),
		a,
	}
}

// Parses `#RRGGBB`, `#RRGGBBAA`, `#RGB`, `#RGBA` (CSS) or the same without
// `#`. Anything else is black, matching femtovg; `hex_color_parse` reports it.
hex_color :: proc(s: string) -> Color {
	c, _ := hex_color_parse(s)
	return c
}

// Like `hex_color`, with `ok = false` (and black) for anything else.
hex_color_parse :: proc(s: string) -> (c: Color, ok: bool) {
	h := s[1:] if len(s) > 0 && s[0] == '#' else s
	if len(h) != 3 && len(h) != 4 && len(h) != 6 && len(h) != 8 {
		return BLACK, false
	}
	v: [8]u8
	for ch, i in transmute([]u8)h {
		switch ch {
		case '0' ..= '9':
			v[i] = ch - '0'
		case 'a' ..= 'f':
			v[i] = ch - 'a' + 10
		case 'A' ..= 'F':
			v[i] = ch - 'A' + 10
		case:
			return BLACK, false
		}
	}
	if len(h) <= 4 {
		// One digit per channel: `F` is `FF`.
		a := v[3] * 17 if len(h) == 4 else 255
		return rgba(v[0] * 17, v[1] * 17, v[2] * 17, a), true
	}
	a := v[6] << 4 | v[7] if len(h) == 8 else 255
	return rgba(v[0] << 4 | v[1], v[2] << 4 | v[3], v[4] << 4 | v[5], a), true
}

premultiplied :: proc "contextless" (c: Color) -> Color {
	return {c.r * c.a, c.g * c.a, c.b * c.a, c.a}
}

color_to_array :: proc "contextless" (c: Color) -> [4]f32 {
	return {c.r, c.g, c.b, c.a}
}

@(private)
hue_channel :: proc "contextless" (hue, m1, m2: f32) -> f32 {
	h := hue
	if h < 0 {
		h += 1
	}
	if h > 1 {
		h -= 1
	}
	if h < 1.0 / 6.0 {
		return m1 + (m2 - m1) * h * 6
	}
	if h < 3.0 / 6.0 {
		return m2
	}
	if h < 4.0 / 6.0 {
		return m1 + (m2 - m1) * (2.0 / 3.0 - h) * 6
	}
	return m1
}
