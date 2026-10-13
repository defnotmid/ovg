package ovg

import "core:encoding/xml"
import "core:math"
import "core:strings"

// Value syntax for the SVG importer (svg.odin): presentation properties,
// CSS colors, lengths, number lists and a small CSS stylesheet subset
// (type, class and id selectors, compound, comma lists).

// The presentation properties the importer understands, as attributes, in
// `style` attributes or in `<style>` rules.
@(private)
Svg_Prop :: enum u8 {
	Fill,
	Fill_Opacity,
	Fill_Rule,
	Stroke,
	Stroke_Opacity,
	Stroke_Width,
	Stroke_Linecap,
	Stroke_Linejoin,
	Stroke_Miterlimit,
	Stroke_Dasharray,
	Stroke_Dashoffset,
	Opacity,
	Visibility,
	Display,
	Color,
	Font_Family,
	Font_Size,
	Font_Weight,
	Font_Style,
	Text_Anchor,
	Dominant_Baseline,
	Alignment_Baseline,
	Letter_Spacing,
	Clip_Path,
	Clip_Rule,
	Mask,
	Mask_Type,
	Filter,
	Mix_Blend_Mode,
	Isolation,
	Stop_Color,
	Stop_Opacity,
	Flood_Color,
	Flood_Opacity,
	Lighting_Color,
	Shape_Rendering,
	Overflow,
	Color_Interpolation_Filters,
	Transform,
	Marker,
	Text_Decoration,
	Paint_Order,
}

@(private)
Svg_Decls :: [Svg_Prop]string

// Other names of a property (svg_props holds each one's main name).
@(private)
SVG_PROP_ALIASES :: [?]struct {
	name: string,
	prop: Svg_Prop,
}{{"marker-start", .Marker}, {"marker-mid", .Marker}, {"marker-end", .Marker}}

// The property named `name`.
@(private)
svg_prop_from_name :: proc(name: string) -> (Svg_Prop, bool) {
	for info, prop in svg_props {
		if info.name == name {
			return prop, true
		}
	}
	for alias in SVG_PROP_ALIASES {
		if alias.name == name {
			return alias.prop, true
		}
	}
	return {}, false
}

// Applies `prop: value; ...` declarations (a style attribute) to `d`.
@(private)
svg_apply_style_attr :: proc(d: ^Svg_Decls, style: string) {
	rest := style
	if strings.contains(style, "/*") {
		// Strip comments.
		b := make([]u8, len(style), context.temp_allocator)
		n := 0
		for i := 0; i < len(style); {
			if strings.has_prefix(style[i:], "/*") {
				end := strings.index(style[i + 2:], "*/")
				i = len(style) if end < 0 else i + 2 + end + 2
				continue
			}
			b[n] = style[i]
			n += 1
			i += 1
		}
		rest = string(b[:n])
	}
	for decl in strings.split_iterator(&rest, ";") {
		colon := strings.index_byte(decl, ':')
		if colon < 0 {
			continue
		}
		name := strings.trim_space(decl[:colon])
		value := strings.trim_space(decl[colon + 1:])
		if strings.has_suffix(value, "!important") {
			value = strings.trim_space(value[:len(value) - len("!important")])
		}
		if p, ok := svg_prop_from_name(name); ok {
			d[p] = value
		}
	}
}

// ---- numbers and lengths ---------------------------------------------------------

@(private)
Svg_Scanner :: struct {
	s:   string,
	pos: int,
}

