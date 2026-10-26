// Renders SVG test files with the software backend and compares them with
// their reference PNGs (resvg test suite layout: `name.svg` next to
// `name.png`, rendered at the PNG's size). Prints a pass rate per
// directory. A pixel differs when a premultiplied channel is off by more
// than `-tol` (8-bit); a test passes when at most `-frac` of its pixels
// differ.
//
//     odin run tools/svg_suite -collection:deps=.. -o:speed -- [-tol:24] [-frac:0.01] [-fonts:dir] [-dump:dir] [-v] dir_or_svg...
//     odin run tools/svg_suite -collection:deps=.. -o:speed -- -bench:file.svg [-n:20]
//
// `-dump:dir` writes the failing renders there (for debugging; keep it out
// of the repository). `-bench` times parsing, recording (draw calls on a
// recording canvas) and a full software render of one file.
package svg_suite

import "core:fmt"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"
import image "deps:odecs/image"

import "../../svg"
import vg "../.."

Options :: struct {
	tol:   int,
	frac:  f64,
	dump:  string,
	verbose: bool,
	// Dumped renders are named relative to this.
	root:    string,
}

Result :: struct {
	category: string,
	name:     string,
	passed:   bool,
	diff:     f64,
}

Loader :: struct {
	dir: string,
}

load_file :: proc(user: rawptr, href: string, allocator: mem.Allocator) -> (data: []u8, ok: bool) {
	l := (^Loader)(user)
	path, _ := filepath.join({l.dir, href}, context.temp_allocator)
	bytes, err := os.read_entire_file(path, allocator)
	return bytes, err == nil
}

main :: proc() {
	opts := Options{tol = 24, frac = 0.01}
	inputs := make([dynamic]string)
	fonts_dir := ""
	bench := ""
	bench_n := 20
	for a in os.args[1:] {
		switch {
		case strings.has_prefix(a, "-tol:"):
			opts.tol, _ = strconv.parse_int(a[5:])
		case strings.has_prefix(a, "-frac:"):
			opts.frac, _ = strconv.parse_f64(a[6:])
		case strings.has_prefix(a, "-fonts:"):
			fonts_dir = a[7:]
		case strings.has_prefix(a, "-root:"):
			opts.root = a[6:]
		case strings.has_prefix(a, "-dump:"):
			opts.dump = a[6:]
		case strings.has_prefix(a, "-bench:"):
			bench = a[7:]
		case strings.has_prefix(a, "-n:"):
			bench_n, _ = strconv.parse_int(a[3:])
		case a == "-v":
			opts.verbose = true
		case:
			append(&inputs, a)
		}
	}

	fonts: vg.Font_Collection
	fallback: []u8
	if fonts_dir != "" {
		fb_path, _ := filepath.join({fonts_dir, "NotoSans-Regular.ttf"}, context.temp_allocator)
		fallback, _ = os.read_entire_file(fb_path, context.allocator)
	}
	vg.font_collection_init(&fonts, fallback)
	defer vg.font_collection_destroy(&fonts)
	if fonts_dir != "" {
		infos, _ := os.read_all_directory_by_path(fonts_dir, context.allocator)
		slice.sort_by(infos, proc(a, b: os.File_Info) -> bool {return a.name < b.name})
		for fi in infos {
			ext := strings.to_lower(filepath.ext(fi.name), context.temp_allocator)
			if ext == ".ttf" || ext == ".otf" {
				data, err := os.read_entire_file(fi.fullpath, context.allocator)
				if err == nil {
					vg.font_collection_add(&fonts, data)
				}
			}
		}
	}

	if bench != "" {
		run_bench(bench, bench_n, &fonts)
		return
	}

	files := make([dynamic]string)
	for in_path in inputs {
		collect(in_path, &files)
	}
	slice.sort(files[:])

	sw: vg.Software_Backend
	vg.software_backend_init(&sw)
	defer vg.software_backend_destroy(&sw)
	c: vg.Canvas
	vg.canvas_init(&c, vg.software_backend(&sw))
	defer vg.canvas_destroy(&c)
	ls: vg.Layer_Stack
	defer vg.layer_stack_destroy(&ls, &c)
	r: svg.Renderer
	defer svg.renderer_destroy(&r, &c)

	results := make([dynamic]Result)
	root := ""
	if len(inputs) == 1 {
		root, _ = filepath.abs(inputs[0])
	}
	if opts.root == "" {
		opts.root = root
	}
	for f in files {
		res := run_one(f, &c, &sw, &ls, &r, &fonts, opts)
		rel := f
		if root != "" {
			rel, _ = filepath.rel(root, f)
		}
		res.category = filepath.dir(rel)
		res.name = filepath.stem(rel)
		append(&results, res)
		if opts.verbose || !res.passed {
			fmt.printfln("%s %s/%s (%.2f%%)", "ok  " if res.passed else "FAIL", res.category, res.name, res.diff * 100)
		}
		free_all(context.temp_allocator)
	}

	// Per category, then per top-level directory.
	Tally :: struct {
		pass, total: int,
	}
	cats := make(map[string]Tally)
	tops := make(map[string]Tally)
	for res in results {
		t := cats[res.category]
		t.total += 1
		t.pass += int(res.passed)
		cats[res.category] = t
		top := res.category
		if i := strings.index_byte(top, '/'); i >= 0 {
			top = top[:i]
		}
		tt := tops[top]
		tt.total += 1
		tt.pass += int(res.passed)
		tops[top] = tt
	}
	keys := make([dynamic]string)
	for k in cats {
		append(&keys, k)
	}
	slice.sort(keys[:])
	fmt.println()
	for k in keys {
		t := cats[k]
		fmt.printfln("  %-40s %3d/%3d  %5.1f%%", k, t.pass, t.total, 100 * f64(t.pass) / f64(t.total))
	}
	clear(&keys)
	for k in tops {
		append(&keys, k)
	}
	slice.sort(keys[:])
	all: Tally
	fmt.println()
	for k in keys {
		t := tops[k]
		all.pass += t.pass
		all.total += t.total
		fmt.printfln("%-42s %4d/%4d  %5.1f%%", k, t.pass, t.total, 100 * f64(t.pass) / f64(t.total))
	}
	fmt.printfln("%-42s %4d/%4d  %5.1f%%  (tol %d/255, at most %.1f%% pixels off)", "total", all.pass, all.total, 100 * f64(all.pass) / f64(max(all.total, 1)), opts.tol, opts.frac * 100)
}

