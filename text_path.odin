package ovg

import "core:math"
import "core:math/linalg"

// Text along a path (SVG textPath): a laid-out line's x becomes a distance
// along the path and its y an offset across it. Each glyph sits where its
// middle falls, turned to the path's direction there.

// A path measured for text: flattened, with each point's distance along
// the path (a move between contours adds none).
Text_Path :: struct {
	flat:  Flat_Path,
	along: [dynamic]f32,
}

Text_Path_Side :: enum u8 {
	Left,
	// Along the path reversed (SVG side="right").
	Right,
}

Text_Path_Options :: struct {
	// The distance along the path where x = 0 falls (SVG startOffset).
	start: f32,
	side:  Text_Path_Side,
}

text_path_init :: proc(tp: ^Text_Path, allocator := context.allocator) {
	flat_path_init(&tp.flat, allocator)
	tp.along = make([dynamic]f32, allocator)
}

text_path_destroy :: proc(tp: ^Text_Path) {
	flat_path_destroy(&tp.flat)
	delete(tp.along)
}

// Measures `p` for text, curves split into segments of about `segment`
// units (a glyph turns at each).
text_path_set :: proc(tp: ^Text_Path, p: ^Path, segment: f32 = 0.5) {
	text_path_set_verbs(tp, p.verbs[:], p.coords[:], segment)
}

// `text_path_set` of a path held as its verbs and coordinates.
text_path_set_verbs :: proc(tp: ^Text_Path, verbs: []Verb, coords: []Vec2, segment: f32 = 0.5) {
	path_flatten_verbs(verbs, coords, &tp.flat, segment)
	resize(&tp.along, len(tp.flat.points))
	d: f32
	for ct in tp.flat.contours {
		pts := tp.flat.points[ct.first:][:ct.count]
		along := tp.along[ct.first:][:ct.count]
		along[0] = d
		for k in 1 ..< len(pts) {
			d += linalg.length(pts[k] - pts[k - 1])
			along[k] = d
		}
	}
}

// The path's length.
text_path_length :: proc(tp: ^Text_Path) -> f32 {
	return tp.along[len(tp.along) - 1] if len(tp.along) > 0 else 0
}

// The point `d` along the path and the path's direction there (unit); not
// ok off either end.
text_path_at :: proc(tp: ^Text_Path, d: f32) -> (p, dir: Vec2, ok: bool) {
	n := len(tp.along)
	if n < 2 || d < 0 || d > tp.along[n - 1] {
		return
	}
	// The last point at or before d starts its segment (at a move between
	// contours, the next contour's first point); the end takes the last
	// segment.
	lo, hi := 0, n - 1
	for lo < hi {
		mid := (lo + hi + 1) / 2
		if tp.along[mid] <= d {
			lo = mid
		} else {
			hi = mid - 1
		}
	}
	i := min(lo, n - 2)
	a, b := tp.flat.points[i], tp.flat.points[i + 1]
	length := tp.along[i + 1] - tp.along[i]
	if length <= 0 {
		return
	}
	dir = (b - a) / length
	return a + dir * (d - tp.along[i]), dir, true
}

// Places the glyphs of `l` (laid out from x = 0, y = 0) along the path:
// each glyph's origin moves onto it and `l.turns` takes its direction (cos,
// sin), a glyph whose middle falls off the path getting {0, 0} (it isn't
// drawn). Drawing turns each glyph about its origin; `text_layout_path`
// follows the turns, and the layout's extent covers the turned glyphs.
text_layout_on_path :: proc(l: ^Text_Layout, tp: ^Text_Path, opts: Text_Path_Options) {
	resize(&l.turns, len(l.glyphs))
	total := text_path_length(tp)
	l.min, l.max = {math.F32_MAX, math.F32_MAX}, {-math.F32_MAX, -math.F32_MAX}
	for run in l.runs {
		font := text_layout_font(l, run)
		asc, desc := font_extent(font, run.em)
		for &g, k in l.glyphs[run.first:][:run.count] {
			turn := &l.turns[run.first + k]
			adv, _ := font_glyph_advance(font, g.glyph)
			half := f32(adv) * run.em * 0.5
			d := opts.start + g.x + half
			if opts.side == .Right {
				d = total - d
			}
			p, dir, ok := text_path_at(tp, d)
			if !ok {
				turn^ = {}
				continue
			}
			if opts.side == .Right {
				dir = -dir
			}
			// Across the path: y down when the path runs right.
			across := Vec2{-dir.y, dir.x}
			o := p - dir * half + across * g.y
			g.x, g.y = o.x, o.y
			turn^ = dir
			for corner in ([4]Vec2{{0, -asc}, {2 * half, -asc}, {0, desc}, {2 * half, desc}}) {
				q := o + dir * corner.x + across * corner.y
				l.min = {min(l.min.x, q.x), min(l.min.y, q.y)}
				l.max = {max(l.max.x, q.x), max(l.max.y, q.y)}
			}
		}
	}
	if l.min.x > l.max.x {
		l.min, l.max = {}, {}
	}
}
