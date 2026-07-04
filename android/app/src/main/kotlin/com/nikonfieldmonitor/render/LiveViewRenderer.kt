package com.nikonfieldmonitor.render

import android.content.res.AssetManager
import android.graphics.BitmapFactory
import android.graphics.SurfaceTexture
import android.opengl.GLES11Ext
import android.opengl.GLES20
import android.opengl.GLSurfaceView
import android.opengl.Matrix
import android.util.Log
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer
import javax.microedition.khronos.egl.EGLConfig
import javax.microedition.khronos.opengles.GL10

/**
 * The full LiveView GPU pipeline.
 *
 * Passes (per spec):
 *   1. JPEG decode -> RGBA texture (frame texture)
 *   2. LUT pass (if enabled AND false color off) -> intermediate FBO
 *   3. False color pass (if on; skips 2) -> intermediate FBO
 *   4. Peaking edge detect -> blend on top
 *   5. Zebra IRE banding -> blend on top
 *   6. Final composite -> SurfaceTexture (Flutter TextureRegistry)
 *
 * The GL context is created on a dedicated GLSurfaceView-less EGL surface
 * bound to a SurfaceTexture that Flutter renders via Texture widget.
 */
class LiveViewRenderer(
    private val assets: AssetManager,
    private val outputTexture: SurfaceTexture,
) : GLSurfaceView.Renderer {

    // Frame texture (uploaded JPEG decode)
    private var frameTexture = 0
    private var frameWidth = 1920
    private var frameHeight = 1080
    private var pendingJpeg: ByteArray? = null
    private val pendingLock = Any()

    // Intermediate FBO for LUT/false-color pass
    private var fbo = 0
    private var fboTexture = 0

    // Programs
    private var lutProgram: ShaderProgram? = null
    private var peakingProgram: ShaderProgram? = null
    private var zebraProgram: ShaderProgram? = null
    private var falseColorProgram: ShaderProgram? = null

    // LUT 3D texture registry: lutId -> (glTexture, size)
    private val luts = mutableMapOf<String, Pair<Int, Int>>()
    private var activeLutId: String? = null

    // Quad geometry
    private val quadVerts = floatArrayOf(
        -1f, -1f, 0f, 0f,
         1f, -1f, 1f, 0f,
        -1f,  1f, 0f, 1f,
         1f,  1f, 1f, 1f,
    )
    private lateinit var quadBuffer: FloatBuffer

    // Assist settings (mirrors Dart MonitorAssistSettings.toBridgeMap())
    data class Settings(
        var peakingEnabled: Boolean = false,
        var peakingColor: String = "red",
        var peakingSensitivity: Int = 1,
        var zebraEnabled: Boolean = false,
        var zebraLowerIre: Int = 70,
        var zebraUpperIre: Int = 100,
        var falseColorEnabled: Boolean = false,
        var lutEnabled: Boolean = false,
        var activeLutId: String? = null,
        var histogramMode: Int = 0,
        var waveformPlacement: Int = 0,
        var waveformOpacity: Float = 0.6f,
        var safeFrame: Int = 0,
        var hudVisible: Boolean = true,
    )

    val settings = Settings()

    override fun onSurfaceCreated(gl: GL10?, config: EGLConfig?) {
        GLES20.glClearColor(0f, 0f, 0f, 1f)
        GLES20.glDisable(GLES20.GL_DEPTH_TEST)

        quadBuffer = ByteBuffer.allocateDirect(quadVerts.size * 4)
            .order(ByteOrder.nativeOrder()).asFloatBuffer().put(quadVerts)
        quadBuffer.position(0)

        // Frame texture
        val tx = IntArray(1)
        GLES20.glGenTextures(1, tx, 0)
        frameTexture = tx[0]
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, frameTexture)
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR)
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)

        // Programs
        lutProgram = ShaderProgram(assets, "lut.frag").also { it.build() }
        peakingProgram = ShaderProgram(assets, "peaking.frag").also { it.build() }
        zebraProgram = ShaderProgram(assets, "zebra.frag").also { it.build() }
        falseColorProgram = ShaderProgram(assets, "falsecolor.frag").also { it.build() }
    }

    override fun onSurfaceChanged(gl: GL10?, width: Int, height: Int) {
        GLES20.glViewport(0, 0, width, height)
        rebuildFbo(width, height)
    }

    override fun onDrawFrame(gl: GL10?) {
        GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)

        // Upload any pending JPEG into frameTexture.
        synchronized(pendingLock) {
            val jpeg = pendingJpeg
            if (jpeg != null) {
                uploadJpegToTexture(jpeg)
                pendingJpeg = null
            }
        }

        // Stage 1: pass through frameTexture with optional LUT / false color.
        // We render into the FBO so the later peaking/zebra passes can sample
        // a single intermediate texture.
        val lutEnabled = settings.lutEnabled && !settings.falseColorEnabled && activeLutId != null
        val falseColorEnabled = settings.falseColorEnabled

        val stageProgram = when {
            falseColorEnabled -> falseColorProgram
            lutEnabled -> lutProgram
            else -> lutProgram // LUT pass with uEnabled=0 = passthrough
        }
        stageProgram!!.use()
        GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, fbo)
        GLES20.glViewport(0, 0, fboWidth, fboHeight)
        GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)

        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, frameTexture)
        GLES20.glUniform1i(stageProgram.uniform("uTexture"), 0)
        GLES20.glUniform1i(stageProgram.uFlipY, 1)

        if (falseColorEnabled) {
            GLES20.glUniform1i(stageProgram.uniform("uEnabled"), 1)
        } else if (lutEnabled) {
            val (lutTex, size) = luts[activeLutId] ?: (0 to 0)
            GLES20.glActiveTexture(GLES20.GL_TEXTURE1)
            GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, lutTex)
            GLES20.glUniform1i(stageProgram.uniform("uLut"), 1)
            GLES20.glUniform1f(stageProgram.uniform("uLutSize"), size.toFloat())
            GLES20.glUniform1i(stageProgram.uniform("uEnabled"), 1)
        } else {
            GLES20.glUniform1i(stageProgram.uniform("uEnabled"), 0)
        }
        drawQuad(stageProgram)

        // Stages 4-5: peaking + zebra blend on top, into the FBO as well.
        if (settings.peakingEnabled) {
            val peakProg = peakingProgram ?: return
            peakProg.use()
            GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, fbo)
            GLES20.glViewport(0, 0, fboWidth, fboHeight)
            GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
            GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, fboTexture)
            GLES20.glUniform1i(peakProg.uniform("uTexture"), 0)
            GLES20.glUniform1i(peakProg.uFlipY, 0)
            GLES20.glUniform2f(
                peakProg.uniform("uTexelSize"),
                1f / fboWidth, 1f / fboHeight,
            )
            val peakColor = peakingColorRgb(settings.peakingColor)
            GLES20.glUniform3f(
                peakProg.uniform("uOverlayColor"),
                peakColor[0], peakColor[1], peakColor[2],
            )
            GLES20.glUniform1i(peakProg.uniform("uSensitivity"), settings.peakingSensitivity)
            GLES20.glUniform1i(peakProg.uniform("uEnabled"), 1)
            drawQuad(peakProg)
        }

        if (settings.zebraEnabled) {
            val zebProg = zebraProgram ?: return
            zebProg.use()
            GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, fbo)
            GLES20.glViewport(0, 0, fboWidth, fboHeight)
            GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
            GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, fboTexture)
            GLES20.glUniform1i(zebProg.uniform("uTexture"), 0)
            GLES20.glUniform1i(zebProg.uFlipY, 0)
            GLES20.glUniform2f(zebProg.uniform("uResolution"), fboWidth.toFloat(), fboHeight.toFloat())
            GLES20.glUniform1f(zebProg.uniform("uLowerIre"), settings.zebraLowerIre.toFloat())
            GLES20.glUniform1f(zebProg.uniform("uUpperIre"), settings.zebraUpperIre.toFloat())
            GLES20.glUniform1i(zebProg.uniform("uEnabled"), 1)
            drawQuad(zebProg)
        }

        // Final blit: fboTexture -> default framebuffer (the SurfaceTexture).
        val finalProg = lutProgram ?: return
        GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, 0)
        GLES20.glViewport(0, 0, viewportWidth, viewportHeight)
        finalProg.use()
        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, fboTexture)
        GLES20.glUniform1i(finalProg.uniform("uTexture"), 0)
        GLES20.glUniform1i(finalProg.uniform("uEnabled"), 0)
        GLES20.glUniform1i(finalProg.uFlipY, 0)
        drawQuad(finalProg)
    }

    private fun drawQuad(prog: ShaderProgram) {
        quadBuffer.position(0)
        if (prog.aPosition >= 0) {
            GLES20.glEnableVertexAttribArray(prog.aPosition)
            GLES20.glVertexAttribPointer(prog.aPosition, 2, GLES20.GL_FLOAT, false, 16, quadBuffer)
        }
        quadBuffer.position(2)
        if (prog.aTexCoord >= 0) {
            GLES20.glEnableVertexAttribArray(prog.aTexCoord)
            GLES20.glVertexAttribPointer(prog.aTexCoord, 2, GLES20.GL_FLOAT, false, 16, quadBuffer)
        }
        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
    }

    private var fboWidth = 1920
    private var fboHeight = 1080
    private var viewportWidth = 1920
    private var viewportHeight = 1080

    private fun rebuildFbo(w: Int, h: Int) {
        viewportWidth = w
        viewportHeight = h
        // Keep FBO at frame resolution for fidelity.
        val fw = frameWidth.coerceAtLeast(2)
        val fh = frameHeight.coerceAtLeast(2)
        if (fboWidth == fw && fboHeight == fh && fbo != 0) return
        fboWidth = fw
        fboHeight = fh
        if (fbo != 0) {
            GLES20.glDeleteFramebuffers(1, intArrayOf(fbo), 0)
            GLES20.glDeleteTextures(1, intArrayOf(fboTexture), 0)
        }
        val gen = IntArray(2)
        GLES20.glGenTextures(1, gen, 0)
        fboTexture = gen[0]
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, fboTexture)
        GLES20.glTexImage2D(
            GLES20.GL_TEXTURE_2D, 0, GLES20.GL_RGBA,
            fw, fh, 0, GLES20.GL_RGBA, GLES20.GL_UNSIGNED_BYTE, null,
        )
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR)
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)

        GLES20.glGenFramebuffers(1, gen, 1)
        fbo = gen[1]
        GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, fbo)
        GLES20.glFramebufferTexture2D(
            GLES20.GL_FRAMEBUFFER, GLES20.GL_COLOR_ATTACHMENT0,
            GLES20.GL_TEXTURE_2D, fboTexture, 0,
        )
        GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, 0)
    }

    fun pushJpeg(jpeg: ByteArray) {
        synchronized(pendingLock) { pendingJpeg = jpeg }
    }

    fun pushRgba(rgba: ByteArray, width: Int, height: Int) {
        // Direct RGBA upload (used when Dart Isolate decoded the frame).
        synchronized(pendingLock) {
            frameWidth = width
            frameHeight = height
            GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, frameTexture)
            GLES20.glTexImage2D(
                GLES20.GL_TEXTURE_2D, 0, GLES20.GL_RGBA,
                width, height, 0, GLES20.GL_RGBA, GLES20.GL_UNSIGNED_BYTE,
                ByteBuffer.wrap(rgba),
            )
        }
    }

    private fun uploadJpegToTexture(jpeg: ByteArray) {
        val bmp = BitmapFactory.decodeByteArray(jpeg, 0, jpeg.size) ?: return
        frameWidth = bmp.width
        frameHeight = bmp.height
        // Ensure FBO matches new frame size.
        rebuildFbo(viewportWidth, viewportHeight)
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, frameTexture)
        GLES20.glTexImage2D(
            GLES20.GL_TEXTURE_2D, 0, GLES20.GL_RGBA,
            bmp.width, bmp.height, 0, GLES20.GL_RGBA, GLES20.GL_UNSIGNED_BYTE,
            ByteBuffer.wrap(pixelsFromBitmap(bmp)),
        )
        bmp.recycle()
    }

    private fun pixelsFromBitmap(bmp: android.graphics.Bitmap): ByteArray {
        val buf = ByteBuffer.allocate(bmp.width * bmp.height * 4)
        bmp.copyPixelsToBuffer(buf)
        return buf.array()
    }

    fun uploadLut(lutId: String, rgba: ByteArray, size: Int) {
        val tex = IntArray(1)
        GLES20.glGenTextures(1, tex, 0)
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, tex[0])
        GLES20.glTexImage2D(
            GLES20.GL_TEXTURE_2D, 0, GLES20.GL_RGBA,
            size * size, size, 0, GLES20.GL_RGBA, GLES20.GL_UNSIGNED_BYTE,
            ByteBuffer.wrap(rgba),
        )
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR)
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)
        luts[lutId] = tex[0] to size
    }

    fun removeLut(lutId: String) {
        val pair = luts.remove(lutId) ?: return
        GLES20.glDeleteTextures(1, intArrayOf(pair.first), 0)
        if (activeLutId == lutId) activeLutId = null
    }

    fun setActiveLut(lutId: String?) {
        activeLutId = lutId
    }

    private fun peakingColorRgb(name: String): FloatArray = when (name) {
        "red" -> floatArrayOf(1f, 0f, 0f)
        "green" -> floatArrayOf(0f, 1f, 0f)
        "blue" -> floatArrayOf(0f, 0.69f, 1f)
        "yellow" -> floatArrayOf(1f, 1f, 0f)
        "white" -> floatArrayOf(1f, 1f, 1f)
        else -> floatArrayOf(1f, 0f, 0f)
    }

    fun release() {
        lutProgram?.release()
        peakingProgram?.release()
        zebraProgram?.release()
        falseColorProgram?.release()
        if (fbo != 0) {
            GLES20.glDeleteFramebuffers(1, intArrayOf(fbo), 0)
            GLES20.glDeleteTextures(1, intArrayOf(fboTexture), 0)
        }
        if (frameTexture != 0) GLES20.glDeleteTextures(1, intArrayOf(frameTexture), 0)
        for ((_, pair) in luts) {
            GLES20.glDeleteTextures(1, intArrayOf(pair.first), 0)
        }
        luts.clear()
    }

    companion object {
        private const val TAG = "LiveViewRenderer"
    }
}
