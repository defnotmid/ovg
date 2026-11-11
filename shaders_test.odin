package ovg

import "core:testing"
import "deps:oksl"

// Every fragment unit and its motion variant compiles with oksl, for SPIR-V,
// MSL and the CPU, linked with the vertex shader that draws it (varyings
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
			p, errors, ok := oksl.compile_pipeline({vertex = vert, fragment = src.source, fragment_prelude = prelude})
			if !testing.expectf(t, ok, "%v (motion %v): %s", u, k == 1, oksl.format_errors(errors, context.temp_allocator)) {
				continue
			}
			m := p.fragment
			testing.expectf(t, len(m.spirv) > 0 && len(m.msl) > 0 && len(m.program.code) > 0, "%v: SPIR-V, MSL and the CPU program", u)
			buffers := make([]string, len(m.storage_buffers), context.temp_allocator)
			for sb, i in m.storage_buffers {
				buffers[i] = sb.name
			}
			testing.expectf(t, shader_bindings_ok(m.channel_names[:m.num_samplers], buffers), "%v: binds %v and %v", u, m.channel_names[:m.num_samplers], buffers)
			// The motion variant writes the twin at location 1.
			want := 2 if k == 1 || u == .Resolve_Velocity else 1
			testing.expectf(t, len(m.stage_outputs) == want, "%v (motion %v): %v outputs", u, k == 1, len(m.stage_outputs))
			oksl.destroy_pipeline(p)
		}
	}
	// A unit reading past what's bound, or out of order, fails the check.
	testing.expect(t, !shader_bindings_ok({"glyphtex"}, {}))
	testing.expect(t, !shader_bindings_ok({}, {"Paints", "Members"}))
	testing.expect(t, shader_bindings_ok({"tex"}, {"Paints", "Shapes"}))
}
