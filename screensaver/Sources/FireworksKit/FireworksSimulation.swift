import CJumpnbump
import Foundation

public struct StarView {
    public let x: Int32
    public let y: Int32
    public let col: Int32
}

/// A decoded `jnb_event` the fireworks tick produced, in the order it
/// produced them — `include/jumpnbump.h`'s `JNB_EVENT_DRAW` note on the
/// `a` value is what distinguishes `.rabbitDraw` (rabbit_atlas) from
/// `.gore` (objects_atlas).
public enum FireworksEvent {
    case rabbitDraw(x: Int32, y: Int32, image: Int32)
    case gore(kind: Int32, x: Int32, y: Int32, image: Int32)
    case sfx(id: Int32, freq: Int32)
}

public enum FireworksSimulationError: Error {
    case initFailed(jnb_result)
}

/// Owns one `jnb_fireworks_*` instance's caller-allocated storage and
/// wraps the ABI in Swift-native types. `include/jumpnbump.h`'s file
/// header documents that at most one such instance is meaningful per
/// process (it shares `core/objects.zig`'s particle pool and the one RNG
/// stream) — this type does not enforce that itself; `JNBFireworksView`
/// enforces it by sharing one instance across every live view.
public final class FireworksSimulation {
    private let storage: UnsafeMutableRawPointer
    private let eventDrainCapacity = 64

    public init(seed: UInt32) throws {
        guard JNB_ABI_VERSION <= UInt32(UInt16.max) else { fatalError("JNB_ABI_VERSION overflowed uint16_t") }
        storage = UnsafeMutableRawPointer.allocate(
            byteCount: jnb_fireworks_size(),
            alignment: jnb_fireworks_align()
        )
        var config = jnb_fireworks_config(abi_version: UInt16(JNB_ABI_VERSION), _pad0: 0, rng_seed: seed)
        let result = jnb_fireworks_init(storage, &config)
        guard result == JNB_OK else {
            storage.deallocate()
            throw FireworksSimulationError.initFailed(result)
        }
    }

    deinit {
        storage.deallocate()
    }

    public func step() {
        _ = jnb_fireworks_step(storage)
    }

    /// Advances every whole 60Hz tick `deltaMs` is worth (core/game_loop.zig's
    /// `ticksFor`, shared with `jnb_pump`). Returns how many ticks ran.
    @discardableResult
    public func pump(deltaMs: UInt32) -> UInt32 {
        var ticks: UInt32 = 0
        _ = jnb_fireworks_pump(storage, deltaMs, &ticks)
        return ticks
    }

    public func stars() -> [StarView] {
        let capacity = Int(JNB_FIREWORKS_NUM_STARS)
        var raw = [jnb_star_view](repeating: jnb_star_view(x: 0, y: 0, col: 0), count: capacity)
        var required = 0
        _ = raw.withUnsafeMutableBufferPointer { ptr in
            jnb_fireworks_stars_copy(storage, ptr.baseAddress, ptr.count, &required)
        }
        return raw.map { StarView(x: $0.x, y: $0.y, col: $0.col) }
    }

    /// Drains every currently-queued event, in tick-produced order.
    public func drainEvents() -> [FireworksEvent] {
        var out: [FireworksEvent] = []
        let buf = UnsafeMutablePointer<jnb_event>.allocate(capacity: eventDrainCapacity)
        defer { buf.deallocate() }

        while jnb_fireworks_event_count(storage) > 0 {
            var drained = 0
            _ = jnb_fireworks_event_drain(storage, buf, eventDrainCapacity, &drained)
            if drained == 0 { break }
            for i in 0..<drained {
                if let e = Self.decode(buf[i]) { out.append(e) }
            }
        }
        return out
    }

    private static func decode(_ e: jnb_event) -> FireworksEvent? {
        switch Int(e.kind) {
        case JNB_EVENT_DRAW:
            return e.a == 2 ? .rabbitDraw(x: e.b, y: e.c, image: e.d) : .gore(kind: e.a, x: e.b, y: e.c, image: e.d)
        case JNB_EVENT_SFX:
            return .sfx(id: e.a, freq: e.b)
        default:
            return nil
        }
    }
}
