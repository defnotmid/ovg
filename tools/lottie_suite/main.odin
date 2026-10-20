// Renders Lottie files with the software backend and compares them with
// reference PNGs: `name.json` next to `name_<frame>.png` (lottie-web's SVG
// renderer over white, at the composition's size). A pixel differs when a
// channel is off by more than `-tol` (8-bit); a frame passes when at most
// `-frac` of its pixels differ. Files named `*text*` pass with up to
// TEXT_FRAC of their pixels off: glyph edges differ from a browser's font
// rasterizer (hinting, subpixel placement) even when the layout matches.
//
//     odin run tools/lottie_suite -collection:deps=.. -o:speed -- [-tol:32] [-frac:0.02] [-dump:dir] [-v] dir
//     odin run tools/lottie_suite -collection:deps=.. -o:speed -- -render:file.json -frames:0,30 -out:dir
//     odin run tools/lottie_suite -collection:deps=.. -o:speed -- -bench:file.json [-n:60]
//
// `-dump:dir` writes every render and a diff image there (keep it out of
// the repository). `-bench` times parsing, recording (draw calls on a
// recording canvas) and full software renders across the animation.
package lottie_suite

import "core:fmt"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"
import image "deps:odecs/image"

import vg "../.."

TEXT_FRAC :: 0.06

Loader :: struct {
	dir: string,
}

load_file :: proc(user: rawptr, path: string, allocator: mem.Allocator) -> (data: []u8, ok: bool) {
	l := (^Loader)(user)
	full, _ := filepath.join({l.dir, path}, context.temp_allocator)
	bytes, err := os.read_entire_file(full, allocator)
	return bytes, err == nil
}

Renderer :: struct {
	sw: vg.Software_Backend,
	c:  vg.Canvas,
	ls: vg.Layer_Stack,
	r:  vg.Lottie_Renderer,
}

renderer_init :: proc(rd: ^Renderer) {
	vg.software_backend_init(&rd.sw)
	vg.canvas_init(&rd.c, vg.software_backend(&rd.sw))
}

renderer_destroy :: proc(rd: ^Renderer) {
	vg.lottie_renderer_destroy(&rd.r, &rd.c)
	vg.layer_stack_destroy(&rd.ls, &rd.c)
	vg.canvas_destroy(&rd.c)
	vg.software_backend_destroy(&rd.sw)
}

// Draws `frame` over white at the composition's size.
draw :: proc(rd: ^Renderer, doc: ^vg.Lottie_Document, frame: f32) {
	w, h := u32(doc.width), u32(doc.height)
	c := &rd.c
	vg.set_size(c, w, h)
	vg.clear_rect(c, 0, 0, w, h, vg.WHITE)
	vg.layer_stack_begin(&rd.ls, c, w, h, nil, doc.uses_blend)
	vg.lottie_draw(c, &rd.ls, &rd.r, doc, frame)
	vg.layer_stack_end(&rd.ls, c)
}

render :: proc(rd: ^Renderer, doc: ^vg.Lottie_Document, frame: f32) -> []u8 {
	draw(rd, doc, frame)
	vg.flush(&rd.c)
	return rd.sw.pixels
}

parse_file :: proc(path: string) -> (doc: vg.Lottie_Document, ok: bool) {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		fmt.eprintfln("%s: can not read", path)
		return
	}
	defer delete(data)
	loader := Loader{filepath.dir(path)}
	perr: vg.Lottie_Error
	doc, perr = vg.lottie_parse(data, {load_file = load_file, user = &loader})
	if perr != nil {
		fmt.eprintfln("%s: %v", path, perr)
		vg.lottie_destroy(&doc)
		return
	}
	return doc, true
}

