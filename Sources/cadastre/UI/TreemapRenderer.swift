import Foundation
import Metal
import QuartzCore
import simd

struct TreemapInstance {
    var rect: SIMD4<Float>   // x, y, width, height in points
    var fill: SIMD4<Float>
    /// corner radius in points, 1 for a leaf, unused, unused
    var style: SIMD4<Float>
}

private struct TreemapUniforms {
    var viewport: SIMD2<Float>
    var scale: SIMD2<Float>
    var translate: SIMD2<Float>
    var highlight: Float
    var pixelScale: Float
    var highlightColor: SIMD4<Float>
    var borderColor: SIMD4<Float>
    var selected: Float
    var selectedColor: SIMD4<Float>
}

/// Instanced rectangle renderer.
///
/// A whole home directory is forty thousand rectangles at a typical window
/// size, and a zoom animation redraws them sixty times a second. One quad and
/// one instance buffer handles that without effort; the per-rectangle Core
/// Graphics loop the older tools use is precisely why they cannot animate.
///
/// The shader is compiled from source at launch rather than shipped as a
/// metallib: it is thirty lines, it costs a few milliseconds once, and it keeps
/// the program a single self-contained binary with no resource bundle to find.
final class TreemapRenderer {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private var instanceBuffer: MTLBuffer?
    private var instanceCount = 0

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct Instance { float4 rect; float4 fill; float4 style; };
    struct Uniforms {
        float2 viewport;
        float2 scale;
        float2 translate;
        float  highlight;
        float  pixelScale;
        float4 highlightColor;
        float4 borderColor;
        float  selected;
        float4 selectedColor;
    };
    struct Varying {
        float4 position [[position]];
        float4 fill;
        float2 local;
        float2 sizePx;
        float  highlighted;
        float  selected;
        float  radius;
        float  leaf;
    };

    // Signed distance to a rounded rectangle: negative inside, positive out,
    // and the value near zero is in pixels — which is what gives a one-pixel
    // antialiased edge for free.
    //
    // `half` is a type in MSL (the 16-bit float) and `distance` is a builtin,
    // so neither can be a variable name here.
    static float roundedBox(float2 offset, float2 extent, float radius) {
        float2 q = abs(offset) - extent + radius;
        return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
    }

