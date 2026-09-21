import Foundation

/// One sprite frame's placement inside its atlas PNG, plus its hotspot —
/// the wire shape `tools/build_sprite_atlas.py` writes to
/// `game/content/sprites/*_atlas.json` (TASK-013.01).
public struct AtlasRect: Equatable {
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int
}

public struct AtlasFrame {
    public let index: Int
    public let rect: AtlasRect
    public let hotspotX: Int
    public let hotspotY: Int

    /// `game/presentation/sprite_geometry.gd`'s `draw_origin()` convention,
    /// also documented at `include/jumpnbump.h`'s `JNB_EVENT_DRAW` note: a
    /// sprite drawn at (x, y) blits with its top-left corner at
    /// (x - hotspot_x, y - hotspot_y).
    public func drawOrigin(atX x: Int, y: Int) -> (x: Int, y: Int) {
        (x - hotspotX, y - hotspotY)
    }
}

public enum AtlasError: Error {
    case malformedJSON
}

/// Decoded `*_atlas.json` manifest: `frames[i].index` is exactly the same
/// gob frame number `core/fireworks.zig`'s `rabbitImage()`/gore frame
/// constants (44..79) emit — see `Atlas.frame(forIndex:)`.
public struct Atlas {
    private let framesByIndex: [Int: AtlasFrame]

    public init(jsonData: Data) throws {
        let decoded = try JSONDecoder().decode(AtlasJSON.self, from: jsonData)
        var byIndex: [Int: AtlasFrame] = [:]
        byIndex.reserveCapacity(decoded.frames.count)
        for f in decoded.frames {
            byIndex[f.index] = AtlasFrame(
                index: f.index,
                rect: AtlasRect(x: f.x, y: f.y, width: f.width, height: f.height),
                hotspotX: f.hotspot_x,
                hotspotY: f.hotspot_y
            )
        }
        self.framesByIndex = byIndex
    }

    public func frame(forIndex index: Int) -> AtlasFrame? {
        framesByIndex[index]
    }
}

private struct AtlasJSON: Decodable {
    struct FrameJSON: Decodable {
        let index: Int
        let x: Int
        let y: Int
        let width: Int
        let height: Int
        let hotspot_x: Int
        let hotspot_y: Int
    }
    let frames: [FrameJSON]
}
