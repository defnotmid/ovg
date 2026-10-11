package ovg

// Multiplies the paint's alpha (colors, gradient stops, image tint) by `a`.
paint_mul_alpha :: proc "contextless" (p: ^Paint, a: f32) {
	flavor_mul_alpha(&p.flavor, a)
}
