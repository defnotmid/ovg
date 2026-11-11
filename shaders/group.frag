// A group (ovg Cmd_Draw_Shapes.group), after common.glsl, curves.glsl and
// shapes.glsl: a record over its instances' bounds, in cells (rc: cell
// units; data: its grid's word offset in `shapes`, the tint's paint row and
// the first instance). Each pixel composites the instances its cell lists,
// in order, each shaded as shape.frag would, source-over, then takes the
// tint. MOTION: the members' motion accumulates beside their colour and
// composites as a layer's, the tint's alpha its opacity.

void main() {
#ifdef MOTION
    vec4 mo = vec4(0.0);
#endif
    shape_clip();
    uvec2 cl = group_cell(data.x);
    uint at = cl.x;
    uint lists = cl.y;
    vec4 acc = vec4(0.0);
    for (uint k = shapes.words[at]; k < shapes.words[at + 1u]; k++) {
        uint index = data.z + shapes.words[lists + k];
        Shape_Instance s = members.rows[index];
        vec2 r;
        if (!member_point(s, r)) {
            continue;
        }
        int rule = shape_rule(s.data.z);
        float coverage;
        if ((s.data.z & 2u) != 0u) {
            int w = curves_winding(s.data.x, r + (s.uv.xy + s.uv.zw) / 64.0);
            coverage = curves_fill_inside(w, rule) ? 1.0 : 0.0;
        } else if (s.m.y == 0.0 && s.m.z == 0.0) {
            coverage = curves_coverage(s.data.x, r, vec2(abs(s.uv.x), abs(s.uv.w)), rule);
        } else {
            coverage = curves_coverage_affine(s.data.x, r, s.uv.xy, s.uv.zw, rule);
        }
        if (coverage < 1.0 / 510.0) {
            continue;
        }
        paint_index = s.data.y;
        vec4 c = fill_color(shader_type(), fpos) * (stroke_mask(vec2(0.5, shape_ease(s.data.z, coverage))) * scissor_mask(fpos));
        acc = c + acc * (1.0 - c.a);
#ifdef MOTION
        mo = motion_over(index, fpos, c.a, mo);
#endif
    }
    if (acc.a < 1.0 / 510.0) {
        discard;
    }
    paint_index = data.y;
    vec4 tint = fill_color(shader_type(), fpos) * scissor_mask(fpos);
    color = acc * tint;
#ifdef MOTION
    motion = twin_composite(mo, acc.a, tint.a);
#endif
}
