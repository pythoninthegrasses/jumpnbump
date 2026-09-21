import Foundation

/// The two atlases fireworks mode draws from — decoded once at load time
/// and reused every frame.
public struct FireworksAtlasSet {
    public let rabbit: Atlas
    public let rabbitImage: AtlasImage
    public let objects: Atlas
    public let objectsImage: AtlasImage

    public init(rabbit: Atlas, rabbitImage: AtlasImage, objects: Atlas, objectsImage: AtlasImage) {
        self.rabbit = rabbit
        self.rabbitImage = rabbitImage
        self.objects = objects
        self.objectsImage = objectsImage
    }
}

/// Composes one `Framebuffer` per tick from `FireworksSimulation`'s output,
/// reproducing `fireworks.c`'s own draw order (fireworks.c:117-244): clear,
/// horizon gradient, stars, then every rabbit/gore draw the tick produced,
/// in the order `FireworksSimulation.drainEvents()` returns them (already
/// rabbit-before-gore per `core/abi.zig`'s `fireworksStepOneTick`).
public struct FireworksFrameRenderer {
    private let atlases: FireworksAtlasSet
    private let palette: Palette

    public init(atlases: FireworksAtlasSet, palette: Palette) {
        self.atlases = atlases
        self.palette = palette
    }

    public func render(events: [FireworksEvent], stars: [StarView]) -> Framebuffer {
        var fb = Framebuffer()
        fb.drawHorizonGradient(palette: palette)

        // Star x/y are raw 16.16 fixed-point (jnb_star_view's own
        // documented convention, unlike JNB_EVENT_DRAW's already-pixel
        // one) -- shift right 16 for pixels, matching
        // core/fixed16.zig's shr16.
        for s in stars {
            fb.drawStar(x: Int(s.x >> 16), y: Int(s.y >> 16), col: Int(s.col), palette: palette)
        }

        for event in events {
            switch event {
            case .rabbitDraw(let x, let y, let image):
                if let frame = atlases.rabbit.frame(forIndex: Int(image)) {
                    fb.blit(atlas: atlases.rabbitImage, frame: frame, atX: Int(x), y: Int(y))
                }
            case .gore(_, let x, let y, let image):
                if let frame = atlases.objects.frame(forIndex: Int(image)) {
                    fb.blit(atlas: atlases.objectsImage, frame: frame, atX: Int(x), y: Int(y))
                }
            case .sfx:
                break // audio is out of scope for the framebuffer renderer
            }
        }

        return fb
    }
}
