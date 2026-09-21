import Metal
import QuartzCore
import ScreenSaver

/// The fireworks screensaver's `ScreenSaverView` (TASK-017.03): loads the
/// exported sprite atlases and `data/level.pcx`'s palette from its own
/// bundle once, acquires the process-wide shared simulation
/// (`FireworksSimulationCoordinator`) on `startAnimation`, and on every
/// `animateOneFrame` uploads the coordinator's latest composed
/// `Framebuffer` into a Metal texture and presents it as one nearest-
/// neighbour, integer-scaled, letterboxed quad (`PresentationGeometry`).
// @objc(JNBFireworksView), not the Swift-default module-qualified name:
// Info.plist's NSPrincipalClass is looked up by the Objective-C runtime at
// bundle-load time, before Swift's own module system is involved, and a
// plain class name is the well-established convention for Swift-based
// ScreenSaverView subclasses.
@objc(JNBFireworksView)
public final class JNBFireworksView: ScreenSaverView {
    private var metalLayer: CAMetalLayer?
    private var device: MTLDevice?
    private var commandQueue: MTLCommandQueue?
    private var pipelineState: MTLRenderPipelineState?
    private var texture: MTLTexture?
    private var acquired = false
    private var loadedAssets: (atlases: FireworksAtlasSet, palette: Palette)?

    public override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        animationTimeInterval = 1.0 / 60.0
        wantsLayer = true
        setUpMetal()
        loadedAssets = try? Self.loadAssets(bundle: Bundle(for: JNBFireworksView.self))
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        animationTimeInterval = 1.0 / 60.0
        wantsLayer = true
        setUpMetal()
        loadedAssets = try? Self.loadAssets(bundle: Bundle(for: JNBFireworksView.self))
    }

    public override var hasConfigureSheet: Bool { false }
    public override var configureSheet: NSWindow? { nil }

    public override func makeBackingLayer() -> CALayer {
        let layer = CAMetalLayer()
        metalLayer = layer
        return layer
    }

    private func setUpMetal() {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        self.device = device
        commandQueue = device.makeCommandQueue()

        guard
            let libraryURL = Bundle(for: JNBFireworksView.self).url(forResource: "default", withExtension: "metallib"),
            let library = try? device.makeLibrary(URL: libraryURL),
            let vertexFn = library.makeFunction(name: "fireworks_vertex"),
            let fragmentFn = library.makeFunction(name: "fireworks_fragment")
        else {
            return
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFn
        descriptor.fragmentFunction = fragmentFn
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipelineState = try? device.makeRenderPipelineState(descriptor: descriptor)

        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: Framebuffer.width,
            height: Framebuffer.height,
            mipmapped: false
        )
        textureDescriptor.usage = [.shaderRead]
        texture = device.makeTexture(descriptor: textureDescriptor)
    }

    static func loadAssets(bundle: Bundle) throws -> (atlases: FireworksAtlasSet, palette: Palette) {
        func resourceData(_ name: String, _ ext: String) throws -> Data {
            guard let url = bundle.url(forResource: name, withExtension: ext) else {
                throw FireworksAssetError.resourceNotFound(name: "\(name).\(ext)")
            }
            return try Data(contentsOf: url)
        }

        let rabbitAtlas = try Atlas(jsonData: resourceData("rabbit_atlas", "json"))
        let rabbitImage = try AtlasImage(pngData: resourceData("rabbit_atlas", "png"))
        let objectsAtlas = try Atlas(jsonData: resourceData("objects_atlas", "json"))
        let objectsImage = try AtlasImage(pngData: resourceData("objects_atlas", "png"))
        let palette = try Palette(pcxData: resourceData("level", "pcx"))

        let atlases = FireworksAtlasSet(rabbit: rabbitAtlas, rabbitImage: rabbitImage, objects: objectsAtlas, objectsImage: objectsImage)
        return (atlases, palette)
    }

    public override func startAnimation() {
        super.startAnimation()
        guard let assets = loadedAssets, !acquired else { return }
        // A fresh random seed per animation session (not per tick) --
        // fireworks mode has no meaningful "resume where it left off"
        // state to restore, matching the original's own startup.
        let seed = UInt32.random(in: 1...UInt32.max)
        if (try? FireworksSimulationCoordinator.shared.acquire(seed: seed, atlases: assets.atlases, palette: assets.palette)) != nil {
            acquired = true
        }
    }

    public override func stopAnimation() {
        if acquired {
            FireworksSimulationCoordinator.shared.release()
            acquired = false
        }
        super.stopAnimation()
    }

    public override func animateOneFrame() {
        guard
            let frame = FireworksSimulationCoordinator.shared.currentFrame(),
            let layer = metalLayer,
            let device = device,
            let commandQueue = commandQueue,
            let pipelineState = pipelineState,
            let texture = texture
        else {
            return
        }

        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.drawableSize = bounds.size

        frame.pixels.withUnsafeBytes { raw in
            texture.replace(
                region: MTLRegionMake2D(0, 0, Framebuffer.width, Framebuffer.height),
                mipmapLevel: 0,
                withBytes: raw.baseAddress!,
                bytesPerRow: Framebuffer.width * 4
            )
        }

        guard let drawable = layer.nextDrawable() else { return }

        let geometry = PresentationGeometry(
            sourceWidth: Framebuffer.width,
            sourceHeight: Framebuffer.height,
            viewWidth: Int(bounds.width),
            viewHeight: Int(bounds.height)
        )
        let clipRect = geometry.clipSpaceRect(viewWidth: Int(bounds.width), viewHeight: Int(bounds.height))

        let passDescriptor = MTLRenderPassDescriptor()
        passDescriptor.colorAttachments[0].texture = drawable.texture
        passDescriptor.colorAttachments[0].loadAction = .clear
        passDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        passDescriptor.colorAttachments[0].storeAction = .store

        guard
            let commandBuffer = commandQueue.makeCommandBuffer(),
            let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor)
        else {
            return
        }

        encoder.setRenderPipelineState(pipelineState)
        var rect = clipRect
        encoder.setVertexBytes(&rect, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}

enum FireworksAssetError: Error {
    case resourceNotFound(name: String)
}

extension PresentationGeometry {
    /// (x0, y0, x1, y1) of the letterboxed destination rect in clip space
    /// (-1...1, Metal's NDC), for the vertex shader's `destRectClipSpace`.
    func clipSpaceRect(viewWidth: Int, viewHeight: Int) -> SIMD4<Float> {
        let vw = Float(max(viewWidth, 1))
        let vh = Float(max(viewHeight, 1))
        let x0 = Float(destX) / vw * 2 - 1
        let x1 = Float(destX + destWidth) / vw * 2 - 1
        // Flip Y: NDC +Y is up, view coordinates count destY from the top.
        let y0 = 1 - Float(destY) / vh * 2
        let y1 = 1 - Float(destY + destHeight) / vh * 2
        return SIMD4<Float>(x0, y1, x1, y0)
    }
}
