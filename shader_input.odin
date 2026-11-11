package ovg

import "core:math"

// What the shape shaders read (shaders/shapes.glsl), built the same way by
// both backends: an instance's row, its motion's, and a group's grid.

// One shape instance as the shape shaders read it (`Shape_Instance` in
// shaders/shapes.glsl).
Shader_Instance :: struct {
	m:      [4]f32,
	t:      [4]f32,
	bounds: [4]f32,
	uv:     [4]f32,
	data:   [4]u32,
	// The scissor's pixels (target pixels x0, y0, x1, y1).
	clip:   [4]f32,
}

// An instance's motion as the shaders read it (`Shape_Motion` in
// shaders/shapes.glsl).
Shader_Motion :: [2][4]f32

// The instance as the shaders read it: `offset` is its shape's words'
// place in the words the shader reads, `frame_words` the frame's own, and
// `clip` its scissor's pixels.
shader_instance :: proc(inst: Shape_Instance, frame_words: []u32, offset: u32, clip: [4]f32) -> Shader_Instance {
	t := inst.transform
	epp := shape_ems_per_pixel(t) * instance_reach(inst)
	sb := Bounds{-1, -1, 1, 1}
	if inst.marker == .None {
		sb = instance_shape_bounds(inst, frame_words)
	}
	uv, data := shader_instance_inputs(inst, offset)
	return {
		m = {t[0], t[1], t[2], t[3]},
		t = {t[4], t[5], epp.x, epp.y},
		bounds = {sb.minx, sb.miny, sb.maxx, sb.maxy},
		uv = uv,
		data = data,
		clip = clip,
	}
}

// What the shape shaders take of an instance per pixel (shapes.glsl's
// flat inputs, data.w left 0): its pixel's footprint and its word offset,
// paint row and flags.
shader_instance_inputs :: proc "contextless" (inst: Shape_Instance, offset: u32) -> (uv: [4]f32, data: [4]u32) {
	u, v := instance_footprint(inst)
	flags: u32 = (1 if inst.rule == .Even_Odd else 0) | (2 if inst.edge == .Aliased else 0) | (4 if inst.edge == .Smooth else 0)
	// A hairline's width in place of the flags: a positive normal float,
	// whose exponent bits the shader tells from the flags by. Anything
	// narrower than the smallest normal float covers nothing anyway.
	if inst.hairline > 0 {
		flags = transmute(u32)max(inst.hairline, transmute(f32)u32(0x0080_0000))
	}
	// A marker: the unit square or circle, its kind where a shape's words
	// are (16 added when it is filled).
	at := offset
	if inst.marker != .None {
		at = u32(inst.marker) | (16 if inst.marker_fill else 0)
	}
	return {u.x, u.y, v.x, v.y}, {at, inst.paint, flags, 0}
}

shader_motion :: proc "contextless" (m: Shape_Motion) -> Shader_Motion {
	v := m.velocity
	return {{v[0], v[1], v[2], v[3]}, {v[4], v[5], m.nearness, 0}}
}

// A group's grid is at most this many cells a side; a group of markers'
// (small, many, often piled up) takes cells about a marker's size.
GROUP_MAX_CELLS :: 64
MARKER_MAX_CELLS :: 256

// group_grid's working memory, reused from group to group.
Group_Grid_Scratch :: struct {
	bounds: [dynamic]Bounds,
	spans:  [dynamic][4]i32,
	fill:   [dynamic]u32,
}

group_grid_scratch_destroy :: proc(s: ^Group_Grid_Scratch) {
	delete(s.bounds)
	delete(s.spans)
	delete(s.fill)
}

// A group's grid (`Cmd_Draw_Shapes.group`): cells about one instance in
// size over the instances' bounds (`area`, cells `cell` wide and high),
// each listing the instances whose bounds meet it, in order, so a pixel
// looks at the few near it. In the words from `head`: the columns and rows
// (nx | ny << 16), each cell's first list entry, one more for the end, then
// the lists (instances from the group's first).
Group_Grid :: struct {
	head:   int,
	area:   Bounds,
	cell:   [2]f32,
	nx, ny: int,
}

