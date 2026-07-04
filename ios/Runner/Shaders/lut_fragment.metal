// 3D LUT fragment shader (2D-packed) — Metal port of shaders/lut.frag.
//
// Samples the live-view RGBA texture, applies a 3D LUT packed into a 2D
// texture of size (N*N) x N, with manual trilinear interpolation across the
// blue axis. Standard technique (Matt Diamond / GPUImage 3 lookup approach).
//
// Uniforms (names kept identical to the GLSL original):
//   uTexture   - live-view RGBA texture   (texture 0)
//   uLut       - 2D-packed 3D LUT texture  (texture 1, only bound when uEnabled==1)
//   uLutSize   - LUT size N (e.g. 17, 25, 33, 64)   (buffer 0, float)
//   uEnabled   - 1 to apply LUT, 0 to pass through  (buffer 1, int)
//
// This file also provides two trivial siblings used by the renderer:
//   passthrough_fragment  - RGBA -> RGBA, no LUT (stage disabled)
//   present_fragment      - RGBA -> BGRA swizzle for the Flutter CVPixelBuffer

#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

fragment float4 lut_fragment(VertexOut in [[stage_in]],
                             texture2d<float, access::sample> uTexture [[texture(0)]],
                             texture2d<float, access::sample> uLut     [[texture(1)]],
                             constant float& uLutSize [[buffer(0)]],
                             constant int&   uEnabled  [[buffer(1)]],
                             sampler smp [[sampler(0)]]) {
    float4 src = uTexture.sample(smp, in.texCoord);
    if (uEnabled == 0) {
        return src;
    }
    float n = uLutSize;
    float3 rgb = clamp(src.rgb, 0.0, 1.0);

    // Trilinear interpolation along B axis (identical math to lut.frag).
    float nb = rgb.b * (n - 1.0);
    float b0 = floor(nb);
    float b1 = min(b0 + 1.0, n - 1.0);
    float fw = nb - b0;

    float2 uv0 = float2((b0 * n + rgb.r * (n - 1.0) + 0.5) / (n * n),
                        (rgb.g * (n - 1.0) + 0.5) / n);
    float2 uv1 = float2((b1 * n + rgb.r * (n - 1.0) + 0.5) / (n * n),
                        (rgb.g * (n - 1.0) + 0.5) / n);

    float3 c0 = uLut.sample(smp, uv0).rgb;
    float3 c1 = uLut.sample(smp, uv1).rgb;
    float3 outRgb = mix(c0, c1, fw);

    return float4(outRgb, src.a);
}

// RGBA -> RGBA passthrough (no LUT bound). Used for pass 2 when neither LUT
// nor false-color is enabled, so we still produce a right-side-up
// intermediate without needing a dummy uLut texture bound at index 1.
fragment float4 passthrough_fragment(VertexOut in [[stage_in]],
                                     texture2d<float, access::sample> uTexture [[texture(0)]],
                                     sampler smp [[sampler(0)]]) {
    return uTexture.sample(smp, in.texCoord);
}

// Final present pass: RGBA intermediate -> BGRA Flutter CVPixelBuffer.
// Flutter's iOS Texture widget samples kCVPixelFormatType_32BGRA, so the
// RGBA pipeline result must be swizzled on the way out. This is the only
// pass whose render-target format differs from the assist passes.
fragment float4 present_fragment(VertexOut in [[stage_in]],
                                 texture2d<float, access::sample> uTexture [[texture(0)]],
                                 sampler smp [[sampler(0)]]) {
    float4 src = uTexture.sample(smp, in.texCoord);
    // Write (b, g, r, a) into the BGRA8Unorm target so the displayed pixel
    // is R=src.r, G=src.g, B=src.b.
    return float4(src.b, src.g, src.r, src.a);
}
