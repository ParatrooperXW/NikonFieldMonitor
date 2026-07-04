package com.nikonfieldmonitor.render

import android.content.Context
import android.graphics.SurfaceTexture
import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.EGLContext
import android.opengl.EGLDisplay
import android.opengl.EGLSurface
import android.opengl.GLES20
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import java.nio.ByteBuffer

/**
 * FlutterPlugin binding for the "nikon_field_monitor/render" MethodChannel.
 *
 * Owns a background [HandlerThread] with its own EGL context + surface so we
 * can render into a Flutter [TextureRegistry.SurfaceTextureEntry] without
 * touching the platform UI thread.
 *
 * Methods (mirror of Dart RenderBridge contract):
 *   createTexture()                              -> {textureId: Long}
 *   releaseTexture(textureId)                    -> null
 *   pushJpegFrame(textureId, jpeg)               -> null
 *   pushRgbaFrame(textureId, rgba, w, h)         -> null
 *   updateAssistSettings(textureId, settings)    -> null
 *   uploadLut(lutId, rgba, size)                 -> null
 *   removeLut(lutId)                             -> null
 *   setLutActive(textureId, lutId)               -> null
 *
 * Events ("nikon_field_monitor/render/events"):
 *   {event: "frameStats", fps, latencyMs, width, height}
 *   {event: "renderError", message}
 */
class RenderPlugin(private val appContext: Context) : FlutterPlugin, MethodChannel.MethodCallHandler {

    private var binding: FlutterPlugin.FlutterPluginBinding? = null
    private var methodChannel: MethodChannel? = null
    private var eventChannel: EventChannel? = null
    private var eventSink: EventChannel.EventSink? = null

    private val renderers = mutableMapOf<Long, RendererEntry>()
    private var renderThread: HandlerThread? = null
    private var renderHandler: Handler? = null

