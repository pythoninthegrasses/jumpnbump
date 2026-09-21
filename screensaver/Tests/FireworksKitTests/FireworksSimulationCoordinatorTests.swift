import XCTest

@testable import FireworksKit

final class FireworksSimulationCoordinatorTests: XCTestCase {
    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func makeAtlasesAndPalette() throws -> (FireworksAtlasSet, Palette) {
        let spritesDir = repoRoot().appendingPathComponent("game/content/sprites")
        let rabbitAtlas = try Atlas(jsonData: Data(contentsOf: spritesDir.appendingPathComponent("rabbit_atlas.json")))
        let rabbitImage = try AtlasImage(pngData: Data(contentsOf: spritesDir.appendingPathComponent("rabbit_atlas.png")))
        let objectsAtlas = try Atlas(jsonData: Data(contentsOf: spritesDir.appendingPathComponent("objects_atlas.json")))
        let objectsImage = try AtlasImage(pngData: Data(contentsOf: spritesDir.appendingPathComponent("objects_atlas.png")))
        let palette = try Palette(pcxData: Data(contentsOf: repoRoot().appendingPathComponent("data/level.pcx")))
        return (FireworksAtlasSet(rabbit: rabbitAtlas, rabbitImage: rabbitImage, objects: objectsAtlas, objectsImage: objectsImage), palette)
    }

    func testCurrentFrameIsNilBeforeAnyAcquire() {
        let coordinator = FireworksSimulationCoordinator()
        XCTAssertNil(coordinator.currentFrame())
    }

    func testAcquireThenCurrentFrameProducesAFrameAndReleaseTearsItDown() throws {
        let coordinator = FireworksSimulationCoordinator()
        let (atlases, palette) = try makeAtlasesAndPalette()

        try coordinator.acquire(seed: 1, atlases: atlases, palette: palette)
        XCTAssertNotNil(coordinator.currentFrame())

        coordinator.release()
        XCTAssertNil(coordinator.currentFrame())
    }

    func testConcurrentAcquiresShareOneSimulationUntilTheLastRelease() throws {
        let coordinator = FireworksSimulationCoordinator()
        let (atlases, palette) = try makeAtlasesAndPalette()

        try coordinator.acquire(seed: 1, atlases: atlases, palette: palette) // view A
        try coordinator.acquire(seed: 1, atlases: atlases, palette: palette) // view B, concurrent

        XCTAssertNotNil(coordinator.currentFrame())
        coordinator.release() // view A leaves
        // Still live for view B -- must not have torn down.
        XCTAssertNotNil(coordinator.currentFrame())

        coordinator.release() // view B leaves, last one out
        XCTAssertNil(coordinator.currentFrame())
    }

    func testReleaseNeverUnderflowsBelowZero() throws {
        let coordinator = FireworksSimulationCoordinator()
        coordinator.release()
        coordinator.release()
        let (atlases, palette) = try makeAtlasesAndPalette()
        try coordinator.acquire(seed: 1, atlases: atlases, palette: palette)
        XCTAssertNotNil(coordinator.currentFrame())
        coordinator.release()
        XCTAssertNil(coordinator.currentFrame())
    }
}
