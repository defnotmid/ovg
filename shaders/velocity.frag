// The motion blur's passes (ovg canvas_motion_blur), after common.glsl,
// over quad.vert's quads. A target with a velocity twin (ovg
// Cmd_Set_Render_Target.velocity) takes each pixel's motion premultiplied
// by coverage, (a * velocity, a * nearness, a), blended source-over.
//
// Default: a layer's motion composited onto the twin (ovg
// Cmd_Composite_Velocity), drawn over the layer's window: its twin (`tex`)
// at its coverage (`glyphtex`'s alpha) and opacity (the paint's P(0).x),
// both read at the pixel (a nearest sampler over a quad on their texels).
// RESOLVE: the screen's twin (`tex`) as velocity (RG) and nearness (R)
// targets.

#ifdef QUAD_FLAT_UNIFORMS
// The software backend's quads: the target's pixels are drawing
// coordinates, ftcoord is gl_FragCoord.xy * quad_tc.xy + quad_tc.zw, and
// the paint is the uniform quad_paint (quad_inputs sets them).
uniform vec4 quad_tc;
vec2 ftcoord;
vec2 fpos;
uint fpaint;
void quad_inputs() {
    fpos = gl_FragCoord.xy;
    ftcoord = fpos * quad_tc.xy + quad_tc.zw;
    fpaint = 0u;
}
#else
layout(location = 0) in vec2 ftcoord;
layout(location = 1) in vec2 fpos;
layout(location = 2) flat in uint fpaint;
void quad_inputs() {}
#endif

layout(location = 0) out vec4 color;
#ifdef RESOLVE
layout(location = 1) out vec4 nearness;
#endif

void main() {
    quad_inputs();
    vec4 t = textureLod(tex, ftcoord, 0.0);
#ifdef RESOLVE
    color = vec4(t.xy, 0.0, 0.0);
    nearness = vec4(t.z, 0.0, 0.0, 0.0);
#else
    paint_index = fpaint;
    color = twin_composite(t, textureLod(glyphtex, ftcoord, 0.0).a, P(0).x);
#endif
}
