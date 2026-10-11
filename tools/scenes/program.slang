// The custom program of the parity tools' "program" scene, with the binding
// layout ovg's run_program uses (oksl's): vertex uniforms in set 1,
// fragment samplers in set 2, the fragment uniform block in set 3.
// scenes.odin mirrors fs_main on the CPU. Rebuild with build_program.sh.

struct View {
    float4 size;
};

struct Params {
    float4 color_a;
    float4 color_b;
    // x: ring radius, y: ring width, z: texture scale
    float4 shape;
};

[[vk::binding(0, 1)]] ConstantBuffer<View> view : register(b0, space1);
[[vk::binding(0, 3)]] ConstantBuffer<Params> params : register(b0, space3);
[[vk::binding(0, 2)]] Sampler2D channel0 : register(t0, space2);
[[vk::binding(1, 2)]] Sampler2D channel1 : register(t1, space2);

struct VS_In {
    float2 position : TEXCOORD0;
    float2 uv : TEXCOORD1;
};

struct VS_Out {
    float4 position : SV_Position;
    float2 uv : TEXCOORD0;
};

[shader("vertex")]
VS_Out vs_main(VS_In i) {
    VS_Out o;
    o.uv = i.uv;
    o.position = float4(2.0 * i.position.x / view.size.x - 1.0, 1.0 - 2.0 * i.position.y / view.size.y, 0, 1);
    return o;
}

[shader("fragment")]
float4 fs_main(float2 uv : TEXCOORD0) : SV_Target {
    float4 tex = channel0.SampleLevel(uv * params.shape.z, 0.0);
    // Unbound: transparent black.
    float4 none = channel1.SampleLevel(uv, 0.0);
    float d = length(uv - 0.5);
    float ring = clamp(1.0 - abs(d - params.shape.x) / params.shape.y, 0.0, 1.0);
    float4 grad = lerp(params.color_a, params.color_b, uv.x);
    float a = ring * grad.a;
    float3 rgb = grad.rgb * a + tex.rgb * tex.a * (1.0 - a) * 0.5;
    float alpha = a + tex.a * (1.0 - a) * 0.5;
    return float4(rgb, alpha) + none;
}
