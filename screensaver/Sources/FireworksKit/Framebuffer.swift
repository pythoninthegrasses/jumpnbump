import Foundation

/// A software 400x256 RGBA8 framebuffer, composed once per tick and handed
/// to Metal as one nearest-neighbour full-screen quad texture
/// (`JNBFireworksView`). Mirrors `fireworks.c`'s own indexed framebuffer:
/// clear to black, draw the horizon gradient, plot stars, blit sprites —
/// see `FireworksFrameRenderer` for the per-tick composition order.
public struct Framebuffer {
    public static let width = 400
    public static let height = 256

    /// Row-major RGBA8, always fully opaque (alpha 255 everywhere) — this
    /// is the whole screen, never a layer composited over something else.
    public private(set) var pixels: [UInt8]

    public init() {
        pixels = [UInt8](repeating: 0, count: Self.width * Self.height * 4)
        clear()
    }

    public mutating func clear() {
        var i = 0
        while i < pixels.count {
            pixels[i] = 0
            pixels[i + 1] = 0
            pixels[i + 2] = 0
            pixels[i + 3] = 255
            i += 4
        }
    }

    public mutating func setPixel(x: Int, y: Int, r: UInt8, g: UInt8, b: UInt8) {
        guard x >= 0, x < Self.width, y >= 0, y < Self.height else { return }
        let i = (y * Self.width + x) * 4
        pixels[i] = r
        pixels[i + 1] = g
        pixels[i + 2] = b
        pixels[i + 3] = 255
    }

    /// fireworks.c's horizon: rows `height-63..<height`, each filled with
    /// palette index `(y - 192) >> 2` (0...15, a blue-to-black ramp in
    /// `data/level.pcx`'s palette).
    public mutating func drawHorizonGradient(palette: Palette) {
        for y in (Self.height - 63)..<Self.height {
            let index = (y - 192) >> 2
            let c = palette.color(at: index)
            for x in 0..<Self.width {
                setPixel(x: x, y: y, r: c.r, g: c.g, b: c.b)
            }
        }
    }

    /// One star pixel (fireworks.c's `set_pixel`), `col` a level.pcx
    /// palette index (already-pixel `jnb_star_view.x/y`, shifted by the
    /// caller — see `FireworksFrameRenderer`).
    public mutating func drawStar(x: Int, y: Int, col: Int, palette: Palette) {
        let c = palette.color(at: col)
        setPixel(x: x, y: y, r: c.r, g: c.g, b: c.b)
    }

    /// Blits `frame`'s pixels from `atlas` at `(x, y)`, hotspot-adjusted
    /// (`AtlasFrame.drawOrigin`) — `add_pob`'s convention. Both the source
    /// atlas rect and the destination framebuffer are clipped
    /// independently; a fully or partially off-screen sprite draws only
    /// its visible pixels. Atlas pixels with alpha 0 (palette index 0,
    /// per TASK-013.01) are skipped, never overwriting the background.
    public mutating func blit(atlas: AtlasImage, frame: AtlasFrame, atX x: Int, y: Int) {
        let origin = frame.drawOrigin(atX: x, y: y)
        for row in 0..<frame.rect.height {
            let dy = origin.y + row
            guard dy >= 0, dy < Self.height else { continue }
            let sy = frame.rect.y + row
            for col in 0..<frame.rect.width {
                let dx = origin.x + col
                guard dx >= 0, dx < Self.width else { continue }
                let sx = frame.rect.x + col
                let p = atlas.pixel(x: sx, y: sy)
                if p.a == 0 { continue }
                setPixel(x: dx, y: dy, r: p.r, g: p.g, b: p.b)
            }
        }
    }
}
