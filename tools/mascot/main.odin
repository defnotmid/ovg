// The ovg mascot: a 32x32 pixel-art chameleon on a branch, in the family of
// onimite's Pip, odecs' turntable and ottis' Ottis. A chameleon because ovg
// is fills, gradients and curves: its colour changes, its tail is a spiral
// path and its tongue is a curve. Writes an SVG whose parts are groups a
// script shows or hides by id (onimite: svg{ overrides = { tongue = { visible = true } } }):
//
//   body          outline, skin, bands, crest, legs, the spiral tail and the
//                 branch (on)
//   skin_pink     the same chameleon blushing pink (off): show it over body
//   skin_blue     ... and cool blue (off)
//   eye_open      the turret eye looking ahead (on)
//   eye_back      looking back over its shoulder, as chameleons do (off)
//   eye_closed    a happy blink (off)
//   mouth_smile   a long smile (on)          mouth_open  open for the tongue (off)
//   tongue        the tongue out and curling up to a sticky tip (off)
//   silhouette    every visible pixel as one outline (off): the shape to
//                 morph, extrude or collide (svg_element_path by id)
//
// Each layer is one path per colour, its pixels traced into merged outlines.
//
// Also writes the project logo as PNGs, scaled without smoothing:
//
//   odin run tools/mascot -- assets   (assets/logo.svg, logo.png 256 px, logo_32x32.png)
package mascot

import "core:fmt"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strings"
import stbi "vendor:stb/image"

W :: 32
H :: 32

Grid :: [H][W]u8 // palette keys, '.' empty

Skin :: enum {
	Green,
	Pink,
	Blue,
}

// Skin colours (B body, D shade, H highlight, S bands) for each skin; the
// rest of the palette is shared.
skin_color :: proc(skin: Skin, c: u8) -> (string, bool) {
	switch skin {
	case .Green:
		switch c {
		case 'B': return "#56c25a", true
		case 'D': return "#2f8a43", true
		case 'H': return "#a6ec74", true
		case 'S': return "#f6d24a", true
		}
	case .Pink:
		switch c {
		case 'B': return "#f2708f", true
		case 'D': return "#b83d64", true
		case 'H': return "#ffb3c4", true
		case 'S': return "#ffe08a", true
		}
	case .Blue:
		switch c {
		case 'B': return "#4aa8f0", true
		case 'D': return "#2b64b8", true
		case 'H': return "#9fe0ff", true
		case 'S': return "#5eead4", true
		}
	}
	return "", false
}

color :: proc(skin: Skin, c: u8) -> string {
	if s, ok := skin_color(skin, c); ok do return s
	switch c {
	case 'O': return "#17261d" // outline
	case 'E': return "#1b1220" // pupil
	case 'W': return "#ffffff" // shine
	case 'K': return "#ff9db4" // cheek
	case 'M': return "#5a1f24" // mouth
	case 'T': return "#ff6f91" // tongue
	case 't': return "#d94470" // tongue shade
	case 'R': return "#8a5a33" // branch
	case 'r': return "#5e3b20" // branch shade
	case 'L': return "#3fa34d" // leaf
	}
	return "#ff00ff"
}

empty :: proc() -> (g: Grid) {
	for &row in g do for &p in row do p = '.'
	return
}

put :: proc(g: ^Grid, x, y: int, c: u8) {
	if 0 <= x && x < W && 0 <= y && y < H do g[y][x] = c
}

in_ellipse :: proc(x, y: int, cx, cy, rx, ry: f64) -> (bool, f64, f64) {
	u := (f64(x) + 0.5 - cx) / rx
	v := (f64(y) + 0.5 - cy) / ry
	return u * u + v * v <= 1, u, v
}

// Fills an ellipse: shade along the lower rim, highlight upper left.
skin :: proc(g: ^Grid, cx, cy, rx, ry: f64) {
	for y in 0 ..< H do for x in 0 ..< W {
		inside, u, v := in_ellipse(x, y, cx, cy, rx, ry)
		if !inside do continue
		c := u8('B')
		if u * u + v * v > 0.55 && u * 0.3 + v * 0.95 > 0.4 do c = 'D'
		else if u * u + v * v > 0.45 && u * 0.4 + v * 0.9 < -0.55 do c = 'H'
		put(g, x, y, c)
	}
}

in_triangle :: proc(x, y: int, a, b, c: [2]f64) -> bool {
	p := [2]f64{f64(x) + 0.5, f64(y) + 0.5}
	side :: proc(p, a, b: [2]f64) -> f64 {return (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)}
	d1, d2, d3 := side(p, a, b), side(p, b, c), side(p, c, a)
	return !((d1 < 0 || d2 < 0 || d3 < 0) && (d1 > 0 || d2 > 0 || d3 > 0))
}

