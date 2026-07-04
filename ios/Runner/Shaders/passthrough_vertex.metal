// Passthrough vertex shader shared by all fragment passes — Metal port of
// shaders/passthrough.vert.
//
// Metal's NDC is y-up (like GL), but Metal textures are top-left origin
// (unlike GL's bottom-left). The renderer therefore passes uFlipY = 1 on
// every pass so the image stays right-side-up across the ping-pong chain;
// the uniform name + semantics are kept identical to the GLSL original.
//
// Uniforms (kept identical to the GLSL original):
//   uFlipY (int)  - 1 to flip texture Y, 0 otherwise.
//
// Vertex data is an interleaved (x, y, u, v) FloatBuffer pulled by
// [[vertex_id]] — no MTLVertexDescriptor is required, mirroring the Android
// quadVerts / glVertexAttribPointer setup in LiveViewRenderer.kt.

#include <metal_stdlib>
using namespace metal;

// Packed (position.xy, texCoord.xy) — 16 bytes per vertex, matches the
// Android quadVerts layout: [-1,-1,0,0, 1,-1,1,0, -1,1,0,1, 1,1,1,1].
// Pulled by [[vertex_id]] from a bound device buffer, so no MTLVertexDescriptor
// is required (the [[attribute(n)]] qualifiers are intentionally omitted).
struct VertexIn {
    float2 position;
    float2 texCoord;
};

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

vertex VertexOut passthrough_vertex(uint vid [[vertex_id]],
                                    device const VertexIn* verts [[buffer(0)]],
                                    constant int& uFlipY [[buffer(1)]]) {
    VertexOut out;
    out.position = float4(verts[vid].position, 0.0, 1.0);
    out.texCoord = verts[vid].texCoord;
    if (uFlipY == 1) {
        out.texCoord.y = 1.0 - out.texCoord.y;
    }
    return out;
}
