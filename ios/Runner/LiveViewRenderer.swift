// LiveViewRenderer.swift — iOS Metal counterpart of Android's LiveViewRenderer.kt.
//
// Implements the same 5-pass LiveView GPU pipeline, but in Metal (iOS does not
// allow OpenGL ES for new apps) and against a CVPixelBuffer-backed
// FlutterTexture instead of a GL SurfaceTexture.
//
// Passes (parity with LiveViewRenderer.kt):
//   1. JPEG decode -> CVPixelBuffer (CGImageSourceCreateWithData +
//      CGImageSourceCreateImageAtIndex, the ImageIO equivalent of
//      CGImageCreate) -> MTLTexture (RGBA8Unorm).
//      OR pushRgbaFrame: direct byte upload into an RGBA8Unorm MTLTexture.
//   2. Stage pass: LUT (2D-packed 3D, trilinear) OR FalseColor (mutually
//      exclusive — falseColor wins) OR passthrough, into intermediate texA.
//   3. Peaking (Sobel edge) blend -> ping-pong into texB.
//   4. Zebra (IRE banding, 45 deg diagonal stripe) blend -> ping-pong back.
//   5. Present: RGBA intermediate -> BGRA Flutter CVPixelBuffer (swizzle).
//
// Ping-pong: Metal forbids reading and writing the same texture in one pass
// (unlike the GL FBO self-read that Android relies on, which is UB-but-works).
// We therefore keep two intermediate textures (texA/texB) and swap.
//
// Coordinate convention note: Metal textures are top-left origin (vs GL's
// bottom-left). To keep the image right-side-up across every ping-pong pass we
// pass uFlipY=1 on every draw (see passthrough_vertex.metal). The shader math
// is otherwise identical to the GLSL originals.
//
// LUT registry: [String: (MTLTexture, Int)] — one set of LUT textures per
// renderer instance (mirrors Android, where uploadLut is forwarded to every
// RendererEntry). The RenderPlugin keeps a master list so newly-created
// renderers can be seeded.

import Foundation
import Metal
import CoreVideo
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Mirror of Dart MonitorAssistSettings.toBridgeMap() — only the fields the
/// GPU pipeline actually consumes. Keys kept identical so the renderer logic
/// matches Android 1:1. See lib/models/monitor_assist_settings.dart.
struct MonitorAssistSettings {
    var peakingEnabled: Bool = false
    var peakingColor: String = "red"
    var peakingSensitivity: Int = 1   // 0=Low / 1=Med / 2=High
    var zebraEnabled: Bool = false
    var zebraLowerIre: Int = 70
    var zebraUpperIre: Int = 100
    var falseColorEnabled: Bool = false
    /// Already the "lutActuallyApplied" value (lutEnabled && !falseColorEnabled)
    /// as computed in Dart toBridgeMap().
    var lutEnabled: Bool = false
    var activeLutId: String?

    static func from(_ map: [String: Any?]) -> MonitorAssistSettings {
        var s = MonitorAssistSettings()
        if let v = map["peakingEnabled"] as? Bool { s.peakingEnabled = v }
        if let v = map["peakingColor"] as? String { s.peakingColor = v }
        if let v = (map["peakingSensitivity"] as? NSNumber)?.intValue { s.peakingSensitivity = v }
        if let v = map["zebraEnabled"] as? Bool { s.zebraEnabled = v }
        if let v = (map["zebraLowerIre"] as? NSNumber)?.intValue { s.zebraLowerIre = v }
        if let v = (map["zebraUpperIre"] as? NSNumber)?.intValue { s.zebraUpperIre = v }
        if let v = map["falseColorEnabled"] as? Bool { s.falseColorEnabled = v }
        if let v = map["lutEnabled"] as? Bool { s.lutEnabled = v }
        if let v = map["activeLutId"] as? String { s.activeLutId = v }
        return s
    }
}

final class LiveViewRenderer {

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let library: MTLLibrary

    // Programs (one MTLRenderPipelineState per pass).
    private let lutProgram: ShaderProgram
    private let falseColorProgram: ShaderProgram
    private let peakingProgram: ShaderProgram
    private let zebraProgram: ShaderProgram
    private let passthroughProgram: ShaderProgram   // stage disabled (RGBA->RGBA)
    private let presentProgram: ShaderProgram       // final RGBA->BGRA swizzle

    // Shared fullscreen quad + sampler.
    private let quadBuffer: MTLBuffer
    private let sampler: MTLSamplerState

    // Decoded input frame (RGBA8Unorm, shaderRead).
    private var frameTexture: MTLTexture?
    private(set) var frameWidth: Int = 1920
    private(set) var frameHeight: Int = 1080

    // Intermediate ping-pong targets at frame resolution (RGBA8Unorm,
    // shaderRead + renderTarget).
    private var texA: MTLTexture?
    private var texB: MTLTexture?