// Outlines every filled pixel's empty 4-neighbours.
outline :: proc(g: ^Grid) {
	src := g^
	for y in 0 ..< H do for x in 0 ..< W {
		if src[y][x] != '.' do continue
		for d in ([4][2]int{{1, 0}, {-1, 0}, {0, 1}, {0, -1}}) {
			nx, ny := x + d.x, y + d.y
			if 0 <= nx && nx < W && 0 <= ny && ny < H && src[ny][nx] != '.' && src[ny][nx] != 'O' {
				g[y][x] = 'O'
				break
			}
		}
	}
}

// Draws `fg` over `g`, outlining fg's shapes against everything else.
over :: proc(g: ^Grid, fg: Grid) {
	shape := fg
	outline(&shape)
	for y in 0 ..< H do for x in 0 ..< W do if shape[y][x] != '.' do g[y][x] = shape[y][x]
}

draw_body :: proc() -> Grid {
	g := empty()

	// The branch along the bottom, a leaf sprouting on the left.
	branch := empty()
	for x in 0 ..< W do for y in 27 ..< 29 do put(&branch, x, y, 'r' if y == 28 || (x * 7) % 11 == 0 else 'R')
	for p in ([?][2]int{{1, 26}, {2, 25}, {2, 26}, {3, 25}, {3, 24}, {4, 24}}) do put(&branch, p.x, p.y, 'L')
	over(&g, branch)

	// The tail: a spiral curled under the body, one turn round a gap, then
	// a curl in the middle.
	tail := empty()
	for y in 0 ..< H do for x in 0 ..< W {
		dx := f64(x) + 0.5 - 5.6
		dy := f64(y) + 0.5 - 22.4
		r := math.sqrt(dx * dx + dy * dy)
		if r <= 4.3 && r >= 2.9 && !(dx > 1.2 && dy < -0.5) do put(&tail, x, y, 'B' if dy < 0.5 else 'D')
	}
	for p in ([?][2]int{{5, 22}, {6, 22}, {5, 21}}) do put(&tail, p.x, p.y, 'B')
	over(&g, tail)

	// Legs gripping the branch.
	legs := empty()
	for leg in ([2]int{10, 20}) {
		for y in 22 ..< 27 do for x in leg ..< leg + 2 do put(&legs, x, y, 'D' if x == leg + 1 else 'B')
		put(&legs, leg - 1, 26, 'D')
		put(&legs, leg + 2, 26, 'D')
	}
	over(&g, legs)

	// The body, a long oval, with a crest of points along the back and
	// yellow bands across it.
	body := empty()
	skin(&body, 15.3, 19.0, 8.6, 5.4)
	for x := 9; x <= 21; x += 2 {
		for y in 0 ..< H {
			if body[y][x] != '.' {
				put(&body, x, y - 1, 'D')
				break
			}
		}
	}
	// bands slanting back, across the lit part of the skin
	for y in 0 ..< H do for x in 0 ..< W {
		if body[y][x] != 'B' && body[y][x] != 'H' do continue
		if x < 9 || x > 21 do continue
		if (x + y / 2) % 5 < 2 do put(&body, x, y, 'S')
	}
	over(&g, body)

	// The head: a rounded snout, a casque rising behind it, a cheek.
	head := empty()
	skin(&head, 24.2, 16.2, 5.8, 4.7)
	for y in 0 ..< H do for x in 0 ..< W {
		if in_triangle(x, y, {18.8, 15.5}, {21.8, 9.2}, {27.4, 13.8}) do put(&head, x, y, 'H' if y < 12 else 'B')
	}
	put(&head, 27, 18, 'K')
	put(&head, 28, 18, 'K')
	over(&g, head)

	// The turret eye: a cone of skin with a ring around the pupil.
	eye := empty()
	for y in 0 ..< H do for x in 0 ..< W {
		inside, u, v := in_ellipse(x, y, 24.6, 14.4, 2.9, 2.9)
		if inside do put(&eye, x, y, 'H' if u + v < -0.7 else 'B')
	}
	over(&g, eye)
	return g
}

// A skin's own copy of the body: every skin pixel in the other colours.
// Drawn as its own layer so the whole chameleon can change colour.
skin_layer :: proc(body: Grid) -> Grid {
	g := empty()
	for y in 0 ..< H do for x in 0 ..< W {
		switch body[y][x] {
		case 'B', 'D', 'H', 'S': g[y][x] = body[y][x]
		}
	}
	return g
}

