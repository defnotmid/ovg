package ovg

import "core:math"

// Appends SVG path data (`d` attribute syntax: M L H V C S Q T A Z, absolute
// and relative) to `p`. Returns false at the first malformed command; what
// was parsed so far stays in the path.
path_svg :: proc(p: ^Path, d: string) -> bool {
	s := Path_Scanner{src = d}
	cur, start, last_ctrl: Vec2
	prev_cmd: u8
	cmd: u8
	// The last command was Z: a drawing command opens a new subpath at the
	// start point (SVG), not a continuation of the closed one.
	closed := false
	for {
		skip_separators(&s)
		if s.pos >= len(s.src) {
			return true
		}
		c := s.src[s.pos]
		if is_command(c) {
			cmd = c
			s.pos += 1
		} else if cmd == 0 {
			return false
		} else if cmd == 'M' {
			// Coordinates after a moveto are implicit linetos.
			cmd = 'L'
		} else if cmd == 'm' {
			cmd = 'l'
		}
		rel := cmd >= 'a'
		base := cur if rel else Vec2{}
		if closed && cmd != 'M' && cmd != 'm' && cmd != 'Z' && cmd != 'z' {
			path_move_to(p, cur.x, cur.y)
		}
		closed = false

		switch cmd {
		case 'M', 'm':
			pt := read_point(&s) or_return
			cur = base + pt
			start = cur
			path_move_to(p, cur.x, cur.y)
		case 'L', 'l':
			pt := read_point(&s) or_return
			cur = base + pt
			path_line_to(p, cur.x, cur.y)
		case 'H', 'h':
			x := read_number(&s) or_return
			cur.x = cur.x + x if rel else x
			path_line_to(p, cur.x, cur.y)
		case 'V', 'v':
			y := read_number(&s) or_return
			cur.y = cur.y + y if rel else y
			path_line_to(p, cur.x, cur.y)
		case 'C', 'c':
			c1 := base + (read_point(&s) or_return)
			c2 := base + (read_point(&s) or_return)
			end := base + (read_point(&s) or_return)
			path_bezier_to(p, c1.x, c1.y, c2.x, c2.y, end.x, end.y)
			last_ctrl = c2
			cur = end
		case 'S', 's':
			c1 := cur
			if prev_cmd == 'C' || prev_cmd == 'c' || prev_cmd == 'S' || prev_cmd == 's' {
				c1 = cur * 2 - last_ctrl
			}
			c2 := base + (read_point(&s) or_return)
			end := base + (read_point(&s) or_return)
			path_bezier_to(p, c1.x, c1.y, c2.x, c2.y, end.x, end.y)
			last_ctrl = c2
			cur = end
		case 'Q', 'q':
			c := base + (read_point(&s) or_return)
			end := base + (read_point(&s) or_return)
			path_quad_to(p, c.x, c.y, end.x, end.y)
			last_ctrl = c
			cur = end
		case 'T', 't':
			c := cur
			if prev_cmd == 'Q' || prev_cmd == 'q' || prev_cmd == 'T' || prev_cmd == 't' {
				c = cur * 2 - last_ctrl
			}
			end := base + (read_point(&s) or_return)
			path_quad_to(p, c.x, c.y, end.x, end.y)
			last_ctrl = c
			cur = end
		case 'A', 'a':
			rx := read_number(&s) or_return
			ry := read_number(&s) or_return
			rot := read_number(&s) or_return
			large := read_flag(&s) or_return
			sweep := read_flag(&s) or_return
			end := base + (read_point(&s) or_return)
			svg_arc(p, cur, end, rx, ry, rot, large, sweep)
			cur = end
		case 'Z', 'z':
			path_close(p)
			cur = start
			closed = true
		case:
			return false
		}
		prev_cmd = cmd
	}
}

