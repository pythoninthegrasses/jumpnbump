import XCTest

@testable import FireworksKit

final class PaletteTests: XCTestCase {
    private func repoRoot() -> URL {
        // Tests/FireworksKitTests/PaletteTests.swift -> up 3 = screensaver/,
        // up 4 = repo root.
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testDecodesLevelPcxPalette() throws {
        let levelPcx = repoRoot().appendingPathComponent("data/level.pcx")
        let data = try Data(contentsOf: levelPcx)
        let palette = try Palette(pcxData: data)

        // fireworks.c's horizon gradient reads indices 0..15; index 0 is
        // pure black (the top of the gradient, `get_color(0, pal)`).
        let black = palette.color(at: 0)
        XCTAssertEqual(black.r, 0)
        XCTAssertEqual(black.g, 0)
        XCTAssertEqual(black.b, 0)
    }

    func testRejectsGarbageBytes() {
        let garbage = Data([0, 1, 2, 3])
        XCTAssertThrowsError(try Palette(pcxData: garbage))
    }
}
