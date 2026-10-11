package ovg

// A rectangle with elliptical corners (SVG rect rx/ry). `ry` 0 means `rx`,
// `rx` 0 means `ry`; both are clamped to half the size.
path_rounded_rect_elliptic :: proc(p: ^Path, x, y, w, h, rx, ry: f32) {
	rx, ry := rx, ry
	if rx <= 0 {rx = ry}
	if ry <= 0 {ry = rx}
	rx = min(rx, abs(w) * 0.5)
	ry = min(ry, abs(h) * 0.5)
	if rx < 0.1 || ry < 0.1 {
		path_rect(p, x, y, w, h)
		return
	}
	if rx == ry {
		path_rounded_rect(p, x, y, w, h, rx)
		return
	}
	K :: 1 - KAPPA90
	path_move_to(p, x + rx, y)
	path_line_to(p, x + w - rx, y)
	path_bezier_to(p, x + w - rx * K, y, x + w, y + ry * K, x + w, y + ry)
	path_line_to(p, x + w, y + h - ry)
	path_bezier_to(p, x + w, y + h - ry * K, x + w - rx * K, y + h, x + w - rx, y + h)
	path_line_to(p, x + rx, y + h)
	path_bezier_to(p, x + rx * K, y + h, x, y + h - ry * K, x, y + h - ry)
	path_line_to(p, x, y + ry)
	path_bezier_to(p, x, y + ry * K, x + rx * K, y, x + rx, y)
	path_close(p)
}
