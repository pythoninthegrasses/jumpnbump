import Foundation

/// Process-wide fireworks singleton coordination.
///
/// `include/jumpnbump.h`'s file header documents that at most one
/// `jnb_fireworks_*` instance is meaningful per process (it shares
/// `core/objects.zig`'s particle pool and the one RNG stream). System
/// Settings can host multiple `ScreenSaverView` previews concurrently in
/// one process (`backlog/decisions/decision-001`, finding 4) — every live
/// `JNBFireworksView` acquires/releases this coordinator instead of owning
/// its own `FireworksSimulation`, and `currentFrame()` advances the shared
/// clock by at most one real-time step per call window: the first view to
/// ask in a given instant pumps and composes; every other concurrent view
/// asking for that same instant gets back the identical, already-composed
/// `Framebuffer` rather than double-advancing the shared state.
public final class FireworksSimulationCoordinator {
    public static let shared = FireworksSimulationCoordinator()

    private let lock = NSLock()
    private var simulation: FireworksSimulation?
    private var renderer: FireworksFrameRenderer?
    private var refCount = 0
    private var lastPumpTime: DispatchTime?
    private var latestFrame: Framebuffer?

    init() {} // internal, not private: FireworksKitTests constructs its own instances rather than sharing `.shared`.

    /// Call once per view from `startAnimation`. The first concurrent
    /// acquire creates the shared simulation with `seed`/`atlases`/
    /// `palette`; later concurrent acquires (while any view is still live)
    /// are no-ops beyond the ref-count, reusing the already-running
    /// simulation and its already-loaded assets.
    public func acquire(seed: UInt32, atlases: FireworksAtlasSet, palette: Palette) throws {
        lock.lock()
        defer { lock.unlock() }
        refCount += 1
        guard simulation == nil else { return }
        simulation = try FireworksSimulation(seed: seed)
        renderer = FireworksFrameRenderer(atlases: atlases, palette: palette)
        lastPumpTime = nil
        latestFrame = nil
    }

    /// Call once per view from `stopAnimation`. Tears the shared
    /// simulation down once the last live view releases it, so the next
    /// acquire (a fresh preview session, or the idle-timer run replacing
    /// the preview) starts a fresh run rather than resuming mid-animation.
    public func release() {
        lock.lock()
        defer { lock.unlock() }
        refCount = max(0, refCount - 1)
        guard refCount == 0 else { return }
        simulation = nil
        renderer = nil
        latestFrame = nil
        lastPumpTime = nil
    }

    /// The frame every live view should currently be drawing, or `nil`
    /// before the first `acquire()` (or after every view has released).
    public func currentFrame() -> Framebuffer? {
        lock.lock()
        defer { lock.unlock() }
        guard let sim = simulation, let renderer = renderer else { return nil }

        guard let last = lastPumpTime else {
            lastPumpTime = DispatchTime.now()
            let frame = renderer.render(events: sim.drainEvents(), stars: sim.stars())
            latestFrame = frame
            return frame
        }

        let now = DispatchTime.now()
        let elapsedNs = now.uptimeNanoseconds &- last.uptimeNanoseconds
        let elapsedMs = UInt32(min(elapsedNs / 1_000_000, UInt64(UInt32.max)))
        guard elapsedMs > 0 else { return latestFrame }

        lastPumpTime = now
        let ticks = sim.pump(deltaMs: elapsedMs)
        if ticks > 0 {
            latestFrame = renderer.render(events: sim.drainEvents(), stars: sim.stars())
        }
        return latestFrame
    }
}
