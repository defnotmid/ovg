package ovg

import "base:runtime"
import "core:math"
import "core:strings"

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

// ---- CSS values --------------------------------------------------------------------

// Scans CSS / SVG number syntax: SVG's lengths and lists and CSS colors.
Css_Scanner :: struct {
	s:   string,
	pos: int,
}

css_skip_ws :: proc "contextless" (sc: ^Css_Scanner, comma := true) {
	for sc.pos < len(sc.s) {
		switch sc.s[sc.pos] {
		case ' ', '\t', '\n', '\r':
			sc.pos += 1
		case ',':
			if !comma {
				return
			}
			sc.pos += 1
		case:
			return
		}
	}
}

// A number at the scanner (no unit).
css_scan_number :: proc "contextless" (sc: ^Css_Scanner) -> (v: f32, ok: bool) {
	css_skip_ws(sc)
	s := sc.s
	i := sc.pos
	sign: f64 = 1
	if i < len(s) && (s[i] == '-' || s[i] == '+') {
		if s[i] == '-' {sign = -1}
		i += 1
	}
	digits := false
	m: f64 = 0
	for i < len(s) && s[i] >= '0' && s[i] <= '9' {
		m = m * 10 + f64(s[i] - '0')
		i += 1
		digits = true
	}
	if i < len(s) && s[i] == '.' {
		i += 1
		f: f64 = 0.1
		for i < len(s) && s[i] >= '0' && s[i] <= '9' {
			m += f64(s[i] - '0') * f
			f *= 0.1
			i += 1
			digits = true
		}
	}
	if !digits {
		return 0, false
	}
	// An exponent, but not the "e" of an "em"/"ex" unit.
	if i + 1 < len(s) && (s[i] == 'e' || s[i] == 'E') && s[i + 1] != 'm' && s[i + 1] != 'x' {
		j := i + 1
		es := 1
		if j < len(s) && (s[j] == '-' || s[j] == '+') {
			if s[j] == '-' {es = -1}
			j += 1
		}
		if j < len(s) && s[j] >= '0' && s[j] <= '9' {
			e := 0
			for j < len(s) && s[j] >= '0' && s[j] <= '9' {
				e = e * 10 + int(s[j] - '0')
				j += 1
			}
			m *= math.pow(10, f64(es * e))
			i = j
		}
	}
	sc.pos = i
	return f32(sign * m), true
}

// Parses a CSS color: `#rgb[a]`, `#rrggbb[aa]`, `rgb()` / `rgba()` (numbers
// or percentages), `hsl()` / `hsla()`, `transparent` and the CSS named
// colors. `currentColor` is not a color here (the caller resolves it).
css_color_parse :: proc(str: string) -> (col: Color, ok: bool) {
	// What this puts on the temp allocator goes when it returns.
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	s := strings.trim_space(str)
	if len(s) == 0 {
		return BLACK, false
	}
	if s[0] == '#' {
		return hex_color_parse(s)
	}
	if open := strings.index_byte(s, '('); open > 0 && s[len(s) - 1] == ')' {
		fname := strings.to_lower(strings.trim_space(s[:open]), context.temp_allocator)
		args := s[open + 1:len(s) - 1]
		v: [4]f32
		pct: [4]bool
		n := 0
		sc := Css_Scanner{s = args}
		for n < 4 {
			css_skip_ws(&sc)
			if sc.pos < len(sc.s) && sc.s[sc.pos] == '/' {
				sc.pos += 1
				continue
			}
			x, num_ok := css_scan_number(&sc)
			if !num_ok {
				break
			}
			v[n] = x
			if sc.pos < len(sc.s) && sc.s[sc.pos] == '%' {
				pct[n] = true
				sc.pos += 1
			} else if strings.has_prefix(sc.s[sc.pos:], "deg") {
				sc.pos += 3
			}
			n += 1
		}
		if n < 3 {
			return BLACK, false
		}
		a: f32 = 1
		if n == 4 {
			a = clamp(v[3] / 100 if pct[3] else v[3], 0, 1)
		}
		switch fname {
		case "rgb", "rgba":
			ch :: proc(x: f32, p: bool) -> f32 {
				return clamp(x / 100 if p else x / 255, 0, 1)
			}
			// 8-bit like browsers and resvg.
			q :: proc(x: f32) -> f32 {
				return math.round(x * 255) / 255
			}
			return {q(ch(v[0], pct[0])), q(ch(v[1], pct[1])), q(ch(v[2], pct[2])), a}, true
		case "hsl", "hsla":
			h := math.mod(v[0], 360)
			if h < 0 {
				h += 360
			}
			c := hsla(h / 360, clamp(v[1] / 100, 0, 1), clamp(v[2] / 100, 0, 1), a)
			q :: proc(x: f32) -> f32 {
				return math.round(x * 255) / 255
			}
			return {q(c.r), q(c.g), q(c.b), a}, true
		}
		return BLACK, false
	}
	lower := strings.to_lower(s, context.temp_allocator)
	if lower == "transparent" {
		return TRANSPARENT, true
	}
	if rgb, found := css_named_color(lower); found {
		return {f32(rgb >> 16) / 255, f32((rgb >> 8) & 0xff) / 255, f32(rgb & 0xff) / 255, 1}, true
	}
	return BLACK, false
}

