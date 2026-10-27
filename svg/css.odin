package svg

import "core:encoding/xml"
import "core:strings"

import vg ".."

// Value syntax for the SVG importer (svg.odin): presentation properties,
// CSS colors, lengths, number lists and a small CSS stylesheet subset
// (type, class and id selectors, compound, comma lists).

// The presentation properties the importer understands, as attributes, in
// `style` attributes or in `<style>` rules.
@(private)
Prop :: enum u8 {
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
	Line_Height,
	White_Space,
	Text_Align,
	Shape_Inside,
	Shape_Padding,
	Inline_Size,
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
Decls :: [Prop]string

// Other names of a property (props holds each one's main name).
@(private)
PROP_ALIASES :: [?]struct {
	name: string,
	prop: Prop,
}{{"marker-start", .Marker}, {"marker-mid", .Marker}, {"marker-end", .Marker}}

// The property named `name`.
@(private)
prop_from_name :: proc(name: string) -> (Prop, bool) {
	for info, prop in props {
		if info.name == name {
			return prop, true
		}
	}
	for alias in PROP_ALIASES {
		if alias.name == name {
			return alias.prop, true
		}
	}
	return {}, false
}

// Applies `prop: value; ...` declarations (a style attribute) to `d`.
@(private)
apply_style_attr :: proc(d: ^Decls, style: string) {
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
		if p, ok := prop_from_name(name); ok {
			d[p] = value
		}
	}
}

// ---- numbers and lengths ---------------------------------------------------------

@(private)
parse_number :: proc "contextless" (s: string) -> (f32, bool) {
	sc := vg.Css_Scanner{s = s}
	v, ok := vg.css_scan_number(&sc)
	if !ok {
		return 0, false
	}
	vg.css_skip_ws(&sc)
	return v, sc.pos == len(s)
}

@(private)
Unit :: enum u8 {
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
Length :: struct {
	v:    f32,
	unit: Unit,
}

@(private)
scan_length :: proc "contextless" (sc: ^vg.Css_Scanner) -> (l: Length, ok: bool) {
	l.v = vg.css_scan_number(sc) or_return
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
			unit: Unit,
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
parse_length :: proc "contextless" (s: string) -> (Length, bool) {
	sc := vg.Css_Scanner{s = s}
	l, ok := scan_length(&sc)
	if !ok {
		return {}, false
	}
	vg.css_skip_ws(&sc)
	return l, sc.pos == len(s)
}

// A length in user units; `percent_of` is what 100% is, `font_size` what
// 1em is.
@(private)
length_px :: proc "contextless" (l: Length, percent_of, font_size: f32) -> f32 {
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
	prop:      Prop,
	important: bool,
	value:     string,
}

@(private)
Css_Rule :: struct {
	selector:    Css_Selector,
	// ids << 16 | classes << 8 | types
	specificity: u32,
	order:       u32,
	decls:       vg.Range,
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
			if p, ok := prop_from_name(name); ok {
				append(&sheet.decls, Css_Decl{p, important, value})
			}
		}
		decls := vg.Range{u32(decl_start), u32(len(sheet.decls) - decl_start)}
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
	if c.tag != "" && c.tag != local_name(e.ident) {
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
css_matches :: proc(sel: ^Css_Selector, x: ^xml.Document, el: u32, budget: ^vg.Budget) -> bool {
	return css_match_from(sel, x, int(sel.n) - 1, el, budget)
}

@(private)
css_match_from :: proc(sel: ^Css_Selector, x: ^xml.Document, k: int, el: u32, budget: ^vg.Budget) -> bool {
	if !vg.budget_take(budget, .Css_Steps) || !css_compound_matches(&sel.parts[k], x, el) {
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
