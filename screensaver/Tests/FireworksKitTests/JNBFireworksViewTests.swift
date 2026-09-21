import XCTest

@testable import FireworksKit

final class JNBFireworksViewTests: XCTestCase {
    func testClipSpaceRectFillsTheWholeViewWhenDestFillsTheWholeView() {
        // 400x256 source, exactly 400x256 view: scale 1, no letterboxing.
        let g = PresentationGeometry(sourceWidth: 400, sourceHeight: 256, viewWidth: 400, viewHeight: 256)
        let rect = g.clipSpaceRect(viewWidth: 400, viewHeight: 256)
        XCTAssertEqual(rect.x, -1, accuracy: 0.0001)
        XCTAssertEqual(rect.z, 1, accuracy: 0.0001) // x1
        // y0 (top-of-dest, at the top of the view) maps to +1 in NDC; y1 (bottom) to -1.
        XCTAssertEqual(rect.w, 1, accuracy: 0.0001) // y0
        XCTAssertEqual(rect.y, -1, accuracy: 0.0001) // y1
    }

    func testClipSpaceRectIsCenteredForALetterboxedView() {
        // 400x256 source in an 800x256 view (scale 1, letterboxed left/right).
        let g = PresentationGeometry(sourceWidth: 400, sourceHeight: 256, viewWidth: 800, viewHeight: 256)
        XCTAssertEqual(g.destX, 200)
        let rect = g.clipSpaceRect(viewWidth: 800, viewHeight: 256)
        // x0 at pixel 200 of 800 -> 200/800*2-1 = -0.5
        XCTAssertEqual(rect.x, -0.5, accuracy: 0.0001)
        XCTAssertEqual(rect.z, 0.5, accuracy: 0.0001)
    }

    func testInitWithFrameSetsPreviewFlagAndSixtyHzInterval() throws {
        let view = JNBFireworksView(frame: NSRect(x: 0, y: 0, width: 300, height: 200), isPreview: true)
        let unwrapped = try XCTUnwrap(view)
        XCTAssertEqual(unwrapped.isPreview, true)
        XCTAssertEqual(unwrapped.animationTimeInterval, 1.0 / 60.0, accuracy: 0.0001)
        XCTAssertEqual(unwrapped.hasConfigureSheet, false)
    }
}
