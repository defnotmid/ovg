// Renders the shared scenes with the software and SDL_GPU backends
// (headless) and compares the pixels. Writes `<scene>_sw.png`,
// `<scene>_gpu.png` and `<scene>_diff.png` into the output directory.
// Each scene is drawn again with motion blur: its pixels must not change,
// and its velocity and nearness must match between the backends (the
// motion scene's written as `motion_velocity_{sw,gpu}.png`).
//
//     odin run tools/sdlgpu_parity -collection:deps=.. -- [out_dir]
//
// `SDL_GPU_DRIVER=vulkan|metal|direct3d12` picks SDL's GPU driver.
package sdlgpu_parity

import "core:fmt"
import "core:os"
import sdl "vendor:sdl3"

import image "deps:oicut/image"

import vg "../.."
import vgsdl "../../sdlgpu"
import "../scenes"

main :: proc() {
	out_dir := os.args[1] if len(os.args) > 1 else "parity_out"
	os.make_directory(out_dir)

	gpu: vgsdl.SDL_Backend
	if err := vgsdl.init(&gpu); err != nil {
		fmt.eprintln("SDL_GPU backend init failed:", err, sdl.GetError())
		os.exit(2)
	}
	defer vgsdl.destroy(&gpu)
	fmt.println("SDL_GPU driver:", sdl.GetGPUDeviceDriver(gpu.device))

	sw: vg.Software_Backend
	vg.software_backend_init(&sw)
	defer vg.software_backend_destroy(&sw)

	sw_canvas, gpu_canvas: vg.Canvas
	vg.canvas_init(&sw_canvas, vg.software_backend(&sw))
	vg.canvas_init(&gpu_canvas, vgsdl.backend(&gpu))
	defer vg.canvas_destroy(&sw_canvas)
	defer vg.canvas_destroy(&gpu_canvas)
	sw_res, gpu_res: scenes.Resources
	scenes.setup(&sw_canvas, &sw_res)
	scenes.setup(&gpu_canvas, &gpu_res)
	defer scenes.resources_destroy(&sw_canvas, &sw_res)
	defer scenes.resources_destroy(&gpu_canvas, &gpu_res)

	failed := 0
	for scene in scenes.ALL {
		a := draw(&sw_canvas, scene, &sw_res, false)
		b := draw(&gpu_canvas, scene, &gpu_res, false)
		d := scenes.compare(a, b)
		if !scenes.report(out_dir, scene.name, "sw", "gpu", a, b, d) {
			failed += 1
		}
		delete(d.image)
		if !motion_check(out_dir, scene, &sw, &gpu, &sw_canvas, &gpu_canvas, &sw_res, &gpu_res, a, b) {
			failed += 1
		}
		delete(a)
		delete(b)
	}
	// A caller-owned output texture, once submitted by the backend and once
	// recorded into the caller's command buffer.
	tex := sdl.CreateGPUTexture(
		gpu.device,
		{
			type = .D2,
			format = .R8G8B8A8_UNORM,
			usage = {.COLOR_TARGET, .SAMPLER},
			width = scenes.W,
			height = scenes.H,
			layer_count_or_depth = 1,
			num_levels = 1,
		},
	)
	defer sdl.ReleaseGPUTexture(gpu.device, tex)
	scenes.draw_frame(&sw_canvas, scenes.ALL[0], &sw_res)
	vg.flush(&sw_canvas)
	a, _ := vg.screenshot(&sw_canvas)
	defer delete(a.pixels)
	for caller_submits in ([2]bool{false, true}) {
		out := vgsdl.Output {
			texture = tex,
			format  = .R8G8B8A8_UNORM,
			width   = scenes.W,
			height  = scenes.H,
		}
		if caller_submits {
			out.command_buffer = sdl.AcquireGPUCommandBuffer(gpu.device)
		}
		scenes.draw_frame(&gpu_canvas, scenes.ALL[0], &gpu_res)
		vg.flush(&gpu_canvas, vgsdl.output(&out))
		if caller_submits {
			_ = sdl.SubmitGPUCommandBuffer(out.command_buffer)
		}
		b, _ := vgsdl.read_texture(&gpu, {texture = tex, format = .R8G8B8A8_UNORM, width = scenes.W, height = scenes.H})
		d := scenes.compare(a.pixels, b)
		if !scenes.report(out_dir, "output_cb" if caller_submits else "output", "sw", "gpu", a.pixels, b, d) {
			failed += 1
		}
		delete(d.image)
		delete(b)
	}

	total := 2 * len(scenes.ALL) + 2
	fmt.printfln("%d/%d checks match (images in %s)", total - failed, total, out_dir)
	if failed > 0 {
		os.exit(1)
	}
}

