// Quads (clears, images copied unclipped) through their paint, after
// common.glsl. MOTION: a target with a velocity twin, whose second colour
// target takes still and farthest at the colour's alpha (a clear's Copy
// blend on both).

layout(location = 0) in vec2 ftcoord;
layout(location = 1) in vec2 fpos;
layout(location = 2) flat in uint fpaint;

layout(location = 0) out vec4 color;
#ifdef MOTION
layout(location = 1) out vec4 motion;
#endif

vec4 main_color() {
    paint_index = fpaint;
    int type = shader_type();
    float stroke_alpha = 1.0;
    if (type != TEXTURE_COPY_UNCLIPPED) {
        stroke_alpha = stroke_mask(ftcoord);
        if (stroke_alpha < stroke_thr()) {
            discard;
        }
    }
    if (type == TEXTURE_COPY_UNCLIPPED) {
        return apply_tex_type(textureLod(tex, ftcoord, 0.0)) * inner_col();
    }
    vec4 result = fill_color(type, fpos);
    result *= stroke_alpha * scissor_mask(fpos);
    return result;
}

void main() {
    vec4 c = main_color();
    color = c;
#ifdef MOTION
    motion = vec4(0.0, 0.0, 0.0, c.a);
#endif
}