    override fun onAttachedToEngine(b: FlutterPlugin.FlutterPluginBinding) {
        binding = b
        methodChannel = MethodChannel(b.binaryMessenger, "nikon_field_monitor/render").also {
            it.setMethodCallHandler(this)
        }
        eventChannel = EventChannel(b.binaryMessenger, "nikon_field_monitor/render/events").also {
            it.setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) {
                    eventSink = sink
                }
                override fun onCancel(arguments: Any?) {
                    eventSink = null
                }
            })
        }
        renderThread = HandlerThread("NikonGLThread").also { it.start() }
        renderHandler = Handler(renderThread!!.looper)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel?.setMethodCallHandler(null)
        methodChannel = null
        eventChannel?.setStreamHandler(null)
        eventChannel = null
        for (e in renderers.values) e.release()
        renderers.clear()
        renderThread?.quitSafely()
        renderThread = null
        renderHandler = null
        this.binding = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "createTexture" -> createTexture(result)
            "releaseTexture" -> {
                val id = (call.argument<Number>("textureId") ?: -1).toLong()
                renderers[id]?.release()
                renderers.remove(id)
                result.success(null)
            }
            "pushJpegFrame" -> {
                val id = (call.argument<Number>("textureId") ?: -1).toLong()
                val jpeg = call.argument<ByteArray>("jpeg")
                renderers[id]?.pushJpeg(jpeg ?: ByteArray(0))
                result.success(null)
            }
            "pushRgbaFrame" -> {
                val id = (call.argument<Number>("textureId") ?: -1).toLong()
                val rgba = call.argument<ByteArray>("rgba") ?: ByteArray(0)
                val w = call.argument<Number>("width")?.toInt() ?: 0
                val h = call.argument<Number>("height")?.toInt() ?: 0
                renderers[id]?.pushRgba(rgba, w, h)
                result.success(null)
            }
            "updateAssistSettings" -> {
                val id = (call.argument<Number>("textureId") ?: -1).toLong()
                @Suppress("UNCHECKED_CAST")
                val map = call.argument<Map<String, Any?>>("settings") ?: emptyMap<String, Any?>()
                renderers[id]?.updateSettings(map)
                result.success(null)
            }
            "uploadLut" -> {
                val lutId = call.argument<String>("lutId") ?: return result.error("bad", "lutId", null)
                val rgba = call.argument<ByteArray>("rgba") ?: ByteArray(0)
                val size = call.argument<Number>("size")?.toInt() ?: 0
                // Apply to every renderer (LUT textures are global).
                for (e in renderers.values) e.uploadLut(lutId, rgba, size)
                result.success(null)
            }
            "removeLut" -> {
                val lutId = call.argument<String>("lutId") ?: return result.error("bad", "lutId", null)
                for (e in renderers.values) e.removeLut(lutId)
                result.success(null)
            }
            "setLutActive" -> {
                val id = (call.argument<Number>("textureId") ?: -1).toLong()
                val lutId = call.argument<String>("lutId")
                renderers[id]?.setActiveLut(lutId)
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun createTexture(result: MethodChannel.Result) {
        val b = binding ?: return result.error("no-binding", "FlutterPluginBinding null", null)
        val entry = b.textureRegistry.createSurfaceTexture()
        val surfaceTexture = entry.surfaceTexture()
        val renderer = RendererEntry(appContext, surfaceTexture, renderHandler!!) { msg ->
            eventSink?.success(mapOf("event" to "renderError", "message" to msg))
        }
        renderers[entry.id()] = renderer
        result.success(entry.id())
    }

    private class RendererEntry(
        private val ctx: Context,
        private val surfaceTexture: SurfaceTexture,
        private val handler: Handler,
        private val onError: (String) -> Unit,
    ) {
        private var egl: EglHelper? = null
        private var renderer: LiveViewRenderer? = null
        private var fpsLastNs = 0L
        private var fpsFrames = 0
        private var lastFps = 0.0

        init { handler.post { init() } }

        private fun init() {
            try {
                egl = EglHelper().also { it.init(surfaceTexture) }
                renderer = LiveViewRenderer(ctx.assets, surfaceTexture).also {
                    it.onSurfaceCreated(null, null)
                    // Default size; gets updated on first frame.
                    it.onSurfaceChanged(null, 1920, 1080)
                }
            } catch (e: Exception) {
                Log.e(TAG, "Renderer init failed", e)
                onError(e.message ?: "init failed")
            }
        }

        fun pushJpeg(jpeg: ByteArray) {
            handler.post {
                try {
                    renderer?.pushJpeg(jpeg)
                    drawFrame()
                } catch (e: Exception) {
                    onError(e.message ?: "draw failed")
                }
            }
        }

        fun pushRgba(rgba: ByteArray, w: Int, h: Int) {
            handler.post {
                try {
                    renderer?.pushRgba(rgba, w, h)
                    drawFrame()
                } catch (e: Exception) {
                    onError(e.message ?: "draw failed")
                }
            }
        }

        fun updateSettings(map: Map<String, Any?>) {
            handler.post {
                val s = renderer?.settings ?: return@post
                s.peakingEnabled = map["peakingEnabled"] as? Boolean ?: false
                s.peakingColor = map["peakingColor"] as? String ?: "red"
                s.peakingSensitivity = (map["peakingSensitivity"] as? Number)?.toInt() ?: 1
                s.zebraEnabled = map["zebraEnabled"] as? Boolean ?: false
                s.zebraLowerIre = (map["zebraLowerIre"] as? Number)?.toInt() ?: 70
                s.zebraUpperIre = (map["zebraUpperIre"] as? Number)?.toInt() ?: 100
                s.falseColorEnabled = map["falseColorEnabled"] as? Boolean ?: false
                s.lutEnabled = map["lutEnabled"] as? Boolean ?: false
                s.activeLutId = map["activeLutId"] as? String
                s.histogramMode = (map["histogramMode"] as? Number)?.toInt() ?: 0
                s.waveformPlacement = (map["waveformPlacement"] as? Number)?.toInt() ?: 0
                s.waveformOpacity = (map["waveformOpacity"] as? Number)?.toFloat() ?: 0.6f
                s.safeFrame = (map["safeFrame"] as? Number)?.toInt() ?: 0
                s.hudVisible = map["hudVisible"] as? Boolean ?: true
            }
        }

        fun uploadLut(lutId: String, rgba: ByteArray, size: Int) {
            handler.post { renderer?.uploadLut(lutId, rgba, size) }
        }

        fun removeLut(lutId: String) {
            handler.post { renderer?.removeLut(lutId) }
        }

        fun setActiveLut(lutId: String?) {
            handler.post { renderer?.setActiveLut(lutId) }
        }

        private fun drawFrame() {
            val r = renderer ?: return
            r.onDrawFrame(null)
            egl?.swapBuffers()
            fpsFrames++
            val now = System.nanoTime()
            if (now - fpsLastNs > 1_000_000_000L) {
                lastFps = fpsFrames * 1_000_000_000.0 / (now - fpsLastNs)
                fpsLastNs = now
                fpsFrames = 0
            }
        }

        fun release() {
            handler.post {
                renderer?.release()
                egl?.release()
            }
        }

        companion object { private const val TAG = "RendererEntry" }
    }

    /**
     * Minimal EGL bootstrap: creates a context + pbuffer/ window surface bound
     * to the Flutter SurfaceTexture so we can GL-render off the UI thread.
     */
    private class EglHelper {
        private var display: EGLDisplay = EGL14.EGL_NO_DISPLAY
        private var context: EGLContext = EGL14.EGL_NO_CONTEXT
        private var surface: EGLSurface = EGL14.EGL_NO_SURFACE
        private var config: EGLConfig? = null

        fun init(surfaceTexture: SurfaceTexture) {
            display = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
            EGL14.eglInitialize(display, null, 0, null, 0)
            val configs = arrayOfNulls<EGLConfig>(1)
            val numConfig = IntArray(1)
            val attribs = intArrayOf(
                EGL14.EGL_RED_SIZE, 8,
                EGL14.EGL_GREEN_SIZE, 8,
                EGL14.EGL_BLUE_SIZE, 8,
                EGL14.EGL_ALPHA_SIZE, 8,
                EGL14.EGL_RENDERABLE_TYPE, EGL14.EGL_OPENGL_ES2_BIT,
                EGL14.EGL_NONE,
            )
            EGL14.eglChooseConfig(display, attribs, 0, configs, 0, 1, numConfig, 0)
            config = configs[0]
            val ctxAttribs = intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 2, EGL14.EGL_NONE)
            context = EGL14.eglCreateContext(display, config, EGL14.EGL_NO_CONTEXT, ctxAttribs, 0)
            val surfaceAttribs = intArrayOf(EGL14.EGL_NONE)
            surface = EGL14.eglCreateWindowSurface(display, config, surfaceTexture, surfaceAttribs, 0)
            EGL14.eglMakeCurrent(display, surface, surface, context)
        }

        fun swapBuffers() {
            EGL14.eglSwapBuffers(display, surface)
        }

        fun release() {
            if (display !== EGL14.EGL_NO_DISPLAY) {
                EGL14.eglMakeCurrent(display, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT)
                if (surface !== EGL14.EGL_NO_SURFACE) EGL14.eglDestroySurface(display, surface)
                if (context !== EGL14.EGL_NO_CONTEXT) EGL14.eglDestroyContext(display, context)
                EGL14.eglTerminate(display)
            }
            surface = EGL14.EGL_NO_SURFACE
            context = EGL14.EGL_NO_CONTEXT
            display = EGL14.EGL_NO_DISPLAY
        }
    }
}
