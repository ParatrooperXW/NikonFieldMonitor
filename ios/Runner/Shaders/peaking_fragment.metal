// Focus peaking fragment shader — Metal port of shaders/peaking.frag.
//
// Computes a brightness gradient using a Sobel operator on the luminance of
// the source texture. Pixels whose gradient magnitude exceeds a threshold
// (driven by sensitivity) are blended with a user-chosen overlay color.
//
// Sensitivity mapping (uniform uSensitivity, 0=Low / 1=Med / 2=High):
//   Low  -> threshold 0.18  (only sharp edges)
//   Med  -> threshold 0.10
//   High -> threshold 0.05  (subtle detail too)
//
// The result is blended ON TOP of the source so peaking never hides image.
//
// Uniforms (names kept identical to the GLSL original):
//   uTexture        (texture 0)
//   uTexelSize      (buffer 0, float2)  1/width, 1/height
//   uOverlayColor   (buffer 1, float3)  peaking color (linear rgb 0..1)
//   uSensitivity    (buffer 2, int)     0/1/2
//   uEnabled        (buffer 3, int)

#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

static inline float luma(float3 c) {
    return dot(c, float3(0.2126, 0.7152, 0.0722));
}

fragment float4 peaking_fragment(VertexOut in [[stage_in]],
                                 texture2d<float, access::sample> uTexture [[texture(0)]],
                                 constant float2& uTexelSize     [[buffer(0)]],
                                 constant float3& uOverlayColor  [[buffer(1)]],
                                 constant int&    uSensitivity   [[buffer(2)]],
                                 constant int&    uEnabled        [[buffer(3)]],
                                 sampler smp [[sampler(0)]]) {
    float4 src = uTexture.sample(smp, in.texCoord);
    if (uEnabled == 0) {
        return src;
    }

    float2 ts = uTexelSize;
    float2 uv = in.texCoord;
    // 3x3 Sobel on luma (identical taps to peaking.frag).
    float l00 = luma(uTexture.sample(smp, uv + float2(-ts.x,  ts.y)).rgb);
    float l10 = luma(uTexture.sample(smp, uv + float2( 0.0,   ts.y)).rgb);
    float l20 = luma(uTexture.sample(smp, uv + float2( ts.x,  ts.y)).rgb);
    float l01 = luma(uTexture.sample(smp, uv + float2(-ts.x,  0.0 )).rgb);
    float l21 = luma(uTexture.sample(smp, uv + float2( ts.x,  0.0 )).rgb);
    float l02 = luma(uTexture.sample(smp, uv + float2(-ts.x, -ts.y)).rgb);
    float l12 = luma(uTexture.sample(smp, uv + float2( 0.0,  -ts.y)).rgb);
    float l22 = luma(uTexture.sample(smp, uv + float2( ts.x, -ts.y)).rgb);

    float gx = -l00 - 2.0 * l01 - l02 + l20 + 2.0 * l21 + l22;
    float gy = -l00 - 2.0 * l10 - l20 + l02 + 2.0 * l12 + l22;
    float mag = sqrt(gx * gx + gy * gy);

    float threshold = uSensitivity == 0 ? 0.18 : (uSensitivity == 1 ? 0.10 : 0.05);
    float intensity = smoothstep(threshold, threshold + 0.05, mag);

    float3 outRgb = mix(src.rgb, uOverlayColor, intensity);
    return float4(outRgb, src.a);
}