    // LUT registry: lutId -> (2D-packed RGBA texture, size N).
    private(set) var luts: [String: (MTLTexture, Int)] = [:]
    private var activeLutId: String?

    var settings = MonitorAssistSettings()

    init(device: MTLDevice, commandQueue: MTLCommandQueue, library: MTLLibrary) throws {
        self.device = device
        self.commandQueue = commandQueue
        self.library = library

        // Assist passes render into RGBA8Unorm intermediates.
        let rgba: MTLPixelFormat = .rgba8Unorm
        self.lutProgram         = try ShaderProgram(device: device, library: library, fragmentFunction: "lut_fragment",         pixelFormat: rgba, label: "lut")
        self.falseColorProgram  = try ShaderProgram(device: device, library: library, fragmentFunction: "falsecolor_fragment",  pixelFormat: rgba, label: "falsecolor")
        self.peakingProgram     = try ShaderProgram(device: device, library: library, fragmentFunction: "peaking_fragment",     pixelFormat: rgba, label: "peaking")
        self.zebraProgram       = try ShaderProgram(device: device, library: library, fragmentFunction: "zebra_fragment",       pixelFormat: rgba, label: "zebra")
        self.passthroughProgram = try ShaderProgram(device: device, library: library, fragmentFunction: "passthrough_fragment", pixelFormat: rgba, label: "passthrough")
        // Present pass renders into the BGRA8Unorm Flutter CVPixelBuffer.
        self.presentProgram     = try ShaderProgram(device: device, library: library, fragmentFunction: "present_fragment",     pixelFormat: .bgra8Unorm, label: "present")

        // Fullscreen triangle strip: (x, y, u, v) per vertex — identical layout
        // to Android's quadVerts in LiveViewRenderer.kt.
        let quad: [Float] = [
            -1, -1, 0, 0,
             1, -1, 1, 0,
            -1,  1, 0, 1,
             1,  1, 1, 1,
        ]
        guard let qb = device.makeBuffer(bytes: quad,
                                        length: quad.count * MemoryLayout<Float>.size,
                                        options: []) else {
            throw NSError(domain: "LiveViewRenderer", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Failed to allocate quad MTLBuffer",
            ])
        }
        self.quadBuffer = qb