collect :: proc(path: string, files: ^[dynamic]string) {
	if strings.has_suffix(path, ".svg") {
		append(files, strings.clone(path))
		return
	}
	infos, err := os.read_all_directory_by_path(path, context.allocator)
	if err != nil {
		return
	}
	for fi in infos {
		if fi.type == .Directory {
			collect(fi.fullpath, files)
		} else if strings.has_suffix(fi.name, ".svg") {
			png := strings.concatenate({fi.fullpath[:len(fi.fullpath) - 4], ".png"}, context.temp_allocator)
			if os.exists(png) {
				append(files, strings.clone(fi.fullpath))
			}
		}
	}
}

run_one :: proc(svg_path: string, c: ^vg.Canvas, sw: ^vg.Software_Backend, ls: ^vg.Layer_Stack, r: ^svg.Renderer, fonts: ^vg.Font_Collection, opts: Options) -> (res: Result) {
	png_path := strings.concatenate({svg_path[:len(svg_path) - 4], ".png"}, context.temp_allocator)
	png, perr := os.read_entire_file(png_path, context.temp_allocator)
	if perr != nil {
		return
	}
	ref_img, ierr := image.decode(png)
	if ierr != nil {
		return
	}
	defer image.destroy_image(&ref_img)
	ref := ref_img.pixels
	w, h := u32(ref_img.width), u32(ref_img.height)

	data, err := os.read_entire_file(svg_path, context.allocator)
	if err != nil {
		return
	}
	defer delete(data)
	loader := Loader{filepath.dir(svg_path)}
	doc, perr2 := svg.parse(data, {load_file = load_file, user = &loader, fonts = fonts})
	defer svg.destroy(&doc)
	text: svg.Layout
	svg.layout(&doc, fonts, &text)
	defer svg.layout_destroy(&text)
	svg.renderer_bind(r, c, &doc)

	vg.set_size(c, w, h)
	vg.reset(c)
	vg.clear_rect(c, 0, 0, w, h, vg.TRANSPARENT)
	if perr2 == .None && doc.width > 0 && doc.height > 0 {
		vg.layer_stack_begin(ls, c, w, h, nil, doc.uses_blend)
		svg.draw(c, ls, r, &doc, &text, vg.transform_scaling(f32(w) / doc.width, f32(h) / doc.height))
		vg.layer_stack_end(ls, c)
	}
	vg.flush(c)
	svg.renderer_unbind(r, c)
	px := sw.pixels
	refpx := ref[:w * h * 4]
	off := 0
	for i := 0; i < int(w * h); i += 1 {
		a := u32(refpx[i * 4 + 3])
		worst := 0
		for k in 0 ..< 4 {
			rv := int(refpx[i * 4 + k])
			if k < 3 {
				rv = int((u32(rv) * a + 127) / 255)
			}
			d := abs(rv - int(px[i * 4 + k]))
			worst = max(worst, d)
		}
		if worst > opts.tol {
			off += 1
		}
	}
	res.diff = f64(off) / f64(w * h)
	res.passed = res.diff <= opts.frac
	if !res.passed && opts.dump != "" {
		os.make_directory(opts.dump)
		name := strings.concatenate({opts.dump, "/", flat_name(opts.root, svg_path), ".png"}, context.temp_allocator)
		image.write_png(name, px, int(w), int(h))
	}
	if opts.verbose && len(doc.warnings) > 0 {
		for wmsg in doc.warnings {
			fmt.printfln("    warning: %s", wmsg)
		}
	}
	return
}

