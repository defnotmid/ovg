// A group of markers (ovg draw_markers), after common.glsl, curves.glsl and
// shapes.glsl: its records and cells a group of shapes', each member a
// marker (its kind in data.x, 16 added when filled; an outline's width in
// data.z) of closed-form coverage. A pixel takes the union of the fills and
// of the outlines, stopping once both are whole (or absent), then the
// fill's paint (the members' row) at the first and the outlines' (the
// tint) at the second over it. MOTION: the group's motion is its first
// marker's (one draw_markers call's).

void main() {
    shape_clip();
    uvec2 cl = group_cell(data.x);
    uint at = cl.x;
    uint lists = cl.y;
    float cf = 0.0;
    float co = 0.0;
    uint fill_row = 0u;
    for (uint k = shapes.words[at]; k < shapes.words[at + 1u]; k++) {
        Shape_Instance s = members.rows[data.z + shapes.words[lists + k]];
        vec2 r;
        if (!member_point(s, r)) {
            continue;
        }
        bool circle = (s.data.x & 15u) == 2u;
        bool filled = (s.data.x & 16u) != 0u;
        float outline = uintBitsToFloat(s.data.z);
        fill_row = s.data.y;
        if (filled) {
            float f = curves_marker(circle, r, s.uv.xy, s.uv.zw, 0.0);
            cf += f - cf * f;
        }
        if (outline > 0.0) {
            float o = curves_marker(circle, r, s.uv.xy, s.uv.zw, outline);
            co += o - co * o;
        }
        if ((!filled || cf >= 1.0) && (outline <= 0.0 || co >= 1.0)) {
            break;
        }
    }
    vec4 result = vec4(0.0);
    if (cf >= 1.0 / 510.0) {
        paint_index = fill_row;
        result = fill_color(shader_type(), fpos) * (stroke_mask(vec2(0.5, cf)) * scissor_mask(fpos));
    }
    if (co >= 1.0 / 510.0) {
        paint_index = data.y;
        vec4 o = fill_color(shader_type(), fpos) * (stroke_mask(vec2(0.5, co)) * scissor_mask(fpos));
        result = o + result * (1.0 - o.a);
    }
    if (result.a < 1.0 / 510.0) {
        discard;
    }
    color = result;
#ifdef MOTION
    motion = motion_over(data.z, fpos, result.a, vec4(0.0));
#endif
}
