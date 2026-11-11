// The custom program of the parity tools' "program" scene, in GLSL ES 3.0
// compiled by oksl (scenes.odin: for the GPU over oksl's layer vertex shader,
// and as its CPU program): the binding layout ovg's run_program uses.

uniform vec4 color_a;
uniform vec4 color_b;
// x: ring radius, y: ring width, z: texture scale
uniform vec4 shape;
uniform sampler2D channel0;
uniform sampler2D channel1;

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 color;

void main() {
    vec4 tex = textureLod(channel0, uv * shape.z, 0.0);
    // Unbound: transparent black.
    vec4 none = textureLod(channel1, uv, 0.0);
    float d = length(uv - 0.5);
    float ring = clamp(1.0 - abs(d - shape.x) / shape.y, 0.0, 1.0);
    vec4 grad = mix(color_a, color_b, uv.x);
    float a = ring * grad.a;
    vec3 rgb = grad.rgb * a + tex.rgb * tex.a * (1.0 - a) * 0.5;
    float alpha = a + tex.a * (1.0 - a) * 0.5;
    color = vec4(rgb, alpha) + none;
}