@(private)
svg_skip_ws :: proc "contextless" (sc: ^Svg_Scanner, comma := true) {
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
@(private)
svg_scan_number :: proc "contextless" (sc: ^Svg_Scanner) -> (v: f32, ok: bool) {
	svg_skip_ws(sc)
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

@(private)
svg_parse_number :: proc "contextless" (s: string) -> (f32, bool) {
	sc := Svg_Scanner{s = s}
	v, ok := svg_scan_number(&sc)
	if !ok {
		return 0, false
	}
	svg_skip_ws(&sc)
	return v, sc.pos == len(s)
}

@(private)
Svg_Unit :: enum u8 {
	None,
	Px,
	Percent,
	Em,
	Ex,
	In,
	Cm,
	Mm,
	Pt,
	Pc,
}

@(private)
Svg_Length :: struct {
	v:    f32,
	unit: Svg_Unit,
}

@(private)
svg_scan_length :: proc "contextless" (sc: ^Svg_Scanner) -> (l: Svg_Length, ok: bool) {
	l.v = svg_scan_number(sc) or_return
	s := sc.s
	if sc.pos < len(s) && s[sc.pos] == '%' {
		sc.pos += 1
		l.unit = .Percent
		return l, true
	}
	if sc.pos + 1 < len(s) {
		u := s[sc.pos:sc.pos + 2]
		units := [?]struct {
			name: string,
			unit: Svg_Unit,
		}{{"px", .Px}, {"em", .Em}, {"ex", .Ex}, {"in", .In}, {"cm", .Cm}, {"mm", .Mm}, {"pt", .Pt}, {"pc", .Pc}}
		for un in units {
			if u == un.name {
				l.unit = un.unit
				sc.pos += 2
				break
			}
		}
	}
	return l, true
}

@(private)
svg_parse_length :: proc "contextless" (s: string) -> (Svg_Length, bool) {
	sc := Svg_Scanner{s = s}
	l, ok := svg_scan_length(&sc)
	if !ok {
		return {}, false
	}
	svg_skip_ws(&sc)
	return l, sc.pos == len(s)
}

// A length in user units; `percent_of` is what 100% is, `font_size` what
// 1em is.
@(private)
svg_length_px :: proc "contextless" (l: Svg_Length, percent_of, font_size: f32) -> f32 {
	switch l.unit {
	case .None, .Px:
		return l.v
	case .Percent:
		return l.v * percent_of / 100
	case .Em:
		return l.v * font_size
	case .Ex:
		return l.v * font_size * 0.5
	case .In:
		return l.v * 96
	case .Cm:
		return l.v * 96 / 2.54
	case .Mm:
		return l.v * 96 / 25.4
	case .Pt:
		return l.v * 4.0 / 3.0
	case .Pc:
		return l.v * 16
	}
	return l.v
}

// ---- colors ------------------------------------------------------------------------

// Parses a CSS color: `#rgb[a]`, `#rrggbb[aa]`, `rgb()` / `rgba()` (numbers
// or percentages), `hsl()` / `hsla()`, `transparent` and the CSS named
// colors. `currentColor` is not a color here (the caller resolves it).
css_color_parse :: proc(str: string) -> (col: Color, ok: bool) {
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
		sc := Svg_Scanner{s = args}
		for n < 4 {
			svg_skip_ws(&sc)
			if sc.pos < len(sc.s) && sc.s[sc.pos] == '/' {
				sc.pos += 1
				continue
			}
			x, num_ok := svg_scan_number(&sc)
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

// ---- stylesheets -----------------------------------------------------------------

// A compound selector: optional type, id, classes, one attribute test and
// :first-child (all must match).
@(private)
Css_Compound :: struct {
	tag:         string,
	id:          string,
	classes:     [4]string,
	n_classes:   u8,
	// 0 none, 1 [attr], 2 [attr=v], 3 [attr~=v], 4 [attr^=v], 5 [attr$=v], 6 [attr*=v]
	attr_op:     u8,
	first_child: bool,
	attr:        string,
	attr_value:  string,
}

// Compounds joined by descendant (' ') or child ('>') combinators.
@(private)
Css_Selector :: struct {
	parts:       [6]Css_Compound,
	// combinators[i] joins parts[i - 1] and parts[i].
	combinators: [6]u8,
	n:           u8,
}

@(private)
Css_Decl :: struct {
	prop:      Svg_Prop,
	important: bool,
	value:     string,
}

@(private)
Css_Rule :: struct {
	selector:    Css_Selector,
	// ids << 16 | classes << 8 | types
	specificity: u32,
	order:       u32,
	decls:       Range,
}

@(private)
Css_Sheet :: struct {
	rules: [dynamic]Css_Rule,
	decls: [dynamic]Css_Decl,
	// Selectors this subset can't match (combinators, pseudo-classes, ...).
	skipped: int,
}

// Adds the rules of a `<style>` element's text. Strings point into `text`.
@(private)
css_parse_sheet :: proc(sheet: ^Css_Sheet, text: string) {
	s := text
	i := 0
	for i < len(s) {
		// Skip whitespace, comments and CDATA / HTML comment markers.
		skip: for i < len(s) {
			switch {
			case s[i] == ' ' || s[i] == '\t' || s[i] == '\n' || s[i] == '\r':
				i += 1
			case strings.has_prefix(s[i:], "/*"):
				end := strings.index(s[i + 2:], "*/")
				i = len(s) if end < 0 else i + 2 + end + 2
			case strings.has_prefix(s[i:], "<![CDATA["):
				i += 9
			case strings.has_prefix(s[i:], "]]>"), strings.has_prefix(s[i:], "-->"):
				i += 3
			case strings.has_prefix(s[i:], "<!--"):
				i += 4
			case:
				break skip
			}
		}
		if i >= len(s) {
			break
		}
		open := strings.index_byte(s[i:], '{')
		if open < 0 {
			break
		}
		prelude := strings.trim_space(s[i:i + open])
		body_start := i + open + 1
		// Find the matching brace (at-rules nest).
		depth := 1
		j := body_start
		for j < len(s) && depth > 0 {
			switch s[j] {
			case '{':
				depth += 1
			case '}':
				depth -= 1
			}
			j += 1
		}
		body := s[body_start:max(j - 1, body_start)]
		i = j
		if strings.has_prefix(prelude, "@") {
			// @media, @font-face, ...: not supported.
			sheet.skipped += 1
			continue
		}
		decl_start := len(sheet.decls)
		rest := body
		for decl in strings.split_iterator(&rest, ";") {
			colon := strings.index_byte(decl, ':')
			if colon < 0 {
				continue
			}
			name := strings.trim_space(decl[:colon])
			value := strings.trim_space(decl[colon + 1:])
			important := false
			if strings.has_suffix(value, "!important") {
				value = strings.trim_space(value[:len(value) - len("!important")])
				important = true
			}
			if p, ok := svg_prop_from_name(name); ok {
				append(&sheet.decls, Css_Decl{p, important, value})
			}
		}
		decls := Range{u32(decl_start), u32(len(sheet.decls) - decl_start)}
		sel_rest := prelude
		for sel_str in strings.split_iterator(&sel_rest, ",") {
			sel, spec, ok := css_parse_selector(strings.trim_space(sel_str))
			if !ok {
				sheet.skipped += 1
				continue
			}
			append(&sheet.rules, Css_Rule{sel, spec, u32(len(sheet.rules)), decls})
		}
	}
}

// Sorts the rules by specificity, then order: applied in sequence, later
// rules win.
@(private)
css_sort_rules :: proc(sheet: ^Css_Sheet) {
	rules := sheet.rules[:]
	// Insertion sort: sheets are small and mostly sorted already.
	for i in 1 ..< len(rules) {
		r := rules[i]
		j := i
		for j > 0 && (rules[j - 1].specificity > r.specificity || (rules[j - 1].specificity == r.specificity && rules[j - 1].order > r.order)) {
			rules[j] = rules[j - 1]
			j -= 1
		}
		rules[j] = r
	}
}

@(private)
css_parse_selector :: proc(s: string) -> (sel: Css_Selector, spec: u32, ok: bool) {
	i := 0
	ident :: proc(s: string, i: ^int) -> string {
		start := i^
		for i^ < len(s) {
			c := s[i^]
			if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' || c == '_' || c >= 0x80 {
				i^ += 1
			} else {
				break
			}
		}
		return s[start:i^]
	}
	comb: u8 = 0
	for {
		for i < len(s) && (s[i] == ' ' || s[i] == '\t' || s[i] == '\n' || s[i] == '\r') {
			i += 1
			if comb == 0 && sel.n > 0 {
				comb = ' '
			}
		}
		if i >= len(s) {
			break
		}
		if s[i] == '>' {
			comb = '>'
			i += 1
			continue
		}
		if s[i] == '+' || s[i] == '~' {
			// Sibling combinators.
			return
		}
		if int(sel.n) == len(sel.parts) {
			return
		}
		c := &sel.parts[sel.n]
		sel.combinators[sel.n] = comb if sel.n > 0 else 0
		comb = 0
		start := i
		if s[i] == '*' {
			i += 1
		} else if s[i] != '.' && s[i] != '#' && s[i] != '[' && s[i] != ':' {
			c.tag = ident(s, &i)
			if c.tag == "" {
				return
			}
			spec += 1
		}
		compound: for i < len(s) {
			switch s[i] {
			case '.':
				i += 1
				name := ident(s, &i)
				if name == "" || c.n_classes == len(c.classes) {
					return
				}
				c.classes[c.n_classes] = name
				c.n_classes += 1
				spec += 1 << 8
			case '#':
				i += 1
				name := ident(s, &i)
				if name == "" {
					return
				}
				c.id = name
				spec += 1 << 16
			case '[':
				end := strings.index_byte(s[i:], ']')
				if end < 0 || c.attr_op != 0 {
					return
				}
				body := s[i + 1:i + end]
				i += end + 1
				spec += 1 << 8
				c.attr_op = 1
				if eq := strings.index_byte(body, '='); eq >= 0 {
					name := body[:eq]
					c.attr_op = 2
					if len(name) > 0 {
						switch name[len(name) - 1] {
						case '~':
							c.attr_op = 3
						case '^':
							c.attr_op = 4
						case '$':
							c.attr_op = 5
						case '*':
							c.attr_op = 6
						}
						if c.attr_op > 2 {
							name = name[:len(name) - 1]
						}
					}
					c.attr = strings.trim_space(name)
					c.attr_value = strings.trim(strings.trim_space(body[eq + 1:]), "'\"")
				} else {
					c.attr = strings.trim_space(body)
				}
			case ':':
				if !strings.has_prefix(s[i:], ":first-child") {
					return
				}
				i += len(":first-child")
				c.first_child = true
				spec += 1 << 8
			case:
				break compound
			}
		}
		if i == start {
			return
		}
		sel.n += 1
	}
	return sel, spec, sel.n > 0
}

@(private)
css_compound_matches :: proc(c: ^Css_Compound, x: ^xml.Document, el: u32) -> bool {
	e := &x.elements[el]
	if e.kind != .Element {
		return false
	}
	if c.tag != "" && c.tag != svg_tag(e.ident) {
		return false
	}
	id, class, attr_val := "", "", ""
	has_attr := false
	for a in e.attribs {
		switch a.key {
		case "id":
			id = a.val
		case "class":
			class = a.val
		}
		if c.attr_op != 0 && a.key == c.attr {
			attr_val = a.val
			has_attr = true
		}
	}
	if c.id != "" && c.id != id {
		return false
	}
	for k in 0 ..< int(c.n_classes) {
		found := false
		rest := class
		for cl in strings.fields_iterator(&rest) {
			if cl == c.classes[k] {
				found = true
				break
			}
		}
		if !found {
			return false
		}
	}
	switch c.attr_op {
	case 1:
		if !has_attr {return false}
	case 2:
		if !has_attr || attr_val != c.attr_value {return false}
	case 3:
		if !has_attr {return false}
		found := false
		rest := attr_val
		for w in strings.fields_iterator(&rest) {
			if w == c.attr_value {
				found = true
			}
		}
		if !found {return false}
	case 4:
		if !has_attr || !strings.has_prefix(attr_val, c.attr_value) {return false}
	case 5:
		if !has_attr || !strings.has_suffix(attr_val, c.attr_value) {return false}
	case 6:
		if !has_attr || !strings.contains(attr_val, c.attr_value) {return false}
	}
	if c.first_child {
		if el == 0 {
			return false
		}
		for v in x.elements[e.parent].value {
			if ch, ok := v.(xml.Element_ID); ok && x.elements[ch].kind == .Element {
				if ch != el {
					return false
				}
				break
			}
		}
	}
	return true
}

// Whether the selector matches element `el`, right to left. Each step
// counts against the budget's Css_Steps (descendant combinators backtrack):
// past it, nothing matches.
@(private)
css_matches :: proc(sel: ^Css_Selector, x: ^xml.Document, el: u32, budget: ^Budget) -> bool {
	return css_match_from(sel, x, int(sel.n) - 1, el, budget)
}

@(private)
css_match_from :: proc(sel: ^Css_Selector, x: ^xml.Document, k: int, el: u32, budget: ^Budget) -> bool {
	if !budget_take(budget, .Css_Steps) || !css_compound_matches(&sel.parts[k], x, el) {
		return false
	}
	if k == 0 {
		return true
	}
	if el == 0 {
		return false
	}
	parent := x.elements[el].parent
	if sel.combinators[k] == '>' {
		return css_match_from(sel, x, k - 1, parent, budget)
	}
	for a := parent;; a = x.elements[a].parent {
		if css_match_from(sel, x, k - 1, a, budget) {
			return true
		}
		if a == 0 || .Css_Steps in budget.hit {
			return false
		}
	}
}
