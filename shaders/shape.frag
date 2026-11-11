// Shape instances, after common.glsl, curves.glsl and shapes.glsl: the
// coverage of the pixel from the instance's curves through its paint, as
// the edge coverage of a path's vertices. Fills and hairlines draw in one
// draw, in order. SHAPE_BOX: instances without rotation or skew (the
// pixel's footprint a box), a leaner shader than the parallelogram one, so
// it runs with more waves. MOTION: a target with a velocity twin.

// A hairline (ovg hairline_shape) is the shape's outline drawn data.z's
// width in pixels wide under any transform. The width is a positive normal
// float and a fill's data.z its flags (under 8), so the float's exponent
// bits tell them apart.
bool shape_is_hairline(uint z) {
    return (z & 0x7f800000u) != 0u;
}

void main() {
    shape_clip();
    paint_index = data.y;
    float coverage;
    uint flags = data.z;
    if (shape_is_hairline(data.z)) {
        coverage = curves_hairline(data.x, rc, uv.xy, uv.zw, uintBitsToFloat(data.z));
        flags = 0u;
    } else if ((data.z & 2u) != 0u) {
        // Aliased: the winding a 64th of a pixel right of and below the
        // centre, so an edge through the centre itself (common when pixel
        // art is scaled by a fraction) falls the same side in every shape,
        // whatever each one's rounding.
        int w = curves_winding(data.x, rc + (uv.xy + uv.zw) / 64.0);
        coverage = curves_fill_inside(w, shape_rule(data.z)) ? 1.0 : 0.0;
    } else {
#ifdef SHAPE_BOX
        coverage = curves_coverage(data.x, rc, vec2(abs(uv.x), abs(uv.w)), shape_rule(data.z));
#else
        coverage = curves_coverage_affine(data.x, rc, uv.xy, uv.zw, shape_rule(data.z));
#endif
    }
    // Below half an 8-bit step the pixel is left alone: rounding leaves such
    // slivers where the shape is absent, and a blend like Copy would clear
    // them.
    if (coverage < 1.0 / 510.0) {
        discard;
    }
    vec4 c = fill_color(shader_type(), fpos) * (stroke_mask(vec2(0.5, shape_ease(flags, coverage))) * scissor_mask(fpos));
    color = c;
#ifdef MOTION
    motion = motion_over(data.w & 0x7fffffffu, fpos, c.a, vec4(0.0));
#endif
}
