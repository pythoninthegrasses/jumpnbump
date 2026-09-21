import XCTest

@testable import FireworksKit

final class FramebufferTests: XCTestCase {
    func testClearProducesOpaqueBlack() {
        var fb = Framebuffer()
        fb.setPixel(x: 10, y: 10, r: 255, g: 255, b: 255)
        fb.clear()
        let i = (10 * Framebuffer.width + 10) * 4
        XCTAssertEqual(fb.pixels[i], 0)
        XCTAssertEqual(fb.pixels[i + 1], 0)
        XCTAssertEqual(fb.pixels[i + 2], 0)
        XCTAssertEqual(fb.pixels[i + 3], 255)
    }

    func testSetPixelOutOfBoundsIsANoOp() {
        var fb = Framebuffer()
        fb.setPixel(x: -1, y: 0, r: 255, g: 0, b: 0)
        fb.setPixel(x: Framebuffer.width, y: 0, r: 255, g: 0, b: 0)
        fb.setPixel(x: 0, y: -1, r: 255, g: 0, b: 0)
        fb.setPixel(x: 0, y: Framebuffer.height, r: 255, g: 0, b: 0)
        // Nothing crashed and the buffer stays default-cleared black.
        let i = 0
        XCTAssertEqual(fb.pixels[i], 0)
    }

    func testBlitPlacesPixelsAtHotspotAdjustedOrigin() throws {
        var fb = Framebuffer()
        // 2x2 opaque-red atlas image at (0,0).
        let pngPixels: [UInt8] = [
            255, 0, 0, 255, 255, 0, 0, 255,
            255, 0, 0, 255, 255, 0, 0, 255,
        ]
        let atlas = AtlasImage(width: 2, height: 2, rgba: pngPixels)
        let frame = AtlasFrame(index: 0, rect: AtlasRect(x: 0, y: 0, width: 2, height: 2), hotspotX: 1, hotspotY: 1)

        fb.blit(atlas: atlas, frame: frame, atX: 10, y: 10)
        // Origin = (10 - 1, 10 - 1) = (9, 9).
        let i = (9 * Framebuffer.width + 9) * 4
        XCTAssertEqual(fb.pixels[i], 255)
        XCTAssertEqual(fb.pixels[i + 1], 0)
        XCTAssertEqual(fb.pixels[i + 2], 0)
    }

    func testBlitClipsAgainstFramebufferEdges() throws {
        var fb = Framebuffer()
        let pngPixels: [UInt8] = Array(repeating: 0, count: 4 * 4 * 4).enumerated().map { i, _ in
            i % 4 == 0 ? 200 : (i % 4 == 3 ? 255 : 0)
        }
        let atlas = AtlasImage(width: 4, height: 4, rgba: pngPixels)
        let frame = AtlasFrame(index: 0, rect: AtlasRect(x: 0, y: 0, width: 4, height: 4), hotspotX: 0, hotspotY: 0)

        // Drawn straddling the bottom-right corner -- must not crash or
        // write out of bounds.
        fb.blit(atlas: atlas, frame: frame, atX: Framebuffer.width - 2, y: Framebuffer.height - 2)
        let i = ((Framebuffer.height - 2) * Framebuffer.width + (Framebuffer.width - 2)) * 4
        XCTAssertEqual(fb.pixels[i], 200)
    }

    func testBlitSkipsTransparentPixels() throws {
        var fb = Framebuffer()
        // Fully transparent 1x1 atlas pixel.
        let atlas = AtlasImage(width: 1, height: 1, rgba: [10, 20, 30, 0])
        let frame = AtlasFrame(index: 0, rect: AtlasRect(x: 0, y: 0, width: 1, height: 1), hotspotX: 0, hotspotY: 0)

        fb.blit(atlas: atlas, frame: frame, atX: 5, y: 5)
        let i = (5 * Framebuffer.width + 5) * 4
        // Untouched: still the cleared black, not the source's (10,20,30).
        XCTAssertEqual(fb.pixels[i], 0)
        XCTAssertEqual(fb.pixels[i + 1], 0)
        XCTAssertEqual(fb.pixels[i + 2], 0)
    }

    func testDrawHorizonGradientFillsOnlyTheBottom63Rows() throws {
        var fb = Framebuffer()
        var rgb = [UInt8](repeating: 0, count: 768)
        for i in stride(from: 0, to: rgb.count, by: 3) {
            rgb[i] = 1
            rgb[i + 1] = 2
            rgb[i + 2] = 3
        }
        let palette = Palette(rgbBytes: rgb)
        fb.drawHorizonGradient(palette: palette)

        // Row 0 (well above the gradient band) stays black.
        let above = 0
        XCTAssertEqual(fb.pixels[above * 4], 0)

        // Row height-1 uses palette index (255-192)>>2 = 15.
        let lastRow = Framebuffer.height - 1
        let i = (lastRow * Framebuffer.width) * 4
        XCTAssertEqual(fb.pixels[i], 1)
        XCTAssertEqual(fb.pixels[i + 1], 2)
        XCTAssertEqual(fb.pixels[i + 2], 3)
    }
}