        let sdesc = MTLSamplerDescriptor()
        sdesc.minFilter = .linear
        sdesc.magFilter = .linear
        sdesc.sAddressMode = .clampToEdge
        sdesc.tAddressMode = .clampToEdge
        guard let smp = device.makeSamplerState(descriptor: sdesc) else {
            throw NSError(domain: "LiveViewRenderer", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "Failed to create sampler state",
            ])
        }
        self.sampler = smp
    }

    // MARK: - Frame ingest

    /// Pass 1 (JPEG path): decode JPEG bytes -> CVPixelBuffer (RGBA) -> upload
    /// into an RGBA8Unorm MTLTexture. Uses CGImageSourceCreateWithData +
    /// CGImageSourceCreateImageAtIndex (the ImageIO form of CGImageCreate).
    func pushJpeg(_ jpeg: Data) throws {
        guard let cvImage = decodeJpegToCVPixelBuffer(jpeg) else {
            throw NSError(domain: "LiveViewRenderer", code: 5, userInfo: [
                NSLocalizedDescriptionKey: "JPEG decode failed",
            ])
        }
        try uploadCVPixelBuffer(cvImage, width: cvImage.width, height: cvImage.height)
    }

    /// Pass 1 (RGBA path): direct byte upload (used when a Dart Isolate
    /// already decoded the frame).
    func pushRgba(_ rgba: Data, width: Int, height: Int) throws {
        guard width > 0, height > 0, rgba.count >= width * height * 4 else {
            throw NSError(domain: "LiveViewRenderer", code: 6, userInfo: [
                NSLocalizedDescriptionKey: "Invalid RGBA frame (\(width)x\(height), \(rgba.count) bytes)",
            ])
        }
        ensureFrameSize(width: width, height: height)
        guard let tex = frameTexture else { return }
        rgba.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Void in
            guard let base = raw.baseAddress else { return }
            tex.replace(region: MTLRegionMake2D(0, 0, width, height),
                        mipmapLevel: 0,
                        withBytes: base,
                        bytesPerRow: width * 4)
        }
    }

    private func decodeJpegToCVPixelBuffer(_ data: Data) -> (pixelBuffer: CVPixelBuffer, width: Int, height: Int)? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            return nil
        }
        let w = cgImage.width
        let h = cgImage.height
        var pb: CVPixelBuffer?
        // RGBA so the shaders' .rgb assumptions match the GLSL originals.
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
        let status = CVPixelBufferCreate(kCFAllocatorDefault, w, h,
                                         kCVPixelFormatType_32RGBA,
                                         attrs as CFDictionary,
                                         &pb)
        guard status == kCVReturnSuccess, let pixelBuffer = pb else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        // premultipliedLast => RGBA layout to match kCVPixelFormatType_32RGBA.
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let ctx = CGContext(data: baseAddress,
                                  width: w,
                                  height: h,
                                  bitsPerComponent: 8,
                                  bytesPerRow: bytesPerRow,
                                  space: colorSpace,
                                  bitmapInfo: bitmapInfo.rawValue) else {
            return nil
        }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        return (pixelBuffer, w, h)
    }

    private func uploadCVPixelBuffer(_ pixelBuffer: CVPixelBuffer, width: Int, height: Int) throws {
        ensureFrameSize(width: width, height: height)
        guard let tex = frameTexture else { return }
        CVPixelBufferLockBaseAddress(pixelBuffer, [.readOnly])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, [.readOnly]) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        let bpr = CVPixelBufferGetBytesPerRow(pixelBuffer)
        tex.replace(region: MTLRegionMake2D(0, 0, width, height),
                    mipmapLevel: 0,
                    withBytes: base,
                    bytesPerRow: bpr)
    }

    /// Recreate frameTexture + intermediates if the frame dimensions changed.
    private func ensureFrameSize(width: Int, height: Int) {
        frameWidth = max(width, 2)
        frameHeight = max(height, 2)
        if let t = frameTexture, t.width == frameWidth, t.height == frameHeight {
            // Same size; reuse. (Intermediates already match.)
            if texA != nil { return }
        }
        frameTexture = makeRGBA(width: frameWidth, height: frameHeight, usage: .shaderRead)
        texA = makeRGBA(width: frameWidth, height: frameHeight, usage: [.shaderRead, .renderTarget])
        texB = makeRGBA(width: frameWidth, height: frameHeight, usage: [.shaderRead, .renderTarget])
    }

    private func makeRGBA(width: Int, height: Int, usage: MTLTextureUsage) -> MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
                                                            width: width,
                                                            height: height,
                                                            mipmapped: false)
        desc.usage = usage
        desc.storageMode = .private   // GPU-local; we upload via replace()
        return device.makeTexture(descriptor: desc)!
    }

    // MARK: - Settings

    func updateSettings(_ map: [String: Any?]) {
        settings = MonitorAssistSettings.from(map)
    }

    // MARK: - LUT registry

    /// Upload a 3D LUT packed as a 2D RGBA texture of size (size*size) x size.
    func uploadLut(_ lutId: String, rgba: Data, size: Int) {
        guard size > 0, rgba.count >= size * size * size * 4 else { return }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
                                                            width: size * size,
                                                            height: size,
                                                            mipmapped: false)
        desc.usage = .shaderRead
        guard let tex = device.makeTexture(descriptor: desc) else { return }
        rgba.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Void in
            guard let base = raw.baseAddress else { return }
            tex.replace(region: MTLRegionMake2D(0, 0, size * size, size),
                        mipmapLevel: 0,
                        withBytes: base,
                        bytesPerRow: size * size * 4)
        }
        luts[lutId] = (tex, size)
    }

    func removeLut(_ lutId: String) {
        luts.removeValue(forKey: lutId)
        if activeLutId == lutId { activeLutId = nil }
    }

    func setActiveLut(_ lutId: String?) {
        activeLutId = lutId
    }

    // MARK: - Render

    /// Run the 5-pass pipeline, writing the final composited frame into the
    /// BGRA8Unorm MTLTexture backed by the Flutter CVPixelBuffer. Called on the
    /// render queue (off the main / platform thread).
    func render(into output: MTLTexture) {
        guard let frame = frameTexture,
              let a = texA,
              let b = texB,
              let cmd = commandQueue.makeCommandBuffer() else {
            return
        }

        var currentSrc: MTLTexture = frame
        var dst: MTLTexture = a
        var other: MTLTexture = b

        // ---- Pass 2: stage (LUT / FalseColor / passthrough) ----
        let lutActuallyOn = settings.lutEnabled && !settings.falseColorEnabled && activeLutId != nil
        if settings.falseColorEnabled {
            draw(into: cmd, from: currentSrc, to: dst, pipeline: falseColorProgram.pipelineState, flipY: 1) { enc in
                var enabled: Int32 = 1
                enc.setFragmentBytes(&enabled, length: MemoryLayout<Int32>.size, index: 0)
            }
        } else if lutActuallyOn, let lut = luts[activeLutId ?? ""] {
            draw(into: cmd, from: currentSrc, to: dst, pipeline: lutProgram.pipelineState, flipY: 1) { enc in
                enc.setFragmentTexture(lut.0, index: 1)
                var size: Float = Float(lut.1)
                enc.setFragmentBytes(&size, length: MemoryLayout<Float>.size, index: 0)
                var enabled: Int32 = 1
                enc.setFragmentBytes(&enabled, length: MemoryLayout<Int32>.size, index: 1)
            }
        } else {
            draw(into: cmd, from: currentSrc, to: dst, pipeline: passthroughProgram.pipelineState, flipY: 1) { _ in }
        }
        currentSrc = dst
        swap(&dst, &other)

        // ---- Pass 3: peaking (Sobel edge blend) ----
        if settings.peakingEnabled {
            let texelW: Float = 1.0 / Float(frameWidth)
            let texelH: Float = 1.0 / Float(frameHeight)
            draw(into: cmd, from: currentSrc, to: dst, pipeline: peakingProgram.pipelineState, flipY: 1) { enc in
                var texel = SIMD2<Float>(texelW, texelH)
                enc.setFragmentBytes(&texel, length: MemoryLayout<SIMD2<Float>>.size, index: 0)
                var color = Self.peakingColorRgb(self.settings.peakingColor)
                enc.setFragmentBytes(&color, length: MemoryLayout<SIMD3<Float>>.size, index: 1)
                var sens: Int32 = Int32(self.settings.peakingSensitivity)
                enc.setFragmentBytes(&sens, length: MemoryLayout<Int32>.size, index: 2)
                var enabled: Int32 = 1
                enc.setFragmentBytes(&enabled, length: MemoryLayout<Int32>.size, index: 3)
            }
            currentSrc = dst
            swap(&dst, &other)
        }

        // ---- Pass 4: zebra (IRE banding, 45 deg stripes) ----
        if settings.zebraEnabled {
            draw(into: cmd, from: currentSrc, to: dst, pipeline: zebraProgram.pipelineState, flipY: 1) { enc in
                var res = SIMD2<Float>(Float(self.frameWidth), Float(self.frameHeight))
                enc.setFragmentBytes(&res, length: MemoryLayout<SIMD2<Float>>.size, index: 0)
                var lower: Float = Float(self.settings.zebraLowerIre)
                enc.setFragmentBytes(&lower, length: MemoryLayout<Float>.size, index: 1)
                var upper: Float = Float(self.settings.zebraUpperIre)
                enc.setFragmentBytes(&upper, length: MemoryLayout<Float>.size, index: 2)
                var enabled: Int32 = 1
                enc.setFragmentBytes(&enabled, length: MemoryLayout<Int32>.size, index: 3)
            }
            currentSrc = dst
            swap(&dst, &other)
        }

        // ---- Pass 5: present RGBA -> BGRA Flutter CVPixelBuffer ----
        draw(into: cmd, from: currentSrc, to: output, pipeline: presentProgram.pipelineState, flipY: 1) { _ in }

        cmd.commit()
        // Wait so the output CVPixelBuffer is safe to hand to Flutter when this
        // returns. The render queue is serial, so this won't overlap the next.
        cmd.waitUntilCompleted()
    }

    /// Single fullscreen-triangle-strip draw into `dst`, sampling `src`.
    private func draw(into cmd: MTLCommandBuffer,
                      from src: MTLTexture,
                      to dst: MTLTexture,
                      pipeline: MTLRenderPipelineState,
                      flipY: Int,
                      configure: (MTLRenderCommandEncoder) -> Void) {
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = dst
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].storeAction = .store
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        guard let enc = cmd.makeRenderCommandEncoder(with: rpd) else { return }
        enc.pushDebugGroup("LiveViewRenderer.\(pipeline.label ?? "pass")")
        enc.setRenderPipelineState(pipeline)
        enc.setVertexBuffer(quadBuffer, offset: 0, index: 0)
        var flip: Int32 = Int32(flipY)
        enc.setVertexBytes(&flip, length: MemoryLayout<Int32>.size, index: 1)
        enc.setFragmentTexture(src, index: 0)
        enc.setFragmentSamplerState(sampler, index: 0)
        configure(enc)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.popDebugGroup()
        enc.endEncoding()
    }

    // MARK: - Peaking color table (matches Android peakingColorRgb + Dart) ----

    private static func peakingColorRgb(_ name: String) -> SIMD3<Float> {
        switch name {
        case "red":    return SIMD3<Float>(1.0, 0.0, 0.0)
        case "green":  return SIMD3<Float>(0.0, 1.0, 0.0)
        case "blue":   return SIMD3<Float>(0.0, 0.69, 1.0)
        case "yellow": return SIMD3<Float>(1.0, 1.0, 0.0)
        case "white":  return SIMD3<Float>(1.0, 1.0, 1.0)
        default:       return SIMD3<Float>(1.0, 0.0, 0.0)
        }
    }

    // MARK: - Teardown

    func release() {
        frameTexture = nil
        texA = nil
        texB = nil
        luts.removeAll()
        activeLutId = nil
    }
}
