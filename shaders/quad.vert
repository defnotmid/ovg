// ovg's vertex shader for quads (clears, filters, the motion passes), in
// GLSL ES 3.0 as oksl compiles it. Every vertex names its paint, a row of
// the fragment shaders' `paints`.
//
// SDL_GPU puts NDC +1 at the top row of every target (screen or texture),
// so y = 0 is the top in both and images stay top-down.

layout(location = 0) in vec2 vertex;
layout(location = 1) in vec2 tcoord;
layout(location = 2) in uint paint;

// Target size (xy) and the drawing coordinates of its top-left pixel (zw).
uniform vec4 view;

layout(location = 0) out vec2 ftcoord;
layout(location = 1) out vec2 fpos;
layout(location = 2) flat out uint fpaint;

void main() {
    ftcoord = tcoord;
    fpos = vertex;
    fpaint = paint;
    vec2 p = vertex - view.zw;
    gl_Position = vec4(2.0 * p.x / view.x - 1.0, 1.0 - 2.0 * p.y / view.y, 0.0, 1.0);
}
