package ovg

import "core:strings"
import cv "deps:ocurves"

// The backends' shading is GLSL ES 3.0 (shaders/), compiled by oksl when a
// backend starts: no shader toolchain, and nothing compiled ahead of time
// to keep in step with ocurves' curves.glsl, which comes from the same
// package as the words it reads. A unit is one fragment shader; the quad
// and shape vertex shaders draw them.

// The fragment units, each but the last three with a motion-blur variant
// that writes its target's velocity twin beside the colour.
Shader_Unit :: enum u8 {
	// Quads: clears, images.
	Main,
	// Quads of image filters, apart so that the draws' shader doesn't
	// carry them.
	Filter,
	// Shape instances: fills, and hairlines (hairline_shape) in the same
	// draws.
	Shape,
	// Instances whose pixel footprint is a box (no rotation or skew).
	Shape_Box,
	// Groups (Cmd_Draw_Shapes.group): one record, its pixels compositing
	// the instances.
	Shape_Group,
	// Groups of markers (fill_markers).
	Marker_Group,
	// Motion blur: a layer's motion onto its target's twin
	// (Cmd_Composite_Velocity), and the screen's twin resolved into the
	// velocity and nearness textures.
	Composite_Velocity,
	Resolve_Velocity,
}

// A unit's source, whether it reads shapes (curves.glsl and shapes.glsl
// ahead of it, after common.glsl), its #defines and whether it has a
// motion variant (MOTION defined too).
Shader_Source :: struct {
	source:  string,
	shapes:  bool,
	defines: string,
	motion:  bool,
}

SHADER_SOURCES := [Shader_Unit]Shader_Source {
	.Main               = {#load("shaders/main.frag", string), false, "", true},
	.Filter             = {#load("shaders/filter.frag", string), false, "", false},
	.Shape              = {#load("shaders/shape.frag", string), true, "", true},
	.Shape_Box          = {#load("shaders/shape.frag", string), true, "#define SHAPE_BOX\n", true},
	.Shape_Group        = {#load("shaders/group.frag", string), true, "", true},
	.Marker_Group       = {#load("shaders/markers.frag", string), true, "", true},
	.Composite_Velocity = {#load("shaders/velocity.frag", string), false, "", false},
	.Resolve_Velocity   = {#load("shaders/velocity.frag", string), false, "#define RESOLVE\n", false},
}

// The vertex shaders: quads (position, texture coordinates, paint row) and
// shape instances (pulled from a storage buffer by gl_VertexID).
SHADER_QUAD_VERT :: #load("shaders/quad.vert", string)
SHADER_SHAPE_VERT :: #load("shaders/shape.vert", string)

@(private = "file")
SHADER_COMMON :: #load("shaders/common.glsl", string)
@(private = "file")
SHADER_SHAPES :: #load("shaders/shapes.glsl", string)

// The samplers and storage buffers a fragment unit may read, in the order
// a backend binds them: a unit reads a prefix of each (shader_bindings_ok).
SHADER_SAMPLERS :: [2]string{"tex", "glyphtex"}
SHADER_BUFFERS :: [4]string{"Paints", "Shapes", "Members", "Motions"}

// The prelude oksl compiles unit `u` after (its Options.prelude), with
// `motion` its motion variant's; in `allocator`.
shader_prelude :: proc(u: Shader_Unit, motion: bool, allocator := context.allocator) -> string {
	src := SHADER_SOURCES[u]
	parts := [5]string{src.defines, "#define MOTION\n" if motion else "", SHADER_COMMON, cv.GLSL if src.shapes else "", SHADER_SHAPES if src.shapes else ""}
	return strings.concatenate(parts[:], allocator)
}

// Whether a compiled unit's samplers (by name, in channel order) and storage
// buffers (block names, in binding order) are prefixes of what a backend
// binds.
shader_bindings_ok :: proc(samplers: []string, buffers: []string) -> bool {
	want_samplers, want_buffers := SHADER_SAMPLERS, SHADER_BUFFERS
	if len(samplers) > len(want_samplers) || len(buffers) > len(want_buffers) {
		return false
	}
	for s, i in samplers {
		if s != want_samplers[i] {
			return false
		}
	}
	for b, i in buffers {
		if b != want_buffers[i] {
			return false
		}
	}
	return true
}