    vertex Varying treemapVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                 constant Instance *instances [[buffer(0)]],
                                 constant Uniforms &u [[buffer(1)]]) {
        Instance inst = instances[iid];
        float2 corner = float2(float(vid & 1), float((vid >> 1) & 1));
        float2 origin = inst.rect.xy * u.scale + u.translate;
        float2 size   = inst.rect.zw * u.scale;
        float2 point  = origin + corner * size;

        Varying out;
        float2 ndc = (point / u.viewport) * 2.0 - 1.0;
        out.position = float4(ndc.x, -ndc.y, 0.0, 1.0);
        out.fill = inst.fill;
        out.local = corner;
        out.sizePx = max(size * u.pixelScale, float2(1.0));
        out.highlighted = (float(iid) == u.highlight) ? 1.0 : 0.0;
        out.selected = (float(iid) == u.selected) ? 1.0 : 0.0;
        out.radius = inst.style.x * u.pixelScale;
        out.leaf = inst.style.y;
        return out;
    }

    fragment float4 treemapFragment(Varying in [[stage_in]],
                                    constant Uniforms &u [[buffer(1)]]) {
        float2 extent = in.sizePx * 0.5;
        float2 offset = in.local * in.sizePx - extent;
        // Capped as a fraction of the tile, not just clamped to it: a flat cap
        // turns every few-pixel rectangle into a dot, and a treemap of dots
        // stops reading as adjacency.
        float radius = min(in.radius, min(extent.x, extent.y) * 0.55);
        float signedDistance = roundedBox(offset, extent, radius);

        // Corners are cut rather than painted: the parent rectangle is already
        // in the framebuffer underneath, so discarding here reveals it.
        float coverage = clamp(0.5 - signedDistance, 0.0, 1.0);
        if (coverage <= 0.0) discard_fragment();

        float3 color = in.fill.rgb;

        // A barely-there vertical gradient. Enough to give each tile a surface;
        // not enough to shift where a colour sits in the palette.
        if (in.leaf > 0.5) {
            color *= mix(1.045, 0.955, in.local.y);
        }

        // A hairline of the surface colour inside every edge: this is the gutter
        // that keeps two adjacent categories from reading as one shape.
        float inset = -signedDistance;
        if (inset < u.pixelScale) {
            color = mix(color, u.borderColor.rgb, 0.5 * u.borderColor.a);
        }
        if (in.highlighted > 0.5) {
            color = inset < 2.0 * u.pixelScale
                  ? u.highlightColor.rgb
                  : mix(color, u.highlightColor.rgb, 0.14);
        }
        // The selection is a ring in the accent colour, distinct from the
        // hover so the keyboard and the pointer can point at two things.
        if (in.selected > 0.5 && inset < 2.5 * u.pixelScale) {
            color = u.selectedColor.rgb;
        }
        return float4(color, coverage);
    }
    """

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue

        do {
            let library = try device.makeLibrary(source: TreemapRenderer.shaderSource, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "treemapVertex")
            descriptor.fragmentFunction = library.makeFunction(name: "treemapFragment")
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            // Needed for the antialiased corners: the cut edge blends onto the
            // parent rectangle already drawn beneath it.
            descriptor.colorAttachments[0].isBlendingEnabled = true
            descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
            descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            FileHandle.standardError.write("cadastre: \(tr(en: "shader unavailable", fr: "shader indisponible")): \(error)\n".data(using: .utf8)!)
            return nil
        }
    }

    var metalDevice: MTLDevice { device }

    /// Build the draw list. Shared by the window and the PNG export so the two
    /// cannot drift apart.
    static func instances(rects: [TreemapRect], fills: [RGBA],
                          model: TreemapModel) -> [TreemapInstance] {
        zip(rects, fills).map { entry, fill in
            let isLeaf = entry.isLeaf || !model.isDirectory[Int(entry.node)]
            return TreemapInstance(
                rect: SIMD4(entry.rect.x, entry.rect.y, entry.rect.width, entry.rect.height),
                fill: SIMD4(fill.r, fill.g, fill.b, 1),
                style: SIMD4(isLeaf ? 2.0 : 3.5, isLeaf ? 1 : 0, 0, 0))
        }
    }

    func upload(_ instances: [TreemapInstance]) {
        instanceCount = instances.count
        guard !instances.isEmpty else { instanceBuffer = nil; return }
        let bytes = MemoryLayout<TreemapInstance>.stride * instances.count
        if instanceBuffer == nil || instanceBuffer!.length < bytes {
            instanceBuffer = device.makeBuffer(length: bytes, options: .storageModeShared)
        }
        guard let buffer = instanceBuffer else { return }
        instances.withUnsafeBytes { source in
            buffer.contents().copyMemory(from: source.baseAddress!, byteCount: bytes)
        }
    }

    func draw(in layer: CAMetalLayer, viewport: CGSize, pixelScale: CGFloat,
              scale: SIMD2<Float>, translate: SIMD2<Float>,
              highlight: Int, selected: Int = -1,
              background: RGBA, border: RGBA, highlightColor: RGBA, selectedColor: RGBA? = nil) {
        guard let drawable = layer.nextDrawable(),
              let commandBuffer = queue.makeCommandBuffer() else { return }
        encode(into: drawable.texture, commandBuffer: commandBuffer, viewport: viewport,
               pixelScale: pixelScale, scale: scale, translate: translate,
               highlight: highlight, selected: selected, background: background, border: border,
               highlightColor: highlightColor, selectedColor: selectedColor ?? highlightColor)
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    /// Same picture, into memory instead of onto the screen — the PNG export
    /// and anything that wants to check the rendering without a display.
    func renderToTexture(viewport: CGSize, pixelScale: CGFloat,
                         background: RGBA, border: RGBA) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: Int(viewport.width * pixelScale),
            height: Int(viewport.height * pixelScale),
            mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor),
              let commandBuffer = queue.makeCommandBuffer() else { return nil }

        encode(into: texture, commandBuffer: commandBuffer, viewport: viewport,
               pixelScale: pixelScale, scale: SIMD2(1, 1), translate: SIMD2(0, 0),
               highlight: -1, selected: -1, background: background, border: border,
               highlightColor: background, selectedColor: background)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return texture
    }

    private func encode(into texture: MTLTexture, commandBuffer: MTLCommandBuffer,
                        viewport: CGSize, pixelScale: CGFloat,
                        scale: SIMD2<Float>, translate: SIMD2<Float>,
                        highlight: Int, selected: Int, background: RGBA, border: RGBA,
                        highlightColor: RGBA, selectedColor: RGBA) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(
            red: Double(background.r), green: Double(background.g),
            blue: Double(background.b), alpha: 1)

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        if let instanceBuffer, instanceCount > 0 {
            var uniforms = TreemapUniforms(
                viewport: SIMD2(Float(viewport.width), Float(viewport.height)),
                scale: scale, translate: translate,
                highlight: Float(highlight), pixelScale: Float(pixelScale),
                highlightColor: SIMD4(highlightColor.r, highlightColor.g, highlightColor.b, 1),
                borderColor: SIMD4(border.r, border.g, border.b, border.a),
                selected: Float(selected),
                selectedColor: SIMD4(selectedColor.r, selectedColor.g, selectedColor.b, 1))
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBuffer(instanceBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<TreemapUniforms>.stride, index: 1)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<TreemapUniforms>.stride, index: 1)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4,
                                   instanceCount: instanceCount)
        }
        encoder.endEncoding()
    }
}
