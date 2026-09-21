import XCTest

@testable import FireworksKit

final class FireworksFrameRendererTests: XCTestCase {
    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func makeRenderer() throws -> FireworksFrameRenderer {
        let spritesDir = repoRoot().appendingPathComponent("game/content/sprites")
        let rabbitAtlas = try Atlas(jsonData: Data(contentsOf: spritesDir.appendingPathComponent("rabbit_atlas.json")))
        let rabbitImage = try AtlasImage(pngData: Data(contentsOf: spritesDir.appendingPathComponent("rabbit_atlas.png")))
        let objectsAtlas = try Atlas(jsonData: Data(contentsOf: spritesDir.appendingPathComponent("objects_atlas.json")))
        let objectsImage = try AtlasImage(pngData: Data(contentsOf: spritesDir.appendingPathComponent("objects_atlas.png")))
        let palette = try Palette(pcxData: Data(contentsOf: repoRoot().appendingPathComponent("data/level.pcx")))

        let atlases = FireworksAtlasSet(rabbit: rabbitAtlas, rabbitImage: rabbitImage, objects: objectsAtlas, objectsImage: objectsImage)
        return FireworksFrameRenderer(atlases: atlases, palette: palette)
    }

    func testRenderDrawsAStarAtItsShiftedPixelPosition() throws {
        let renderer = try makeRenderer()
        // Fixed-point (16.16): pixel (100, 50) = 100<<16, 50<<16.
        let stars = [StarView(x: 100 << 16, y: 50 << 16, col: 24)]
        let fb = renderer.render(events: [], stars: stars)

        let i = (50 * Framebuffer.width + 100) * 4
        // Not still the cleared black -- a star pixel was actually plotted.
        let isBlack = fb.pixels[i] == 0 && fb.pixels[i + 1] == 0 && fb.pixels[i + 2] == 0
        XCTAssertFalse(isBlack)
    }

    func testRenderBlitsARabbitFrameFromTheRealAtlas() throws {
        let renderer = try makeRenderer()
        // image 0 is a real, always-present rabbit frame (colour 0, dir 0, frame 0).
        let events: [FireworksEvent] = [.rabbitDraw(x: 200, y: 100, image: 0)]
        let fb = renderer.render(events: events, stars: [])

        // At least one pixel within the frame's footprint differs from
        // black -- proves the atlas blit actually ran (exact pixel
        // position depends on the frame's hotspot, tested separately in
        // FramebufferTests).
        var sawNonBlack = false
        for y in 90..<115 {
            for x in 190..<215 {
                let i = (y * Framebuffer.width + x) * 4
                if fb.pixels[i] != 0 || fb.pixels[i + 1] != 0 || fb.pixels[i + 2] != 0 {
                    sawNonBlack = true
                }
            }
        }
        XCTAssertTrue(sawNonBlack)
    }

    func testRenderIgnoresAnUnknownAtlasIndexRatherThanCrashing() throws {
        let renderer = try makeRenderer()
        let events: [FireworksEvent] = [.rabbitDraw(x: 200, y: 100, image: 9999)]
        _ = renderer.render(events: events, stars: [])
        // Reaching this line without a crash is the assertion.
    }
}
