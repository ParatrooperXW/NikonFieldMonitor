// Zebra (IRE) fragment shader — Metal port of shaders/zebra.frag.
//
// Pixels whose luma (mapped to IRE 0..100) falls inside [uLowerIre, uUpperIre]
// get a 45-degree diagonal stripe pattern overlaid, so the operator can see
// where exposure hits the chosen IRE band (e.g. 70-100 for skin, 90-100 over).
//
// The stripe pattern is computed in fragment coordinates (uResolution) so it
// stays fixed regardless of camera motion — same convention as on-set monitors.
//
// Uniforms (names kept identical to the GLSL original):
//   uTexture     (texture 0)
//   uResolution  (buffer 0, float2)  output buffer size in pixels
//   uLowerIre    (buffer 1, float)   0..100
//   uUpperIre    (buffer 2, float)   0..100
//   uEnabled     (buffer 3, int)

#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

static inline float luma(float3 c) {
    return dot(c, float3(0.2126, 0.7152, 0.0722));
}

fragment float4 zebra_fragment(VertexOut in [[stage_in]],
                               texture2d<float, access::sample> uTexture [[texture(0)]],
                               constant float2& uResolution [[buffer(0)]],
                               constant float&  uLowerIre   [[buffer(1)]],
                               constant float&  uUpperIre   [[buffer(2)]],
                               constant int&    uEnabled     [[buffer(3)]],
                               sampler smp [[sampler(0)]]) {
    float4 src = uTexture.sample(smp, in.texCoord);
    if (uEnabled == 0) {
        return src;
    }

    // Luma 0..1 -> IRE 0..100. (For a true IRE scale on Nikon N-Log this would
    // require a log-to-linear step first; for sRGB LiveView output this 1:1
    // mapping is the practical approximation.)
    float ire = luma(src.rgb) * 100.0;

    if (ire >= uLowerIre && ire <= uUpperIre) {
        // Diagonal stripe pattern at 45 degrees, period 8px.
        float2 px = in.texCoord * uResolution;
        float stripe = fmod(px.x + px.y, 8.0);
        if (stripe < 4.0) {
            // Overlay translucent white with negative-blend feel (classic zebra).
            float3 zebra = float3(1.0) - src.rgb;
            return float4(mix(src.rgb, zebra, 0.5), src.a);
        }
    }
    return src;
}