@(private)
css_named_color :: proc(name: string) -> (u32, bool) {
	// Sorted by name for the binary search.
	@(static, rodata)
	NAMES := [?]struct {
		name: string,
		rgb:  u32,
	} {
		{"aliceblue", 0xf0f8ff}, {"antiquewhite", 0xfaebd7}, {"aqua", 0x00ffff}, {"aquamarine", 0x7fffd4},
		{"azure", 0xf0ffff}, {"beige", 0xf5f5dc}, {"bisque", 0xffe4c4}, {"black", 0x000000},
		{"blanchedalmond", 0xffebcd}, {"blue", 0x0000ff}, {"blueviolet", 0x8a2be2}, {"brown", 0xa52a2a},
		{"burlywood", 0xdeb887}, {"cadetblue", 0x5f9ea0}, {"chartreuse", 0x7fff00}, {"chocolate", 0xd2691e},
		{"coral", 0xff7f50}, {"cornflowerblue", 0x6495ed}, {"cornsilk", 0xfff8dc}, {"crimson", 0xdc143c},
		{"cyan", 0x00ffff}, {"darkblue", 0x00008b}, {"darkcyan", 0x008b8b}, {"darkgoldenrod", 0xb8860b},
		{"darkgray", 0xa9a9a9}, {"darkgreen", 0x006400}, {"darkgrey", 0xa9a9a9}, {"darkkhaki", 0xbdb76b},
		{"darkmagenta", 0x8b008b}, {"darkolivegreen", 0x556b2f}, {"darkorange", 0xff8c00}, {"darkorchid", 0x9932cc},
		{"darkred", 0x8b0000}, {"darksalmon", 0xe9967a}, {"darkseagreen", 0x8fbc8f}, {"darkslateblue", 0x483d8b},
		{"darkslategray", 0x2f4f4f}, {"darkslategrey", 0x2f4f4f}, {"darkturquoise", 0x00ced1}, {"darkviolet", 0x9400d3},
		{"deeppink", 0xff1493}, {"deepskyblue", 0x00bfff}, {"dimgray", 0x696969}, {"dimgrey", 0x696969},
		{"dodgerblue", 0x1e90ff}, {"firebrick", 0xb22222}, {"floralwhite", 0xfffaf0}, {"forestgreen", 0x228b22},
		{"fuchsia", 0xff00ff}, {"gainsboro", 0xdcdcdc}, {"ghostwhite", 0xf8f8ff}, {"gold", 0xffd700},
		{"goldenrod", 0xdaa520}, {"gray", 0x808080}, {"green", 0x008000}, {"greenyellow", 0xadff2f},
		{"grey", 0x808080}, {"honeydew", 0xf0fff0}, {"hotpink", 0xff69b4}, {"indianred", 0xcd5c5c},
		{"indigo", 0x4b0082}, {"ivory", 0xfffff0}, {"khaki", 0xf0e68c}, {"lavender", 0xe6e6fa},
		{"lavenderblush", 0xfff0f5}, {"lawngreen", 0x7cfc00}, {"lemonchiffon", 0xfffacd}, {"lightblue", 0xadd8e6},
		{"lightcoral", 0xf08080}, {"lightcyan", 0xe0ffff}, {"lightgoldenrodyellow", 0xfafad2}, {"lightgray", 0xd3d3d3},
		{"lightgreen", 0x90ee90}, {"lightgrey", 0xd3d3d3}, {"lightpink", 0xffb6c1}, {"lightsalmon", 0xffa07a},
		{"lightseagreen", 0x20b2aa}, {"lightskyblue", 0x87cefa}, {"lightslategray", 0x778899}, {"lightslategrey", 0x778899},
		{"lightsteelblue", 0xb0c4de}, {"lightyellow", 0xffffe0}, {"lime", 0x00ff00}, {"limegreen", 0x32cd32},
		{"linen", 0xfaf0e6}, {"magenta", 0xff00ff}, {"maroon", 0x800000}, {"mediumaquamarine", 0x66cdaa},
		{"mediumblue", 0x0000cd}, {"mediumorchid", 0xba55d3}, {"mediumpurple", 0x9370db}, {"mediumseagreen", 0x3cb371},
		{"mediumslateblue", 0x7b68ee}, {"mediumspringgreen", 0x00fa9a}, {"mediumturquoise", 0x48d1cc}, {"mediumvioletred", 0xc71585},
		{"midnightblue", 0x191970}, {"mintcream", 0xf5fffa}, {"mistyrose", 0xffe4e1}, {"moccasin", 0xffe4b5},
		{"navajowhite", 0xffdead}, {"navy", 0x000080}, {"oldlace", 0xfdf5e6}, {"olive", 0x808000},
		{"olivedrab", 0x6b8e23}, {"orange", 0xffa500}, {"orangered", 0xff4500}, {"orchid", 0xda70d6},
		{"palegoldenrod", 0xeee8aa}, {"palegreen", 0x98fb98}, {"paleturquoise", 0xafeeee}, {"palevioletred", 0xdb7093},
		{"papayawhip", 0xffefd5}, {"peachpuff", 0xffdab9}, {"peru", 0xcd853f}, {"pink", 0xffc0cb},
		{"plum", 0xdda0dd}, {"powderblue", 0xb0e0e6}, {"purple", 0x800080}, {"rebeccapurple", 0x663399},
		{"red", 0xff0000}, {"rosybrown", 0xbc8f8f}, {"royalblue", 0x4169e1}, {"saddlebrown", 0x8b4513},
		{"salmon", 0xfa8072}, {"sandybrown", 0xf4a460}, {"seagreen", 0x2e8b57}, {"seashell", 0xfff5ee},
		{"sienna", 0xa0522d}, {"silver", 0xc0c0c0}, {"skyblue", 0x87ceeb}, {"slateblue", 0x6a5acd},
		{"slategray", 0x708090}, {"slategrey", 0x708090}, {"snow", 0xfffafa}, {"springgreen", 0x00ff7f},
		{"steelblue", 0x4682b4}, {"tan", 0xd2b48c}, {"teal", 0x008080}, {"thistle", 0xd8bfd8},
		{"tomato", 0xff6347}, {"turquoise", 0x40e0d0}, {"violet", 0xee82ee}, {"wheat", 0xf5deb3},
		{"white", 0xffffff}, {"whitesmoke", 0xf5f5f5}, {"yellow", 0xffff00}, {"yellowgreen", 0x9acd32},
	}
	lo, hi := 0, len(NAMES)
	for lo < hi {
		mid := (lo + hi) / 2
		switch {
		case NAMES[mid].name == name:
			return NAMES[mid].rgb, true
		case NAMES[mid].name < name:
			lo = mid + 1
		case:
			hi = mid
		}
	}
	return 0, false
}
