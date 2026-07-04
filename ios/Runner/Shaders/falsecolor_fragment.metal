// False color fragment shader — Metal port of shaders/falsecolor.frag.
//
// Maps normalized luma (0..1, ~ IRE 0..1023) to a false-color palette used on
// professional cinema monitors:
//
//   0.00 - 0.01  deep purple   (shadow clip)
//   0.18         green         (18% gray / mid reference)
//   0.40 - 0.50  magenta       (skin-tone line)
//   0.70 - 0.89  yellow        (bright but not clipped)
//   0.90 - 1.00  red           (highlight clip)
//
// Bands are smoothly interpolated so transitions don't posterize abruptly.
//
// Uniforms (names kept identical to the GLSL original):
//   uTexture   (texture 0)
//   uEnabled   (buffer 0, int)

#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

static inline float luma(float3 c) {
    return dot(c, float3(0.2126, 0.7152, 0.0722));
}

// Anchor-point false-color palette — identical bands to falsecolor.frag.
static inline float3 falseColor(float l) {
    if (l < 0.01) {
        return float3(0.13, 0.0, 0.27);                         // deep purple (shadow clip)
    } else if (l < 0.17) {
        float t = (l - 0.01) / (0.17 - 0.01);
        return mix(float3(0.13, 0.0, 0.27), float3(0.0, 0.5, 0.0), t);  // purple -> green
    } else if (l < 0.20) {
        float t = (l - 0.17) / (0.20 - 0.17);
        return mix(float3(0.0, 0.5, 0.0), float3(0.0, 0.8, 0.0), t);    // 18% gray green band
    } else if (l < 0.40) {
        float t = (l - 0.20) / (0.40 - 0.20);
        return mix(float3(0.0, 0.8, 0.0), float3(0.0, 0.6, 0.2), t);
    } else if (l < 0.50) {
        float t = (l - 0.40) / (0.50 - 0.40);
        return mix(float3(0.0, 0.6, 0.2), float3(0.9, 0.0, 0.7), t);    // -> magenta skin line
    } else if (l < 0.70) {
        float t = (l - 0.50) / (0.70 - 0.50);
        return mix(float3(0.9, 0.0, 0.7), float3(0.9, 0.7, 0.0), t);    // magenta -> yellow
    } else if (l < 0.90) {
        float t = (l - 0.70) / (0.90 - 0.70);
        return mix(float3(0.9, 0.7, 0.0), float3(1.0, 1.0, 0.0), t);    // yellow band
    } else {
        float t = clamp((l - 0.90) / 0.10, 0.0, 1.0);
        return mix(float3(1.0, 1.0, 0.0), float3(1.0, 0.0, 0.0), t);    // yellow -> red clip
    }
}

fragment float4 falsecolor_fragment(VertexOut in [[stage_in]],
                                    texture2d<float, access::sample> uTexture [[texture(0)]],
                                    constant int& uEnabled [[buffer(0)]],
                                    sampler smp [[sampler(0)]]) {
    float4 src = uTexture.sample(smp, in.texCoord);
    if (uEnabled == 0) {
        return src;
    }
    float l = clamp(luma(src.rgb), 0.0, 1.0);
    return float4(falseColor(l), src.a);
}
