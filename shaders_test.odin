package ovg

import "core:strings"
import "core:testing"
import "deps:oksl"

// Every fragment unit and its motion variant compiles with oksl, for SPIR-V,
// MSL, DXBC (Direct3D 12) and the CPU, linked with the vertex shader that draws it (varyings
// matched by name, type and interpolation); the samplers and buffers it
// reads are a prefix of what the backends bind. No GPU needed.
@(test)
test_shaders_compile :: proc(t: ^testing.T) {
	for src, u in SHADER_SOURCES {
		vert := SHADER_QUAD_VERT
		#partial switch u {
		case .Shape, .Shape_Box, .Shape_Group, .Marker_Group:
			vert = SHADER_SHAPE_VERT
		}
		for k in 0 ..< (2 if src.motion else 1) {
			prelude := shader_prelude(u, k == 1, context.temp_allocator)
			p, errors, ok := oksl.compile_pipeline({vertex = vert, fragment = src.source, fragment_prelude = prelude}, {dxbc = true})
			if !testing.expectf(t, ok, "%v (motion %v): %s", u, k == 1, oksl.format_errors(errors, context.temp_allocator)) {
				continue
			}
			m := p.fragment
			testing.expectf(t, len(m.spirv) > 0 && len(m.msl) > 0 && len(m.dxbc) > 0 && len(p.vertex.dxbc) > 0 && len(m.program.code) > 0, "%v: SPIR-V, MSL, DXBC and the CPU program", u)
			buffers := make([]string, len(m.storage_buffers), context.temp_allocator)
			for sb, i in m.storage_buffers {
				buffers[i] = sb.name
			}
			testing.expectf(t, shader_bindings_ok(m.channel_names[:m.num_samplers], buffers), "%v: binds %v and %v", u, m.channel_names[:m.num_samplers], buffers)
			// The motion variant writes the twin at location 1.
			want := 2 if k == 1 || u == .Resolve_Velocity else 1
			testing.expectf(t, len(m.stage_outputs) == want, "%v (motion %v): %v outputs", u, k == 1, len(m.stage_outputs))
			oksl.destroy_pipeline(p)
			if u == .Main || u == .Resolve_Velocity {
				// Run by the software backend's own Odin: clears, and a copy.
				continue
			}
			// The software backend's compile: the shape units' uv and data
			// uniforms, the quad units' quad_tc, and no stage inputs (their
			// positions from gl_FragCoord).
			cpu, cpu_errors, cpu_ok := oksl.compile(src.source, {profile = .Glsl, prelude = strings.concatenate({shader_cpu_defines(u), prelude}, context.temp_allocator), no_spirv = true, no_msl = true})
			if !testing.expectf(t, cpu_ok, "%v (motion %v) on the CPU: %s", u, k == 1, oksl.format_errors(cpu_errors, context.temp_allocator)) {
				continue
			}
			if src.shapes {
				_, has_uv := oksl.find_uniform(cpu, "uv")
				_, has_data := oksl.find_uniform(cpu, "data")
				testing.expectf(t, has_data && (has_uv || u != .Shape), "%v: uv %v, data %v uniforms", u, has_uv, has_data)
			} else {
				_, has_tc := oksl.find_uniform(cpu, "quad_tc")
				testing.expectf(t, has_tc || u == .Filter, "%v: quad_tc %v", u, has_tc)
			}
			testing.expectf(t, len(cpu.stage_inputs) == 0, "%v: stage inputs %v", u, cpu.stage_inputs)
			oksl.destroy(cpu)
		}
	}
	// A unit reading past what's bound, or out of order, fails the check.
	testing.expect(t, !shader_bindings_ok({"glyphtex"}, {}))
	testing.expect(t, !shader_bindings_ok({}, {"Paints", "Members"}))
	testing.expect(t, shader_bindings_ok({"tex"}, {"Paints", "Shapes"}))
}