draw_eyes :: proc() -> (ahead, back, closed: Grid) {
	ahead, back, closed = empty(), empty(), empty()
	for p in ([?][2]int{{25, 14}, {26, 14}, {25, 15}, {26, 15}}) do put(&ahead, p.x, p.y, 'E')
	put(&ahead, 25, 14, 'W')
	for p in ([?][2]int{{23, 13}, {24, 13}, {23, 14}, {24, 14}}) do put(&back, p.x, p.y, 'E')
	put(&back, 24, 13, 'W')
	for p in ([?][2]int{{23, 15}, {24, 14}, {25, 14}, {26, 15}}) do put(&closed, p.x, p.y, 'E')
	return
}

draw_mouths :: proc() -> (smile, open: Grid) {
	smile, open = empty(), empty()
	// a long line from the snout back under the cheek, curling up at the end
	for p in ([?][2]int{{29, 18}, {28, 19}, {27, 19}, {26, 19}, {25, 19}, {24, 18}}) do put(&smile, p.x, p.y, 'M')
	for p in ([?][2]int{{29, 18}, {28, 18}, {28, 19}, {27, 19}, {26, 19}, {29, 19}}) do put(&open, p.x, p.y, 'M')
	put(&open, 28, 18, 'T')
	return
}

// The tongue: out of the mouth and curling up the right edge to a round,
// sticky tip, as a curve would.
draw_tongue :: proc() -> Grid {
	g := empty()
	for p in ([?][2]int{{30, 18}, {31, 17}, {31, 16}, {30, 15}, {30, 14}, {30, 13}, {31, 12}, {31, 11}}) do put(&g, p.x, p.y, 'T')
	for p in ([?][2]int{{29, 8}, {30, 8}, {31, 8}, {29, 9}, {30, 9}, {31, 9}, {30, 10}, {30, 7}}) do put(&g, p.x, p.y, 'T')
	put(&g, 31, 9, 't')
	put(&g, 30, 10, 't')
	put(&g, 29, 8, 'W')
	return g
}

Layer :: struct {
	name: string,
	grid: Grid,
	on:   bool,
	skin: Skin,
}

// Each layer's pixels of one colour as one path, and the visible layers'
// union as `silhouette` (off): the whole chameleon as one outline, for
// morphing, extruding or colliding (ovg svg_element_path(doc, &p, "silhouette")).
svg :: proc(layers: []Layer) -> string {
	b := strings.builder_make()
	fmt.sbprintf(&b, `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 %d %d" width="%d" height="%d" shape-rendering="crispEdges">`, W, H, W * 8, H * 8)
	strings.write_byte(&b, '\n')
	for l in layers {
		fmt.sbprintf(&b, `<g id="%s"%s>`, l.name, "" if l.on else ` display="none"`)
		done: [256]bool
		for y in 0 ..< H do for x in 0 ..< W {
			c := l.grid[y][x]
			if c == '.' || done[c] do continue
			done[c] = true
			mask: Mask
			for yy in 0 ..< H do for xx in 0 ..< W do mask[yy][xx] = l.grid[yy][xx] == c
			fmt.sbprintf(&b, `<path fill="%s" d="`, color(l.skin, c))
			trace(&b, &mask)
			strings.write_string(&b, `"/>`)
		}
		strings.write_string(&b, "</g>\n")
	}
	all: Mask
	for l in layers {
		if !l.on do continue
		for y in 0 ..< H do for x in 0 ..< W do all[y][x] ||= l.grid[y][x] != '.'
	}
	strings.write_string(&b, `<g id="silhouette" display="none"><path fill="#17261d" d="`)
	trace(&b, &all)
	strings.write_string(&b, "\"/></g>\n</svg>\n")
	return strings.to_string(b)
}

Mask :: [H][W]bool

