package com.nikonfieldmonitor.render

import android.opengl.GLES20
import android.util.Log
import java.io.BufferedReader
import java.io.InputStreamReader

/**
 * Compiles + links a GLSL program from an Android asset path.
 *
 * The vertex shader is shared ([passthrough.vert]); each fragment shader
 * (lut.frag / peaking.frag / zebra.frag / falsecolor.frag) is loaded by name.
 */
class ShaderProgram(
    private val assets: android.content.res.AssetManager,
    private val fragAsset: String,
) {
    private var program = 0
    private var vertexShader = 0
    private var fragmentShader = 0

    var aPosition = 0
        private set
    var aTexCoord = 0
        private set
    var uFlipY = 0
        private set

    fun build() {
        val vertSrc = readAsset("shaders/passthrough.vert")
        val fragSrc = readAsset("shaders/$fragAsset")
        vertexShader = compile(GLES20.GL_VERTEX_SHADER, vertSrc)
        fragmentShader = compile(GLES20.GL_FRAGMENT_SHADER, fragSrc)
        program = GLES20.glCreateProgram()
        GLES20.glAttachShader(program, vertexShader)
        GLES20.glAttachShader(program, fragmentShader)
        GLES20.glLinkProgram(program)
        val status = IntArray(1)
        GLES20.glGetProgramiv(program, GLES20.GL_LINK_STATUS, status, 0)
        if (status[0] != GLES20.GL_TRUE) {
            val log = GLES20.glGetProgramInfoLog(program)
            Log.e(TAG, "Link failed for $fragAsset: $log")
            throw IllegalStateException("Shader link failed: $log")
        }
        aPosition = GLES20.glGetAttribLocation(program, "aPosition")
        aTexCoord = GLES20.glGetAttribLocation(program, "aTexCoord")
        uFlipY = GLES20.glGetUniformLocation(program, "uFlipY")
    }

    fun use() = GLES20.glUseProgram(program)

    fun uniform(name: String): Int = GLES20.glGetUniformLocation(program, name)

    fun release() {
        if (vertexShader != 0) GLES20.glDeleteShader(vertexShader)
        if (fragmentShader != 0) GLES20.glDeleteShader(fragmentShader)
        if (program != 0) GLES20.glDeleteProgram(program)
        program = 0
    }

    private fun compile(type: Int, src: String): Int {
        val sh = GLES20.glCreateShader(type)
        GLES20.glShaderSource(sh, src)
        GLES20.glCompileShader(sh)
        val status = IntArray(1)
        GLES20.glGetShaderiv(sh, GLES20.GL_COMPILE_STATUS, status, 0)
        if (status[0] != GLES20.GL_TRUE) {
            val log = GLES20.glGetShaderInfoLog(sh)
            Log.e(TAG, "Compile failed ($fragAsset): $log")
            GLES20.glDeleteShader(sh)
            throw IllegalStateException("Shader compile failed: $log")
        }
        return sh
    }

    private fun readAsset(path: String): String {
        assets.open(path).use { ins ->
            return BufferedReader(InputStreamReader(ins)).readText()
        }
    }

    companion object {
        private const val TAG = "ShaderProgram"
    }
}
