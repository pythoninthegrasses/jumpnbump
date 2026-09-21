import XCTest

@testable import FireworksKit

final class PresentationGeometryTests: XCTestCase {
    func testChoosesLargestIntegerScaleThatFitsBothDimensions() {
        // 400x256 source, an 1800x1100 view: floor(1800/400)=4, floor(1100/256)=4.
        let g = PresentationGeometry(sourceWidth: 400, sourceHeight: 256, viewWidth: 1800, viewHeight: 1100)
        XCTAssertEqual(g.scale, 4)
        XCTAssertEqual(g.destWidth, 1600)
        XCTAssertEqual(g.destHeight, 1024)
    }

    func testHeightIsTheBindingConstraint() {
        // Very wide, short view: floor(4000/400)=10, floor(300/256)=1 -> scale 1.
        let g = PresentationGeometry(sourceWidth: 400, sourceHeight: 256, viewWidth: 4000, viewHeight: 300)
        XCTAssertEqual(g.scale, 1)
    }

    func testCentersTheLetterboxedRect() {
        let g = PresentationGeometry(sourceWidth: 400, sourceHeight: 256, viewWidth: 1800, viewHeight: 1100)
        XCTAssertEqual(g.destX, (1800 - 1600) / 2)
        XCTAssertEqual(g.destY, (1100 - 1024) / 2)
    }

    func testNeverScalesBelowOneEvenInATinyPreviewPane() {
        let g = PresentationGeometry(sourceWidth: 400, sourceHeight: 256, viewWidth: 128, viewHeight: 90)
        XCTAssertEqual(g.scale, 1)
        XCTAssertEqual(g.destWidth, 400)
        XCTAssertEqual(g.destHeight, 256)
    }
}