// Writes the outline of the mask's pixels as path data: one closed loop per
// boundary, the pixels on its right (clockwise on screen), so holes wind the
// other way and fill as holes under either fill rule. Straight runs are
// single segments; pixels touching only at a corner stay apart.
trace :: proc(b: ^strings.Builder, m: ^Mask) {
	V :: (W + 1) * (H + 1)
	at :: proc(m: ^Mask, x, y: int) -> bool {return x >= 0 && y >= 0 && x < W && y < H && m[y][x]}
	// Boundary edges by start vertex (at most two: pixels touching at a corner).
	out: [V][2]i32
	n: [V]int
	add :: proc(out: ^[V][2]i32, n: ^[V]int, x0, y0, x1, y1: int) {
		v := y0 * (W + 1) + x0
		out[v][n[v]] = i32(y1 * (W + 1) + x1)
		n[v] += 1
	}
	for y in 0 ..< H do for x in 0 ..< W {
		if !m[y][x] do continue
		if !at(m, x, y - 1) do add(&out, &n, x, y, x + 1, y)
		if !at(m, x + 1, y) do add(&out, &n, x + 1, y, x + 1, y + 1)
		if !at(m, x, y + 1) do add(&out, &n, x + 1, y + 1, x, y + 1)
		if !at(m, x - 1, y) do add(&out, &n, x, y + 1, x, y)
	}
	xy :: proc(v: i32) -> [2]int {return {int(v) % (W + 1), int(v) / (W + 1)}}
	for start in 0 ..< V {
		for n[start] > 0 {
			// Walk the loop, writing a point where the direction changes.
			pts: [dynamic][2]int
			defer delete(pts)
			v := i32(start)
			dir: [2]int
			for {
				k := 0
				if n[v] == 2 {
					// At a corner touch, turn right: keep to the pixels on the right.
					right := [2]int{-dir.y, dir.x}
					for j in 0 ..< 2 {
						if len(pts) > 0 && xy(out[v][j]) - xy(v) == right do k = j
					}
				}
				next := out[v][k]
				out[v][k] = out[v][n[v] - 1]
				n[v] -= 1
				d := xy(next) - xy(v)
				if len(pts) == 0 || d != dir do append(&pts, xy(v))
				dir = d
				v = next
				if v == i32(start) do break
			}
			fmt.sbprintf(b, "M%d %d", pts[0].x, pts[0].y)
			for p, i in pts[1:] {
				prev := pts[i]
				if p.y == prev.y do fmt.sbprintf(b, "H%d", p.x)
				else do fmt.sbprintf(b, "V%d", p.y)
			}
			strings.write_byte(b, 'Z')
		}
	}
}

hex_byte :: proc(s: string) -> u8 {
	v: u8
	for c in transmute([]u8)s {
		v <<= 4
		switch c {
		case '0' ..= '9': v |= c - '0'
		case 'a' ..= 'f': v |= c - 'a' + 10
		}
	}
	return v
}

// The visible layers flattened, scaled by `scale` without smoothing.
png :: proc(path: string, layers: []Layer, scale: int) -> bool {
	size := W * scale
	pixels := make([]u8, size * size * 4)
	defer delete(pixels)
	for l in layers {
		if !l.on do continue
		for y in 0 ..< H do for x in 0 ..< W {
			c := l.grid[y][x]
			if c == '.' do continue
			hex := color(l.skin, c)
			rgba := [4]u8{hex_byte(hex[1:3]), hex_byte(hex[3:5]), hex_byte(hex[5:7]), 255}
			for dy in 0 ..< scale do for dx in 0 ..< scale {
				i := ((y * scale + dy) * size + x * scale + dx) * 4
				pixels[i + 0], pixels[i + 1], pixels[i + 2], pixels[i + 3] = rgba[0], rgba[1], rgba[2], rgba[3]
			}
		}
	}
	return stbi.write_png(strings.clone_to_cstring(path, context.temp_allocator), i32(size), i32(size), 4, raw_data(pixels), i32(size * 4)) != 0
}

main :: proc() {
	dir := os.args[1] if len(os.args) > 1 else "assets"
	body := draw_body()
	skins := skin_layer(body)
	eye_open, eye_back, eye_closed := draw_eyes()
	mouth_smile, mouth_open := draw_mouths()
	layers := []Layer {
		{"body", body, true, .Green},
		{"skin_pink", skins, false, .Pink},
		{"skin_blue", skins, false, .Blue},
		{"eye_open", eye_open, true, .Green},
		{"eye_back", eye_back, false, .Green},
		{"eye_closed", eye_closed, false, .Green},
		{"mouth_smile", mouth_smile, true, .Green},
		{"mouth_open", mouth_open, false, .Green},
		{"tongue", draw_tongue(), false, .Green},
	}
	join :: proc(dir, name: string) -> string {
		p, _ := filepath.join({dir, name}, context.temp_allocator)
		return p
	}
	if err := os.write_entire_file(join(dir, "logo.svg"), svg(layers)); err != nil {
		fmt.eprintfln("writing %s: %v", join(dir, "logo.svg"), err)
		os.exit(1)
	}
	if !png(join(dir, "logo.png"), layers, 8) || !png(join(dir, "logo_32x32.png"), layers, 1) {
		fmt.eprintln("writing the PNGs failed")
		os.exit(1)
	}
}
