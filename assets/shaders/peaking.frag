// Focus peaking fragment shader.
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
precision mediump float;

varying vec2 vTexCoord;

uniform sampler2D uTexture;
uniform vec2 uTexelSize;        // 1/width, 1/height
uniform vec3 uOverlayColor;     // peaking color (linear rgb 0..1)
uniform int uSensitivity;       // 0/1/2
uniform int uEnabled;

float luma(vec3 c) {
    return dot(c, vec3(0.2126, 0.7152, 0.0722));
}

void main() {
    vec4 src = texture2D(uTexture, vTexCoord);
    if (uEnabled == 0) {
        gl_FragColor = src;
        return;
    }

    vec2 ts = uTexelSize;
    // 3x3 Sobel on luma
    float l00 = luma(texture2D(uTexture, vTexCoord + vec2(-ts.x,  ts.y)).rgb);
    float l10 = luma(texture2D(uTexture, vTexCoord + vec2( 0.0,   ts.y)).rgb);
    float l20 = luma(texture2D(uTexture, vTexCoord + vec2( ts.x,  ts.y)).rgb);
    float l01 = luma(texture2D(uTexture, vTexCoord + vec2(-ts.x,  0.0  )).rgb);
    float l21 = luma(texture2D(uTexture, vTexCoord + vec2( ts.x,  0.0  )).rgb);
    float l02 = luma(texture2D(uTexture, vTexCoord + vec2(-ts.x, -ts.y)).rgb);
    float l12 = luma(texture2D(uTexture, vTexCoord + vec2( 0.0,  -ts.y)).rgb);
    float l22 = luma(texture2D(uTexture, vTexCoord + vec2( ts.x, -ts.y)).rgb);

    float gx = -l00 - 2.0 * l01 - l02 + l20 + 2.0 * l21 + l22;
    float gy = -l00 - 2.0 * l10 - l20 + l02 + 2.0 * l12 + l22;
    float mag = sqrt(gx * gx + gy * gy);

    float threshold = uSensitivity == 0 ? 0.18 : (uSensitivity == 1 ? 0.10 : 0.05);
    float intensity = smoothstep(threshold, threshold + 0.05, mag);

    vec3 outRgb = mix(src.rgb, uOverlayColor, intensity);
    gl_FragColor = vec4(outRgb, src.a);
}