main :: proc() {
	tol, frac := 32, 0.02
	dump, render_path, out_dir, bench := "", "", ".", ""
	frames_arg := "0"
	bench_n := 60
	verbose := false
	inputs := make([dynamic]string)
	for a in os.args[1:] {
		switch {
		case strings.has_prefix(a, "-tol:"):
			tol, _ = strconv.parse_int(a[5:])
		case strings.has_prefix(a, "-frac:"):
			frac, _ = strconv.parse_f64(a[6:])
		case strings.has_prefix(a, "-dump:"):
			dump = a[6:]
		case strings.has_prefix(a, "-render:"):
			render_path = a[8:]
		case strings.has_prefix(a, "-frames:"):
			frames_arg = a[8:]
		case strings.has_prefix(a, "-out:"):
			out_dir = a[5:]
		case strings.has_prefix(a, "-bench:"):
			bench = a[7:]
		case strings.has_prefix(a, "-n:"):
			bench_n, _ = strconv.parse_int(a[3:])
		case a == "-v":
			verbose = true
		case:
			append(&inputs, a)
		}
	}
	rd: Renderer
	renderer_init(&rd)
	defer renderer_destroy(&rd)

	if bench != "" {
		run_bench(&rd, bench, bench_n)
		return
	}
	if render_path != "" {
		doc, ok := parse_file(render_path)
		if !ok {
			os.exit(1)
		}
		defer vg.lottie_destroy(&doc)
		vg.lottie_renderer_bind(&rd.r, &rd.c, &doc)
		defer vg.lottie_renderer_unbind(&rd.r, &rd.c)
		for w in doc.warnings {
			fmt.println("warning:", w)
		}
		stem := filepath.stem(render_path)
		for f in strings.split(frames_arg, ",", context.temp_allocator) {
			fr, _ := strconv.parse_f32(f)
			px := render(&rd, &doc, fr)
			out := fmt.tprintf("%s/%s_%s.png", out_dir, stem, f)
			image.write_png(out, px, int(doc.width), int(doc.height))
			fmt.println(out)
		}
		return
	}

	files := make([dynamic]string)
	for in_path in inputs {
		infos, err := os.read_all_directory_by_path(in_path, context.allocator)
		if err != nil {
			continue
		}
		for fi in infos {
			if strings.has_suffix(fi.name, ".json") {
				append(&files, fi.fullpath)
			}
		}
	}
	slice.sort(files[:])
	pass, total := 0, 0
	for f in files {
		doc, ok := parse_file(f)
		if !ok {
			total += 1
			fmt.printfln("FAIL %s (does not parse)", filepath.base(f))
			continue
		}
		vg.lottie_renderer_bind(&rd.r, &rd.c, &doc)
		stem := filepath.stem(f)
		dir := filepath.dir(f)
		infos, _ := os.read_all_directory_by_path(dir, context.temp_allocator)
		for fi in infos {
			prefix := fmt.tprintf("%s_", stem)
			if !strings.has_prefix(fi.name, prefix) || !strings.has_suffix(fi.name, ".png") {
				continue
			}
			frame_str := fi.name[len(prefix):len(fi.name) - 4]
			fr, is_num := strconv.parse_f32(frame_str)
			if !is_num {
				continue
			}
			png, perr := os.read_entire_file(fi.fullpath, context.temp_allocator)
			if perr != nil {
				continue
			}
			ref_img, ierr := image.decode(png)
			if ierr != nil {
				continue
			}
			ref, rw, rh := ref_img.pixels, ref_img.width, ref_img.height
			px := render(&rd, &doc, fr)
			total += 1
			off, worst := 0, 0
			sum: f64
			n := rw * rh
			if rw != int(doc.width) || rh != int(doc.height) {
				off = n
			} else {
				diff := make([]u8, n * 4, context.temp_allocator) if dump != "" else nil
				for i in 0 ..< n {
					m := 0
					for k in 0 ..< 3 {
						d := abs(int(px[i * 4 + k]) - int(ref[i * 4 + k]))
						m = max(m, d)
						sum += f64(d)
					}
					worst = max(worst, m)
					if m > tol {
						off += 1
					}
					if diff != nil {
						v := u8(min(255, m * 4))
						diff[i * 4], diff[i * 4 + 1], diff[i * 4 + 2], diff[i * 4 + 3] = v, v, v, 255
					}
				}
				if dump != "" {
					image.write_png(fmt.tprintf("%s/%s_%s_ours.png", dump, stem, frame_str), px, rw, rh)
					image.write_png(fmt.tprintf("%s/%s_%s_diff.png", dump, stem, frame_str), diff, rw, rh)
				}
			}
			image.destroy_image(&ref_img)
			share := f64(off) / f64(max(n, 1))
			ok_frame := share <= (max(frac, TEXT_FRAC) if strings.contains(stem, "text") else frac)
			pass += int(ok_frame)
			if verbose || !ok_frame {
				fmt.printfln("%s %s @%s: %.2f%% pixels off, mean %.2f/255, worst %d", "ok  " if ok_frame else "FAIL", stem, frame_str, share * 100, sum / f64(max(n * 3, 1)), worst)
			}
		}
		for w in doc.warnings {
			if verbose {
				fmt.printfln("     %s: %s", stem, w)
			}
		}
		vg.lottie_renderer_unbind(&rd.r, &rd.c)
		vg.lottie_destroy(&doc)
		free_all(context.temp_allocator)
	}
	fmt.printfln("total %d/%d frames (tol %d/255, at most %.1f%% pixels off)", pass, total, tol, frac * 100)
	if pass != total {
		os.exit(1)
	}
}