run_bench :: proc(path: string, n: int, fonts: ^vg.Font_Collection) {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		fmt.eprintln("can't read", path)
		os.exit(1)
	}
	loader := Loader{filepath.dir(path)}
	popts := svg.Parse_Options{load_file = load_file, user = &loader, fonts = fonts}
	parse_best := max(f64)
	doc: svg.Document
	for i in 0 ..< n {
		t0 := time.tick_now()
		d, perr := svg.parse(data, popts)
		dt := time.duration_milliseconds(time.tick_since(t0))
		if perr != .None {
			fmt.eprintln("parse failed:", perr)
			os.exit(1)
		}
		parse_best = min(parse_best, dt)
		if i == n - 1 {
			doc = d
		} else {
			svg.destroy(&d)
		}
	}
	defer svg.destroy(&doc)
	w := u32(1000)
	h := u32(f32(w) * doc.height / doc.width)
	xf := vg.transform_scaling(f32(w) / doc.width, f32(h) / doc.height)

	// Recording: the CPU side of drawing (shapes, commands).
	rc: vg.Canvas
	vg.canvas_init_recording(&rc)
	defer vg.canvas_destroy(&rc)
	rls: vg.Layer_Stack
	defer vg.layer_stack_destroy(&rls, &rc)
	rr: svg.Renderer
	defer svg.renderer_destroy(&rr, &rc)
	svg.renderer_bind(&rr, &rc, &doc)
	text: svg.Layout
	svg.layout(&doc, fonts, &text)
	defer svg.layout_destroy(&text)
	frame: vg.Recorded_Frame
	defer vg.recorded_frame_destroy(&frame)
	record_best := max(f64)
	for _ in 0 ..< n {
		t0 := time.tick_now()
		vg.set_size(&rc, w, h)
		vg.layer_stack_begin(&rls, &rc, w, h, nil, doc.uses_blend)
		svg.draw(&rc, &rls, &rr, &doc, &text, xf)
		vg.layer_stack_end(&rls, &rc)
		vg.canvas_take(&rc, &frame)
		record_best = min(record_best, time.duration_milliseconds(time.tick_since(t0)))
	}

	sw: vg.Software_Backend
	vg.software_backend_init(&sw)
	defer vg.software_backend_destroy(&sw)
	c: vg.Canvas
	vg.canvas_init(&c, vg.software_backend(&sw))
	defer vg.canvas_destroy(&c)
	ls: vg.Layer_Stack
	defer vg.layer_stack_destroy(&ls, &c)
	r: svg.Renderer
	defer svg.renderer_destroy(&r, &c)
	svg.renderer_bind(&r, &c, &doc)
	sw_best := max(f64)
	for _ in 0 ..< max(n / 4, 1) {
		t0 := time.tick_now()
		vg.set_size(&c, w, h)
		vg.clear_rect(&c, 0, 0, w, h, vg.WHITE)
		vg.layer_stack_begin(&ls, &c, w, h, nil, doc.uses_blend)
		svg.draw(&c, &ls, &r, &doc, &text, xf)
		vg.layer_stack_end(&ls, &c)
		vg.flush(&c)
		sw_best = min(sw_best, time.duration_milliseconds(time.tick_since(t0)))
	}
	fmt.printfln("%s: %d bytes, %d nodes, %d shapes, %d path verbs, %d servers", path, len(data), len(doc.nodes), len(doc.shapes), len(doc.verbs), len(doc.servers))
	fmt.printfln("parse %.2f ms, record %.2f ms (%d commands, %d shapes), software render %.2f ms at %dx%d (best of %d)", parse_best, record_best, len(frame.commands), len(frame.shapes), sw_best, w, h, n)
}

flat_name :: proc(root, p: string) -> string {
	rel := p
	if root != "" {
		rel, _ = filepath.rel(root, p, context.temp_allocator)
	}
	rel = rel[:len(rel) - 4]
	out, _ := strings.replace_all(rel, "/", "_", context.temp_allocator)
	return out
}
