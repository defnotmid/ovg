package ovg

// Skyline bottom-left rectangle packer. Port of femtovg's `text/atlas.rs`.

Atlas_Node :: struct {
	x, y, width: u32,
}

Atlas :: struct {
	width, height: u32,
	nodes:         [dynamic]Atlas_Node,
}

atlas_init :: proc(a: ^Atlas, width, height: u32, allocator := context.allocator) {
	a.width = width
	a.height = height
	a.nodes = make([dynamic]Atlas_Node, allocator)
	append(&a.nodes, Atlas_Node{0, 0, width})
}

atlas_destroy :: proc(a: ^Atlas) {
	delete(a.nodes)
	a^ = {}
}

atlas_reset :: proc(a: ^Atlas, width, height: u32) {
	clear(&a.nodes)
	append(&a.nodes, Atlas_Node{0, 0, width})
	a.width = width
	a.height = height
}

atlas_expand :: proc(a: ^Atlas, width, height: u32) {
	if width > a.width {
		append(&a.nodes, Atlas_Node{a.width, 0, width - a.width})
	}
	a.width = width
	a.height = height
}

// Top-left corner of a free `w x h` area, or `ok = false` when full.
atlas_add_rect :: proc(a: ^Atlas, w, h: u32) -> (x, y: u32, ok: bool) {
	best_h := a.height
	best_w := a.width
	best_i := -1
	for i in 0 ..< len(a.nodes) {
		if fy, fits := atlas_rect_fits(a, i, w, h); fits {
			if fy + h < best_h || (fy + h == best_h && a.nodes[i].width < best_w) {
				best_i = i
				best_w = a.nodes[i].width
				best_h = fy + h
				x = a.nodes[i].x
				y = fy
			}
		}
	}
	if best_i < 0 {
		return 0, 0, false
	}
	atlas_add_skyline_level(a, best_i, x, y, w, h)
	return x, y, true
}

@(private = "file")
atlas_add_skyline_level :: proc(a: ^Atlas, idx: int, x, y, w, h: u32) {
	inject_at(&a.nodes, idx, Atlas_Node{x, y + h, w})

	// Shrink or drop the nodes now under the new one.
	for i := idx + 1; i < len(a.nodes); {
		prev := a.nodes[i - 1]
		node := &a.nodes[i]
		if node.x >= prev.x + prev.width {
			break
		}
		shrink := prev.x + prev.width - node.x
		if node.width <= shrink {
			ordered_remove(&a.nodes, i)
			continue
		}
		node.x += shrink
		node.width -= shrink
		break
	}

	// Merge neighbours at the same height.
	for j := 0; j + 1 < len(a.nodes); {
		if a.nodes[j].y == a.nodes[j + 1].y {
			a.nodes[j].width += a.nodes[j + 1].width
			ordered_remove(&a.nodes, j + 1)
		} else {
			j += 1
		}
	}
}

@(private = "file")
atlas_rect_fits :: proc(a: ^Atlas, start: int, w, h: u32) -> (u32, bool) {
	x := a.nodes[start].x
	y := a.nodes[start].y
	if x + w > a.width {
		return 0, false
	}
	space_left := i64(w)
	for i := start; space_left > 0; i += 1 {
		if i >= len(a.nodes) {
			return 0, false
		}
		y = max(y, a.nodes[i].y)
		if y + h > a.height {
			return 0, false
		}
		space_left -= i64(a.nodes[i].width)
	}
	return y, true
}