run_bench :: proc(rd: ^Renderer, path: string, n: int) {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		fmt.eprintln("can not read", path)
		return
	}
	defer delete(data)
	runs := 20
	t0 := time.tick_now()
	for _ in 0 ..< runs {
		doc, perr := vg.lottie_parse(data)
		if perr != nil {
			fmt.eprintln("parse failed:", perr)
			return
		}
		vg.lottie_destroy(&doc)
	}
	parse := time.tick_since(t0) / time.Duration(runs)
	doc, _ := parse_file(path)
	defer vg.lottie_destroy(&doc)
	span := doc.out_frame - doc.in_frame
	// Recording only: evaluation and draw calls, no rasterization.
	rec: vg.Canvas
	vg.canvas_init_recording(&rec)
	defer vg.canvas_destroy(&rec)
	rls: vg.Layer_Stack
	defer vg.layer_stack_destroy(&rls, &rec)
	rr: vg.Lottie_Renderer
	defer vg.lottie_renderer_destroy(&rr, &rec)
	vg.lottie_renderer_bind(&rr, &rec, &doc)
	w, h := u32(doc.width), u32(doc.height)
	frame_at :: proc(doc: ^vg.Lottie_Document, i, n: int, span: f32) -> f32 {
		return doc.in_frame + span * f32(i) / f32(max(n, 1))
	}
	t1 := time.tick_now()
	for i in 0 ..< n {
		vg.set_size(&rec, w, h)
		vg.layer_stack_begin(&rls, &rec, w, h, nil, doc.uses_blend)
		vg.lottie_draw(&rec, &rls, &rr, &doc, frame_at(&doc, i, n, span))
		vg.layer_stack_end(&rls, &rec)
		recorded: vg.Recorded_Frame
		vg.canvas_take(&rec, &recorded)
		vg.recorded_frame_destroy(&recorded)
	}
	record := time.tick_since(t1) / time.Duration(n)
	t2 := time.tick_now()
	for i in 0 ..< n {
		render(rd, &doc, frame_at(&doc, i, n, span))
	}
	full := time.tick_since(t2) / time.Duration(n)
	fmt.printfln("%s: %d bytes, %dx%d, %d layers, %d shapes, %d keys", filepath.base(path), len(data), w, h, len(doc.layers), len(doc.shapes), len(doc.keys))
	fmt.printfln("  parse   %v", parse)
	fmt.printfln("  record  %v / frame", record)
	fmt.printfln("  render  %v / frame (software, incl. record)", full)
}