// Appends the grid of the group of `shapes` (a command's instances) to
// `words`, which grows geometrically as a frame's groups append.
group_grid :: proc(s: ^Group_Grid_Scratch, words: ^[dynamic]u32, shapes: []Shape_Instance, frame_words: []u32) -> (g: Group_Grid) {
	n := len(shapes)
	resize(&s.bounds, n)
	bounds := s.bounds[:]
	area := EMPTY_BOUNDS
	for inst, k in shapes {
		bounds[k] = instance_bounds(inst, frame_words)
		area = {min(area.minx, bounds[k].minx), min(area.miny, bounds[k].miny), max(area.maxx, bounds[k].maxx), max(area.maxy, bounds[k].maxy)}
	}
	w, h := max(area.maxx - area.minx, 1), max(area.maxy - area.miny, 1)
	side: f32
	for ib in bounds {
		side += (ib.maxx - ib.minx) + (ib.maxy - ib.miny)
	}
	side = max(side / f32(2 * n), 1)
	most := MARKER_MAX_CELLS if n > 0 && shapes[0].marker != .None else GROUP_MAX_CELLS
	nx := clamp(int(math.ceil(w / side)), 1, most)
	ny := clamp(int(math.ceil(h / side)), 1, most)
	cw, ch := w / f32(nx), h / f32(ny)
	cells :: proc(b: Bounds, area: Bounds, cw, ch: f32, nx, ny: int) -> (i0, j0, i1, j1: int) {
		i0 = clamp(int((b.minx - area.minx) / cw), 0, nx - 1)
		j0 = clamp(int((b.miny - area.miny) / ch), 0, ny - 1)
		i1 = clamp(int((b.maxx - area.minx) / cw), 0, nx - 1)
		j1 = clamp(int((b.maxy - area.miny) / ch), 0, ny - 1)
		return
	}
	grow :: proc(a: ^[dynamic]u32, n: int) {
		if n > cap(a) {
			reserve(a, max(n, 2 * cap(a)))
		}
		resize(a, n)
	}
	head := len(words)
	at := head + 1
	lists := at + nx * ny + 1
	grow(words, lists)
	words[head] = u32(nx) | u32(ny) << 16
	for k in at ..< lists {
		words[k] = 0
	}
	// Each member's cells, counted, then listed: the spans are clamped to the
	// grid and the lists sized by the counts, so the indices need no checks.
	resize(&s.spans, n)
	spans := s.spans[:]
	for ib, k in bounds {
		i0, j0, i1, j1 := cells(ib, area, cw, ch, nx, ny)
		spans[k] = {i32(i0), i32(j0), i32(i1), i32(j1)}
		for j in j0 ..= j1 {
			for i in i0 ..= i1 {
				#no_bounds_check words[at + j * nx + i + 1] += 1
			}
		}
	}
	for k in at ..< lists - 1 {
		words[k + 1] += words[k]
	}
	grow(words, lists + int(words[lists - 1]))
	resize(&s.fill, nx * ny)
	fill := s.fill[:]
	copy(fill, words[at:lists - 1])
	for sp, k in spans {
		for j in int(sp[1]) ..= int(sp[3]) {
			for i in int(sp[0]) ..= int(sp[2]) {
				#no_bounds_check {
					words[lists + int(fill[j * nx + i])] = u32(k)
					fill[j * nx + i] += 1
				}
			}
		}
	}
	return {head, area, {cw, ch}, nx, ny}
}

// Whether cell (i, j) of grid `g` in `words` lists any instance.
group_cell_listed :: #force_inline proc "contextless" (words: []u32, g: Group_Grid, i, j: int) -> bool {
	cell := g.head + 1 + j * g.nx + i
	return words[cell] != words[cell + 1]
}
