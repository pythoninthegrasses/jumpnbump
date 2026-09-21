import CoreGraphics
import Foundation
import ImageIO

public enum AtlasImageError: Error {
    case decodeFailed
}

/// A decoded `*_atlas.png` (TASK-013.01's RGBA8, index-0-transparent
/// output): raw row-major RGBA8 pixels, decoded via ImageIO/CoreGraphics
/// (system frameworks, no third-party PNG dependency).
public struct AtlasImage {
    public let width: Int
    public let height: Int
    private let pixels: [UInt8] // RGBA8, row-major, width*height*4 bytes

    /// Direct pixel construction, bypassing PNG decoding — used by tests
    /// (`@testable import`) to build tiny fixture images without round-
    /// tripping through an encoder.
    init(width: Int, height: Int, rgba: [UInt8]) {
        precondition(rgba.count == width * height * 4)
        self.width = width
        self.height = height
        self.pixels = rgba
    }

    public init(pngData: Data) throws {
        guard
            let source = CGImageSourceCreateWithData(pngData as CFData, nil),
            let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw AtlasImageError.decodeFailed
        }

        let w = cgImage.width
        let h = cgImage.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard
            let context = buf.withUnsafeMutableBytes({ raw -> CGContext? in
                CGContext(
                    data: raw.baseAddress,
                    width: w,
                    height: h,
                    bitsPerComponent: 8,
                    bytesPerRow: w * 4,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )
            })
        else {
            throw AtlasImageError.decodeFailed
        }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))

        self.width = w
        self.height = h
        self.pixels = buf
    }

    /// (r, g, b, a), each 0...255. Out-of-bounds reads as fully transparent
    /// black rather than trapping, since callers (Framebuffer.blit) already
    /// clip against the destination, not this source.
    public func pixel(x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        guard x >= 0, x < width, y >= 0, y < height else { return (0, 0, 0, 0) }
        let i = (y * width + x) * 4
        return (pixels[i], pixels[i + 1], pixels[i + 2], pixels[i + 3])
    }
}
