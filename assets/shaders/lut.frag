// 3D LUT fragment shader (2D-packed).
//
// Samples the live-view RGBA texture, applies a 3D LUT packed into a 2D
// texture of size (N*N) x N, with manual trilinear interpolation across the
// three axes. Standard technique (Oscar/Matt Diamond 2D-packed 3D LUT).
//
// References:
//   - "Using a 3D LUT as a 2D texture" (Matt Diamond)
//   - GPUImage 3 / MetalPetal lookup texture approach
//
// Uniforms:
//   uTexture        - live-view RGBA texture
//   uLut            - 2D-packed 3D LUT texture
//   uLutSize        - LUT size N (e.g. 17, 25, 33, 64)
//   uEnabled        - 1 to apply LUT, 0 to pass through
precision mediump float;

varying vec2 vTexCoord;

uniform sampler2D uTexture;
uniform sampler2D uLut;
uniform float uLutSize;   // N
uniform int uEnabled;

// Map a 3D LUT coordinate (r,g,b in [0,1]) into the 2D-packed texture.
// Layout: width = N*N, height = N. For a given (b,g,r):
//   tile = floor(b * (N-1))   (which N-wide tile)
//   x within tile = r
//   y = g
vec2 lut3dTo2d(vec3 rgb, float n) {
    float nb = clamp(rgb.b, 0.0, 1.0) * (n - 1.0);
    float tile = floor(nb);
    float frac_b = nb - tile;
    // We blend two tiles for trilinear along B; here we just pick nearest tile
    // for the 2D sample call (trilinear handled in caller).
    float x = (tile * n + clamp(rgb.r, 0.0, 1.0) * (n - 1.0) + 0.5) / (n * n);
    float y = (clamp(rgb.g, 0.0, 1.0) * (n - 1.0) + 0.5) / n;
    return vec2(x, y);
}

void main() {
    vec4 src = texture2D(uTexture, vTexCoord);
    if (uEnabled == 0) {
        gl_FragColor = src;
        return;
    }
    float n = uLutSize;
    vec3 rgb = src.rgb;

    // Trilinear interpolation along B axis.
    float nb = clamp(rgb.b, 0.0, 1.0) * (n - 1.0);
    float b0 = floor(nb);
    float b1 = min(b0 + 1.0, n - 1.0);
    float fw = nb - b0;

    vec2 uv0 = vec2((b0 * n + clamp(rgb.r, 0.0, 1.0) * (n - 1.0) + 0.5) / (n * n),
                    (clamp(rgb.g, 0.0, 1.0) * (n - 1.0) + 0.5) / n);
    vec2 uv1 = vec2((b1 * n + clamp(rgb.r, 0.0, 1.0) * (n - 1.0) + 0.5) / (n * n),
                    (clamp(rgb.g, 0.0, 1.0) * (n - 1.0) + 0.5) / n);

    vec3 c0 = texture2D(uLut, uv0).rgb;
    vec3 c1 = texture2D(uLut, uv1).rgb;
    vec3 outRgb = mix(c0, c1, fw);

    gl_FragColor = vec4(outRgb, src.a);
}