// Parses an SVG transform list ("matrix(a b c d e f)", "translate(x [y])",
// "scale(sx [sy])", "rotate(deg [cx cy])", "skewX(deg)", "skewY(deg)",
// separated by spaces or commas). As in SVG, each transform applies in the
// coordinate system the ones before it establish: "translate(10) scale(2)"
// scales first, then translates. Returns false on malformed input.
transform_svg :: proc(src: string) -> (m: Transform2D, ok: bool) {
	s := Path_Scanner{src = src}
	m = TRANSFORM_IDENTITY
	for {
		skip_separators(&s)
		if s.pos >= len(s.src) {
			return m, true
		}
		start := s.pos
		for s.pos < len(s.src) && ((s.src[s.pos] | 0x20) >= 'a' && (s.src[s.pos] | 0x20) <= 'z') {
			s.pos += 1
		}
		name := s.src[start:s.pos]
		skip_separators(&s)
		if s.pos >= len(s.src) || s.src[s.pos] != '(' {
			return m, false
		}
		s.pos += 1
		args: [6]f32
		n := 0
		for {
			skip_separators(&s)
			if s.pos < len(s.src) && s.src[s.pos] == ')' {
				s.pos += 1
				break
			}
			if n == len(args) {
				return m, false
			}
			args[n] = read_number(&s) or_return
			n += 1
		}
		t: Transform2D
		switch {
		case name == "matrix" && n == 6:
			t = Transform2D(args)
		case name == "translate" && (n == 1 || n == 2):
			t = transform_translation(args[0], args[1])
		case name == "scale" && (n == 1 || n == 2):
			t = transform_scaling(args[0], args[1] if n == 2 else args[0])
		case name == "rotate" && (n == 1 || n == 3):
			t = transform_translation(-args[1], -args[2])
			t = transform_multiply(t, transform_rotation(args[0] * math.RAD_PER_DEG))
			t = transform_multiply(t, transform_translation(args[1], args[2]))
		case name == "skewX" && n == 1:
			t = transform_skew_x(args[0] * math.RAD_PER_DEG)
		case name == "skewY" && n == 1:
			t = transform_skew_y(args[0] * math.RAD_PER_DEG)
		case:
			return m, false
		}
		// Later transforms apply first (closer to the content).
		m = transform_multiply(t, m)
	}
}

@(private = "file")
Path_Scanner :: struct {
	src: string,
	pos: int,
}

@(private = "file")
is_command :: proc(c: u8) -> bool {
	switch c {
	case 'M', 'm', 'L', 'l', 'H', 'h', 'V', 'v', 'C', 'c', 'S', 's', 'Q', 'q', 'T', 't', 'A', 'a', 'Z', 'z':
		return true
	}
	return false
}

@(private = "file")
skip_separators :: proc(s: ^Path_Scanner) {
	for s.pos < len(s.src) {
		switch s.src[s.pos] {
		case ' ', '\t', '\n', '\r', ',':
			s.pos += 1
		case:
			return
		}
	}
}

@(private = "file")
read_number :: proc(s: ^Path_Scanner) -> (f32, bool) {
	skip_separators(s)
	start := s.pos
	if s.pos < len(s.src) && (s.src[s.pos] == '-' || s.src[s.pos] == '+') {
		s.pos += 1
	}
	digits, dot := false, false
	for s.pos < len(s.src) {
		c := s.src[s.pos]
		if c >= '0' && c <= '9' {
			digits = true
		} else if c == '.' && !dot {
			dot = true
		} else {
			break
		}
		s.pos += 1
	}
	if s.pos < len(s.src) && digits && (s.src[s.pos] == 'e' || s.src[s.pos] == 'E') {
		s.pos += 1
		if s.pos < len(s.src) && (s.src[s.pos] == '-' || s.src[s.pos] == '+') {
			s.pos += 1
		}
		for s.pos < len(s.src) && s.src[s.pos] >= '0' && s.src[s.pos] <= '9' {
			s.pos += 1
		}
	}
	if !digits {
		return 0, false
	}
	return parse_f32(s.src[start:s.pos]), true
}

@(private = "file")
read_point :: proc(s: ^Path_Scanner) -> (pt: Vec2, ok: bool) {
	x := read_number(s) or_return
	y := read_number(s) or_return
	return {x, y}, true
}

// Arc flags may be written without separators ("a1 1 0 01 10 10").
@(private = "file")
read_flag :: proc(s: ^Path_Scanner) -> (bool, bool) {
	skip_separators(s)
	if s.pos >= len(s.src) {
		return false, false
	}
	c := s.src[s.pos]
	if c != '0' && c != '1' {
		return false, false
	}
	s.pos += 1
	return c == '1', true
}

