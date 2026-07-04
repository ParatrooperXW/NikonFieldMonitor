// RenderPlugin.swift — iOS FlutterPlugin binding for the
// "nikon_field_monitor/render" MethodChannel + "nikon_field_monitor/render/events"
// EventChannel. Counterpart of Android's RenderPlugin.kt.
//
// Owns a shared Metal device + command queue and a background serial dispatch
// queue (so we never block the platform/UI thread while rendering LiveView).
// Each createTexture() call produces a RendererEntry that conforms to
// FlutterTexture and is registered with the FlutterTextureRegistry — the
// Flutter Texture widget then samples the CVPixelBuffer returned by
// copyPixelBuffer() each frame.
//
// MethodChannel contract (mirrors lib/native_bridge/native_render_bridge.dart):
//   createTexture()                              -> int textureId
//   releaseTexture(textureId)                    -> null
//   pushJpegFrame(textureId, jpeg)               -> null
//   pushRgbaFrame(textureId, rgba, width, height)-> null
//   updateAssistSettings(textureId, settings)    -> null
//   uploadLut(lutId, rgba, size)                 -> null
//   removeLut(lutId)                             -> null
//   setLutActive(textureId, lutId?)              -> null
//
// EventChannel emits:
//   {"event":"frameStats","type":"frameStats","textureId":..,
//    "fps":..,"latencyMs":..,"width":..,"height":..}
//   {"event":"renderError","message":..}
//
// (Both "event" and "type" keys are emitted so the payload is compatible with
// the Dart RenderBridge._onEvent parser, which reads event['event'], as well
// as the iOS-native contract documented in the task spec which uses 'type'.)

import Foundation
import Flutter
import Metal
import CoreVideo
import UIKit

final class RenderPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {

    /// Invoked when the number of active LiveView textures transitions between
    /// zero and non-zero. AppDelegate uses this to toggle
    /// `UIApplication.shared.isIdleTimerDisabled` so the screen stays awake
    /// while a monitor feed is running.
    var onLiveViewActiveChanged: ((Bool) -> Void)?

    private var registrar: FlutterPluginRegistrar?
    private var methodChannel: FlutterMethodChannel?
    private var eventChannel: FlutterEventChannel?
    private var eventSink: FlutterEventSink?

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let library: MTLLibrary
    private let renderQueue = DispatchQueue(label: "nikon.metal.render", qos: .userInitiated)

    /// textureId -> entry.
    private var renderers: [Int64: RendererEntry] = [:]

    /// Master LUT registry so newly-created renderers are seeded with the LUTs
    /// already uploaded before they existed (Android only forwards to existing
    /// renderers; we additionally seed new ones to avoid a latent bug where a
    /// LUT uploaded before createTexture would be missing).
    private var lutMaster: [String: (Data, Int)] = [:]

    private init?(device: MTLDevice) {
        self.device = device
        guard let queue = device.makeCommandQueue() else { return nil }
        self.commandQueue = queue
        // default.metallib is produced by the Run Script build phase that
        // compiles every .metal file in Runner/Shaders (see ios/README.md).
        guard let lib = try? device.makeDefaultLibrary() else {
            NSLog("[RenderPlugin] default.metallib not found — did the Metal " +
                  "build phase run? See ios/README.md.")
            return nil
        }
        self.library = lib
        super.init()
    }

    // MARK: - FlutterPlugin

