import XCTest

@testable import FireworksKit

final class FireworksSimulationTests: XCTestCase {
    func testInitProducesExactlyThreeHundredStarsWithinTheDocumentedPaletteRange() throws {
        let sim = try FireworksSimulation(seed: 1)
        let stars = sim.stars()
        XCTAssertEqual(stars.count, 300)
        // fireworks.c's `col = 30 - rnd(7)`, always in [24, 30].
        for s in stars {
            XCTAssertTrue((24...30).contains(s.col))
        }
    }

    func testPumpAndStepAreDeterministicAndAgreeTickForTick() throws {
        let a = try FireworksSimulation(seed: 0xC0FFEE)
        let ticks = a.pump(deltaMs: 1000)
        XCTAssertEqual(ticks, 60)

        let b = try FireworksSimulation(seed: 0xC0FFEE)
        for _ in 0..<60 { b.step() }

        let starsA = a.stars()
        let starsB = b.stars()
        XCTAssertEqual(starsA.count, starsB.count)
        for (sa, sb) in zip(starsA, starsB) {
            XCTAssertEqual(sa.x, sb.x)
            XCTAssertEqual(sa.y, sb.y)
            XCTAssertEqual(sa.col, sb.col)
        }
    }

    func testDrainEventsProducesRabbitDrawsGoreAndSfxOverTime() throws {
        let sim = try FireworksSimulation(seed: 0xC0FFEE)
        var sawRabbitDraw = false
        var sawGore = false
        var sawSfx = false
        for _ in 0..<600 {
            sim.step()
            for event in sim.drainEvents() {
                switch event {
                case .rabbitDraw: sawRabbitDraw = true
                case .gore: sawGore = true
                case .sfx: sawSfx = true
                }
            }
        }
        XCTAssertTrue(sawRabbitDraw)
        XCTAssertTrue(sawGore)
        XCTAssertTrue(sawSfx)
    }

    /// Pinned identically in core/abitest.zig's own Tier-C test -- the two
    /// sides of the ABI can never silently drift apart on star-field
    /// determinism. If this ever needs to change, core/abitest.zig's
    /// matching test must change with it, in the same commit.
    func testStarFieldChecksumAfter600TicksFromSeed0xC0FFEEMatchesTheCorePinnedGoldenValue() throws {
        let sim = try FireworksSimulation(seed: 0xC0FFEE)
        for _ in 0..<600 { sim.step() }
        let checksum = fnv1a32(stars: sim.stars())
        XCTAssertEqual(checksum, 0x3ae19a6a)
    }
}

/// FNV-1a over the exact byte layout core/abitest.zig's `jnb_checksum` call
/// hashes: `JNB_FIREWORKS_NUM_STARS` `jnb_star_view` records, each
/// `{int32 x, int32 y, int32 col}` little-endian, packed with no padding
/// (`JNB_STATIC_ASSERT(sizeof(jnb_star_view) == 12)`) -- core/world.zig's
/// `fnv1a32`, reimplemented here rather than crossing the ABI a second time
/// for a pure test-side checksum.
private func fnv1a32(stars: [StarView]) -> UInt32 {
    var bytes = [UInt8]()
    bytes.reserveCapacity(stars.count * 12)
    for s in stars {
        for v in [s.x, s.y, s.col] {
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { bytes.append(contentsOf: $0) }
        }
    }
    var hash: UInt32 = 0x811c_9dc5
    for b in bytes {
        hash ^= UInt32(b)
        hash = hash &* 0x0100_0193
    }
    return hash
}
