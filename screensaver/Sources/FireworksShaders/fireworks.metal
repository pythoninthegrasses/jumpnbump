#include <metal_stdlib>
using namespace metal;

// A single full-screen quad presenting Framebuffer's 400x256 RGBA8 texture,
// nearest-neighbour sampled -- crisp integer-scaled pixel art, matching
// game/'s own presentation convention (TASK-014.04) without going through
// Godot. Vertex data is a hardcoded triangle-strip covering the letterboxed
// destination rect in clip space; JNBFireworksView computes that rect
// per-frame (PresentationGeometry) and uploads it as `viewport`.

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex VertexOut fireworks_vertex(uint vertexID [[vertex_id]],
                                   constant float4 *destRectClipSpace [[buffer(0)]]) {
    // destRectClipSpace holds (x0,y0,x1,y1) of the letterboxed rect, both
    // corners already in clip space (-1...1).
    float4 rect = destRectClipSpace[0];
    float2 positions[4] = {
        float2(rect.x, rect.y),
        float2(rect.z, rect.y),
        float2(rect.x, rect.w),
        float2(rect.z, rect.w),
    };
    float2 uvs[4] = {
        float2(0.0, 1.0),
        float2(1.0, 1.0),
        float2(0.0, 0.0),
        float2(1.0, 0.0),
    };
    VertexOut out;
    out.position = float4(positions[vertexID], 0.0, 1.0);
    out.uv = uvs[vertexID];
    return out;
}

fragment float4 fireworks_fragment(VertexOut in [[stage_in]],
                                    texture2d<float, access::sample> tex [[texture(0)]]) {
    constexpr sampler nearestSampler(mag_filter::nearest, min_filter::nearest, mip_filter::none);
    return tex.sample(nearestSampler, in.uv);
}
