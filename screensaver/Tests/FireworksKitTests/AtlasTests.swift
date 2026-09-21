import XCTest

@testable import FireworksKit

final class AtlasTests: XCTestCase {
    private func fixtureURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/mini_atlas.json")
    }

    func testDecodesFramesKeyedByIndex() throws {
        let data = try Data(contentsOf: fixtureURL())
        let atlas = try Atlas(jsonData: data)

        let frame0 = try XCTUnwrap(atlas.frame(forIndex: 0))
        XCTAssertEqual(frame0.rect, AtlasRect(x: 0, y: 0, width: 4, height: 3))
        XCTAssertEqual(frame0.hotspotX, -1)
        XCTAssertEqual(frame0.hotspotY, 1)

        let frame5 = try XCTUnwrap(atlas.frame(forIndex: 5))
        XCTAssertEqual(frame5.rect, AtlasRect(x: 10, y: 20, width: 7, height: 5))
    }

    func testUnknownIndexReturnsNil() throws {
        let data = try Data(contentsOf: fixtureURL())
        let atlas = try Atlas(jsonData: data)
        XCTAssertNil(atlas.frame(forIndex: 999))
    }

    func testDrawOriginSubtractsHotspot() throws {
        // sprite_geometry.gd's draw_origin() convention (also
        // include/jumpnbump.h's file-header note on JNB_EVENT_DRAW): a
        // sprite drawn at (x, y) blits at (x - hotspot_x, y - hotspot_y).
        let data = try Data(contentsOf: fixtureURL())
        let atlas = try Atlas(jsonData: data)
        let frame = try XCTUnwrap(atlas.frame(forIndex: 0))

        let origin = frame.drawOrigin(atX: 100, y: 50)
        XCTAssertEqual(origin.x, 101)
        XCTAssertEqual(origin.y, 49)
    }
}
