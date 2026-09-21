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

    func testAnisotropicFillScalesEachAxisIndependently() {
        // QHD 2560x1440: floor(2560/400)=6, floor(1440/256)=5 -- uniform
        // mode is bound by height (scale 5); anisotropic fill takes each
        // axis's own largest integer scale instead.
        let g = PresentationGeometry(
            sourceWidth: 400, sourceHeight: 256, viewWidth: 2560, viewHeight: 1440, fillMode: .anisotropicFill
        )
        XCTAssertEqual(g.scaleX, 6)
        XCTAssertEqual(g.scaleY, 5)
        XCTAssertEqual(g.destWidth, 2400)
        XCTAssertEqual(g.destHeight, 1280)
        XCTAssertEqual(g.destX, (2560 - 2400) / 2)
        XCTAssertEqual(g.destY, (1440 - 1280) / 2)
    }

    func testAnisotropicFillMatchesUniformWhenBothAxesAgree() {
        let uniform = PresentationGeometry(sourceWidth: 400, sourceHeight: 256, viewWidth: 1800, viewHeight: 1100)
        let anisotropic = PresentationGeometry(
            sourceWidth: 400, sourceHeight: 256, viewWidth: 1800, viewHeight: 1100, fillMode: .anisotropicFill
        )
        XCTAssertEqual(anisotropic.destWidth, uniform.destWidth)
        XCTAssertEqual(anisotropic.destHeight, uniform.destHeight)
    }
}