@(private = "file")
parse_f32 :: proc(str: string) -> f32 {
	i := 0
	sign: f64 = 1
	if i < len(str) && (str[i] == '-' || str[i] == '+') {
		if str[i] == '-' {sign = -1}
		i += 1
	}
	v: f64 = 0
	for i < len(str) && str[i] >= '0' && str[i] <= '9' {
		v = v * 10 + f64(str[i] - '0')
		i += 1
	}
	if i < len(str) && str[i] == '.' {
		i += 1
		scale: f64 = 0.1
		for i < len(str) && str[i] >= '0' && str[i] <= '9' {
			v += f64(str[i] - '0') * scale
			scale *= 0.1
			i += 1
		}
	}
	if i < len(str) && (str[i] == 'e' || str[i] == 'E') {
		i += 1
		esign := 1
		if i < len(str) && (str[i] == '-' || str[i] == '+') {
			if str[i] == '-' {esign = -1}
			i += 1
		}
		e := 0
		for i < len(str) && str[i] >= '0' && str[i] <= '9' {
			e = e * 10 + int(str[i] - '0')
			i += 1
		}
		v *= math.pow(10, f64(esign * e))
	}
	return f32(sign * v)
}

// Endpoint-parameterized elliptical arc (SVG implementation notes, F.6),
// approximated with cubic beziers of at most 90 degrees each.
@(private = "file")
svg_arc :: proc(p: ^Path, from, to: Vec2, rx_in, ry_in, rotation: f32, large, sweep: bool) {
	if from == to {
		return
	}
	rx, ry := abs(rx_in), abs(ry_in)
	if rx == 0 || ry == 0 {
		path_line_to(p, to.x, to.y)
		return
	}
	phi := rotation * math.RAD_PER_DEG
	cp, sp := math.cos(phi), math.sin(phi)
	d := (from - to) * 0.5
	x1 := cp * d.x + sp * d.y
	y1 := -sp * d.x + cp * d.y

	// Scale up radii that cannot reach the endpoint.
	lambda := (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
	if lambda > 1 {
		s := math.sqrt(lambda)
		rx *= s
		ry *= s
	}
	num := rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
	den := rx * rx * y1 * y1 + ry * ry * x1 * x1
	coef := math.sqrt(max(num / den, 0))
	if large == sweep {
		coef = -coef
	}
	cxp := coef * rx * y1 / ry
	cyp := -coef * ry * x1 / rx
	mid := (from + to) * 0.5
	c := Vec2{cp * cxp - sp * cyp + mid.x, sp * cxp + cp * cyp + mid.y}

	vec_angle :: proc(u, v: Vec2) -> f32 {
		a := math.atan2(u.x * v.y - u.y * v.x, u.x * v.x + u.y * v.y)
		return a
	}
	u := Vec2{(x1 - cxp) / rx, (y1 - cyp) / ry}
	v := Vec2{(-x1 - cxp) / rx, (-y1 - cyp) / ry}
	theta := vec_angle({1, 0}, u)
	delta := vec_angle(u, v)
	if !sweep && delta > 0 {
		delta -= math.TAU
	} else if sweep && delta < 0 {
		delta += math.TAU
	}

	segments := max(int(math.ceil(abs(delta) / (math.PI / 2))), 1)
	step := delta / f32(segments)
	k := 4.0 / 3.0 * math.tan(step / 4)
	point :: proc(c: Vec2, rx, ry, cp, sp, a: f32) -> Vec2 {
		x, y := rx * math.cos(a), ry * math.sin(a)
		return {c.x + cp * x - sp * y, c.y + sp * x + cp * y}
	}
	deriv :: proc(rx, ry, cp, sp, a: f32) -> Vec2 {
		x, y := -rx * math.sin(a), ry * math.cos(a)
		return {cp * x - sp * y, sp * x + cp * y}
	}
	a0 := theta
	for i in 0 ..< segments {
		a1 := a0 + step
		p0 := point(c, rx, ry, cp, sp, a0)
		p3 := point(c, rx, ry, cp, sp, a1)
		if i == segments - 1 {
			p3 = to
		}
		c1 := p0 + deriv(rx, ry, cp, sp, a0) * k
		c2 := p3 - deriv(rx, ry, cp, sp, a1) * k
		path_bezier_to(p, c1.x, c1.y, c2.x, c2.y, p3.x, p3.y)
		a0 = a1
	}
}
