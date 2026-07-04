// Zebra (IRE) fragment shader.
//
// Pixels whose luma (mapped to IRE 0..100) falls inside [uLowerIre, uUpperIre]
// get a 45-degree diagonal stripe pattern overlaid, so the operator can see
// where exposure hits the chosen IRE band (e.g. 70-100 for skin, 90-100 over).
//
// The stripe pattern is computed in fragment coordinates (uResolution) so it
// stays fixed regardless of camera motion — same convention as on-set monitors.
precision mediump float;

varying vec2 vTexCoord;

uniform sampler2D uTexture;
uniform vec2 uResolution;    // output buffer size in pixels
uniform float uLowerIre;     // 0..100
uniform float uUpperIre;     // 0..100
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

    // Luma 0..1 -> IRE 0..100. (For a true IRE scale on Nikon N-Log this would
    // require a log-to-linear step first; for sRGB LiveView output this 1:1
    // mapping is the practical approximation.)
    float ire = luma(src.rgb) * 100.0;

    if (ire >= uLowerIre && ire <= uUpperIre) {
        // Diagonal stripe pattern at 45 degrees, period 8px.
        vec2 px = vTexCoord * uResolution;
        float stripe = mod(px.x + px.y, 8.0);
        if (stripe < 4.0) {
            // Overlay translucent white with negative-blend feel (classic zebra).
            vec3 zebra = vec3(1.0) - src.rgb;
            gl_FragColor = vec4(mix(src.rgb, zebra, 0.5), src.a);
            return;
        }
    }
    gl_FragColor = src;
}