// The scene's pixels, drawn with or without motion blur.
draw :: proc(c: ^vg.Canvas, scene: scenes.Scene, r: ^scenes.Resources, motion: bool) -> []u8 {
	vg.canvas_motion_blur(c, motion)
	scenes.draw_frame(c, scene, r)
	vg.flush(c)
	shot, err := vg.screenshot(c)
	if err != nil {
		fmt.eprintln("screenshot failed:", err)
		os.exit(2)
	}
	return shot.pixels
}

// The scene drawn with motion blur: the same pixels as without (`a`, `b`),
// and the same velocity and nearness on both backends, each within
// MOTION_TOLERANCE, plus MOTION_RELATIVE of its size (the GPU blends twins
// in 16-bit floats), plus MOTION_COVERAGE of the frame's largest (where the
// backends' coverage differs by a few 8-bit steps, as their pixels may).
motion_check :: proc(out_dir: string, scene: scenes.Scene, sw: ^vg.Software_Backend, gpu: ^vgsdl.SDL_Backend, sw_canvas, gpu_canvas: ^vg.Canvas, sw_res, gpu_res: ^scenes.Resources, a, b: []u8) -> bool {
	MOTION_TOLERANCE :: 0.02
	MOTION_RELATIVE :: 0.01
	MOTION_COVERAGE :: 4.0 / 255
	a2 := draw(sw_canvas, scene, sw_res, true)
	defer delete(a2)
	b2 := draw(gpu_canvas, scene, gpu_res, true)
	defer delete(b2)
	same := string(a) == string(a2) && string(b) == string(b2)
	v, n := vg.software_backend_velocity(sw)
	vt, nt := vgsdl.velocity_textures(gpu)
	if len(v) != scenes.W * scenes.H || vt == nil || nt == nil {
		fmt.printfln("%-10s motion: no velocity  MISMATCH", scene.name)
		return false
	}
	gv, _ := vgsdl.read_texture(gpu, {texture = vt, format = .R16G16_FLOAT, width = scenes.W, height = scenes.H})
	defer delete(gv)
	gn, _ := vgsdl.read_texture(gpu, {texture = nt, format = .R16_FLOAT, width = scenes.W, height = scenes.H})
	defer delete(gn)
	// The GPU's halves as floats.
	half :: proc(b: []u8, i: int) -> f32 {
		return f32(transmute(f16)(u16(b[2 * i]) | u16(b[2 * i + 1]) << 8))
	}
	q := make([]vg.Vec2, len(v))
	defer delete(q)
	m := make([]f32, len(n))
	defer delete(m)
	for i in 0 ..< len(v) {
		q[i], m[i] = {half(gv, 2 * i), half(gv, 2 * i + 1)}, half(gn, i)
	}
	most, nearest: f32
	for i in 0 ..< len(v) {
		most, nearest = max(most, abs(v[i].x), abs(v[i].y)), max(nearest, n[i])
	}
	worst_v, worst_n: f32
	over, first := 0, -1
	for i in 0 ..< len(v) {
		dv := max(abs(q[i].x - v[i].x), abs(q[i].y - v[i].y))
		dn := abs(m[i] - n[i])
		worst_v, worst_n = max(worst_v, dv), max(worst_n, dn)
		if dv > MOTION_TOLERANCE + MOTION_RELATIVE * max(abs(v[i].x), abs(v[i].y)) + MOTION_COVERAGE * most || dn > MOTION_TOLERANCE + MOTION_RELATIVE * n[i] + MOTION_COVERAGE * nearest {
			over += 1
			first = i if first < 0 else first
		}
	}
	ok := same && over == 0
	fmt.printfln("%-10s motion: pixels %s, velocity up to %.2f px (diff %.4f), nearness up to %.1f (diff %.4f), beyond tolerance %d  %s", scene.name, "same" if same else "CHANGED", most, worst_v, nearest, worst_n, over, "ok" if ok else "MISMATCH")
	if first >= 0 {
		fmt.printfln("    first at (%d, %d): software %v %v, GPU %v %v", first % scenes.W, first / scenes.W, v[first], n[first], q[first], m[first])
	}
	if scene.name == "motion" || !ok {
		show(fmt.tprintf("%s/%s_velocity_sw.png", out_dir, scene.name), v, n)
		show(fmt.tprintf("%s/%s_velocity_gpu.png", out_dir, scene.name), q, m)
	}
	return ok
}

// Velocity as colour: 128 plus 8 per pixel of motion in red and green,
// nearness times 12 in blue.
show :: proc(path: string, v: []vg.Vec2, n: []f32) {
	px := make([]u8, scenes.W * scenes.H * 4)
	defer delete(px)
	for i in 0 ..< scenes.W * scenes.H {
		px[4 * i] = u8(clamp(128 + 8 * v[i].x, 0, 255))
		px[4 * i + 1] = u8(clamp(128 + 8 * v[i].y, 0, 255))
		px[4 * i + 2] = u8(clamp(12 * n[i], 0, 255))
		px[4 * i + 3] = 255
	}
	image.write_png(path, px, scenes.W, scenes.H)
}
