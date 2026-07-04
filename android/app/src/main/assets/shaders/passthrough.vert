// Passthrough vertex shader shared by all fragment passes.
// Fullscreen triangle: positions in clip space already, UVs flipped Y for GL.
// Uniforms:
//   uFlipY (int)  - 1 to flip texture Y (GL origin bottom-left), 0 otherwise.
attribute vec4 aPosition;
attribute vec2 aTexCoord;
varying vec2 vTexCoord;
uniform int uFlipY;

void main() {
    vTexCoord = aTexCoord;
    if (uFlipY == 1) {
        vTexCoord.y = 1.0 - vTexCoord.y;
    }
    gl_Position = aPosition;
}