    static func register(with registrar: FlutterPluginRegistrar) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let plugin = RenderPlugin(device: device) else {
            NSLog("[RenderPlugin] Metal unavailable on this device; plugin disabled.")
            return
        }
        plugin.onLiveViewActiveChanged = { active in
            DispatchQueue.main.async {
                UIApplication.shared.isIdleTimerDisabled = active
            }
        }
        plugin.attach(to: registrar)
        registrar.publish(plugin)
    }

    /// Instance-based wiring (used by both register(with:) and by AppDelegate
    /// when it wants to install a custom onLiveViewActiveChanged closure first).
    @discardableResult
    func attach(to registrar: FlutterPluginRegistrar) -> Bool {
        self.registrar = registrar
        let messenger = registrar.messenger()
        let mc = FlutterMethodChannel(name: "nikon_field_monitor/render", binaryMessenger: messenger)
        mc.setMethodCallHandler { [weak self] call, result in
            self?.handle(call, result: result)
        }
        self.methodChannel = mc

        let ec = FlutterEventChannel(name: "nikon_field_monitor/render/events", binaryMessenger: messenger)
        ec.setStreamHandler(self)
        self.eventChannel = ec
        return true
    }

    // MARK: - FlutterStreamHandler

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        self.eventSink = events
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        self.eventSink = nil
        return nil
    }

    // MARK: - Method dispatch

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = (call.arguments as? [String: Any]) ?? [:]

        switch call.method {
        case "createTexture":
            createTexture(result: result)

        case "releaseTexture":
            let id = (args["textureId"] as? NSNumber)?.int64Value ?? -1
            // Unregister on the main thread (FlutterTextureRegistry is main-thread).
            self.registrar?.textures().unregisterTexture(id)
            renderQueue.async {
                self.renderers[id]?.release()
                self.renderers.removeValue(forKey: id)
                self.notifyActiveIfNeeded()
            }
            result(nil)

        case "pushJpegFrame":
            let id = (args["textureId"] as? NSNumber)?.int64Value ?? -1
            // Dart Uint8List arrives as FlutterStandardTypedData over the channel.
            let jpeg: Data = (args["jpeg"] as? FlutterStandardTypedData)?.data ?? Data()
            renderQueue.async {
                self.renderers[id]?.pushJpeg(jpeg)
            }
            result(nil)

        case "pushRgbaFrame":
            let id = (args["textureId"] as? NSNumber)?.int64Value ?? -1
            let rgba: Data = (args["rgba"] as? FlutterStandardTypedData)?.data ?? Data()
            let w = (args["width"] as? NSNumber)?.intValue ?? 0
            let h = (args["height"] as? NSNumber)?.intValue ?? 0
            renderQueue.async {
                self.renderers[id]?.pushRgba(rgba, width: w, height: h)
            }
            result(nil)

        case "updateAssistSettings":
            let id = (args["textureId"] as? NSNumber)?.int64Value ?? -1
            let settings = (args["settings"] as? [String: Any?]) ?? [:]
            renderQueue.async {
                self.renderers[id]?.updateSettings(settings)
            }
            result(nil)

        case "uploadLut":
            guard let lutId = args["lutId"] as? String else {
                result(FlutterError(code: "bad", message: "lutId required", details: nil))
                return
            }
            let rgbaStd = (args["rgba"] as? FlutterStandardTypedData) ?? FlutterStandardTypedData(bytes: Data())
            let size = (args["size"] as? NSNumber)?.intValue ?? 0
            lutMaster[lutId] = (rgbaStd.data, size)
            renderQueue.async {
                for entry in self.renderers.values {
                    entry.uploadLut(lutId, rgba: rgbaStd.data, size: size)
                }
            }
            result(nil)

        case "removeLut":
            guard let lutId = args["lutId"] as? String else {
                result(FlutterError(code: "bad", message: "lutId required", details: nil))
                return
            }
            lutMaster.removeValue(forKey: lutId)
            renderQueue.async {
                for entry in self.renderers.values {
                    entry.removeLut(lutId)
                }
            }
            result(nil)

        case "setLutActive":
            let id = (args["textureId"] as? NSNumber)?.int64Value ?? -1
            let lutId = args["lutId"] as? String   // nil = LUT off
            renderQueue.async {
                self.renderers[id]?.setActiveLut(lutId)
            }
            result(nil)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func createTexture(result: @escaping FlutterResult) {
        guard let registrar = self.registrar else {
            result(FlutterError(code: "no-registrar", message: "FlutterPluginRegistrar is nil", details: nil))
            return
        }
        guard let entry = RendererEntry(device: device,
                                        commandQueue: commandQueue,
                                        library: library,
                                        onError: { [weak self] msg in
                                            self?.emitError(msg)
                                        },
                                        onStats: { [weak self] stats in
                                            self?.emitStats(stats)
                                        }) else {
            result(FlutterError(code: "render-init", message: "Failed to create RendererEntry", details: nil))
            return
        }
        // Seed with any LUTs uploaded before this texture existed.
        for (lutId, (rgba, size)) in lutMaster {
            entry.uploadLut(lutId, rgba: rgba, size: size)
        }
        let textureId = registrar.textures().register(entry)
        renderQueue.async {
            entry.setTextureId(textureId)
            self.renderers[textureId] = entry
            self.notifyActiveIfNeeded()
        }
        // Match Android's createTexture return shape: bare textureId (int).
        // The Dart RenderBridge.createTexture() invokes this as
        // `invokeMethod<int>('createTexture')` and casts the result to int —
        // returning a Map here would throw a runtime cast error on iOS.
        result(textureId)
    }

    private func notifyActiveIfNeeded() {
        let active = !renderers.isEmpty
        let closure = onLiveViewActiveChanged
        DispatchQueue.main.async { closure?(active) }
    }

    // MARK: - Event emission

    private func emitError(_ message: String) {
        let sink = eventSink
        DispatchQueue.main.async {
            sink?(["event": "renderError", "message": message])
        }
    }

    private func emitStats(_ stats: FrameStats) {
        let sink = eventSink
        DispatchQueue.main.async {
            // Both "event" (Dart RenderBridge parser) and "type" (iOS spec)
            // keys are present for cross-contract compatibility.
            sink?([
                "event": "frameStats",
                "type": "frameStats",
                "textureId": stats.textureId,
                "fps": stats.fps,
                "latencyMs": stats.latencyMs,
                "width": stats.width,
                "height": stats.height,
            ])
        }
    }

    struct FrameStats {
        let textureId: Int64
        let fps: Double
        let latencyMs: Int
        let width: Int
        let height: Int
    }

    // MARK: - RendererEntry

    /// One FlutterTexture-backed LiveView surface. Owns:
    ///   - a LiveViewRenderer (the 5-pass Metal pipeline)
    ///   - a CVPixelBufferPool (BGRA, IOSurface-backed so Metal can texture it)
    ///   - a CVMetalTextureCache to obtain an MTLTexture view of each pool PB
    ///   - the "current" pixel buffer handed to Flutter via copyPixelBuffer
    ///
    /// All rendering happens on the plugin's renderQueue.
    final class RendererEntry: NSObject, FlutterTexture {

        let device: MTLDevice
        let commandQueue: MTLCommandQueue
        let renderer: LiveViewRenderer
        /// Assigned by RenderPlugin after the entry is registered with the
        /// FlutterTextureRegistry (the id is only known then). Read by the
        /// frameStats emitter so events carry the correct textureId.
        var textureId: Int64
        private let onError: (String) -> Void
        private let onStats: (FrameStats) -> Void

        // CVPixelBuffer pool (BGRA) + Metal texture cache for zero-copy output.
        private var pool: CVPixelBufferPool?
        private var textureCache: CVMetalTextureCache?
        // Keep the CVMetalTextureRef alive for the duration of a render (it owns
        // the MTLTexture returned by CVMetalTextureGetTexture).
        private var pinnedCVTexture: CVMetalTexture?
        private var currentPixelBuffer: CVPixelBuffer?

        // FPS / latency tracking.
        private var frameCount: Int = 0
        private var lastStatsTime: DispatchTime = .now()
        private var lastLatencyMs: Int = 0

        var frameWidth: Int { renderer.frameWidth }
        var frameHeight: Int { renderer.frameHeight }

        init?(device: MTLDevice,
              commandQueue: MTLCommandQueue,
              library: MTLLibrary,
              onError: @escaping (String) -> Void,
              onStats: @escaping (FrameStats) -> Void) {
            self.device = device
            self.commandQueue = commandQueue
            self.onError = onError
            self.onStats = onStats
            self.textureId = 0
            do {
                self.renderer = try LiveViewRenderer(device: device,
                                                    commandQueue: commandQueue,
                                                    library: library)
            } catch {
                NSLog("[RendererEntry] init failed: \(error.localizedDescription)")
                return nil
            }
            super.init()
            CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
            rebuildPool(width: renderer.frameWidth, height: renderer.frameHeight)
        }

        /// Called by RenderPlugin immediately after the FlutterTextureRegistry
        /// returns the texture id. Must run on the renderQueue (where stats are
        /// emitted) to avoid a data race on `textureId`.
        func setTextureId(_ id: Int64) {
            self.textureId = id
        }

        // MARK: Frame ingest (called on renderQueue)

        func pushJpeg(_ data: Data) {
            do {
                try renderer.pushJpeg(data)
                drawFrame()
            } catch {
                onError(error.localizedDescription)
            }
        }

        func pushRgba(_ data: Data, width: Int, height: Int) {
            do {
                try renderer.pushRgba(data, width: width, height: height)
                drawFrame()
            } catch {
                onError(error.localizedDescription)
            }
        }

        func updateSettings(_ map: [String: Any?]) {
            renderer.updateSettings(map)
        }

        func uploadLut(_ lutId: String, rgba: Data, size: Int) {
            renderer.uploadLut(lutId, rgba: rgba, size: size)
        }

        func removeLut(_ lutId: String) {
            renderer.removeLut(lutId)
        }

        func setActiveLut(_ lutId: String?) {
            renderer.setActiveLut(lutId)
        }

        // MARK: Render

        private func drawFrame() {
            let w = renderer.frameWidth
            let h = renderer.frameHeight
            rebuildPool(width: w, height: h)

            guard let pb = nextPixelBuffer(width: w, height: h) else {
                onError("CVPixelBuffer pool exhausted")
                return
            }
            guard let outTexture = metalTexture(from: pb, width: w, height: h) else {
                onError("CVMetalTextureCacheCreateTextureFromImage failed")
                return
            }

            let started = DispatchTime.now()
            renderer.render(into: outTexture)
            let latencyNs = DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds
            lastLatencyMs = Int(latencyNs / 1_000_000)

            // Pin the CV texture + pixel buffer for the lifetime Flutter reads it.
            currentPixelBuffer = pb

            // Frame stats: emit ~1/sec.
            frameCount += 1
            let now = DispatchTime.now()
            let elapsed = now.uptimeNanoseconds - lastStatsTime.uptimeNanoseconds
            if elapsed >= 1_000_000_000 {
                let fps = Double(frameCount) * 1_000_000_000.0 / Double(elapsed)
                onStats(FrameStats(textureId: textureId,
                                   fps: fps,
                                   latencyMs: lastLatencyMs,
                                   width: w,
                                   height: h))
                frameCount = 0
                lastStatsTime = now
            }
        }

        // MARK: Pool / texture helpers

        private func rebuildPool(width: Int, height: Int) {
            if let p = pool, p.width == width, p.height == height { return }
            // Tear down old pool.
            if let p = pool { CVPixelBufferPoolFlush(p, .excessBuffers) }
            pool = nil

            let pbAttrs: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                kCVPixelBufferMetalCompatibilityKey: true,
            ]
            let poolAttrs: [CFString: Any] = [
                kCVPixelBufferPoolMinimumBufferCountKey: 3,
            ]
            var newPool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(kCFAllocatorDefault, poolAttrs as CFDictionary,
                                    pbAttrs as CFDictionary, &newPool)
            self.pool = newPool
        }

        private func nextPixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
            var pb: CVPixelBuffer?
            let status: CVReturn
            if let pool = pool {
                status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, nil, &pb)
            } else {
                let attrs: [CFString: Any] = [
                    kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                    kCVPixelBufferMetalCompatibilityKey: true,
                ]
                status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                             kCVPixelFormatType_32BGRA,
                                             attrs as CFDictionary, &pb)
            }
            guard status == kCVReturnSuccess else { return nil }
            return pb
        }

        private func metalTexture(from pixelBuffer: CVPixelBuffer, width: Int, height: Int) -> MTLTexture? {
            var cvTex: CVMetalTexture?
            let status = CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault,
                textureCache,
                pixelBuffer,
                nil,
                .bgra8Unorm,
                width,
                height,
                &cvTex)
            guard status == kCVReturnSuccess, let cvTex = cvTex else { return nil }
            // Retain for the render; release the previous pinned texture.
            self.pinnedCVTexture = cvTex
            return CVMetalTextureGetTexture(cvTex)
        }

        // MARK: FlutterTexture

        func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
            guard let pb = currentPixelBuffer else { return nil }
            // passUnretained: we retain ownership in currentPixelBuffer; Flutter
            // reads it within the frame then releases its retain. The pool
            // recycles the buffer once all retains drop.
            return .passUnretained(pb)
        }

        // MARK: Teardown

        func release() {
            renderer.release()
            if let p = pool { CVPixelBufferPoolFlush(p, .excessBuffers) }
            pool = nil
            pinnedCVTexture = nil
            currentPixelBuffer = nil
            textureCache = nil
        }
    }
}

// MARK: - Convenience for AppDelegate-driven registration

extension RenderPlugin {
    /// Construct a plugin instance directly (AppDelegate path). Returns nil if
    /// Metal is unavailable or default.metallib is missing.
    static func make() -> RenderPlugin? {
        guard let device = MTLCreateSystemDefaultDevice(),
              let plugin = RenderPlugin(device: device) else {
            return nil
        }
        return plugin
    }
}
