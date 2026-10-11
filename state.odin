package ovg

// Scissor rectangle in its own coordinate system: centered at the origin of
// `transform` with half-size `extent`.
Scissor :: struct {
	transform:  Transform2D,
	extent:     [2]f32,
	has_extent: bool,
}

// The equivalent screen rectangle if the scissor is axis-aligned and
// unscaled. With no scissor this is the whole target.
scissor_as_rect :: proc "contextless" (s: Scissor, canvas_w, canvas_h: f32) -> (Rect, bool) {
	if !s.has_extent {
		return {0, 0, canvas_w, canvas_h}, true
	}
	m := s.transform
	if m[1] != 0 || m[2] != 0 || m[0] != 1 || m[3] != 1 {
		return {}, false
	}
	hw, hh := s.extent[0], s.extent[1]
	return {m[4] - hw, m[5] - hh, hw * 2, hh * 2}, true
}

// Everything `save` / `restore` manage.
State :: struct {
	composite_operation: Composite_Operation_State,
	transform:           Transform2D,
	scissor:             Scissor,
	alpha:               f32,
}

default_state :: proc "contextless" () -> State {
	return {
		composite_operation = composite_state_from_op(.Source_Over),
		transform = TRANSFORM_IDENTITY,
		scissor = {transform = TRANSFORM_IDENTITY},
		alpha = 1,
	}
}
