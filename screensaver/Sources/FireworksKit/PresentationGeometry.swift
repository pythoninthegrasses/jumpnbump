import Foundation

/// Where the 400x256 framebuffer lands inside an arbitrary view size:
/// largest whole-pixel integer scale that fits, centered, the remainder
/// letterboxed — same crisp-pixel-art convention `game/`'s presentation
/// layer uses for level rendering (TASK-014.04), computed independently
/// here since this renderer never goes through Godot's viewport stretch.
public struct PresentationGeometry {
    /// `.uniform` scales both axes by the same integer factor (square
    /// pixels, letterboxed remainder on whichever axis has slack).
    /// `.anisotropicFill` scales each axis by its own largest integer
    /// factor instead, trading square pixels for a smaller letterbox --
    /// what `JNBFireworksView` uses.
    public enum FillMode {
        case uniform
        case anisotropicFill
    }

    public let scaleX: Int
    public let scaleY: Int
    public let destX: Int
    public let destY: Int
    public let destWidth: Int
    public let destHeight: Int

    public var scale: Int { scaleX }

    public init(
        sourceWidth: Int, sourceHeight: Int, viewWidth: Int, viewHeight: Int, fillMode: FillMode = .uniform
    ) {
        let byWidth = max(1, viewWidth / sourceWidth)
        let byHeight = max(1, viewHeight / sourceHeight)
        switch fillMode {
        case .uniform:
            let s = min(byWidth, byHeight)
            scaleX = s
            scaleY = s
        case .anisotropicFill:
            scaleX = byWidth
            scaleY = byHeight
        }
        destWidth = sourceWidth * scaleX
        destHeight = sourceHeight * scaleY
        destX = (viewWidth - destWidth) / 2
        destY = (viewHeight - destHeight) / 2
    }
}
