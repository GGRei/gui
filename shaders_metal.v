module gui

// Metal vertex source used by the runtime custom Shader API.
const vs_custom_metal = '
#include <metal_stdlib>
using namespace metal;

struct VertexIn {
    float3 position [[attribute(0)]];
    float2 texcoord0 [[attribute(1)]];
    float4 color0 [[attribute(2)]];
};

struct VertexOut {
    float4 position [[position]];
    float2 uv;
    float4 color;
    float params;
    float4 p0;
    float4 p1;
    float4 p2;
    float4 p3;
};

struct Uniforms {
    float4x4 mvp;
    float4x4 tm;
};


vertex VertexOut vs_main(VertexIn in [[stage_in]], constant Uniforms &uniforms [[buffer(0)]]) {
    VertexOut out;
    out.position = uniforms.mvp * float4(in.position.xy, 0.0, 1.0);
    out.uv = in.texcoord0;
    out.color = in.color0;
    out.params = in.position.z;
    out.p0 = uniforms.tm[0];
    out.p1 = uniforms.tm[1];
    out.p2 = uniforms.tm[2];
    out.p3 = uniforms.tm[3];
    return out;
}
'
