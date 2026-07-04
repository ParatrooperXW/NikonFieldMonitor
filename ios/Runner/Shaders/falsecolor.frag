// False color fragment shader.
//
// Maps normalized luma (0..1, ≈ IRE 0..1023) to a false-color palette used on
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
// References:
//   - SmallHD / Atomos false-color conventions
//   - DIT / focus-puller on-set reference palettes
precision mediump float;

varying vec2 vTexCoord;

uniform sampler2D uTexture;
uniform int uEnabled;

float luma(vec3 c) {
    return dot(c, vec3(0.2126, 0.7152, 0.0722));
}

vec3 falseColor(float l) {
    // Define anchor points (luma, color).
    // Colors are linear-ish RGB.
    if (l < 0.01) {
        return vec3(0.13, 0.0, 0.27);        // deep purple (shadow clip)
    } else if (l < 0.17) {
        float t = (l - 0.01) / (0.17 - 0.01);
        return mix(vec3(0.13, 0.0, 0.27), vec3(0.0, 0.5, 0.0), t);  // purple -> green
    } else if (l < 0.20) {
        float t = (l - 0.17) / (0.20 - 0.17);
        return mix(vec3(0.0, 0.5, 0.0), vec3(0.0, 0.8, 0.0), t);    // 18% gray green band
    } else if (l < 0.40) {
        float t = (l - 0.20) / (0.40 - 0.20);
        return mix(vec3(0.0, 0.8, 0.0), vec3(0.0, 0.6, 0.2), t);
    } else if (l < 0.50) {
        float t = (l - 0.40) / (0.50 - 0.40);
        return mix(vec3(0.0, 0.6, 0.2), vec3(0.9, 0.0, 0.7), t);    // -> magenta skin line
    } else if (l < 0.70) {
        float t = (l - 0.50) / (0.70 - 0.50);
        return mix(vec3(0.9, 0.0, 0.7), vec3(0.9, 0.7, 0.0), t);    // magenta -> yellow
    } else if (l < 0.90) {
        float t = (l - 0.70) / (0.90 - 0.70);
        return mix(vec3(0.9, 0.7, 0.0), vec3(1.0, 1.0, 0.0), t);     // yellow band
    } else {
        float t = clamp((l - 0.90) / 0.10, 0.0, 1.0);
        return mix(vec3(1.0, 1.0, 0.0), vec3(1.0, 0.0, 0.0), t);     // yellow -> red clip
    }
}

void main() {
    vec4 src = texture2D(uTexture, vTexCoord);
    if (uEnabled == 0) {
        gl_FragColor = src;
        return;
    }
    float l = clamp(luma(src.rgb), 0.0, 1.0);
    gl_FragColor = vec4(falseColor(l), src.a);
}
