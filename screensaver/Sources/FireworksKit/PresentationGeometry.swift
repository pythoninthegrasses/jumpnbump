import Foundation

/// Where the 400x256 framebuffer lands inside an arbitrary view size:
/// largest whole-pixel integer scale that fits, centered, the remainder
/// letterboxed — same crisp-pixel-art convention `game/`'s presentation
/// layer uses for level rendering (TASK-014.04), computed independently
/// here since this renderer never goes through Godot's viewport stretch.
public struct PresentationGeometry {
    public let scale: Int
    public let destX: Int
    public let destY: Int
    public let destWidth: Int
    public let destHeight: Int

    public init(sourceWidth: Int, sourceHeight: Int, viewWidth: Int, viewHeight: Int) {
        let byWidth = viewWidth / sourceWidth
        let byHeight = viewHeight / sourceHeight
        let s = max(1, min(byWidth, byHeight))
        scale = s
        destWidth = sourceWidth * s
        destHeight = sourceHeight * s
        destX = (viewWidth - destWidth) / 2
        destY = (viewHeight - destHeight) / 2
    }
}
