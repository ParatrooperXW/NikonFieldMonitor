// ShaderProgram.swift — iOS counterpart of Android's ShaderProgram.kt.
//
// Where the Android version compiles+links GLSL source from assets at runtime,
// on iOS the `.metal` files are compiled offline (Run Script build phase ->
// `xcrun -sdk iphoneos metal` + `metal-lib`) into `default.metallib`, which is
// bundled with the app and loaded here as a single MTLLibrary.
//
// Each ShaderProgram wraps one MTLRenderPipelineState (vertex function +
// fragment function + target pixel format). Uniform locations are replaced by
// the explicit [[buffer(n)]] / [[texture(n)]] / [[sampler(n)]] indices
// declared in the `.metal` source — the renderer binds them directly, so there
// is no equivalent of glGetUniformLocation.

import Foundation
import Metal

final class ShaderProgram {

    /// The linked pipeline state object used by a render command encoder.
    let pipelineState: MTLRenderPipelineState

    /// Human-readable label for Metal debug captures.
    let label: String

    /// Create a pipeline that pairs `passthrough_vertex` with the named
    /// fragment function, rendering into the given pixel format.
    ///
    /// - Parameters:
    ///   - vertexFunction: Vertex function name in default.metallib
    ///     (default "passthrough_vertex").
    ///   - fragmentFunction: Fragment function name in default.metallib
    ///     (e.g. "lut_fragment", "peaking_fragment", "zebra_fragment",
    ///      "falsecolor_fragment", "passthrough_fragment", "present_fragment").
    ///   - pixelFormat: Pixel format of the color attachment this pipeline
    ///     renders into. Assist passes use .rgba8Unorm; the present pass uses
    ///     .bgra8Unorm (Flutter CVPixelBuffer).
    init(device: MTLDevice,
         library: MTLLibrary,
         vertexFunction: String = "passthrough_vertex",
         fragmentFunction: String,
         pixelFormat: MTLPixelFormat,
         label: String) throws {
        guard let vFn = library.makeFunction(name: vertexFunction) else {
            throw NSError(domain: "ShaderProgram", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Vertex function '\(vertexFunction)' not found in default.metallib",
            ])
        }
        guard let fFn = library.makeFunction(name: fragmentFunction) else {
            throw NSError(domain: "ShaderProgram", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Fragment function '\(fragmentFunction)' not found in default.metallib",
            ])
        }

        let desc = MTLRenderPipelineDescriptor()
        desc.label = label
        desc.vertexFunction = vFn
        desc.fragmentFunction = fFn
        desc.colorAttachments[0].pixelFormat = pixelFormat
        // No vertexDescriptor: the vertex shader pulls vertices from a bound
        // device buffer by [[vertex_id]] (interleaved x,y,u,v), mirroring the
        // Android quadBuffer / glVertexAttribPointer setup.
        // Blending is disabled: every pass fully writes its target; the
        // peaking/zebra shaders perform their own source-mix in-shader (same as
        // the GLSL originals, which did not rely on GL blend state either).

        self.pipelineState = try device.makeRenderPipelineState(descriptor: desc)
        self.label = label
    }
}
